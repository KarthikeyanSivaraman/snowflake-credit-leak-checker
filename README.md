# Snowflake Credit Leak Checker (v1.2)

One read-only SQL script that scans your Snowflake account for the usual places credits leak, and returns a single scored list: what is wrong, the evidence, a suggested fix (as text), and a rough credit / dollar impact.

> Status: v1.2, tested end to end on a live Snowflake trial account (see "Tested on"). Checks marked experimental are heuristics; some SHOW/column formats are tagged `-- [VERIFY]` in the SQL.

## What it does

- Reads `SNOWFLAKE.ACCOUNT_USAGE` views plus `SHOW WAREHOUSES` / `SHOW RESOURCE MONITORS` / `SHOW SERVICES IN ACCOUNT`.
- Runs 10 checks (01-09 and 11) and a summary, then returns one result set sorted HIGH -> MED -> LOW, with a summary of credits by warehouse and serverless service at the top and your top 3 findings under it.
- Every finding has: `check_id, severity, object, finding, evidence, suggested_fix_sql, est_monthly_credits_at_risk` (plus `est_monthly_usd_at_risk` using your credit price).

## What it does NOT do

- **It is strictly read-only.** Only `SELECT`, `SHOW`, `SET` (session variables), and an optional `USE ROLE`. No `CREATE`, `ALTER`, `DROP`, no `PUT`, no stages, no temp tables.
- **No data leaves your account.** The script has no external calls, no network access, no file output. Results appear in your own worksheet.
- It never executes the suggested fixes. `suggested_fix_sql` is text for you to review.
- It does not read your table data, only usage and metadata views. (Query text snippets are hidden by default; see `show_query_text`.)
- Estimates are directional, not guarantees.

## Required role / privileges

Run as `ACCOUNTADMIN`, or as a role with `IMPORTED PRIVILEGES` on the `SNOWFLAKE` database plus visibility of your warehouses and resource monitors (`MONITOR USAGE` on the account, or `MONITOR`/ownership on each). A least-privilege role is provided as an optional, separate file: [`optional_least_privilege_role.sql`](optional_least_privilege_role.sql). You also need a warehouse to run on; an X-Small is enough and the script takes seconds.

## How to run

1. In Snowsight, open a new SQL worksheet and paste the **whole** of [`credit_leak_checker.sql`](credit_leak_checker.sql).
2. Edit the **PARAMETERS** block at the top. At minimum set `credit_price_usd` to **your contract price** (3.0 is a placeholder; the script never assumes a price silently and prints the one it used).
3. Pick a warehouse, click the arrow next to Run, choose **Run All**. The **last** result is the report (the scored list); earlier results are the individual checks.

Running a single check: Snowsight's Run All appears to use its own session, so variables it sets are not visible to statements you run afterwards. To run one check on its own, first run section 0's `SHOW` / `SET` statements **one by one in the same session** (each `SHOW ...;` followed by its `SET q_xx = LAST_QUERY_ID();`), then run just that check.

**No privilege to `SHOW SERVICES IN ACCOUNT`?** Check 11 is isolated for this. Its `SHOW` sits in section 0 because a failing `SHOW` stops Run All. Comment out the three spots marked `CHECK 11` (the `SHOW SERVICES` + `SET q_svc` lines in section 0, the check 11 block, and the `q_c11` line in the final `UNION`) and the other checks run unchanged. The role needs OWNERSHIP, USAGE, MONITOR or OPERATE on the services to see them (ACCOUNTADMIN works).

ACCOUNT_USAGE has latency (45 minutes for QUERY_HISTORY, up to 3 hours for metering and load views, up to 8 hours for QUERY_ATTRIBUTION_HISTORY per the Snowflake docs), so very recent activity will not appear yet.

## How to read the results

| Column | Meaning |
|---|---|
| `check_id` | Which check fired (see list below). `10_SUMMARY` = credit totals, `10_TOP3_#n` = the three findings to fix first |
| `severity` | HIGH = likely material waste or no guardrail; MED = worth fixing; LOW = tidy-up or informational; INFO = totals |
| `object` | Warehouse, query pattern, table, or service |
| `evidence` | The numbers behind the finding |
| `suggested_fix_sql` | Text only. Review it, adapt it, run it yourself if you agree |
| `est_monthly_credits_at_risk` | Rough monthly credits. Empty = not applicable (e.g. a missing guardrail, or storage which is billed in $, not credits) |
| `est_monthly_usd_at_risk` | The above times `credit_price_usd` |

If a check finds nothing it simply does not appear. A clean (or nearly empty) account returning few rows is a normal result. "At risk" for check 05 means the estimated cost of that query pattern, not a promised saving.

## The checks

