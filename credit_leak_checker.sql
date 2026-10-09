/* =============================================================================
   SNOWFLAKE CREDIT LEAK CHECKER  (v1.2)          License: MIT (see README.md)
   -----------------------------------------------------------------------------
   CHANGELOG
     v1.2 (2026-10-09, after the v1.1 live run)
       - Severity now needs BOTH a share of spend AND an absolute monthly credit
         amount (parameters at the top). Check 05 drops patterns under 0.01 estimated
         credits, so a "13% of nothing" pattern can no longer rank MED / TOP3.
       - Check 07 severity scales with the service's share of ALL account credits in
         the lookback (>= 50% HIGH, >= 20% MED), so a dominant spend such as
         container services is no longer buried at LOW.
       - Check 11: a SUSPENDED never-suspend service is MED (not LOW) when its compute
         pool used >= 20% of total credits. RUNNING rules unchanged.
       - Summary (10): rows under 0.01 credits are hidden.
     v1.1 (2026-10-09, after the first live test on a trial account)
       - NEW check 11: Snowpark Container Services (SHOW SERVICES IN ACCOUNT). Found
         on our own trial: container services were 80% of all credits and resource
         monitors do not cover them.
       - Check 04 (resource monitors): fixed '100%' threshold parsing (false 04B).
       - Check 09: no row when billed cloud-services credits round to < 0.01.
       - Snowflake-managed objects (SYSTEM$* warehouses, COMPUTE_SERVICE_WH_*) are
         labelled "(Snowflake-managed)" in checks 04, 05 and the summary; they are
         capped at LOW so they do not take TOP3 slots (unless the single largest
         query pattern); COMPUTE_SERVICE_WH_* is not priced at warehouse rates.
       - How-to-run text: paste the whole file, Run All, the LAST result is the report.
       - OPT-B Snowpipe: credits per GB (BYTES_BILLED), not per file.
     v1 (2026-10-08) first release.
   WHAT IT DOES
     Reads SNOWFLAKE.ACCOUNT_USAGE plus SHOW commands and returns ONE scored list
     of where credits are probably leaking, each with a suggested fix (as TEXT)
     and a rough credit / $ impact.

   STRICTLY READ-ONLY
     Only SELECT / SHOW / SET (session variables) / USE ROLE are used. Nothing is
     created, altered or dropped. Nothing leaves your account. The "suggested_fix_sql"
     column is plain text for YOU to review; the script never executes it.

   REQUIRED ACCESS
     - ACCOUNTADMIN, or
     - a role with IMPORTED PRIVILEGES on the SNOWFLAKE database, plus MONITOR
       (or ownership) on warehouses / resource monitors so SHOW returns them.
       (See optional_least_privilege_role.sql.)
     - A running or auto-resumable warehouse (an X-Small is plenty; the script
       costs a few seconds of compute).

   HOW TO RUN (Snowsight)
     1. Open a new SQL worksheet, paste this whole file.
     2. Edit the PARAMETERS block below (especially credit_price_usd).
     3. Select a warehouse, click the arrow next to Run, choose "Run All".
        The LAST result is the final scored list (earlier results are per-check).
        Snowsight's Run All appears to use its own session, so to run ONE check on
        its own, first run section 0's SHOW / SET statements one by one in that
        same session, then the check you want.
     4. No SHOW SERVICES privilege? Comment out the three marked "CHECK 11" spots
        (section 0, the check 11 block, and its line in the final UNION).

   DATA LATENCY (ACCOUNT_USAGE is not real time)
     Per the Snowflake docs ("Account Usage" overview, data latency table):
       QUERY_HISTORY 45 min | WAREHOUSE_METERING_HISTORY, WAREHOUSE_LOAD_HISTORY,
       METERING_HISTORY, METERING_DAILY_HISTORY, PIPE_USAGE_HISTORY,
       SERVERLESS_TASK_HISTORY up to 3 h | TABLE_STORAGE_METRICS, TABLES 90 min |
       QUERY_ATTRIBUTION_HISTORY up to 8 h. Cloud-services figures in
       METERING_HISTORY can lag up to 6 h. So the last few hours of activity may
       be missing; a brand new warehouse will not show up in usage views yet.
     https://docs.snowflake.com/en/sql-reference/account-usage

   EDITION NOTES
     - Works on trial / Standard: checks 01, 02, 03, 04, 05, 06, 07, 09, 10, 11.
     - Check 08 (storage) runs on Standard too, but Time Travel > 1 day only
       exists on Enterprise+, so it will mostly report Fail-safe/dropped tables.
     - Nothing here depends on Enterprise-only views. Anything uncertain is tagged
       -- [VERIFY] inline.

   HONESTY NOTES
     - "est_monthly_credits_at_risk" is a ROUGH, directional estimate, not a
       guaranteed saving. Checks marked EXPERIMENTAL are heuristics.
     - Per-query credit figures are estimates (execution time x warehouse size
       rate). Real billing is per warehouse-second, shared by concurrent queries.
     - Credit rates assume STANDARD warehouses (XS=1 ... 6XL=512 credits/hour).
       Snowpark-optimized and Gen2 warehouses bill at different rates; multi-cluster
       warehouses bill per running cluster.
   ============================================================================= */


/* ============================== PARAMETERS ================================== */
-- !!! SET YOUR CONTRACT PRICE. 3.0 is only a placeholder (list prices vary by
-- !!! edition, cloud and region; capacity contracts differ). Nothing is assumed
-- !!! silently: the price used is printed in the final result footer.
SET credit_price_usd = 3.0;

SET lookback_days = 30;               -- how far back to look (history views keep 365 days)
SET autosuspend_max_sec = 300;        -- check 01 flags AUTO_SUSPEND above this
SET spill_min_gb = 1;                 -- check 06 flags queries spilling >= this many GB to remote storage
SET storage_min_gb = 1;               -- check 08 ignores tables below this size (TT + Fail-safe + clone-retained)
SET repeat_min_runs = 20;             -- check 05B: identical query text re-executed at least this often
SET storage_price_usd_per_tb_month = 0; -- 0 = not set (no $ shown for storage). Set to YOUR contract $/TB/month.
SET show_query_text = 0;
-- v1.2 severity parameters (a finding needs BOTH enough share AND enough absolute monthly credits):
SET min_monthly_credits_med  = 1;     -- checks 05 / 07 / 11: below this many credits per month, never above LOW
SET min_monthly_credits_high = 5;     -- check 05: HIGH needs at least this many credits per month
SET share_med_05  = 0.10;             -- check 05: share of estimated query compute for MED
SET share_high_05 = 0.20;             -- check 05: share of estimated query compute for HIGH
SET share_med_svc  = 0.20;            -- checks 07 / 11: share of TOTAL account credits for MED
SET share_high_svc = 0.50;            -- check 07: share of TOTAL account credits for HIGH
SET pattern_min_credits = 0.01;       -- check 05: ignore patterns with fewer estimated credits than this over the lookback
--              -- 0 = hide query text snippets (safer to share results); 1 = show first 160 chars

-- Optional: pick your role (uncomment). Needs ACCOUNTADMIN or IMPORTED PRIVILEGES on SNOWFLAKE.
-- USE ROLE ACCOUNTADMIN;

/* ====================== SECTION 0: SNAPSHOT SHOW COMMANDS ==================== */
-- SHOW output is captured by remembering its query id and reading it back with
-- RESULT_SCAN (results are kept 24 h in the same session). No tables are created.
SHOW WAREHOUSES;
SET q_wh = LAST_QUERY_ID();        -- RESULT_SCAN($variable) verified in Snowsight (2026-10-09)

SHOW RESOURCE MONITORS;
SET q_rm = LAST_QUERY_ID();

-- CHECK 11 (1 of 3): container services. SHOW SERVICES IN ACCOUNT needs at least one of
-- OWNERSHIP / USAGE / MONITOR / OPERATE on each service (ACCOUNTADMIN is fine). If your
-- role lacks this and the statement errors, Run All STOPS here, so comment out these two
-- lines AND the other two "CHECK 11" spots (check 11 block, final UNION line).
SHOW SERVICES IN ACCOUNT;
SET q_svc = LAST_QUERY_ID();


/* ======================================================================
   CHECK 01: AUTO_SUSPEND too long or disabled          [confidence: solid]
   Source: SHOW WAREHOUSES (auto_suspend in seconds; NULL/0 = never suspends).
   ====================================================================== */
