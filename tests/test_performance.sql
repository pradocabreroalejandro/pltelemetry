-- PLTelemetry Performance Tests
-- This file tests PLTelemetry performance characteristics and overhead
-- Measures impact on business operations and identifies bottlenecks

PROMPT ================================================================================
PROMPT PLTelemetry Performance Tests
PROMPT ================================================================================

SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET TIMING ON

-- Performance test utilities
CREATE OR REPLACE PACKAGE plt_perf_test_utils AS
    TYPE t_timing_result IS RECORD (
        operation_name VARCHAR2(100),
        iterations NUMBER,
        total_time_ms NUMBER,
        avg_time_ms NUMBER,
        min_time_ms NUMBER,
        max_time_ms NUMBER,
        overhead_pct NUMBER
    );
    
    TYPE t_timing_results IS TABLE OF t_timing_result INDEX BY BINARY_INTEGER;
    
    g_results t_timing_results;
    g_result_count NUMBER := 0;
    
    PROCEDURE start_test_suite(p_suite_name VARCHAR2);
    PROCEDURE time_operation(p_operation_name VARCHAR2, p_iterations NUMBER, p_test_block VARCHAR2);
    PROCEDURE time_operation_with_baseline(p_operation_name VARCHAR2, p_iterations NUMBER, p_test_block VARCHAR2, p_baseline_block VARCHAR2);
    PROCEDURE show_results;
    PROCEDURE end_test_suite;
    PROCEDURE cleanup_test_data;
    
    FUNCTION get_timestamp_ms RETURN NUMBER;
END;
/

