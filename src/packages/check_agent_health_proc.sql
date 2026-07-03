CREATE OR REPLACE PROCEDURE check_agent_health AS
    l_is_healthy BOOLEAN;
    l_status_msg VARCHAR2(4000);
BEGIN
    -- Use the centralized function
    l_is_healthy := PLTelemetry.is_agent_healthy();

    IF NOT l_is_healthy THEN
        -- 🚨 RED ALERT
        DBMS_OUTPUT.PUT_LINE('⚠️ Agent down. Activating Failover.');
        
        UPDATE plt_agent_registry 
        SET status_message = 'DEAD', updated_at = SYSTIMESTAMP 
        WHERE agent_id = 'PRIMARY_AGENT';
        
        -- Make sure the PL/SQL processor is ON
        -- (Doesn't fail if already on)
        BEGIN
            DBMS_SCHEDULER.ENABLE('PLTELEMETRY.PLT_FAILOVER_JOB');
        EXCEPTION WHEN OTHERS THEN 
            -- ORA-27475 if it doesn't exist, etc.
            NULL; 
        END;

    ELSE
        -- 🟢 ALL OK
        -- If it was marked as DEAD, revive it
        SELECT status_message INTO l_status_msg FROM plt_agent_registry WHERE agent_id = 'PRIMARY_AGENT';
        
        IF l_status_msg = 'DEAD' THEN
            DBMS_OUTPUT.PUT_LINE('✅ Agent recovered. Shutting down PL/SQL Failover.');
            
            UPDATE plt_agent_registry 
            SET status_message = 'RUNNING', updated_at = SYSTIMESTAMP 
            WHERE agent_id = 'PRIMARY_AGENT';
            
            -- TURN OFF the failover job to save resources
            BEGIN
                DBMS_SCHEDULER.DISABLE('PLTELEMETRY.PLT_FAILOVER_JOB');
            EXCEPTION WHEN OTHERS THEN NULL; END;
        END IF;
    END IF;
    
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        -- Logging without SQLERRM, as you like
        INSERT INTO plt_telemetry_errors (error_message, module_name)
        VALUES (
            DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            'check_agent_health'
        );
        COMMIT;
END;
/

-- Create the Job that runs this check every minute
BEGIN
    DBMS_SCHEDULER.create_job (
        job_name        => 'PLT_HEALTH_MONITOR',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN check_agent_health; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=1', -- Check every minute
        enabled         => TRUE
    );
END;
/
