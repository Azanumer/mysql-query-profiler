#!/usr/bin/env bash
#
# mysql-query-profiler — EXPLAIN your queries and flag the expensive ones.
#
# Runs EXPLAIN on each query (from --file, --query, or --stdin) and flags:
#   FULL TABLE SCAN  — type=ALL, MySQL reads every row of the table.
#   NO INDEX USED    — no key chosen and the access type is not const/system.
#   FILESORT         — Extra contains "Using filesort" (no index for ORDER BY).
#   TEMPORARY TABLE  — Extra contains "Using temporary" (GROUP BY / DISTINCT).
#   HIGH ROW ESTIMATE — a step estimates more than --rows-warn rows.
#
# Exit codes: 0 = every query clean, 1 = at least one warning,
#             2 = usage error, a query failed to EXPLAIN, or no queries given.
#
# Connection: flags below, or MYSQL_PWD / ~/.my.cnf as usual for mysql(1).
#
set -euo pipefail

PROG="$(basename "$0")"
VERSION="1.0.0"

usage() {
    cat <<EOF
Usage: $PROG [OPTIONS] --file queries.sql | --query "SELECT ..." | --stdin

Options:
  --file FILE          SQL file with one statement per ';' (statements may
                       span lines; lines starting with -- or # are skipped).
  --query SQL          A single query to profile (repeatable).
  --stdin              Read queries from standard input, same format as --file.
  --host HOST          MySQL host (default: from ~/.my.cnf / localhost).
  --port PORT          MySQL port.
  --user USER          MySQL user.
  --password PASS      MySQL password (prefer MYSQL_PWD or ~/.my.cnf).
  --database DB        Default database for the queries.
  --defaults-file F    Read connection options from file F.
  --socket SOCK        MySQL socket.
  --rows-warn N        Row-estimate warning threshold (default 10000).
  --only-flagged       Only print queries that got at least one flag.
  --json               Print machine-readable JSON instead of text.
  --quiet              Print only the final summary line.
  --help               Show this help and exit.
  --version            Show the version and exit.

Exit codes: 0 clean, 1 warnings found, 2 error.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
INPUT_FILE=""
USE_STDIN=0
declare -a QUERIES=()
HOST="" PORT="" MYSQL_USER="" MYSQL_PASS="" DATABASE="" DEFAULTS_FILE="" SOCKET=""
ROWS_WARN=10000
ONLY_FLAGGED=0
JSON_OUT=0
QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)          INPUT_FILE="$2"; shift 2 ;;
        --query)         QUERIES+=("$2"); shift 2 ;;
        --stdin)         USE_STDIN=1; shift ;;
        --host)          HOST="$2"; shift 2 ;;
        --port)          PORT="$2"; shift 2 ;;
        --user)          MYSQL_USER="$2"; shift 2 ;;
        --password)      MYSQL_PASS="$2"; shift 2 ;;
        --database)      DATABASE="$2"; shift 2 ;;
        --defaults-file) DEFAULTS_FILE="$2"; shift 2 ;;
        --socket)        SOCKET="$2"; shift 2 ;;
        --rows-warn)     ROWS_WARN="$2"; shift 2 ;;
        --only-flagged)  ONLY_FLAGGED=1; shift ;;
        --json)          JSON_OUT=1; shift ;;
        --quiet)         QUIET=1; shift ;;
        --help)          usage; exit 0 ;;
        --version)       echo "$PROG $VERSION"; exit 0 ;;
        --file=*|--query=*|--host=*|--port=*|--user=*|--password=*|--database=*|--defaults-file=*|--socket=*|--rows-warn=*)
            key="${1%%=*}"; val="${1#*=}"
            case "$key" in
                --file) INPUT_FILE="$val" ;;
                --query) QUERIES+=("$val") ;;
                --host) HOST="$val" ;;
                --port) PORT="$val" ;;
                --user) MYSQL_USER="$val" ;;
                --password) MYSQL_PASS="$val" ;;
                --database) DATABASE="$val" ;;
                --defaults-file) DEFAULTS_FILE="$val" ;;
                --socket) SOCKET="$val" ;;
                --rows-warn) ROWS_WARN="$val" ;;
            esac
            shift ;;
        *) echo "$PROG: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if ! [[ "$ROWS_WARN" =~ ^[0-9]+$ ]]; then
    echo "$PROG: --rows-warn must be a non-negative integer" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Collect queries from a stream (file or stdin).
