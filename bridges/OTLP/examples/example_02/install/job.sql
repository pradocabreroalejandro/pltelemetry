-- ============================================================================
-- Heartbeat Monitoring - Scheduled Job Setup
-- Clean, table-driven monitoring with intelligent scheduling
-- ============================================================================

PROMPT Setting up Heartbeat Monitoring Job...

-- ============================================================================
-- Clean up existing jobs
-- ============================================================================
BEGIN
    -- Drop existing heartbeat job if it exists
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('HEARTBEAT_MONITORING_JOB');
        DBMS_OUTPUT.PUT_LINE('✅ Existing job dropped');
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('ℹ️  No existing job to drop');
    END;
    
    -- Also drop any old queue processing job (if exists)
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLT_QUEUE_PROCESSOR');
        DBMS_OUTPUT.PUT_LINE('✅ Existing queue processor dropped');
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- No queue job to drop
    END;
END;
/

-- ============================================================================
-- Create the main heartbeat monitoring job
-- ============================================================================
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HEARTBEAT_MONITORING_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN HEARTBEAT_MONITOR.perform_heartbeat_checks(TRUE); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=15',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'PLTelemetry Heartbeat Monitor - Table-driven service health monitoring'
    );

    DBMS_OUTPUT.PUT_LINE('✅ Heartbeat monitoring job created successfully');
    DBMS_OUTPUT.PUT_LINE('   • Runs every minute');
    DBMS_OUTPUT.PUT_LINE('   • Uses table-driven configuration');
    DBMS_OUTPUT.PUT_LINE('   • Intelligent criticality-based scheduling');
    DBMS_OUTPUT.PUT_LINE('   • Full PLTelemetry distributed tracing');
    
END;
/

-- ============================================================================
-- Create PLTelemetry queue processor job (if using async mode)
-- ============================================================================
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_QUEUE_PROCESSOR',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLTelemetry.process_queue(100); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=1', -- Every minute
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'PLTelemetry Queue Processor - Process async telemetry exports'
    );

    DBMS_OUTPUT.PUT_LINE('✅ PLTelemetry queue processor job created');
    DBMS_OUTPUT.PUT_LINE('   • Processes async telemetry queue');
    DBMS_OUTPUT.PUT_LINE('   • Runs every minute');
    
END;
/

-- ============================================================================
-- Verify job creation and status
-- ============================================================================
PROMPT
PROMPT Job Status:
SELECT 
    job_name,
    enabled,
    state,
    TO_CHAR(last_start_date, 'YYYY-MM-DD HH24:MI:SS') as last_run,
    TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI:SS') as next_run,
    run_count,
    failure_count
FROM user_scheduler_jobs 
WHERE job_name IN ('HEARTBEAT_MONITORING_JOB', 'PLT_QUEUE_PROCESSOR')
ORDER BY job_name;

-- ============================================================================
-- Configuration verification
-- ============================================================================
PROMPT
PROMPT Service Configuration Summary:
SELECT 
    c.criticality_code,
    c.description,
    c.check_interval_minutes,
    COUNT(s.service_id) as service_count,
    SUM(CASE WHEN s.is_enabled = 1 THEN 1 ELSE 0 END) as enabled_services
FROM heartbeat_criticality_levels c
LEFT JOIN heartbeat_services s ON c.criticality_code = s.criticality_code
GROUP BY c.criticality_code, c.description, c.check_interval_minutes
ORDER BY c.check_interval_minutes;

PROMPT
PROMPT Enabled Services:
SELECT 
    s.service_name,
    s.criticality_code,
    c.check_interval_minutes,
    s.consecutive_failures,
    TO_CHAR(s.last_check_time, 'YYYY-MM-DD HH24:MI:SS') as last_checked
FROM heartbeat_services s
JOIN heartbeat_criticality_levels c ON s.criticality_code = c.criticality_code
WHERE s.is_enabled = 1
ORDER BY c.check_interval_minutes, s.service_name;

-- ============================================================================
-- Test the monitoring system
-- ============================================================================
PROMPT
PROMPT Testing monitoring system...

-- Test the configuration loading
BEGIN
    HEARTBEAT_MONITOR.configure_telemetry();
    DBMS_OUTPUT.PUT_LINE('✅ PLTelemetry configuration successful');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ PLTelemetry configuration failed: ' || SQLERRM);
