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
        job_action      => 'BEGIN PLTelemetry.process_queue(200); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=10', -- Cada 10 segundos
        enabled         => TRUE,
        comments        => 'Envía telemetría de Oracle al OTel Collector'
    );
    
    DBMS_OUTPUT.PUT_LINE('Job creado y activado. 🚀');
END;
/

BEGIN
    -- Primero lo borramos por si existía de pruebas anteriores
    BEGIN
        DBMS_SCHEDULER.DROP_JOB('PLT_METRIC_TICKER_JOB');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- Creamos el Job
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLT_METRIC_TICKER_JOB',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PLT_DB_MONITOR_LOGIC.run_collection_cycle',
        start_date      => SYSTIMESTAMP,
        -- FRECUENCIA: Cada 10 segundos
        repeat_interval => 'FREQ=SECONDLY;INTERVAL=10', 
        enabled         => TRUE,
        comments        => 'Metronomo de Observabilidad: Dispara recolectores segun su configuracion'
    );
    
    DBMS_OUTPUT.PUT_LINE('Job PLT_METRIC_TICKER_JOB creado y activado.');
END;
/

BEGIN
    
    DBMS_SCHEDULER.create_job (
        job_name        => 'PLTELEMETRY.PLT_FAILOVER_JOB',
        job_type        => 'PLSQL_BLOCK',
        -- CORRECCIÓN: Apuntamos al paquete correcto
        job_action      => 'BEGIN PLT_OTLP_BRIDGE.run_failover_processing; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=1', 
        enabled         => TRUE,
        comments        => 'Vigilante: Procesa la cola vía UTL_HTTP si el Agente Go muere'
    );
    
    DBMS_OUTPUT.PUT_LINE('Job PLT_FAILOVER_JOB recreado correctamente apuntando a PLT_OTLP_BRIDGE.');
END;
/