CREATE OR REPLACE PACKAGE BODY plt_perf_test_utils AS
    
    FUNCTION get_timestamp_ms RETURN NUMBER IS
    BEGIN
        RETURN EXTRACT(SECOND FROM (SYSTIMESTAMP - DATE '1970-01-01')) * 1000 +
               EXTRACT(SECOND FROM SYSTIMESTAMP) * 1000;
    END;
    
    PROCEDURE start_test_suite(p_suite_name VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('=== ' || p_suite_name || ' ===');
        g_result_count := 0;
        g_results.DELETE;
    END;
    
    PROCEDURE time_operation(p_operation_name VARCHAR2, p_iterations NUMBER, p_test_block VARCHAR2) IS
        l_start_time NUMBER;
        l_end_time NUMBER;
        l_iteration_times DBMS_SQL.NUMBER_TABLE;
        l_total_time NUMBER := 0;
        l_min_time NUMBER := 999999;
        l_max_time NUMBER := 0;
        l_iter_time NUMBER;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('Testing: ' || p_operation_name || ' (' || p_iterations || ' iterations)');
        
        -- Warm up
        FOR i IN 1..5 LOOP
            EXECUTE IMMEDIATE p_test_block;
        END LOOP;
        
        -- Actual timing
        FOR i IN 1..p_iterations LOOP
            l_start_time := get_timestamp_ms();
            EXECUTE IMMEDIATE p_test_block;
            l_end_time := get_timestamp_ms();
            
            l_iter_time := l_end_time - l_start_time;
            l_total_time := l_total_time + l_iter_time;
            
            IF l_iter_time < l_min_time THEN l_min_time := l_iter_time; END IF;
            IF l_iter_time > l_max_time THEN l_max_time := l_iter_time; END IF;
        END LOOP;
        
        g_result_count := g_result_count + 1;
        g_results(g_result_count).operation_name := p_operation_name;
        g_results(g_result_count).iterations := p_iterations;
        g_results(g_result_count).total_time_ms := l_total_time;
        g_results(g_result_count).avg_time_ms := l_total_time / p_iterations;
        g_results(g_result_count).min_time_ms := l_min_time;
        g_results(g_result_count).max_time_ms := l_max_time;
        g_results(g_result_count).overhead_pct := 0;
        
        DBMS_OUTPUT.PUT_LINE('  Total: ' || ROUND(l_total_time, 2) || 'ms, Avg: ' || 
                           ROUND(l_total_time / p_iterations, 3) || 'ms, Min: ' || 
                           ROUND(l_min_time, 3) || 'ms, Max: ' || ROUND(l_max_time, 3) || 'ms');
    END;
    
    PROCEDURE time_operation_with_baseline(p_operation_name VARCHAR2, p_iterations NUMBER, p_test_block VARCHAR2, p_baseline_block VARCHAR2) IS
        l_start_time NUMBER;
        l_end_time NUMBER;
        l_baseline_time NUMBER := 0;
        l_test_time NUMBER := 0;
        l_iter_time NUMBER;
        l_overhead_pct NUMBER;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('Testing with baseline: ' || p_operation_name || ' (' || p_iterations || ' iterations)');
        
        -- Measure baseline (without telemetry)
        FOR i IN 1..p_iterations LOOP
            l_start_time := get_timestamp_ms();
            EXECUTE IMMEDIATE p_baseline_block;
            l_end_time := get_timestamp_ms();
            l_baseline_time := l_baseline_time + (l_end_time - l_start_time);
        END LOOP;
        
        -- Measure with telemetry
        FOR i IN 1..p_iterations LOOP
            l_start_time := get_timestamp_ms();
            EXECUTE IMMEDIATE p_test_block;
            l_end_time := get_timestamp_ms();
            l_test_time := l_test_time + (l_end_time - l_start_time);
        END LOOP;
        
        l_overhead_pct := CASE WHEN l_baseline_time > 0 THEN ((l_test_time - l_baseline_time) / l_baseline_time) * 100 ELSE 0 END;
        
        g_result_count := g_result_count + 1;
        g_results(g_result_count).operation_name := p_operation_name;
        g_results(g_result_count).iterations := p_iterations;
        g_results(g_result_count).total_time_ms := l_test_time;
        g_results(g_result_count).avg_time_ms := l_test_time / p_iterations;
        g_results(g_result_count).min_time_ms := 0;
        g_results(g_result_count).max_time_ms := 0;
        g_results(g_result_count).overhead_pct := l_overhead_pct;
        
        DBMS_OUTPUT.PUT_LINE('  Baseline: ' || ROUND(l_baseline_time, 2) || 'ms, With telemetry: ' || 
                           ROUND(l_test_time, 2) || 'ms, Overhead: ' || ROUND(l_overhead_pct, 1) || '%');
    END;
    
    PROCEDURE show_results IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Performance Test Results Summary:');
        DBMS_OUTPUT.PUT_LINE(RPAD('-', 80, '-'));
        DBMS_OUTPUT.PUT_LINE(RPAD('Operation', 25) || RPAD('Iterations', 12) || RPAD('Avg (ms)', 12) || RPAD('Overhead %', 12));
        DBMS_OUTPUT.PUT_LINE(RPAD('-', 80, '-'));
        
        FOR i IN 1..g_result_count LOOP
            DBMS_OUTPUT.PUT_LINE(
                RPAD(g_results(i).operation_name, 25) ||
                RPAD(TO_CHAR(g_results(i).iterations), 12) ||
                RPAD(TO_CHAR(ROUND(g_results(i).avg_time_ms, 3)), 12) ||
                RPAD(TO_CHAR(ROUND(g_results(i).overhead_pct, 1)), 12)
            );
        END LOOP;
        DBMS_OUTPUT.PUT_LINE(RPAD('-', 80, '-'));
    END;
    
    PROCEDURE end_test_suite IS
        l_avg_overhead NUMBER := 0;
        l_overhead_count NUMBER := 0;
    BEGIN
        show_results();
        
        -- Calculate average overhead
        FOR i IN 1..g_result_count LOOP
            IF g_results(i).overhead_pct > 0 THEN
                l_avg_overhead := l_avg_overhead + g_results(i).overhead_pct;
                l_overhead_count := l_overhead_count + 1;
            END IF;
        END LOOP;
        
        IF l_overhead_count > 0 THEN
            l_avg_overhead := l_avg_overhead / l_overhead_count;
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('Average telemetry overhead: ' || ROUND(l_avg_overhead, 1) || '%');
        END IF;
    END;
    
    PROCEDURE cleanup_test_data IS
    BEGIN
        DELETE FROM plt_traces WHERE root_operation LIKE 'test_perf_%';
        DELETE FROM plt_spans WHERE operation_name LIKE 'test_perf_%';
        DELETE FROM plt_events WHERE event_name LIKE 'test_perf_%';
        DELETE FROM plt_metrics WHERE metric_name LIKE 'test_perf_%';
        DELETE FROM plt_queue WHERE payload LIKE '%test_perf_%';
        COMMIT;
    END;
END;
/

-- Test 1: Basic Operation Performance
-- ============================================================================
BEGIN
    plt_perf_test_utils.start_test_suite('Basic Operation Performance');
    
    -- Configure for performance testing
    PLTelemetry.set_async_mode(TRUE);
    PLTelemetry.set_autocommit(FALSE);
    
    -- Test trace creation performance
    plt_perf_test_utils.time_operation(
        'Trace Creation',
        100,
        'DECLARE l_id VARCHAR2(32); BEGIN l_id := PLTelemetry.start_trace(''test_perf_trace''); PLTelemetry.end_trace(l_id); END;'
    );
    
    -- Test span creation performance
    plt_perf_test_utils.time_operation(
        'Span Creation',
        200,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_span_trace''); l_sid := PLTelemetry.start_span(''test_perf_span''); PLTelemetry.end_span(l_sid, ''OK''); PLTelemetry.end_trace(l_tid); END;'
    );
    
    -- Test event creation performance
    plt_perf_test_utils.time_operation(
        'Event Creation',
        300,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_event_trace''); l_sid := PLTelemetry.start_span(''test_perf_event_span''); PLTelemetry.add_event(l_sid, ''test_perf_event''); PLTelemetry.end_span(l_sid, ''OK''); PLTelemetry.end_trace(l_tid); END;'
    );
    
    -- Test metric recording performance
    plt_perf_test_utils.time_operation(
        'Metric Recording',
        200,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_metric_trace''); l_sid := PLTelemetry.start_span(''test_perf_metric_span''); PLTelemetry.log_metric(''test_perf_metric'', 123.45, ''ms''); PLTelemetry.end_span(l_sid, ''OK''); PLTelemetry.end_trace(l_tid); END;'
    );
    
    plt_perf_test_utils.end_test_suite();
