PROMPT [07] Creating Queue Maintenance Job...

BEGIN
    -- Drop if exists to avoid errors on re-execution
    BEGIN
        DBMS_SCHEDULER.drop_job('PLT_QUEUE_MAINTENANCE_JOB');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    DBMS_SCHEDULER.create_job (
        job_name        => 'PLT_QUEUE_MAINTENANCE_JOB',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PLT_QUEUE_MANAGER.run_maintenance_cycle',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=1', -- Check every minute
        enabled         => TRUE,
        comments        => 'Monitors queue sizes and executes rotation/truncate'
    );
END;
/

PROMPT ✅ Queue maintenance job created.
