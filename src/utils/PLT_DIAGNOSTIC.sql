-- =============================================================================
-- PLT_DIAGNOSTIC.sql - Health Check & Troubleshooting Script
-- =============================================================================
-- Run as: sqlplus PLTELEMETRY/plt@//localhost:1521/FREEPDB1 @PLT_DIAGNOSTIC.sql
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET LINESIZE 200;
SET PAGESIZE 100;
SET DEFINE OFF;
SET TIMING ON;

PROMPT
PROMPT =========================================================================
PROMPT PLTELEMETRY DIAGNOSTIC SUITE
PROMPT =========================================================================
PROMPT

-- =============================================================================
-- 1. SCHEDULER JOBS STATUS
-- =============================================================================
PROMPT
PROMPT === SCHEDULER JOBS STATUS ===
SELECT job_name, 
       enabled, 
       state, 
       TO_CHAR(last_start_date, 'YYYY-MM-DD HH24:MI:SS') as last_start,
       TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI:SS') as next_run,
       failure_count
FROM user_scheduler_jobs
WHERE job_name LIKE 'PLT%'
ORDER BY job_name;

-- =============================================================================
-- 2. METRIC COLLECTORS CONFIGURATION
-- =============================================================================
PROMPT
PROMPT === METRIC COLLECTORS CONFIG ===
SELECT collector_code, 
       reader_package || '.' || reader_function as reader,
       interval_seconds,
       execution_scope,
       is_enabled,
       TO_CHAR(last_run, 'YYYY-MM-DD HH24:MI:SS') as last_run
FROM plt_metric_collectors
ORDER BY collector_code;

-- =============================================================================
-- 3. QUEUE STATUS
-- =============================================================================
PROMPT
PROMPT === QUEUE STATUS ===
SELECT item_type, 
       status, 
       COUNT(*) as count,
       TO_CHAR(MIN(created_at), 'YYYY-MM-DD HH24:MI:SS') as oldest_item,
       TO_CHAR(MAX(created_at), 'YYYY-MM-DD HH24:MI:SS') as newest_item
FROM plt_queue_reader
GROUP BY item_type, status
ORDER BY item_type, status;

-- =============================================================================
-- 4. QUEUE REGISTRY (Rotation Status)
-- =============================================================================
PROMPT
PROMPT === QUEUE REGISTRY ===
SELECT partition_name, 
       is_active, 
       state, 
       row_count_est,
       TO_CHAR(last_truncate, 'YYYY-MM-DD HH24:MI:SS') as last_truncate
FROM plt_queue_registry
ORDER BY partition_name;

-- =============================================================================
-- 5. AGENT REGISTRY (Heartbeat)
-- =============================================================================
PROMPT
PROMPT === AGENT REGISTRY ===
SELECT agent_id,
       pulse_mode,
       system_heat,
       TO_CHAR(last_heartbeat, 'YYYY-MM-DD HH24:MI:SS') as last_heartbeat,
       TO_CHAR(last_process_time, 'YYYY-MM-DD HH24:MI:SS') as last_process,
       items_processed,
       status_message
FROM plt_agent_registry
ORDER BY agent_id;

-- =============================================================================
-- 6. OTLP CONFIGURATION
-- =============================================================================
PROMPT
PROMPT === OTLP CONFIGURATION ===
SELECT config_group, 
       config_key, 
       config_value, 
       description
FROM plt_sys_config
WHERE config_group = 'OTLP'
ORDER BY config_key;

-- =============================================================================
-- 7. RECENT ERRORS
-- =============================================================================
PROMPT
PROMPT === RECENT ERRORS (Last 10) ===
SELECT TO_CHAR(error_time, 'YYYY-MM-DD HH24:MI:SS') as error_time,
       module_name,
       SUBSTR(error_message, 1, 100) as error_msg
FROM plt_telemetry_errors
ORDER BY error_time DESC
FETCH FIRST 10 ROWS ONLY;

-- =============================================================================
-- 8. ACTIVATION RULES
-- =============================================================================
PROMPT
PROMPT === ACTIVATION RULES ===
SELECT object_pattern, 
       is_enabled, 
       sample_rate,
       TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at
FROM plt_activation_rules
ORDER BY object_pattern;

-- =============================================================================
-- 9. TENANTS
-- =============================================================================
PROMPT
PROMPT === TENANTS ===
SELECT tenant_id, 
       description, 
       CASE is_enabled WHEN 1 THEN 'ENABLED' ELSE 'DISABLED' END as status,
       TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at
FROM plt_tenants
ORDER BY tenant_id;

-- =============================================================================
-- 10. QUICK HEALTH CHECK SUMMARY
-- =============================================================================
PROMPT
PROMPT === HEALTH CHECK SUMMARY ===
SELECT 
    (SELECT COUNT(*) FROM user_scheduler_jobs WHERE job_name LIKE 'PLT%' AND enabled = 1) as enabled_jobs,
    (SELECT COUNT(*) FROM plt_metric_collectors WHERE is_enabled = 1) as active_collectors,
    (SELECT COUNT(*) FROM plt_queue_reader WHERE status = 'NEW') as pending_items,
    (SELECT COUNT(*) FROM plt_queue_reader WHERE status = 'PROCESSED') as processed_items,
    (SELECT COUNT(*) FROM plt_queue_reader WHERE status = 'FAILED') as failed_items,
    (SELECT COUNT(*) FROM plt_telemetry_errors WHERE error_time > SYSTIMESTAMP - INTERVAL '1' HOUR) as errors_last_hour
FROM dual;

PROMPT
PROMPT =========================================================================
PROMPT DIAGNOSTIC COMPLETE
PROMPT =========================================================================
PROMPT
PROMPT If you see issues:
PROMPT   - Jobs not enabled? Run: @04_jobs.sql
PROMPT   - Collectors disabled? Run: UPDATE plt_metric_collectors SET is_enabled=1 WHERE is_enabled=0;
PROMPT   - No pending items? Check if activation rules allow tracing
PROMPT   - Errors in last hour? Check plt_telemetry_errors for details
PROMPT

EXIT;
