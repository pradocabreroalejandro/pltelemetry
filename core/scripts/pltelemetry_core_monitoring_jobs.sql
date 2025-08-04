
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
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=30', -- Every 30 seconds
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