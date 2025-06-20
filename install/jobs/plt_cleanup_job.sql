-- PLTelemetry Cleanup Job
-- This script creates scheduled jobs for data retention and cleanup
-- 
-- Jobs created:
-- 1. PLT_QUEUE_CLEANUP - Removes processed queue entries older than 7 days
-- 2. PLT_DATA_CLEANUP - Archives/removes old telemetry data based on retention policy

PROMPT Creating PLTelemetry cleanup jobs...

-- Drop existing cleanup jobs if they exist
BEGIN
    FOR rec IN (
        SELECT job_name 
        FROM USER_SCHEDULER_JOBS 
        WHERE job_name IN ('PLT_QUEUE_CLEANUP', 'PLT_DATA_CLEANUP')
    ) LOOP
        DBMS_SCHEDULER.DROP_JOB(
            job_name => rec.job_name,
            force    => TRUE
        );
        DBMS_OUTPUT.PUT_LINE('Dropped existing job: ' || rec.job_name);
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN
        NULL; -- Jobs might not exist
END;
/

-- Create queue cleanup job
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLT_QUEUE_CLEANUP',
        job_type        => 'PLSQL_BLOCK',
        job_action      => '
DECLARE
    l_deleted_count NUMBER := 0;
    l_retention_days NUMBER := 7;  -- Configurable retention period
    l_cutoff_date TIMESTAMP WITH TIME ZONE;
BEGIN
    l_cutoff_date := SYSTIMESTAMP - INTERVAL l_retention_days DAY;
    
    -- Delete processed queue entries older than retention period
    DELETE FROM plt_queue 
    WHERE processed = ''Y'' 
      AND processed_time < l_cutoff_date;
    
    l_deleted_count := SQL%ROWCOUNT;
    
    -- Log cleanup activity if significant
    IF l_deleted_count > 0 THEN
        INSERT INTO plt_telemetry_errors (
            error_time,
            error_message,
            module_name
        ) VALUES (
            SYSTIMESTAMP,
            ''Queue cleanup: deleted '' || l_deleted_count || '' processed entries older than '' || l_retention_days || '' days'',
            ''PLT_QUEUE_CLEANUP''
        );
    END IF;
    
    COMMIT;
    
EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO plt_telemetry_errors (
            error_time,
            error_message,
            error_code,
            module_name,
            error_stack
        ) VALUES (
            SYSTIMESTAMP,
            ''Queue cleanup failed: '' || SUBSTR(SQLERRM, 1, 3000),
            SQLCODE,
            ''PLT_QUEUE_CLEANUP'',
            SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 3000)
        );
        COMMIT;
        RAISE;
END;',
        start_date      => TRUNC(SYSDATE + 1) + INTERVAL '3' HOUR,  -- 3 AM tomorrow
        repeat_interval => 'FREQ=DAILY; BYHOUR=3; BYMINUTE=0',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'PLTelemetry queue cleanup - removes processed entries older than 7 days'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ PLT_QUEUE_CLEANUP job created successfully');
END;
/

-- Create comprehensive data cleanup job
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLT_DATA_CLEANUP',
        job_type        => 'PLSQL_BLOCK',
        job_action      => '
DECLARE
    l_retention_days NUMBER := 90;  -- Main data retention: 90 days
    l_error_retention_days NUMBER := 30;  -- Error log retention: 30 days
    l_failed_export_retention_days NUMBER := 14;  -- Failed export retention: 14 days
    l_cutoff_date TIMESTAMP WITH TIME ZONE;
    l_error_cutoff TIMESTAMP WITH TIME ZONE;
    l_export_cutoff TIMESTAMP WITH TIME ZONE;
    l_deleted_count NUMBER;
    l_total_deleted NUMBER := 0;
    
