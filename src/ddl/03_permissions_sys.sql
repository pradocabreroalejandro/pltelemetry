-- =============================================================================
-- 03_permissions_sys.sql
-- System Permissions (Run as SYS / SYSDBA)
-- =============================================================================
-- NOTE: Adjust 'PLTELEMETRY' to the actual name of your user/schema.

-- 1. PERFORMANCE VIEWS
GRANT SELECT ON V_$SYSMETRIC TO PLTELEMETRY;
GRANT SELECT ON V_$SESSION TO PLTELEMETRY;
GRANT SELECT ON V_$RESOURCE_LIMIT TO PLTELEMETRY;
GRANT SELECT ON DBA_TABLESPACE_USAGE_METRICS TO PLTELEMETRY;
GRANT SELECT ON V_$SYSSTAT TO PLTELEMETRY;
GRANT SELECT ON V_$OSSTAT TO PLTELEMETRY;
GRANT SELECT ON V_$PROCESS TO PLTELEMETRY;
-- Optional but useful for metadata
GRANT SELECT ON V_$INSTANCE TO PLTELEMETRY;
GRANT CREATE JOB TO pltelemetry;
-- So it can kill them if they go crazy
GRANT MANAGE SCHEDULER TO pltelemetry;
GRANT CREATE SYNONYM TO PLTELEMETRY;
-- Optional, but helps if CREATE OR REPLACE fails
GRANT DROP ANY SYNONYM TO PLTELEMETRY;

-- 2. ACLs FOR UTL_HTTP (Needed for the PL/SQL Bridge)
BEGIN
  -- Note: In Oracle 12c+ using APPEND_HOST_ACE is the norm.
  -- Make sure the PLTELEMETRY user exists before running this.
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*', -- In prod, restrict this to the Collector's IP
    ace  => xs$ace_type(
        privilege_list => xs$name_list('connect', 'resolve'),
        principal_name => 'PLTELEMETRY'
    )
  );
END;
/

PROMPT ✅ Permissions assigned.
