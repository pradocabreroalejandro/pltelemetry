CREATE OR REPLACE PACKAGE BODY PLT_OTLP_BRIDGE AS

    -- =========================================================================
    -- CONFIGURACIÓN GLOBAL
    -- =========================================================================
    g_base_url      VARCHAR2(500);
    g_service_name  VARCHAR2(100) := 'oracle-db';
    g_env           VARCHAR2(100) := 'prod';
    g_debug         BOOLEAN := FALSE;
    
    -- Cache del Resource
    g_cached_resource JSON_OBJECT_T;

    -- =========================================================================
    -- UTILIDADES
    -- =========================================================================

    PROCEDURE log_debug(p_msg VARCHAR2) IS
    BEGIN
        IF g_debug THEN DBMS_OUTPUT.PUT_LINE('[BRIDGE] ' || p_msg); END IF;
    END;

    FUNCTION random_hex(p_length NUMBER) RETURN VARCHAR2 IS
        l_hex VARCHAR2(100);
    BEGIN
        SELECT LISTAGG(TO_CHAR(ROUND(DBMS_RANDOM.VALUE(0, 15)), 'X'), '') 
               WITHIN GROUP (ORDER BY level)
        INTO l_hex
        FROM dual 
        CONNECT BY level <= p_length;
        RETURN TRIM(l_hex);
    END;

    FUNCTION get_timestamp_nano(p_ts TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP) RETURN VARCHAR2 IS
        l_epoch TIMESTAMP WITH TIME ZONE := TO_TIMESTAMP_TZ('1970-01-01 00:00:00 +00:00', 'YYYY-MM-DD HH24:MI:SS TZH:TZM');
        l_diff INTERVAL DAY(9) TO SECOND(9);
        l_seconds NUMBER;
    BEGIN
        l_diff := p_ts - l_epoch;
        l_seconds := EXTRACT(DAY FROM l_diff) * 86400 + 
                     EXTRACT(HOUR FROM l_diff) * 3600 + 
                     EXTRACT(MINUTE FROM l_diff) * 60 + 
                     EXTRACT(SECOND FROM l_diff);
        -- Formato texto para evitar notación científica
        RETURN TO_CHAR(TRUNC(l_seconds)) || TO_CHAR(EXTRACT(SECOND FROM l_diff) - TRUNC(EXTRACT(SECOND FROM l_diff)), 'FM.000000000') * 1000000000;
    END;

    -- Versión para strings ISO8601
    FUNCTION to_unix_nano(p_iso_ts VARCHAR2) RETURN VARCHAR2 IS
        l_ts TIMESTAMP WITH TIME ZONE;
    BEGIN
        IF p_iso_ts IS NULL THEN l_ts := SYSTIMESTAMP; 
        ELSE 
            BEGIN
                l_ts := TO_TIMESTAMP_TZ(p_iso_ts, 'YYYY-MM-DD"T"HH24:MI:SS.FF6"Z"');
            EXCEPTION WHEN OTHERS THEN l_ts := SYSTIMESTAMP; END;
        END IF;
        RETURN get_timestamp_nano(l_ts);
    END;

    FUNCTION get_resource(p_tenant_id VARCHAR2) RETURN JSON_OBJECT_T IS
        l_res JSON_OBJECT_T;
        l_attrs JSON_ARRAY_T;
        PROCEDURE add_attr(k VARCHAR2, v VARCHAR2) IS
            l_kv JSON_OBJECT_T := JSON_OBJECT_T();
            l_val JSON_OBJECT_T := JSON_OBJECT_T();
        BEGIN
            l_val.put('stringValue', v);
            l_kv.put('key', k); l_kv.put('value', l_val);
            l_attrs.append(l_kv);
        END;
    BEGIN
        IF g_cached_resource IS NULL THEN g_cached_resource := JSON_OBJECT_T(); END IF;
        l_res := JSON_OBJECT_T();
        l_attrs := JSON_ARRAY_T();

        add_attr('service.name', g_service_name);
        add_attr('deployment.environment', g_env);
        add_attr('telemetry.sdk.language', 'plsql');
        add_attr('db.instance', SYS_CONTEXT('USERENV', 'INSTANCE_NAME'));
        add_attr('tenant.id', NVL(p_tenant_id, 'default'));

        l_res.put('attributes', l_attrs);
        RETURN l_res;
    END;

    -- =========================================================================
    -- HTTP SENDER
    -- =========================================================================
    PROCEDURE send_http(p_path VARCHAR2, p_payload CLOB) IS
        l_req  UTL_HTTP.REQ;
        l_res  UTL_HTTP.RESP;
        l_url  VARCHAR2(1000) := g_base_url || p_path;
        l_len  NUMBER := DBMS_LOB.GETLENGTH(p_payload);
        l_buff VARCHAR2(32000);
        l_off  NUMBER := 1;
        l_amt  NUMBER := 32000;
    BEGIN
        -- Ojo: Si no tienes ACLs configuradas, esto fallará en tiempo de ejecución
        UTL_HTTP.SET_TRANSFER_TIMEOUT(10);
        l_req := UTL_HTTP.BEGIN_REQUEST(l_url, 'POST', 'HTTP/1.1');
        UTL_HTTP.SET_HEADER(l_req, 'Content-Type', 'application/json');
        UTL_HTTP.SET_HEADER(l_req, 'Content-Length', l_len);
        
        WHILE l_off <= l_len LOOP
            DBMS_LOB.READ(p_payload, l_amt, l_off, l_buff);
            UTL_HTTP.WRITE_TEXT(l_req, l_buff);
            l_off := l_off + l_amt;
        END LOOP;

        l_res := UTL_HTTP.GET_RESPONSE(l_req);
        -- log_debug('HTTP Status: ' || l_res.status_code);
        BEGIN LOOP UTL_HTTP.READ_TEXT(l_res, l_buff, 32000); END LOOP;
        EXCEPTION WHEN UTL_HTTP.END_OF_BODY THEN NULL; END;
        UTL_HTTP.END_RESPONSE(l_res);
    EXCEPTION
        WHEN OTHERS THEN
            log_debug('HTTP Error: ' || SQLERRM);
            BEGIN UTL_HTTP.END_RESPONSE(l_res); EXCEPTION WHEN OTHERS THEN NULL; END;
            -- No hacemos raise para no abortar el proceso batch
    END;

    -- =========================================================================
    -- TELEMETRY SENDERS (Ahora definidos ANTES de usarse)
    -- =========================================================================

    -- 1. MÉTRICAS
    PROCEDURE send_metric(p_src JSON_OBJECT_T) IS
        l_otlp_root JSON_OBJECT_T := JSON_OBJECT_T();
        l_rm        JSON_ARRAY_T := JSON_ARRAY_T(); 
        l_rm_obj    JSON_OBJECT_T := JSON_OBJECT_T();
        l_sm        JSON_ARRAY_T := JSON_ARRAY_T(); 
        l_sm_obj    JSON_OBJECT_T := JSON_OBJECT_T();
        l_metrics   JSON_ARRAY_T := JSON_ARRAY_T();
        l_m_obj     JSON_OBJECT_T := JSON_OBJECT_T();
        l_data      JSON_OBJECT_T := JSON_OBJECT_T();
        l_pts       JSON_ARRAY_T := JSON_ARRAY_T();
        l_pt        JSON_OBJECT_T := JSON_OBJECT_T();
        l_attrs     JSON_ARRAY_T := JSON_ARRAY_T(); 
        
        l_name      VARCHAR2(255) := p_src.get_string('name');
        l_val       NUMBER := p_src.get_number('value');
        l_type      VARCHAR2(50) := NVL(p_src.get_string('type'), 'GAUGE');
        l_trace_id  VARCHAR2(32) := p_src.get_string('trace_id');
        l_span_id   VARCHAR2(16) := p_src.get_string('span_id');

        PROCEDURE add_pt_attr(k VARCHAR2, v VARCHAR2) IS
            l_kv JSON_OBJECT_T := JSON_OBJECT_T();
            l_v  JSON_OBJECT_T := JSON_OBJECT_T();
        BEGIN
            l_v.put('stringValue', v); l_kv.put('key', k); l_kv.put('value', l_v); l_attrs.append(l_kv);
        END;
    BEGIN
        l_pt.put('timeUnixNano', to_unix_nano(p_src.get_string('timestamp')));
        IF l_type = 'COUNTER' THEN l_pt.put('asInt', l_val); ELSE l_pt.put('asDouble', l_val); END IF;
        
        IF l_trace_id IS NOT NULL THEN add_pt_attr('trace_id', l_trace_id); END IF;
        IF l_span_id IS NOT NULL THEN add_pt_attr('span_id', l_span_id); END IF;
        
        l_pt.put('attributes', l_attrs);
        l_pts.append(l_pt);
        l_data.put('dataPoints', l_pts);
        
        l_m_obj.put('name', l_name);
        IF l_type = 'COUNTER' THEN
            l_data.put('isMonotonic', TRUE); l_data.put('aggregationTemporality', 2);
            l_m_obj.put('sum', l_data);
        ELSE
            l_m_obj.put('gauge', l_data);
        END IF;
        l_metrics.append(l_m_obj);
        l_sm_obj.put('metrics', l_metrics);
        l_sm.append(l_sm_obj);
        l_rm_obj.put('resource', get_resource(p_src.get_string('tenant_id')));
        l_rm_obj.put('scopeMetrics', l_sm);
        l_rm.append(l_rm_obj);
        l_otlp_root.put('resourceMetrics', l_rm);

        send_http('/v1/metrics', l_otlp_root.to_clob());
    END;

    -- 2. TRAZAS
    PROCEDURE send_trace(p_data JSON_OBJECT_T) IS
        l_otlp_payload   JSON_OBJECT_T := JSON_OBJECT_T();
        l_resource_spans JSON_ARRAY_T := JSON_ARRAY_T();
        l_scope_spans    JSON_ARRAY_T := JSON_ARRAY_T();
        l_spans          JSON_ARRAY_T := JSON_ARRAY_T();
        l_span           JSON_OBJECT_T := JSON_OBJECT_T();
        
        -- Objetos intermedios declarados arriba para evitar el "Dim"
        l_scope_obj      JSON_OBJECT_T := JSON_OBJECT_T();
        l_scope          JSON_OBJECT_T := JSON_OBJECT_T();
        l_res_span_obj   JSON_OBJECT_T := JSON_OBJECT_T();
        
        l_trace_id       VARCHAR2(32);
        l_span_id        VARCHAR2(16);
        l_start_time     VARCHAR2(50);
        l_end_time       VARCHAR2(50);
    BEGIN
        l_trace_id := NVL(p_data.get_String('trace_id'), random_hex(32));
        l_span_id := NVL(p_data.get_String('span_id'), random_hex(16));
        l_start_time := get_timestamp_nano(); 
        l_end_time := get_timestamp_nano(SYSTIMESTAMP + NUMTODSINTERVAL(0.1, 'SECOND')); -- 100ms dummy

        l_span.put('traceId', l_trace_id);
        l_span.put('spanId', l_span_id);
        IF p_data.has('parent_span_id') THEN
            l_span.put('parentSpanId', p_data.get_String('parent_span_id'));
        END IF;
        l_span.put('name', NVL(p_data.get_String('name'), 'oracle-db-operation'));
        l_span.put('kind', 1); -- INTERNAL
        l_span.put('startTimeUnixNano', l_start_time);
        l_span.put('endTimeUnixNano', l_end_time);
        
        l_spans.append(l_span);
        
        -- Scope
        l_scope.put('name', 'oracle.plsql.bridge');
        l_scope.put('version', '1.0.0');
        l_scope_obj.put('scope', l_scope);
        l_scope_obj.put('spans', l_spans);
        l_scope_spans.append(l_scope_obj);
        
        -- Resource
        l_res_span_obj.put('resource', get_resource(p_data.get_string('tenant_id')));
        l_res_span_obj.put('scopeSpans', l_scope_spans);
        l_resource_spans.append(l_res_span_obj);
        
        l_otlp_payload.put('resourceSpans', l_resource_spans);

        send_http('/v1/traces', l_otlp_payload.to_clob);
        
        IF g_debug THEN log_debug('Trace sent: ' || l_trace_id); END IF;
    END;

    -- 3. LOGS
    PROCEDURE send_log(p_data JSON_OBJECT_T) IS
        l_otlp_payload  JSON_OBJECT_T := JSON_OBJECT_T();
        l_resource_logs JSON_ARRAY_T := JSON_ARRAY_T();
        l_scope_logs    JSON_ARRAY_T := JSON_ARRAY_T();
        l_log_records   JSON_ARRAY_T := JSON_ARRAY_T();
        
        l_log           JSON_OBJECT_T := JSON_OBJECT_T();
        l_body          JSON_OBJECT_T := JSON_OBJECT_T();
        
        -- Variables auxiliares declaradas correctamente
        l_scope_log_obj JSON_OBJECT_T := JSON_OBJECT_T();
        l_res_log_obj   JSON_OBJECT_T := JSON_OBJECT_T();
    BEGIN
        l_log.put('timeUnixNano', get_timestamp_nano());
        l_log.put('severityText', NVL(p_data.get_String('severity'), 'INFO'));
        
        l_body.put('stringValue', NVL(p_data.get_String('message'), 'Empty log message'));
        l_log.put('body', l_body);
        
        IF p_data.has('trace_id') THEN l_log.put('traceId', p_data.get_String('trace_id')); END IF;
        IF p_data.has('span_id') THEN l_log.put('spanId', p_data.get_String('span_id')); END IF;

        l_log_records.append(l_log);

        l_scope_log_obj.put('logRecords', l_log_records);
        l_scope_logs.append(l_scope_log_obj);
        
        l_res_log_obj.put('resource', get_resource(p_data.get_string('tenant_id')));
        l_res_log_obj.put('scopeLogs', l_scope_logs);
        l_resource_logs.append(l_res_log_obj);
        
        l_otlp_payload.put('resourceLogs', l_resource_logs);

        send_http('/v1/logs', l_otlp_payload.to_clob);
        
        IF g_debug THEN log_debug('Log sent.'); END IF;
    END;

    -- =========================================================================
    -- PROCESAMIENTO PRINCIPAL (Ahora ya "ve" las funciones de arriba)
    -- =========================================================================

    PROCEDURE init(p_otlp_endpoint VARCHAR2, p_service_name VARCHAR2, p_environment VARCHAR2) IS
    BEGIN
        g_base_url := RTRIM(p_otlp_endpoint, '/');
        g_service_name := p_service_name;
        g_env := p_environment;
    END;

    PROCEDURE set_debug(p_enabled BOOLEAN) IS BEGIN g_debug := p_enabled; END;

    PROCEDURE process_payload(p_item_type VARCHAR2, p_json CLOB) IS
        l_obj JSON_OBJECT_T;
    BEGIN
        IF g_base_url IS NULL THEN
            RAISE_APPLICATION_ERROR(-20000, 'PLT_OTLP_BRIDGE not initialized. Call init() first.');
        END IF;

        l_obj := JSON_OBJECT_T.parse(p_json);

        IF p_item_type = 'METRIC' THEN
            send_metric(l_obj);
        ELSIF p_item_type = 'TRACE' THEN
            send_trace(l_obj); 
        ELSIF p_item_type = 'LOG' THEN
            send_log(l_obj);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            log_debug('Error processing payload: ' || SQLERRM);
    END;

END PLT_OTLP_BRIDGE;
/