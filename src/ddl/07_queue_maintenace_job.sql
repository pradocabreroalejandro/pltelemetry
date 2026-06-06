PROMPT [07] Creating Queue Maintenance Job...

BEGIN
    -- Borramos si existe para evitar errores al re-ejecutar
    BEGIN
        DBMS_SCHEDULER.drop_job('PLT_QUEUE_MAINTENANCE_JOB');
    EXCEPTION WHEN OTHERS THEN NULL; END;

    DBMS_SCHEDULER.create_job (
        job_name        => 'PLT_QUEUE_MAINTENANCE_JOB',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PLT_QUEUE_MANAGER.run_maintenance_cycle',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=1', -- Revisar cada minuto
        enabled         => TRUE,
        comments        => 'Monitoriza tamaño de colas y ejecuta rotación/truncate'
    );
END;
/

PROMPT ✅ Job de mantenimiento de cola creado.