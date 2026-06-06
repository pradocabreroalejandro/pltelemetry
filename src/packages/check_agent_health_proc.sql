CREATE OR REPLACE PROCEDURE check_agent_health AS
    l_is_healthy BOOLEAN;
    l_status_msg VARCHAR2(4000);
BEGIN
    -- Usamos la función centralizada
    l_is_healthy := PLTelemetry.is_agent_healthy();

    IF NOT l_is_healthy THEN
        -- 🚨 ALERTA ROJA
        DBMS_OUTPUT.PUT_LINE('⚠️ Agente caído. Activando Failover.');
        
        UPDATE plt_agent_registry 
        SET status_message = 'DEAD', updated_at = SYSTIMESTAMP 
        WHERE agent_id = 'PRIMARY_AGENT';
        
        -- Nos aseguramos que el procesador PL/SQL esté ENCENDIDO
        -- (No falla si ya está encendido)
        BEGIN
            DBMS_SCHEDULER.ENABLE('PLTELEMETRY.PLT_FAILOVER_JOB');
        EXCEPTION WHEN OTHERS THEN 
            -- ORA-27475 si no existe, etc.
            NULL; 
        END;

    ELSE
        -- 🟢 TODO OK
        -- Si estaba marcado como DEAD, lo revivimos
        SELECT status_message INTO l_status_msg FROM plt_agent_registry WHERE agent_id = 'PRIMARY_AGENT';
        
        IF l_status_msg = 'DEAD' THEN
            DBMS_OUTPUT.PUT_LINE('✅ Agente recuperado. Apagando Failover PL/SQL.');
            
            UPDATE plt_agent_registry 
            SET status_message = 'RUNNING', updated_at = SYSTIMESTAMP 
            WHERE agent_id = 'PRIMARY_AGENT';
            
            -- APAGAMOS el job de failover para ahorrar recursos
            BEGIN
                DBMS_SCHEDULER.DISABLE('PLTELEMETRY.PLT_FAILOVER_JOB');
            EXCEPTION WHEN OTHERS THEN NULL; END;
        END IF;
    END IF;
    
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        -- Logging sin SQLERRM, como te gusta
        INSERT INTO plt_telemetry_errors (error_message, module_name)
        VALUES (
            DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            'check_agent_health'
        );
        COMMIT;
END;
/

-- Crear el Job que ejecuta este chequeo cada minuto
BEGIN
    DBMS_SCHEDULER.create_job (
        job_name        => 'PLT_HEALTH_MONITOR',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN check_agent_health; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=1', -- Chequear cada minuto
        enabled         => TRUE
    );
END;
/