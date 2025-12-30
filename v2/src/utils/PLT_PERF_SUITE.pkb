CREATE OR REPLACE PACKAGE BODY PLT_PERF_SUITE AS

    -- Variable dummy para ignorar retornos de funciones si fuera necesario
    ignore_result VARCHAR2(100);

    -- =========================================================================
    -- HELPER INTERNO PARA LOGUEAR ATRIBUTOS
    -- =========================================================================
    PROCEDURE log_kv(p_key VARCHAR2, p_val VARCHAR2) IS
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_attrs(1) := PLTelemetry.attr(p_key, p_val);
        PLTelemetry.log('INFO', 'Attribute Log', l_attrs);
    END;

    -- =========================================================================
    -- GENERADORES DE ESCENARIOS
    -- =========================================================================

    -- ESCENARIO 1: LIGERO (Métricas puras y Logs cortos)
    PROCEDURE scen_light IS
    BEGIN
        PLTelemetry.log_metric('perf.test.counter', 1, 'COUNTER');
        PLTelemetry.log('INFO', 'Keep alive signal');
    END;

    -- ESCENARIO 2: ESTÁNDAR (Simulación de Pedido)
    PROCEDURE scen_standard IS
        l_span_id VARCHAR2(64);
    BEGIN
        l_span_id := PLTelemetry.start_span('process_order');
        
        log_kv('order.id', TO_CHAR(TRUNC(DBMS_RANDOM.VALUE(1000,9999))));
        log_kv('client.region', 'EU-WEST');
        
        -- Span hijo 1
        ignore_result := PLTelemetry.start_span('validate_stock');
        PLTelemetry.end_span('OK');

        -- Span hijo 2
        ignore_result := PLTelemetry.start_span('charge_credit_card');
        PLTelemetry.end_span('OK');

        PLTelemetry.log('INFO', 'Order processed successfully');
        PLTelemetry.end_span('OK');
    END;

    -- ESCENARIO 3: PESADO (Atributos grandes, CLOBs, Errores)
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

    -- ESCENARIO 4: SUPER HEAVY (Deep Nesting + Loops + High Volume)
    PROCEDURE scen_super_heavy IS
        l_root    VARCHAR2(64);
        l_batch   VARCHAR2(64);
        l_item    VARCHAR2(64);
        -- Simulamos un payload JSON que roza los límites de VARCHAR2
        l_payload VARCHAR2(32000) := RPAD('{"data":"', 4000, 'X') || '"}';
    BEGIN
        -- Nivel 0: Proceso General
        l_root := PLTelemetry.start_span('etl_nightly_job');
        log_kv('job.id', 'ETL-999');

        -- Simulamos procesamiento por lotes
        FOR i IN 1..3 LOOP -- 3 Batches
            -- Nivel 1: Batch
            l_batch := PLTelemetry.start_span('process_batch_' || i);
            log_kv('batch.size', '500');

            -- Nivel 2: Items dentro del batch (simulamos un loop rápido)
            FOR j IN 1..5 LOOP 
                l_item := PLTelemetry.start_span('transform_row');
                -- Inyectamos mucho texto para probar serialización
                log_kv('row.data', substr(l_payload, 1, 1000)); 
                PLTelemetry.end_span('OK');
            END LOOP;

            PLTelemetry.log('INFO', 'Batch '||i||' finished');
            PLTelemetry.end_span('OK'); -- Fin Batch
        END LOOP;

        PLTelemetry.end_span('OK'); -- Fin Root
    END;

    -- =========================================================================
    -- EJECUTOR DE SESIÓN
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
        -- Forzamos tenant de pruebas único para cada escenario
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
    -- ORQUESTADOR DE CONCURRENCIA (SPAWNER)
    -- =========================================================================
    PROCEDURE spawn_load_test(
        p_concurrent_users    NUMBER DEFAULT 5,
        p_iterations_per_user NUMBER DEFAULT 1000,
        p_scenario            VARCHAR2 DEFAULT 'STANDARD'
    ) IS
        l_job_name VARCHAR2(100);
        l_plsql    VARCHAR2(4000);
    BEGIN
        -- Limpiamos jobs previos
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
        
        DBMS_OUTPUT.PUT_LINE('🚀 Lanzados ' || p_concurrent_users || ' usuarios concurrentes (Escenario: '||p_scenario||').');
    END spawn_load_test;

    PROCEDURE reset_queue IS
    BEGIN
        EXECUTE IMMEDIATE 'TRUNCATE TABLE plt_queue';
        -- Limpiamos logs de tests anteriores para tener la tabla de resultados limpia
        DELETE FROM plt_telemetry_errors WHERE module_name = 'PERF_TEST';
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('🗑️ Cola y logs de prueba vaciados.');
    END;

END PLT_PERF_SUITE;
/