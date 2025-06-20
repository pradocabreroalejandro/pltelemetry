-- PLTelemetry ORDS Integration Examples
-- This file demonstrates how to integrate PLTelemetry with Oracle REST Data Services (ORDS)
-- for distributed tracing across Angular -> ORDS -> Oracle -> Tauri workflows

PROMPT ================================================================================
PROMPT PLTelemetry ORDS Integration Examples
PROMPT ================================================================================

-- Example 1: Basic ORDS REST endpoint with telemetry
-- ============================================================================
PROMPT
PROMPT Example 1: Basic ORDS REST endpoint with telemetry
PROMPT ============================================================================

CREATE OR REPLACE PROCEDURE ords_get_customer(
    p_customer_id   IN  NUMBER,
    p_trace_id      IN  VARCHAR2 DEFAULT NULL,  -- From HTTP header X-Trace-Id
    p_span_id       IN  VARCHAR2 DEFAULT NULL,  -- From HTTP header X-Parent-Span-Id
    p_user_id       IN  VARCHAR2 DEFAULT NULL   -- From JWT or session
) 
IS
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
    l_customer_name VARCHAR2(100);
BEGIN
    -- Continue existing trace or start new one
    IF p_trace_id IS NOT NULL THEN
        PLTelemetry.g_current_trace_id := p_trace_id;
        l_trace_id := p_trace_id;
    ELSE
        l_trace_id := PLTelemetry.start_trace('ords_get_customer');
    END IF;
    
    -- Start ORDS span
    l_span_id := PLTelemetry.start_span('ords_get_customer', p_span_id, l_trace_id);
    
    -- Add HTTP semantic attributes
    l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_METHOD, 'GET');
    l_attrs(2) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_URL, '/ords/api/v1/customers/' || p_customer_id);
    l_attrs(3) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_USER_ID, NVL(p_user_id, 'anonymous'));
    l_attrs(4) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
    
    PLTelemetry.add_event(l_span_id, 'ords_request_started', l_attrs);
    
    -- Database operation with nested span
    DECLARE
        l_db_span VARCHAR2(16);
    BEGIN
        l_db_span := PLTelemetry.start_span('query_customer_data', l_span_id);
        
        l_attrs(5) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_DB_OPERATION, 'SELECT');
        l_attrs(6) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_DB_STATEMENT, 'SELECT name FROM customers WHERE id = ?');
        
        -- Simulate database query
        BEGIN
            SELECT name INTO l_customer_name 
            FROM customers 
            WHERE customer_id = p_customer_id;
            
            l_attrs(7) := PLTelemetry.add_attribute('customer.name', l_customer_name);
            l_attrs(8) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_STATUS, '200');
            
            PLTelemetry.add_event(l_db_span, 'customer_found', l_attrs);
            PLTelemetry.end_span(l_db_span, 'OK', l_attrs);
            
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                l_attrs(7) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_STATUS, '404');
                l_attrs(8) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, 'Customer not found');
                
                PLTelemetry.add_event(l_db_span, 'customer_not_found', l_attrs);
                PLTelemetry.end_span(l_db_span, 'ERROR', l_attrs);
                
                PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
                IF p_trace_id IS NULL THEN PLTelemetry.end_trace(l_trace_id); END IF;
                
                RAISE_APPLICATION_ERROR(-20404, 'Customer not found');
        END;
    END;
    
    -- Complete ORDS span
    PLTelemetry.add_event(l_span_id, 'ords_response_ready', l_attrs);
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    
    -- Record API metric
    PLTelemetry.log_metric('api_request_count', 1, 'requests', l_attrs);
    
    -- Only end trace if we started it
    IF p_trace_id IS NULL THEN
        PLTelemetry.end_trace(l_trace_id);
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        l_attrs(7) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_STATUS, '500');
        l_attrs(8) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SUBSTR(SQLERRM, 1, 500));
        
        PLTelemetry.add_event(l_span_id, 'ords_error', l_attrs);
        PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
        PLTelemetry.log_metric('api_error_count', 1, 'errors', l_attrs);
        
        IF p_trace_id IS NULL THEN PLTelemetry.end_trace(l_trace_id); END IF;
        RAISE;
END;
/

-- Example 2: ORDS POST endpoint for order creation
-- ============================================================================
PROMPT
PROMPT Example 2: ORDS POST endpoint for order creation
PROMPT ============================================================================

CREATE OR REPLACE PROCEDURE ords_create_order(
    p_customer_id   IN  NUMBER,
    p_items         IN  VARCHAR2,  -- JSON array of items
    p_total_amount  IN  NUMBER,
    p_trace_id      IN  VARCHAR2 DEFAULT NULL,
    p_span_id       IN  VARCHAR2 DEFAULT NULL,
    p_user_id       IN  VARCHAR2 DEFAULT NULL,
    p_order_id      OUT NUMBER
)
IS
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
    l_validation_span VARCHAR2(16);
    l_create_span VARCHAR2(16);
    l_inventory_span VARCHAR2(16);