WITH sz(size_key, credits_per_hr, size_rank, size_down, size_up) AS (
  SELECT * FROM VALUES
    ('XSMALL',1,1,'X-Small','Small'),   ('SMALL',2,2,'X-Small','Medium'),
    ('MEDIUM',4,3,'Small','Large'),     ('LARGE',8,4,'Medium','X-Large'),
    ('XLARGE',16,5,'Large','2X-Large'), ('2XLARGE',32,6,'X-Large','3X-Large'),
    ('3XLARGE',64,7,'2X-Large','4X-Large'), ('4XLARGE',128,8,'3X-Large','5X-Large'),
    ('5XLARGE',256,9,'4X-Large','6X-Large'), ('6XLARGE',512,10,'5X-Large','6X-Large')
),
wh AS (
  SELECT "name"::VARCHAR AS warehouse_name,
         UPPER(REPLACE(REPLACE("size"::VARCHAR,'-',''),' ','')) AS size_key,   -- [VERIFY] "size" like 'X-Small'
         "size"::VARCHAR AS wh_size,
         UPPER("state"::VARCHAR) AS wh_state,
         TRY_TO_NUMBER("auto_suspend"::VARCHAR) AS auto_suspend_sec            -- NULL = never suspends
  FROM TABLE(RESULT_SCAN($q_wh))
)
SELECT
  '01_AUTO_SUSPEND'                                                        AS check_id,
  IFF(COALESCE(w.auto_suspend_sec,0) = 0 OR w.auto_suspend_sec > 3600, 'HIGH', 'MED') AS severity,
  w.warehouse_name                                                         AS object,
  IFF(COALESCE(w.auto_suspend_sec,0) = 0,
      'Warehouse is set to NEVER auto-suspend (AUTO_SUSPEND NULL/0): once started it bills until someone suspends it',
      'AUTO_SUSPEND is ' || w.auto_suspend_sec::VARCHAR || 's, above the ' || TO_VARCHAR($autosuspend_max_sec)
        || 's threshold: every burst of work keeps the warehouse billing for the idle tail')  AS finding,
  'size=' || w.wh_size || ', state=' || w.wh_state || ', auto_suspend='
    || COALESCE(w.auto_suspend_sec::VARCHAR, 'NULL (never)')
    || IFF(COALESCE(w.auto_suspend_sec,0) = 0 AND w.wh_state = 'STARTED',
           ', currently RUNNING: upper bound if it stays up 24x7 = ' || (s.credits_per_hr*24*30)::VARCHAR || ' credits/month', '')
    || '. Measured idle burn is in check 03.'                              AS evidence,
  'ALTER WAREHOUSE "' || w.warehouse_name || '" SET AUTO_SUSPEND = 60;  -- 60s is a common default; consider 300 only for BI warehouses that benefit from a warm cache' AS suggested_fix_sql,
  IFF(COALESCE(w.auto_suspend_sec,0) = 0 AND w.wh_state = 'STARTED', s.credits_per_hr*24*30, NULL)::FLOAT AS est_monthly_credits_at_risk
FROM wh w
LEFT JOIN sz s ON s.size_key = w.size_key
WHERE COALESCE(w.auto_suspend_sec,0) = 0 OR w.auto_suspend_sec > $autosuspend_max_sec
ORDER BY w.warehouse_name;
SET q_c01 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 02: AUTO_RESUME off (2A, hygiene)  +  oversized candidates (2B)
   2A confidence: solid.   2B confidence: EXPERIMENTAL (heuristic).
   2B logic: size >= MEDIUM, >= 20 queries, no queuing in WAREHOUSE_LOAD_HISTORY,
   p95 execution < 10 s, p95 bytes scanned < 2 GB, no remote spilling.
   Meaning: the queries look small for the size. Test one size down; do not
   assume it is safe. Estimated saving = 50% of that warehouse's credits.
   ====================================================================== */
WITH sz(size_key, credits_per_hr, size_rank, size_down, size_up) AS (
  SELECT * FROM VALUES
    ('XSMALL',1,1,'X-Small','Small'),   ('SMALL',2,2,'X-Small','Medium'),
    ('MEDIUM',4,3,'Small','Large'),     ('LARGE',8,4,'Medium','X-Large'),
    ('XLARGE',16,5,'Large','2X-Large'), ('2XLARGE',32,6,'X-Large','3X-Large'),
    ('3XLARGE',64,7,'2X-Large','4X-Large'), ('4XLARGE',128,8,'3X-Large','5X-Large'),
    ('5XLARGE',256,9,'4X-Large','6X-Large'), ('6XLARGE',512,10,'5X-Large','6X-Large')
),
wh AS (
  SELECT "name"::VARCHAR AS warehouse_name,
         UPPER(REPLACE(REPLACE("size"::VARCHAR,'-',''),' ','')) AS size_key,
         "size"::VARCHAR AS wh_size,
         UPPER("state"::VARCHAR) AS wh_state,
         LOWER("auto_resume"::VARCHAR) AS auto_resume                          -- 'true' / 'false'
  FROM TABLE(RESULT_SCAN($q_wh))
),
ld AS (
  SELECT warehouse_name,
         COUNT(*)                    AS intervals_seen,
         MAX(avg_running)            AS peak_running,
         SUM(avg_queued_load)        AS total_queued_load
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
  WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
  GROUP BY warehouse_name
),
qshape AS (
  SELECT warehouse_name,
         COUNT(*)                                       AS n_queries,
         APPROX_PERCENTILE(execution_time, 0.95)        AS p95_exec_ms,
         APPROX_PERCENTILE(bytes_scanned, 0.95)         AS p95_bytes_scanned,
         SUM(COALESCE(bytes_spilled_to_local_storage,0) + COALESCE(bytes_spilled_to_remote_storage,0)) AS spilled_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL AND execution_time > 0
  GROUP BY warehouse_name
),
cr AS (
  SELECT warehouse_name, SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
  GROUP BY warehouse_name
)
-- 2A: AUTO_RESUME disabled
SELECT
  '02A_AUTO_RESUME_OFF' AS check_id,
  'LOW' AS severity,
  w.warehouse_name AS object,
  'AUTO_RESUME is OFF: queries fail until someone resumes the warehouse manually. Not a direct credit leak, but often a leftover from testing' AS finding,
  'size=' || w.wh_size || ', state=' || w.wh_state AS evidence,
  'ALTER WAREHOUSE "' || w.warehouse_name || '" SET AUTO_RESUME = TRUE;  -- skip if you intentionally gate this warehouse' AS suggested_fix_sql,
  NULL::FLOAT AS est_monthly_credits_at_risk