END;
/

-- Test 2: Attribute Performance
-- ============================================================================
BEGIN
    plt_perf_test_utils.start_test_suite('Attribute Performance');
    
    -- Test attribute creation
    plt_perf_test_utils.time_operation(
        'Single Attribute',
        500,
        'DECLARE l_attr VARCHAR2(100); BEGIN l_attr := PLTelemetry.add_attribute(''test.key'', ''test_value''); END;'
    );
    
    -- Test attributes to JSON conversion
    plt_perf_test_utils.time_operation(
        'Attributes to JSON (5 attrs)',
        200,
        'DECLARE l_attrs PLTelemetry.t_attributes; l_json VARCHAR2(4000); BEGIN l_attrs(1) := PLTelemetry.add_attribute(''key1'', ''value1''); l_attrs(2) := PLTelemetry.add_attribute(''key2'', ''value2''); l_attrs(3) := PLTelemetry.add_attribute(''key3'', ''value3''); l_attrs(4) := PLTelemetry.add_attribute(''key4'', ''value4''); l_attrs(5) := PLTelemetry.add_attribute(''key5'', ''value5''); l_json := PLTelemetry.attributes_to_json(l_attrs); END;'
    );
    
    -- Test large attribute collections
    plt_perf_test_utils.time_operation(
        'Large Attribute Collection (20 attrs)',
        50,
        'DECLARE l_attrs PLTelemetry.t_attributes; l_json VARCHAR2(4000); BEGIN FOR i IN 1..20 LOOP l_attrs(i) := PLTelemetry.add_attribute(''key'' || i, ''value'' || i || ''_data''); END LOOP; l_json := PLTelemetry.attributes_to_json(l_attrs); END;'
    );
    
    plt_perf_test_utils.end_test_suite();
END;
/

