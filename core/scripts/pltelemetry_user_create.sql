-- =====================================================
-- PLTelemetry Database Setup
-- Creates user, tablespace and required grants
-- Execute as SYSDBA
-- =====================================================

-- Create tablespace for PLTelemetry
CREATE TABLESPACE PLTELEMETRY_DATA
    DATAFILE '/opt/oracle/oradata/FREE/pltelemetry_data01.dbf' SIZE 2G
    AUTOEXTEND ON 
    NEXT 200M
    MAXSIZE UNLIMITED;

-- Create PLTelemetry user
CREATE USER PLTELEMETRY 
    IDENTIFIED BY "plt"
    DEFAULT TABLESPACE PLTELEMETRY_DATA
    TEMPORARY TABLESPACE TEMP
    QUOTA UNLIMITED ON PLTELEMETRY_DATA;

-- Basic database privileges
GRANT CONNECT TO PLTELEMETRY;
GRANT RESOURCE TO PLTELEMETRY;
GRANT CREATE SESSION TO PLTELEMETRY;
GRANT CREATE TABLE TO PLTELEMETRY;
GRANT CREATE SEQUENCE TO PLTELEMETRY;
GRANT CREATE PROCEDURE TO PLTELEMETRY;
GRANT CREATE TYPE TO PLTELEMETRY;
GRANT CREATE VIEW TO PLTELEMETRY;
GRANT CREATE TRIGGER TO PLTELEMETRY;

-- PLTelemetry specific privileges
GRANT EXECUTE ON UTL_HTTP TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_UTILITY TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_SCHEDULER TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_JOB TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_RANDOM TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_LOCK TO PLTELEMETRY;

-- JSON functionality for Oracle 12c+
GRANT EXECUTE ON JSON_OBJECT_T TO PLTELEMETRY;
GRANT EXECUTE ON JSON_ARRAY_T TO PLTELEMETRY;

-- System context access for environment information
GRANT SELECT ON V_$INSTANCE TO PLTELEMETRY;
GRANT SELECT ON V_$DATABASE TO PLTELEMETRY;
GRANT SELECT ON V_$SESSION TO PLTELEMETRY;

-- Job scheduling privileges
GRANT CREATE JOB TO PLTELEMETRY;
GRANT MANAGE SCHEDULER TO PLTELEMETRY;

-- Advanced queuing (if needed for async processing)
GRANT EXECUTE ON DBMS_AQ TO PLTELEMETRY;
GRANT EXECUTE ON DBMS_AQADM TO PLTELEMETRY;

-- Network ACL for outbound HTTP connections
-- Adjust host/port according to your OTLP collector endpoints
BEGIN
    -- Create ACL for PLTelemetry HTTP access
    DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(
        acl         => 'pltelemetry_acl.xml',
        description => 'PLTelemetry HTTP access for OTLP and bridges',
        principal   => 'PLTELEMETRY',
        is_grant    => TRUE,
        privilege   => 'connect',
        start_date  => NULL,
        end_date    => NULL
    );
    
    -- Add resolve privilege for DNS lookups
    DBMS_NETWORK_ACL_ADMIN.ADD_PRIVILEGE(
        acl       => 'pltelemetry_acl.xml',
        principal => 'PLTELEMETRY',
        is_grant  => TRUE,
        privilege => 'resolve'
    );
    
    -- Assign ACL to common OTLP collector ports and hosts
    -- Tempo/Jaeger OTLP (adjust hosts as needed)
    DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
        acl        => 'pltelemetry_acl.xml',
        host       => '*',  -- Allow all hosts (adjust for security)
        lower_port => 4317, -- gRPC OTLP
        upper_port => 4318  -- HTTP OTLP
    );
    
    -- PostgreSQL bridge (if using)
    DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
        acl        => 'pltelemetry_acl.xml',
        host       => '*',
        lower_port => 5432,
        upper_port => 5432
    );
    
    -- Elasticsearch bridge (if using)
    DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
        acl        => 'pltelemetry_acl.xml',
        host       => '*',
        lower_port => 9200,
        upper_port => 9200
    );
    
    -- Common HTTP/HTTPS ports
    DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
        acl        => 'pltelemetry_acl.xml',
        host       => '*',
        lower_port => 80,
        upper_port => 80
    );
    
    DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
        acl        => 'pltelemetry_acl.xml',
        host       => '*',
        lower_port => 443,
        upper_port => 443
    );
    
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('✓ Network ACL created successfully');
    
EXCEPTION
    WHEN OTHERS THEN
        -- ACL might already exist, try to just assign privileges
        IF SQLCODE = -31021 THEN -- ACL already exists
            DBMS_OUTPUT.PUT_LINE('⚠ ACL already exists, updating privileges...');
            
            DBMS_NETWORK_ACL_ADMIN.ADD_PRIVILEGE(
                acl       => 'pltelemetry_acl.xml',
                principal => 'PLTELEMETRY',
                is_grant  => TRUE,
                privilege => 'connect'
            );
            
            DBMS_NETWORK_ACL_ADMIN.ADD_PRIVILEGE(
                acl       => 'pltelemetry_acl.xml',
                principal => 'PLTELEMETRY',
                is_grant  => TRUE,
                privilege => 'resolve'
            );
            
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('✓ Privileges updated successfully');
        ELSE
            DBMS_OUTPUT.PUT_LINE('✗ ACL creation failed: ' || SQLERRM);
            RAISE;
        END IF;
END;
/

-- Verify tablespace creation
SELECT 
    tablespace_name,
    bytes/1024/1024 as size_mb,
    autoextensible
FROM dba_data_files 
WHERE tablespace_name = 'PLTELEMETRY_DATA';

-- Verify user creation and privileges
SELECT 
    username,
    default_tablespace,
    temporary_tablespace,
    account_status
FROM dba_users 
WHERE username = 'PLTELEMETRY';

-- Show granted privileges
SELECT privilege 
FROM dba_sys_privs 
WHERE grantee = 'PLTELEMETRY'
ORDER BY privilege;

PROMPT
PROMPT =====================================================
PROMPT PLTelemetry user and tablespace created successfully
PROMPT Default password: PLTel3m3try2025!
PROMPT ⚠ CHANGE THE PASSWORD IMMEDIATELY IN PRODUCTION!
PROMPT =====================================================
PROMPT