# Statements may span lines; a statement ends at a line whose last
# non-blank character is ';'. Comment-only and blank lines are skipped.
# NOTE: a ';' inside a string literal ends the statement early — use
# --query for such statements.
# ---------------------------------------------------------------------------
collect_stream() {
    local buffer=""
    local line trimmed
    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$trimmed" ]] && continue
        [[ "$trimmed" == --* || "$trimmed" == \#* ]] && continue
        buffer+="$line"$'\n'
        if [[ "$trimmed" == *';' ]]; then
            # Strip the trailing semicolon and any trailing whitespace.
            buffer="$(printf '%s' "$buffer" | sed -e 's/[[:space:]]*;[[:space:]]*$//')"
            QUERIES+=("$buffer")
            buffer=""
        fi
    done
    if [[ -n "$(printf '%s' "$buffer" | tr -d '[:space:]')" ]]; then
        echo "$PROG: warning: unterminated statement at end of input (no trailing ';'), skipped" >&2
    fi
}

if [[ -n "$INPUT_FILE" ]]; then
    [[ -r "$INPUT_FILE" ]] || { echo "$PROG: cannot read --file $INPUT_FILE" >&2; exit 2; }
    collect_stream < "$INPUT_FILE"
fi
if [[ "$USE_STDIN" -eq 1 ]]; then
    collect_stream
fi

if [[ "${#QUERIES[@]}" -eq 0 ]]; then
    echo "$PROG: no queries given (use --file, --query or --stdin)" >&2
    usage >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# MySQL connection arguments
# ---------------------------------------------------------------------------
declare -a MYSQL_ARGS=()
[[ -n "$DEFAULTS_FILE" ]] && MYSQL_ARGS+=(--defaults-file="$DEFAULTS_FILE")
[[ -n "$HOST" ]]         && MYSQL_ARGS+=(--host="$HOST")
[[ -n "$PORT" ]]         && MYSQL_ARGS+=(--port="$PORT")
[[ -n "$MYSQL_USER" ]]   && MYSQL_ARGS+=(--user="$MYSQL_USER")
[[ -n "$MYSQL_PASS" ]]   && MYSQL_ARGS+=(--password="$MYSQL_PASS")
[[ -n "$DATABASE" ]]     && MYSQL_ARGS+=(--database="$DATABASE")
[[ -n "$SOCKET" ]]       && MYSQL_ARGS+=(--socket="$SOCKET")

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Profile one query. Prints its report (text or JSON fragment) and sets
# the global PROFILE_STATUS to OK / WARN / ERROR.
# ---------------------------------------------------------------------------
PROFILE_STATUS="OK"
PROFILE_JSON=""

profile_one() {
    local query="$1"
    local explain_sql="$query"
    if ! [[ "$query" =~ ^[[:space:]]*[Ee][Xx][Pp][Ll][Aa][Ii][Nn][[:space:]] ]]; then
        explain_sql="EXPLAIN $query"
    fi

    local output rc=0 errfile
    errfile="$(mktemp)"
    output="$(mysql "${MYSQL_ARGS[@]}" -B -e "$explain_sql" 2>"$errfile")" || rc=$?
    local errmsg
    errmsg="$(cat "$errfile")"
    rm -f "$errfile"

    local -a flags=()
    local -a explain_rows_json=()
    PROFILE_STATUS="OK"

    if [[ "$rc" -ne 0 ]]; then
        PROFILE_STATUS="ERROR"
        flags+=("EXPLAIN failed: $(printf '%s' "$errmsg" | head -n 1)")
    else
        # Map column names to positions from the header line (MySQL and
        # MariaDB EXPLAIN both print a header with -B).
        local header_line="${output%%$'\n'*}"
        local -a header=()
        IFS=$'\t' read -r -a header <<< "$header_line"
        local idx_type=-1 idx_key=-1 idx_rows=-1 idx_extra=-1 idx_table=-1
        local i
        for i in "${!header[@]}"; do
            case "${header[$i]}" in
                type)  idx_type=$i ;;
                key)   idx_key=$i ;;
                rows)  idx_rows=$i ;;
                Extra) idx_extra=$i ;;
                table) idx_table=$i ;;
            esac
        done

        if [[ "$idx_type" -lt 0 || "$idx_key" -lt 0 || "$idx_rows" -lt 0 || "$idx_extra" -lt 0 ]]; then
            PROFILE_STATUS="ERROR"
            flags+=("unexpected EXPLAIN output (missing type/key/rows/Extra columns)")
        else
            local body="${output#*$'\n'}"
            [[ "$body" == "$output" ]] && body=""
            local row
            while IFS= read -r row; do
                [[ -z "$row" ]] && continue
                local -a cols=()
                IFS=$'\t' read -r -a cols <<< "$row"
                local ctype="${cols[$idx_type]:-}" ckey="${cols[$idx_key]:-}"
                local crows="${cols[$idx_rows]:-0}" cextra="${cols[$idx_extra]:-}"
                local ctable="${cols[$idx_table]:-?}"
                [[ "$ckey" == "NULL" ]] && ckey=""

                if [[ "$ctype" == "ALL" ]]; then
                    flags+=("FULL TABLE SCAN on $ctable (${crows} rows estimated)")
                fi
                if [[ -z "$ckey" && "$ctype" != "const" && "$ctype" != "system" && "$ctype" != "NULL" ]]; then
                    flags+=("NO INDEX USED on $ctable (type=$ctype)")
                fi
                if [[ "$cextra" == *"Using filesort"* ]]; then
                    flags+=("FILESORT on $ctable")
                fi
                if [[ "$cextra" == *"Using temporary"* ]]; then
                    flags+=("TEMPORARY TABLE on $ctable")
                fi
                if [[ "$crows" =~ ^[0-9]+$ ]] && [[ "$crows" -gt "$ROWS_WARN" ]]; then
                    flags+=("HIGH ROW ESTIMATE on $ctable (${crows} rows)")
                fi

                explain_rows_json+=("{\"table\":\"$(json_escape "$ctable")\",\"type\":\"$(json_escape "$ctype")\",\"key\":\"$(json_escape "$ckey")\",\"rows\":${crows:-0},\"extra\":\"$(json_escape "$cextra")\"}")
            done <<< "$body"
        fi
    fi

    if [[ "${#flags[@]}" -gt 0 && "$PROFILE_STATUS" == "OK" ]]; then
        PROFILE_STATUS="WARN"
    fi

    # --- Build the JSON fragment for this query. ---
    local flags_json=""
    local f
    for f in "${flags[@]}"; do
        [[ -n "$flags_json" ]] && flags_json+=","
        flags_json+="\"$(json_escape "$f")\""
    done
    local rows_json=""
    local r
    for r in "${explain_rows_json[@]}"; do
        [[ -n "$rows_json" ]] && rows_json+=","
        rows_json+="$r"
    done
    PROFILE_JSON="{\"query\":\"$(json_escape "$query")\",\"status\":\"$PROFILE_STATUS\",\"flags\":[$flags_json],\"explain\":[$rows_json]}"

    # --- Text output. ---
    if [[ "$JSON_OUT" -eq 0 && "$QUIET" -eq 0 ]]; then
        if [[ "$ONLY_FLAGGED" -eq 1 && "$PROFILE_STATUS" == "OK" ]]; then
            return
        fi
        printf '[%s] %s\n' "$PROFILE_STATUS" "$query"
        for f in "${flags[@]}"; do
            printf '  - %s\n' "$f"
        done
    fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