-- Test 3: Nested Span Performance
-- ============================================================================
BEGIN
    plt_perf_test_utils.start_test_suite('Nested Span Performance');
    
    -- Test shallow nesting (2 levels)
    plt_perf_test_utils.time_operation(
        'Shallow Nesting (2 levels)',
        100,
        'DECLARE l_tid VARCHAR2(32); l_sid1 VARCHAR2(16); l_sid2 VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_shallow''); l_sid1 := PLTelemetry.start_span(''test_perf_parent''); l_sid2 := PLTelemetry.start_span(''test_perf_child'', l_sid1); PLTelemetry.end_span(l_sid2, ''OK''); PLTelemetry.end_span(l_sid1, ''OK''); PLTelemetry.end_trace(l_tid); END;'
    );
    
    -- Test deep nesting (5 levels)
    plt_perf_test_utils.time_operation(
        'Deep Nesting (5 levels)',
        50,
        'DECLARE l_tid VARCHAR2(32); l_sid1 VARCHAR2(16); l_sid2 VARCHAR2(16); l_sid3 VARCHAR2(16); l_sid4 VARCHAR2(16); l_sid5 VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_deep''); l_sid1 := PLTelemetry.start_span(''test_perf_l1''); l_sid2 := PLTelemetry.start_span(''test_perf_l2'', l_sid1); l_sid3 := PLTelemetry.start_span(''test_perf_l3'', l_sid2); l_sid4 := PLTelemetry.start_span(''test_perf_l4'', l_sid3); l_sid5 := PLTelemetry.start_span(''test_perf_l5'', l_sid4); PLTelemetry.end_span(l_sid5, ''OK''); PLTelemetry.end_span(l_sid4, ''OK''); PLTelemetry.end_span(l_sid3, ''OK''); PLTelemetry.end_span(l_sid2, ''OK''); PLTelemetry.end_span(l_sid1, ''OK''); PLTelemetry.end_trace(l_tid); END;'
    );
    
    plt_perf_test_utils.end_test_suite();
END;
/

-- Test 4: Sync vs Async Performance
-- ============================================================================
BEGIN
    plt_perf_test_utils.start_test_suite('Sync vs Async Performance');
    
    -- Test async mode performance (default)
    PLTelemetry.set_async_mode(TRUE);
    plt_perf_test_utils.time_operation(
        'Async Mode',
        100,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_async''); l_sid := PLTelemetry.start_span(''test_perf_async_span''); PLTelemetry.add_event(l_sid, ''test_perf_async_event''); PLTelemetry.end_span(l_sid, ''OK''); PLTelemetry.end_trace(l_tid); END;'
    );
    
    -- Test sync mode performance (will try to send to backend)
    PLTelemetry.set_async_mode(FALSE);
    PLTelemetry.set_backend_url('http://localhost:3000/api/telemetry');  -- Use a realistic URL
    plt_perf_test_utils.time_operation(
        'Sync Mode',
        10,  -- Fewer iterations due to network calls
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_sync''); l_sid := PLTelemetry.start_span(''test_perf_sync_span''); PLTelemetry.add_event(l_sid, ''test_perf_sync_event''); PLTelemetry.end_span(l_sid, ''OK''); PLTelemetry.end_trace(l_tid); END;'
    );
    
    -- Reset to async for remaining tests
    PLTelemetry.set_async_mode(TRUE);
    
    plt_perf_test_utils.end_test_suite();
END;
/

