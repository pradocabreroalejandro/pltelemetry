-- =============================================================================
-- PLT_DB_MONITOR - Direct Grants for PDB Environment
-- ⚠️  IMPORTANT: Run this as SYS AFTER connecting to the correct PDB!
-- =============================================================================

PROMPT Checking current container...
SELECT SYS_CONTEXT('USERENV', 'CON_NAME') as current_container FROM DUAL;

PROMPT
PROMPT ⚠️  If you see CDB$ROOT above, you need to:
PROMPT 1. SHOW PDBS;
PROMPT 2. ALTER SESSION SET CONTAINER = your_pdb_name;
PROMPT 3. Then run this script again
PROMPT

PROMPT Granting privileges directly to PLTELEMETRY in current PDB...

-- =============================================================================
-- Dictionary Views Access
-- =============================================================================

GRANT SELECT ON v_$database TO PLTELEMETRY;
GRANT SELECT ON v_$instance TO PLTELEMETRY;
GRANT SELECT ON v_$session TO PLTELEMETRY;
GRANT SELECT ON v_$sysmetric TO PLTELEMETRY;
GRANT SELECT ON v_$osstat TO PLTELEMETRY;
GRANT SELECT ON v_$sgainfo TO PLTELEMETRY;
GRANT SELECT ON v_$sgastat TO PLTELEMETRY;
GRANT SELECT ON v_$pgastat TO PLTELEMETRY;
GRANT SELECT ON v_$sga TO PLTELEMETRY;
GRANT SELECT ON dba_tablespaces TO PLTELEMETRY;
GRANT SELECT ON dba_data_files TO PLTELEMETRY;
GRANT SELECT ON dba_temp_files TO PLTELEMETRY;
GRANT SELECT ON dba_free_space TO PLTELEMETRY;
GRANT SELECT ON dba_objects TO PLTELEMETRY;
GRANT SELECT ON dba_users TO PLTELEMETRY;
GRANT SELECT ON dba_segments TO PLTELEMETRY;
GRANT SELECT ON dba_scheduler_jobs TO PLTELEMETRY;
GRANT SELECT ON dba_scheduler_job_run_details TO PLTELEMETRY;
GRANT SELECT ON dba_scheduler_running_jobs TO PLTELEMETRY;
GRANT SELECT ON v_$active_session_history TO PLTELEMETRY;
GRANT SELECT ON v_$waitstat TO PLTELEMETRY;
GRANT SELECT ON v_$system_event TO PLTELEMETRY;

-- =============================================================================
-- Execute Privileges
-- =============================================================================

GRANT EXECUTE ON UTL_HTTP TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_CRYPTO TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_LOB TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_RANDOM TO PLTELEMETRY;

-- =============================================================================
-- System Privileges
-- =============================================================================

GRANT CREATE JOB TO PLTELEMETRY;
GRANT MANAGE SCHEDULER TO PLTELEMETRY;

-- =============================================================================
-- Network ACL (skip if fails)
-- =============================================================================

BEGIN
  DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(
    acl         => 'pltelemetry_monitoring_acl.xml',
    description => 'PLTelemetry Database Monitoring ACL',
    principal   => 'PLTELEMETRY',
    is_grant    => TRUE,
    privilege   => 'connect'
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl  => 'pltelemetry_monitoring_acl.xml',
    host => 'plt-otel-collector'
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl  => 'pltelemetry_monitoring_acl.xml',
    host => 'localhost'
  );
  
  DBMS_OUTPUT.PUT_LINE('✅ Network ACL created successfully');
  COMMIT;
  
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('⚠️  ACL creation failed (may already exist): ' || SQLERRM);
END;
/

-- =============================================================================
-- Test Access
-- =============================================================================

PROMPT Testing access as PLTELEMETRY...

-- Switch to PLTELEMETRY user for testing
CONNECT PLTELEMETRY/your_password@your_service

-- Quick tests
DECLARE
  l_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM v$database;
  DBMS_OUTPUT.PUT_LINE('✅ v$database access: OK (' || l_count || ' rows)');
  
  SELECT COUNT(*) INTO l_count FROM v$session WHERE ROWNUM <= 1;
  DBMS_OUTPUT.PUT_LINE('✅ v$session access: OK');
  
  SELECT COUNT(*) INTO l_count FROM dba_tablespaces;
  DBMS_OUTPUT.PUT_LINE('✅ dba_tablespaces access: OK (' || l_count || ' rows)');
  
  SELECT COUNT(*) INTO l_count FROM dba_objects WHERE ROWNUM <= 1;
  DBMS_OUTPUT.PUT_LINE('✅ dba_objects access: OK');
  
  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('🎉 All critical views accessible!');
  
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('❌ Access test failed: ' || SQLERRM);
END;
/

PROMPT
PROMPT =============================================================================
PROMPT Manual Grant Verification
PROMPT =============================================================================
PROMPT
PROMPT If the above failed, try these manual grants as SYS:
PROMPT
PROMPT -- Core views
PROMPT GRANT SELECT ON sys.v_$database TO PLTELEMETRY;
PROMPT GRANT SELECT ON sys.v_$session TO PLTELEMETRY;
PROMPT GRANT SELECT ON sys.dba_tablespaces TO PLTELEMETRY;
PROMPT GRANT SELECT ON sys.dba_free_space TO PLTELEMETRY;
PROMPT GRANT SELECT ON sys.dba_objects TO PLTELEMETRY;
PROMPT GRANT SELECT ON sys.dba_scheduler_jobs TO PLTELEMETRY;
PROMPT GRANT SELECT ON sys.dba_scheduler_job_run_details TO PLTELEMETRY;
PROMPT
PROMPT -- Execute privileges  
PROMPT GRANT EXECUTE ON sys.utl_http TO PLTELEMETRY;
PROMPT GRANT EXECUTE ON sys.dbms_crypto TO PLTELEMETRY;
PROMPT
PROMPT =============================================================================


GRANT SELECT ON v_$database TO PLTELEMETRY;
GRANT SELECT ON v_$session TO PLTELEMETRY;
GRANT SELECT ON v_$sysmetric TO PLTELEMETRY;
GRANT SELECT ON v_$sgainfo TO PLTELEMETRY;
GRANT SELECT ON v_$pgastat TO PLTELEMETRY;
GRANT SELECT ON v_$osstat TO PLTELEMETRY;
GRANT SELECT ON dba_tablespaces TO PLTELEMETRY;
GRANT SELECT ON dba_data_files TO PLTELEMETRY;
GRANT SELECT ON dba_free_space TO PLTELEMETRY;
GRANT SELECT ON dba_objects TO PLTELEMETRY;
GRANT SELECT ON dba_scheduler_jobs TO PLTELEMETRY;
GRANT SELECT ON dba_scheduler_job_run_details TO PLTELEMETRY;
GRANT EXECUTE ON UTL_HTTP TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_CRYPTO TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_LOB TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_RANDOM TO PLTELEMETRY;
GRANT CREATE JOB TO PLTELEMETRY;