-- =============================================================================
-- PLT_OTLP_BRIDGE - Complete Usage Examples
-- Modern examples for the OTLP bridge with events, logs, and enhanced features
-- =============================================================================

-- 1. INITIAL BRIDGE CONFIGURATION (MANDATORY)
-- =============================================================================
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Configuring PLT_OTLP_BRIDGE ===');
    
    -- MANDATORY: Configure PLTelemetry to use the OTLP bridge
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    
    -- MANDATORY: Configure the OTLP collector endpoint
    PLT_OTLP_BRIDGE.set_otlp_collector('http://your-collector:4318');
    
    -- RECOMMENDED: Configure service identification
    PLT_OTLP_BRIDGE.set_service_info(
        p_service_name => 'oracle-order-system',
        p_service_version => '1.2.0',
        p_tenant_id => 'production'
    );
    
    -- USEFUL: Enable debug mode for initial setup
    PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
    
    -- OPTIONAL: Use native JSON parsing for Oracle 12c+ (better performance)
    PLT_OTLP_BRIDGE.set_native_json_mode(TRUE);
    
    -- OPTIONAL: Set timeout for HTTP requests
    PLT_OTLP_BRIDGE.set_timeout(30);
    
    DBMS_OUTPUT.PUT_LINE('✓ OTLP Bridge configured successfully');
END;
/

-- 2. BASIC EXAMPLE: Simple Trace with Events
-- =============================================================================
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Basic Trace Example ===');
    
    -- Start a new trace
    l_trace_id := PLTelemetry.start_trace('process_customer_order');
    DBMS_OUTPUT.PUT_LINE('Trace started: ' || l_trace_id);
    
    -- Start a span
    l_span_id := PLTelemetry.start_span('validate_customer');
    DBMS_OUTPUT.PUT_LINE('Span started: ' || l_span_id);
    
    -- Add timeline events (NEW FEATURE)
    PLTelemetry.add_event(l_span_id, 'validation_started');
    
    -- Simulate some work
    DBMS_LOCK.SLEEP(1);
    
    -- Add attributes
    l_attrs(1) := PLTelemetry.add_attribute('customer.id', '12345');
    l_attrs(2) := PLTelemetry.add_attribute('customer.tier', 'premium');
    
    -- Add completion event
    PLTelemetry.add_event(l_span_id, 'validation_completed', l_attrs);
    
    -- End span with status
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    
    -- End trace
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('✓ Basic trace completed');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Error: ' || SQLERRM);
END;
/

-- 3. ADVANCED EXAMPLE: Nested Spans with Parent-Child Relationships
-- =============================================================================
DECLARE
    l_trace_id VARCHAR2(32);
    l_parent_span VARCHAR2(16);
    l_validation_span VARCHAR2(16);
    l_payment_span VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Advanced Nested Spans Example ===');
    
    -- Start main trace
    l_trace_id := PLTelemetry.start_trace('complete_order_processing');
    
    -- Parent span for entire order
    l_parent_span := PLTelemetry.start_span('order_main', NULL, l_trace_id);
    PLTelemetry.add_event(l_parent_span, 'order_received');
    
    -- Child span 1: Customer validation
    l_validation_span := PLTelemetry.start_span('customer_validation', l_parent_span, l_trace_id);
    
    -- Simulate validation work
    DBMS_LOCK.SLEEP(0.5);
    
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('customer.id', '67890');
    l_attrs(2) := PLTelemetry.add_attribute('validation.method', 'oauth2');
    l_attrs(3) := PLTelemetry.add_attribute('validation.rules_checked', '5');
    
    PLTelemetry.add_event(l_validation_span, 'customer_verified', l_attrs);
    PLTelemetry.end_span(l_validation_span, 'OK', l_attrs);
    
    -- Child span 2: Payment processing
    l_payment_span := PLTelemetry.start_span('payment_processing', l_parent_span, l_trace_id);
    
    -- Simulate payment processing
    DBMS_LOCK.SLEEP(1.2);
    
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('payment.method', 'credit_card');
    l_attrs(2) := PLTelemetry.add_attribute('payment.provider', 'stripe');
    l_attrs(3) := PLTelemetry.add_attribute('payment.amount', '299.99');
    l_attrs(4) := PLTelemetry.add_attribute('payment.currency', 'EUR');
    
    PLTelemetry.add_event(l_payment_span, 'payment_authorized', l_attrs);
    PLTelemetry.add_event(l_payment_span, 'payment_captured', l_attrs);
    PLTelemetry.end_span(l_payment_span, 'OK', l_attrs);
    
    -- Complete parent span
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('order.status', 'completed');
    l_attrs(2) := PLTelemetry.add_attribute('order.total_duration_ms', '1700');
    
    PLTelemetry.add_event(l_parent_span, 'order_completed', l_attrs);
    PLTelemetry.end_span(l_parent_span, 'OK', l_attrs);
    
    -- End trace
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('✓ Advanced nested spans completed');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Error in nested spans: ' || SQLERRM);
END;
/

