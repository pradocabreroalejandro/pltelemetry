CREATE OR REPLACE PACKAGE BODY PLT_QUEUE_MANAGER AS

    -- Constantes internas
    c_reg_active   CONSTANT VARCHAR2(10) := 'ACTIVE';
    c_reg_draining CONSTANT VARCHAR2(10) := 'DRAINING';
    c_reg_ready    CONSTANT VARCHAR2(10) := 'READY';

    -- Logger interno (wrapper sobre PLTelemetry o tabla de errores directa si PLT falla)
    PROCEDURE log_internal(p_msg VARCHAR2, p_level VARCHAR2 DEFAULT 'INFO') IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        -- Intentamos usar el sistema de errores propio
        INSERT INTO plt_telemetry_errors (error_message, module_name, tenant_id)
        VALUES (p_msg, 'PLT_QUEUE_MANAGER', 'SYS');
        COMMIT;
    EXCEPTION WHEN OTHERS THEN ROLLBACK;
    END;

    -- Obtiene el tamaño actual de una tabla en MB
    FUNCTION get_table_size_mb(p_table_name VARCHAR2) RETURN NUMBER IS
        l_bytes NUMBER := 0;
    BEGIN
        SELECT SUM(bytes)
        INTO l_bytes
        FROM user_segments
        WHERE segment_name = UPPER(p_table_name);
        
        RETURN ROUND(NVL(l_bytes, 0) / 1024 / 1024, 2);
    EXCEPTION WHEN OTHERS THEN RETURN 0;
    END;

    -- Ejecuta el TRUNCATE real
    PROCEDURE do_truncate(p_table_name VARCHAR2) IS
        l_ddl VARCHAR2(100);
    BEGIN
        l_ddl := 'TRUNCATE TABLE ' || p_table_name;
        log_internal('Ejecutando: ' || l_ddl, 'WARN');
        EXECUTE IMMEDIATE l_ddl;
        
        -- Actualizamos registro
        UPDATE plt_queue_registry
        SET state = c_reg_ready,
            last_truncate = SYSTIMESTAMP,
            row_count_est = 0,
            bytes_est = 0
        WHERE partition_name = p_table_name;
        
    EXCEPTION WHEN OTHERS THEN
        log_internal('Fallo en TRUNCATE de ' || p_table_name || ': ' || 
                     DBMS_UTILITY.FORMAT_ERROR_STACK, 'ERROR');
        RAISE;
    END;

    -- Lógica de rotación
    PROCEDURE rotate_partition IS
        l_current_active VARCHAR2(30);
        l_next_active    VARCHAR2(30);
        l_next_state     VARCHAR2(20);
        l_pending_cnt    NUMBER;
    BEGIN
        -- 1. Identificar quién es quién
        SELECT partition_name INTO l_current_active
        FROM plt_queue_registry WHERE is_active = 'Y';

        -- Buscar el candidato (el que NO es activo)
        -- Asumimos solo 2 tablas por ahora.
        SELECT partition_name, state INTO l_next_active, l_next_state
        FROM plt_queue_registry WHERE is_active = 'N';

        log_internal('Intentando rotación: ' || l_current_active || ' -> ' || l_next_active);

        -- 2. Verificar que el candidato esté LISTO
        -- Si el candidato está en DRAINING y aún tiene datos pendientes, ¡NO PODEMOS ROTAR!
        -- Sería una situación de "Full de Estambul" (ambas tablas llenas).
        IF l_next_state = c_reg_draining THEN
            -- Chequeo paranoico: ¿Realmente tiene datos pendientes?
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || l_next_active || ' WHERE status != ''PROCESSED''' INTO l_pending_cnt;
            
            IF l_pending_cnt > 0 THEN
                log_internal('CRITICAL: No se puede rotar. La tabla destino ' || l_next_active || 
                             ' aún tiene ' || l_pending_cnt || ' items pendientes.', 'ERROR');
                -- Aquí podrías lanzar una alerta gorda o intentar procesar en pánico.
                RETURN;
            ELSE
                -- Si contador es 0 pero estado era DRAINING, hacemos un TRUNCATE rápido por higiene
                do_truncate(l_next_active);
            END IF;
        END IF;

        -- 3. EL SWITCH (Critical Section)
        -- Apuntamos el Sinónimo
        EXECUTE IMMEDIATE 'CREATE OR REPLACE SYNONYM plt_queue_writer FOR ' || l_next_active;
        
        -- Actualizamos metadatos
        UPDATE plt_queue_registry SET is_active = 'N', state = c_reg_draining WHERE partition_name = l_current_active;
        UPDATE plt_queue_registry SET is_active = 'Y', state = c_reg_active   WHERE partition_name = l_next_active;
        
        COMMIT;
        
        log_internal('Rotación completada. Nuevo activo: ' || l_next_active);

    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        log_internal('Error fatal en rotate_partition: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || ' - ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 'ERROR');
    END;

    -- Ciclo de Mantenimiento
    PROCEDURE run_maintenance_cycle IS
        l_active_table VARCHAR2(30);
        l_active_mb    NUMBER;
        l_limit_mb     NUMBER;
        l_drain_table  VARCHAR2(30);
        l_drain_cnt    NUMBER;
    BEGIN
        -- Leer Configuración
        l_limit_mb := PLT_CONFIGURATION.get_num_param('QUEUE', 'MAX_SIZE_MB', 500);

        -- 1. Chequeo de Espacio (Active)
        SELECT partition_name INTO l_active_table
        FROM plt_queue_registry WHERE is_active = 'Y';

        l_active_mb := get_table_size_mb(l_active_table);
        
        -- Actualizamos stats estimados
        UPDATE plt_queue_registry SET bytes_est = l_active_mb * 1024 * 1024 WHERE partition_name = l_active_table;

        IF l_active_mb >= l_limit_mb THEN
            log_internal('Límite excedido en ' || l_active_table || ' (' || l_active_mb || 'MB / ' || l_limit_mb || 'MB). Iniciando rotación.');
            rotate_partition;
            RETURN; -- Si rotamos, ya no hacemos truncate en este ciclo, esperamos al siguiente para estabilizar
        END IF;

        -- 2. Chequeo de Limpieza (Draining)
        BEGIN
            SELECT partition_name INTO l_drain_table
            FROM plt_queue_registry WHERE state = c_reg_draining;

            -- ¿Está vacía de pendientes?
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || l_drain_table || ' WHERE status != ''PROCESSED''' INTO l_drain_cnt;

            IF l_drain_cnt = 0 THEN
                log_internal('Tabla ' || l_drain_table || ' totalmente procesada. Procediendo a TRUNCATE.');
                do_truncate(l_drain_table);
            END IF;
            
        EXCEPTION WHEN NO_DATA_FOUND THEN
            NULL; -- No hay nada en draining (estamos en modo fresh start)
        END;
        
        COMMIT;

    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        log_internal('Error en maintenance_cycle: ' || DBMS_UTILITY.FORMAT_ERROR_STACK, 'ERROR');
    END;

    PROCEDURE force_rotation IS
    BEGIN
        rotate_partition;
    END;

    PROCEDURE get_status(
        p_active_table OUT VARCHAR2,
        p_active_mb    OUT NUMBER,
        p_drain_table  OUT VARCHAR2,
        p_drain_rows   OUT NUMBER
    ) IS
    BEGIN
        SELECT partition_name INTO p_active_table FROM plt_queue_registry WHERE is_active = 'Y';
        p_active_mb := get_table_size_mb(p_active_table);
        
        BEGIN
            SELECT partition_name INTO p_drain_table FROM plt_queue_registry WHERE state = c_reg_draining;
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || p_drain_table || ' WHERE status != ''PROCESSED''' INTO p_drain_rows;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            p_drain_table := 'NONE';
            p_drain_rows := 0;
        END;
    END;

END PLT_QUEUE_MANAGER;
/