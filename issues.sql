-- issues.sql - DuckDB queries for analyzing GitHub issues
-- Usage: duckdb < issues.sql
--    or: duckdb -cmd ".read issues.sql"   (then run queries interactively)

-- Load issues from JSON
CREATE OR REPLACE TABLE issues AS
SELECT
    repo,
    number,
    title,
    state,
    createdAt::TIMESTAMP AS created_at,
    updatedAt::TIMESTAMP AS updated_at,
    date_diff('day', updatedAt::DATE, current_date) AS days_since_update,
    url,
    author->>'login' AS author,
    labels,
    assignees
FROM read_json_auto('issues.json');

-- Unnest labels into a flat table for label-based queries
CREATE OR REPLACE TABLE issue_labels AS
SELECT
    i.repo,
    i.number,
    i.title,
    i.url,
    i.created_at,
    i.updated_at,
    l->>'name' AS label
FROM issues i,
     LATERAL unnest(i.labels) AS t(l);

-- ============================================================
-- Views
-- ============================================================

-- All open issues across repos, sorted by creation date (newest first)
CREATE OR REPLACE VIEW all_issues_by_date AS
SELECT
    repo,
    number,
    title,
    author,
    created_at,
    updated_at,
    url
FROM issues
ORDER BY created_at DESC;

-- Issue counts grouped by repo
CREATE OR REPLACE VIEW issues_by_repo AS
SELECT
    repo,
    count(*) AS issue_count,
    min(created_at) AS oldest_issue,
    max(updated_at) AS last_activity
FROM issues
GROUP BY repo
ORDER BY issue_count DESC;

-- Issues grouped by label with counts
CREATE OR REPLACE VIEW issues_by_label AS
SELECT
    label,
    count(*) AS issue_count,
    list(DISTINCT repo) AS repos
FROM issue_labels
GROUP BY label
ORDER BY issue_count DESC;

-- Recently updated issues (last 7 days)
CREATE OR REPLACE VIEW recently_updated AS
SELECT
    repo,
    number,
    title,
    author,
    updated_at,
    url
FROM issues
WHERE days_since_update <= 7
ORDER BY updated_at DESC;

-- Stale issues (no update in 30+ days)
CREATE OR REPLACE VIEW stale_issues AS
SELECT
    repo,
    number,
    title,
    author,
    updated_at,
    days_since_update,
    url
FROM issues
WHERE days_since_update > 30
ORDER BY days_since_update DESC;

-- ============================================================
-- Summary report (runs on load)
-- ============================================================

.print '=== Issue Summary ==='
.print ''

.print '--- Issues by Repo ---'
SELECT * FROM issues_by_repo;

.print ''
.print '--- Issues by Label ---'
SELECT * FROM issues_by_label;

.print ''
.print '--- Recently Updated (7 days) ---'
SELECT * FROM recently_updated;

.print ''
.print '--- Stale Issues (30+ days) ---'
SELECT repo, number, title, updated_at, days_since_update FROM stale_issues;
