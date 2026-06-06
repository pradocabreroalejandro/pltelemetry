-- =============================================================================
-- 04_jobs.sql
-- Definición de Jobs del Scheduler
-- =============================================================================
PROMPT [04] Creating Scheduler Jobs...

begin
    -- 1. JOB DE FAILOVER (Envío vía PL/SQL si el Agente muere)
    -- Corre cada minuto para verificar salud y procesar si es necesario.
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
      enabled         => true, -- Se habilita por defecto, el SP decide si hace algo o no
      comments        => 'Vigilante: Procesa la cola vía UTL_HTTP si el Agente Go muere'
   );

    -- 2. JOB DE MÉTRICAS (El "Ticker")
    -- Corre cada 10 segundos para evaluar colectores
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

   BEGIN
    
        DBMS_SCHEDULER.CREATE_JOB (
            job_name        => 'PLT_DB_MONITOR_JOB',
            job_type        => 'PLSQL_BLOCK', -- Usamos PLSQL_BLOCK para mayor flexibilidad
            job_action      => 'BEGIN PLT_DB_MONITOR_LOGIC.run_collection_cycle; END;',
            start_date      => SYSTIMESTAMP,
            repeat_interval => 'FREQ=SECONDLY; INTERVAL=10', -- Ejecutar cada 10 segundos
            enabled         => TRUE,
            comments        => 'Lanza el ciclo de recolección de métricas de base de datos'
        );
        
        DBMS_OUTPUT.PUT_LINE('✅ Job PLT_DB_MONITOR_JOB creado correctamente. Frecuencia: 10s');
    END;



end;
/

PROMPT ✅ Jobs creados correctamente.