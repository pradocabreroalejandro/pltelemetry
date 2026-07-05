-- =============================================================================
-- 04_jobs.sql
-- Scheduler Job Definitions
-- =============================================================================
PROMPT [04] Creating Scheduler Jobs...

BEGIN
    -- =======================================================================
    -- JOB 1: FAILOVER (Process queue via UTL_HTTP if Go Agent is down)
    -- =======================================================================
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLT_FAILOVER_JOB');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_FAILOVER_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLT_OTLP_BRIDGE.run_failover_processing; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=1',
        enabled         => TRUE,
        comments        => 'Watchdog: Processes queue via UTL_HTTP if Go Agent dies'
    );

    -- =======================================================================
    -- JOB 2: METRIC COLLECTION (Main job - runs every 10 seconds)
    -- =======================================================================
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLT_METRIC_COLLECTOR_JOB');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_METRIC_COLLECTOR_JOB',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PLT_DB_MONITOR_LOGIC.run_collection_cycle',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY; INTERVAL=10',
        enabled         => TRUE,
        comments        => 'Collects all metrics from plt_metric_collectors table'
    );
    
    DBMS_OUTPUT.PUT_LINE('✅ Job PLT_METRIC_COLLECTOR_JOB created successfully (every 10s)');

    -- =======================================================================
    -- JOB 3: QUEUE MAINTENANCE (Rotation and cleanup)
    -- =======================================================================
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLT_QUEUE_MAINTENANCE_JOB');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_QUEUE_MAINTENANCE_JOB',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PLT_QUEUE_MANAGER.run_maintenance_cycle',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=5',
        enabled         => TRUE,
        comments        => 'Queue rotation and maintenance cycle'
    );
    
    DBMS_OUTPUT.PUT_LINE('✅ Job PLT_QUEUE_MAINTENANCE_JOB created successfully (every 5min)');
END;
/

PROMPT ✅ Jobs created successfully.
