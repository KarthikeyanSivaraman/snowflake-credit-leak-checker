/* =============================================================================
   OPTIONAL: least-privilege role for the Credit Leak Checker
   -----------------------------------------------------------------------------
   You do NOT need this file. Running credit_leak_checker.sql as ACCOUNTADMIN works.
   Use it only if your security team prefers a dedicated read-only role.

   This file DOES create objects (a role) and grant privileges, unlike the checker
   itself. Run it as ACCOUNTADMIN, review every line first, and use the cleanup
   block at the bottom to remove it afterwards.

   What the role can do: read SNOWFLAKE.ACCOUNT_USAGE views (usage + metadata
   only, never your table data), see warehouses / resource monitors via MONITOR,
   and use one warehouse to run the queries.
   What it cannot do: read any table data, modify or operate anything.

   Replace <YOUR_WAREHOUSE> and <YOUR_USER> before running.
   [VERIFY] Not yet tested. Check the SHOW commands at the end return rows.
   ============================================================================= */

USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS CREDIT_LEAK_CHECKER_ROLE
  COMMENT = 'Read-only role for the Snowflake Credit Leak Checker. Safe to drop.';

-- Option 1 (broad, simple): read all ACCOUNT_USAGE / ORGANIZATION-free metadata views.
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE CREDIT_LEAK_CHECKER_ROLE;

-- Option 2 (narrower, newer): grant only the SNOWFLAKE database roles the checker needs
-- instead of Option 1. USAGE_VIEWER covers cost views (metering, warehouse load, storage);
-- QUERY_HISTORY / TABLES-type metadata views come from the GOVERNANCE_VIEWER / SECURITY_VIEWER
-- database roles. [VERIFY] which database roles cover QUERY_HISTORY and TABLES in your account.
-- If you prefer this, comment out Option 1 above and use:
-- GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER      TO ROLE CREDIT_LEAK_CHECKER_ROLE;
-- GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE CREDIT_LEAK_CHECKER_ROLE;

-- Let SHOW WAREHOUSES / SHOW RESOURCE MONITORS return every object (ownership not required).
GRANT MONITOR USAGE ON ACCOUNT TO ROLE CREDIT_LEAK_CHECKER_ROLE;    -- [VERIFY] should expose all warehouses + resource monitors to SHOW

-- A warehouse to run the checker on (an X-Small is enough). USAGE only, no OPERATE.
GRANT USAGE ON WAREHOUSE <YOUR_WAREHOUSE> TO ROLE CREDIT_LEAK_CHECKER_ROLE;
-- SHOW WAREHOUSES only lists warehouses the role has some privilege on; to see ALL warehouses
-- also grant MONITOR on each one (repeat per warehouse):
-- GRANT MONITOR ON WAREHOUSE <OTHER_WAREHOUSE> TO ROLE CREDIT_LEAK_CHECKER_ROLE;

GRANT ROLE CREDIT_LEAK_CHECKER_ROLE TO USER <YOUR_USER>;

-- Sanity check (as the new role):
-- USE ROLE CREDIT_LEAK_CHECKER_ROLE;
-- SHOW WAREHOUSES;
-- SHOW RESOURCE MONITORS;
-- SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY;
-- SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS;

/* ----------------------------- CLEANUP (uncomment) ------------------------- */
-- USE ROLE ACCOUNTADMIN;
-- DROP ROLE IF EXISTS CREDIT_LEAK_CHECKER_ROLE;
