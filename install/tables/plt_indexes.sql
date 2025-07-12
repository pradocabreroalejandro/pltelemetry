-- PLTelemetry Performance Indexes - Enterprise Multi-tenant Edition
-- This script creates indexes for optimal PLTelemetry performance with tenant isolation
-- 
-- Indexes created for:
-- - Query performance on common access patterns
-- - Foreign key performance
-- - Queue processing efficiency
-- - Error analysis and monitoring
-- - Enterprise multi-tenant performance

PROMPT Creating PLTelemetry performance indexes...

-- Traces indexes (tenant-aware)
CREATE INDEX idx_plt_traces_start_time ON plt_traces(start_time);
CREATE INDEX idx_plt_traces_service ON plt_traces(service_name, start_time);
CREATE INDEX idx_plt_traces_operation ON plt_traces(root_operation, start_time);
CREATE INDEX idx_plt_traces_tenant ON plt_traces(tenant_id, start_time);  -- NEW: Tenant isolation
CREATE INDEX idx_plt_traces_tenant_op ON plt_traces(tenant_id, root_operation, start_time);  -- NEW: Tenant + operation

-- Spans indexes (tenant-aware)
CREATE INDEX idx_plt_spans_trace_id ON plt_spans(trace_id, start_time);
CREATE INDEX idx_plt_spans_parent ON plt_spans(parent_span_id, start_time);
CREATE INDEX idx_plt_spans_operation ON plt_spans(operation_name, start_time);
CREATE INDEX idx_plt_spans_status ON plt_spans(status, start_time);
CREATE INDEX idx_plt_spans_duration_simple ON plt_spans(duration_ms);  -- Standard Edition compatible
CREATE INDEX idx_plt_spans_tenant ON plt_spans(tenant_id, start_time);  -- NEW: Tenant isolation
CREATE INDEX idx_plt_spans_tenant_op ON plt_spans(tenant_id, operation_name, start_time);  -- NEW: Tenant + operation
CREATE INDEX idx_plt_spans_tenant_status ON plt_spans(tenant_id, status, start_time);  -- NEW: Tenant + status

-- Events indexes (tenant-aware)
CREATE INDEX idx_plt_events_span_id ON plt_events(span_id, event_time);
CREATE INDEX idx_plt_events_name ON plt_events(event_name, event_time);
CREATE INDEX idx_plt_events_time ON plt_events(event_time);
CREATE INDEX idx_plt_events_tenant ON plt_events(tenant_id, event_time);  -- NEW: Tenant isolation

-- Metrics indexes (tenant-aware) - CRITICAL for enterprise dashboards
CREATE INDEX idx_plt_metrics_name ON plt_metrics(metric_name, timestamp);
CREATE INDEX idx_plt_metrics_trace ON plt_metrics(trace_id, timestamp);
CREATE INDEX idx_plt_metrics_span ON plt_metrics(span_id, timestamp);
CREATE INDEX idx_plt_metrics_time ON plt_metrics(timestamp);
CREATE INDEX idx_plt_metrics_value ON plt_metrics(metric_name, metric_value, timestamp);
CREATE INDEX idx_plt_metrics_tenant ON plt_metrics(tenant_id, timestamp);  -- NEW: Tenant isolation
CREATE INDEX idx_plt_metrics_tenant_name ON plt_metrics(tenant_id, metric_name, timestamp);  -- NEW: Tenant + metric
CREATE INDEX idx_plt_metrics_tenant_daily ON plt_metrics(tenant_id, TRUNC(timestamp), metric_name);  -- NEW: Daily aggregations

-- Queue indexes (tenant-aware for async processing)
CREATE INDEX idx_plt_queue_processed ON plt_queue(processed, process_attempts, created_at);
CREATE INDEX idx_plt_queue_created ON plt_queue(created_at);
CREATE INDEX idx_plt_queue_processed_time ON plt_queue(processed_time);
CREATE INDEX idx_plt_queue_attempts ON plt_queue(process_attempts, last_attempt_time);
CREATE INDEX idx_plt_queue_tenant ON plt_queue(tenant_id, processed, created_at);  -- NEW: Tenant queue processing

-- Failed exports indexes (tenant-aware)
CREATE INDEX idx_plt_failed_exports_time ON plt_failed_exports(export_time);
CREATE INDEX idx_plt_failed_exports_status ON plt_failed_exports(http_status, export_time);
CREATE INDEX idx_plt_failed_exports_retry ON plt_failed_exports(retry_count, last_retry);
CREATE INDEX idx_plt_failed_exports_tenant ON plt_failed_exports(tenant_id, export_time);  -- NEW: Tenant failures

-- Error logging indexes (tenant-aware)
CREATE INDEX idx_plt_telemetry_errors_time ON plt_telemetry_errors(error_time);
CREATE INDEX idx_plt_telemetry_errors_trace ON plt_telemetry_errors(trace_id);
CREATE INDEX idx_plt_telemetry_errors_span ON plt_telemetry_errors(span_id);
CREATE INDEX idx_plt_telemetry_errors_module ON plt_telemetry_errors(module_name, error_time);
CREATE INDEX idx_plt_telemetry_errors_code ON plt_telemetry_errors(error_code, error_time);
CREATE INDEX idx_plt_telemetry_errors_tenant ON plt_telemetry_errors(tenant_id, error_time);  -- NEW: Tenant errors