END;
/

-- Test a single service check (if any services exist)
DECLARE
    l_service_name VARCHAR2(50);
    l_result HEARTBEAT_MONITOR.t_health_result;
BEGIN
    -- Get first enabled service
    SELECT service_name 
    INTO l_service_name
    FROM heartbeat_services 
    WHERE is_enabled = 1 
    AND ROWNUM = 1;
    
    DBMS_OUTPUT.PUT_LINE('🔍 Testing health check for: ' || l_service_name);
    
    l_result := HEARTBEAT_MONITOR.check_service_health(l_service_name);
    
    DBMS_OUTPUT.PUT_LINE('   Status: ' || l_result.status);
    DBMS_OUTPUT.PUT_LINE('   Response Time: ' || l_result.response_time_ms || 'ms');
    DBMS_OUTPUT.PUT_LINE('   ✅ Service health check completed successfully');
    
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('ℹ️  No enabled services found - add some services first');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ Test health check failed: ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('   This is normal if services are not running yet');
END;
/

-- ============================================================================
-- Management Commands Reference
-- ============================================================================
PROMPT
PROMPT =============================================================================
PROMPT Heartbeat Monitoring System - Management Commands
PROMPT =============================================================================
PROMPT
PROMPT -- Manual monitoring cycle (force all services):
PROMPT EXEC HEARTBEAT_MONITOR.perform_heartbeat_checks(p_force_all_checks => TRUE);
PROMPT
PROMPT -- Check specific service:
PROMPT DECLARE
PROMPT     l_result HEARTBEAT_MONITOR.t_health_result;
PROMPT BEGIN
PROMPT     l_result := HEARTBEAT_MONITOR.check_service_health('oracle-reports');
PROMPT     DBMS_OUTPUT.PUT_LINE('Status: ' || l_result.status);
PROMPT END;
PROMPT /
PROMPT
PROMPT -- Add new service:
PROMPT EXEC HEARTBEAT_MONITOR.add_service('new-api', 'New API Service', 'http://localhost:8080', 'MEDIUM', 15, 1);
PROMPT
PROMPT -- Disable/Enable service monitoring:
PROMPT EXEC HEARTBEAT_MONITOR.set_service_monitoring('service-name', 0); -- disable
PROMPT EXEC HEARTBEAT_MONITOR.set_service_monitoring('service-name', 1); -- enable
PROMPT
PROMPT -- Reset failure counters:
PROMPT EXEC HEARTBEAT_MONITOR.reset_service_failures('service-name');
PROMPT
PROMPT -- Generate monitoring report:
PROMPT DECLARE
PROMPT     l_report CLOB;
PROMPT BEGIN
PROMPT     l_report := HEARTBEAT_MONITOR.generate_monitoring_report(24);
PROMPT     DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 4000));
PROMPT END;
PROMPT /
PROMPT
PROMPT -- Check job status:
PROMPT SELECT job_name, enabled, state, run_count, failure_count
PROMPT FROM user_scheduler_jobs 
PROMPT WHERE job_name = 'HEARTBEAT_MONITORING_JOB';
PROMPT
PROMPT -- View recent errors:
PROMPT SELECT error_time, error_message 
PROMPT FROM plt_telemetry_errors 
PROMPT WHERE module_name = 'HEARTBEAT_MONITOR'
PROMPT   AND error_time > SYSDATE - 1/24
PROMPT ORDER BY error_time DESC;
PROMPT
PROMPT -- Stop/Start monitoring:
PROMPT EXEC DBMS_SCHEDULER.DISABLE('HEARTBEAT_MONITORING_JOB');
PROMPT EXEC DBMS_SCHEDULER.ENABLE('HEARTBEAT_MONITORING_JOB');
PROMPT
PROMPT =============================================================================
PROMPT
PROMPT ✅ Heartbeat Monitoring System Setup Complete!
PROMPT
PROMPT Next steps:
PROMPT 1. Verify your services are running on their configured endpoints
PROMPT 2. Check Grafana/Tempo for distributed traces from PLTelemetry
PROMPT 3. Monitor the job execution and service health status
PROMPT 4. Add/modify services in heartbeat_services table as needed
PROMPT
PROMPT The monitoring job will start running immediately and check services
PROMPT based on their criticality levels every minute.
PROMPT =============================================================================