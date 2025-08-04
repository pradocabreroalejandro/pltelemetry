-- =====================================================
-- PLTelemetry - Cleanup Jobs (Fixed Version)
-- Database maintenance jobs for data retention
-- Execute as PLTELEMETRY user
-- =====================================================

SET SERVEROUTPUT ON

PROMPT Creating PLTelemetry cleanup jobs...

-- =====================================================
-- DROP EXISTING JOBS (Clean approach)
-- =====================================================

BEGIN
    FOR rec IN (
        SELECT job_name 
        FROM user_scheduler_jobs 
        WHERE job_name IN ('PLT_QUEUE_CLEANUP_JOB', 'PLT_TELEMETRY_CLEANUP_JOB', 
                          'PLT_SYSTEM_CLEANUP_JOB', 'PLT_QUEUE_CLEANUP', 'PLT_DATA_CLEANUP')
    ) LOOP
        DBMS_SCHEDULER.DROP_JOB(
            job_name => rec.job_name,
            force    => TRUE
        );
        DBMS_OUTPUT.PUT_LINE('Dropped existing job: ' || rec.job_name);
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('No existing jobs to drop');
END;
/

-- =====================================================
-- JOB 1: PLT_QUEUE CLEANUP (Every 30 minutes)
-- =====================================================

BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_QUEUE_CLEANUP_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
                               DELETE FROM plt_queue 
                               WHERE processed = ''Y'';
                               
                               INSERT INTO plt_telemetry_errors (
                                  error_time, error_message, module_name
                               ) VALUES (
                                  SYSTIMESTAMP, 
                                  ''Queue cleanup: '' || SQL%ROWCOUNT || '' processed rows deleted'',
                                  ''PLT_QUEUE_CLEANUP_JOB''
                               );
                               COMMIT;
                            EXCEPTION
                               WHEN OTHERS THEN
                                  INSERT INTO plt_telemetry_errors (
                                     error_time, error_message, module_name
                                  ) VALUES (
                                     SYSTIMESTAMP, 
                                     ''Queue cleanup failed: '' || SUBSTR(SQLERRM, 1, 200),
                                     ''PLT_QUEUE_CLEANUP_JOB''
                                  );
                                  COMMIT;
                            END;',
        start_date      => SYSTIMESTAMP + INTERVAL '1' MINUTE,
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=30',
        enabled         => TRUE,
        comments        => 'PLTelemetry: Clean processed queue items every 30 minutes'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ PLT_QUEUE_CLEANUP_JOB created - runs every 30 minutes');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Failed to create PLT_QUEUE_CLEANUP_JOB: ' || SQLERRM);
END;
/

-- =====================================================
-- JOB 2: TELEMETRY DATA CLEANUP (Daily at 23:00)
-- =====================================================

BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_TELEMETRY_CLEANUP_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'DECLARE
                               l_cutoff_date TIMESTAMP := SYSTIMESTAMP - 7;  -- 7 days ago
                               l_total_deleted NUMBER := 0;
                               l_deleted NUMBER;
                            BEGIN
                               -- Clean plt_events first (child of spans)
                               DELETE FROM plt_events 
                               WHERE event_time < l_cutoff_date;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Clean plt_span_attributes (child of spans)
                               DELETE FROM plt_span_attributes 
                               WHERE created_at < l_cutoff_date;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Clean plt_spans (child of traces)
                               DELETE FROM plt_spans 
                               WHERE start_time < l_cutoff_date;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Clean plt_traces (parent table)
                               DELETE FROM plt_traces 
                               WHERE start_time < l_cutoff_date;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Clean plt_metrics
                               DELETE FROM plt_metrics 
                               WHERE timestamp < l_cutoff_date;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Clean plt_logs
                               DELETE FROM plt_logs 
                               WHERE timestamp < l_cutoff_date;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Log summary
                               INSERT INTO plt_telemetry_errors (
                                  error_time, error_message, module_name
                               ) VALUES (
                                  SYSTIMESTAMP, 
                                  ''Telemetry cleanup: '' || l_total_deleted || '' total rows deleted (7 days retention)'',
                                  ''PLT_TELEMETRY_CLEANUP_JOB''
                               );
                               
                               COMMIT;
                               
                            EXCEPTION
                               WHEN OTHERS THEN
                                  ROLLBACK;
                                  INSERT INTO plt_telemetry_errors (
                                     error_time, error_message, module_name
                                  ) VALUES (
                                     SYSTIMESTAMP, 
                                     ''Telemetry cleanup failed: '' || SUBSTR(SQLERRM, 1, 200),
                                     ''PLT_TELEMETRY_CLEANUP_JOB''
                                  );
                                  COMMIT;
                            END;',
        start_date      => TRUNC(SYSDATE) + 1 + (23/24),
        repeat_interval => 'FREQ=DAILY;BYHOUR=23;BYMINUTE=0',
        enabled         => TRUE,
        comments        => 'PLTelemetry: Clean telemetry data older than 7 days (daily at 23:00)'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ PLT_TELEMETRY_CLEANUP_JOB created - runs daily at 23:00');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Failed to create PLT_TELEMETRY_CLEANUP_JOB: ' || SQLERRM);
END;
/

-- =====================================================
-- JOB 3: SYSTEM TABLES CLEANUP (Daily at 23:05)
-- =====================================================

BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_SYSTEM_CLEANUP_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'DECLARE
                               l_cutoff_date TIMESTAMP := SYSTIMESTAMP - 7;  -- 7 days ago
                               l_total_deleted NUMBER := 0;
                               l_deleted NUMBER;
                            BEGIN
                               -- Clean plt_telemetry_errors (keep some for reference)
                               DELETE FROM plt_telemetry_errors 
                               WHERE error_time < l_cutoff_date
                               AND module_name NOT LIKE ''%CLEANUP%'';  -- Keep cleanup logs longer
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Clean plt_failed_exports
                               DELETE FROM plt_failed_exports 
                               WHERE export_time < l_cutoff_date;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Clean plt_fallback_metrics
                               DELETE FROM plt_fallback_metrics 
                               WHERE metric_time < l_cutoff_date;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Clean db_validation_results
                               DELETE FROM db_validation_results 
                               WHERE check_timestamp < l_cutoff_date;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Clean old failed queue entries (safety net)
                               DELETE FROM plt_queue 
                               WHERE created_at < l_cutoff_date 
                               AND processed = ''N'' 
                               AND process_attempts >= 3;
                               l_deleted := SQL%ROWCOUNT;
                               l_total_deleted := l_total_deleted + l_deleted;
                               
                               -- Log summary
                               INSERT INTO plt_telemetry_errors (
                                  error_time, error_message, module_name
                               ) VALUES (
                                  SYSTIMESTAMP, 
                                  ''System cleanup: '' || l_total_deleted || '' total rows deleted (7 days retention)'',
                                  ''PLT_SYSTEM_CLEANUP_JOB''
                               );
                               
                               COMMIT;
                               
                            EXCEPTION
                               WHEN OTHERS THEN
                                  ROLLBACK;
                                  INSERT INTO plt_telemetry_errors (
                                     error_time, error_message, module_name
                                  ) VALUES (
                                     SYSTIMESTAMP, 
                                     ''System cleanup failed: '' || SUBSTR(SQLERRM, 1, 200),
                                     ''PLT_SYSTEM_CLEANUP_JOB''
                                  );
                                  COMMIT;
                            END;',
        start_date      => TRUNC(SYSDATE) + 1 + (23/24) + (5/1440),
        repeat_interval => 'FREQ=DAILY;BYHOUR=23;BYMINUTE=5',
        enabled         => TRUE,
        comments        => 'PLTelemetry: Clean system tables older than 7 days (daily at 23:05)'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ PLT_SYSTEM_CLEANUP_JOB created - runs daily at 23:05');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Failed to create PLT_SYSTEM_CLEANUP_JOB: ' || SQLERRM);
END;
/

-- =====================================================
-- VERIFICATION AND STATUS
-- =====================================================

PROMPT
PROMPT === Job Status Verification ===

SELECT 
    job_name,
    enabled,
    state,
    next_run_date,
    repeat_interval,
    comments
FROM user_scheduler_jobs 
WHERE job_name LIKE 'PLT_%_CLEANUP_JOB'
ORDER BY job_name;

PROMPT
PROMPT === Job Run History (if any) ===

SELECT 
    job_name,
    log_date,
    status,
    run_duration,
    additional_info
FROM user_scheduler_job_run_details 
WHERE job_name LIKE 'PLT_%_CLEANUP_JOB'
ORDER BY log_date DESC, job_name;

PROMPT
PROMPT =====================================================
PROMPT PLTelemetry Cleanup Jobs Created Successfully
PROMPT =====================================================
PROMPT 
PROMPT Jobs created:
PROMPT 1. PLT_QUEUE_CLEANUP_JOB      - Every 30 minutes
PROMPT 2. PLT_TELEMETRY_CLEANUP_JOB  - Daily at 23:00
PROMPT 3. PLT_SYSTEM_CLEANUP_JOB     - Daily at 23:05
PROMPT 
PROMPT Data retention:
PROMPT - Queue processed items: Immediate cleanup
PROMPT - Telemetry data: 7 days retention
PROMPT - System/error tables: 7 days retention
PROMPT 
PROMPT All jobs are ENABLED and will start automatically
PROMPT =====================================================

-- Quick cleanup stats query for monitoring
PROMPT
PROMPT === Current Data Volume (for monitoring) ===

SELECT 'plt_queue' as table_name, 
       COUNT(*) as total_rows,
       SUM(CASE WHEN processed = 'Y' THEN 1 ELSE 0 END) as processed_rows,
       SUM(CASE WHEN processed = 'N' THEN 1 ELSE 0 END) as pending_rows
FROM plt_queue
UNION ALL
SELECT 'plt_traces', COUNT(*), 
       SUM(CASE WHEN start_time < SYSTIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END),
       SUM(CASE WHEN start_time >= SYSTIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END)
FROM plt_traces
UNION ALL
SELECT 'plt_spans', COUNT(*), 
       SUM(CASE WHEN start_time < SYSTIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END),
       SUM(CASE WHEN start_time >= SYSTIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END)
FROM plt_spans
UNION ALL
SELECT 'plt_metrics', COUNT(*), 
       SUM(CASE WHEN timestamp < SYSTIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END),
       SUM(CASE WHEN timestamp >= SYSTIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END)
FROM plt_metrics
UNION ALL
SELECT 'plt_logs', COUNT(*), 
       SUM(CASE WHEN timestamp < SYSTIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END),
       SUM(CASE WHEN timestamp >= SYSTIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END)
FROM plt_logs;