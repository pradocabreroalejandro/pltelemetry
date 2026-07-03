CREATE OR REPLACE PACKAGE BODY PLT_PERF_SUITE AS

    -- Dummy variable to ignore function returns if needed
    ignore_result VARCHAR2(100);

    -- =========================================================================
    -- INTERNAL HELPER TO LOG ATTRIBUTES
    -- =========================================================================
    PROCEDURE log_kv(p_key VARCHAR2, p_val VARCHAR2) IS
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_attrs(1) := PLTelemetry.attr(p_key, p_val);
        PLTelemetry.log('INFO', 'Attribute Log', l_attrs);
    END;

    -- =========================================================================
    -- SCENARIO GENERATORS
    -- =========================================================================

    -- SCENARIO 1: LIGHT (Pure metrics and short logs)
    PROCEDURE scen_light IS
    BEGIN
        PLTelemetry.log_metric('perf.test.counter', 1, 'COUNTER');
        PLTelemetry.log('INFO', 'Keep alive signal');
    END;

    -- SCENARIO 2: STANDARD (Order Simulation)
    PROCEDURE scen_standard IS
        l_span_id VARCHAR2(64);
    BEGIN
        l_span_id := PLTelemetry.start_span('process_order');
        
        log_kv('order.id', TO_CHAR(TRUNC(DBMS_RANDOM.VALUE(1000,9999))));
        log_kv('client.region', 'EU-WEST');
        
        -- Child span 1
        ignore_result := PLTelemetry.start_span('validate_stock');
        PLTelemetry.end_span('OK');

        -- Child span 2
        ignore_result := PLTelemetry.start_span('charge_credit_card');
        PLTelemetry.end_span('OK');

        PLTelemetry.log('INFO', 'Order processed successfully');
        PLTelemetry.end_span('OK');
    END;

    -- SCENARIO 3: HEAVY (Large attributes, CLOBs, Errors)
    PROCEDURE scen_heavy IS
        l_big_text VARCHAR2(4000) := RPAD('LOREM IPSUM ', 2000, 'A');
        l_span_id  VARCHAR2(64);
    BEGIN
        l_span_id := PLTelemetry.start_span('batch_process_heavy');
        
        log_kv('payload.dump', l_big_text);
        
        BEGIN
            l_span_id := PLTelemetry.start_span('risky_operation');
            PLTelemetry.log('WARN', 'Memory usage high');
            
            IF DBMS_RANDOM.VALUE > 0.5 THEN
                RAISE_APPLICATION_ERROR(-20001, 'Simulated Chaos Failure');
            END IF;
            
            PLTelemetry.end_span('OK');
        EXCEPTION WHEN OTHERS THEN
            PLTelemetry.log('ERROR', 'Sub-task failed: ' || 
                 SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 200));
            PLTelemetry.end_span('ERROR', 'Simulated Failure');
        END;

        PLTelemetry.end_span('OK');
    END;

    -- SCENARIO 4: SUPER HEAVY (Deep Nesting + Loops + High Volume)
    PROCEDURE scen_super_heavy IS
        l_root    VARCHAR2(64);
        l_batch   VARCHAR2(64);
        l_item    VARCHAR2(64);
        -- Simulate a JSON payload that borders VARCHAR2 limits
        l_payload VARCHAR2(32000) := RPAD('{"data":"', 4000, 'X') || '"}';
    BEGIN
        -- Level 0: Overall Process
        l_root := PLTelemetry.start_span('etl_nightly_job');
        log_kv('job.id', 'ETL-999');

        -- Simulate batch processing
        FOR i IN 1..3 LOOP -- 3 Batches
            -- Level 1: Batch
            l_batch := PLTelemetry.start_span('process_batch_' || i);
            log_kv('batch.size', '500');

            -- Level 2: Items within the batch (simulate a fast loop)
            FOR j IN 1..5 LOOP 
                l_item := PLTelemetry.start_span('transform_row');
                -- Inject lots of text to test serialization
                log_kv('row.data', substr(l_payload, 1, 1000)); 
                PLTelemetry.end_span('OK');
            END LOOP;

            PLTelemetry.log('INFO', 'Batch '||i||' finished');
            PLTelemetry.end_span('OK'); -- End Batch
        END LOOP;

        PLTelemetry.end_span('OK'); -- End Root
    END;

    -- =========================================================================
    -- SESSION EXECUTOR
    -- =========================================================================
    PROCEDURE run_test_session(
        p_iterations NUMBER DEFAULT 1000,
        p_scenario   VARCHAR2 DEFAULT 'STANDARD'
    ) IS
        l_start_ts TIMESTAMP := SYSTIMESTAMP;
        l_end_ts   TIMESTAMP;
        l_elapsed  NUMBER;
        l_ops      NUMBER;
    BEGIN
        -- Force unique test tenant for each scenario
        PLTelemetry.set_tenant('PERF_' || p_scenario);

        FOR i IN 1..p_iterations LOOP
            CASE p_scenario
                WHEN 'LIGHT'       THEN scen_light;
                WHEN 'STANDARD'    THEN scen_standard;
                WHEN 'HEAVY'       THEN scen_heavy;
                WHEN 'SUPER_HEAVY' THEN scen_super_heavy;
                ELSE scen_standard;
            END CASE;

            IF MOD(i, 100) = 0 THEN COMMIT; END IF;
        END LOOP;
        COMMIT;

        l_end_ts := SYSTIMESTAMP;
        
        l_elapsed := EXTRACT(SECOND FROM (l_end_ts - l_start_ts)) + 
                     EXTRACT(MINUTE FROM (l_end_ts - l_start_ts)) * 60;
                      
        IF l_elapsed = 0 THEN l_elapsed := 0.001; END IF;
        l_ops := ROUND(p_iterations / l_elapsed, 2);

        INSERT INTO plt_telemetry_errors (module_name, error_message)
        VALUES ('PERF_TEST', 
            'SCENARIO: ' || RPAD(p_scenario, 12) || 
            ' | ITER: ' || p_iterations || 
            ' | TIME: ' || TO_CHAR(l_elapsed, 'FM990.00') || 's' || 
            ' | OPS: ' || TO_CHAR(l_ops, 'FM999990.00'));
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            INSERT INTO plt_telemetry_errors (module_name, error_message)
            VALUES ('PERF_TEST_FAIL', 
                SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000));
            COMMIT;
    END run_test_session;

    -- =========================================================================
    -- CONCURRENCY ORCHESTRATOR (SPAWNER)
    -- =========================================================================
    PROCEDURE spawn_load_test(
        p_concurrent_users    NUMBER DEFAULT 5,
        p_iterations_per_user NUMBER DEFAULT 1000,
        p_scenario            VARCHAR2 DEFAULT 'STANDARD'
    ) IS
        l_job_name VARCHAR2(100);
        l_plsql    VARCHAR2(4000);
    BEGIN
        -- Clean up previous jobs
        FOR j IN (SELECT job_name FROM user_scheduler_jobs WHERE job_name LIKE 'PLT_PERF_%') LOOP
            BEGIN DBMS_SCHEDULER.DROP_JOB(j.job_name, force => TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        END LOOP;

        l_plsql := 'BEGIN PLT_PERF_SUITE.run_test_session(' || p_iterations_per_user || ', ''' || p_scenario || '''); END;';

        FOR i IN 1..p_concurrent_users LOOP
            l_job_name := 'PLT_PERF_USER_' || i;
            
            DBMS_SCHEDULER.CREATE_JOB (
                job_name   => l_job_name,
                job_type   => 'PLSQL_BLOCK',
                job_action => l_plsql,
                enabled    => TRUE,
                auto_drop  => TRUE,
                comments   => 'Load generator user ' || i
            );
        END LOOP;
        
        DBMS_OUTPUT.PUT_LINE('🚀 Launched ' || p_concurrent_users || ' concurrent users (Scenario: '||p_scenario||').');
    END spawn_load_test;

    -- =========================================================================
    -- RESET QUEUE (ADAPTED TO NEW 01/02 TOPOLOGY)
    -- =========================================================================
    PROCEDURE reset_queue IS
    BEGIN
        -- 1. Deep cleanup of physical tables
        -- Use Dynamic SQL in case the tables don't exist (though they should)
        BEGIN EXECUTE IMMEDIATE 'TRUNCATE TABLE plt_queue_01'; EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN EXECUTE IMMEDIATE 'TRUNCATE TABLE plt_queue_02'; EXCEPTION WHEN OTHERS THEN NULL; END;

        -- 2. Reset the Registry (Brain)
        -- Return to Factory Default state: 01 Active, 02 Ready.
        DELETE FROM plt_queue_registry;
        INSERT INTO plt_queue_registry (partition_name, is_active, state) VALUES ('PLT_QUEUE_01', 'Y', 'ACTIVE');
        INSERT INTO plt_queue_registry (partition_name, is_active, state) VALUES ('PLT_QUEUE_02', 'N', 'READY');

        -- 3. Reset the Pointer (Synonym)
        -- Ensure PLTelemetry points to 01
        EXECUTE IMMEDIATE 'CREATE OR REPLACE SYNONYM plt_queue_writer FOR plt_queue_01';

        -- 4. Clean up previous test results
        DELETE FROM plt_telemetry_errors WHERE module_name LIKE 'PERF_%';
        
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('🗑️ Queue topology reset (01 and 02 truncated, Registry restarted).');
    END reset_queue;

END PLT_PERF_SUITE;
/
