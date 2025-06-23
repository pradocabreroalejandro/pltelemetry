-- ============================================
-- PLT_POSTGRES_BRIDGE Installation Script
-- Version: 1.0
-- ============================================

-- This script installs the PostgreSQL bridge for PLTelemetry
-- Prerequisites:
--   1. PLTelemetry core package must be installed first
--   2. User must have CREATE PROCEDURE privilege
--   3. EXECUTE privilege on UTL_HTTP package

SET SERVEROUTPUT ON
SET VERIFY OFF
SET FEEDBACK ON

PROMPT
PROMPT ============================================
PROMPT PLT_POSTGRES_BRIDGE Installation
PROMPT ============================================
PROMPT

-- Check prerequisites
DECLARE
    l_count NUMBER;
    l_errors NUMBER := 0;
BEGIN
    -- Check if PLTelemetry exists
    SELECT COUNT(*)
    INTO l_count
    FROM user_objects
    WHERE object_name = 'PLTELEMETRY'
    AND object_type = 'PACKAGE';
    
    IF l_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: PLTelemetry package not found!');
        DBMS_OUTPUT.PUT_LINE('Please install PLTelemetry core first.');
        l_errors := l_errors + 1;
    ELSE
        DBMS_OUTPUT.PUT_LINE('✓ PLTelemetry package found');
    END IF;
    
    -- Check UTL_HTTP privilege
    BEGIN
        IF UTL_HTTP.REQUEST('http://127.0.0.1:1') IS NULL THEN
            NULL; -- Won't reach here, but syntax is valid
        END IF;
        DBMS_OUTPUT.PUT_LINE('✓ UTL_HTTP access confirmed');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -29273 THEN
                DBMS_OUTPUT.PUT_LINE('ERROR: No privilege to execute UTL_HTTP!');
                DBMS_OUTPUT.PUT_LINE('Ask your DBA to run:');
                DBMS_OUTPUT.PUT_LINE('  GRANT EXECUTE ON UTL_HTTP TO ' || USER || ';');
                l_errors := l_errors + 1;
            ELSE
                -- Other errors are OK (connection refused, etc)
                DBMS_OUTPUT.PUT_LINE('✓ UTL_HTTP access confirmed');
            END IF;
    END;
    
    -- Check if bridge already exists
    SELECT COUNT(*)
    INTO l_count
    FROM user_objects
    WHERE object_name = 'PLT_POSTGRES_BRIDGE'
    AND object_type IN ('PACKAGE', 'PACKAGE BODY');
    
    IF l_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('WARNING: PLT_POSTGRES_BRIDGE already exists');
        DBMS_OUTPUT.PUT_LINE('It will be replaced with the new version');
    END IF;
    
    IF l_errors > 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Prerequisites check failed. Installation aborted.');
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Prerequisites check passed. Proceeding with installation...');
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- Create helper function for JSON escaping
PROMPT Creating helper function escape_json_string...

CREATE OR REPLACE FUNCTION escape_json_string(p_input VARCHAR2)
RETURN VARCHAR2
IS
    l_output VARCHAR2(4000);
