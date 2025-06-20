-- PLTelemetry Queue Processor Job
-- This script creates a scheduled job to process the async telemetry queue
-- 
-- The job runs every minute and processes pending queue entries
-- Adjust the frequency and batch size based on your requirements

PROMPT Creating PLTelemetry queue processor job...

-- Drop existing job if it exists
BEGIN
    DBMS_SCHEDULER.DROP_JOB(
        job_name => 'PLT_QUEUE_PROCESSOR',
        force    => TRUE
    );
    DBMS_OUTPUT.PUT_LINE('Dropped existing PLT_QUEUE_PROCESSOR job');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -27475 THEN  -- Job does not exist
            RAISE;
        END IF;
END;
/

-- Create the queue processor job
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLT_QUEUE_PROCESSOR',
        job_type        => 'PLSQL_BLOCK',
        job_action      => '
DECLARE
    l_processed NUMBER := 0;
    l_errors NUMBER := 0;
    l_start_time TIMESTAMP;
BEGIN
    l_start_time := SYSTIMESTAMP;
    
    -- Process queue with error handling
    BEGIN
        PLTelemetry.process_queue(100);  -- Process up to 100 entries per run
    EXCEPTION
        WHEN OTHERS THEN
            -- Log job execution error
            INSERT INTO plt_telemetry_errors (
                error_time, 
                error_message, 
                error_code,
                module_name,
                error_stack
            ) VALUES (
                SYSTIMESTAMP,
                ''Queue processor job failed: '' || SUBSTR(SQLERRM, 1, 3000),
                SQLCODE,
                ''PLT_QUEUE_PROCESSOR'',
                SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 3000)
            );
            COMMIT;
    END;
    
    -- Optional: Log successful execution periodically
    -- Uncomment if you want to track job execution
    /*
    IF EXTRACT(MINUTE FROM SYSTIMESTAMP) = 0 THEN  -- Log once per hour
        INSERT INTO plt_telemetry_errors (
            error_time,
            error_message,
            module_name
        ) VALUES (
            SYSTIMESTAMP,
            ''Queue processor executed successfully'',
            ''PLT_QUEUE_PROCESSOR''
        );
        COMMIT;
    END IF;
    */
END;',
        start_date      => SYSTIMESTAMP + INTERVAL '1' MINUTE,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=1',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'PLTelemetry async queue processor - runs every minute'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ PLT_QUEUE_PROCESSOR job created successfully');
    DBMS_OUTPUT.PUT_LINE('  Frequency: Every 1 minute');
    DBMS_OUTPUT.PUT_LINE('  Batch size: 100 entries per run');
    DBMS_OUTPUT.PUT_LINE('  Start time: ' || TO_CHAR(SYSTIMESTAMP + INTERVAL '1' MINUTE, 'YYYY-MM-DD HH24:MI:SS'));
END;
/

-- Create a more frequent processor for high-volume environments (optional)
-- Uncomment if you need higher throughput
/*
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLT_QUEUE_PROCESSOR_FAST',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLTelemetry.process_queue(50); END;',
        start_date      => SYSTIMESTAMP + INTERVAL '30' SECOND,
        repeat_interval => 'FREQ=SECONDLY; INTERVAL=30',
        enabled         => FALSE,  -- Disabled by default
        auto_drop       => FALSE,
        comments        => 'PLTelemetry high-frequency queue processor - 30 seconds'
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ PLT_QUEUE_PROCESSOR_FAST job created (disabled)');
    DBMS_OUTPUT.PUT_LINE('  Enable with: DBMS_SCHEDULER.ENABLE(''PLT_QUEUE_PROCESSOR_FAST'')');
END;
/
*/

-- Verify job creation
DECLARE
    l_count NUMBER;
    l_enabled VARCHAR2(10);
    l_next_run TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT COUNT(*), MAX(enabled), MAX(next_run_date)
    INTO l_count, l_enabled, l_next_run
    FROM USER_SCHEDULER_JOBS
    WHERE job_name = 'PLT_QUEUE_PROCESSOR';
    
    IF l_count = 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Failed to create PLT_QUEUE_PROCESSOR job');
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Job Status:');
    DBMS_OUTPUT.PUT_LINE('  Enabled: ' || l_enabled);
    DBMS_OUTPUT.PUT_LINE('  Next run: ' || TO_CHAR(l_next_run, 'YYYY-MM-DD HH24:MI:SS TZH:TZM'));
END;
/

PROMPT
PROMPT Queue Processor Job Configuration:
PROMPT 
PROMPT To monitor the job:
PROMPT   SELECT job_name, enabled, next_run_date, run_count, failure_count
PROMPT   FROM USER_SCHEDULER_JOBS 
PROMPT   WHERE job_name = 'PLT_QUEUE_PROCESSOR';
PROMPT
PROMPT To view job run history:
PROMPT   SELECT log_date, status, error#, additional_info
PROMPT   FROM USER_SCHEDULER_JOB_RUN_DETAILS 
PROMPT   WHERE job_name = 'PLT_QUEUE_PROCESSOR'
PROMPT   ORDER BY log_date DESC;
PROMPT
PROMPT To manually process the queue:
PROMPT   BEGIN PLTelemetry.process_queue(100); END;
PROMPT
PROMPT To disable the job:
PROMPT   EXEC DBMS_SCHEDULER.DISABLE('PLT_QUEUE_PROCESSOR');
PROMPT
PROMPT To adjust the frequency:
PROMPT   EXEC DBMS_SCHEDULER.SET_ATTRIBUTE('PLT_QUEUE_PROCESSOR', 'repeat_interval', 'FREQ=MINUTELY; INTERVAL=5');
PROMPT