BEGIN
    -- Setup tracing context
    IF p_trace_id IS NOT NULL THEN
        PLTelemetry.g_current_trace_id := p_trace_id;
        l_trace_id := p_trace_id;
    ELSE
        l_trace_id := PLTelemetry.start_trace('ords_create_order');
    END IF;
    
    l_span_id := PLTelemetry.start_span('ords_create_order', p_span_id, l_trace_id);
    
    -- Setup base attributes
    l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_METHOD, 'POST');
    l_attrs(2) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_URL, '/ords/api/v1/orders');
    l_attrs(3) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_USER_ID, NVL(p_user_id, 'anonymous'));
    l_attrs(4) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
    l_attrs(5) := PLTelemetry.add_attribute('order.total_amount', TO_CHAR(p_total_amount));
    
    PLTelemetry.add_event(l_span_id, 'order_creation_started', l_attrs);
    
    -- Step 1: Validation
    l_validation_span := PLTelemetry.start_span('validate_order_request', l_span_id);
    BEGIN
        -- Validate customer exists
        DECLARE
            l_customer_count NUMBER;
        BEGIN
            SELECT COUNT(*) INTO l_customer_count 
            FROM customers 
            WHERE customer_id = p_customer_id AND status = 'ACTIVE';
            
            IF l_customer_count = 0 THEN
                RAISE_APPLICATION_ERROR(-20400, 'Invalid or inactive customer');
            END IF;
        END;
        
        -- Validate order total
        IF p_total_amount <= 0 THEN
            RAISE_APPLICATION_ERROR(-20400, 'Invalid order total');
        END IF;
        
        PLTelemetry.add_event(l_validation_span, 'validation_passed');
        PLTelemetry.end_span(l_validation_span, 'OK');
        
    EXCEPTION
        WHEN OTHERS THEN
            l_attrs(6) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
            PLTelemetry.end_span(l_validation_span, 'ERROR', l_attrs);
            RAISE;
    END;
    
    -- Step 2: Check inventory
    l_inventory_span := PLTelemetry.start_span('check_inventory', l_span_id);
    BEGIN
        -- Simulate inventory check
        DBMS_LOCK.SLEEP(0.1);
        
        l_attrs(6) := PLTelemetry.add_attribute('inventory.check_result', 'sufficient');
        PLTelemetry.add_event(l_inventory_span, 'inventory_checked', l_attrs);
        PLTelemetry.end_span(l_inventory_span, 'OK', l_attrs);
        
    EXCEPTION
        WHEN OTHERS THEN
            l_attrs(6) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, 'Insufficient inventory');
            PLTelemetry.end_span(l_inventory_span, 'ERROR', l_attrs);
            RAISE;
    END;
    
    -- Step 3: Create order
    l_create_span := PLTelemetry.start_span('create_order_record', l_span_id);
    BEGIN
        -- Generate order ID (simplified)
        SELECT order_seq.NEXTVAL INTO p_order_id FROM DUAL;
        
        -- Insert order (simplified)
        INSERT INTO orders (order_id, customer_id, total_amount, status, created_date)
        VALUES (p_order_id, p_customer_id, p_total_amount, 'PENDING', SYSDATE);
        
        l_attrs(6) := PLTelemetry.add_attribute('order.id', TO_CHAR(p_order_id));
        l_attrs(7) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_DB_OPERATION, 'INSERT');
        
        PLTelemetry.add_event(l_create_span, 'order_created', l_attrs);
        PLTelemetry.end_span(l_create_span, 'OK', l_attrs);
        
    EXCEPTION
        WHEN OTHERS THEN
            l_attrs(6) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
            PLTelemetry.end_span(l_create_span, 'ERROR', l_attrs);
            RAISE;
    END;
    
    -- Complete main span
    l_attrs(8) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_STATUS, '201');
    PLTelemetry.add_event(l_span_id, 'order_creation_completed', l_attrs);
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    
    -- Record metrics
    PLTelemetry.log_metric('orders_created', 1, 'orders', l_attrs);
    PLTelemetry.log_metric('order_value', p_total_amount, 'EUR', l_attrs);
    
    IF p_trace_id IS NULL THEN PLTelemetry.end_trace(l_trace_id); END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        l_attrs(8) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_STATUS, '500');
        l_attrs(9) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SUBSTR(SQLERRM, 1, 500));
        
        PLTelemetry.add_event(l_span_id, 'order_creation_failed', l_attrs);
        PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
        PLTelemetry.log_metric('order_creation_errors', 1, 'errors', l_attrs);
        
        IF p_trace_id IS NULL THEN PLTelemetry.end_trace(l_trace_id); END IF;
        RAISE;
