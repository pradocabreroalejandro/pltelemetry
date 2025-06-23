-- Sample Data for PLTelemetry Demo
-- This script creates realistic telemetry data for testing and demo purposes

\c pltelemetry_db;
SET search_path TO telemetry, public;

-- ========================================================================
-- SAMPLE TRACES AND SPANS
-- ========================================================================

-- Sample trace 1: Customer order processing
INSERT INTO telemetry.traces (trace_id, root_operation, start_time, end_time, service_name, service_instance)
VALUES 
('a1b2c3d4e5f6789012345678901234ab', 'process_customer_order', 
 NOW() - INTERVAL '1 hour', NOW() - INTERVAL '59 minutes', 
 'oracle-crm', 'prod-db-01:ORCL');

-- Spans for order processing
INSERT INTO telemetry.spans (span_id, trace_id, parent_span_id, operation_name, start_time, end_time, duration_ms, status)
VALUES 
('a1b2c3d4e5f67890', 'a1b2c3d4e5f6789012345678901234ab', NULL, 'validate_customer', 
 NOW() - INTERVAL '1 hour', NOW() - INTERVAL '59 minutes 50 seconds', 245.67, 'OK'),
('b2c3d4e5f6789012', 'a1b2c3d4e5f6789012345678901234ab', 'a1b2c3d4e5f67890', 'check_credit_limit', 
 NOW() - INTERVAL '59 minutes 45 seconds', NOW() - INTERVAL '59 minutes 35 seconds', 156.23, 'OK'),
('c3d4e5f678901234', 'a1b2c3d4e5f6789012345678901234ab', 'a1b2c3d4e5f67890', 'reserve_inventory', 
 NOW() - INTERVAL '59 minutes 30 seconds', NOW() - INTERVAL '59 minutes 25 seconds', 423.89, 'OK'),
('d4e5f67890123456', 'a1b2c3d4e5f6789012345678901234ab', NULL, 'process_payment', 
 NOW() - INTERVAL '59 minutes 20 seconds', NOW() - INTERVAL '59 minutes 15 seconds', 1234.56, 'OK');

-- Sample trace 2: Error scenario
INSERT INTO telemetry.traces (trace_id, root_operation, start_time, end_time, service_name, service_instance)
VALUES 
('f1e2d3c4b5a6987654321098765432ef', 'process_refund', 
 NOW() - INTERVAL '30 minutes', NOW() - INTERVAL '28 minutes', 
 'oracle-crm', 'prod-db-01:ORCL');

-- Spans with errors
INSERT INTO telemetry.spans (span_id, trace_id, parent_span_id, operation_name, start_time, end_time, duration_ms, status)
VALUES 
('f1e2d3c4b5a69876', 'f1e2d3c4b5a6987654321098765432ef', NULL, 'validate_refund_request', 
 NOW() - INTERVAL '30 minutes', NOW() - INTERVAL '29 minutes 45 seconds', 543.21, 'OK'),
('e1d2c3b4a5968765', 'f1e2d3c4b5a6987654321098765432ef', 'f1e2d3c4b5a69876', 'check_original_payment', 
 NOW() - INTERVAL '29 minutes 40 seconds', NOW() - INTERVAL '29 minutes 30 seconds', 234.56, 'ERROR'),
('d1c2b3a495867543', 'f1e2d3c4b5a6987654321098765432ef', 'f1e2d3c4b5a69876', 'reverse_payment', 
 NOW() - INTERVAL '29 minutes 25 seconds', NOW() - INTERVAL '28 minutes 5 seconds', 891.23, 'ERROR');

-- Sample trace 3: Recent activity
INSERT INTO telemetry.traces (trace_id, root_operation, start_time, service_name, service_instance)
VALUES 
('1234567890abcdef1234567890abcdef', 'generate_monthly_report', 
 NOW() - INTERVAL '5 minutes', 
 'oracle-reporting', 'prod-db-02:ORCL');

-- Long-running spans
INSERT INTO telemetry.spans (span_id, trace_id, parent_span_id, operation_name, start_time, end_time, duration_ms, status)
VALUES 
('1234567890abcdef', '1234567890abcdef1234567890abcdef', NULL, 'collect_data', 
 NOW() - INTERVAL '5 minutes', NOW() - INTERVAL '3 minutes', 120000.45, 'OK'),
