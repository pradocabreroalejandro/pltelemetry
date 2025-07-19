-- ============================================================================
-- PLT Service Discovery - Scheduled Job Setup
-- Clean, table-driven monitoring with intelligent scheduling
-- ============================================================================

PROMPT Setting up PLT Service Discovery Job...

-- ============================================================================
-- Clean up existing jobs
-- ============================================================================
BEGIN
    -- Drop existing service discovery job if it exists
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLT_SERVICE_DISCOVERY_JOB');
        DBMS_OUTPUT.PUT_LINE('✅ Existing PLT service discovery job dropped');
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('ℹ️  No existing service discovery job to drop');
    END;
    
    -- Drop old heartbeat job (legacy cleanup)
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('HEARTBEAT_MONITORING_JOB');
        DBMS_OUTPUT.PUT_LINE('✅ Legacy heartbeat job dropped');
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- No legacy job to drop
    END;
    
END;
/

-- ============================================================================
-- Create the main service discovery monitoring job
-- ============================================================================
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_SERVICE_DISCOVERY_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLT_SERVICE_DISCOVERY.perform_discovery_checks(FALSE); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=.5', -- Every 30 seconds
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'PLTelemetry Service Discovery - Table-driven service health monitoring with escalation'
    );

    DBMS_OUTPUT.PUT_LINE('✅ PLT Service Discovery job created successfully');
    DBMS_OUTPUT.PUT_LINE('   • Runs every minute');
    DBMS_OUTPUT.PUT_LINE('   • Uses table-driven configuration from plt_service_discovery_config');
    DBMS_OUTPUT.PUT_LINE('   • Intelligent criticality-based scheduling with escalation');
    DBMS_OUTPUT.PUT_LINE('   • Full PLTelemetry distributed tracing integration');
    DBMS_OUTPUT.PUT_LINE('   • Individual service metrics for clean time series');
    
END;
/



-- ============================================================================
-- Create cleanup job for old telemetry data
-- ============================================================================
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_DATA_CLEANUP_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => '
DECLARE
    l_deleted NUMBER := 0;
    l_retention_days NUMBER := 7; -- Keep 7 days of service discovery data
BEGIN
    -- Clean old queue entries
    DELETE FROM plt_queue 
    WHERE processed = ''Y'' 
      AND processed_time < SYSTIMESTAMP - INTERVAL l_retention_days DAY;
    l_deleted := SQL%ROWCOUNT;
    
    -- Clean old telemetry errors  
    DELETE FROM plt_telemetry_errors
    WHERE error_time < SYSTIMESTAMP - INTERVAL (l_retention_days * 2) DAY
      AND module_name IN (''PLT_SERVICE_DISCOVERY'', ''PLT_OTLP_BRIDGE'');
    l_deleted := l_deleted + SQL%ROWCOUNT;
    
    -- Log cleanup if significant
    IF l_deleted > 0 THEN
        INSERT INTO plt_telemetry_errors (
            error_time, error_message, module_name
        ) VALUES (
            SYSTIMESTAMP,
            ''Cleanup completed: deleted '' || l_deleted || '' old records'',
            ''PLT_DATA_CLEANUP''
        );
    END IF;
    
    COMMIT;
END;',
        start_date      => TRUNC(SYSDATE + 1) + INTERVAL '3' HOUR, -- 3 AM tomorrow
        repeat_interval => 'FREQ=DAILY;BYHOUR=3;BYMINUTE=0', -- Daily at 3 AM
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'PLTelemetry Data Cleanup - Remove old queue and error entries'
    );

    DBMS_OUTPUT.PUT_LINE('✅ PLTelemetry data cleanup job created');
    DBMS_OUTPUT.PUT_LINE('   • Runs daily at 3:00 AM');
    DBMS_OUTPUT.PUT_LINE('   • Keeps 7 days of service discovery data');
    
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
WHERE job_name IN ('PLT_SERVICE_DISCOVERY_JOB', 'PLT_DATA_CLEANUP_JOB')
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
    c.escalation_multiplier,
    c.max_escalation_failures,
    COUNT(s.service_id) as service_count,
    SUM(CASE WHEN s.is_enabled = 1 THEN 1 ELSE 0 END) as enabled_services
FROM plt_service_discovery_crit_levels c
LEFT JOIN plt_service_discovery_config s ON c.criticality_code = s.criticality_code
GROUP BY c.criticality_code, c.description, c.check_interval_minutes, c.escalation_multiplier, c.max_escalation_failures
ORDER BY c.check_interval_minutes;