-- 4. METRICS EXAMPLE: Custom Metrics with Trace Context
-- =============================================================================
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Metrics Example ===');
    
    -- Start trace context for metrics
    l_trace_id := PLTelemetry.start_trace('system_metrics_collection');
    l_span_id := PLTelemetry.start_span('collect_performance_metrics', NULL, l_trace_id);
    
    -- Simple metric
    PLTelemetry.log_metric('orders_processed_total', 156, 'count');
    
    -- Metric with attributes (dimensional data)
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('region', 'europe');
    l_attrs(2) := PLTelemetry.add_attribute('store_type', 'online');
    l_attrs(3) := PLTelemetry.add_attribute('payment_method', 'card');
    
    PLTelemetry.log_metric('revenue_daily', 15847.95, 'EUR', l_attrs);
    
    -- Performance metrics
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('query_type', 'customer_lookup');
    l_attrs(2) := PLTelemetry.add_attribute('table', 'customers');
    
    PLTelemetry.log_metric('db_query_duration', 245.67, 'ms', l_attrs);
    
    -- System metrics
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('resource_type', 'memory');
    
    PLTelemetry.log_metric('memory_usage_pct', 78.5, 'percent', l_attrs);
    
    -- Complete metrics collection
    PLTelemetry.end_span(l_span_id, 'OK');
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('✓ Metrics sent successfully');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Error sending metrics: ' || SQLERRM);
END;
/

-- 5. ERROR HANDLING EXAMPLE: Proper Error Tracing
-- =============================================================================
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Error Handling Example ===');
    
    l_trace_id := PLTelemetry.start_trace('operation_with_error');
    l_span_id := PLTelemetry.start_span('risky_operation', NULL, l_trace_id);
    
    PLTelemetry.add_event(l_span_id, 'operation_started');
    
    BEGIN
        -- Simulate operation that might fail
        IF DBMS_RANDOM.VALUE(0, 1) > 0.3 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Simulated business logic error');
        END IF;
        
        -- Success path
        PLTelemetry.add_event(l_span_id, 'operation_successful');
        PLTelemetry.end_span(l_span_id, 'OK');
        
        DBMS_OUTPUT.PUT_LINE('✓ Operation completed successfully');
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Capture error details
            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            l_attrs(3) := PLTelemetry.add_attribute('error.type', 'application_error');
            l_attrs(4) := PLTelemetry.add_attribute('error.recovery', 'manual_intervention_required');
            
            -- Add error event
            PLTelemetry.add_event(l_span_id, 'error_occurred', l_attrs);
            
            -- End span with ERROR status
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            
            DBMS_OUTPUT.PUT_LINE('✓ Error captured and sent to telemetry');
            -- Note: Don't re-raise if you want to continue execution
    END;
    
    PLTelemetry.end_trace(l_trace_id);
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Error in error handling: ' || SQLERRM);
END;
/