BEGIN
    IF p_input IS NULL THEN
        RETURN NULL;
    END IF;
    
    l_output := p_input;
    
    -- Escape in correct order (backslash first!)
    l_output := REPLACE(l_output, '\', '\\');    -- Backslash
    l_output := REPLACE(l_output, '"', '\"');    -- Quotes
    l_output := REPLACE(l_output, CHR(10), '\n'); -- Newline
    l_output := REPLACE(l_output, CHR(13), '\r'); -- Carriage return
    l_output := REPLACE(l_output, CHR(9), '\t');  -- Tab
    l_output := REPLACE(l_output, CHR(8), '\b');  -- Backspace
    l_output := REPLACE(l_output, CHR(12), '\f'); -- Form feed
    
    RETURN l_output;
END escape_json_string;
/

SHOW ERRORS

-- Install package specification
PROMPT Creating PLT_POSTGRES_BRIDGE package specification...

@@PLT_POSTGRES_BRIDGE.pks

SHOW ERRORS

-- Install package body
PROMPT Creating PLT_POSTGRES_BRIDGE package body...

@@PLT_POSTGRES_BRIDGE.pkb

SHOW ERRORS

-- Verify installation
PROMPT
PROMPT Verifying installation...

DECLARE
    l_count NUMBER;
    l_status VARCHAR2(20);
BEGIN
    -- Check package
    SELECT COUNT(*), MAX(status)
    INTO l_count, l_status
    FROM user_objects
    WHERE object_name = 'PLT_POSTGRES_BRIDGE'
    AND object_type IN ('PACKAGE', 'PACKAGE BODY');
    
    IF l_count = 2 AND l_status = 'VALID' THEN
        DBMS_OUTPUT.PUT_LINE('✓ PLT_POSTGRES_BRIDGE package installed successfully');
    ELSE
        DBMS_OUTPUT.PUT_LINE('✗ PLT_POSTGRES_BRIDGE package installation failed');
        DBMS_OUTPUT.PUT_LINE('  Objects found: ' || l_count);
        DBMS_OUTPUT.PUT_LINE('  Status: ' || l_status);
    END IF;
    
    -- Check helper function
    SELECT COUNT(*), MAX(status)
    INTO l_count, l_status
    FROM user_objects
    WHERE object_name = 'ESCAPE_JSON_STRING'
    AND object_type = 'FUNCTION';
    
    IF l_count = 1 AND l_status = 'VALID' THEN
        DBMS_OUTPUT.PUT_LINE('✓ Helper function escape_json_string installed successfully');
    ELSE
        DBMS_OUTPUT.PUT_LINE('✗ Helper function installation failed');
    END IF;
END;
/

-- Create synonyms (optional)
PROMPT
PROMPT Creating public synonyms (optional - requires DBA privilege)...

BEGIN
    EXECUTE IMMEDIATE 'CREATE PUBLIC SYNONYM PLT_POSTGRES_BRIDGE FOR PLT_POSTGRES_BRIDGE';
    DBMS_OUTPUT.PUT_LINE('✓ Public synonym created');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1031 THEN
            DBMS_OUTPUT.PUT_LINE('ℹ Skipping public synonym (requires DBA privilege)');
        ELSE
            DBMS_OUTPUT.PUT_LINE('ℹ Skipping public synonym: ' || SQLERRM);
        END IF;
END;
/

-- Configuration test
PROMPT
PROMPT ============================================
PROMPT Testing basic configuration...
PROMPT ============================================

DECLARE
    l_test_json VARCHAR2(200);
    l_escaped VARCHAR2(200);
BEGIN
    -- Test JSON escaping
    l_test_json := 'Test\with"special';
    l_escaped := escape_json_string(l_test_json);
    
    IF l_escaped = 'Test\\with\"special' THEN
        DBMS_OUTPUT.PUT_LINE('✓ JSON escaping works correctly');
    ELSE
        DBMS_OUTPUT.PUT_LINE('✗ JSON escaping failed');
        DBMS_OUTPUT.PUT_LINE('  Input: ' || l_test_json);
        DBMS_OUTPUT.PUT_LINE('  Output: ' || l_escaped);
    END IF;
    
    -- Test basic configuration
    PLT_POSTGRES_BRIDGE.set_postgrest_url('http://localhost:3000');
    PLT_POSTGRES_BRIDGE.set_timeout(30);
    
    DBMS_OUTPUT.PUT_LINE('✓ Configuration methods work correctly');
    
    -- Test JSON parsing
    DECLARE
        l_json VARCHAR2(200) := '{"name":"test","value":123.45,"unit":"ms"}';
        l_name VARCHAR2(100);
        l_value VARCHAR2(100);
    BEGIN
        l_name := PLT_POSTGRES_BRIDGE.get_json_value(l_json, 'name');
        l_value := PLT_POSTGRES_BRIDGE.get_json_value(l_json, 'value');
        
        IF l_name = 'test' AND l_value = '123.45' THEN
            DBMS_OUTPUT.PUT_LINE('✓ JSON parsing works correctly');
        ELSE
            DBMS_OUTPUT.PUT_LINE('✗ JSON parsing failed');
        END IF;
    END;
END;
/

-- Usage instructions
PROMPT
PROMPT ============================================
PROMPT Installation Complete!
PROMPT ============================================
PROMPT
PROMPT Next steps:
PROMPT
PROMPT 1. Configure PLTelemetry to use the bridge:
PROMPT    BEGIN
PROMPT        PLTelemetry.set_backend_url('POSTGRES_BRIDGE');
PROMPT        PLT_POSTGRES_BRIDGE.set_postgrest_url('http://your-server:3000');
PROMPT    END;
PROMPT
PROMPT 2. Test the connection:
PROMPT    See examples/basic_integration.sql
PROMPT
PROMPT 3. For async mode, set up the processing job:
PROMPT    See examples/job_setup.sql
PROMPT
PROMPT Documentation: https://github.com/yourusername/pltelemetry
PROMPT
PROMPT ============================================

-- Grant execute permissions (optional)
PROMPT
PROMPT To grant access to other users:
PROMPT   GRANT EXECUTE ON PLT_POSTGRES_BRIDGE TO username;
PROMPT   GRANT EXECUTE ON escape_json_string TO username;
PROMPT

-- Summary
SELECT 
    object_name,
    object_type,
    status,
    created,
    last_ddl_time
FROM user_objects
WHERE object_name IN ('PLT_POSTGRES_BRIDGE', 'ESCAPE_JSON_STRING')
ORDER BY object_name, object_type;

-- End of installation
PROMPT
PROMPT Installation script completed.
PROMPT