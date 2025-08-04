-- =====================================================
-- OTLP Collector Connectivity Test
-- Run as PLTELEMETRY user
-- =====================================================

SET SERVEROUTPUT ON

DECLARE
    l_request   UTL_HTTP.REQ;
    l_response  UTL_HTTP.RESP;
    l_result    VARCHAR2(200);
    l_body      VARCHAR2(4000);
    l_test_payload VARCHAR2(1000);
    
    -- Common OTLP collector endpoints to test
    TYPE t_endpoints IS TABLE OF VARCHAR2(100);
    l_endpoints t_endpoints := t_endpoints(
        'http://localhost:4318',
        'http://127.0.0.1:4318', 
        'http://otel-collector:4318',
        'http://jaeger:14268'
    );
    
    -- Simple test JSON payload
    l_simple_trace CONSTANT VARCHAR2(4000) := '{
        "resourceSpans": [{
            "resource": {
                "attributes": [
                    {"key": "service.name", "value": {"stringValue": "test-service"}}
                ]
            },
            "scopeSpans": [{
                "scope": {"name": "test-scope"},
                "spans": [{
                    "traceId": "12345678901234567890123456789012",
                    "spanId": "1234567890123456",
                    "name": "test-span",
                    "kind": 1,
                    "startTimeUnixNano": "1640995200000000000",
                    "endTimeUnixNano": "1640995201000000000"
                }]
            }]
        }]
    }';
    
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== OTLP Collector Connectivity Test ===');
    DBMS_OUTPUT.PUT_LINE('Testing common collector endpoints...');
    DBMS_OUTPUT.PUT_LINE(' ');
    
    FOR i IN 1..l_endpoints.COUNT LOOP
        l_result := 'Testing: ' || l_endpoints(i);
        DBMS_OUTPUT.PUT_LINE(l_result);
        
        BEGIN
            -- Test 1: Basic connectivity (HEAD request)
            l_request := UTL_HTTP.BEGIN_REQUEST(
                url => l_endpoints(i) || '/v1/traces',
                method => 'HEAD'
            );
            
            UTL_HTTP.SET_HEADER(l_request, 'User-Agent', 'PLTelemetry-ConnTest/1.0');
            UTL_HTTP.SET_HEADER(l_request, 'Connection', 'close');
            
            l_response := UTL_HTTP.GET_RESPONSE(l_request);
            
            DBMS_OUTPUT.PUT_LINE('  ✓ Connection: SUCCESS (HTTP ' || l_response.status_code || ')');
            
            -- Check if it looks like an OTLP endpoint
            IF l_response.status_code IN (200, 405, 415) THEN
                DBMS_OUTPUT.PUT_LINE('  ✓ Endpoint: Likely OTLP collector');
            ELSIF l_response.status_code = 404 THEN
                DBMS_OUTPUT.PUT_LINE('  ⚠ Endpoint: Service running, but not OTLP (/v1/traces not found)');
            ELSE
                DBMS_OUTPUT.PUT_LINE('  ? Endpoint: Unknown service (HTTP ' || l_response.status_code || ')');
            END IF;
            
            UTL_HTTP.END_RESPONSE(l_response);
            
            -- Test 2: Try a POST with minimal payload (if HEAD succeeded)
            IF l_response.status_code != 404 THEN
                BEGIN
                    l_request := UTL_HTTP.BEGIN_REQUEST(
                        url => l_endpoints(i) || '/v1/traces',
                        method => 'POST'
                    );
                    
                    UTL_HTTP.SET_HEADER(l_request, 'Content-Type', 'application/json');
                    UTL_HTTP.SET_HEADER(l_request, 'User-Agent', 'PLTelemetry-ConnTest/1.0');
                    UTL_HTTP.SET_HEADER(l_request, 'Connection', 'close');
                    
                    UTL_HTTP.WRITE_TEXT(l_request, l_simple_trace);
                    
                    l_response := UTL_HTTP.GET_RESPONSE(l_request);
                    
                    IF l_response.status_code IN (200, 202) THEN
                        DBMS_OUTPUT.PUT_LINE('  ✓ OTLP POST: SUCCESS - Ready for telemetry!');
                    ELSIF l_response.status_code = 400 THEN
                        DBMS_OUTPUT.PUT_LINE('  ⚠ OTLP POST: Bad request (collector may need different format)');
                    ELSIF l_response.status_code = 415 THEN
                        DBMS_OUTPUT.PUT_LINE('  ⚠ OTLP POST: Content-type issue (try gRPC instead)');
                    ELSE
                        DBMS_OUTPUT.PUT_LINE('  ? OTLP POST: HTTP ' || l_response.status_code);
                    END IF;
                    
                    UTL_HTTP.END_RESPONSE(l_response);
                    
                EXCEPTION
                    WHEN OTHERS THEN
                        DBMS_OUTPUT.PUT_LINE('  ⚠ OTLP POST: ' || SUBSTR(SQLERRM, 1, 50));
                        BEGIN
                            UTL_HTTP.END_RESPONSE(l_response);
                        EXCEPTION WHEN OTHERS THEN NULL;
                        END;
                END;
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE = -12541 OR SQLCODE = -12545 THEN
                    DBMS_OUTPUT.PUT_LINE('  ✗ Connection: No service running');
                ELSIF SQLCODE = -12535 THEN
                    DBMS_OUTPUT.PUT_LINE('  ✗ Connection: Connection timeout');
                ELSIF SQLCODE = -24247 THEN
                    DBMS_OUTPUT.PUT_LINE('  ✗ Connection: ACL denied');
                ELSIF SQLCODE = -29273 THEN
                    DBMS_OUTPUT.PUT_LINE('  ✗ Connection: HTTP request failed');
                ELSE
                    DBMS_OUTPUT.PUT_LINE('  ✗ Connection: ' || SUBSTR(SQLERRM, 1, 50));
                END IF;
                
                BEGIN
                    UTL_HTTP.END_RESPONSE(l_response);
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
        END;
        
        DBMS_OUTPUT.PUT_LINE(' ');
        
    END LOOP;
    
    -- Test alternative endpoints
    DBMS_OUTPUT.PUT_LINE('=== Testing Alternative Endpoints ===');
    
    -- Grafana Agent
    BEGIN
        l_request := UTL_HTTP.BEGIN_REQUEST('http://localhost:12345/api/v1/otlp/v1/traces', 'HEAD');
        UTL_HTTP.SET_HEADER(l_request, 'Connection', 'close');
        l_response := UTL_HTTP.GET_RESPONSE(l_request);
        DBMS_OUTPUT.PUT_LINE('Grafana Agent (12345): ✓ HTTP ' || l_response.status_code);
        UTL_HTTP.END_RESPONSE(l_response);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Grafana Agent (12345): ✗ Not available');
    END;
    
    -- Direct Tempo
    BEGIN
        l_request := UTL_HTTP.BEGIN_REQUEST('http://localhost:3200/api/traces', 'HEAD');
        UTL_HTTP.SET_HEADER(l_request, 'Connection', 'close');
        l_response := UTL_HTTP.GET_RESPONSE(l_request);
        DBMS_OUTPUT.PUT_LINE('Direct Tempo (3200): ✓ HTTP ' || l_response.status_code);
        UTL_HTTP.END_RESPONSE(l_response);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Direct Tempo (3200): ✗ Not available');
    END;
    
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('=== Test Results Summary ===');
    DBMS_OUTPUT.PUT_LINE('✓ = Working collector found');
    DBMS_OUTPUT.PUT_LINE('⚠ = Service running but may need configuration');
    DBMS_OUTPUT.PUT_LINE('✗ = No service or connection failed');
    DBMS_OUTPUT.PUT_LINE('? = Unexpected response');
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('Next steps:');
    DBMS_OUTPUT.PUT_LINE('- If you see ✗ everywhere: Start your OTLP collector');
    DBMS_OUTPUT.PUT_LINE('- If you see ✓: Use that endpoint in PLTelemetry config');
    DBMS_OUTPUT.PUT_LINE('- If you see ⚠: Check collector configuration');
    