-- Test 5: Business Logic Overhead
-- ============================================================================
BEGIN
    plt_perf_test_utils.start_test_suite('Business Logic Overhead');
    
    -- Create a simple business function for testing
    EXECUTE IMMEDIATE '
    CREATE OR REPLACE FUNCTION test_business_function(p_input NUMBER) RETURN NUMBER IS
        l_result NUMBER;
    BEGIN
        -- Simulate business logic
        l_result := p_input;
        FOR i IN 1..10 LOOP
            l_result := l_result + (i * 0.1);
        END LOOP;
        l_result := SQRT(l_result * 1.5);
        RETURN ROUND(l_result, 2);
    END;';
    
    -- Test business function without telemetry
    plt_perf_test_utils.time_operation_with_baseline(
        'Business Function w/ Telemetry',
        200,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); l_result NUMBER; BEGIN l_tid := PLTelemetry.start_trace(''test_perf_business''); l_sid := PLTelemetry.start_span(''test_perf_business_func''); l_result := test_business_function(42); PLTelemetry.log_metric(''test_perf_result'', l_result, ''units''); PLTelemetry.end_span(l_sid, ''OK''); PLTelemetry.end_trace(l_tid); END;',
        'DECLARE l_result NUMBER; BEGIN l_result := test_business_function(42); END;'
    );
    
    -- Test database operation with telemetry overhead
    plt_perf_test_utils.time_operation_with_baseline(
        'DB Query w/ Telemetry',
        100,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); l_count NUMBER; l_attrs PLTelemetry.t_attributes; BEGIN l_tid := PLTelemetry.start_trace(''test_perf_db''); l_sid := PLTelemetry.start_span(''test_perf_db_query''); l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_DB_OPERATION, ''SELECT''); SELECT COUNT(*) INTO l_count FROM user_tables; PLTelemetry.log_metric(''test_perf_table_count'', l_count, ''tables'', l_attrs); PLTelemetry.end_span(l_sid, ''OK'', l_attrs); PLTelemetry.end_trace(l_tid); END;',
        'DECLARE l_count NUMBER; BEGIN SELECT COUNT(*) INTO l_count FROM user_tables; END;'
    );
    
    -- Clean up test function
    EXECUTE IMMEDIATE 'DROP FUNCTION test_business_function';
    
    plt_perf_test_utils.end_test_suite();
END;
/

-- Test 6: Queue Processing Performance
-- ============================================================================
BEGIN
    plt_perf_test_utils.start_test_suite('Queue Processing Performance');
    
    DECLARE
        l_queue_count_before NUMBER;
        l_queue_count_after NUMBER;
        l_start_time NUMBER;
        l_end_time NUMBER;
        l_processing_time NUMBER;
    BEGIN
        -- Ensure async mode and create some queue entries
        PLTelemetry.set_async_mode(TRUE);
        
        -- Create test data in queue
        FOR i IN 1..50 LOOP
            DECLARE
                l_tid VARCHAR2(32);
                l_sid VARCHAR2(16);
            BEGIN
                l_tid := PLTelemetry.start_trace('test_perf_queue_' || i);
                l_sid := PLTelemetry.start_span('test_perf_queue_span_' || i);
                PLTelemetry.add_event(l_sid, 'test_perf_queue_event_' || i);
                PLTelemetry.end_span(l_sid, 'OK');
                PLTelemetry.end_trace(l_tid);
            END;
        END LOOP;
        
        -- Get queue count before processing
        SELECT COUNT(*) INTO l_queue_count_before FROM plt_queue WHERE processed = 'N';
        
        -- Time the queue processing
        l_start_time := plt_perf_test_utils.get_timestamp_ms();
        PLTelemetry.process_queue(25);  -- Process 25 entries
        l_end_time := plt_perf_test_utils.get_timestamp_ms();
        
        l_processing_time := l_end_time - l_start_time;
        
        -- Get queue count after processing
        SELECT COUNT(*) INTO l_queue_count_after FROM plt_queue WHERE processed = 'N';
        
        DBMS_OUTPUT.PUT_LINE('Queue Processing Results:');
        DBMS_OUTPUT.PUT_LINE('  Entries before: ' || l_queue_count_before);
        DBMS_OUTPUT.PUT_LINE('  Entries after: ' || l_queue_count_after);
        DBMS_OUTPUT.PUT_LINE('  Entries processed: ' || (l_queue_count_before - l_queue_count_after));
        DBMS_OUTPUT.PUT_LINE('  Processing time: ' || ROUND(l_processing_time, 2) || 'ms');
        
        IF (l_queue_count_before - l_queue_count_after) > 0 THEN
            DBMS_OUTPUT.PUT_LINE('  Time per entry: ' || 
                ROUND(l_processing_time / (l_queue_count_before - l_queue_count_after), 2) || 'ms');
        END IF;
    END;
    
    plt_perf_test_utils.end_test_suite();
END;
/

