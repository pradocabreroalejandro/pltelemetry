-- PLTelemetry Tables Truncate Script
-- Truncates all PLTelemetry tables in the correct order to respect FK constraints
-- 
-- Order: Child tables first, then parent tables
-- This avoids FK constraint violations during cleanup

PROMPT Truncating PLTelemetry tables in FK-safe order...

-- Step 1: Tables with no dependencies (or that reference others)
PROMPT Truncating child tables...

-- Events (references spans)
TRUNCATE TABLE plt_events;
PROMPT - plt_events truncated

-- Span attributes (references spans)
TRUNCATE TABLE plt_span_attributes;
PROMPT - plt_span_attributes truncated

-- Metrics (references traces and spans)
TRUNCATE TABLE plt_metrics;
PROMPT - plt_metrics truncated

-- Logs (references traces and spans, but with nullable FKs)
TRUNCATE TABLE plt_logs;
PROMPT - plt_logs truncated

-- Step 2: Spans (references traces and parent spans)
PROMPT Truncating spans...
TRUNCATE TABLE plt_spans;
PROMPT - plt_spans truncated

-- Step 3: Traces (root table, no dependencies)
PROMPT Truncating traces...
TRUNCATE TABLE plt_traces;
PROMPT - plt_traces truncated

-- Step 4: Infrastructure tables (no FK dependencies)
PROMPT Truncating infrastructure tables...

-- Queue (independent)
TRUNCATE TABLE plt_queue;
PROMPT - plt_queue truncated

-- Failed exports (independent)
TRUNCATE TABLE plt_failed_exports;
PROMPT - plt_failed_exports truncated

-- Error logging (independent)
TRUNCATE TABLE plt_telemetry_errors;
PROMPT - plt_telemetry_errors truncated

PROMPT 
PROMPT All PLTelemetry tables truncated successfully!
PROMPT 
PROMPT Summary:
PROMPT - 9 tables truncated in FK-safe order
PROMPT - All telemetry data cleared
PROMPT - Ready for fresh data collection
PROMPT