END;
/

-- Example 3: ORDS procedure for distributed trace propagation
-- ============================================================================
PROMPT
PROMPT Example 3: ORDS trace context extraction helper
PROMPT ============================================================================

CREATE OR REPLACE FUNCTION extract_trace_context(
    p_http_headers IN VARCHAR2  -- JSON string of HTTP headers
) RETURN VARCHAR2  -- Returns trace_id
IS
    l_trace_id VARCHAR2(32);
    l_traceparent VARCHAR2(100);
BEGIN
    -- Extract W3C traceparent header if available
    -- Format: 00-{trace-id}-{parent-id}-{trace-flags}
    BEGIN
        SELECT JSON_VALUE(p_http_headers, '$.traceparent') 
        INTO l_traceparent 
        FROM DUAL;
        
        IF l_traceparent IS NOT NULL THEN
            -- Extract trace ID from traceparent
            l_trace_id := SUBSTR(l_traceparent, 4, 32);  -- Skip version and hyphen
            RETURN l_trace_id;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Continue to fallback
    END;
    
    -- Fallback: Extract custom X-Trace-Id header
    BEGIN
        SELECT JSON_VALUE(p_http_headers, '$."x-trace-id"') 
        INTO l_trace_id 
        FROM DUAL;
        
        IF l_trace_id IS NOT NULL THEN
            RETURN l_trace_id;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;
    
    -- No trace context found
    RETURN NULL;
END;
/

-- Example 4: Complete ORDS workflow with trace propagation
-- ============================================================================
PROMPT
PROMPT Example 4: Complete ORDS workflow simulation
PROMPT ============================================================================

CREATE OR REPLACE PROCEDURE ords_complete_workflow_example
IS
    l_trace_id VARCHAR2(32);
    l_main_span VARCHAR2(16);
    l_order_id NUMBER;
    l_headers VARCHAR2(1000);
BEGIN
    -- Simulate receiving trace context from Angular
    l_trace_id := 'a1b2c3d4e5f6789012345678901234ab';  -- From Angular frontend
    
    -- Simulate HTTP headers JSON
    l_headers := '{"x-trace-id": "' || l_trace_id || '", "authorization": "Bearer jwt-token", "content-type": "application/json"}';
    
    DBMS_OUTPUT.PUT_LINE('Simulating ORDS workflow with trace: ' || l_trace_id);
    
    -- Step 1: ORDS receives request from Angular
    PLTelemetry.g_current_trace_id := l_trace_id;
    l_main_span := PLTelemetry.start_span('ords_order_workflow', NULL, l_trace_id);
    
    -- Step 2: Process order creation
    ords_create_order(
        p_customer_id  => 12345,
        p_items        => '[{"item_id": 1, "quantity": 2}, {"item_id": 2, "quantity": 1}]',
        p_total_amount => 299.99,
        p_trace_id     => l_trace_id,
        p_span_id      => l_main_span,
        p_user_id      => 'user123',
        p_order_id     => l_order_id
    );
    
    -- Step 3: Simulate response to Angular (which will continue to Tauri)
    DECLARE
        l_response_span VARCHAR2(16);
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_response_span := PLTelemetry.start_span('prepare_response', l_main_span);
        
        l_attrs(1) := PLTelemetry.add_attribute('order.id', TO_CHAR(l_order_id));
        l_attrs(2) := PLTelemetry.add_attribute('response.format', 'JSON');
        l_attrs(3) := PLTelemetry.add_attribute('next_step', 'print_order');
        
        PLTelemetry.add_event(l_response_span, 'response_prepared_for_angular', l_attrs);
        PLTelemetry.end_span(l_response_span, 'OK', l_attrs);
    END;
    
    PLTelemetry.end_span(l_main_span, 'OK');
    
    DBMS_OUTPUT.PUT_LINE('Order created: ' || l_order_id);
    DBMS_OUTPUT.PUT_LINE('Trace continues to Angular, then to Tauri for printing...');
    
    -- Note: Trace is NOT ended here because it continues to Angular -> Tauri
    -- Angular will continue the same trace when calling Tauri for printing
END;
/

-- Test the complete workflow
BEGIN
    ords_complete_workflow_example();
END;
/

-- Example 5: ORDS authentication and authorization with telemetry
-- ============================================================================
PROMPT
PROMPT Example 5: ORDS authentication with telemetry
PROMPT ============================================================================

