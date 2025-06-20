-- PLTelemetry Basic Usage Examples
-- This file contains simple examples to get started with PLTelemetry
-- Run these examples after installing PLTelemetry to verify functionality

PROMPT ================================================================================
PROMPT PLTelemetry Basic Usage Examples
PROMPT ================================================================================

-- First, configure PLTelemetry (adjust URLs and keys for your environment)
BEGIN
    -- Set your backend endpoint
    PLTelemetry.set_backend_url('http://localhost:3000/api/telemetry');
    
    -- Set API key for authentication
    PLTelemetry.set_api_key('your-secret-api-key');
    
    -- Enable async mode for better performance
    PLTelemetry.set_async_mode(TRUE);
    
    DBMS_OUTPUT.PUT_LINE('PLTelemetry configured successfully');
END;
/

-- Example 1: Simple trace with single span
-- ============================================================================
PROMPT
PROMPT Example 1: Simple trace with single span
PROMPT ============================================================================

DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
BEGIN
    -- Start a new trace
    l_trace_id := PLTelemetry.start_trace('simple_example');
    DBMS_OUTPUT.PUT_LINE('Started trace: ' || l_trace_id);
    
    -- Start a span
    l_span_id := PLTelemetry.start_span('do_work');
    DBMS_OUTPUT.PUT_LINE('Started span: ' || l_span_id);
    
    -- Simulate some work
    DBMS_LOCK.SLEEP(1);  -- Sleep for 1 second
    
    -- End the span
    PLTelemetry.end_span(l_span_id, 'OK');
    DBMS_OUTPUT.PUT_LINE('Ended span: ' || l_span_id);
    
    -- End the trace
    PLTelemetry.end_trace(l_trace_id);
    DBMS_OUTPUT.PUT_LINE('Ended trace: ' || l_trace_id);
END;
/

-- Example 2: Adding attributes to spans
-- ============================================================================
PROMPT
PROMPT Example 2: Adding attributes to spans
PROMPT ============================================================================

DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    l_trace_id := PLTelemetry.start_trace('example_with_attributes');
    l_span_id := PLTelemetry.start_span('process_customer');
    
    -- Create attributes
    l_attrs(1) := PLTelemetry.add_attribute('customer.id', '12345');
    l_attrs(2) := PLTelemetry.add_attribute('customer.tier', 'PREMIUM');
    l_attrs(3) := PLTelemetry.add_attribute('process.type', 'verification');
    
    -- Do some work
    DBMS_LOCK.SLEEP(0.5);
    
    -- End span with attributes
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('Completed trace with attributes');
END;
/

-- Example 3: Adding events to spans
-- ============================================================================
PROMPT
PROMPT Example 3: Adding events to spans  
PROMPT ============================================================================

DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    l_trace_id := PLTelemetry.start_trace('example_with_events');
    l_span_id := PLTelemetry.start_span('order_processing');
    
    -- Add start event
    PLTelemetry.add_event(l_span_id, 'order_received');
    
    -- Simulate validation step
    DBMS_LOCK.SLEEP(0.3);
    l_attrs(1) := PLTelemetry.add_attribute('validation.status', 'passed');
    PLTelemetry.add_event(l_span_id, 'order_validated', l_attrs);
    
    -- Simulate processing step
    DBMS_LOCK.SLEEP(0.5);
    l_attrs.DELETE;
    l_attrs(1) := PLTelemetry.add_attribute('items.count', '3');
    PLTelemetry.add_event(l_span_id, 'items_processed', l_attrs);
    
    -- Add completion event
    PLTelemetry.add_event(l_span_id, 'order_completed');
    
    PLTelemetry.end_span(l_span_id, 'OK');
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('Completed trace with events');
END;
/

-- Example 4: Recording metrics
-- ============================================================================
PROMPT
PROMPT Example 4: Recording metrics
PROMPT ============================================================================

DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    l_trace_id := PLTelemetry.start_trace('example_with_metrics');
    l_span_id := PLTelemetry.start_span('calculate_totals');
    
    -- Set up attributes for metrics
    l_attrs(1) := PLTelemetry.add_attribute('currency', 'EUR');
    l_attrs(2) := PLTelemetry.add_attribute('region', 'EMEA');
    
    -- Record various metrics
    PLTelemetry.log_metric('order_total', 299.99, 'EUR', l_attrs);
    PLTelemetry.log_metric('processing_time', 1.25, 'seconds', l_attrs);
    PLTelemetry.log_metric('items_count', 5, 'items', l_attrs);
    
    PLTelemetry.end_span(l_span_id, 'OK');
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('Completed trace with metrics');
END;
/

-- Example 5: Nested spans (parent-child relationship)
-- ============================================================================
PROMPT
PROMPT Example 5: Nested spans (parent-child relationship)
PROMPT ============================================================================

DECLARE
    l_trace_id     VARCHAR2(32);
    l_parent_span  VARCHAR2(16);
    l_child_span1  VARCHAR2(16);
    l_child_span2  VARCHAR2(16);
    l_attrs        PLTelemetry.t_attributes;
BEGIN
    l_trace_id := PLTelemetry.start_trace('nested_spans_example');
    
    -- Parent span
    l_parent_span := PLTelemetry.start_span('process_order');
    PLTelemetry.add_event(l_parent_span, 'order_processing_started');
    
    -- First child span
    l_child_span1 := PLTelemetry.start_span('validate_payment', l_parent_span);
    DBMS_LOCK.SLEEP(0.3);
    l_attrs(1) := PLTelemetry.add_attribute('payment.method', 'credit_card');
    PLTelemetry.end_span(l_child_span1, 'OK', l_attrs);
    
    -- Second child span
    l_child_span2 := PLTelemetry.start_span('update_inventory', l_parent_span);
    DBMS_LOCK.SLEEP(0.4);
    l_attrs.DELETE;
    l_attrs(1) := PLTelemetry.add_attribute('inventory.updated_items', '3');
    PLTelemetry.end_span(l_child_span2, 'OK', l_attrs);
    
    -- Complete parent span
    PLTelemetry.add_event(l_parent_span, 'order_processing_completed');
    PLTelemetry.end_span(l_parent_span, 'OK');
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('Completed nested spans example');
END;
/

