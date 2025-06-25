-- PLTelemetry Performance Indexes
-- This script creates indexes for optimal PLTelemetry performance
-- 
-- Indexes created for:
-- - Query performance on common access patterns
-- - Foreign key performance
-- - Queue processing efficiency
-- - Error analysis and monitoring

PROMPT Creating PLTelemetry performance indexes...

-- Traces indexes
CREATE INDEX idx_plt_traces_start_time ON plt_traces(start_time);
CREATE INDEX idx_plt_traces_service ON plt_traces(service_name, start_time);
CREATE INDEX idx_plt_traces_operation ON plt_traces(root_operation, start_time);

-- Spans indexes
CREATE INDEX idx_plt_spans_trace_id ON plt_spans(trace_id, start_time);
CREATE INDEX idx_plt_spans_parent ON plt_spans(parent_span_id, start_time);
CREATE INDEX idx_plt_spans_operation ON plt_spans(operation_name, start_time);
CREATE INDEX idx_plt_spans_status ON plt_spans(status, start_time);
CREATE INDEX idx_plt_spans_duration ON plt_spans(duration_ms) WHERE duration_ms IS NOT NULL;

-- Events indexes
CREATE INDEX idx_plt_events_span_id ON plt_events(span_id, event_time);
CREATE INDEX idx_plt_events_name ON plt_events(event_name, event_time);
CREATE INDEX idx_plt_events_time ON plt_events(event_time);

-- Metrics indexes
CREATE INDEX idx_plt_metrics_name ON plt_metrics(metric_name, timestamp);
CREATE INDEX idx_plt_metrics_trace ON plt_metrics(trace_id, timestamp);
CREATE INDEX idx_plt_metrics_span ON plt_metrics(span_id, timestamp);
CREATE INDEX idx_plt_metrics_time ON plt_metrics(timestamp);
CREATE INDEX idx_plt_metrics_value ON plt_metrics(metric_name, metric_value, timestamp);

-- Queue indexes (for async processing performance)
CREATE INDEX idx_plt_queue_processed ON plt_queue(processed, process_attempts, created_at);
CREATE INDEX idx_plt_queue_created ON plt_queue(created_at);
CREATE INDEX idx_plt_queue_processed_time ON plt_queue(processed_time);
CREATE INDEX idx_plt_queue_attempts ON plt_queue(process_attempts, last_attempt_time);

-- Failed exports indexes
CREATE INDEX idx_plt_failed_exports_time ON plt_failed_exports(export_time);
CREATE INDEX idx_plt_failed_exports_status ON plt_failed_exports(http_status, export_time);
CREATE INDEX idx_plt_failed_exports_retry ON plt_failed_exports(retry_count, last_retry);

-- Error logging indexes
CREATE INDEX idx_plt_telemetry_errors_time ON plt_telemetry_errors(error_time);
CREATE INDEX idx_plt_telemetry_errors_trace ON plt_telemetry_errors(trace_id);
CREATE INDEX idx_plt_telemetry_errors_span ON plt_telemetry_errors(span_id);
CREATE INDEX idx_plt_telemetry_errors_module ON plt_telemetry_errors(module_name, error_time);
CREATE INDEX idx_plt_telemetry_errors_code ON plt_telemetry_errors(error_code, error_time);


CREATE INDEX idx_plt_logs_trace_id ON plt_logs(trace_id);
CREATE INDEX idx_plt_logs_span_id ON plt_logs(span_id);
CREATE INDEX idx_plt_logs_timestamp ON plt_logs(timestamp);

-- Composite indexes for common query patterns
CREATE INDEX idx_plt_trace_span_lookup ON plt_spans(trace_id, span_id);
CREATE INDEX idx_plt_active_spans ON plt_spans(trace_id, end_time) WHERE end_time IS NULL;
CREATE INDEX idx_plt_error_spans ON plt_spans(trace_id, status) WHERE status = 'ERROR';

-- Function-based indexes for common operations
CREATE INDEX idx_plt_queue_failed ON plt_queue(process_attempts) WHERE process_attempts >= 3;
CREATE INDEX idx_plt_queue_pending ON plt_queue(created_at) WHERE processed = 'N';

-- Bitmap indexes for low-cardinality columns (if appropriate for your data volume)
-- Uncomment these if you have Oracle Enterprise Edition and large data volumes
-- CREATE BITMAP INDEX idx_plt_queue_processed_bmp ON plt_queue(processed);
-- CREATE BITMAP INDEX idx_plt_spans_status_bmp ON plt_spans(status);

PROMPT PLTelemetry indexes created successfully.
PROMPT
PROMPT Index Summary:
PROMPT - 25+ indexes created for optimal query performance
PROMPT - Queue processing optimized for async operations
PROMPT - Time-based indexes for efficient data retention
PROMPT - Error analysis and monitoring support