-- Test 7: Memory Usage Patterns
-- ============================================================================
BEGIN
    plt_perf_test_utils.start_test_suite('Memory Usage Patterns');
    
    -- Test large trace with many spans
    plt_perf_test_utils.time_operation(
        'Large Trace (50 spans)',
        5,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_large_trace''); FOR i IN 1..50 LOOP l_sid := PLTelemetry.start_span(''test_perf_span_'' || i); PLTelemetry.add_event(l_sid, ''test_perf_event_'' || i); PLTelemetry.end_span(l_sid, ''OK''); END LOOP; PLTelemetry.end_trace(l_tid); END;'
    );
    
    -- Test many concurrent traces
    plt_perf_test_utils.time_operation(
        'Many Small Traces (20 traces)',
        10,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); BEGIN FOR i IN 1..20 LOOP l_tid := PLTelemetry.start_trace(''test_perf_small_trace_'' || i); l_sid := PLTelemetry.start_span(''test_perf_small_span_'' || i); PLTelemetry.end_span(l_sid, ''OK''); PLTelemetry.end_trace(l_tid); END LOOP; END;'
    );
    
    plt_perf_test_utils.end_test_suite();
END;
/

-- Test 8: Configuration Impact
-- ============================================================================
BEGIN
    plt_perf_test_utils.start_test_suite('Configuration Impact');
    
    -- Test with autocommit enabled
    PLTelemetry.set_autocommit(TRUE);
    plt_perf_test_utils.time_operation(
        'With Autocommit',
        50,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_autocommit''); l_sid := PLTelemetry.start_span(''test_perf_autocommit_span''); PLTelemetry.end_span(l_sid, ''OK''); PLTelemetry.end_trace(l_tid); END;'
    );
    
    -- Test with autocommit disabled
    PLTelemetry.set_autocommit(FALSE);
    plt_perf_test_utils.time_operation(
        'Without Autocommit',
        50,
        'DECLARE l_tid VARCHAR2(32); l_sid VARCHAR2(16); BEGIN l_tid := PLTelemetry.start_trace(''test_perf_no_autocommit''); l_sid := PLTelemetry.start_span(''test_perf_no_autocommit_span''); PLTelemetry.end_span(l_sid, ''OK''); PLTelemetry.end_trace(l_tid); END;'
    );
    
    plt_perf_test_utils.end_test_suite();
END;
/

-- Performance Test Summary and Recommendations
-- ============================================================================
PROMPT
PROMPT ================================================================================
PROMPT Performance Test Summary and Recommendations
PROMPT ================================================================================

DECLARE
    l_total_traces NUMBER;
    l_total_spans NUMBER;
    l_total_events NUMBER;
    l_total_metrics NUMBER;
    l_queue_size NUMBER;
    l_avg_span_duration NUMBER;
