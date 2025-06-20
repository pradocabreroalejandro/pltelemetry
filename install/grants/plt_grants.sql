-- PLTelemetry Required Grants
-- This script sets up the necessary privileges for PLTelemetry operation
-- 
-- Run this as a privileged user (DBA) to grant necessary permissions
-- to the PLTelemetry installation user

PROMPT Setting up required grants for PLTelemetry...

-- Define the target user (replace with actual username)
DEFINE PLT_USER = &1

-- Validate that user was provided
DECLARE
    l_username VARCHAR2(128) := UPPER('&PLT_USER');
BEGIN
    IF l_username IS NULL OR l_username = 'UNDEFINED' THEN
        RAISE_APPLICATION_ERROR(-20001, 
            'Usage: @plt_grants.sql <username>' || CHR(10) ||
            'Example: @plt_grants.sql MYAPP_USER');
    END IF;
    
    -- Check if user exists
    DECLARE
        l_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO l_count 
        FROM DBA_USERS 
        WHERE USERNAME = l_username;
        
        IF l_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 
                'User ' || l_username || ' does not exist');
        END IF;
    END;
    
    DBMS_OUTPUT.PUT_LINE('Setting up grants for user: ' || l_username);
END;
/

-- Core Oracle packages required for PLTelemetry
PROMPT Granting access to core Oracle packages...

-- UTL_HTTP for backend communication
GRANT EXECUTE ON SYS.UTL_HTTP TO &PLT_USER;

-- DBMS_CRYPTO for ID generation
GRANT EXECUTE ON SYS.DBMS_CRYPTO TO &PLT_USER;

-- DBMS_SCHEDULER for queue processing jobs
GRANT EXECUTE ON SYS.DBMS_SCHEDULER TO &PLT_USER;

-- DBMS_APPLICATION_INFO for session context
GRANT EXECUTE ON SYS.DBMS_APPLICATION_INFO TO &PLT_USER;

-- DBMS_UTILITY for error stack formatting
GRANT EXECUTE ON SYS.DBMS_UTILITY TO &PLT_USER;

-- Database privileges
PROMPT Granting database privileges...

-- CREATE JOB for scheduler jobs
GRANT CREATE JOB TO &PLT_USER;

-- CREATE PROCEDURE for package installation
GRANT CREATE PROCEDURE TO &PLT_USER;

-- CREATE TABLE (if not already granted)
GRANT CREATE TABLE TO &PLT_USER;

-- CREATE INDEX for performance indexes
GRANT CREATE INDEX TO &PLT_USER;

-- Network access for HTTP calls
PROMPT Setting up network access...

-- Note: Network ACLs might need to be configured separately
-- This is an example - adjust host and port ranges as needed
BEGIN
    -- Check if ACL exists for PLTelemetry
    DECLARE
        l_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO l_count 
        FROM DBA_NETWORK_ACLS 
        WHERE ACL = 'pltelemetry_acl.xml';
        
        IF l_count = 0 THEN
            -- Create ACL for PLTelemetry HTTP access
            DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(
                acl         => 'pltelemetry_acl.xml',
                description => 'PLTelemetry HTTP access for telemetry export',
                principal   => UPPER('&PLT_USER'),
                is_grant    => TRUE,
                privilege   => 'connect'
            );
            
            -- Grant resolve privilege
            DBMS_NETWORK_ACL_ADMIN.ADD_PRIVILEGE(
                acl       => 'pltelemetry_acl.xml',
                principal => UPPER('&PLT_USER'),
                is_grant  => TRUE,
                privilege => 'resolve'
            );
            
            -- Assign ACL to host ranges (adjust as needed)
            -- This example allows access to common ranges - customize for your environment
            DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
                acl  => 'pltelemetry_acl.xml',
                host => '*',  -- All hosts - restrict this in production
                lower_port => 80,
                upper_port => 443
            );
            
            DBMS_OUTPUT.PUT_LINE('✓ Network ACL created for PLTelemetry');
        ELSE
            DBMS_OUTPUT.PUT_LINE('ℹ Network ACL already exists');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('⚠ Warning: Could not set up network ACL automatically');
            DBMS_OUTPUT.PUT_LINE('  You may need to configure network access manually');
            DBMS_OUTPUT.PUT_LINE('  Error: ' || SQLERRM);
    END;
END;
/

-- Verification
PROMPT Verifying grants...
DECLARE
    l_missing_grants VARCHAR2(4000) := '';
    l_count NUMBER;
BEGIN
    -- Check required object privileges
    FOR rec IN (
        SELECT 'UTL_HTTP' as obj_name FROM DUAL UNION ALL
        SELECT 'DBMS_CRYPTO' FROM DUAL UNION ALL
        SELECT 'DBMS_SCHEDULER' FROM DUAL UNION ALL
        SELECT 'DBMS_APPLICATION_INFO' FROM DUAL UNION ALL
        SELECT 'DBMS_UTILITY' FROM DUAL
    ) LOOP
        SELECT COUNT(*) INTO l_count
        FROM DBA_TAB_PRIVS
        WHERE GRANTEE = UPPER('&PLT_USER')
          AND TABLE_NAME = rec.obj_name
          AND PRIVILEGE = 'EXECUTE';
        
        IF l_count = 0 THEN
            l_missing_grants := l_missing_grants || rec.obj_name || ' ';
        END IF;
    END LOOP;
    
    -- Check system privileges
    FOR rec IN (
        SELECT 'CREATE JOB' as priv_name FROM DUAL UNION ALL
        SELECT 'CREATE PROCEDURE' FROM DUAL UNION ALL
        SELECT 'CREATE TABLE' FROM DUAL UNION ALL
        SELECT 'CREATE INDEX' FROM DUAL
    ) LOOP
        SELECT COUNT(*) INTO l_count
        FROM DBA_SYS_PRIVS
        WHERE GRANTEE = UPPER('&PLT_USER')
          AND PRIVILEGE = rec.priv_name;
        
        IF l_count = 0 THEN
            l_missing_grants := l_missing_grants || rec.priv_name || ' ';
        END IF;
    END LOOP;
    
    IF LENGTH(l_missing_grants) > 0 THEN
        RAISE_APPLICATION_ERROR(-20003, 
            'Missing required grants: ' || l_missing_grants);
    ELSE
        DBMS_OUTPUT.PUT_LINE('✓ All required grants verified successfully');
    END IF;
END;
/

PROMPT
PROMPT ================================================================================
PROMPT PLTelemetry Grants Setup Complete
PROMPT ================================================================================
PROMPT
PROMPT Grants provided to user: &PLT_USER
PROMPT
PROMPT Required privileges:
PROMPT ✓ EXECUTE on UTL_HTTP, DBMS_CRYPTO, DBMS_SCHEDULER
PROMPT ✓ CREATE JOB, CREATE PROCEDURE, CREATE TABLE, CREATE INDEX
PROMPT ✓ Network ACL for HTTP access (if possible)
PROMPT
PROMPT Note: You may need to adjust network ACL settings based on your
PROMPT       specific backend URL and security requirements.
PROMPT
PROMPT Next: Run the main installation script as user &PLT_USER
PROMPT ================================================================================