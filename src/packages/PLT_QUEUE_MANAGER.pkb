CREATE OR REPLACE PACKAGE BODY PLT_QUEUE_MANAGER AS

    -- Internal constants
    c_reg_active   CONSTANT VARCHAR2(10) := 'ACTIVE';
    c_reg_draining CONSTANT VARCHAR2(10) := 'DRAINING';
    c_reg_ready    CONSTANT VARCHAR2(10) := 'READY';

    -- Internal logger (wrapper over PLTelemetry or direct error table if PLT fails)
    PROCEDURE log_internal(p_msg VARCHAR2, p_level VARCHAR2 DEFAULT 'INFO') IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        -- Try to use the own error system
        INSERT INTO plt_telemetry_errors (error_message, module_name, tenant_id)
        VALUES (p_msg, 'PLT_QUEUE_MANAGER', 'SYS');
        COMMIT;
    EXCEPTION WHEN OTHERS THEN ROLLBACK;
    END;

    -- Gets the current size of a table in MB
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

    -- Executes the actual TRUNCATE
    PROCEDURE do_truncate(p_table_name VARCHAR2) IS
        l_ddl VARCHAR2(100);
    BEGIN
        l_ddl := 'TRUNCATE TABLE ' || p_table_name;
        log_internal('Executing: ' || l_ddl, 'WARN');
        EXECUTE IMMEDIATE l_ddl;
        
        -- Update registry
        UPDATE plt_queue_registry
        SET state = c_reg_ready,
            last_truncate = SYSTIMESTAMP,
            row_count_est = 0,
            bytes_est = 0
        WHERE partition_name = p_table_name;
        
    EXCEPTION WHEN OTHERS THEN
        log_internal('TRUNCATE failure on ' || p_table_name || ': ' || 
                     DBMS_UTILITY.FORMAT_ERROR_STACK, 'ERROR');
        RAISE;
    END;

    -- Rotation logic
    PROCEDURE rotate_partition IS
        l_current_active VARCHAR2(30);
        l_next_active    VARCHAR2(30);
        l_next_state     VARCHAR2(20);
        l_pending_cnt    NUMBER;
    BEGIN
        -- 1. Identify who is who
        SELECT partition_name INTO l_current_active
        FROM plt_queue_registry WHERE is_active = 'Y';

        -- Find the candidate (the one that is NOT active)
        -- Assume only 2 tables for now.
        SELECT partition_name, state INTO l_next_active, l_next_state
        FROM plt_queue_registry WHERE is_active = 'N';

        log_internal('Attempting rotation: ' || l_current_active || ' -> ' || l_next_active);

        -- 2. Verify that the candidate is READY
        -- If the candidate is in DRAINING and still has pending data, WE CANNOT ROTATE!
        -- It would be an "Istanbul Full" situation (both tables full).
        IF l_next_state = c_reg_draining THEN
            -- Paranoid check: Does it really have pending data?
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || l_next_active || ' WHERE status != ''PROCESSED''' INTO l_pending_cnt;
            
            IF l_pending_cnt > 0 THEN
                log_internal('CRITICAL: Cannot rotate. Target table ' || l_next_active || 
                             ' still has ' || l_pending_cnt || ' pending items.', 'ERROR');
                -- Here you could raise a big alert or try to process in panic.
                RETURN;
            ELSE
                -- If count is 0 but state was DRAINING, do a quick TRUNCATE for hygiene
                do_truncate(l_next_active);
            END IF;
        END IF;

        -- 3. THE SWITCH (Critical Section)
        -- Point the Synonym
        EXECUTE IMMEDIATE 'CREATE OR REPLACE SYNONYM plt_queue_writer FOR ' || l_next_active;
        
        -- Update metadata
        UPDATE plt_queue_registry SET is_active = 'N', state = c_reg_draining WHERE partition_name = l_current_active;
        UPDATE plt_queue_registry SET is_active = 'Y', state = c_reg_active   WHERE partition_name = l_next_active;
        
        COMMIT;
        
        log_internal('Rotation completed. New active: ' || l_next_active);

    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        log_internal('Fatal error in rotate_partition: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || ' - ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 'ERROR');
    END;

    -- Maintenance Cycle
    PROCEDURE run_maintenance_cycle IS
        l_active_table VARCHAR2(30);
        l_active_mb    NUMBER;
        l_limit_mb     NUMBER;
        l_drain_table  VARCHAR2(30);
        l_drain_cnt    NUMBER;
    BEGIN
        -- Read Configuration
        l_limit_mb := PLT_CONFIGURATION.get_num_param('QUEUE', 'MAX_SIZE_MB', 500);

        -- 1. Space Check (Active)
        SELECT partition_name INTO l_active_table
        FROM plt_queue_registry WHERE is_active = 'Y';

        l_active_mb := get_table_size_mb(l_active_table);
        
        -- Update estimated stats
        UPDATE plt_queue_registry SET bytes_est = l_active_mb * 1024 * 1024 WHERE partition_name = l_active_table;

        IF l_active_mb >= l_limit_mb THEN
            log_internal('Limit exceeded in ' || l_active_table || ' (' || l_active_mb || 'MB / ' || l_limit_mb || 'MB). Starting rotation.');
            rotate_partition;
            RETURN; -- If we rotated, don't truncate in this cycle, wait for the next one to stabilize
        END IF;

        -- 2. Cleanup Check (Draining)
        BEGIN
            SELECT partition_name INTO l_drain_table
            FROM plt_queue_registry WHERE state = c_reg_draining;

            -- Is it empty of pending items?
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || l_drain_table || ' WHERE status != ''PROCESSED''' INTO l_drain_cnt;

            IF l_drain_cnt = 0 THEN
                log_internal('Table ' || l_drain_table || ' fully processed. Proceeding to TRUNCATE.');
                do_truncate(l_drain_table);
            END IF;
            
        EXCEPTION WHEN NO_DATA_FOUND THEN
            NULL; -- Nothing in draining (we are in fresh start mode)
        END;
        
        COMMIT;

    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        log_internal('Error in maintenance_cycle: ' || DBMS_UTILITY.FORMAT_ERROR_STACK, 'ERROR');
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