('234567890abcdef1', '1234567890abcdef1234567890abcdef', '1234567890abcdef', 'aggregate_sales', 
 NOW() - INTERVAL '4 minutes 30 seconds', NOW() - INTERVAL '3 minutes 45 seconds', 45000.67, 'OK'),
('34567890abcdef12', '1234567890abcdef1234567890abcdef', '1234567890abcdef', 'calculate_metrics', 
 NOW() - INTERVAL '3 minutes 30 seconds', NOW() - INTERVAL '2 minutes 15 seconds', 75000.89, 'OK');

-- ========================================================================
-- SAMPLE EVENTS
-- ========================================================================

INSERT INTO telemetry.events (span_id, event_name, event_time, attributes)
VALUES 
('a1b2c3d4e5f67890', 'customer_validated', 
 NOW() - INTERVAL '59 minutes 55 seconds',
 '{"customer.id": "12345", "customer.type": "premium", "validation.method": "oauth"}'),
('b2c3d4e5f6789012', 'credit_check_completed', 
 NOW() - INTERVAL '59 minutes 40 seconds',
 '{"credit.limit": "50000", "credit.available": "35000", "check.result": "approved"}'),
('c3d4e5f678901234', 'inventory_reserved', 
 NOW() - INTERVAL '59 minutes 28 seconds',
 '{"item.sku": "PROD-001", "quantity": "2", "warehouse": "WH-MADRID"}'),
('d4e5f67890123456', 'payment_processed', 
 NOW() - INTERVAL '59 minutes 16 seconds',
 '{"payment.method": "credit_card", "amount": "299.99", "currency": "EUR", "processor": "stripe"}'),
('e1d2c3b4a5968765', 'payment_lookup_failed', 
 NOW() - INTERVAL '29 minutes 35 seconds',
 '{"error.code": "PAYMENT_NOT_FOUND", "payment.id": "pay_12345", "retry.attempt": "1"}'),
('1234567890abcdef', 'data_collection_started', 
 NOW() - INTERVAL '4 minutes 55 seconds',
 '{"report.type": "monthly", "period": "2025-05", "tables.count": "23"}'),
('234567890abcdef1', 'sales_aggregation_completed', 
 NOW() - INTERVAL '3 minutes 50 seconds',
 '{"records.processed": "156789", "sales.total": "2340567.89", "currency": "EUR"}');

-- ========================================================================
-- SAMPLE METRICS
-- ========================================================================

-- Performance metrics
INSERT INTO telemetry.metrics (metric_name, metric_value, metric_unit, trace_id, span_id, timestamp, attributes)
VALUES 
('order_processing_time', 1234.56, 'milliseconds', 'a1b2c3d4e5f6789012345678901234ab', 'd4e5f67890123456', 
 NOW() - INTERVAL '59 minutes', '{"customer.type": "premium", "order.items": "3"}'),
('credit_check_duration', 156.23, 'milliseconds', 'a1b2c3d4e5f6789012345678901234ab', 'b2c3d4e5f6789012', 
 NOW() - INTERVAL '59 minutes', '{"credit.provider": "experian", "cache.hit": "false"}'),
('inventory_reserve_time', 423.89, 'milliseconds', 'a1b2c3d4e5f6789012345678901234ab', 'c3d4e5f678901234', 
 NOW() - INTERVAL '59 minutes', '{"warehouse": "WH-MADRID", "item.category": "electronics"}'),
('payment_processing_time', 1234.56, 'milliseconds', 'a1b2c3d4e5f6789012345678901234ab', 'd4e5f67890123456', 
 NOW() - INTERVAL '59 minutes', '{"payment.processor": "stripe", "payment.method": "credit_card"}'),
('refund_validation_time', 543.21, 'milliseconds', 'f1e2d3c4b5a6987654321098765432ef', 'f1e2d3c4b5a69876', 
 NOW() - INTERVAL '30 minutes', '{"refund.reason": "defective_product", "customer.tier": "gold"}'),
('data_collection_duration', 120000.45, 'milliseconds', '1234567890abcdef1234567890abcdef', '1234567890abcdef', 
 NOW() - INTERVAL '4 minutes', '{"report.type": "monthly", "data.volume": "156GB"}'),
