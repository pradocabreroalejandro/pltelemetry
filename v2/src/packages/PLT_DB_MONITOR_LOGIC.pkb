CREATE OR REPLACE PACKAGE BODY PLTELEMETRY.PLT_DB_MONITOR_LOGIC AS

    ----------------------------------------------------------------------------
    -- Private: Procesa el cursor. 
    -- YA NO NECESITA p_tenant_id como parámetro, lo coge del ambiente.
    ----------------------------------------------------------------------------
    PROCEDURE process_metrics(p_dataset t_plt_metric_tab) IS 
        l_attrs PLTelemetry.t_attributes;
        l_json  JSON_OBJECT_T;
        l_keys  JSON_KEY_LIST;
    BEGIN
        IF p_dataset IS NULL OR p_dataset.COUNT = 0 THEN RETURN; END IF;

        FOR i IN 1 .. p_dataset.COUNT LOOP
            l_attrs := CAST(NULL AS PLTelemetry.t_attributes);
            
            -- NOTA: Ya no inyectamos 'tenant_id' aquí manualmente.
            -- PLTelemetry.log_metric lo cogerá de su g_tenant_id interno.
            
            -- Solo procesamos tags extra si la métrica los trae (ej: tablespace)
            IF p_dataset(i).tags_json IS NOT NULL THEN
                BEGIN
                    l_json := JSON_OBJECT_T.parse(p_dataset(i).tags_json);
                    l_keys := l_json.get_keys;
                    FOR k IN 1 .. l_keys.COUNT LOOP
                        l_attrs(l_attrs.COUNT + 1) := 
                            PLTelemetry.attr(l_keys(k), l_json.get_string(l_keys(k)));
                    END LOOP;
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END IF;

            -- Llamada limpia
            PLTelemetry.log_metric(
                p_name  => p_dataset(i).metric_name,
                p_value => p_dataset(i).metric_value,
                p_type  => p_dataset(i).metric_type,
                p_attrs => l_attrs
            );
        END LOOP;
    END;

    ----------------------------------------------------------------------------
    -- Ejecuta un colector (Simplificado)
    ----------------------------------------------------------------------------
    PROCEDURE run_collector_dynamic(
        p_code      VARCHAR2, 
        p_package   VARCHAR2, 
        p_func      VARCHAR2
    ) IS
        l_rows   t_plt_metric_tab;
        l_sql    VARCHAR2(1000);
    BEGIN
        -- No necesitamos pasar el tenant aquí, porque ya se seteó antes de llamar a esta func.
        
        l_sql := 'SELECT VALUE(t) FROM TABLE(' || 
                 DBMS_ASSERT.SIMPLE_SQL_NAME(p_package) || '.' || 
                 DBMS_ASSERT.SIMPLE_SQL_NAME(p_func) || ') t';

        BEGIN
            EXECUTE IMMEDIATE l_sql BULK COLLECT INTO l_rows;
            process_metrics(l_rows); -- Llamada simple
        EXCEPTION 
            WHEN OTHERS THEN
                PLTelemetry.log('ERROR', 'Fallo en ' || p_code || ': ' || SQLERRM);
        END;
    END;

    ----------------------------------------------------------------------------
    -- Loop Principal (Donde gestionamos el Contexto)
    ----------------------------------------------------------------------------
    PROCEDURE run_collection_cycle IS
    BEGIN
        FOR r IN (
            SELECT collector_code, reader_package, reader_function, execution_scope
            FROM plt_metric_collectors
            WHERE is_enabled = 1 
              AND (last_run IS NULL OR 
                   last_run + numtodsinterval(interval_seconds, 'SECOND') <= SYSTIMESTAMP)
        ) LOOP
            
            IF r.execution_scope = 'PER_TENANT' THEN
                -- === MODO MULTI-TENANT ===
                FOR t IN (SELECT tenant_id FROM plt_tenants WHERE is_enabled = 1) LOOP
                    
                    -- 1. ESTABLECER CONTEXTO GLOBAL
                    PLTelemetry.set_tenant(t.tenant_id);
                    
                    -- 2. EJECUTAR (El paquete PLTelemetry usará ese tenant internamente)
                    run_collector_dynamic(r.collector_code, r.reader_package, r.reader_function);
                    
                END LOOP;
                
            ELSE
                -- === MODO GLOBAL ===
                -- 1. ESTABLECER CONTEXTO DEFAULT
                PLTelemetry.set_tenant('default');
                
                -- 2. EJECUTAR
                run_collector_dynamic(r.collector_code, r.reader_package, r.reader_function);
            END IF;

            -- Resetear contexto por seguridad al salir
            PLTelemetry.set_tenant('default');

            UPDATE plt_metric_collectors 
               SET last_run = SYSTIMESTAMP 
             WHERE collector_code = r.collector_code;
             
        END LOOP;
        
        COMMIT;
    END;

END PLT_DB_MONITOR_LOGIC;
/