CREATE OR REPLACE FUNCTION ords_validate_jwt_token(
    p_jwt_token IN VARCHAR2,
    p_trace_id  IN VARCHAR2 DEFAULT NULL
) RETURN VARCHAR2  -- Returns user_id or raises exception
IS
    l_span_id VARCHAR2(16);
    l_attrs   PLTelemetry.t_attributes;
    l_user_id VARCHAR2(100);
BEGIN
    l_span_id := PLTelemetry.start_span('validate_jwt_token', NULL, p_trace_id);
    
    l_attrs(1) := PLTelemetry.add_attribute('auth.method', 'JWT');
    l_attrs(2) := PLTelemetry.add_attribute('token.length', TO_CHAR(LENGTH(p_jwt_token)));
    
    PLTelemetry.add_event(l_span_id, 'jwt_validation_started', l_attrs);
    
    -- Simulate JWT validation
    IF p_jwt_token IS NULL OR LENGTH(p_jwt_token) < 20 THEN
        l_attrs(3) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, 'Invalid JWT token');
        PLTelemetry.add_event(l_span_id, 'jwt_validation_failed', l_attrs);
        PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
        RAISE_APPLICATION_ERROR(-20401, 'Invalid JWT token');
    END IF;
    
    -- Extract user_id from token (simplified)
    l_user_id := 'user_' || SUBSTR(p_jwt_token, -6);
    
    l_attrs(3) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_USER_ID, l_user_id);
    PLTelemetry.add_event(l_span_id, 'jwt_validation_successful', l_attrs);
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    
    RETURN l_user_id;
    
EXCEPTION
    WHEN OTHERS THEN
        l_attrs(3) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
        PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
        RAISE;
END;
/

-- Example 6: ORDS response time monitoring
-- ============================================================================
PROMPT
PROMPT Example 6: ORDS response time monitoring
PROMPT ============================================================================

CREATE OR REPLACE PROCEDURE ords_monitor_performance
IS
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
    l_start_time TIMESTAMP;
    l_end_time TIMESTAMP;
    l_duration NUMBER;
BEGIN
    l_trace_id := PLTelemetry.start_trace('ords_performance_monitoring');
    l_span_id := PLTelemetry.start_span('api_performance_test');
    
    l_start_time := SYSTIMESTAMP;
    
    -- Simulate various API response times
    FOR i IN 1..5 LOOP
        DECLARE
            l_api_span VARCHAR2(16);
            l_response_time NUMBER;
        BEGIN
            l_api_span := PLTelemetry.start_span('api_call_' || i, l_span_id);
            
            -- Simulate API call with random response time
            l_response_time := DBMS_RANDOM.VALUE(50, 500);  -- 50-500ms
            DBMS_LOCK.SLEEP(l_response_time / 1000);
            
            l_attrs(1) := PLTelemetry.add_attribute('api.endpoint', '/api/v1/endpoint' || i);
            l_attrs(2) := PLTelemetry.add_attribute('response.time_ms', TO_CHAR(l_response_time));
            
            PLTelemetry.end_span(l_api_span, 'OK', l_attrs);
            PLTelemetry.log_metric('api_response_time', l_response_time, 'milliseconds', l_attrs);
        END;
    END LOOP;
    
    l_end_time := SYSTIMESTAMP;
    l_duration := EXTRACT(SECOND FROM (l_end_time - l_start_time)) * 1000;
    
    l_attrs(1) := PLTelemetry.add_attribute('total.duration_ms', TO_CHAR(l_duration));
    PLTelemetry.log_metric('total_test_duration', l_duration, 'milliseconds', l_attrs);
    
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('Performance test completed in ' || ROUND(l_duration, 2) || 'ms');
END;
/

-- Run performance monitoring example
BEGIN
    ords_monitor_performance();
END;
/

PROMPT
PROMPT ================================================================================
PROMPT ORDS Integration Examples Completed
PROMPT ================================================================================
PROMPT
PROMPT Key Integration Patterns Demonstrated:
PROMPT ✓ Trace propagation from Angular frontend via HTTP headers
PROMPT ✓ RESTful API endpoint instrumentation
PROMPT ✓ Nested spans for complex operations
PROMPT ✓ HTTP semantic conventions usage
PROMPT ✓ JWT authentication with telemetry
PROMPT ✓ Performance monitoring for APIs
PROMPT ✓ Error handling with proper status codes
PROMPT
PROMPT For Production Use:
PROMPT 1. Extract trace context from ORDS HTTP headers
PROMPT 2. Pass trace_id and span_id to your PL/SQL procedures
PROMPT 3. Use semantic conventions for HTTP operations
PROMPT 4. Monitor API performance with metrics
PROMPT 5. Ensure traces continue to Tauri via WebSocket
PROMPT
PROMPT ================================================================================