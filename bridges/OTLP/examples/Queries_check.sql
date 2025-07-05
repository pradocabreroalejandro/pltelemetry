-- PLTelemetry Useful SELECT Queries
-- Collection of handy queries for monitoring and debugging PLTelemetry
-- 
-- Categories:
-- 1. Health Check & Status
-- 2. Active Traces & Spans
-- 3. Performance Analysis
-- 4. Error Investigation
-- 5. Queue Management
-- 6. Business Intelligence

PROMPT PLTelemetry Query Collection - Choose your weapon! 🎯

-- =============================================================================
-- 1. HEALTH CHECK & STATUS QUERIES
-- =============================================================================

PROMPT 
PROMPT === HEALTH CHECK & STATUS ===

-- Overall system health
SELECT 
    'Total Traces' as metric,
    COUNT(*) as value,
    TO_CHAR(MIN(start_time), 'YYYY-MM-DD HH24:MI') as earliest,
    TO_CHAR(MAX(start_time), 'YYYY-MM-DD HH24:MI') as latest
FROM plt_traces
UNION ALL
SELECT 
    'Total Spans' as metric,
    COUNT(*) as value,
    TO_CHAR(MIN(start_time), 'YYYY-MM-DD HH24:MI') as earliest,
    TO_CHAR(MAX(start_time), 'YYYY-MM-DD HH24:MI') as latest
FROM plt_spans
UNION ALL
SELECT 
    'Total Events' as metric,
    COUNT(*) as value,
    TO_CHAR(MIN(event_time), 'YYYY-MM-DD HH24:MI') as earliest,
    TO_CHAR(MAX(event_time), 'YYYY-MM-DD HH24:MI') as latest
FROM plt_events
UNION ALL
SELECT 
    'Total Metrics' as metric,
    COUNT(*) as value,
    TO_CHAR(MIN(timestamp), 'YYYY-MM-DD HH24:MI') as earliest,
    TO_CHAR(MAX(timestamp), 'YYYY-MM-DD HH24:MI') as latest
FROM plt_metrics;

-- Queue status (if using async mode)
SELECT 
    processed,
    COUNT(*) as count,
    AVG(process_attempts) as avg_attempts,
    MAX(process_attempts) as max_attempts,
    TO_CHAR(MIN(created_at), 'YYYY-MM-DD HH24:MI') as oldest,
    TO_CHAR(MAX(created_at), 'YYYY-MM-DD HH24:MI') as newest
FROM plt_queue 
GROUP BY processed
ORDER BY processed DESC;

-- =============================================================================
-- 2. ACTIVE TRACES & SPANS
-- =============================================================================

PROMPT 
PROMPT === ACTIVE TRACES & SPANS ===

-- Currently active traces (no end_time)
SELECT 
    trace_id,
    root_operation,
    service_name,
    start_time,
    ROUND((EXTRACT(SECOND FROM (SYSTIMESTAMP - start_time)) * 1000), 2) as duration_ms,
    (SELECT COUNT(*) FROM plt_spans WHERE trace_id = t.trace_id) as span_count,
    (SELECT COUNT(*) FROM plt_spans WHERE trace_id = t.trace_id AND end_time IS NULL) as active_spans
FROM plt_traces t
WHERE end_time IS NULL
ORDER BY start_time DESC;

-- Currently active spans (no end_time)
SELECT 
    s.trace_id,
    s.span_id,
    s.parent_span_id,
    s.operation_name,
    s.status,
    s.start_time,
    ROUND((EXTRACT(SECOND FROM (SYSTIMESTAMP - s.start_time)) * 1000), 2) as duration_ms,
    t.root_operation,
    (SELECT COUNT(*) FROM plt_events WHERE span_id = s.span_id) as event_count
FROM plt_spans s
JOIN plt_traces t ON s.trace_id = t.trace_id
WHERE s.end_time IS NULL
ORDER BY s.start_time DESC;

-- =============================================================================
-- 3. PERFORMANCE ANALYSIS
-- =============================================================================

PROMPT 
PROMPT === PERFORMANCE ANALYSIS ===

-- Slowest operations (completed spans only)
SELECT 
    operation_name,
    COUNT(*) as execution_count,
    ROUND(AVG(duration_ms), 2) as avg_duration_ms,
    ROUND(MIN(duration_ms), 2) as min_duration_ms,
    ROUND(MAX(duration_ms), 2) as max_duration_ms,
    ROUND(STDDEV(duration_ms), 2) as stddev_ms,
    status
FROM plt_spans 
WHERE end_time IS NOT NULL 
  AND duration_ms IS NOT NULL
GROUP BY operation_name, status
HAVING COUNT(*) > 1  -- Only operations with multiple executions
ORDER BY avg_duration_ms DESC;

-- Traces by duration (completed only)
SELECT 
    t.trace_id,
    t.root_operation,
    t.service_name,
    ROUND(EXTRACT(SECOND FROM (t.end_time - t.start_time)) * 1000, 2) as total_duration_ms,
    (SELECT COUNT(*) FROM plt_spans WHERE trace_id = t.trace_id) as span_count,
    (SELECT COUNT(*) FROM plt_spans WHERE trace_id = t.trace_id AND status = 'ERROR') as error_spans,
    t.start_time
FROM plt_traces t
WHERE t.end_time IS NOT NULL
ORDER BY total_duration_ms DESC
FETCH FIRST 20 ROWS ONLY;

