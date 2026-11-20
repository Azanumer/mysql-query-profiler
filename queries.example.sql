-- Example queries for mysql-query-profiler.
-- Run: ./profile-queries.sh --file queries.example.sql --database wordpress

-- Full table scan + filesort: no index on post_status, ORDER BY post_date.
SELECT * FROM wp_posts WHERE post_status = 'publish' ORDER BY post_date DESC;

-- Clean lookup by primary key.
SELECT ID, post_title FROM wp_posts WHERE ID = 42;

-- JOIN that uses the postmeta index.
SELECT p.ID, m.meta_value FROM wp_posts p
JOIN wp_postmeta m ON m.post_id = p.ID
WHERE m.meta_key = '_thumbnail_id';