| ID | What | Notes |
|---|---|---|
| 01 | Warehouses with AUTO_SUSPEND > 300 s, NULL, or 0 | SHOW WAREHOUSES |
| 02A | AUTO_RESUME disabled | Hygiene, not a direct leak |
| 02B | Oversized warehouse candidates (MEDIUM+ running small queries, no queuing) | **Experimental** |
| 03 | Idle burn: credits billed in hours with no queries (lookback window) | WAREHOUSE_METERING_HISTORY vs QUERY_HISTORY |
| 04 | Warehouses without a resource monitor and no account-level monitor; notify-only or unassigned monitors | |
| 05 | Top 10 most expensive query patterns (estimated) | 05B repeat-run queries is **experimental** |
| 06 | Heavy remote spilling | Fix is warehouse sizing or the query |
| 07 | Serverless spend: Snowpipe, tasks, auto-clustering, materialized views, search optimization, etc. | Resource monitors do not cap these |
| 08 | Storage waste: Time Travel/Fail-safe heavy tables, dropped tables still stored, clone-retained bytes, staging-looking permanent tables (08D **experimental**) | Time Travel > 1 day needs Enterprise |
| 09 | Cloud services billed above the 10% daily allowance (hidden if it rounds to < 0.01 credits) | METERING_DAILY_HISTORY |
| 10 | Summary: credits by warehouse + serverless, top 3 findings | |
| 11 | Container services (Notebooks, Streamlit, user services): RUNNING, never/long auto-suspend | SHOW SERVICES + METERING_HISTORY. **Resource monitors do not cover this spend.** New in v1.1 |

## Parameters

`credit_price_usd` (set your price), `lookback_days` (default 30), `autosuspend_max_sec` (300), `spill_min_gb` (1), `storage_min_gb` (1), `repeat_min_runs` (20), `storage_price_usd_per_tb_month` (0 = off), `show_query_text` (0 = hide query text, safer when sharing results), plus the v1.2 severity knobs: `min_monthly_credits_med` (1), `min_monthly_credits_high` (5), `share_med_05` (0.10), `share_high_05` (0.20), `share_med_svc` (0.20), `share_high_svc` (0.50), `pattern_min_credits` (0.01). A finding needs both enough share of spend and enough absolute monthly credits to rank above LOW.

## Known limitations

- Snowflake-managed objects (`SYSTEM$*` warehouses, `COMPUTE_SERVICE_WH_*` pools) are labelled "(Snowflake-managed)" and capped at LOW so they do not crowd out your own issues. `COMPUTE_SERVICE_WH_*` is not priced at warehouse rates in check 05 (it is container-runtime compute, counted in checks 07 / 11).
- Check 11 credits are metered per compute pool, so the per-service figure is the pool's credits split across its running services: directional only. It can also appear next to the same spend in check 07.
- `ALTER SERVICE ... SUSPEND` fails on Notebook/Streamlit-managed services even for ACCOUNTADMIN (needs OPERATE on the managed service); the fix text tells you to stop the notebook session or delete the Streamlit app in Snowsight. `AUTO_SUSPEND_SECS` on services is a preview feature per the docs.
- Credit rates assume standard warehouses (X-Small = 1 credit/hour, doubling per size). Snowpark-optimized and newer warehouse generations bill differently; multi-cluster warehouses bill per running cluster.
- Per-query credit figures are estimates (execution time x size rate); concurrent queries share one warehouse's billing, so patterns can be over-counted.
- Check 03 joins hourly metering rows to queries; on very busy accounts shorten `lookback_days`.
- ACCOUNT_USAGE latency means the last few hours are missing; brand new warehouses/tables may not appear yet.
- Storage checks report bytes (and $ if you set a storage price); Fail-safe cannot be shortened on permanent tables, only avoided by using transient tables.
- Not covered in v1: data transfer/egress, Cortex/AI function spend beyond the service-type rollup in 07, Iceberg/external tables, org-level (multi-account) views, tag- or budget-based attribution.
- Some column names and SHOW output formats are tagged `-- [VERIFY]` in the SQL because they were written from the docs, not tested live.

## Want the full audit?

A **Snowflake Cost Audit** is available: read-only (nothing in your account is changed), a short report with prioritized fixes and $ estimates in 5 business days, and **if nothing worth fixing is found, you don't pay**. A few audits are being done as case studies, and the first one is free.

Contact: https://www.linkedin.com/in/annapoorani-karthikeyan-28a2a4235/

## License

MIT, see [LICENSE](LICENSE). Provided as-is with no warranty; estimates are directional, not guarantees.

## Tested on

- Snowflake trial account, AWS_US_EAST_2, role ACCOUNTADMIN, 2026-10-09
- v1.2 full Run All passed end to end; the scored list renders as the last result
- It found a real leak on the test account itself: **container services (a Notebook set to never auto-suspend, and a Streamlit app with a 3-day auto-suspend) were 79% of all credits over 30 days**. Resource monitors did not cover this spend, and even ACCOUNTADMIN could not suspend the managed service directly (the Streamlit app had to be deleted). That finding became check 11.
- Bugs found and fixed during testing: resource-monitor thresholds come back as `'100%'` strings (false "notify-only" alarm); severity ranking now needs both share of spend and an absolute credit amount, so tiny patterns no longer rank and dominant spend surfaces first.

Found something it misses, or a column that differs on your edition? Open an issue.
