-- =============================================================================
-- PLT_DB_MONITOR - Aggressive Demo Job (Every 30 seconds)
-- Creates a scheduled job for continuous database monitoring
-- =============================================================================

PROMPT Setting up PLT_DB_MONITOR aggressive demo job...

-- =============================================================================
-- Clean up existing job if it exists
-- =============================================================================
BEGIN
    -- Drop existing job if it exists
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLT_DB_MONITOR_DEMO_JOB');
        DBMS_OUTPUT.PUT_LINE('✅ Existing demo job dropped');
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('ℹ️  No existing demo job to drop');
    END;
END;
/

-- =============================================================================
-- Create the aggressive demo job (30 seconds interval)
-- =============================================================================
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_DB_MONITOR_DEMO_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLT_DB_MONITOR.perform_database_validations(FALSE); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=30', -- Every 30 seconds!
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'PLT_DB_MONITOR Demo Job - Aggressive 30-second monitoring for demo purposes'
    );

    DBMS_OUTPUT.PUT_LINE('🚀 PLT_DB_MONITOR demo job created successfully!');
    DBMS_OUTPUT.PUT_LINE('   • Runs every 30 seconds');
    DBMS_OUTPUT.PUT_LINE('   • Only checks validations due for checking (not forced)');
    DBMS_OUTPUT.PUT_LINE('   • Perfect for live demo with fresh metrics');
    DBMS_OUTPUT.PUT_LINE('   • Will generate lots of beautiful telemetry data');
    
END;
/


-- =============================================================================
-- Verify job creation and show status
-- =============================================================================
PROMPT
PROMPT =============================================================================
PROMPT Job Status and Information
PROMPT =============================================================================

SELECT 
    job_name,
    CASE WHEN enabled = 'TRUE' THEN '🟢 ENABLED' ELSE '🔴 DISABLED' END as status,
    state,
    TO_CHAR(last_start_date, 'YYYY-MM-DD HH24:MI:SS') as last_run,
    TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI:SS') as next_run,
    run_count,
    failure_count,
    repeat_interval
FROM user_scheduler_jobs 
WHERE job_name IN ('PLT_DB_MONITOR_DEMO_JOB')
ORDER BY job_name;

-- =============================================================================
-- Show currently enabled validations
-- =============================================================================
PROMPT
PROMPT =============================================================================
PROMPT Enabled Database Validations (what will be monitored)
PROMPT =============================================================================

SELECT 
    v.validation_type_code,
    v.instance_name,
    v.target_identifier,
    r.check_interval_minutes,
    TO_CHAR(v.last_check_time, 'YYYY-MM-DD HH24:MI:SS') as last_checked,
    v.last_check_status,
    v.last_check_value,
    v.consecutive_failures
FROM db_validation_instances v
JOIN db_validation_rules r ON v.validation_type_code = r.validation_type_code 
                           AND r.environment_name = PLT_DB_MONITOR.detect_environment()
WHERE v.is_enabled = 1
ORDER BY v.validation_type_code, v.instance_name;

-- =============================================================================
-- Real-time monitoring commands for demo
-- =============================================================================
PROMPT
PROMPT =============================================================================
PROMPT Real-time Demo Monitoring Commands
PROMPT =============================================================================
PROMPT
PROMPT -- Watch job executions in real-time:
PROMPT SELECT job_name, state, last_start_date, next_run_date, run_count
PROMPT FROM user_scheduler_jobs 
PROMPT WHERE job_name LIKE 'PLT_%'
PROMPT ORDER BY next_run_date;
PROMPT
PROMPT -- Watch validation results updating:
PROMPT SELECT instance_name, last_check_time, last_check_status, last_check_value
PROMPT FROM db_validation_instances 
PROMPT WHERE is_enabled = 1
PROMPT ORDER BY last_check_time DESC NULLS LAST;
PROMPT
PROMPT -- Check for any job errors:
PROMPT SELECT job_name, log_date, status, error#, additional_info
PROMPT FROM user_scheduler_job_run_details
PROMPT WHERE job_name LIKE 'PLT_%'
PROMPT   AND log_date > SYSDATE - 1/24
PROMPT ORDER BY log_date DESC;
PROMPT
PROMPT -- Manual execution for immediate results:
PROMPT EXEC PLT_DB_MONITOR.perform_database_validations(TRUE);
PROMPT
PROMPT =============================================================================
PROMPT Demo Job Management Commands
PROMPT =============================================================================
PROMPT
PROMPT -- Stop the aggressive demo job:
PROMPT EXEC DBMS_SCHEDULER.DISABLE('PLT_DB_MONITOR_DEMO_JOB');
PROMPT
PROMPT -- Start the demo job again:
PROMPT EXEC DBMS_SCHEDULER.ENABLE('PLT_DB_MONITOR_DEMO_JOB');
PROMPT
PROMPT -- Run the job immediately (for instant demo):
PROMPT EXEC DBMS_SCHEDULER.RUN_JOB('PLT_DB_MONITOR_DEMO_JOB');
PROMPT
PROMPT -- Check job logs:
PROMPT SELECT * FROM user_scheduler_job_log WHERE job_name = 'PLT_DB_MONITOR_DEMO_JOB';
PROMPT
PROMPT =============================================================================
PROMPT
PROMPT 🚀 DEMO SETUP COMPLETE!
PROMPT
PROMPT Your database monitoring system is now running aggressively:
PROMPT • Database validations every 30 seconds
PROMPT • Queue processing every 15 seconds  
PROMPT • Fresh metrics flowing to Grafana continuously
PROMPT • Perfect for live demos and real-time visualization
PROMPT
PROMPT ⚠️  WARNING: This is aggressive for demo purposes only!
PROMPT For production, use longer intervals (5+ minutes) to avoid overhead.
PROMPT
PROMPT 📊 Check Grafana for metrics: pltelemetry_db_*
PROMPT 🔍 Check Tempo for traces: database_validation_cycle
PROMPT
PROMPT =============================================================================