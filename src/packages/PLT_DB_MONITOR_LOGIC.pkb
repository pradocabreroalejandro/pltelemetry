CREATE OR REPLACE PACKAGE BODY PLTELEMETRY.PLT_DB_MONITOR_LOGIC AS

    ----------------------------------------------------------------------------
    -- Private: Processes metrics and sends them to PLTelemetry queue.
    -- V3 compatible: tenant is passed via p_tenant_id parameter.
    ----------------------------------------------------------------------------
    PROCEDURE process_metrics(
        p_dataset   t_plt_metric_tab,
        p_tenant_id VARCHAR2 DEFAULT 'default'
    ) IS 
        l_attrs PLTelemetry.t_attributes;
        l_json  JSON_OBJECT_T;
        l_keys  JSON_KEY_LIST;
    BEGIN
        IF p_dataset IS NULL OR p_dataset.COUNT = 0 THEN RETURN; END IF;

        FOR i IN 1 .. p_dataset.COUNT LOOP
            l_attrs := CAST(NULL AS PLTelemetry.t_attributes);
            
            -- Only process extra tags if the metric brings them (e.g.: tablespace)
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

            -- V3 compatible: pass tenant explicitly
            PLTelemetry.log_metric(
                p_name      => p_dataset(i).metric_name,
                p_value     => p_dataset(i).metric_value,
                p_type      => p_dataset(i).metric_type,
                p_attrs     => l_attrs,
                p_tenant_id => p_tenant_id
            );
        END LOOP;
    END;

    ----------------------------------------------------------------------------
    -- Executes a collector with explicit tenant parameter
    ----------------------------------------------------------------------------
    PROCEDURE run_collector_dynamic(
        p_code      VARCHAR2, 
        p_package   VARCHAR2, 
        p_func      VARCHAR2,
        p_tenant_id VARCHAR2 DEFAULT 'default'
    ) IS
        l_rows   t_plt_metric_tab;
        l_sql    VARCHAR2(1000);
    BEGIN
        l_sql := 'SELECT VALUE(t) FROM TABLE(' || 
                 DBMS_ASSERT.SIMPLE_SQL_NAME(p_package) || '.' || 
                 DBMS_ASSERT.SIMPLE_SQL_NAME(p_func) || ') t';

        BEGIN
            EXECUTE IMMEDIATE l_sql BULK COLLECT INTO l_rows;
            process_metrics(l_rows, p_tenant_id); 
        EXCEPTION 
            WHEN OTHERS THEN
                PLTelemetry.log('ERROR', 'Failure in ' || p_code || ': ' || 
                    SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
                           DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000),
                    p_tenant_id => p_tenant_id);
        END;
    END;

    ----------------------------------------------------------------------------
    -- Main Loop: Iterates collectors and handles tenant context
    ----------------------------------------------------------------------------
    PROCEDURE run_collection_cycle IS
        l_tenant_id VARCHAR2(100);
    BEGIN
        FOR r IN (
            SELECT collector_code, reader_package, reader_function, execution_scope
            FROM plt_metric_collectors
            WHERE is_enabled = 1 
              AND (last_run IS NULL OR 
                   last_run + numtodsinterval(interval_seconds, 'SECOND') <= SYSTIMESTAMP)
        ) LOOP
            
            IF r.execution_scope = 'PER_TENANT' THEN
                -- === MULTI-TENANT MODE: one call per tenant ===
                FOR t IN (SELECT tenant_id FROM plt_tenants WHERE is_enabled = 1) LOOP
                    l_tenant_id := t.tenant_id;
                    run_collector_dynamic(
                        r.collector_code, 
                        r.reader_package, 
                        r.reader_function,
                        l_tenant_id
                    );
                END LOOP;
                
            ELSE
                -- === GLOBAL MODE: single call with default tenant ===
                l_tenant_id := 'default';
                run_collector_dynamic(
                    r.collector_code, 
                    r.reader_package, 
                    r.reader_function,
                    l_tenant_id
                );
            END IF;

            -- Update last_run timestamp
            UPDATE plt_metric_collectors 
               SET last_run = SYSTIMESTAMP 
             WHERE collector_code = r.collector_code;
             
        END LOOP;
        
        COMMIT;
    EXCEPTION 
        WHEN OTHERS THEN
            ROLLBACK;
            PLTelemetry.log('ERROR', 'Critical error in run_collection_cycle: ' || 
                SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
                       DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000));
    END;

END PLT_DB_MONITOR_LOGIC;

/
