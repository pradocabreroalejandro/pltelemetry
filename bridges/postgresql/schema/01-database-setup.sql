-- PLTelemetry PostgreSQL Database Schema
-- Professional setup with dedicated database, schema and users
-- 
-- Database: pltelemetry_db
-- Schema: telemetry
-- Users: 
--   - pltel_admin: Full access for setup/maintenance
--   - pltel_writer: Write access for Oracle PL/SQL
--   - pltel_reader: Read access for Grafana
--
-- Tables created:
-- - telemetry.traces: Main trace records
-- - telemetry.spans: Span records within traces  
-- - telemetry.events: Events within spans
-- - telemetry.metrics: Metric records
-- - telemetry.queue: Async processing queue
-- - telemetry.failed_exports: Failed export attempts
-- - telemetry.telemetry_errors: Error logging

-- ========================================================================
-- STEP 1: Database and Users Setup (run as postgres superuser)
-- ========================================================================

-- Create dedicated database
CREATE DATABASE pltelemetry_db
    WITH ENCODING 'UTF8'
    LC_COLLATE = 'en_US.UTF-8'
    LC_CTYPE = 'en_US.UTF-8'
    TEMPLATE = template0;

-- Connect to the new database
\c pltelemetry_db;

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "btree_gin";

-- Create users with specific roles
CREATE USER pltel_admin WITH PASSWORD 'PltAdmin2025!';
CREATE USER pltel_writer WITH PASSWORD 'PltWriter2025!';
CREATE USER pltel_reader WITH PASSWORD 'PltReader2025!';

-- Grant database access
GRANT CONNECT ON DATABASE pltelemetry_db TO pltel_admin, pltel_writer, pltel_reader;


-- ========================================================================
-- STEP 2: Schema and Tables Setup
-- ========================================================================

-- Create dedicated schema
CREATE SCHEMA IF NOT EXISTS telemetry;

-- Set search path for this session
SET search_path TO telemetry, public;

-- Drop existing tables if they exist (for reinstall)
DROP TABLE IF EXISTS telemetry.telemetry_errors CASCADE;
DROP TABLE IF EXISTS telemetry.failed_exports CASCADE;
DROP TABLE IF EXISTS telemetry.queue CASCADE;
DROP TABLE IF EXISTS telemetry.metrics CASCADE;
DROP TABLE IF EXISTS telemetry.events CASCADE;
DROP TABLE IF EXISTS telemetry.spans CASCADE;
DROP TABLE IF EXISTS telemetry.traces CASCADE;

-- ========================================================================
-- STEP 3: Core Tables
-- ========================================================================

