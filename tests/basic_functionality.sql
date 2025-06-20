-- PLTelemetry Basic Functionality Tests
-- This file contains unit tests for core PLTelemetry functionality
-- Run these tests after installing PLTelemetry to verify it works correctly

PROMPT ================================================================================
PROMPT PLTelemetry Basic Functionality Tests
PROMPT ================================================================================

-- Test configuration
SET SERVEROUTPUT ON
SET FEEDBACK OFF

-- Global test counters
DECLARE
    g_test_count NUMBER := 0;
    g_pass_count NUMBER := 0;
    g_fail_count NUMBER := 0;
BEGIN
    NULL;
END;
/

-- Test utility procedures
CREATE OR REPLACE PACKAGE plt_test_utils AS
    g_test_count NUMBER := 0;
    g_pass_count NUMBER := 0;
    g_fail_count NUMBER := 0;
    
    PROCEDURE start_test_suite(p_suite_name VARCHAR2);
    PROCEDURE assert_equals(p_description VARCHAR2, p_expected VARCHAR2, p_actual VARCHAR2);
    PROCEDURE assert_not_null(p_description VARCHAR2, p_value VARCHAR2);
    PROCEDURE assert_null(p_description VARCHAR2, p_value VARCHAR2);
    PROCEDURE assert_true(p_description VARCHAR2, p_condition BOOLEAN);
    PROCEDURE end_test_suite;
    PROCEDURE cleanup_test_data;
END;
/

