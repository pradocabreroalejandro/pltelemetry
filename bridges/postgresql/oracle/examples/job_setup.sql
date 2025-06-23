-- ============================================
-- FILE: job_setup.sql
-- PostgreSQL Bridge - Job Setup Example
-- ============================================

/*
This example shows how to set up automated queue processing jobs
for the PostgreSQL bridge when using asynchronous mode.
*/

SET SERVEROUTPUT ON SIZE UNLIMITED

-- Step 1: Configure for async mode with PostgreSQL bridge
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== CONFIGURING ASYNC MODE WITH JOBS ===');
    
    -- Set async mode
    PLTelemetry.set_async_mode(TRUE);
    PLTelemetry.set_backend_url('POSTGRES_BRIDGE');
    PLTelemetry.set_autocommit(TRUE);
    PLT_POSTGRES_BRIDGE.set_postgrest_url('http://localhost:3000');
    
    DBMS_OUTPUT.PUT_LINE('✓ Async mode configured');
END;
/

-- Step 2: Create the main processing job
BEGIN
    -- Drop existing job if exists
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLTELEMETRY_PROCESS_QUEUE', TRUE);
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;
    
    -- Create new job
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLTELEMETRY_PROCESS_QUEUE',
        job_type        => 'PLSQL_BLOCK',
        job_action      => '
        DECLARE
            l_start_time TIMESTAMP := SYSTIMESTAMP;
            l_processed  NUMBER;
            l_pending    NUMBER;
        BEGIN
            -- Get initial count
            SELECT COUNT(*) INTO l_pending 
            FROM plt_queue 
            WHERE processed = ''N'';
            
            IF l_pending > 0 THEN
                -- Process up to 100 items
                PLTelemetry.process_queue(100);
                
                -- Log results
                SELECT COUNT(*) INTO l_processed
                FROM plt_queue 
                WHERE processed = ''Y''
                AND processed_time >= l_start_time;
                
                INSERT INTO plt_telemetry_errors (
                    error_time, 
                    error_message, 
                    module_name
                ) VALUES (
                    SYSTIMESTAMP,
                    ''Queue processed: '' || l_processed || '' items in '' ||
                    ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)), 2) || '' seconds'',
                    ''QUEUE_JOB''
                );
                COMMIT;
            END IF;
        END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY; INTERVAL=30',  -- Every 30 seconds
        enabled         => FALSE,  -- Start disabled
        comments        => 'Process PLTelemetry queue for PostgreSQL bridge'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ Main processing job created (disabled)');
END;
/

-- Step 3: Create a high-frequency job for production
BEGIN
    -- Drop if exists
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLTELEMETRY_PROCESS_QUEUE_FAST', TRUE);
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;
    
    -- Create fast processing job
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLTELEMETRY_PROCESS_QUEUE_FAST',
        job_type        => 'PLSQL_BLOCK',
        job_action      => '
        BEGIN
            -- Only run if there are items to process
            FOR i IN (
                SELECT 1 FROM plt_queue 
                WHERE processed = ''N'' 
                AND ROWNUM = 1
            ) LOOP
                -- Process smaller batches more frequently
                PLTelemetry.process_queue(25);
            END LOOP;
        END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY; INTERVAL=5',  -- Every 5 seconds
        enabled         => FALSE,
        comments        => 'High-frequency PLTelemetry queue processor'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ Fast processing job created (disabled)');
END;
/

-- Step 4: Create cleanup job for old processed entries
BEGIN
    -- Drop if exists
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLTELEMETRY_CLEANUP_QUEUE', TRUE);
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;
    
    -- Create cleanup job
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLTELEMETRY_CLEANUP_QUEUE',
        job_type        => 'PLSQL_BLOCK',
        job_action      => '
        DECLARE
            l_deleted NUMBER;
        BEGIN
            -- Delete processed entries older than 7 days
            DELETE FROM plt_queue 
            WHERE processed = ''Y'' 
            AND processed_time < SYSTIMESTAMP - INTERVAL ''7'' DAY;
            
            l_deleted := SQL%ROWCOUNT;
            
            -- Also delete failed entries older than 30 days
            DELETE FROM plt_queue 
            WHERE processed = ''N'' 
            AND process_attempts >= 5
            AND created_time < SYSTIMESTAMP - INTERVAL ''30'' DAY;
            
            l_deleted := l_deleted + SQL%ROWCOUNT;
            
            -- Delete old error logs
            DELETE FROM plt_telemetry_errors
            WHERE error_time < SYSTIMESTAMP - INTERVAL ''30'' DAY
            AND module_name IN (''QUEUE_JOB'', ''process_queue'');
            
            l_deleted := l_deleted + SQL%ROWCOUNT;
            
            IF l_deleted > 0 THEN
                INSERT INTO plt_telemetry_errors (
                    error_time, 
                    error_message, 
                    module_name
                ) VALUES (
                    SYSTIMESTAMP,
                    ''Cleanup completed: '' || l_deleted || '' records deleted'',
                    ''CLEANUP_JOB''
                );
            END IF;
            
            COMMIT;
        END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=DAILY; BYHOUR=2; BYMINUTE=0',  -- Daily at 2 AM
        enabled         => FALSE,
        comments        => 'Cleanup old PLTelemetry queue entries'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ Cleanup job created (disabled)');
END;
/

-- Step 5: View all jobs
PROMPT
PROMPT Created jobs:
SELECT 
    job_name,
    enabled,
    state,
    repeat_interval,
    comments
FROM user_scheduler_jobs
WHERE job_name LIKE 'PLTELEMETRY%'
ORDER BY job_name;

-- Step 6: Test the job processing
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== TESTING ASYNC MODE ===');
    
    -- Create some test data
    l_trace_id := PLT_POSTGRES_BRIDGE.start_trace_with_postgres('job_test');
    l_span_id := PLTelemetry.start_span('test_operation');
    
    DBMS_LOCK.sleep(0.1);
    
    PLTelemetry.end_span(l_span_id, 'OK');
    PLTelemetry.log_metric('test_metric', 123, 'value');
    
    DBMS_OUTPUT.PUT_LINE('Trace created: ' || l_trace_id);
    
    -- Check queue
    FOR rec IN (
        SELECT COUNT(*) as cnt 
        FROM plt_queue 
        WHERE processed = 'N'
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('Items in queue: ' || rec.cnt);
    END LOOP;
END;
/

-- Step 7: Enable and test a job
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== ENABLING AND TESTING JOB ===');
    
    -- Enable the main job
    DBMS_SCHEDULER.ENABLE('PLTELEMETRY_PROCESS_QUEUE');
    DBMS_OUTPUT.PUT_LINE('✓ Job enabled');
    
    -- Run it manually once
    DBMS_SCHEDULER.RUN_JOB('PLTELEMETRY_PROCESS_QUEUE', FALSE);
    DBMS_OUTPUT.PUT_LINE('✓ Job executed manually');
    
    -- Check results
    FOR rec IN (
        SELECT error_message 
        FROM plt_telemetry_errors 
        WHERE module_name = 'QUEUE_JOB'
        AND error_time > SYSTIMESTAMP - INTERVAL '1' MINUTE
        ORDER BY error_time DESC
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('Job log: ' || rec.error_message);
        EXIT; -- Just show the latest
    END LOOP;
END;
/