('sales_aggregation_time', 45000.67, 'milliseconds', '1234567890abcdef1234567890abcdef', '234567890abcdef1', 
 NOW() - INTERVAL '3 minutes 50 seconds', '{"records.count": "156789", "aggregation.type": "sum"}');

-- Business metrics
INSERT INTO telemetry.metrics (metric_name, metric_value, metric_unit, trace_id, span_id, timestamp, attributes)
VALUES 
('order_value', 299.99, 'EUR', 'a1b2c3d4e5f6789012345678901234ab', 'd4e5f67890123456', 
 NOW() - INTERVAL '59 minutes', '{"customer.segment": "premium", "order.channel": "web"}'),
('items_ordered', 3, 'count', 'a1b2c3d4e5f6789012345678901234ab', 'c3d4e5f678901234', 
 NOW() - INTERVAL '59 minutes', '{"product.category": "electronics", "discount.applied": "10"}'),
('credit_utilization', 0.7, 'percentage', 'a1b2c3d4e5f6789012345678901234ab', 'b2c3d4e5f6789012', 
 NOW() - INTERVAL '59 minutes', '{"customer.credit_limit": "50000", "customer.age": "5_years"}'),
('refund_amount', 149.99, 'EUR', 'f1e2d3c4b5a6987654321098765432ef', 'f1e2d3c4b5a69876', 
 NOW() - INTERVAL '30 minutes', '{"refund.type": "partial", "original.order": "ORD-98765"}'),
('report_data_volume', 156.7, 'GB', '1234567890abcdef1234567890abcdef', '1234567890abcdef', 
 NOW() - INTERVAL '4 minutes', '{"compression.ratio": "0.3", "source.tables": "23"}'),
('monthly_sales_total', 2340567.89, 'EUR', '1234567890abcdef1234567890abcdef', '234567890abcdef1', 
 NOW() - INTERVAL '3 minutes 50 seconds', '{"month": "2025-05", "growth.rate": "12.5"}');

-- System metrics
INSERT INTO telemetry.metrics (metric_name, metric_value, metric_unit, trace_id, span_id, timestamp, attributes)
VALUES 
('database_connections', 45, 'count', 'a1b2c3d4e5f6789012345678901234ab', 'a1b2c3d4e5f67890', 
 NOW() - INTERVAL '59 minutes', '{"pool.max": "100", "pool.active": "45", "db.instance": "ORCL"}'),
('memory_usage', 2.3, 'GB', 'a1b2c3d4e5f6789012345678901234ab', 'b2c3d4e5f6789012', 
 NOW() - INTERVAL '59 minutes', '{"process.name": "oracle", "heap.size": "4GB"}'),
('cpu_utilization', 0.65, 'percentage', 'f1e2d3c4b5a6987654321098765432ef', 'e1d2c3b4a5968765', 
 NOW() - INTERVAL '29 minutes', '{"cores": "8", "load.avg": "3.2"}'),
-- LÍNEA CORREGIDA:
('network_latency', 23.5, 'milliseconds', 'a1b2c3d4e5f6789012345678901234ab', 'd4e5f67890123456', 
 NOW() - INTERVAL '59 minutes', '{"endpoint": "payment.api", "region": "eu-west-1"}'),
('disk_io_wait', 12.3, 'milliseconds', '1234567890abcdef1234567890abcdef', '1234567890abcdef', 
 NOW() - INTERVAL '4 minutes', '{"disk.type": "SSD", "operation": "read", "volume": "data"}');

-- ========================================================================
-- SAMPLE ERROR SCENARIOS
-- ========================================================================

-- Error logs
INSERT INTO telemetry.telemetry_errors (error_time, error_message, error_stack, error_code, module_name, trace_id, span_id, session_user_id, host)
VALUES 
(NOW() - INTERVAL '29 minutes 35 seconds', 
 'Payment record not found in external system', 
 'ORA-20001: PAYMENT_NOT_FOUND at line 245\ncheck_original_payment(pay_12345)\nprocess_refund_request()', 
 -20001, 'check_original_payment', 'f1e2d3c4b5a6987654321098765432ef', 'e1d2c3b4a5968765', 
 'CRM_USER', 'prod-db-01'),
(NOW() - INTERVAL '29 minutes 20 seconds', 
 'Timeout connecting to payment gateway', 
 'UTL_HTTP.TRANSFER_TIMEOUT\nreverse_payment()\nprocess_refund_request()', 
 -29273, 'reverse_payment', 'f1e2d3c4b5a6987654321098765432ef', 'd1c2b3a495867543', 
 'CRM_USER', 'prod-db-01'),