-- Example 6: Using semantic conventions
-- ============================================================================
PROMPT
PROMPT Example 6: Using OpenTelemetry semantic conventions
PROMPT ============================================================================

DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    l_trace_id := PLTelemetry.start_trace('semantic_conventions_example');
    l_span_id := PLTelemetry.start_span('database_query');
    
    -- Use standard OpenTelemetry semantic conventions
    l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_DB_OPERATION, 'SELECT');
    l_attrs(2) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_DB_STATEMENT, 'SELECT * FROM customers WHERE status = ?');
    l_attrs(3) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_USER_ID, 'user123');
    
    -- Simulate database query
    DBMS_LOCK.SLEEP(0.2);
    
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('Completed semantic conventions example');
END;
/

-- Example 7: Simple function instrumentation
-- ============================================================================
PROMPT
PROMPT Example 7: Simple function instrumentation
PROMPT ============================================================================

CREATE OR REPLACE FUNCTION calculate_discount_example(
    p_customer_tier VARCHAR2,
    p_order_total   NUMBER
) RETURN NUMBER
IS
    l_span_id   VARCHAR2(16);
    l_attrs     PLTelemetry.t_attributes;
    l_discount  NUMBER;
BEGIN
    -- Start span within existing trace context
    l_span_id := PLTelemetry.start_span('calculate_discount');
    
    -- Add input parameters as attributes
    l_attrs(1) := PLTelemetry.add_attribute('customer.tier', p_customer_tier);
    l_attrs(2) := PLTelemetry.add_attribute('order.total', TO_CHAR(p_order_total));
    
    -- Business logic
    CASE p_customer_tier
        WHEN 'PREMIUM' THEN l_discount := p_order_total * 0.15;
        WHEN 'GOLD' THEN l_discount := p_order_total * 0.10;
        WHEN 'SILVER' THEN l_discount := p_order_total * 0.05;
        ELSE l_discount := 0;
    END CASE;
    
    -- Add result as attribute
    l_attrs(3) := PLTelemetry.add_attribute('discount.amount', TO_CHAR(l_discount));
    
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    
    RETURN l_discount;
END;
/

-- Test the instrumented function
DECLARE
    l_trace_id VARCHAR2(32);
    l_discount NUMBER;
BEGIN
    l_trace_id := PLTelemetry.start_trace('test_function_instrumentation');
    
    l_discount := calculate_discount_example('PREMIUM', 200.00);
    
    DBMS_OUTPUT.PUT_LINE('Calculated discount: ' || l_discount);
    
    PLTelemetry.end_trace(l_trace_id);
END;
/

-- Example 8: Configuration and status check
-- ============================================================================
PROMPT
PROMPT Example 8: Configuration and status check
PROMPT ============================================================================

DECLARE
    l_backend_url VARCHAR2(500);
    l_autocommit  BOOLEAN;
    l_current_trace VARCHAR2(32);
    l_current_span VARCHAR2(16);
BEGIN
    -- Check current configuration
    l_backend_url := PLTelemetry.get_backend_url();
    l_autocommit := PLTelemetry.get_autocommit();
    l_current_trace := PLTelemetry.get_current_trace_id();
    l_current_span := PLTelemetry.get_current_span_id();
    
    DBMS_OUTPUT.PUT_LINE('Current Configuration:');
    DBMS_OUTPUT.PUT_LINE('  Backend URL: ' || NVL(l_backend_url, 'NOT SET'));
    DBMS_OUTPUT.PUT_LINE('  Autocommit: ' || CASE WHEN l_autocommit THEN 'TRUE' ELSE 'FALSE' END);
    DBMS_OUTPUT.PUT_LINE('  Current Trace: ' || NVL(l_current_trace, 'NONE'));
    DBMS_OUTPUT.PUT_LINE('  Current Span: ' || NVL(l_current_span, 'NONE'));
END;
/

-- Check queue status
PROMPT
PROMPT Queue Status:
SELECT 
    COUNT(*) as total_entries,
    SUM(CASE WHEN processed = 'N' THEN 1 ELSE 0 END) as pending,
    SUM(CASE WHEN processed = 'Y' THEN 1 ELSE 0 END) as processed,
    SUM(CASE WHEN process_attempts >= 3 THEN 1 ELSE 0 END) as failed
FROM plt_queue;

-- Check recent activity
PROMPT
PROMPT Recent Traces (last 10):
SELECT 
    trace_id,
    root_operation,
    start_time,
    end_time,
    CASE 
        WHEN end_time IS NOT NULL THEN 
            EXTRACT(SECOND FROM (end_time - start_time)) * 1000
        ELSE NULL 
    END as duration_ms
FROM plt_traces
ORDER BY start_time DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT ================================================================================
PROMPT Basic Usage Examples Completed
PROMPT ================================================================================
PROMPT
PROMPT Next steps:
PROMPT 1. Check the queue processing: SELECT * FROM plt_queue WHERE processed = 'N';
PROMPT 2. Monitor for errors: SELECT * FROM plt_telemetry_errors ORDER BY error_time DESC;
PROMPT 3. Try the advanced examples in advanced_examples.sql
PROMPT 4. Integrate with your existing procedures and functions
PROMPT
PROMPT ================================================================================