declare -a json_objects=()
total=0 ok=0 warn=0 errors=0
overall=0

for q in "${QUERIES[@]}"; do
    total=$((total + 1))
    profile_one "$q"
    json_objects+=("$PROFILE_JSON")
    case "$PROFILE_STATUS" in
        OK)    ok=$((ok + 1)) ;;
        WARN)  warn=$((warn + 1)); [[ "$overall" -eq 0 ]] && overall=1 ;;
        ERROR) errors=$((errors + 1)); overall=2 ;;
    esac
done

if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '['
    first=1
    for obj in "${json_objects[@]}"; do
        [[ "$first" -eq 1 ]] && first=0 || printf ','
        printf '%s' "$obj"
    done
    printf ']\n'
    printf '%s: %d quer%s profiled: %d OK, %d with warnings, %d errors\n' \
        "$PROG" "$total" "$([[ "$total" -eq 1 ]] && echo y || echo ies)" \
        "$ok" "$warn" "$errors" >&2
elif [[ "$QUIET" -eq 1 ]]; then
    printf '%s: %d quer%s profiled: %d OK, %d with warnings, %d errors\n' \
        "$PROG" "$total" "$([[ "$total" -eq 1 ]] && echo y || echo ies)" \
        "$ok" "$warn" "$errors"
else
    printf '%s: %d quer%s profiled: %d OK, %d with warnings, %d errors\n' \
        "$PROG" "$total" "$([[ "$total" -eq 1 ]] && echo y || echo ies)" \
        "$ok" "$warn" "$errors"
fi

exit "$overall"
