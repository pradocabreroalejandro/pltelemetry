-- =====================================================
-- ACL Verification Script for PLTelemetry
-- Run as PLTELEMETRY user or SYSDBA
-- =====================================================

-- 1. Check if ACL exists and user has privileges
SELECT 
    acl,
    principal,
    privilege,
    is_grant
FROM dba_network_acl_privileges 
WHERE acl = 'pltelemetry_acl.xml'
AND principal = 'PLTELEMETRY'
ORDER BY privilege;

-- 2. Check ACL assignments (hosts and ports)
SELECT 
    acl,
    host,
    lower_port,
    upper_port
FROM dba_network_acls 
WHERE acl = 'pltelemetry_acl.xml'
ORDER BY host, lower_port;

-- 3. Test HTTP connectivity to common endpoints
-- Run as PLTELEMETRY user
SET SERVEROUTPUT ON

DECLARE
    l_request   UTL_HTTP.REQ;
    l_response  UTL_HTTP.RESP;
    l_value     VARCHAR2(32767);
    l_result    VARCHAR2(100);
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Testing HTTP Connectivity ===');
    
    -- Test 1: Basic HTTP (Google)
    BEGIN
        l_request := UTL_HTTP.BEGIN_REQUEST('http://www.google.com');
        UTL_HTTP.SET_HEADER(l_request, 'User-Agent', 'PLTelemetry-Test/1.0');
        UTL_HTTP.SET_HEADER(l_request, 'Connection', 'close');
        l_response := UTL_HTTP.GET_RESPONSE(l_request);
        
        IF l_response.status_code = 200 THEN
            l_result := '✓ SUCCESS';
        ELSE
            l_result := '⚠ HTTP ' || l_response.status_code;
        END IF;
        
        UTL_HTTP.END_RESPONSE(l_response);
        
    EXCEPTION
        WHEN OTHERS THEN
            l_result := '✗ FAILED: ' || SUBSTR(SQLERRM, 1, 50);
            BEGIN
                UTL_HTTP.END_RESPONSE(l_response);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
    END;
    
    DBMS_OUTPUT.PUT_LINE('HTTP (port 80):      ' || l_result);
    
    -- Test 2: HTTPS (Google)
    BEGIN
        UTL_HTTP.SET_WALLET('file:/path/to/wallet', 'wallet_password'); -- Adjust if needed
        l_request := UTL_HTTP.BEGIN_REQUEST('https://www.google.com');
        UTL_HTTP.SET_HEADER(l_request, 'User-Agent', 'PLTelemetry-Test/1.0');
        UTL_HTTP.SET_HEADER(l_request, 'Connection', 'close');
        l_response := UTL_HTTP.GET_RESPONSE(l_request);
        
        IF l_response.status_code = 200 THEN
            l_result := '✓ SUCCESS';
        ELSE
            l_result := '⚠ HTTP ' || l_response.status_code;
        END IF;
        
        UTL_HTTP.END_RESPONSE(l_response);
        
    EXCEPTION
        WHEN OTHERS THEN
            l_result := '✗ FAILED: ' || SUBSTR(SQLERRM, 1, 50);
            IF SQLCODE = -29024 THEN
                l_result := '⚠ WALLET NOT CONFIGURED';
            END IF;
            BEGIN
                UTL_HTTP.END_RESPONSE(l_response);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
    END;
    
    DBMS_OUTPUT.PUT_LINE('HTTPS (port 443):    ' || l_result);
    
    -- Test 3: OTLP HTTP port (will fail but should show connection attempt)
    BEGIN
        l_request := UTL_HTTP.BEGIN_REQUEST('http://localhost:4318/v1/traces');
        UTL_HTTP.SET_HEADER(l_request, 'Content-Type', 'application/json');
        UTL_HTTP.SET_HEADER(l_request, 'Connection', 'close');
        l_response := UTL_HTTP.GET_RESPONSE(l_request);
        l_result := '✓ Connected (HTTP ' || l_response.status_code || ')';
        UTL_HTTP.END_RESPONSE(l_response);
        
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -12541 OR SQLCODE = -12545 THEN
                l_result := '✓ ACL OK (No listener on localhost:4318)';
            ELSIF SQLCODE = -24247 THEN
                l_result := '✗ ACL DENIED';
            ELSE
                l_result := '? ' || SUBSTR(SQLERRM, 1, 40);
            END IF;
    END;
    
    DBMS_OUTPUT.PUT_LINE('OTLP HTTP (4318):    ' || l_result);
    
    -- Test 4: PostgreSQL port
    BEGIN
        l_request := UTL_HTTP.BEGIN_REQUEST('http://localhost:5432');
        l_response := UTL_HTTP.GET_RESPONSE(l_request);
        l_result := '✓ Connected';
        UTL_HTTP.END_RESPONSE(l_response);
        
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -12541 OR SQLCODE = -12545 THEN
                l_result := '✓ ACL OK (No HTTP on localhost:5432)';
            ELSIF SQLCODE = -24247 THEN
                l_result := '✗ ACL DENIED';
            ELSE
                l_result := '? ' || SUBSTR(SQLERRM, 1, 40);
            END IF;
    END;
    
    DBMS_OUTPUT.PUT_LINE('PostgreSQL (5432):   ' || l_result);
    
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('=== ACL Test Summary ===');
    DBMS_OUTPUT.PUT_LINE('✓ = Working correctly');
    DBMS_OUTPUT.PUT_LINE('⚠ = Minor issue (may work in production)');
    DBMS_OUTPUT.PUT_LINE('✗ = ACL problem (needs fixing)');
    DBMS_OUTPUT.PUT_LINE('? = Unexpected error (check manually)');
    
END;
/

-- 4. Quick privilege check for current user
SELECT 
    CASE 
        WHEN UTL_HTTP.REQUEST_PIECES('http://www.google.com') IS NOT NULL THEN
            'EXECUTE on UTL_HTTP: ✓ GRANTED'
        ELSE
            'EXECUTE on UTL_HTTP: ✗ NOT GRANTED'
    END as utl_http_status
FROM dual;

-- 5. Check network ACL configuration parameters
SELECT 
    name,
    value,
    description
FROM v$parameter 
WHERE name IN ('utl_http_proxy', 'sec_case_sensitive_logon')
ORDER BY name;

-- 6. Detailed ACL information
SELECT 
    'ACL File: ' || acl as info
FROM dba_network_acls 
WHERE acl = 'pltelemetry_acl.xml'
UNION ALL
SELECT 
    'Total Privileges: ' || COUNT(*) as info
FROM dba_network_acl_privileges 
WHERE acl = 'pltelemetry_acl.xml'
UNION ALL
SELECT 
    'Host Assignments: ' || COUNT(*) as info
FROM dba_network_acls 
WHERE acl = 'pltelemetry_acl.xml';

PROMPT
PROMPT =====================================================
PROMPT ACL verification complete
PROMPT Check output above for any ✗ errors
PROMPT =====================================================