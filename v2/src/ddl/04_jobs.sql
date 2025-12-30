-- =============================================================================
-- 04_jobs.sql
-- Definición de Jobs del Scheduler
-- =============================================================================
PROMPT [04] Creating Scheduler Jobs...

BEGIN
    -- 1. JOB DE FAILOVER (Envío vía PL/SQL si el Agente muere)
    -- Corre cada minuto para verificar salud y procesar si es necesario.
    BEGIN DBMS_SCHEDULER.DROP_JOB('PLT_FAILOVER_JOB'); EXCEPTION WHEN OTHERS THEN NULL; END;
    
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLT_FAILOVER_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLT_OTLP_BRIDGE.run_failover_processing; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=1', 
        enabled         => TRUE, -- Se habilita por defecto, el SP decide si hace algo o no
        comments        => 'Vigilante: Procesa la cola vía UTL_HTTP si el Agente Go muere'
    );

    -- 2. JOB DE MÉTRICAS (El "Ticker")
    -- Corre cada 10 segundos para evaluar colectores
    BEGIN DBMS_SCHEDULER.DROP_JOB('PLT_METRIC_TICKER_JOB'); EXCEPTION WHEN OTHERS THEN NULL; END;

    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLT_METRIC_TICKER_JOB',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PLT_DB_MONITOR_LOGIC.run_collection_cycle',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY; INTERVAL=10', 
        enabled         => TRUE,
        comments        => 'Metronomo: Dispara recolectores de metricas'
    );
    
    -- NOTA: El JOB_PUSH_TELEMETRY original (loop de envío) NO lo creo aquí,
    -- porque asumo que el AGENTE GO es el encargado principal de vaciar la cola.
    -- El PLT_FAILOVER_JOB es el respaldo.
    -- Si no vas a usar Agente Go y quieres solo PL/SQL, descomenta lo siguiente:
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
    
END;
/

PROMPT ✅ Jobs creados correctamente.