END;
/

-- =====================================================
-- ACL Complete Recheck
-- Run as SYSDBA first, then as PLTELEMETRY
-- =====================================================

-- PART 1: Run as SYSDBA
PROMPT === ACL Status Check (as SYSDBA) ===

-- Show all ACLs for PLTELEMETRY user
SELECT 
    'ACL: ' || acl as info,
    'User: ' || principal as user_info,
    'Privilege: ' || privilege as privilege_info,
    'Granted: ' || is_grant as granted
FROM dba_network_acl_privileges 
WHERE principal = 'PLTELEMETRY'
ORDER BY acl, privilege;

-- Show host assignments for PLTELEMETRY ACLs
SELECT 
    'ACL: ' || acl as acl_info,
    'Host: ' || host as host_info,
    'Ports: ' || NVL(TO_CHAR(lower_port), 'ALL') || '-' || NVL(TO_CHAR(upper_port), 'ALL') as port_info
FROM dba_network_acls 
WHERE acl IN (
    SELECT DISTINCT acl 
    FROM dba_network_acl_privileges 
    WHERE principal = 'PLTELEMETRY'
)
ORDER BY acl, host;

-- Check if user has UTL_HTTP execute
SELECT 
    'UTL_HTTP Execute: ' || 
    CASE 
        WHEN COUNT(*) > 0 THEN 'GRANTED'
        ELSE 'NOT GRANTED'
    END as utl_http_status
