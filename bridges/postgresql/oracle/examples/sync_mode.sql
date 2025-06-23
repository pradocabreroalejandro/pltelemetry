-- ============================================
-- FILE: sync_mode.sql
-- PostgreSQL Bridge - Synchronous Mode Example
-- ============================================

/*
This example demonstrates using the PostgreSQL bridge in synchronous mode.
In sync mode, telemetry data is sent immediately to PostgreSQL without queuing.

IMPORTANT: Order matters in sync mode due to foreign key constraints!
*/

SET SERVEROUTPUT ON SIZE UNLIMITED

-- Configure for synchronous mode
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== CONFIGURING SYNCHRONOUS MODE ===');
    
    -- Basic configuration
    PLTelemetry.set_backend_url('POSTGRES_BRIDGE');
    PLTelemetry.set_autocommit(TRUE);
    
    -- IMPORTANT: Set synchronous mode
    PLTelemetry.set_async_mode(FALSE);
    
    -- Configure bridge
    PLT_POSTGRES_BRIDGE.set_postgrest_url('http://localhost:3000');
    
    DBMS_OUTPUT.PUT_LINE('Mode: ' || CASE 
        WHEN PLTelemetry.g_async_mode THEN 'ASYNC' 
        ELSE 'SYNC' 
    END);
    DBMS_OUTPUT.PUT_LINE('✓ Synchronous mode configured');
END;
/

-- Example 1: Correct order for sync mode
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== EXAMPLE 1: CORRECT ORDER ===');
    
    -- 1. Start trace (sent immediately to PostgreSQL)
    l_trace_id := PLT_POSTGRES_BRIDGE.start_trace_with_postgres('sync_order_demo');
    DBMS_OUTPUT.PUT_LINE('1. Trace created: ' || l_trace_id);
    
    -- 2. Start span (only stored locally)
    l_span_id := PLTelemetry.start_span('process_order');
    DBMS_OUTPUT.PUT_LINE('2. Span started: ' || l_span_id);
    
    -- 3. Add attributes
    l_attrs(1) := PLTelemetry.add_attribute('order.id', '12345');
    l_attrs(2) := PLTelemetry.add_attribute('order.total', '299.99');
    
    -- 4. Simulate processing
    DBMS_LOCK.sleep(0.3);
    
    -- 5. CRITICAL: End span BEFORE creating metrics
    -- This sends the span to PostgreSQL
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    DBMS_OUTPUT.PUT_LINE('3. Span ended and sent to PostgreSQL');
    
    -- 6. NOW we can safely create metrics
    -- The span exists in PostgreSQL, so FK constraint is satisfied
    PLTelemetry.log_metric('order_processing_time', 300, 'ms', l_attrs);
    DBMS_OUTPUT.PUT_LINE('4. Metric sent to PostgreSQL');
    
    DBMS_OUTPUT.PUT_LINE('✓ Success - correct order maintained');
END;
/

-- Example 2: Multiple spans with proper ordering
DECLARE
    l_trace_id VARCHAR2(32);
    l_parent_span VARCHAR2(16);
    l_child_span1 VARCHAR2(16);
    l_child_span2 VARCHAR2(16);
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== EXAMPLE 2: NESTED SPANS ===');
    
    -- Create trace
    l_trace_id := PLT_POSTGRES_BRIDGE.start_trace_with_postgres('sync_nested_demo');
    
    -- Parent span
    l_parent_span := PLTelemetry.start_span('main_process');
    DBMS_OUTPUT.PUT_LINE('Parent span: ' || l_parent_span);
    
    -- Child span 1
    l_child_span1 := PLTelemetry.start_span('subprocess_1', l_parent_span);
    DBMS_LOCK.sleep(0.1);
    PLTelemetry.end_span(l_child_span1, 'OK');
    PLTelemetry.log_metric('subprocess_1_duration', 100, 'ms');
    DBMS_OUTPUT.PUT_LINE('  Child 1 completed');
    
    -- Child span 2
    l_child_span2 := PLTelemetry.start_span('subprocess_2', l_parent_span);
    DBMS_LOCK.sleep(0.2);
    PLTelemetry.end_span(l_child_span2, 'OK');
    PLTelemetry.log_metric('subprocess_2_duration', 200, 'ms');
    DBMS_OUTPUT.PUT_LINE('  Child 2 completed');
    
    -- End parent
    PLTelemetry.end_span(l_parent_span, 'OK');
    PLTelemetry.log_metric('total_duration', 300, 'ms');
    DBMS_OUTPUT.PUT_LINE('Parent completed');
    
    DBMS_OUTPUT.PUT_LINE('✓ Nested spans processed correctly');
END;
/

-- Example 3: Error handling in sync mode
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_error_count NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== EXAMPLE 3: ERROR HANDLING ===');
    
    -- Create trace
    l_trace_id := PLT_POSTGRES_BRIDGE.start_trace_with_postgres('sync_error_demo');
    l_span_id := PLTelemetry.start_span('may_fail_process');
    
    BEGIN
        -- Simulate some process that might fail
        IF DBMS_RANDOM.value < 0.5 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Simulated process error');
        END IF;
        
        -- Success path
        PLTelemetry.end_span(l_span_id, 'OK');
        PLTelemetry.log_metric('success_count', 1, 'count');
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Error path - still record telemetry
            PLTelemetry.end_span(l_span_id, 'ERROR');
            PLTelemetry.log_metric('error_count', 1, 'count');
            DBMS_OUTPUT.PUT_LINE('Process failed but telemetry recorded');
    END;
    
    -- Check if telemetry errors occurred
    SELECT COUNT(*) INTO l_error_count
    FROM plt_telemetry_errors
    WHERE error_time > SYSTIMESTAMP - INTERVAL '1' MINUTE
    AND module_name LIKE '%sync_error_demo%';
    
    DBMS_OUTPUT.PUT_LINE('Telemetry errors: ' || l_error_count);
    DBMS_OUTPUT.PUT_LINE('✓ Error handling complete');
END;
/

-- Cleanup: Switch back to async mode
BEGIN
    PLTelemetry.set_async_mode(TRUE);
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Switched back to async mode');
END;
/