-- Logs indexes (tenant-aware) - CRITICAL for enterprise log analysis
CREATE INDEX idx_plt_logs_trace_id ON plt_logs(trace_id);
CREATE INDEX idx_plt_logs_span_id ON plt_logs(span_id);
CREATE INDEX idx_plt_logs_timestamp ON plt_logs(timestamp);
CREATE INDEX idx_plt_logs_level_time ON plt_logs(log_level, timestamp);
CREATE INDEX idx_plt_logs_tenant ON plt_logs(tenant_id, timestamp);  -- NEW: Tenant isolation
CREATE INDEX idx_plt_logs_tenant_level ON plt_logs(tenant_id, log_level, timestamp);  -- NEW: Tenant + level
CREATE INDEX idx_plt_logs_tenant_daily ON plt_logs(tenant_id, TRUNC(timestamp), log_level);  -- NEW: Daily log analysis

-- Span attributes indexes (tenant-aware)
CREATE INDEX plt_span_attr_span_idx ON plt_span_attributes(span_id);
CREATE INDEX plt_span_attr_key_idx ON plt_span_attributes(attribute_key);
CREATE INDEX plt_span_attr_value_idx ON plt_span_attributes(attribute_key, attribute_value);
CREATE INDEX plt_span_attr_tenant_idx ON plt_span_attributes(tenant_id, attribute_key);  -- NEW: Tenant attributes

-- Composite indexes for common query patterns (Standard Edition compatible)
CREATE INDEX idx_plt_trace_span_lookup ON plt_spans(trace_id, span_id);
CREATE INDEX idx_plt_active_spans_simple ON plt_spans(trace_id, end_time);  -- Standard Edition compatible
CREATE INDEX idx_plt_error_spans_simple ON plt_spans(trace_id, status);  -- Standard Edition compatible

-- Function-based indexes for common operations (Standard Edition compatible)
CREATE INDEX idx_plt_queue_failed ON plt_queue(CASE WHEN process_attempts >= 3 THEN process_attempts END);
CREATE INDEX idx_plt_queue_pending ON plt_queue(CASE WHEN processed = 'N' THEN created_at END);

-- Indexes for distributed tracing patterns (Standard Edition compatible)
CREATE INDEX idx_plt_logs_distributed ON plt_logs(CASE WHEN trace_id IS NOT NULL THEN trace_id END, log_level, timestamp);
CREATE INDEX idx_plt_metrics_distributed ON plt_metrics(CASE WHEN trace_id IS NOT NULL THEN trace_id END, metric_name, timestamp);
CREATE INDEX idx_plt_tenant_traces ON plt_traces(CASE WHEN tenant_id IS NOT NULL THEN tenant_id END, start_time);
CREATE INDEX idx_plt_tenant_active_spans ON plt_spans(CASE WHEN end_time IS NULL AND tenant_id IS NOT NULL THEN tenant_id END, trace_id);

-- Alternative simple indexes for the failed WHERE conditions
CREATE INDEX idx_plt_spans_duration_simple ON plt_spans(duration_ms);  -- Remove WHERE clause
CREATE INDEX idx_plt_active_spans_simple ON plt_spans(trace_id, end_time);  -- Remove WHERE clause
CREATE INDEX idx_plt_error_spans_simple ON plt_spans(trace_id, status);  -- Remove WHERE clause

-- NEW: Enterprise partitioning-ready indexes (for future table partitioning)
CREATE INDEX idx_plt_metrics_part_ready ON plt_metrics(tenant_id, TRUNC(timestamp, 'MM'), metric_name);  -- Monthly partitions
CREATE INDEX idx_plt_logs_part_ready ON plt_logs(tenant_id, TRUNC(timestamp, 'MM'), log_level);  -- Monthly partitions

-- Bitmap indexes for low-cardinality columns (Enterprise Edition only)
-- Uncomment these if you have Oracle Enterprise Edition and large data volumes
-- CREATE BITMAP INDEX idx_plt_queue_processed_bmp ON plt_queue(processed);
-- CREATE BITMAP INDEX idx_plt_spans_status_bmp ON plt_spans(status);
-- CREATE BITMAP INDEX idx_plt_logs_level_bmp ON plt_logs(log_level);
-- CREATE BITMAP INDEX idx_plt_tenant_bmp ON plt_traces(tenant_id);  -- NEW: Tenant bitmap

PROMPT PLTelemetry indexes created successfully.
PROMPT
PROMPT Index Summary:
PROMPT - 40+ indexes created for optimal query performance
PROMPT - Queue processing optimized for async operations
PROMPT - Time-based indexes for efficient data retention
PROMPT - Error analysis and monitoring support
PROMPT - Distributed tracing pattern optimization
PROMPT - Log level filtering optimization
PROMPT - ENTERPRISE: Multi-tenant isolation and performance
PROMPT - ENTERPRISE: Daily/monthly aggregation support
PROMPT - ENTERPRISE: Partitioning-ready for massive scale
PROMPT - Distributed tracing pattern optimization
PROMPT - Log level filtering optimization