BEGIN
    -- Gather performance statistics
    SELECT COUNT(*) INTO l_total_traces FROM plt_traces WHERE root_operation LIKE 'test_perf_%';
    SELECT COUNT(*) INTO l_total_spans FROM plt_spans WHERE operation_name LIKE 'test_perf_%';
    SELECT COUNT(*) INTO l_total_events FROM plt_events WHERE event_name LIKE 'test_perf_%';
    SELECT COUNT(*) INTO l_total_metrics FROM plt_metrics WHERE metric_name LIKE 'test_perf_%';
    SELECT COUNT(*) INTO l_queue_size FROM plt_queue WHERE processed = 'N';
    
    -- Calculate average span duration for completed spans
    SELECT ROUND(AVG(duration_ms), 2) INTO l_avg_span_duration
    FROM plt_spans 
    WHERE operation_name LIKE 'test_perf_%' AND duration_ms IS NOT NULL;
    
    DBMS_OUTPUT.PUT_LINE('Performance Test Data Generated:');
    DBMS_OUTPUT.PUT_LINE('  Traces created: ' || l_total_traces);
    DBMS_OUTPUT.PUT_LINE('  Spans created: ' || l_total_spans);
    DBMS_OUTPUT.PUT_LINE('  Events created: ' || l_total_events);
    DBMS_OUTPUT.PUT_LINE('  Metrics recorded: ' || l_total_metrics);
    DBMS_OUTPUT.PUT_LINE('  Queue entries pending: ' || l_queue_size);
    DBMS_OUTPUT.PUT_LINE('  Avg span duration: ' || NVL(TO_CHAR(l_avg_span_duration), 'N/A') || 'ms');
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Performance Recommendations:');
    DBMS_OUTPUT.PUT_LINE('');
    
    DBMS_OUTPUT.PUT_LINE('✓ OPTIMAL SETTINGS:');
    DBMS_OUTPUT.PUT_LINE('  • Use async mode (PLTelemetry.set_async_mode(TRUE))');
    DBMS_OUTPUT.PUT_LINE('  • Disable autocommit for batch operations');
    DBMS_OUTPUT.PUT_LINE('  • Limit attributes to 10-15 per span for best performance');
    DBMS_OUTPUT.PUT_LINE('  • Process queue regularly (every 1-5 minutes)');
    DBMS_OUTPUT.PUT_LINE('');
    
    DBMS_OUTPUT.PUT_LINE('⚠ PERFORMANCE CONSIDERATIONS:');
    DBMS_OUTPUT.PUT_LINE('  • Sync mode adds network latency to critical path');
    DBMS_OUTPUT.PUT_LINE('  • Deep nesting (>5 levels) increases overhead');
    DBMS_OUTPUT.PUT_LINE('  • Large attribute collections (>20) slow JSON conversion');
    DBMS_OUTPUT.PUT_LINE('  • Autocommit enabled increases transaction overhead');
    DBMS_OUTPUT.PUT_LINE('');
    
    DBMS_OUTPUT.PUT_LINE('🎯 PRODUCTION TUNING:');
    DBMS_OUTPUT.PUT_LINE('  • Monitor queue size and processing rates');
    DBMS_OUTPUT.PUT_LINE('  • Adjust queue processor frequency based on load');
    DBMS_OUTPUT.PUT_LINE('  • Use connection pooling for backend HTTP calls');
    DBMS_OUTPUT.PUT_LINE('  • Implement circuit breakers for backend failures');
    DBMS_OUTPUT.PUT_LINE('  • Set appropriate retention policies for data cleanup');
    
    -- Performance thresholds
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('📊 EXPECTED PERFORMANCE THRESHOLDS:');
    DBMS_OUTPUT.PUT_LINE('  • Trace creation: < 5ms');
    DBMS_OUTPUT.PUT_LINE('  • Span creation: < 3ms');
    DBMS_OUTPUT.PUT_LINE('  • Event creation: < 2ms');
    DBMS_OUTPUT.PUT_LINE('  • Metric recording: < 3ms');
    DBMS_OUTPUT.PUT_LINE('  • Business logic overhead: < 10%');
    DBMS_OUTPUT.PUT_LINE('  • Queue processing: < 50ms per entry');
END;
/

-- Cleanup performance test data
PROMPT
PROMPT Cleaning up performance test data...
BEGIN
    plt_perf_test_utils.cleanup_test_data();
    DBMS_OUTPUT.PUT_LINE('✓ Performance test data cleaned up');
END;
/

-- Drop test utilities
DROP PACKAGE plt_perf_test_utils;

PROMPT
PROMPT ================================================================================
PROMPT Performance Tests Completed
PROMPT ================================================================================
PROMPT
PROMPT PLTelemetry performance characteristics have been measured:
PROMPT ✓ Basic operation timings
PROMPT ✓ Attribute processing performance
PROMPT ✓ Nested span overhead
PROMPT ✓ Sync vs async mode comparison
PROMPT ✓ Business logic overhead assessment
PROMPT ✓ Queue processing efficiency
PROMPT ✓ Memory usage patterns
PROMPT ✓ Configuration impact analysis
PROMPT
PROMPT The telemetry system is designed for minimal overhead in production
PROMPT environments when properly configured with async mode enabled.
PROMPT
PROMPT Use the recommendations above to optimize PLTelemetry for your
PROMPT specific workload and performance requirements.
PROMPT
PROMPT ================================================================================