FROM wh w
WHERE w.auto_resume = 'false'
UNION ALL
-- 2B: oversized candidates (EXPERIMENTAL)
SELECT
  '02B_OVERSIZED_CANDIDATE (experimental)',
  IFF(s.size_rank >= 4, 'MED', 'LOW'),
  w.warehouse_name,
  'Queries look small for a ' || w.wh_size || ' warehouse: candidate to test one size down',
  'queries=' || qs.n_queries::VARCHAR
    || ', p95 exec=' || ROUND(qs.p95_exec_ms/1000, 1)::VARCHAR || 's'
    || ', p95 bytes scanned=' || ROUND(qs.p95_bytes_scanned/POWER(1024,3), 2)::VARCHAR || ' GB'
    || ', queued load total=' || COALESCE(ROUND(l.total_queued_load,2)::VARCHAR,'n/a')
    || ', peak avg_running=' || COALESCE(ROUND(l.peak_running,2)::VARCHAR,'n/a')
    || ', credits in lookback=' || ROUND(COALESCE(c.credits,0),2)::VARCHAR,
  'ALTER WAREHOUSE "' || w.warehouse_name || '" SET WAREHOUSE_SIZE = ''' || s.size_down
    || ''';  -- test with your real workload; revert if latency matters more than cost',
  (COALESCE(c.credits,0) * 0.5 * 30.0 / $lookback_days)::FLOAT
FROM wh w
JOIN sz s          ON s.size_key = w.size_key
JOIN qshape qs     ON qs.warehouse_name = w.warehouse_name
LEFT JOIN ld l     ON l.warehouse_name = w.warehouse_name
LEFT JOIN cr c     ON c.warehouse_name = w.warehouse_name
WHERE s.size_rank >= 3                       -- MEDIUM or larger
  AND qs.n_queries >= 20
  AND COALESCE(l.total_queued_load, 0) = 0
  AND qs.p95_exec_ms < 10000
  AND qs.p95_bytes_scanned < 2 * POWER(1024,3)
  AND qs.spilled_bytes = 0;
SET q_c02 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 03: Idle burn                       [confidence: needs verify]
   Hours in the lookback where a warehouse billed compute credits but NO query
   overlapped that hour. Mostly the idle tail after the last query (AUTO_SUSPEND
   too long), or a warehouse left running. A 60 s tail per resume is normal and
   unavoidable; this check surfaces the excess.
   Cost note: the range join below scans hourly rows x queries. Fine for most
   accounts; on very busy accounts reduce lookback_days.
   ====================================================================== */
WITH hrs AS (
  SELECT warehouse_name, start_time, end_time, credits_used_compute
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
    AND credits_used_compute > 0
    AND warehouse_name <> 'CLOUD_SERVICES_ONLY'      -- [VERIFY] pseudo-warehouse name for cloud-services-only rows
),
q AS (
  SELECT warehouse_name, start_time, end_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD('day', -1 * ($lookback_days + 1), CURRENT_TIMESTAMP())  -- +1 day margin for long queries
    AND warehouse_name IS NOT NULL
),
per_hour AS (
  SELECT h.warehouse_name, h.start_time, h.credits_used_compute,
         COUNT(q.start_time) AS n_queries
  FROM hrs h
  LEFT JOIN q
    ON q.warehouse_name = h.warehouse_name
   AND q.start_time < h.end_time
   AND q.end_time  >= h.start_time
  GROUP BY h.warehouse_name, h.start_time, h.credits_used_compute
),
agg AS (
  SELECT warehouse_name,
         SUM(credits_used_compute)                              AS total_credits,
         SUM(IFF(n_queries = 0, credits_used_compute, 0))       AS idle_credits,
         COUNT_IF(n_queries = 0)                                AS idle_hours,
         COUNT(*)                                               AS billed_hours
  FROM per_hour
  GROUP BY warehouse_name
)
SELECT
  '03_IDLE_BURN' AS check_id,
  CASE WHEN idle_credits/NULLIF(total_credits,0) >= 0.25 AND idle_credits*30.0/$lookback_days >= 5 THEN 'HIGH'
       WHEN idle_credits/NULLIF(total_credits,0) >= 0.10 AND idle_credits*30.0/$lookback_days >= 1 THEN 'MED'
       ELSE 'LOW' END AS severity,
  warehouse_name AS object,
  'Billed ' || ROUND(idle_credits,2)::VARCHAR || ' credits in ' || idle_hours::VARCHAR
    || ' hour(s) with no queries running (' || ROUND(100*idle_credits/NULLIF(total_credits,0),0)::VARCHAR || '% of its compute credits)' AS finding,
  'billed hours=' || billed_hours::VARCHAR || ', idle hours=' || idle_hours::VARCHAR
    || ', total compute credits=' || ROUND(total_credits,2)::VARCHAR
    || ', lookback=' || TO_VARCHAR($lookback_days) || ' days' AS evidence,
  'ALTER WAREHOUSE "' || warehouse_name || '" SET AUTO_SUSPEND = 60;  -- also check for scheduled tasks/BI tools that ping this warehouse' AS suggested_fix_sql,
  (idle_credits * 30.0 / $lookback_days)::FLOAT AS est_monthly_credits_at_risk
FROM agg
WHERE idle_credits > 0
ORDER BY idle_credits DESC;
SET q_c03 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 04: No resource monitor guardrail   [confidence: needs verify]
   A warehouse is "covered" if it has its own monitor OR an account-level monitor
   exists. 4B flags monitors that only notify (no suspend action) or that are
   attached to nothing. Resource monitors cover warehouses only, NOT serverless
   features (see check 07).
   ====================================================================== */
WITH sz(size_key, rank_) AS (
  SELECT * FROM VALUES ('XSMALL',1),('SMALL',2),('MEDIUM',3),('LARGE',4),('XLARGE',5),
                       ('2XLARGE',6),('3XLARGE',7),('4XLARGE',8),('5XLARGE',9),('6XLARGE',10)
),
wh AS (
  SELECT "name"::VARCHAR AS warehouse_name,
         "size"::VARCHAR AS wh_size,
         UPPER(REPLACE(REPLACE("size"::VARCHAR,'-',''),' ','')) AS size_key,
         TRY_TO_NUMBER("auto_suspend"::VARCHAR) AS auto_suspend_sec,
         NULLIF(NULLIF(LOWER(TRIM("resource_monitor"::VARCHAR)),'null'),'') AS rm_name,   -- [VERIFY] shows NULL or 'null' when unassigned
         -- Snowflake-managed "warehouses" (Streamlit/notebook runtime, container task pools): you do not own or tune them
         (STARTSWITH(UPPER("name"::VARCHAR), 'SYSTEM$') OR STARTSWITH(UPPER("name"::VARCHAR), 'COMPUTE_SERVICE_WH')) AS is_managed
  FROM TABLE(RESULT_SCAN($q_wh))
),
rm AS (
  SELECT "name"::VARCHAR AS rm_name,
         UPPER("level"::VARCHAR) AS rm_level,                                            -- [VERIFY] ACCOUNT / WAREHOUSE / NULL
         TRY_TO_NUMBER("credit_quota"::VARCHAR, 38, 2) AS credit_quota,
         TRY_TO_NUMBER("used_credits"::VARCHAR, 38, 2) AS used_credits,
         TRY_TO_NUMBER(REPLACE("suspend_at"::VARCHAR,'%','')) AS suspend_at,             -- SHOW shows thresholds like '100%' (fixed 2026-10-09: TRY_TO_NUMBER('100%') = NULL caused a false 04B)
         TRY_TO_NUMBER(REPLACE("suspend_immediately_at"::VARCHAR,'%','')) AS suspend_imm_at
  FROM TABLE(RESULT_SCAN($q_rm))
),
acct AS (SELECT COUNT_IF(rm_level = 'ACCOUNT') AS n_account_monitors, COUNT(*) AS n_monitors FROM rm)
SELECT
  '04_NO_RESOURCE_MONITOR' AS check_id,
  IFF(w.is_managed, 'LOW', IFF(COALESCE(w.auto_suspend_sec,0) = 0 OR COALESCE(s.rank_,0) >= 4, 'HIGH', 'MED')) AS severity,   -- managed objects capped at LOW
  w.warehouse_name || IFF(w.is_managed, ' (Snowflake-managed)', '') AS object,
  IFF(w.is_managed,
      'Snowflake-managed warehouse with no resource monitor. Informational: you cannot tune it, and an account-level monitor is the only way to cap it',
      'No resource monitor on this warehouse and no account-level monitor: nothing caps or alerts on runaway spend') AS finding,
  'size=' || w.wh_size || ', monitors in account=' || a.n_monitors::VARCHAR
    || ', account-level monitors=' || a.n_account_monitors::VARCHAR AS evidence,
  IFF(w.is_managed,
      '-- Snowflake-managed: usually not yours to configure. If you want a global cap, use an account-level monitor (ALTER ACCOUNT SET RESOURCE_MONITOR = <monitor>). Note: resource monitors do not cover container services (check 11).',
      'CREATE RESOURCE MONITOR "' || w.warehouse_name || '_MONITOR" WITH CREDIT_QUOTA = <monthly credits you accept> FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY TRIGGERS ON 75 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND ON 110 PERCENT DO SUSPEND_IMMEDIATE;  ALTER WAREHOUSE "'
        || w.warehouse_name || '" SET RESOURCE_MONITOR = "' || w.warehouse_name || '_MONITOR";') AS suggested_fix_sql,
  NULL::FLOAT AS est_monthly_credits_at_risk
FROM wh w
CROSS JOIN acct a
LEFT JOIN sz s ON s.size_key = w.size_key
WHERE w.rm_name IS NULL AND a.n_account_monitors = 0
UNION ALL
SELECT
  '04B_MONITOR_NOTIFY_ONLY',
  'LOW',
  r.rm_name,
  'Resource monitor has no SUSPEND action: it alerts but never stops spend',
  'level=' || COALESCE(r.rm_level,'unassigned') || ', credit_quota=' || COALESCE(r.credit_quota::VARCHAR,'n/a')
    || ', used=' || COALESCE(r.used_credits::VARCHAR,'n/a'),
  'ALTER RESOURCE MONITOR "' || r.rm_name || '" SET TRIGGERS ON 90 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND ON 110 PERCENT DO SUSPEND_IMMEDIATE;  -- review thresholds first',
  NULL::FLOAT
FROM rm r
WHERE r.suspend_at IS NULL AND r.suspend_imm_at IS NULL
UNION ALL
SELECT
  '04C_MONITOR_UNASSIGNED',
  'LOW',
  r.rm_name,
  'Resource monitor exists but is attached to neither the account nor any warehouse, so it protects nothing',
  'credit_quota=' || COALESCE(r.credit_quota::VARCHAR,'n/a'),
  'ALTER WAREHOUSE <warehouse> SET RESOURCE_MONITOR = "' || r.rm_name || '";  -- or ALTER ACCOUNT SET RESOURCE_MONITOR = "' || r.rm_name || '";',
  NULL::FLOAT
FROM rm r
WHERE r.rm_level IS NULL OR r.rm_level = 'NULL';
SET q_c04 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 05: Most expensive query patterns (5) + repeat-run queries (5B)
   5  confidence: needs verify (estimate = execution time x size rate, grouped by
      QUERY_PARAMETERIZED_HASH so the same query shape with different literals
      groups together). The estimate over-counts when queries run concurrently.
   5B confidence: EXPERIMENTAL.
   FALLBACK / ALTERNATIVE: QUERY_ATTRIBUTION_HISTORY (see optional block at the
   very end of this file) gives Snowflake's own per-query credit attribution, but
   lags up to 8 h and may be unavailable; it is kept out of the main UNION so the
   script runs even if the view is missing.
   ====================================================================== */
WITH sz(size_key, credits_per_hr, size_rank, size_down, size_up) AS (
  SELECT * FROM VALUES
    ('XSMALL',1,1,'X-Small','Small'),   ('SMALL',2,2,'X-Small','Medium'),
    ('MEDIUM',4,3,'Small','Large'),     ('LARGE',8,4,'Medium','X-Large'),
    ('XLARGE',16,5,'Large','2X-Large'), ('2XLARGE',32,6,'X-Large','3X-Large'),
    ('3XLARGE',64,7,'2X-Large','4X-Large'), ('4XLARGE',128,8,'3X-Large','5X-Large'),
    ('5XLARGE',256,9,'4X-Large','6X-Large'), ('6XLARGE',512,10,'5X-Large','6X-Large')
),
q AS (
  SELECT COALESCE(h.query_parameterized_hash, h.query_hash, h.query_id) AS pat,   -- [VERIFY] QUERY_PARAMETERIZED_HASH exists
         h.query_hash, h.query_id, h.user_name, h.warehouse_name, h.execution_time, h.bytes_scanned,
         h.start_time, h.query_text,
         h.execution_time / 3600000.0 * s.credits_per_hr AS est_credits,
         STARTSWITH(UPPER(h.warehouse_name), 'SYSTEM$') AS is_managed       -- Snowflake-managed warehouse (still billed as a warehouse, so still priced)
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY h
  JOIN sz s ON s.size_key = UPPER(REPLACE(REPLACE(h.warehouse_size,'-',''),' ',''))
  WHERE h.start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
    AND h.warehouse_name IS NOT NULL
    AND h.execution_time > 0
    -- COMPUTE_SERVICE_WH_* "warehouses" are container-runtime compute pools (e.g. COMPUTE_SERVICE_WH_USER_TASKS_POOL_*),
    -- not standard warehouses: standard credit rates would be wrong and would double count with checks 07 / 11.
    AND NOT STARTSWITH(UPPER(h.warehouse_name), 'COMPUTE_SERVICE_WH')
),
agg AS (
  SELECT pat,
         COUNT(*)                         AS runs,
         COUNT(DISTINCT user_name)        AS users,
         SUM(est_credits)                 AS est_credits,
         AVG(execution_time) / 1000       AS avg_sec,
         MAX(execution_time) / 1000       AS max_sec,
         LISTAGG(DISTINCT warehouse_name || IFF(is_managed, ' (Snowflake-managed)', ''), ', ') AS whs,
         BOOLAND_AGG(is_managed)          AS all_managed,
         MIN(query_id)                    AS sample_query_id,
         ANY_VALUE(LEFT(REGEXP_REPLACE(query_text, '\\s+', ' '), 160)) AS sample_text
  FROM q
  GROUP BY pat
),
tot AS (SELECT SUM(est_credits) AS t FROM agg),
top_patterns AS (
  SELECT a.*, t.t AS total_est,
         ROW_NUMBER() OVER (ORDER BY a.est_credits DESC) AS rk
  FROM agg a CROSS JOIN tot t
  WHERE a.est_credits >= $pattern_min_credits      -- v1.2 absolute floor: drop ~0.00-credit patterns
  QUALIFY rk <= 10
),
rep AS (   -- 5B: identical query text (QUERY_HASH) that really re-scanned data many times
  SELECT query_hash,
         COUNT_IF(bytes_scanned > 0 AND execution_time >= 1000)                     AS real_runs,
         COUNT(DISTINCT IFF(bytes_scanned > 0 AND execution_time >= 1000, start_time::DATE, NULL)) AS distinct_days,
         SUM(IFF(bytes_scanned > 0 AND execution_time >= 1000, est_credits, 0))    AS est_credits_real,
         AVG(IFF(bytes_scanned > 0 AND execution_time >= 1000, execution_time, NULL)) / 1000 AS avg_sec,
         MIN(query_id) AS sample_query_id,
         ANY_VALUE(LEFT(REGEXP_REPLACE(query_text, '\\s+', ' '), 160)) AS sample_text,
         LISTAGG(DISTINCT warehouse_name, ', ') AS whs
  FROM q
  WHERE query_hash IS NOT NULL
  GROUP BY query_hash
  HAVING COUNT_IF(bytes_scanned > 0 AND execution_time >= 1000) >= $repeat_min_runs
)
SELECT
  '05_TOP_QUERY_PATTERNS' AS check_id,
  CASE WHEN all_managed AND rk > 1 THEN 'LOW'      -- Snowflake-managed patterns only rank above LOW if they are genuinely the single largest
       WHEN est_credits / NULLIF(total_est,0) >= $share_high_05 AND est_credits * 30.0 / $lookback_days >= $min_monthly_credits_high THEN 'HIGH'
       WHEN est_credits / NULLIF(total_est,0) >= $share_med_05  AND est_credits * 30.0 / $lookback_days >= $min_monthly_credits_med  THEN 'MED'
       ELSE 'LOW' END AS severity,
  'pattern ' || LEFT(pat, 12) || ' (rank ' || rk::VARCHAR || ')' || IFF(all_managed, ' (Snowflake-managed)', '') AS object,
  'Query pattern accounts for ~' || ROUND(est_credits, 2)::VARCHAR || ' estimated credits ('
    || ROUND(100 * est_credits / NULLIF(total_est,0), 0)::VARCHAR || '% of estimated query compute) over ' || runs::VARCHAR || ' runs' AS finding,
  'runs=' || runs::VARCHAR || ', users=' || users::VARCHAR || ', avg=' || ROUND(avg_sec,1)::VARCHAR || 's, max=' || ROUND(max_sec,1)::VARCHAR
    || 's, warehouses=' || whs || ', sample_query_id=' || sample_query_id
    || ', text=' || IFF($show_query_text = 1, sample_text, '[hidden: SET show_query_text = 1]') AS evidence,
  '-- Open query ' || sample_query_id || ' in Snowsight > Query History > Query Profile. Check partition pruning (scanned vs total), join explosion, SELECT *, repeated full scans; fix the query before resizing the warehouse.' AS suggested_fix_sql,
  (est_credits * 30.0 / $lookback_days)::FLOAT AS est_monthly_credits_at_risk   -- = estimated COST of the pattern, not a promised saving
FROM top_patterns
UNION ALL
SELECT
  '05B_REPEAT_QUERIES (experimental)',
  IFF(est_credits_real * (1 - distinct_days / NULLIF(real_runs,0)) * 30.0 / $lookback_days >= 5, 'MED', 'LOW'),
  'query_hash ' || LEFT(query_hash, 12),
  'Identical query text re-executed ' || real_runs::VARCHAR || ' times on ' || distinct_days::VARCHAR
    || ' day(s), each time scanning data: candidate for result cache / a scheduled materialization',
  'avg=' || ROUND(avg_sec,1)::VARCHAR || 's, warehouses=' || whs || ', sample_query_id=' || sample_query_id
    || ', text=' || IFF($show_query_text = 1, sample_text, '[hidden: SET show_query_text = 1]'),
  '-- If the underlying data changes rarely: ensure USE_CACHED_RESULT is TRUE for the BI/user session, or serve the result from a table / dynamic table refreshed on a schedule (materialized views need Enterprise). Result cache only helps for byte-identical text with unchanged data within 24h.',
  (est_credits_real * (1 - distinct_days / NULLIF(real_runs,0)) * 30.0 / $lookback_days)::FLOAT   -- upper bound if all repeats beyond one-per-day were avoided
FROM rep;
SET q_c05 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 06: Heavy remote spilling            [confidence: needs verify]
   bytes_spilled_to_remote_storage means the working set did not fit in warehouse
   memory + local SSD: very slow and expensive. Fix is either a bigger warehouse
   for that workload (often net-cheaper because it finishes sooner) or fixing the
   query (filter earlier, avoid huge sorts/joins). No credit estimate: n/a.
   ====================================================================== */
WITH sp AS (
  SELECT warehouse_name,
         ANY_VALUE(warehouse_size)                                  AS warehouse_size,
         COALESCE(query_parameterized_hash, query_hash, query_id)   AS pat,       -- [VERIFY]
         COUNT(*)                                                   AS runs,
         SUM(bytes_spilled_to_remote_storage) / POWER(1024,3)       AS total_remote_gb,
         MAX(bytes_spilled_to_remote_storage) / POWER(1024,3)       AS max_remote_gb,
         MIN(query_id)                                              AS sample_query_id,
         ANY_VALUE(LEFT(REGEXP_REPLACE(query_text, '\\s+', ' '), 160)) AS sample_text
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    AND bytes_spilled_to_remote_storage >= $spill_min_gb * POWER(1024,3)
  GROUP BY warehouse_name, COALESCE(query_parameterized_hash, query_hash, query_id)
)
SELECT
  '06_REMOTE_SPILL' AS check_id,
  IFF(runs >= 10 OR total_remote_gb >= 100, 'HIGH', 'MED') AS severity,
  warehouse_name || ' / pattern ' || LEFT(pat, 12) AS object,
  runs::VARCHAR || ' run(s) spilled ' || ROUND(total_remote_gb, 1)::VARCHAR || ' GB to REMOTE storage (largest single query ' || ROUND(max_remote_gb,1)::VARCHAR || ' GB)' AS finding,
  'warehouse_size=' || COALESCE(warehouse_size,'n/a') || ', sample_query_id=' || sample_query_id
    || ', text=' || IFF($show_query_text = 1, sample_text, '[hidden: SET show_query_text = 1]') AS evidence,
  '-- Option A (separate heavy workload): ALTER WAREHOUSE "' || warehouse_name || '" SET WAREHOUSE_SIZE = ''<one size up>'';  or route this query to a dedicated larger warehouse. Option B: rewrite query ' || sample_query_id || ' (see Query Profile: spilling operators).' AS suggested_fix_sql,
  NULL::FLOAT AS est_monthly_credits_at_risk
FROM sp
ORDER BY total_remote_gb DESC
LIMIT 20;
SET q_c06 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 07: Serverless spend                 [confidence: needs verify]
   One row per (service type, object) outside normal warehouse metering, from
   METERING_HISTORY: Snowpipe (PIPE), serverless tasks, automatic clustering,
   materialized views, search optimization, query acceleration, replication,
   AI services, etc. Flags anything >= 0.1 credit/month; severity by monthly size
   (>= 50 HIGH, >= 10 MED). Resource monitors do NOT cap these.
   Detail views for Snowpipe / tasks (PIPE_USAGE_HISTORY, SERVERLESS_TASK_HISTORY)
   can drill down; see the optional block at the end of this file.
   ====================================================================== */
WITH s AS (
  SELECT service_type,
         COALESCE(NULLIF(database_name || '.' || schema_name || '.', '.'), '') || COALESCE(name, service_type) AS obj,  -- [VERIFY] DATABASE_NAME/SCHEMA_NAME/NAME populated per service
         SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
    AND service_type NOT IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER')
  GROUP BY service_type, 2
),
tot AS (   -- v1.2: ALL account credits in the lookback (warehouses + serverless), the denominator for severity
  SELECT SUM(credits_used) AS total
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
)
SELECT
  '07_SERVERLESS_' || service_type AS check_id,
  CASE WHEN credits * 30.0 / $lookback_days >= 50
         OR (credits / NULLIF(t.total,0) >= $share_high_svc AND credits * 30.0 / $lookback_days >= $min_monthly_credits_med) THEN 'HIGH'
       WHEN credits * 30.0 / $lookback_days >= 10
         OR (credits / NULLIF(t.total,0) >= $share_med_svc  AND credits * 30.0 / $lookback_days >= $min_monthly_credits_med) THEN 'MED'
       ELSE 'LOW' END AS severity,
  obj AS object,
  'Serverless service ' || service_type || ' consumed ' || ROUND(credits, 2)::VARCHAR || ' credits in the last ' || TO_VARCHAR($lookback_days) || ' days ('
    || ROUND(100 * credits / NULLIF(t.total,0), 0)::VARCHAR || '% of all ' || ROUND(t.total,2)::VARCHAR || ' account credits)' AS finding,
  'Not covered by warehouse resource monitors; verify it is intentional and sized right' AS evidence,
  CASE service_type
    WHEN 'PIPE' THEN '-- Snowpipe: current billing is a fixed credit amount per GB ingested, so look at volume: is all of it needed, are files re-loaded, would COPY INTO on a warehouse be cheaper for infrequent big loads? Drill down: PIPE_USAGE_HISTORY (see OPT-B: credits per GB billed).'
    WHEN 'SERVERLESS_TASK' THEN '-- ALTER TASK <task> SUSPEND;  or lengthen its SCHEDULE; if it runs back-to-back consider a warehouse-backed task. Drill down: SERVERLESS_TASK_HISTORY.'
    WHEN 'AUTO_CLUSTERING' THEN '-- If the clustering key is not improving pruning: ALTER TABLE <table> SUSPEND RECLUSTER;  or ALTER TABLE <table> DROP CLUSTERING KEY;  (check SYSTEM$CLUSTERING_INFORMATION first)'
    WHEN 'MATERIALIZED_VIEW' THEN '-- Unused or high-churn base table? ALTER MATERIALIZED VIEW <mv> SUSPEND;  or DROP it after checking ACCESS_HISTORY for readers.'
    WHEN 'SEARCH_OPTIMIZATION' THEN '-- ALTER TABLE <table> DROP SEARCH OPTIMIZATION;  or limit it with ADD SEARCH OPTIMIZATION ON EQUALITY(<cols>).'
    WHEN 'QUERY_ACCELERATION' THEN '-- ALTER WAREHOUSE <wh> SET ENABLE_QUERY_ACCELERATION = FALSE;  or lower QUERY_ACCELERATION_MAX_SCALE_FACTOR.'
    WHEN 'SNOWPARK_CONTAINER_SERVICES' THEN '-- Container services (incl. Notebook / Streamlit runtimes) bill per compute-pool uptime. See check 11 for which services are running and how to stop them.'
    WHEN 'AI_SERVICES' THEN '-- Review which users/roles call AI functions; set per-role limits and consider smaller models.'
    ELSE '-- Review in Snowsight > Admin > Cost Management > Consumption, filter by this service type.'
  END AS suggested_fix_sql,
  (credits * 30.0 / $lookback_days)::FLOAT AS est_monthly_credits_at_risk
FROM s CROSS JOIN tot t
WHERE credits * 30.0 / $lookback_days >= 0.1
ORDER BY credits DESC
LIMIT 30;
SET q_c07 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 08: Storage waste                    [confidence: needs verify]
   Storage is billed in $ per TB, not credits, so est_monthly_credits_at_risk is
   n/a. If you SET storage_price_usd_per_tb_month, the $ per month is added to the
   evidence text. 8A heavy Time Travel + Fail-safe; 8B dropped tables still
   holding storage; 8C bytes retained only because of clones; 8D permanent tables
   that look like staging/scratch data (name heuristic = EXPERIMENTAL).
   Fail-safe (7 days, permanent tables) cannot be shortened by you; the lever is
   to make staging data TRANSIENT (no Fail-safe, Time Travel <= 1 day).
   ====================================================================== */
WITH m AS (
  SELECT id, table_catalog, table_schema, table_name,
         UPPER(is_transient::VARCHAR) AS is_transient,                       -- [VERIFY] values 'YES'/'NO'
         COALESCE(active_bytes,0) AS active_bytes,
         COALESCE(time_travel_bytes,0) AS tt_bytes,
         COALESCE(failsafe_bytes,0) AS fs_bytes,
         COALESCE(retained_for_clone_bytes,0) AS clone_bytes,
         table_dropped,                                                      -- [VERIFY] NULL while the table is live
         table_catalog || '.' || table_schema || '.' || table_name AS fqn
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
),
ret AS (   -- [VERIFY] ACCOUNT_USAGE.TABLES has TABLE_ID, RETENTION_TIME, DELETED
  SELECT table_id, retention_time, table_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
),
usd AS (SELECT $storage_price_usd_per_tb_month AS p)
-- 8A: heavy Time Travel + Fail-safe on live tables
SELECT
  '08A_TT_FAILSAFE_HEAVY' AS check_id,
  IFF(tt_bytes + fs_bytes >= POWER(1024,4), 'HIGH', IFF(tt_bytes + fs_bytes >= active_bytes AND tt_bytes + fs_bytes >= 10*POWER(1024,3), 'MED', 'LOW')) AS severity,
  fqn AS object,
  'Time Travel + Fail-safe hold ' || ROUND((tt_bytes+fs_bytes)/POWER(1024,3),1)::VARCHAR || ' GB vs ' || ROUND(active_bytes/POWER(1024,3),1)::VARCHAR || ' GB of active data',
  'time_travel=' || ROUND(tt_bytes/POWER(1024,3),1)::VARCHAR || ' GB, failsafe=' || ROUND(fs_bytes/POWER(1024,3),1)::VARCHAR
    || ' GB, transient=' || is_transient
    || IFF(u.p > 0, ', ~$' || ROUND((tt_bytes+fs_bytes)/POWER(1024,4) * u.p, 2)::VARCHAR || '/month at your storage price', ''),
  '-- High churn (frequent full reloads/updates) inflates Time Travel + Fail-safe. Options: ALTER TABLE ' || fqn || ' SET DATA_RETENTION_TIME_IN_DAYS = 1;  and for reloadable data, recreate as TRANSIENT (CREATE TRANSIENT TABLE ... AS SELECT ...) so there is no Fail-safe.',
  NULL::FLOAT
FROM m, usd u
WHERE table_dropped IS NULL
  AND tt_bytes + fs_bytes >= $storage_min_gb * POWER(1024,3)
  AND tt_bytes + fs_bytes >= active_bytes
UNION ALL
-- 8B: dropped tables still holding storage
SELECT
  '08B_DROPPED_STILL_STORED',
  IFF(tt_bytes + fs_bytes >= 100*POWER(1024,3), 'MED', 'LOW'),
  fqn,
  'Dropped table still holds ' || ROUND((tt_bytes+fs_bytes)/POWER(1024,3),1)::VARCHAR || ' GB (dropped ' || table_dropped::DATE::VARCHAR || ')',
  'time_travel=' || ROUND(tt_bytes/POWER(1024,3),1)::VARCHAR || ' GB, failsafe=' || ROUND(fs_bytes/POWER(1024,3),1)::VARCHAR
    || IFF(u.p > 0, ', ~$' || ROUND((tt_bytes+fs_bytes)/POWER(1024,4) * u.p, 2)::VARCHAR || '/month', ''),
  '-- Informational: Time Travel purges automatically after the retention period, then Fail-safe (7 days, permanent tables) which you cannot shorten. Prevention: create scratch/staging tables as TRANSIENT; for future drops lower DATA_RETENTION_TIME_IN_DAYS before dropping.',
  NULL::FLOAT
FROM m, usd u
WHERE table_dropped IS NOT NULL
  AND tt_bytes + fs_bytes >= $storage_min_gb * POWER(1024,3)
UNION ALL
-- 8C: storage retained only because of clones
SELECT
  '08C_RETAINED_FOR_CLONE',
  'LOW',
  fqn,
  ROUND(clone_bytes/POWER(1024,3),1)::VARCHAR || ' GB retained only because other objects still clone from this table',
  'active=' || ROUND(active_bytes/POWER(1024,3),1)::VARCHAR || ' GB' || IFF(u.p > 0, ', ~$' || ROUND(clone_bytes/POWER(1024,4) * u.p, 2)::VARCHAR || '/month', ''),
  '-- Find and drop stale clones of this table (SHOW TABLES / TABLE_STORAGE_METRICS by CLONE_GROUP_ID); storage frees once no clone references it.',
  NULL::FLOAT
FROM m, usd u
WHERE clone_bytes >= $storage_min_gb * POWER(1024,3)
UNION ALL
-- 8D: permanent tables that look like staging/scratch data (EXPERIMENTAL name heuristic)
SELECT
  '08D_STAGING_NOT_TRANSIENT (experimental)',
  IFF(tt_bytes + fs_bytes >= 50*POWER(1024,3), 'MED', 'LOW'),
  fqn,
  'Looks like staging/scratch data (by name) but is a PERMANENT table with retention ' || r.retention_time::VARCHAR || ' day(s): pays for Fail-safe + Time Travel',
  'time_travel=' || ROUND(tt_bytes/POWER(1024,3),1)::VARCHAR || ' GB, failsafe=' || ROUND(fs_bytes/POWER(1024,3),1)::VARCHAR
    || ', active=' || ROUND(active_bytes/POWER(1024,3),1)::VARCHAR || ' GB'
    || IFF(u.p > 0, ', ~$' || ROUND((tt_bytes+fs_bytes)/POWER(1024,4) * u.p, 2)::VARCHAR || '/month', ''),
  '-- If this data can be reloaded from source: recreate as TRANSIENT (CREATE TRANSIENT TABLE ... AS SELECT ...), or ALTER TABLE ' || fqn || ' SET DATA_RETENTION_TIME_IN_DAYS = 0;  Better: put staging tables in a TRANSIENT SCHEMA.',
  NULL::FLOAT
FROM m
JOIN ret r ON r.table_id = m.id
CROSS JOIN usd u
WHERE m.table_dropped IS NULL
  AND m.is_transient IN ('NO', 'FALSE')
  AND r.table_type = 'BASE TABLE'
  AND REGEXP_LIKE(UPPER(m.table_name || ' ' || m.table_schema), '.*(^|[^A-Z])(STG|STAGE|STAGING|TMP|TEMP|RAW|LANDING|SCRATCH|BAK|BACKUP|OLD)([^A-Z]|$).*')
  AND m.tt_bytes + m.fs_bytes >= $storage_min_gb * POWER(1024,3)
ORDER BY 1, 2;
SET q_c08 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 09: Cloud services above the 10% daily threshold  [needs verify]
   Cloud services credits are only BILLED when a day's cloud-services usage
   exceeds 10% of that day's warehouse compute (METERING_DAILY_HISTORY docs).
   billed_cloud_services = credits_used_cloud_services + credits_adjustment_cloud_services
   (the adjustment is stored as a negative number). On a near-idle trial,
   tiny compute makes the 10% line tiny, so a LOW finding there is expected.
   ====================================================================== */
WITH d AS (
  SELECT usage_date,
         SUM(IFF(service_type = 'WAREHOUSE_METERING', credits_used_compute, 0)) AS wh_compute,
         SUM(credits_used_cloud_services)                                      AS cs_used,
         SUM(credits_adjustment_cloud_services)                                AS cs_adj,   -- [VERIFY] negative values; does the 10% adjustment appear per-day on all rows?
         SUM(credits_used)                                                     AS all_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD('day', -1 * $lookback_days, CURRENT_DATE())
  GROUP BY usage_date
),
b AS (
  SELECT usage_date, wh_compute, cs_used, all_credits,
         GREATEST(cs_used + COALESCE(cs_adj,0), 0) AS cs_billed
  FROM d
),
agg AS (
  SELECT SUM(cs_billed) AS billed, SUM(cs_used) AS used, SUM(wh_compute) AS wh_compute, SUM(all_credits) AS all_credits,
         COUNT_IF(cs_billed > 0.0001) AS days_over, COUNT(*) AS n_days,
         MAX_BY(usage_date, cs_billed) AS worst_day, MAX(cs_billed) AS worst_billed
  FROM b
)
SELECT
  '09_CLOUD_SERVICES_OVER_10PCT' AS check_id,
  CASE WHEN billed * 30.0 / $lookback_days >= 5 AND billed / NULLIF(all_credits,0) >= 0.10 THEN 'HIGH'
       WHEN billed * 30.0 / $lookback_days >= 1 THEN 'MED' ELSE 'LOW' END AS severity,
  'account' AS object,
  ROUND(billed, 2)::VARCHAR || ' cloud-services credits were billed beyond the 10% allowance on ' || days_over::VARCHAR || ' of ' || n_days::VARCHAR || ' days' AS finding,
  'cloud services used=' || ROUND(used,2)::VARCHAR || ', warehouse compute=' || ROUND(wh_compute,2)::VARCHAR
    || ', worst day=' || worst_day::VARCHAR || ' (' || ROUND(worst_billed,2)::VARCHAR || ' billed)' AS evidence,
  '-- Find the heavy cloud-services queries: SELECT query_type, COUNT(*) n, SUM(credits_used_cloud_services) cs FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY WHERE start_time >= DATEADD(''day'',-7,CURRENT_TIMESTAMP()) GROUP BY 1 ORDER BY 3 DESC LIMIT 10;  Common causes: very many tiny queries, metadata commands (SHOW/DESCRIBE) in loops, frequent failed queries, tiny-file COPY.' AS suggested_fix_sql,
  (billed * 30.0 / $lookback_days)::FLOAT AS est_monthly_credits_at_risk
FROM agg
WHERE ROUND(billed, 2) >= 0.01;      -- v1.1: suppress rows that would display as 0.00 billed credits
SET q_c09 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 10: Summary - credits by warehouse + serverless service
   [confidence: needs verify]. Feeds the top of the final result set.
   ====================================================================== */
WITH w AS (
  SELECT 'warehouse' AS kind,
         warehouse_name || IFF(STARTSWITH(UPPER(warehouse_name), 'SYSTEM$') OR STARTSWITH(UPPER(warehouse_name), 'COMPUTE_SERVICE_WH'),
                               ' (Snowflake-managed)', '') AS obj,
         SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
  GROUP BY warehouse_name
),
s AS (
  SELECT 'serverless' AS kind, service_type AS obj, SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
    AND service_type NOT IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER')
  GROUP BY service_type
),
u AS (SELECT * FROM w UNION ALL SELECT * FROM s),
t AS (SELECT SUM(credits) AS total FROM u)
SELECT
  '10_SUMMARY' AS check_id,
  'INFO' AS severity,
  u.kind || ': ' || u.obj AS object,
  ROUND(u.credits, 2)::VARCHAR || ' credits in the last ' || TO_VARCHAR($lookback_days) || ' days ('
    || ROUND(100 * u.credits / NULLIF(t.total,0), 0)::VARCHAR || '% of ' || ROUND(t.total,2)::VARCHAR || ' total; about $'
    || ROUND(u.credits * $credit_price_usd, 2)::VARCHAR || ' at $' || TO_VARCHAR($credit_price_usd) || '/credit)' AS finding,
  'Source: WAREHOUSE_METERING_HISTORY / METERING_HISTORY (includes cloud-services credits for warehouses)' AS evidence,
  'n/a' AS suggested_fix_sql,
  u.credits::FLOAT AS credits_in_lookback
FROM u CROSS JOIN t
WHERE ROUND(u.credits, 2) >= 0.01      -- v1.2: hide rows that would display as 0.00
ORDER BY u.credits DESC;
SET q_c10 = LAST_QUERY_ID();


/* ======================================================================
   CHECK 11: Container services (Snowpark Container Services)   [NEW in v1.1]
   CHECK 11 (2 of 3) -- comment out this whole block if your role cannot run
   SHOW SERVICES IN ACCOUNT (see section 0).
   Notebooks (container runtime) and Streamlit apps run as container services on a
   compute pool and bill for the whole time the service is up, whether or not anyone
   is using it. RESOURCE MONITORS DO NOT COVER THIS SPEND (they cap warehouses only).
   Flags: RUNNING services (HIGH if auto_suspend_secs is 0 = never, or > 3600; else MED)
   and SUSPENDED services configured with auto_suspend_secs 0 / > 3600 (LOW: a risk
   the next time they start).
   Credits: METERING_HISTORY (SERVICE_TYPE = 'SNOWPARK_CONTAINER_SERVICES') is
   metered per compute pool (NAME = pool name, e.g. SYSTEM_COMPUTE_POOL_CPU), not
   per service. The monthly figure is the pool's credits, split evenly across the
   RUNNING services on that pool, so it is directional and a pool can include
   services that no longer exist.
   ====================================================================== */
WITH svc AS (
  SELECT "name"::VARCHAR                                         AS service_name,
         "database_name"::VARCHAR                                AS db_name,
         "schema_name"::VARCHAR                                  AS schema_name,
         UPPER("status"::VARCHAR)                                AS status,
         "owner"::VARCHAR                                        AS owner_role,
         "compute_pool"::VARCHAR                                 AS compute_pool,
         TRY_TO_NUMBER("auto_suspend_secs"::VARCHAR)             AS auto_suspend_secs,     -- 0 = never suspends
         TRY_TO_TIMESTAMP_LTZ("resumed_on"::VARCHAR)             AS resumed_on,
         TRY_TO_TIMESTAMP_LTZ("created_on"::VARCHAR)             AS created_on,
         UPPER(NULLIF(TRIM("managing_object_domain"::VARCHAR),'')) AS managed_domain,    -- e.g. 'NOTEBOOK', 'STREAMLIT'
         NULLIF(TRIM("managing_object_name"::VARCHAR),'')        AS managed_name
  FROM TABLE(RESULT_SCAN($q_svc))
),
pool AS (
  SELECT UPPER(name) AS pool_name, SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE service_type = 'SNOWPARK_CONTAINER_SERVICES'
    AND start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
  GROUP BY UPPER(name)
),
tot AS (SELECT SUM(credits_used) AS total
         FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
         WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())),
x AS (
  SELECT s.*,
         p.credits AS pool_credits,
         p.credits / NULLIF(t.total, 0) AS pool_share,
         SUM(IFF(s.status = 'RUNNING', 1, 0)) OVER (PARTITION BY UPPER(s.compute_pool)) AS n_running_on_pool,
         COALESCE(s.auto_suspend_secs, 0) = 0 OR s.auto_suspend_secs > 3600       AS never_or_long
  FROM svc s
  LEFT JOIN pool p ON p.pool_name = UPPER(s.compute_pool)
  CROSS JOIN tot t
)
SELECT
  '11_CONTAINER_SERVICE' AS check_id,
  CASE WHEN status = 'RUNNING' THEN IFF(never_or_long, 'HIGH', 'MED')
       -- v1.2: a suspended never-suspend service is MED when its pool used a large share of ALL credits
       WHEN pool_share >= $share_med_svc AND pool_credits * 30.0 / $lookback_days >= $min_monthly_credits_med THEN 'MED'
       ELSE 'LOW' END AS severity,
  db_name || '.' || schema_name || '.' || service_name
    || IFF(managed_domain IS NOT NULL, ' (' || INITCAP(managed_domain) || IFF(managed_name IS NOT NULL, ': ' || managed_name, '') || ')', '') AS object,
  IFF(status = 'RUNNING',
      'Container service is RUNNING and bills while up' || IFF(never_or_long,
         ', with AUTO_SUSPEND_SECS = ' || COALESCE(auto_suspend_secs, 0)::VARCHAR || IFF(COALESCE(auto_suspend_secs, 0) = 0, ' (never auto-suspends)', ' (longer than 1 hour)'), ''),
      'Service is ' || status || ' but configured with AUTO_SUSPEND_SECS = ' || COALESCE(auto_suspend_secs, 0)::VARCHAR
         || IFF(COALESCE(auto_suspend_secs, 0) = 0, ' (never)', ' (longer than 1 hour)') || ': a risk the next time it starts') AS finding,
  'compute_pool=' || COALESCE(compute_pool, 'n/a') || ', status=' || status
    || ', up since=' || COALESCE(TO_VARCHAR(COALESCE(resumed_on, created_on), 'YYYY-MM-DD HH24:MI'), 'n/a')
    || IFF(status = 'RUNNING' AND COALESCE(resumed_on, created_on) IS NOT NULL,
           ' (~' || DATEDIFF('hour', COALESCE(resumed_on, created_on), CURRENT_TIMESTAMP())::VARCHAR || ' h)', '')
    || ', owner=' || COALESCE(owner_role, 'n/a')
    || ', pool credits in lookback=' || COALESCE(ROUND(pool_credits, 2)::VARCHAR, 'n/a')
    || IFF(pool_share IS NOT NULL, ' (' || ROUND(100 * pool_share, 0)::VARCHAR || '% of all account credits)', '')
    || '. Resource monitors do NOT cover container services.' AS evidence,
  CASE
    WHEN managed_domain = 'NOTEBOOK' THEN
      '-- Managed by a Notebook: end the notebook session / stop the notebook in Snowsight (Projects > Notebooks). ALTER SERVICE normally fails here even for ACCOUNTADMIN ("Insufficient privileges to operate on service ... must have OPERATE granted") because the service is managed by the notebook.'
    WHEN managed_domain = 'STREAMLIT' THEN
      '-- Managed by a Streamlit app: stop or delete the Streamlit app in Snowsight (Projects > Streamlit). ALTER SERVICE normally fails here even for ACCOUNTADMIN (needs OPERATE on the managed service).'
    WHEN managed_domain IS NOT NULL THEN
      '-- Managed by a ' || managed_domain || ' object: stop or delete that object in Snowsight rather than altering the service directly (needs OPERATE on the managed service).'
    ELSE
      '-- User-owned service: ALTER SERVICE "' || db_name || '"."' || schema_name || '"."' || service_name || '" SUSPEND;  and/or  ALTER SERVICE "' || db_name || '"."' || schema_name || '"."' || service_name
        || '" SET AUTO_SUSPEND_SECS = 600;  -- SUSPEND needs OPERATE; SET needs OWNERSHIP; AUTO_SUSPEND_SECS minimum is 300 (preview feature per docs). Also consider ALTER COMPUTE POOL ... SET AUTO_SUSPEND_SECS.'
  END AS suggested_fix_sql,
  IFF(status = 'RUNNING' AND pool_credits IS NOT NULL,
      pool_credits * 30.0 / $lookback_days / GREATEST(n_running_on_pool, 1), NULL)::FLOAT AS est_monthly_credits_at_risk
FROM x
WHERE status = 'RUNNING' OR (status = 'SUSPENDED' AND never_or_long)
ORDER BY service_name;
SET q_c11 = LAST_QUERY_ID();


/* ======================================================================
   FINAL RESULT SET: scored list, sorted by severity.
   Order: SUMMARY rows, TOP 3 findings, then every finding HIGH -> MED -> LOW,
   then the footer (assumptions + next step).
   If a check returned 0 rows it simply does not appear: a clean account is a
   valid outcome. [VERIFY] RESULT_SCAN($q_cNN) on each saved query id.
   ====================================================================== */
WITH f AS (
  SELECT * FROM TABLE(RESULT_SCAN($q_c01))
  UNION ALL SELECT * FROM TABLE(RESULT_SCAN($q_c02))
  UNION ALL SELECT * FROM TABLE(RESULT_SCAN($q_c03))
  UNION ALL SELECT * FROM TABLE(RESULT_SCAN($q_c04))
  UNION ALL SELECT * FROM TABLE(RESULT_SCAN($q_c05))
  UNION ALL SELECT * FROM TABLE(RESULT_SCAN($q_c06))
  UNION ALL SELECT * FROM TABLE(RESULT_SCAN($q_c07))
  UNION ALL SELECT * FROM TABLE(RESULT_SCAN($q_c08))
  UNION ALL SELECT * FROM TABLE(RESULT_SCAN($q_c09))
  UNION ALL SELECT * FROM TABLE(RESULT_SCAN($q_c11))     -- CHECK 11 (3 of 3): remove this line if you removed check 11
),
ranked AS (
  SELECT f.*,
         DECODE(severity, 'HIGH', 1, 'MED', 2, 'LOW', 3, 9) AS sev_rank
  FROM f
),
top3 AS (
  SELECT * FROM ranked
  QUALIFY ROW_NUMBER() OVER (ORDER BY sev_rank, est_monthly_credits_at_risk DESC NULLS LAST, check_id, object) <= 3
)
SELECT check_id, severity, object, finding, evidence, suggested_fix_sql,
       ROUND(est_monthly_credits_at_risk, 2) AS est_monthly_credits_at_risk,       -- NULL = n/a
       ROUND(est_monthly_credits_at_risk * $credit_price_usd, 2) AS est_monthly_usd_at_risk
FROM (
  -- credit totals (summary)
  SELECT check_id, severity, object, finding, evidence, suggested_fix_sql,
         NULL::FLOAT AS est_monthly_credits_at_risk, 0 AS grp, 0 AS sev_rank, credits_in_lookback AS sort_val
  FROM TABLE(RESULT_SCAN($q_c10))
  UNION ALL
  -- top 3 findings
  SELECT '10_TOP3_#' || (ROW_NUMBER() OVER (ORDER BY sev_rank, est_monthly_credits_at_risk DESC NULLS LAST, check_id, object))::VARCHAR,
         severity, check_id || ' / ' || object, finding, evidence, suggested_fix_sql,
         est_monthly_credits_at_risk, 1, 0,
         -1 * (ROW_NUMBER() OVER (ORDER BY sev_rank, est_monthly_credits_at_risk DESC NULLS LAST, check_id, object))
  FROM top3
  UNION ALL
  -- all findings
  SELECT check_id, severity, object, finding, evidence, suggested_fix_sql,
         est_monthly_credits_at_risk, 2, sev_rank, COALESCE(est_monthly_credits_at_risk, -1)
  FROM ranked
  UNION ALL
  -- footer
  SELECT 'ZZ_NEXT_STEP', 'INFO', 'Snowflake Cost Audit',
         'Want the full audit with fixes and $ estimates? Snowflake Cost Audit: first audit free / money-back. Contact: https://www.linkedin.com/in/annapoorani-karthikeyan-28a2a4235/',
         'Assumptions: credit price $' || TO_VARCHAR($credit_price_usd) || '/credit, lookback ' || TO_VARCHAR($lookback_days)
           || ' days, standard-warehouse credit rates. ACCOUNT_USAGE lags 45 min to 8 h, so very recent activity is missing. Estimates are directional, not guarantees.',
         'n/a', NULL::FLOAT, 9, 0, 0
)
ORDER BY grp, sev_rank, sort_val DESC NULLS LAST;


/* ======================================================================
   OPTIONAL DETAIL QUERIES (run separately; NOT part of the scored result)
   Both are EXPERIMENTAL: written from the docs, exact columns need [VERIFY].
   ====================================================================== */

-- OPT-A: Snowflake's own per-query credit attribution (excludes idle time and
--        queries <= ~100 ms; lags up to 8 h; complete data only since mid-Aug 2024).
--        If the view is unavailable to your role, skip it: check 05 already covers this.
-- SELECT query_parameterized_hash, warehouse_name, COUNT(*) AS runs,
--        SUM(credits_attributed_compute) AS credits_compute,                      -- [VERIFY]
--        SUM(credits_used_query_acceleration) AS credits_qas
-- FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
-- GROUP BY 1, 2 ORDER BY credits_compute DESC LIMIT 10;

-- OPT-B: Snowpipe efficiency (credits per GB billed). Current Snowpipe billing is a fixed
--        credit amount per GB ingested (not per file), so credits/GB should be roughly
--        flat; compare it across pipes and over time, and look for credits with ~0 bytes
--        (maintenance/compaction charges). FILES_INSERTED is shown for context only.
-- SELECT pipe_name,
--        SUM(credits_used)                                              AS credits,
--        SUM(bytes_billed) / POWER(1024,3)                              AS gb_billed,        -- [VERIFY] BYTES_BILLED (docs list it; confirm it is populated)
--        SUM(bytes_inserted) / POWER(1024,3)                            AS gb_inserted,      -- [VERIFY]
--        SUM(credits_used) / NULLIF(SUM(bytes_billed) / POWER(1024,3), 0) AS credits_per_gb_billed,
--        SUM(files_inserted)                                            AS files             -- [VERIFY] VARIANT type per docs; may need ::NUMBER
-- FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
-- WHERE start_time >= DATEADD('day', -1 * $lookback_days, CURRENT_TIMESTAMP())
-- GROUP BY 1 ORDER BY credits DESC;

/* End of Snowflake Credit Leak Checker v1.2. Read-only: nothing was created or changed. */