FROM dba_tab_privs 
WHERE grantee = 'PLTELEMETRY' 
AND table_name = 'UTL_HTTP'
AND privilege = 'EXECUTE';

PROMPT
PROMPT === Switch to PLTELEMETRY user for connectivity test ===
PROMPT Connect as PLTELEMETRY and run the following:

-- PART 2: Instructions for PLTELEMETRY user
PROMPT
PROMPT CONNECT PLTELEMETRY/[password]
PROMPT
PROMPT SET SERVEROUTPUT ON
PROMPT 
PROMPT DECLARE
PROMPT     l_request   UTL_HTTP.REQ;
PROMPT     l_response  UTL_HTTP.RESP;
PROMPT BEGIN
PROMPT     -- Test otel-collector specifically
PROMPT     l_request := UTL_HTTP.BEGIN_REQUEST('http://otel-collector:4318/v1/traces', 'HEAD');
PROMPT     UTL_HTTP.SET_HEADER(l_request, 'Connection', 'close');
PROMPT     l_response := UTL_HTTP.GET_RESPONSE(l_request);
PROMPT     
PROMPT     DBMS_OUTPUT.PUT_LINE('otel-collector:4318 = HTTP ' || l_response.status_code);
PROMPT     
PROMPT     UTL_HTTP.END_RESPONSE(l_response);
PROMPT     
PROMPT EXCEPTION
PROMPT     WHEN OTHERS THEN
PROMPT         DBMS_OUTPUT.PUT_LINE('Error: ' || SQLCODE || ' - ' || SQLERRM);
PROMPT END;
PROMPT /
PROMPT

-- Quick Docker command helper
PROMPT
PROMPT === Quick OTLP Collector Setup (if needed) ===
PROMPT 
PROMPT If no collectors are running, you can start one with:
PROMPT 
PROMPT # Simple OTLP collector with Jaeger
PROMPT docker run -d --name otel-collector \
PROMPT   -p 4317:4317 -p 4318:4318 -p 14250:14250 \
PROMPT   otel/opentelemetry-collector-contrib:latest
PROMPT 
PROMPT # Or with Grafana Tempo
PROMPT docker run -d --name tempo \
PROMPT   -p 3200:3200 -p 4317:4317 -p 4318:4318 \
PROMPT   grafana/tempo:latest
PROMPT 
PROMPT =====================================================