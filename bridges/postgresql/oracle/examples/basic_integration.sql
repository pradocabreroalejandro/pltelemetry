-- ============================================
-- FILE: basic_integration.sql
-- PostgreSQL Bridge - Basic Integration Example
-- ============================================

/*
This example demonstrates the basic setup and usage of the PostgreSQL bridge
for PLTelemetry. It covers configuration, simple trace creation, and verification.
*/

-- Prerequisites:
-- 1. PLTelemetry core package installed
-- 2. PLT_POSTGRES_BRIDGE package installed
-- 3. PostgreSQL with telemetry schema created
-- 4. PostgREST running on port 3000

SET SERVEROUTPUT ON SIZE UNLIMITED

-- Step 1: Configure the bridge
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== CONFIGURING POSTGRESQL BRIDGE ===');
    
    -- Set PLTelemetry to use the PostgreSQL bridge
    PLTelemetry.set_backend_url('POSTGRES_BRIDGE');
    
    -- Enable autocommit for immediate processing
    PLTelemetry.set_autocommit(TRUE);
    
    -- Configure the bridge endpoint
    PLT_POSTGRES_BRIDGE.set_postgrest_url('http://localhost:3000');
    
    -- Optional: Set timeout for HTTP calls
    PLT_POSTGRES_BRIDGE.set_timeout(30);
    
    DBMS_OUTPUT.PUT_LINE('✓ Configuration complete');
END;
/

-- Step 2: Create a simple trace with span and metric
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== CREATING TELEMETRY DATA ===');
    
    -- Start a new trace
    l_trace_id := PLT_POSTGRES_BRIDGE.start_trace_with_postgres('user_registration');
    DBMS_OUTPUT.PUT_LINE('Trace started: ' || l_trace_id);
    
    -- Create a span for validation process
    l_span_id := PLTelemetry.start_span('validate_user_data');
    
    -- Add some attributes
    l_attrs(1) := PLTelemetry.add_attribute('user.type', 'premium');
    l_attrs(2) := PLTelemetry.add_attribute('user.country', 'ES');
    l_attrs(3) := PLTelemetry.add_attribute('validation.rules', '5');
    
    -- Simulate some work
    DBMS_LOCK.sleep(0.5);
    
    -- Add an event
    PLTelemetry.add_event(l_span_id, 'email_validated', l_attrs);
    
    -- End the span with status
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    
    -- Log a metric (IMPORTANT: After span ends in sync mode!)
    PLTelemetry.log_metric('validation_duration', 500, 'ms', l_attrs);
    
    -- End the trace
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('✓ Telemetry data created');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== VERIFICATION QUERIES ===');
    DBMS_OUTPUT.PUT_LINE('Run these in PostgreSQL to verify:');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('-- Check trace:');
    DBMS_OUTPUT.PUT_LINE('SELECT * FROM telemetry.traces WHERE trace_id = ''' || l_trace_id || ''';');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('-- Check span:');
    DBMS_OUTPUT.PUT_LINE('SELECT * FROM telemetry.spans WHERE trace_id = ''' || l_trace_id || ''';');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('-- Check metrics:');
    DBMS_OUTPUT.PUT_LINE('SELECT * FROM telemetry.metrics WHERE trace_id = ''' || l_trace_id || ''';');
END;
/

-- Step 3: Check for any errors
PROMPT
PROMPT Checking for errors...
SELECT error_time, error_message, module_name
FROM plt_telemetry_errors
WHERE error_time > SYSTIMESTAMP - INTERVAL '5' MINUTE
ORDER BY error_time DESC;

-- Step 4: View queue status (if using async mode)
PROMPT
PROMPT Queue status:
SELECT 
    (SELECT COUNT(*) FROM plt_queue WHERE processed = 'N') as pending_items,
    (SELECT COUNT(*) FROM plt_queue WHERE processed = 'Y' AND processed_time > SYSTIMESTAMP - INTERVAL '1' HOUR) as processed_last_hour,
    (SELECT MAX(processed_time) FROM plt_queue WHERE processed = 'Y') as last_processed
FROM dual;