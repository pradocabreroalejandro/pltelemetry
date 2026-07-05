-- =============================================================================
-- PLT_ENABLE_TRACING.sql - Enable All Tracing & Diagnostics
-- =============================================================================
-- Run as: sqlplus PLTELEMETRY/plt@//localhost:1521/FREEPDB1 @PLT_ENABLE_TRACING.sql
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET FEEDBACK ON;
SET VERIFY OFF;
SET LINESIZE 200;

PROMPT
PROMPT =========================================================================
PROMPT ENABLING PLTELEMETRY TRACING
PROMPT =========================================================================
PROMPT

-- =============================================================================
-- 1. CHECK IF PACKAGES EXIST
-- =============================================================================
PROMPT
PROMPT === Checking installed packages ===
SELECT object_name, object_type, status 
FROM user_objects 
WHERE object_name LIKE 'PLT%' 
  AND object_type IN ('PACKAGE', 'PACKAGE BODY')
ORDER BY object_name;

-- =============================================================================
-- 2. ENABLE ALL ACTIVATION RULES (Critical for tracing to work)
-- =============================================================================
PROMPT
PROMPT === Enabling activation rules (100% sampling) ===
UPDATE plt_activation_rules 
SET is_enabled = 'Y', 
    sample_rate = 1.0 
WHERE object_pattern = '*';

COMMIT;

-- =============================================================================
-- 3. ENABLE ALL METRIC COLLECTORS
-- =============================================================================
PROMPT
PROMPT === Enabling all metric collectors ===
UPDATE plt_metric_collectors 
SET is_enabled = 1 
WHERE is_enabled = 0;

COMMIT;

-- =============================================================================
-- 4. DISPLAY CURRENT CONFIGURATION
-- =============================================================================
PROMPT
PROMPT === Current Activation Rules ===
SELECT object_pattern, is_enabled, sample_rate FROM plt_activation_rules;

PROMPT
PROMPT === Current Metric Collectors ===
SELECT collector_code, 
       reader_package || '.' || reader_function as reader,
       interval_seconds,
       is_enabled,
       TO_CHAR(last_run, 'YYYY-MM-DD HH24:MI:SS') as last_run
FROM plt_metric_collectors
ORDER BY collector_code;

-- =============================================================================
-- 5. TEST: Direct function call (bypass monitor logic)
-- =============================================================================
PROMPT
PROMPT === Testing get_system_metrics function directly ===
SELECT COUNT(*) as metrics_count 
FROM TABLE(PLT_DB_METRIC_READER.get_system_metrics);

PROMPT
PROMPT === Testing get_session_metrics function directly ===
SELECT COUNT(*) as metrics_count 
FROM TABLE(PLT_DB_METRIC_READER.get_session_metrics);

-- =============================================================================
-- 6. INSERT METRICS MANUALLY USING PLTelemetry API
-- =============================================================================
PROMPT
PROMPT === Inserting test metrics via PLTelemetry API ===
BEGIN
    -- Test metric 1
    PLTelemetry.log_metric('plt_health_check', 1, 'GAUGE');
    
    -- Test metric 2: System metrics
    FOR r IN (SELECT * FROM TABLE(PLT_DB_METRIC_READER.get_system_metrics)) LOOP
        PLTelemetry.log_metric(
            p_name  => r.metric_name,
            p_value => r.metric_value,
            p_type  => r.metric_type
        );
    END LOOP;
    
    -- Test metric 3: Session metrics
    FOR r IN (SELECT * FROM TABLE(PLT_DB_METRIC_READER.get_session_metrics)) LOOP
        PLTelemetry.log_metric(
            p_name  => r.metric_name,
            p_value => r.metric_value,
            p_type  => r.metric_type
        );
    END LOOP;
    
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Metrics inserted successfully!');
EXCEPTION 
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        ROLLBACK;
END;
/

-- =============================================================================
-- 7. VERIFY QUEUE HAS ITEMS
-- =============================================================================
PROMPT
PROMPT === Queue Status (should show items now) ===
SELECT item_type, status, COUNT(*) as count
FROM plt_queue_reader
GROUP BY item_type, status
ORDER BY item_type, status;

PROMPT
PROMPT === Last 10 Queue Items ===
SELECT id, item_type, status, tenant_id, TO_CHAR(created_at, 'HH24:MI:SS') as created_at
FROM plt_queue_reader
ORDER BY id DESC
FETCH FIRST 10 ROWS ONLY;

-- =============================================================================
-- 8. CHECK ERRORS
-- =============================================================================
PROMPT
PROMPT === Recent Errors ===
SELECT TO_CHAR(error_time, 'YYYY-MM-DD HH24:MI:SS') as error_time,
       module_name,
       SUBSTR(error_message, 1, 100) as error_msg
FROM plt_telemetry_errors
ORDER BY error_time DESC
FETCH FIRST 5 ROWS ONLY;

PROMPT
PROMPT =========================================================================
PROMPT DIAGNOSTIC COMPLETE
PROMPT =========================================================================
PROMPT 
PROMPT If queue is STILL empty, the packages are not installed. Run:
PROMPT   python install.py
PROMPT   OR manually: @src/ddl/00_types.sql @src/ddl/01_tables.sql ... etc.
PROMPT

EXIT;