CREATE OR REPLACE PACKAGE BODY plt_test_utils AS
    
    PROCEDURE start_test_suite(p_suite_name VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('=== ' || p_suite_name || ' ===');
        g_test_count := 0;
        g_pass_count := 0;
        g_fail_count := 0;
    END;
    
    PROCEDURE assert_equals(p_description VARCHAR2, p_expected VARCHAR2, p_actual VARCHAR2) IS
    BEGIN
        g_test_count := g_test_count + 1;
        IF NVL(p_expected, 'NULL') = NVL(p_actual, 'NULL') THEN
            g_pass_count := g_pass_count + 1;
            DBMS_OUTPUT.PUT_LINE('✓ PASS: ' || p_description);
        ELSE
            g_fail_count := g_fail_count + 1;
            DBMS_OUTPUT.PUT_LINE('✗ FAIL: ' || p_description);
            DBMS_OUTPUT.PUT_LINE('  Expected: ' || NVL(p_expected, 'NULL'));
            DBMS_OUTPUT.PUT_LINE('  Actual: ' || NVL(p_actual, 'NULL'));
        END IF;
    END;
    
    PROCEDURE assert_not_null(p_description VARCHAR2, p_value VARCHAR2) IS
    BEGIN
        g_test_count := g_test_count + 1;
        IF p_value IS NOT NULL THEN
            g_pass_count := g_pass_count + 1;
            DBMS_OUTPUT.PUT_LINE('✓ PASS: ' || p_description);
        ELSE
            g_fail_count := g_fail_count + 1;
            DBMS_OUTPUT.PUT_LINE('✗ FAIL: ' || p_description || ' (value is NULL)');
        END IF;
    END;
    
    PROCEDURE assert_null(p_description VARCHAR2, p_value VARCHAR2) IS
    BEGIN
        g_test_count := g_test_count + 1;
        IF p_value IS NULL THEN
            g_pass_count := g_pass_count + 1;
            DBMS_OUTPUT.PUT_LINE('✓ PASS: ' || p_description);
        ELSE
            g_fail_count := g_fail_count + 1;
            DBMS_OUTPUT.PUT_LINE('✗ FAIL: ' || p_description || ' (value is not NULL: ' || p_value || ')');
        END IF;
    END;
    
    PROCEDURE assert_true(p_description VARCHAR2, p_condition BOOLEAN) IS
    BEGIN
        g_test_count := g_test_count + 1;
        IF p_condition THEN
            g_pass_count := g_pass_count + 1;
            DBMS_OUTPUT.PUT_LINE('✓ PASS: ' || p_description);
        ELSE
            g_fail_count := g_fail_count + 1;
            DBMS_OUTPUT.PUT_LINE('✗ FAIL: ' || p_description);
        END IF;
    END;
    
    PROCEDURE end_test_suite IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Results: ' || g_pass_count || ' passed, ' || g_fail_count || ' failed (' || g_test_count || ' total)');
        IF g_fail_count > 0 THEN
            DBMS_OUTPUT.PUT_LINE('❌ SUITE FAILED');
        ELSE
            DBMS_OUTPUT.PUT_LINE('✅ SUITE PASSED');
        END IF;
    END;
    
    PROCEDURE cleanup_test_data IS
    BEGIN
        -- Clean up test data
        DELETE FROM plt_traces WHERE root_operation LIKE 'test_%';
        DELETE FROM plt_spans WHERE operation_name LIKE 'test_%';
        DELETE FROM plt_events WHERE event_name LIKE 'test_%';
        DELETE FROM plt_metrics WHERE metric_name LIKE 'test_%';
        DELETE FROM plt_queue WHERE payload LIKE '%test_%';
        DELETE FROM plt_telemetry_errors WHERE module_name LIKE 'test_%';
        COMMIT;
    END;
END;
/

-- Test 1: Basic Configuration
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Configuration Tests');
    
    -- Test setting and getting backend URL
    PLTelemetry.set_backend_url('http://test.example.com/api');
    plt_test_utils.assert_equals(
        'Backend URL setting/getting',
        'http://test.example.com/api',
        PLTelemetry.get_backend_url()
    );
    
    -- Test autocommit setting
    PLTelemetry.set_autocommit(TRUE);
    plt_test_utils.assert_true(
        'Autocommit setting to TRUE',
        PLTelemetry.get_autocommit()
    );
    
    PLTelemetry.set_autocommit(FALSE);
    plt_test_utils.assert_true(
        'Autocommit setting to FALSE',
        NOT PLTelemetry.get_autocommit()
    );
    
    -- Test async mode setting
    PLTelemetry.set_async_mode(TRUE);
    PLTelemetry.set_async_mode(FALSE);  -- No direct getter, but should not error
    
    plt_test_utils.end_test_suite();
END;
/

-- Test 2: Trace Management
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Trace Management Tests');
    
    DECLARE
        l_trace_id VARCHAR2(32);
        l_trace_count NUMBER;
    BEGIN
        -- Test trace creation
        l_trace_id := PLTelemetry.start_trace('test_trace_creation');
        
        plt_test_utils.assert_not_null('Trace ID generation', l_trace_id);
        plt_test_utils.assert_equals('Trace ID length', '32', TO_CHAR(LENGTH(l_trace_id)));
        plt_test_utils.assert_equals('Current trace ID', l_trace_id, PLTelemetry.get_current_trace_id());
        
        -- Verify trace was inserted
        SELECT COUNT(*) INTO l_trace_count 
        FROM plt_traces 
        WHERE trace_id = l_trace_id;
        
        plt_test_utils.assert_equals('Trace inserted in database', '1', TO_CHAR(l_trace_count));
        
        -- Test trace ending
        PLTelemetry.end_trace(l_trace_id);
        
        -- Verify trace was ended
        SELECT COUNT(*) INTO l_trace_count 
        FROM plt_traces 
        WHERE trace_id = l_trace_id AND end_time IS NOT NULL;
        
        plt_test_utils.assert_equals('Trace ended in database', '1', TO_CHAR(l_trace_count));
    END;
    
    plt_test_utils.end_test_suite();
END;
/

-- Test 3: Span Management
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Span Management Tests');
    
    DECLARE
        l_trace_id VARCHAR2(32);
        l_span_id VARCHAR2(16);
        l_span_count NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        -- Create trace for span tests
        l_trace_id := PLTelemetry.start_trace('test_span_management');
        
        -- Test span creation
        l_span_id := PLTelemetry.start_span('test_span_creation');
        
        plt_test_utils.assert_not_null('Span ID generation', l_span_id);
        plt_test_utils.assert_equals('Span ID length', '16', TO_CHAR(LENGTH(l_span_id)));
        plt_test_utils.assert_equals('Current span ID', l_span_id, PLTelemetry.get_current_span_id());
        
        -- Verify span was inserted
        SELECT COUNT(*) INTO l_span_count 
        FROM plt_spans 
        WHERE span_id = l_span_id;
        
        plt_test_utils.assert_equals('Span inserted in database', '1', TO_CHAR(l_span_count));
        
        -- Test span ending with attributes
        l_attrs(1) := PLTelemetry.add_attribute('test.attribute', 'test_value');
        PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
        
        -- Verify span was ended
        SELECT COUNT(*) INTO l_span_count 
        FROM plt_spans 
        WHERE span_id = l_span_id AND end_time IS NOT NULL AND status = 'OK';
        
        plt_test_utils.assert_equals('Span ended with OK status', '1', TO_CHAR(l_span_count));
        
        PLTelemetry.end_trace(l_trace_id);
    END;
    
    plt_test_utils.end_test_suite();
END;
/

-- Test 4: Nested Spans
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Nested Spans Tests');
    
    DECLARE
        l_trace_id VARCHAR2(32);
        l_parent_span VARCHAR2(16);
        l_child_span VARCHAR2(16);
        l_relationship_count NUMBER;
    BEGIN
        l_trace_id := PLTelemetry.start_trace('test_nested_spans');
        
        -- Create parent span
        l_parent_span := PLTelemetry.start_span('test_parent_span');
        
        -- Create child span
        l_child_span := PLTelemetry.start_span('test_child_span', l_parent_span);
        
        -- Verify parent-child relationship
        SELECT COUNT(*) INTO l_relationship_count
        FROM plt_spans
        WHERE span_id = l_child_span 
          AND parent_span_id = l_parent_span
          AND trace_id = l_trace_id;
        
        plt_test_utils.assert_equals('Parent-child span relationship', '1', TO_CHAR(l_relationship_count));
        
        -- End spans in correct order
        PLTelemetry.end_span(l_child_span, 'OK');
        PLTelemetry.end_span(l_parent_span, 'OK');
        PLTelemetry.end_trace(l_trace_id);
    END;
    
    plt_test_utils.end_test_suite();
END;
/

-- Test 5: Events
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Events Tests');
    
    DECLARE
        l_trace_id VARCHAR2(32);
        l_span_id VARCHAR2(16);
        l_attrs PLTelemetry.t_attributes;
        l_event_count NUMBER;
    BEGIN
        l_trace_id := PLTelemetry.start_trace('test_events');
        l_span_id := PLTelemetry.start_span('test_event_span');
        
        -- Add event without attributes
        PLTelemetry.add_event(l_span_id, 'test_simple_event');
        
        -- Add event with attributes
        l_attrs(1) := PLTelemetry.add_attribute('event.type', 'test');
        l_attrs(2) := PLTelemetry.add_attribute('event.value', '42');
        PLTelemetry.add_event(l_span_id, 'test_event_with_attributes', l_attrs);
        
        -- Verify events were created
        SELECT COUNT(*) INTO l_event_count
        FROM plt_events
        WHERE span_id = l_span_id;
        
        plt_test_utils.assert_equals('Events created for span', '2', TO_CHAR(l_event_count));
        
        -- Verify specific event names
        SELECT COUNT(*) INTO l_event_count
        FROM plt_events
        WHERE span_id = l_span_id AND event_name = 'test_simple_event';
        
        plt_test_utils.assert_equals('Simple event created', '1', TO_CHAR(l_event_count));
        
        SELECT COUNT(*) INTO l_event_count
        FROM plt_events
        WHERE span_id = l_span_id AND event_name = 'test_event_with_attributes';
        
        plt_test_utils.assert_equals('Event with attributes created', '1', TO_CHAR(l_event_count));
        
        PLTelemetry.end_span(l_span_id, 'OK');
        PLTelemetry.end_trace(l_trace_id);
    END;
    
    plt_test_utils.end_test_suite();
END;
/

-- Test 6: Metrics
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Metrics Tests');
    
    DECLARE
        l_trace_id VARCHAR2(32);
        l_span_id VARCHAR2(16);
        l_attrs PLTelemetry.t_attributes;
        l_metric_count NUMBER;
        l_metric_value NUMBER;
    BEGIN
        l_trace_id := PLTelemetry.start_trace('test_metrics');
        l_span_id := PLTelemetry.start_span('test_metric_span');
        
        -- Log various types of metrics
        l_attrs(1) := PLTelemetry.add_attribute('test.context', 'metric_test');
        
        PLTelemetry.log_metric('test_counter', 1, 'count', l_attrs);
        PLTelemetry.log_metric('test_duration', 123.45, 'milliseconds', l_attrs);
        PLTelemetry.log_metric('test_percentage', 85.5, 'percent', l_attrs);
        
        -- Verify metrics were created
        SELECT COUNT(*) INTO l_metric_count
        FROM plt_metrics
        WHERE metric_name LIKE 'test_%' AND trace_id = l_trace_id;
        
        plt_test_utils.assert_equals('Metrics created', '3', TO_CHAR(l_metric_count));
        
        -- Verify specific metric value
        SELECT metric_value INTO l_metric_value
        FROM plt_metrics
        WHERE metric_name = 'test_duration' AND trace_id = l_trace_id;
        
        plt_test_utils.assert_equals('Metric value stored correctly', '123.45', TO_CHAR(l_metric_value));
        
        PLTelemetry.end_span(l_span_id, 'OK');
        PLTelemetry.end_trace(l_trace_id);
    END;
    
    plt_test_utils.end_test_suite();
END;
/

-- Test 7: Attribute Handling
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Attribute Handling Tests');
    
    DECLARE
        l_attr_result VARCHAR2(4000);
        l_attrs PLTelemetry.t_attributes;
        l_json_result VARCHAR2(4000);
    BEGIN
        -- Test basic attribute creation
        l_attr_result := PLTelemetry.add_attribute('test.key', 'test_value');
        plt_test_utils.assert_equals('Basic attribute format', 'test.key=test_value', l_attr_result);
        
        -- Test attribute with special characters
        l_attr_result := PLTelemetry.add_attribute('test.special', 'value with = and \ chars');
        plt_test_utils.assert_not_null('Attribute with special characters', l_attr_result);
        
        -- Test attributes to JSON conversion
        l_attrs(1) := PLTelemetry.add_attribute('key1', 'value1');
        l_attrs(2) := PLTelemetry.add_attribute('key2', 'value2');
        l_attrs(3) := PLTelemetry.add_attribute('number.key', '42');
        
        l_json_result := PLTelemetry.attributes_to_json(l_attrs);
        
        plt_test_utils.assert_not_null('Attributes to JSON conversion', l_json_result);
        plt_test_utils.assert_true('JSON contains key1', INSTR(l_json_result, 'key1') > 0);
        plt_test_utils.assert_true('JSON contains value1', INSTR(l_json_result, 'value1') > 0);
        plt_test_utils.assert_true('JSON is valid format', SUBSTR(l_json_result, 1, 1) = '{' AND SUBSTR(l_json_result, -1, 1) = '}');
    END;
    
    plt_test_utils.end_test_suite();
END;
/

-- Test 8: Error Scenarios
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Error Scenarios Tests');
    
    DECLARE
        l_trace_id VARCHAR2(32);
        l_span_id VARCHAR2(16);
        l_error_occurred BOOLEAN := FALSE;
    BEGIN
        -- Test ending non-existent span (should not error)
        BEGIN
            PLTelemetry.end_span('nonexistent_span', 'ERROR');
            plt_test_utils.assert_true('Ending non-existent span handled gracefully', TRUE);
        EXCEPTION
            WHEN OTHERS THEN
                plt_test_utils.assert_true('Ending non-existent span should not raise exception', FALSE);
        END;
        
        -- Test adding event to non-existent span (should not error)
        BEGIN
            PLTelemetry.add_event('nonexistent_span', 'test_event');
            plt_test_utils.assert_true('Adding event to non-existent span handled gracefully', TRUE);
        EXCEPTION
            WHEN OTHERS THEN
                plt_test_utils.assert_true('Adding event to non-existent span should not raise exception', FALSE);
        END;
        
        -- Test null parameter handling
        BEGIN
            PLTelemetry.add_event(NULL, 'test_event');
            PLTelemetry.add_event('some_span', NULL);
            plt_test_utils.assert_true('Null parameter handling', TRUE);
        EXCEPTION
            WHEN OTHERS THEN
                plt_test_utils.assert_true('Null parameters should be handled gracefully', FALSE);
        END;
        
        -- Test extremely long operation name
        l_trace_id := PLTelemetry.start_trace('test_long_names');
        BEGIN
            l_span_id := PLTelemetry.start_span(RPAD('very_long_operation_name', 300, 'x'));
            PLTelemetry.end_span(l_span_id, 'OK');
            plt_test_utils.assert_true('Long operation name handling', TRUE);
        EXCEPTION
            WHEN OTHERS THEN
                plt_test_utils.assert_true('Long operation names should be handled', FALSE);
        END;
        
        PLTelemetry.end_trace(l_trace_id);
    END;
    
    plt_test_utils.end_test_suite();
END;
/

-- Test 9: Queue Functionality (Async Mode)
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Queue Functionality Tests');
    
    DECLARE
        l_trace_id VARCHAR2(32);
        l_span_id VARCHAR2(16);
        l_queue_count_before NUMBER;
        l_queue_count_after NUMBER;
    BEGIN
        -- Enable async mode
        PLTelemetry.set_async_mode(TRUE);
        
        -- Get initial queue count
        SELECT COUNT(*) INTO l_queue_count_before FROM plt_queue WHERE processed = 'N';
        
        -- Perform operations that should queue telemetry
        l_trace_id := PLTelemetry.start_trace('test_queue_functionality');
        l_span_id := PLTelemetry.start_span('test_queue_span');
        PLTelemetry.end_span(l_span_id, 'OK');
        PLTelemetry.end_trace(l_trace_id);
        
        -- Check if items were queued
        SELECT COUNT(*) INTO l_queue_count_after FROM plt_queue WHERE processed = 'N';
        
        plt_test_utils.assert_true('Items queued in async mode', l_queue_count_after > l_queue_count_before);
        
        -- Test queue processing
        BEGIN
            PLTelemetry.process_queue(10);
            plt_test_utils.assert_true('Queue processing completed without error', TRUE);
        EXCEPTION
            WHEN OTHERS THEN
                plt_test_utils.assert_true('Queue processing should not fail', FALSE);
        END;
    END;
    
    plt_test_utils.end_test_suite();
END;
/

-- Test 10: Context Management
-- ============================================================================
BEGIN
    plt_test_utils.start_test_suite('Context Management Tests');
    
    DECLARE
        l_trace_id1 VARCHAR2(32);
        l_trace_id2 VARCHAR2(32);
        l_span_id VARCHAR2(16);
    BEGIN
        -- Test initial state (no context)
        plt_test_utils.assert_null('Initial trace context', PLTelemetry.get_current_trace_id());
        plt_test_utils.assert_null('Initial span context', PLTelemetry.get_current_span_id());
        
        -- Test context setting
        l_trace_id1 := PLTelemetry.start_trace('test_context_1');
        plt_test_utils.assert_equals('Trace context set', l_trace_id1, PLTelemetry.get_current_trace_id());
        
        l_span_id := PLTelemetry.start_span('test_context_span');
        plt_test_utils.assert_equals('Span context set', l_span_id, PLTelemetry.get_current_span_id());
        
        -- Test context preservation across operations
        PLTelemetry.add_event(l_span_id, 'test_context_event');
        plt_test_utils.assert_equals('Context preserved after event', l_span_id, PLTelemetry.get_current_span_id());
        
        PLTelemetry.end_span(l_span_id, 'OK');
        PLTelemetry.end_trace(l_trace_id1);
        
        -- Test context clearing
        PLTelemetry.clear_trace_context();
        plt_test_utils.assert_null('Context cleared', PLTelemetry.get_current_trace_id());
    END;
    
    plt_test_utils.end_test_suite();
END;
/

-- Final Test Summary
-- ============================================================================
PROMPT
PROMPT ================================================================================
PROMPT Test Suite Summary
PROMPT ================================================================================

DECLARE
    l_total_traces NUMBER;
    l_total_spans NUMBER;
    l_total_events NUMBER;
    l_total_metrics NUMBER;
    l_total_queue NUMBER;
    l_total_errors NUMBER;
BEGIN
    -- Count test data created
    SELECT COUNT(*) INTO l_total_traces FROM plt_traces WHERE root_operation LIKE 'test_%';
    SELECT COUNT(*) INTO l_total_spans FROM plt_spans WHERE operation_name LIKE 'test_%';
    SELECT COUNT(*) INTO l_total_events FROM plt_events WHERE event_name LIKE 'test_%';
    SELECT COUNT(*) INTO l_total_metrics FROM plt_metrics WHERE metric_name LIKE 'test_%';
    SELECT COUNT(*) INTO l_total_queue FROM plt_queue WHERE payload LIKE '%test_%';
    SELECT COUNT(*) INTO l_total_errors FROM plt_telemetry_errors WHERE module_name LIKE 'test_%';
    
    DBMS_OUTPUT.PUT_LINE('Test Data Created:');
    DBMS_OUTPUT.PUT_LINE('  Traces: ' || l_total_traces);
    DBMS_OUTPUT.PUT_LINE('  Spans: ' || l_total_spans);
    DBMS_OUTPUT.PUT_LINE('  Events: ' || l_total_events);
    DBMS_OUTPUT.PUT_LINE('  Metrics: ' || l_total_metrics);
    DBMS_OUTPUT.PUT_LINE('  Queue entries: ' || l_total_queue);
    DBMS_OUTPUT.PUT_LINE('  Errors: ' || l_total_errors);
    
    IF l_total_errors > 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('⚠️  Check plt_telemetry_errors table for any issues during testing');
    END IF;
END;
/

-- Cleanup
PROMPT
PROMPT Cleaning up test data...
BEGIN
    plt_test_utils.cleanup_test_data();
    DBMS_OUTPUT.PUT_LINE('✓ Test data cleaned up');
END;
/

-- Drop test utilities
DROP PACKAGE plt_test_utils;

PROMPT
PROMPT ================================================================================
PROMPT Basic Functionality Tests Completed
PROMPT ================================================================================
PROMPT
PROMPT All core PLTelemetry functionality has been tested:
PROMPT ✓ Configuration management
PROMPT ✓ Trace lifecycle
PROMPT ✓ Span lifecycle and nesting
PROMPT ✓ Event creation
PROMPT ✓ Metric recording
PROMPT ✓ Attribute handling and JSON conversion
PROMPT ✓ Error scenario handling
PROMPT ✓ Queue functionality (async mode)
PROMPT ✓ Context management
PROMPT
PROMPT If any tests failed, check the error details above and verify:
PROMPT 1. PLTelemetry package is properly installed
PROMPT 2. Required privileges are granted
PROMPT 3. Database tables exist and are accessible
PROMPT 4. Network connectivity for backend calls (if applicable)
PROMPT
PROMPT ================================================================================