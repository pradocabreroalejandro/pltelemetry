-- PLTelemetry Installation Script
-- Version: 0.1.0
-- 
-- This script installs PLTelemetry package and all required components
-- Run as a privileged user with necessary grants

PROMPT ================================================================================
PROMPT PLTelemetry v0.1.0 Installation
PROMPT OpenTelemetry SDK for Oracle PL/SQL
PROMPT ================================================================================

-- Set environment
SET VERIFY OFF
SET FEEDBACK OFF
SET ECHO ON
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

-- Check Oracle version compatibility
DECLARE
    l_version VARCHAR2(100);
    l_major_version NUMBER;
BEGIN
    SELECT VERSION INTO l_version FROM V$INSTANCE;
    l_major_version := TO_NUMBER(SUBSTR(l_version, 1, INSTR(l_version, '.') - 1));
    
    IF l_major_version < 12 THEN
        RAISE_APPLICATION_ERROR(-20001, 
            'PLTelemetry requires Oracle 12c or higher. Current version: ' || l_version);
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('Oracle version check passed: ' || l_version);
END;
/

-- Check required privileges
PROMPT Checking required privileges...
DECLARE
    l_count NUMBER;
BEGIN
    -- Check UTL_HTTP access
    BEGIN
        SELECT COUNT(*) INTO l_count 
        FROM USER_TAB_PRIVS 
        WHERE TABLE_NAME = 'UTL_HTTP' AND PRIVILEGE = 'EXECUTE';
        
        IF l_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 
                'Missing EXECUTE privilege on UTL_HTTP. Please grant: GRANT EXECUTE ON UTL_HTTP TO ' || USER);
        END IF;
        DBMS_OUTPUT.PUT_LINE('✓ UTL_HTTP access verified');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20002, 
                'Cannot verify UTL_HTTP access. Please ensure: GRANT EXECUTE ON UTL_HTTP TO ' || USER);
    END;
    
    
END;
/

PROMPT
PROMPT Step 1: Creating database tables...
@@tables/plt_tables.sql

PROMPT
PROMPT Step 2: Creating additional indexes...
@@tables/plt_indexes.sql

PROMPT
PROMPT Step 3: Installing PLTelemetry package specification...
@@../src/PLTelemetry.pks

PROMPT
PROMPT Step 4: Installing PLTelemetry package body...
@@../src/PLTelemetry.pkb

PROMPT
PROMPT Step 5: Setting up scheduler jobs...
@@jobs/plt_cleanup_job.sql

PROMPT
PROMPT Step 6: Verifying installation...
DECLARE
    l_count NUMBER;
    l_status VARCHAR2(10);
BEGIN
    -- Check tables
    SELECT COUNT(*) INTO l_count 
    FROM USER_TABLES 
    WHERE TABLE_NAME IN ('PLT_TRACES', 'PLT_SPANS', 'PLT_EVENTS', 'PLT_METRICS', 
                         'PLT_QUEUE', 'PLT_FAILED_EXPORTS', 'PLT_TELEMETRY_ERRORS');
    
    IF l_count != 7 THEN
        RAISE_APPLICATION_ERROR(-20004, 'Not all tables were created. Expected 7, found ' || l_count);
    END IF;
    DBMS_OUTPUT.PUT_LINE('✓ All tables created successfully');
    
    -- Check package
    SELECT COUNT(*) INTO l_count 
    FROM USER_OBJECTS 
    WHERE OBJECT_NAME = 'PLTELEMETRY' AND OBJECT_TYPE = 'PACKAGE';
    
    IF l_count = 0 THEN
        RAISE_APPLICATION_ERROR(-20005, 'PLTelemetry package not found');
    END IF;
    
    SELECT STATUS INTO l_status 
    FROM USER_OBJECTS 
    WHERE OBJECT_NAME = 'PLTELEMETRY' AND OBJECT_TYPE = 'PACKAGE BODY';
    
    IF l_status != 'VALID' THEN
        RAISE_APPLICATION_ERROR(-20006, 'PLTelemetry package body is not valid');
    END IF;
    DBMS_OUTPUT.PUT_LINE('✓ PLTelemetry package installed and valid');
    
    -- Check jobs
    SELECT COUNT(*) INTO l_count 
    FROM USER_SCHEDULER_JOBS 
    WHERE JOB_NAME IN ('PLT_QUEUE_CLEANUP');
    
    IF l_count != 2 THEN
        DBMS_OUTPUT.PUT_LINE('⚠ Warning: Expected 2 scheduler jobs, found ' || l_count);
    ELSE
        DBMS_OUTPUT.PUT_LINE('✓ Scheduler jobs created successfully');
    END IF;
END;
/

PROMPT
PROMPT ================================================================================
PROMPT PLTelemetry Installation Completed Successfully!
PROMPT ================================================================================
PROMPT
PROMPT Next Steps:
PROMPT 1. Configure your backend URL:
PROMPT    PLTelemetry.set_backend_url('https://your-backend.com/api/telemetry');
PROMPT
PROMPT 2. Set your API key:
PROMPT    PLTelemetry.set_api_key('your-secret-api-key');
PROMPT
PROMPT 3. Enable async mode (recommended):
PROMPT    PLTelemetry.set_async_mode(TRUE);
PROMPT
PROMPT 4. Test the installation:
PROMPT    @@../examples/basic_usage.sql
PROMPT
PROMPT Documentation: https://github.com/pradocabreroalejandro/pltelemetry
PROMPT
PROMPT ================================================================================

-- Reset environment
SET VERIFY ON
SET FEEDBACK ON
SET ECHO OFF