-- Most active operations (by volume)
SELECT 
    operation_name,
    COUNT(*) as total_executions,
    SUM(CASE WHEN status = 'OK' THEN 1 ELSE 0 END) as successful,
    SUM(CASE WHEN status = 'ERROR' THEN 1 ELSE 0 END) as failed,
    ROUND(SUM(CASE WHEN status = 'ERROR' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) as error_rate_pct,
    ROUND(AVG(duration_ms), 2) as avg_duration_ms
FROM plt_spans 
WHERE end_time IS NOT NULL
GROUP BY operation_name
ORDER BY total_executions DESC;

-- =============================================================================
-- 4. ERROR INVESTIGATION
-- =============================================================================

PROMPT 
PROMPT === ERROR INVESTIGATION ===

-- Recent errors from telemetry system
SELECT 
    error_time,
    module_name,
    SUBSTR(error_message, 1, 100) as error_summary,
    trace_id,
    span_id
FROM plt_telemetry_errors 
WHERE error_time > SYSTIMESTAMP - INTERVAL '24' HOUR
ORDER BY error_time DESC;

-- Failed spans with context
SELECT 
    s.trace_id,
    s.span_id,
    s.operation_name,
    s.start_time,
    s.duration_ms,
    t.root_operation,
    t.service_name,
    (SELECT COUNT(*) FROM plt_events WHERE span_id = s.span_id) as event_count
FROM plt_spans s
JOIN plt_traces t ON s.trace_id = t.trace_id
WHERE s.status = 'ERROR'
ORDER BY s.start_time DESC;

-- Failed exports (HTTP issues)
SELECT 
    export_time,
    http_status,
    SUBSTR(payload, 1, 100) as payload_preview,
    SUBSTR(error_message, 1, 100) as error_summary,
    retry_count
FROM plt_failed_exports 
WHERE export_time > SYSTIMESTAMP - INTERVAL '24' HOUR
ORDER BY export_time DESC;

-- =============================================================================
-- 5. QUEUE MANAGEMENT
-- =============================================================================

PROMPT 
PROMPT === QUEUE MANAGEMENT ===

-- Queue items that need attention
SELECT 
    queue_id,
    created_at,
    process_attempts,
    last_attempt_time,
    SUBSTR(payload, 1, 100) as payload_preview,
    SUBSTR(last_error, 1, 100) as error_summary
FROM plt_queue 
WHERE processed = 'N'
  AND process_attempts >= 3  -- Items that are struggling
ORDER BY process_attempts DESC, created_at ASC;

-- Queue processing statistics
SELECT 
    TO_CHAR(created_at, 'YYYY-MM-DD HH24') as hour_bucket,
    COUNT(*) as total_items,
    COUNT(CASE WHEN processed = 'Y' THEN 1 END) as processed,
    COUNT(CASE WHEN processed = 'N' THEN 1 END) as pending,
    ROUND(AVG(process_attempts), 2) as avg_attempts
FROM plt_queue 
WHERE created_at > SYSTIMESTAMP - INTERVAL '24' HOUR
GROUP BY TO_CHAR(created_at, 'YYYY-MM-DD HH24')
ORDER BY hour_bucket DESC;

-- =============================================================================
-- 6. BUSINESS INTELLIGENCE 
-- =============================================================================

PROMPT 
PROMPT === BUSINESS INTELLIGENCE ===

-- Trace volume by hour (last 24h)
SELECT 
    TO_CHAR(start_time, 'YYYY-MM-DD HH24') as hour_bucket,
    COUNT(*) as trace_count,
    COUNT(DISTINCT root_operation) as unique_operations,
    ROUND(AVG(EXTRACT(SECOND FROM (end_time - start_time)) * 1000), 2) as avg_duration_ms
FROM plt_traces 
WHERE start_time > SYSTIMESTAMP - INTERVAL '24' HOUR
  AND end_time IS NOT NULL
GROUP BY TO_CHAR(start_time, 'YYYY-MM-DD HH24')
ORDER BY hour_bucket DESC;

-- Most common events
SELECT 
    event_name,
    COUNT(*) as occurrence_count,
    COUNT(DISTINCT span_id) as unique_spans,
    TO_CHAR(MIN(event_time), 'YYYY-MM-DD HH24:MI') as first_seen,
    TO_CHAR(MAX(event_time), 'YYYY-MM-DD HH24:MI') as last_seen
FROM plt_events 
WHERE event_time > SYSTIMESTAMP - INTERVAL '7' DAY
GROUP BY event_name
ORDER BY occurrence_count DESC;

-- Metrics summary
SELECT 
    metric_name,
    metric_unit,
    COUNT(*) as measurement_count,
    ROUND(AVG(metric_value), 2) as avg_value,
    ROUND(MIN(metric_value), 2) as min_value,
    ROUND(MAX(metric_value), 2) as max_value,
    TO_CHAR(MAX(timestamp), 'YYYY-MM-DD HH24:MI') as last_recorded
FROM plt_metrics 
WHERE timestamp > SYSTIMESTAMP - INTERVAL '24' HOUR
GROUP BY metric_name, metric_unit
ORDER BY measurement_count DESC;

-- Distributed tracing overview (spans with distributed attributes)
SELECT 
    sa.attribute_value as system_name,
    COUNT(DISTINCT s.trace_id) as trace_count,
    COUNT(DISTINCT s.span_id) as span_count,
    ROUND(AVG(s.duration_ms), 2) as avg_duration_ms,
    COUNT(CASE WHEN s.status = 'ERROR' THEN 1 END) as error_count
FROM plt_span_attributes sa
JOIN plt_spans s ON sa.span_id = s.span_id
WHERE sa.attribute_key = 'system.name'
  AND s.start_time > SYSTIMESTAMP - INTERVAL '24' HOUR
GROUP BY sa.attribute_value
ORDER BY trace_count DESC;

PROMPT 
PROMPT === QUERY COLLECTION COMPLETE ===
PROMPT Use these queries to monitor, debug, and analyze your PLTelemetry data!
PROMPT Pro tip: Add WHERE clauses with time ranges for better performance on large datasets.