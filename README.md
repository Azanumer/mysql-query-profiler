# MySQL Query Profiler

Runs `EXPLAIN` on your queries and flags the expensive ones — before they become the 3 a.m. "site is down" page.

## What it flags

| Flag | Meaning |
|---|---|
| `FULL TABLE SCAN` | `type=ALL` — MySQL reads every row of the table. |
| `NO INDEX USED` | No key chosen and the access type isn't `const`/`system`. |
| `FILESORT` | `Extra` contains `Using filesort` — no index serves the `ORDER BY`. |
| `TEMPORARY TABLE` | `Extra` contains `Using temporary` — `GROUP BY`/`DISTINCT` spills to a temp table. |
| `HIGH ROW ESTIMATE` | A step estimates more than `--rows-warn` rows (default 10,000). |

## Usage

```bash
# One query:
./profile-queries.sh --query "SELECT * FROM wp_posts WHERE post_status = 'publish'" --database wordpress

# A whole file (statements may span lines; end each with ';'):
./profile-queries.sh --file queries.example.sql --database wordpress

# From a pipe:
wp db query "SHOW TABLES" | ./profile-queries.sh --stdin

# Machine-readable output for CI:
./profile-queries.sh --file queries.sql --json --database wordpress
```

Connection options: `--host`, `--port`, `--user`, `--password`, `--database`, `--socket`, `--defaults-file` — or the usual `~/.my.cnf` / `MYSQL_PWD`. The script never writes anything; it only runs `EXPLAIN`.

## Options

- `--rows-warn N` — row-estimate warning threshold (default `10000`).
- `--only-flagged` — only print queries that got at least one flag.
- `--json` — print a JSON array instead of text (summary goes to stderr).
- `--quiet` — print only the final summary line.

## Exit codes

- `0` — every query clean.
- `1` — at least one warning.
- `2` — usage error, a query failed to `EXPLAIN`, or no queries given.

## Example output

```
[WARN] SELECT * FROM wp_posts WHERE post_status = 'publish' ORDER BY post_date DESC
  - FULL TABLE SCAN on wp_posts (48210 rows estimated)
  - FILESORT on wp_posts
  - HIGH ROW ESTIMATE on wp_posts (48210 rows)
[OK] SELECT ID, post_title FROM wp_posts WHERE ID = 42
profile-queries.sh: 2 queries profiled: 1 OK, 1 with warnings, 0 errors
```

## Requirements

- `mysql` client in `PATH`
- Bash 4+

## License

MIT — see [LICENSE](LICENSE).