-- Main traces table
CREATE TABLE telemetry.traces (
    trace_id VARCHAR(32) PRIMARY KEY,
    root_operation VARCHAR(255) NOT NULL,
    start_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    end_time TIMESTAMPTZ,
    service_name VARCHAR(100) NOT NULL DEFAULT 'oracle-plsql',
    service_instance VARCHAR(255),
    created_by VARCHAR(100) DEFAULT SESSION_USER,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE telemetry.traces IS 'OpenTelemetry traces - root operations';
COMMENT ON COLUMN telemetry.traces.trace_id IS '128-bit trace ID (32 hex chars)';
COMMENT ON COLUMN telemetry.traces.root_operation IS 'Name of the root operation';
COMMENT ON COLUMN telemetry.traces.service_name IS 'Service identifier';
COMMENT ON COLUMN telemetry.traces.service_instance IS 'Service instance identifier';

-- Spans table
CREATE TABLE telemetry.spans (
    span_id VARCHAR(16) PRIMARY KEY,
    trace_id VARCHAR(32) NOT NULL,
    parent_span_id VARCHAR(16),
    operation_name VARCHAR(255) NOT NULL,
    start_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    end_time TIMESTAMPTZ,
    duration_ms DECIMAL(15,3),
    status VARCHAR(50) NOT NULL DEFAULT 'RUNNING',
    created_by VARCHAR(100) DEFAULT SESSION_USER,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT fk_spans_trace FOREIGN KEY (trace_id) REFERENCES telemetry.traces(trace_id) ON DELETE CASCADE,
    CONSTRAINT fk_spans_parent FOREIGN KEY (parent_span_id) REFERENCES telemetry.spans(span_id) ON DELETE SET NULL,
    CONSTRAINT chk_spans_status CHECK (status IN ('RUNNING', 'OK', 'ERROR', 'CANCELLED'))
);

COMMENT ON TABLE telemetry.spans IS 'OpenTelemetry spans - individual operations within traces';
COMMENT ON COLUMN telemetry.spans.span_id IS '64-bit span ID (16 hex chars)';
COMMENT ON COLUMN telemetry.spans.parent_span_id IS 'Parent span for nested operations';
COMMENT ON COLUMN telemetry.spans.duration_ms IS 'Span duration in milliseconds';

-- Events table
CREATE TABLE telemetry.events (
    event_id BIGSERIAL PRIMARY KEY,
    span_id VARCHAR(16) NOT NULL,
    event_name VARCHAR(255) NOT NULL,
    event_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attributes JSONB,
    created_by VARCHAR(100) DEFAULT SESSION_USER,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT fk_events_span FOREIGN KEY (span_id) REFERENCES telemetry.spans(span_id) ON DELETE CASCADE
);

COMMENT ON TABLE telemetry.events IS 'Events within spans - point-in-time occurrences';
COMMENT ON COLUMN telemetry.events.attributes IS 'JSON attributes for the event';

-- Metrics table
CREATE TABLE telemetry.metrics (
    metric_id BIGSERIAL PRIMARY KEY,
    metric_name VARCHAR(255) NOT NULL,
    metric_value DECIMAL(20,6) NOT NULL,
    metric_unit VARCHAR(50),
    trace_id VARCHAR(32),
    span_id VARCHAR(16),
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attributes JSONB,
    created_by VARCHAR(100) DEFAULT SESSION_USER,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT fk_metrics_trace FOREIGN KEY (trace_id) REFERENCES telemetry.traces(trace_id) ON DELETE SET NULL,
    CONSTRAINT fk_metrics_span FOREIGN KEY (span_id) REFERENCES telemetry.spans(span_id) ON DELETE SET NULL
);

COMMENT ON TABLE telemetry.metrics IS 'Application metrics with telemetry context';
COMMENT ON COLUMN telemetry.metrics.metric_unit IS 'Unit of measurement (ms, bytes, requests, etc.)';
COMMENT ON COLUMN telemetry.metrics.attributes IS 'JSON attributes for the metric';

-- Failed exports table
CREATE TABLE telemetry.failed_exports (
    export_id BIGSERIAL PRIMARY KEY,
    export_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    http_status INTEGER,
    payload TEXT,
    error_message TEXT,
    retry_count INTEGER NOT NULL DEFAULT 0,
    last_retry TIMESTAMPTZ,
    created_by VARCHAR(100) DEFAULT SESSION_USER,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE telemetry.failed_exports IS 'Failed telemetry export attempts for debugging';
COMMENT ON COLUMN telemetry.failed_exports.payload IS 'Payload that failed to export';

-- Async processing queue
CREATE TABLE telemetry.queue (
    queue_id BIGSERIAL PRIMARY KEY,
    payload TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed BOOLEAN NOT NULL DEFAULT FALSE,
    process_attempts INTEGER NOT NULL DEFAULT 0,
    processed_time TIMESTAMPTZ,
    last_error TEXT,
    last_attempt_time TIMESTAMPTZ,
    created_by VARCHAR(100) DEFAULT SESSION_USER
);

COMMENT ON TABLE telemetry.queue IS 'Async processing queue for telemetry export';
COMMENT ON COLUMN telemetry.queue.payload IS 'JSON payload to be exported';
COMMENT ON COLUMN telemetry.queue.process_attempts IS 'Number of processing attempts (max 3)';

-- Error logging table
CREATE TABLE telemetry.telemetry_errors (
    error_id BIGSERIAL PRIMARY KEY,
    error_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error_message TEXT,
    error_stack TEXT,
    error_code INTEGER,
    module_name VARCHAR(100),
    trace_id VARCHAR(32),
    span_id VARCHAR(16),
    session_user_id VARCHAR(128) DEFAULT SESSION_USER,
    os_user VARCHAR(128),
    host VARCHAR(256),
    ip_address INET,
    created_by VARCHAR(100) DEFAULT SESSION_USER,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE telemetry.telemetry_errors IS 'Internal error logging for PLTelemetry operations';
COMMENT ON COLUMN telemetry.telemetry_errors.module_name IS 'PLTelemetry module where error occurred';

-- ========================================================================
-- STEP 4: Performance Indexes
-- ========================================================================

-- Traces indexes
CREATE INDEX idx_telemetry_traces_start_time ON telemetry.traces(start_time);
CREATE INDEX idx_telemetry_traces_service ON telemetry.traces(service_name, start_time);
CREATE INDEX idx_telemetry_traces_operation ON telemetry.traces(root_operation, start_time);
CREATE INDEX idx_telemetry_traces_created_at ON telemetry.traces(created_at);

-- Spans indexes
CREATE INDEX idx_telemetry_spans_trace_id ON telemetry.spans(trace_id, start_time);
CREATE INDEX idx_telemetry_spans_parent ON telemetry.spans(parent_span_id, start_time);
CREATE INDEX idx_telemetry_spans_operation ON telemetry.spans(operation_name, start_time);
CREATE INDEX idx_telemetry_spans_status ON telemetry.spans(status, start_time);
CREATE INDEX idx_telemetry_spans_duration ON telemetry.spans(duration_ms) WHERE duration_ms IS NOT NULL;

-- Events indexes
CREATE INDEX idx_telemetry_events_span_id ON telemetry.events(span_id, event_time);
CREATE INDEX idx_telemetry_events_name ON telemetry.events(event_name, event_time);
CREATE INDEX idx_telemetry_events_time ON telemetry.events(event_time);

-- Metrics indexes
CREATE INDEX idx_telemetry_metrics_name ON telemetry.metrics(metric_name, timestamp);
CREATE INDEX idx_telemetry_metrics_trace ON telemetry.metrics(trace_id, timestamp);
CREATE INDEX idx_telemetry_metrics_span ON telemetry.metrics(span_id, timestamp);
CREATE INDEX idx_telemetry_metrics_time ON telemetry.metrics(timestamp);
CREATE INDEX idx_telemetry_metrics_value ON telemetry.metrics(metric_name, metric_value, timestamp);

-- Queue indexes (for async processing performance)
CREATE INDEX idx_telemetry_queue_processed ON telemetry.queue(processed, process_attempts, created_at);
CREATE INDEX idx_telemetry_queue_created ON telemetry.queue(created_at);
CREATE INDEX idx_telemetry_queue_processed_time ON telemetry.queue(processed_time);
CREATE INDEX idx_telemetry_queue_attempts ON telemetry.queue(process_attempts, last_attempt_time);

-- Failed exports indexes
CREATE INDEX idx_telemetry_failed_exports_time ON telemetry.failed_exports(export_time);
CREATE INDEX idx_telemetry_failed_exports_status ON telemetry.failed_exports(http_status, export_time);
CREATE INDEX idx_telemetry_failed_exports_retry ON telemetry.failed_exports(retry_count, last_retry);

-- Error logging indexes
CREATE INDEX idx_telemetry_errors_time ON telemetry.telemetry_errors(error_time);
CREATE INDEX idx_telemetry_errors_trace ON telemetry.telemetry_errors(trace_id);
CREATE INDEX idx_telemetry_errors_span ON telemetry.telemetry_errors(span_id);
CREATE INDEX idx_telemetry_errors_module ON telemetry.telemetry_errors(module_name, error_time);
CREATE INDEX idx_telemetry_errors_code ON telemetry.telemetry_errors(error_code, error_time);

-- Composite indexes for common query patterns
CREATE INDEX idx_telemetry_trace_span_lookup ON telemetry.spans(trace_id, span_id);
CREATE INDEX idx_telemetry_active_spans ON telemetry.spans(trace_id, end_time) WHERE end_time IS NULL;
CREATE INDEX idx_telemetry_error_spans ON telemetry.spans(trace_id, status) WHERE status = 'ERROR';

-- Function-based indexes for common operations
CREATE INDEX idx_telemetry_queue_failed ON telemetry.queue(process_attempts) WHERE process_attempts >= 3;
CREATE INDEX idx_telemetry_queue_pending ON telemetry.queue(created_at) WHERE processed = FALSE;

-- JSONB indexes for attributes
CREATE INDEX idx_telemetry_events_attributes ON telemetry.events USING GIN (attributes);
CREATE INDEX idx_telemetry_metrics_attributes ON telemetry.metrics USING GIN (attributes);

-- Full text search indexes
CREATE INDEX idx_telemetry_traces_operation_fts ON telemetry.traces USING GIN (to_tsvector('english', root_operation));
CREATE INDEX idx_telemetry_spans_operation_fts ON telemetry.spans USING GIN (to_tsvector('english', operation_name));

-- ========================================================================
-- STEP 5: User Permissions and Security
-- ========================================================================

-- Admin user: Full access to telemetry schema
GRANT ALL PRIVILEGES ON SCHEMA telemetry TO pltel_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA telemetry TO pltel_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA telemetry TO pltel_admin;

-- Writer user: Insert/Update access for Oracle PL/SQL
GRANT USAGE ON SCHEMA telemetry TO pltel_writer;
GRANT INSERT, UPDATE ON telemetry.traces TO pltel_writer;
GRANT INSERT, UPDATE ON telemetry.spans TO pltel_writer;
GRANT INSERT ON telemetry.events TO pltel_writer;
GRANT INSERT ON telemetry.metrics TO pltel_writer;
GRANT INSERT ON telemetry.queue TO pltel_writer;
GRANT INSERT ON telemetry.failed_exports TO pltel_writer;
GRANT INSERT ON telemetry.telemetry_errors TO pltel_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA telemetry TO pltel_writer;

-- Reader user: Read-only access for Grafana
GRANT USAGE ON SCHEMA telemetry TO pltel_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA telemetry TO pltel_reader;