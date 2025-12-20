BEGIN
    -- Limpieza por si acaso
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('JOB_PUSH_TELEMETRY');
    EXCEPTION WHEN OTHERS THEN NULL; 
    END;

    -- Crear el Job
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'JOB_PUSH_TELEMETRY',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLTelemetry.process_queue(100); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=10', -- Cada 10 segundos
        enabled         => TRUE,
        comments        => 'Envía telemetría de Oracle al OTel Collector'
    );
    
    DBMS_OUTPUT.PUT_LINE('Job creado y activado. 🚀');
END;
/