(NOW() - INTERVAL '15 minutes', 
 'Invalid JSON format in telemetry payload', 
 'JSON_PARSE_ERROR at character 45\nattributes_to_json()\nend_span()', 
 -40441, 'end_span', NULL, NULL, 
 'TELEMETRY_USER', 'prod-db-01'),
(NOW() - INTERVAL '8 minutes', 
 'Database connection pool exhausted', 
 'ORA-12516: TNS:listener could not find available handler\nget_connection()\nstart_trace()', 
 -12516, 'start_trace', NULL, NULL, 
 'APP_USER', 'prod-db-02'),
(NOW() - INTERVAL '2 minutes', 
 'Span end time before start time detected', 
 'INVALID_TIME_RANGE\nvalidate_span_duration()\nend_span()', 
 -20002, 'end_span', '1234567890abcdef1234567890abcdef', '34567890abcdef12', 
 'REPORTING_USER', 'prod-db-02');

-- Failed exports
INSERT INTO telemetry.failed_exports (export_time, http_status, payload, error_message, retry_count)
VALUES 
(NOW() - INTERVAL '45 minutes', 503, 
 '{"trace_id":"a1b2c3d4e5f6789012345678901234ab","span_id":"d4e5f67890123456","operation":"end_span"...', 
 'Service Unavailable: Backend telemetry service temporarily down', 2),
(NOW() - INTERVAL '32 minutes', 408, 
 '{"metric_name":"payment_processing_time","value":1234.56,"trace_id":"a1b2c3d4e5f6789012345678901234ab"...', 
 'Request Timeout: Backend took longer than 30 seconds to respond', 1),
(NOW() - INTERVAL '12 minutes', 413, 
 '{"trace_id":"1234567890abcdef1234567890abcdef","span_id":"1234567890abcdef","attributes":{"large_field":"very long data..."...', 
 'Payload Too Large: Request body exceeds 4MB limit', 3),
(NOW() - INTERVAL '5 minutes', 400, 
 '{"trace_id":"invalid-trace-id","span_id":"also-invalid","operation":"end_span"}', 
 'Bad Request: Invalid trace_id format - must be 32 hex characters', 0);

-- Queue entries (some processed, some pending)
INSERT INTO telemetry.queue (payload, created_at, processed, process_attempts, processed_time, last_error)
VALUES 
('{"trace_id":"a1b2c3d4e5f6789012345678901234ab","operation":"trace_complete"}', 
 NOW() - INTERVAL '1 hour', true, 1, NOW() - INTERVAL '59 minutes', NULL),
('{"metric_name":"order_completion_rate","value":0.95,"timestamp":"' || (NOW() - INTERVAL '30 minutes')::text || '"}', 
 NOW() - INTERVAL '35 minutes', true, 1, NOW() - INTERVAL '34 minutes', NULL),
('{"trace_id":"f1e2d3c4b5a6987654321098765432ef","operation":"trace_error"}', 
 NOW() - INTERVAL '25 minutes', false, 2, NULL, 'Connection refused: Backend service not responding'),
('{"span_id":"pending_span_001","operation":"span_timeout_warning"}', 
 NOW() - INTERVAL '10 minutes', false, 0, NULL, NULL),
('{"metric_name":"system_health_check","value":1,"timestamp":"' || (NOW() - INTERVAL '2 minutes')::text || '"}', 
 NOW() - INTERVAL '3 minutes', false, 1, NULL, 'HTTP 502: Bad Gateway');

-- ========================================================================
-- SAMPLE DATA FOR PERFORMANCE TESTING
-- ========================================================================

-- Generate additional traces for volume testing
DO $$
DECLARE
    i INTEGER;
    trace_id_val VARCHAR(32);
    span_id_val VARCHAR(16);
    operation_names TEXT[] := ARRAY['user_login', 'product_search', 'add_to_cart', 'checkout_process', 'inventory_check', 'price_calculation'];
    service_names TEXT[] := ARRAY['oracle-crm', 'oracle-inventory', 'oracle-pricing', 'oracle-auth'];
    statuses TEXT[] := ARRAY['OK', 'OK', 'OK', 'OK', 'ERROR'];  -- 80% OK, 20% ERROR
