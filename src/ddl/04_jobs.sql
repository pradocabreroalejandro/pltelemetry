-- =============================================================================
-- 04_jobs.sql
-- Scheduler Job Definitions
-- =============================================================================
PROMPT [04] Creating Scheduler Jobs...

begin
    -- 1. FAILOVER JOB (Send via PL/SQL if the Agent dies)
    -- Runs every minute to check health and process if necessary.
   begin
      dbms_scheduler.drop_job('PLT_FAILOVER_JOB');
   exception
      when others then
         null;
   end;
   dbms_scheduler.create_job(
      job_name        => 'PLT_FAILOVER_JOB',
      job_type        => 'PLSQL_BLOCK',
      job_action      => 'BEGIN PLT_OTLP_BRIDGE.run_failover_processing; END;',
      start_date      => systimestamp,
      repeat_interval => 'FREQ=MINUTELY; INTERVAL=1',
      enabled         => true, -- Enabled by default, the SP decides whether to do something or not
      comments        => 'Watchdog: Processes the queue via UTL_HTTP if the Go Agent dies'
   );

    -- 2. METRICS JOB (The "Ticker")
    -- Runs every 10 seconds to evaluate collectors
   begin
      dbms_scheduler.drop_job('PLT_METRIC_TICKER_JOB');
   exception
      when others then
         null;
   end;
   dbms_scheduler.create_job(
      job_name        => 'PLT_METRIC_TICKER_JOB',
      job_type        => 'STORED_PROCEDURE',
      job_action      => 'PLT_DB_MONITOR_LOGIC.run_collection_cycle',
      start_date      => systimestamp,
      repeat_interval => 'FREQ=SECONDLY; INTERVAL=10',
      enabled         => true,
      comments        => 'Metronome: Fires metric collectors'
   );
    
    -- NOTE: The original JOB_PUSH_TELEMETRY (send loop) is NOT created here,
    -- because I assume the GO AGENT is the main responsible for emptying the queue.
    -- PLT_FAILOVER_JOB is the backup.
    -- If you won't use the Go Agent and want only PL/SQL, uncomment the following:
    /*
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'JOB_PUSH_TELEMETRY_SOLO',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLTelemetry.process_queue(200); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=10', 
        enabled         => TRUE
    );
    */

   BEGIN
    
        DBMS_SCHEDULER.CREATE_JOB (
            job_name        => 'PLT_DB_MONITOR_JOB',
            job_type        => 'PLSQL_BLOCK', -- Use PLSQL_BLOCK for greater flexibility
            job_action      => 'BEGIN PLT_DB_MONITOR_LOGIC.run_collection_cycle; END;',
            start_date      => SYSTIMESTAMP,
            repeat_interval => 'FREQ=SECONDLY; INTERVAL=10', -- Run every 10 seconds
            enabled         => TRUE,
            comments        => 'Launches the database metrics collection cycle'
        );
        
        DBMS_OUTPUT.PUT_LINE('✅ Job PLT_DB_MONITOR_JOB created successfully. Frequency: 10s');
    END;



end;
/

PROMPT ✅ Jobs created successfully.