-- 6. LOGGING EXAMPLE: Structured Logs with Trace Context
-- =============================================================================
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Structured Logging Example ===');
    
    l_trace_id := PLTelemetry.start_trace('user_authentication');
    l_span_id := PLTelemetry.start_span('validate_credentials', NULL, l_trace_id);
    
    -- Add structured log entries
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('user.id', 'user123');
    l_attrs(2) := PLTelemetry.add_attribute('auth.method', 'password');
    
    PLTelemetry.log_message('INFO', 'User authentication started', l_attrs);
    
    -- Simulate authentication steps
    DBMS_LOCK.SLEEP(0.2);
    
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('user.id', 'user123');
    l_attrs(2) := PLTelemetry.add_attribute('validation.step', 'password_check');
    
    PLTelemetry.log_message('DEBUG', 'Password validation completed', l_attrs);
    
    -- Final log
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('user.id', 'user123');
    l_attrs(2) := PLTelemetry.add_attribute('auth.result', 'success');
    l_attrs(3) := PLTelemetry.add_attribute('session.id', 'sess_789');
    
    PLTelemetry.log_message('INFO', 'User authenticated successfully', l_attrs);
    
    PLTelemetry.end_span(l_span_id, 'OK');
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('✓ Structured logs sent successfully');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Error in logging: ' || SQLERRM);
END;
/

-- 7. CONFIGURATION VERIFICATION AND CLEANUP
-- =============================================================================
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== Configuration Verification ===');
    
    -- Check current configuration
    DBMS_OUTPUT.PUT_LINE('Backend URL: ' || PLTelemetry.get_backend_url());
    DBMS_OUTPUT.PUT_LINE('Current Trace: ' || NVL(PLTelemetry.get_current_trace_id(), 'NONE'));
    DBMS_OUTPUT.PUT_LINE('Current Span: ' || NVL(PLTelemetry.get_current_span_id(), 'NONE'));
    DBMS_OUTPUT.PUT_LINE('JSON Mode: ' || CASE WHEN PLT_OTLP_BRIDGE.get_native_json_mode() THEN 'NATIVE' ELSE 'LEGACY' END);
    
    -- Disable debug mode for production
    PLT_OTLP_BRIDGE.set_debug_mode(FALSE);
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('✓ All examples completed successfully!');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('📊 Check your observability stack:');
    DBMS_OUTPUT.PUT_LINE('   - Traces: Jaeger/Tempo UI');
    DBMS_OUTPUT.PUT_LINE('   - Metrics: Prometheus/Grafana');
    DBMS_OUTPUT.PUT_LINE('   - Logs: Loki/Grafana');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('🐛 For troubleshooting:');
    DBMS_OUTPUT.PUT_LINE('   SELECT * FROM plt_telemetry_errors WHERE module_name = ''PLT_OTLP_BRIDGE'';');
END;
/

-- =============================================================================
-- IMPORTANT NOTES:
-- =============================================================================
/*

🔧 PREREQUISITES:

1. OTLP Collector running and accessible
   Example Docker command:
   docker run -p 4317:4317 -p 4318:4318 \
     -v ./otel-config.yaml:/etc/config.yaml \
     otel/opentelemetry-collector-contrib:latest --config=/etc/config.yaml

2. Or use Jaeger with OTLP support:
   docker run -d --name jaeger \
     -p 16686:16686 -p 14250:14250 -p 4317:4317 -p 4318:4318 \
     jaegertracing/all-in-one:latest

3. Or use Grafana Cloud/Tempo:
   Update collector endpoint with your cloud endpoint

📊 WHAT TO EXPECT:

- Distributed traces with parent-child span relationships
- Metrics with dimensional attributes and trace context
- Structured logs with severity levels and trace correlation
- Timeline events within spans
- Proper error status propagation
- JSON OTLP format sent to collector

🐛 TROUBLESHOOTING:

If traces don't appear:
1. Verify collector is accessible: curl http://your-collector:4318/v1/traces
2. Check error table: SELECT * FROM plt_telemetry_errors;
3. Enable debug mode: PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
4. Verify Oracle UTL_HTTP ACLs are configured
5. Check collector logs for incoming data

💡 PERFORMANCE TIPS:

- Use async mode for production: PLTelemetry.set_async_mode(TRUE);
- Enable native JSON for Oracle 12c+: PLT_OTLP_BRIDGE.set_native_json_mode(TRUE);
- Consider sampling for high-volume applications
- Monitor collector performance and adjust timeout if needed

*/