PROMPT
PROMPT Enabled Services:
SELECT 
    s.service_name,
    s.criticality_code,
    c.check_interval_minutes,
    s.consecutive_failures,
    CASE 
        WHEN s.consecutive_failures >= c.max_escalation_failures THEN 'CRITICAL'
        WHEN s.consecutive_failures >= (c.max_escalation_failures / 2) THEN 'WARNING'
        ELSE 'NORMAL'
    END as escalation_status,
    s.tenant_id,
    TO_CHAR(s.last_check_time, 'YYYY-MM-DD HH24:MI:SS') as last_checked,
    TO_CHAR(s.last_success_time, 'YYYY-MM-DD HH24:MI:SS') as last_success
FROM plt_service_discovery_config s
JOIN plt_service_discovery_crit_levels c ON s.criticality_code = c.criticality_code
WHERE s.is_enabled = 1
ORDER BY c.check_interval_minutes, s.consecutive_failures DESC, s.service_name;

-- ============================================================================
-- Test the monitoring system
-- ============================================================================
PROMPT
PROMPT Testing PLT Service Discovery system...

-- Test the configuration loading
BEGIN
    PLT_SERVICE_DISCOVERY.configure_telemetry();
    DBMS_OUTPUT.PUT_LINE('✅ PLTelemetry configuration successful');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ PLTelemetry configuration failed: ' || SQLERRM);
END;
/

-- Test a single service check (if any services exist)
DECLARE
    l_service_name VARCHAR2(50);
    l_result PLT_SERVICE_DISCOVERY.t_health_result;