BEGIN
    FOR i IN 1..50 LOOP
        -- Generate random IDs
        trace_id_val := LPAD(TO_HEX(i), 32, '0');
        span_id_val := LPAD(TO_HEX(i), 16, '0');
        
        -- Insert trace
        INSERT INTO telemetry.traces (trace_id, root_operation, start_time, end_time, service_name, service_instance)
        VALUES (
            trace_id_val,
            operation_names[1 + (i % array_length(operation_names, 1))],
            NOW() - (INTERVAL '1 minute' * (i + random() * 60)),
            NOW() - (INTERVAL '1 minute' * (i + random() * 30)),
            service_names[1 + (i % array_length(service_names, 1))],
            'load-test-db:ORCL'
        );
        
        -- Insert span
        INSERT INTO telemetry.spans (span_id, trace_id, operation_name, start_time, end_time, duration_ms, status)
        VALUES (
            span_id_val,
            trace_id_val,
            operation_names[1 + (i % array_length(operation_names, 1))],
            NOW() - (INTERVAL '1 minute' * (i + random() * 60)),
            NOW() - (INTERVAL '1 minute' * (i + random() * 30)),
            (random() * 5000 + 100)::DECIMAL(15,3),
            statuses[1 + (i % array_length(statuses, 1))]
        );
        
        -- Insert metric
        INSERT INTO telemetry.metrics (metric_name, metric_value, metric_unit, trace_id, span_id, timestamp)
        VALUES (
            'response_time',
            (random() * 2000 + 50)::DECIMAL(20,6),
            'milliseconds',
            trace_id_val,
            span_id_val,
            NOW() - (INTERVAL '1 minute' * (i + random() * 60))
        );
    END LOOP;
END $$;

-- ========================================================================
-- SUMMARY VIEWS FOR GRAFANA (Optional)
-- ========================================================================

-- Create a view for easier Grafana queries
CREATE OR REPLACE VIEW telemetry.trace_summary AS
SELECT 
    t.trace_id,
    t.root_operation,
    t.service_name,
    t.start_time,
    t.end_time,
    EXTRACT(EPOCH FROM (t.end_time - t.start_time)) * 1000 AS total_duration_ms,
    COUNT(s.span_id) AS span_count,
    COUNT(CASE WHEN s.status = 'ERROR' THEN 1 END) AS error_count,
    AVG(s.duration_ms) AS avg_span_duration,
    MAX(s.duration_ms) AS max_span_duration
FROM telemetry.traces t
LEFT JOIN telemetry.spans s ON t.trace_id = s.trace_id
GROUP BY t.trace_id, t.root_operation, t.service_name, t.start_time, t.end_time;

-- Grant permissions on the view
GRANT SELECT ON telemetry.trace_summary TO pltel_reader;

-- Create indexes on commonly queried timestamp columns for better performance
CREATE INDEX IF NOT EXISTS idx_telemetry_traces_end_time ON telemetry.traces(end_time) WHERE end_time IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_telemetry_spans_end_time ON telemetry.spans(end_time) WHERE end_time IS NOT NULL;

-- ========================================================================
-- VALIDATION QUERIES
-- ========================================================================

-- Quick validation of sample data
SELECT 'Traces created' AS object_type, COUNT(*) AS count FROM telemetry.traces
UNION ALL
SELECT 'Spans created', COUNT(*) FROM telemetry.spans
UNION ALL  
SELECT 'Events created', COUNT(*) FROM telemetry.events
UNION ALL
SELECT 'Metrics created', COUNT(*) FROM telemetry.metrics
UNION ALL
SELECT 'Errors logged', COUNT(*) FROM telemetry.telemetry_errors
UNION ALL
SELECT 'Failed exports', COUNT(*) FROM telemetry.failed_exports
UNION ALL
SELECT 'Queue entries', COUNT(*) FROM telemetry.queue;

-- Show some sample trace hierarchies
SELECT 
    t.root_operation,
    s.operation_name,
    s.parent_span_id,
    s.duration_ms,
    s.status
FROM telemetry.traces t
JOIN telemetry.spans s ON t.trace_id = s.trace_id
WHERE t.trace_id = 'a1b2c3d4e5f6789012345678901234ab'
ORDER BY s.start_time;

COMMIT;