BEGIN
    l_cutoff_date := SYSTIMESTAMP - INTERVAL l_retention_days DAY;
    l_error_cutoff := SYSTIMESTAMP - INTERVAL l_error_retention_days DAY;
    l_export_cutoff := SYSTIMESTAMP - INTERVAL l_failed_export_retention_days DAY;
    
    -- 1. Clean up old events (oldest first, as they depend on spans)
    DELETE FROM plt_events 
    WHERE span_id IN (
        SELECT s.span_id 
        FROM plt_spans s 
        JOIN plt_traces t ON s.trace_id = t.trace_id
        WHERE t.start_time < l_cutoff_date
    );
    l_deleted_count := SQL%ROWCOUNT;
    l_total_deleted := l_total_deleted + l_deleted_count;
    
    -- 2. Clean up old metrics
    DELETE FROM plt_metrics 
    WHERE timestamp < l_cutoff_date;
    l_deleted_count := SQL%ROWCOUNT;
    l_total_deleted := l_total_deleted + l_deleted_count;
    
    -- 3. Clean up old spans
    DELETE FROM plt_spans 
    WHERE trace_id IN (
        SELECT trace_id 
        FROM plt_traces 
        WHERE start_time < l_cutoff_date
    );
    l_deleted_count := SQL%ROWCOUNT;
    l_total_deleted := l_total_deleted + l_deleted_count;
    
    -- 4. Clean up old traces
    DELETE FROM plt_traces 
    WHERE start_time < l_cutoff_date;
    l_deleted_count := SQL%ROWCOUNT;
    l_total_deleted := l_total_deleted + l_deleted_count;
    
    -- 5. Clean up old failed exports
    DELETE FROM plt_failed_exports 
    WHERE export_time < l_export_cutoff;
    l_deleted_count := SQL%ROWCOUNT;
    l_total_deleted := l_total_deleted + l_deleted_count;
    
    -- 6. Clean up old error logs
    DELETE FROM plt_telemetry_errors 
    WHERE error_time < l_error_cutoff
      AND module_name != ''PLT_DATA_CLEANUP'';  -- Keep cleanup logs longer
    l_deleted_count := SQL%ROWCOUNT;
    l_total_deleted := l_total_deleted + l_deleted_count;
    
    -- Log cleanup summary
    INSERT INTO plt_telemetry_errors (
        error_time,
        error_message,
        module_name
    ) VALUES (
        SYSTIMESTAMP,
        ''Data cleanup completed: deleted '' || l_total_deleted || '' total records. '' ||
        ''Retention: data='' || l_retention_days || ''d, errors='' || l_error_retention_days || ''d, exports='' || l_failed_export_retention_days || ''d'',
        ''PLT_DATA_CLEANUP''
    );
    
    COMMIT;
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO plt_telemetry_errors (
            error_time,
            error_message,
            error_code,
            module_name,
            error_stack
        ) VALUES (
            SYSTIMESTAMP,
            ''Data cleanup failed: '' || SUBSTR(SQLERRM, 1, 3000),
            SQLCODE,
            ''PLT_DATA_CLEANUP'',
            SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 3000)
        );
        COMMIT;
        RAISE;
END;',
        start_date      => TRUNC(SYSDATE + 1) + INTERVAL '2' HOUR,  -- 2 AM tomorrow
        repeat_interval => 'FREQ=DAILY; BYHOUR=2; BYMINUTE=0',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'PLTelemetry data cleanup - removes old telemetry data based on retention policy'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ PLT_DATA_CLEANUP job created successfully');
END;
/

-- Verify jobs creation
DECLARE
    l_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO l_count
    FROM USER_SCHEDULER_JOBS
    WHERE job_name IN ('PLT_QUEUE_CLEANUP', 'PLT_DATA_CLEANUP')
      AND enabled = 'TRUE';
    
    IF l_count != 2 THEN
        DBMS_OUTPUT.PUT_LINE('⚠ Warning: Expected 2 cleanup jobs, found ' || l_count || ' enabled');
    ELSE
        DBMS_OUTPUT.PUT_LINE('✓ Both cleanup jobs created and enabled successfully');
    END IF;
    
    -- Show next run times
    FOR rec IN (
        SELECT job_name, next_run_date
        FROM USER_SCHEDULER_JOBS
        WHERE job_name IN ('PLT_QUEUE_CLEANUP', 'PLT_DATA_CLEANUP')
        ORDER BY job_name
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  ' || rec.job_name || ' next run: ' || 
                           TO_CHAR(rec.next_run_date, 'YYYY-MM-DD HH24:MI:SS'));
    END LOOP;
END;
/

PROMPT
PROMPT ================================================================================
PROMPT PLTelemetry Cleanup Jobs Configuration
PROMPT ================================================================================
PROMPT
PROMPT Jobs Created:
PROMPT ✓ PLT_QUEUE_CLEANUP    - Daily at 3:00 AM (removes processed queue entries > 7 days)
PROMPT ✓ PLT_DATA_CLEANUP     - Daily at 2:00 AM (removes telemetry data > 90 days)
PROMPT
PROMPT Default Retention Policies:
PROMPT • Queue entries:     7 days (processed only)
PROMPT • Telemetry data:   90 days (traces, spans, events, metrics)
PROMPT • Error logs:       30 days
PROMPT • Failed exports:   14 days
PROMPT
PROMPT To customize retention periods, edit the job actions:
PROMPT   EXEC DBMS_SCHEDULER.SET_ATTRIBUTE(''PLT_DATA_CLEANUP'', ''job_action'', ''...'');
PROMPT
PROMPT To monitor cleanup activity:
PROMPT   SELECT * FROM plt_telemetry_errors 
PROMPT   WHERE module_name IN (''PLT_QUEUE_CLEANUP'', ''PLT_DATA_CLEANUP'')
PROMPT   ORDER BY error_time DESC;
PROMPT
PROMPT To disable cleanup jobs:
PROMPT   EXEC DBMS_SCHEDULER.DISABLE(''PLT_QUEUE_CLEANUP'');
PROMPT   EXEC DBMS_SCHEDULER.DISABLE(''PLT_DATA_CLEANUP'');
PROMPT
PROMPT ================================================================================