BEGIN
    -- Get first enabled service
    SELECT service_name 
    INTO l_service_name
    FROM plt_service_discovery_config 
    WHERE is_enabled = 1 
    AND ROWNUM = 1;
    
    DBMS_OUTPUT.PUT_LINE('🔍 Testing health check for: ' || l_service_name);
    
    l_result := PLT_SERVICE_DISCOVERY.check_service_health(l_service_name);
    
    DBMS_OUTPUT.PUT_LINE('   Status: ' || l_result.status);
    DBMS_OUTPUT.PUT_LINE('   Response Time: ' || NVL(TO_CHAR(l_result.response_time_ms), 'N/A') || 'ms');
    DBMS_OUTPUT.PUT_LINE('   Status Code: ' || NVL(TO_CHAR(l_result.status_code), 'N/A'));
    DBMS_OUTPUT.PUT_LINE('   Tenant: ' || NVL(l_result.tenant_id, 'default'));
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
PROMPT PLT Service Discovery System - Management Commands
PROMPT =============================================================================
PROMPT
PROMPT -- Manual monitoring cycle (force all services):
PROMPT EXEC PLT_SERVICE_DISCOVERY.perform_discovery_checks(p_force_all_checks => TRUE);
PROMPT
PROMPT -- Manual monitoring cycle for specific tenant:
PROMPT EXEC PLT_SERVICE_DISCOVERY.perform_discovery_checks(FALSE, 'CORE_PROD');
PROMPT
PROMPT -- Check specific service:
PROMPT DECLARE
PROMPT     l_result PLT_SERVICE_DISCOVERY.t_health_result;
PROMPT BEGIN
PROMPT     l_result := PLT_SERVICE_DISCOVERY.check_service_health('oracle-reports');
PROMPT     DBMS_OUTPUT.PUT_LINE('Status: ' || l_result.status);
PROMPT     DBMS_OUTPUT.PUT_LINE('Response: ' || l_result.response_time_ms || 'ms');
PROMPT END;
PROMPT /
PROMPT
PROMPT -- Add new service:
PROMPT EXEC PLT_SERVICE_DISCOVERY.add_service('new-api', 'New API Service', 'http://localhost:8080', 'MEDIUM', 15, 1, 'CORE_PROD');
PROMPT
PROMPT -- Update service configuration:
PROMPT EXEC PLT_SERVICE_DISCOVERY.update_service('new-api', p_criticality_code => 'HIGH', p_timeout_seconds => 30);
PROMPT
PROMPT -- Disable/Enable service monitoring:
PROMPT EXEC PLT_SERVICE_DISCOVERY.set_service_monitoring('service-name', 0); -- disable
PROMPT EXEC PLT_SERVICE_DISCOVERY.set_service_monitoring('service-name', 1); -- enable
PROMPT
PROMPT -- Reset failure counters (emergency reset):
PROMPT EXEC PLT_SERVICE_DISCOVERY.reset_service_failures('service-name');
PROMPT
PROMPT -- Remove service:
PROMPT EXEC PLT_SERVICE_DISCOVERY.remove_service('old-service');
PROMPT
PROMPT -- Generate discovery report:
PROMPT DECLARE
PROMPT     l_report CLOB;
PROMPT BEGIN
PROMPT     l_report := PLT_SERVICE_DISCOVERY.generate_discovery_report(24);
PROMPT     DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 4000));
PROMPT END;
PROMPT /
PROMPT
PROMPT -- Get health summary by tenant:
PROMPT DECLARE
PROMPT     l_summary CLOB;
PROMPT BEGIN
PROMPT     l_summary := PLT_SERVICE_DISCOVERY.get_discovery_health_summary();
PROMPT     DBMS_OUTPUT.PUT_LINE(SUBSTR(l_summary, 1, 4000));
PROMPT END;
PROMPT /
PROMPT
PROMPT -- Get service runtime info:
PROMPT DECLARE
PROMPT     l_runtime PLT_SERVICE_DISCOVERY.t_service_runtime;
PROMPT BEGIN
PROMPT     l_runtime := PLT_SERVICE_DISCOVERY.get_service_runtime('oracle-reports');
PROMPT     DBMS_OUTPUT.PUT_LINE('Service: ' || l_runtime.service_name);
PROMPT     DBMS_OUTPUT.PUT_LINE('Criticality: ' || l_runtime.criticality_code);
PROMPT     DBMS_OUTPUT.PUT_LINE('Consecutive Failures: ' || l_runtime.consecutive_failures);
PROMPT     DBMS_OUTPUT.PUT_LINE('Escalation Level: ' || l_runtime.escalation_level);
PROMPT     DBMS_OUTPUT.PUT_LINE('Current Check Interval: ' || l_runtime.current_check_interval || ' min');
PROMPT END;
PROMPT /
PROMPT
PROMPT -- Set tenant context:
PROMPT EXEC PLT_SERVICE_DISCOVERY.set_tenant_context('CORE_PROD', 'Core Production Environment');
PROMPT
PROMPT -- Clear tenant context:
PROMPT EXEC PLT_SERVICE_DISCOVERY.clear_tenant_context();
PROMPT
PROMPT -- Check job status:
PROMPT SELECT job_name, enabled, state, run_count, failure_count, comments
PROMPT FROM user_scheduler_jobs 
PROMPT WHERE job_name LIKE 'PLT_%'
PROMPT ORDER BY job_name;
PROMPT
PROMPT -- View recent errors:
PROMPT SELECT error_time, error_message, module_name, trace_id
PROMPT FROM plt_telemetry_errors 
PROMPT WHERE module_name LIKE 'PLT_%'
PROMPT   AND error_time > SYSDATE - 1/24
PROMPT ORDER BY error_time DESC;
PROMPT
PROMPT -- Check queue status (if using async mode):
PROMPT SELECT 
PROMPT     COUNT(*) as total_queued,
PROMPT     SUM(CASE WHEN processed = 'Y' THEN 1 ELSE 0 END) as processed,
PROMPT     SUM(CASE WHEN processed = 'N' THEN 1 ELSE 0 END) as pending,
PROMPT     MAX(process_attempts) as max_attempts
PROMPT FROM plt_queue;
PROMPT
PROMPT -- Stop/Start monitoring:
PROMPT EXEC DBMS_SCHEDULER.DISABLE('PLT_SERVICE_DISCOVERY_JOB');
PROMPT EXEC DBMS_SCHEDULER.ENABLE('PLT_SERVICE_DISCOVERY_JOB');
PROMPT
PROMPT -- Force immediate run:
PROMPT EXEC DBMS_SCHEDULER.RUN_JOB('PLT_SERVICE_DISCOVERY_JOB');
PROMPT
PROMPT =============================================================================
PROMPT
PROMPT ✅ PLT Service Discovery System Setup Complete!
PROMPT
PROMPT Next steps:
PROMPT 1. Verify your services are running on their configured endpoints
PROMPT 2. Check Grafana/Tempo for distributed traces from PLTelemetry
PROMPT 3. Monitor the job execution and service health status
PROMPT 4. Add/modify services in plt_service_discovery_config table as needed
PROMPT 5. Review escalation logic and adjust criticality levels if needed
PROMPT
PROMPT The monitoring job will start running immediately and check services
PROMPT based on their criticality levels and escalation logic every minute.
PROMPT
PROMPT Key Features:
PROMPT • Criticality-based intervals (CRITICAL: 1min, HIGH: 2min, MEDIUM: 5min, LOW: 10min)
PROMPT • Automatic escalation on failures (faster checks when services fail)
PROMPT • Individual service metrics for clean time series in Grafana
PROMPT • Multi-tenant support for enterprise environments
PROMPT • Distributed tracing integration across all health checks
PROMPT • Smart scheduling - only checks services when due
PROMPT =============================================================================