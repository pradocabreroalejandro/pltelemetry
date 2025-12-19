CREATE OR REPLACE PACKAGE BODY PLTelemetry AS

    -- =========================================================================
    -- INTERNAL STATE (SESSION MEMORY)
    -- =========================================================================
    
    -- Ampliamos tamaños por seguridad
    TYPE t_span_context IS RECORD (
        trace_id       VARCHAR2(64),
        span_id        VARCHAR2(32),
        parent_span_id VARCHAR2(32),
        operation      VARCHAR2(1000),
        start_time     TIMESTAMP WITH TIME ZONE,
        start_cpu      NUMBER
    );

    TYPE t_span_stack IS TABLE OF t_span_context INDEX BY BINARY_INTEGER;
    g_span_stack    t_span_stack;
    g_stack_ptr     BINARY_INTEGER := 0; 

    g_tenant_id     VARCHAR2(100) := 'default'; 
    g_session_id    VARCHAR2(32);

    -- =========================================================================
    -- PRIVATE HELPERS
    -- =========================================================================

    -- Generador HEX matemático (infalible contra ORA-06502)
    FUNCTION generate_hex_id(p_length NUMBER) RETURN VARCHAR2 IS
        l_res     VARCHAR2(100) := '';
        l_chars   CONSTANT VARCHAR2(16) := '0123456789abcdef';
        l_index   NUMBER;
    BEGIN
        FOR i IN 1..p_length LOOP
            l_index := TRUNC(DBMS_RANDOM.VALUE(1, 17)); 
            l_res := l_res || SUBSTR(l_chars, l_index, 1);
        END LOOP;
        RETURN l_res;
    END;

    FUNCTION iso_date(p_date TIMESTAMP WITH TIME ZONE) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(p_date, 'YYYY-MM-DD"T"HH24:MI:SS.FF6"Z"');
    END;

    -- INTERNAL ERROR LOGGER (Ahora con Stack Trace completo)
    PROCEDURE log_internal_error(p_msg VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        -- Ampliamos buffer para que quepa el stack
        l_full_msg VARCHAR2(4000); 
        l_tenant   VARCHAR2(100) := g_tenant_id;
        l_trace_id VARCHAR2(64); 
        l_span_id  VARCHAR2(32); 
    BEGIN
        IF g_stack_ptr > 0 THEN
            l_trace_id := g_span_stack(g_stack_ptr).trace_id;
            l_span_id  := g_span_stack(g_stack_ptr).span_id;
        END IF;

        -- Concatenamos mensaje + Stack de error + Backtrace (línea exacta)
        l_full_msg := SUBSTR(
            p_msg || CHR(10) || 
            'Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
            'Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 
            1, 4000
        );

        BEGIN
            INSERT INTO plt_telemetry_errors (
                error_message, module_name, tenant_id, trace_id, span_id
            ) VALUES (
                l_full_msg, 'PLTelemetry', l_tenant, l_trace_id, l_span_id
            );
        EXCEPTION WHEN OTHERS THEN
            -- Fallback
            INSERT INTO plt_telemetry_errors (error_message, module_name, tenant_id)
            VALUES (SUBSTR(l_full_msg, 1, 3500) || ' [FALLBACK]', 'PLTelemetry', l_tenant);
        END;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK;
    END;

    -- MAIN QUEUE WRITER
    PROCEDURE enqueue(p_type VARCHAR2, p_payload CLOB) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_tenant_local VARCHAR2(100) := g_tenant_id;
    BEGIN
        INSERT INTO plt_queue (item_type, payload, tenant_id)
        VALUES (p_type, p_payload, l_tenant_local);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_internal_error('Enqueue failed'); -- Ya cogerá el stack dentro
    END;

    FUNCTION attrs_to_json(p_attrs t_attributes) RETURN JSON_OBJECT_T IS
        l_json JSON_OBJECT_T := JSON_OBJECT_T();
        l_idx  BINARY_INTEGER;
    BEGIN
        IF p_attrs.COUNT > 0 THEN
            l_idx := p_attrs.FIRST;
            WHILE l_idx IS NOT NULL LOOP
                l_json.put(p_attrs(l_idx).key, p_attrs(l_idx).value);
                l_idx := p_attrs.NEXT(l_idx);
            END LOOP;
        END IF;
        RETURN l_json;
    EXCEPTION
        WHEN OTHERS THEN RETURN JSON_OBJECT_T(); 
    END;

    -- =========================================================================
    -- PUBLIC API IMPLEMENTATION
    -- =========================================================================

    FUNCTION attr(k VARCHAR2, v VARCHAR2) RETURN t_attribute IS
        l_rec t_attribute;
    BEGIN
        l_rec.key := k;
        l_rec.value := v;
        RETURN l_rec;
    END;

    PROCEDURE set_tenant(p_tenant_id VARCHAR2) IS
    BEGIN
        g_tenant_id := NVL(TRIM(p_tenant_id), 'default');
    END;

    FUNCTION start_span(
        p_operation   IN VARCHAR2,
        p_force_trace IN BOOLEAN DEFAULT FALSE
    ) RETURN VARCHAR2 IS
        l_ctx t_span_context;
    BEGIN
        IF g_session_id IS NULL THEN g_session_id := generate_hex_id(16); END IF;

        l_ctx.operation  := SUBSTR(p_operation, 1, 900); 
        l_ctx.start_time := SYSTIMESTAMP;
        l_ctx.span_id    := generate_hex_id(16);
        l_ctx.start_cpu  := DBMS_UTILITY.GET_CPU_TIME;

        IF g_stack_ptr > 0 THEN
            l_ctx.trace_id       := g_span_stack(g_stack_ptr).trace_id;
            l_ctx.parent_span_id := g_span_stack(g_stack_ptr).span_id;
        ELSE
            l_ctx.trace_id       := generate_hex_id(32);
            l_ctx.parent_span_id := NULL;
        END IF;

        g_stack_ptr := g_stack_ptr + 1;
        g_span_stack(g_stack_ptr) := l_ctx;

        DBMS_APPLICATION_INFO.SET_ACTION('SPAN:' || SUBSTR(l_ctx.operation, 1, 30));

        RETURN l_ctx.span_id;
    EXCEPTION
        WHEN OTHERS THEN
            log_internal_error('start_span error');
            RETURN NULL;
    END;

    PROCEDURE end_span(
        p_status_code IN VARCHAR2 DEFAULT 'OK',
        p_status_msg  IN VARCHAR2 DEFAULT NULL
    ) IS
        l_ctx         t_span_context;
        l_json_obj    JSON_OBJECT_T;
        l_duration_ms NUMBER;
        l_end_time    TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
    BEGIN
        IF g_stack_ptr < 1 THEN RETURN; END IF;

        l_ctx := g_span_stack(g_stack_ptr);
        g_span_stack.DELETE(g_stack_ptr);
        g_stack_ptr := g_stack_ptr - 1;

        l_duration_ms := EXTRACT(DAY FROM (l_end_time - l_ctx.start_time)) * 86400000 +
                         EXTRACT(HOUR FROM (l_end_time - l_ctx.start_time)) * 3600000 +
                         EXTRACT(MINUTE FROM (l_end_time - l_ctx.start_time)) * 60000 +
                         EXTRACT(SECOND FROM (l_end_time - l_ctx.start_time)) * 1000;

        l_json_obj := JSON_OBJECT_T();
        l_json_obj.put('trace_id', l_ctx.trace_id);
        l_json_obj.put('span_id', l_ctx.span_id);
        l_json_obj.put('operation_name', l_ctx.operation);
        l_json_obj.put('tenant_id', g_tenant_id);
        l_json_obj.put('start_time', iso_date(l_ctx.start_time));
        l_json_obj.put('end_time', iso_date(l_end_time));
        l_json_obj.put('duration_ms', l_duration_ms);
        l_json_obj.put('status', p_status_code);

        IF l_ctx.parent_span_id IS NOT NULL THEN
            l_json_obj.put('parent_span_id', l_ctx.parent_span_id);
        END IF;

        IF p_status_msg IS NOT NULL THEN
            l_json_obj.put('status_message', p_status_msg);
        END IF;

        enqueue('TRACE', l_json_obj.to_clob());

        IF g_stack_ptr > 0 THEN
            DBMS_APPLICATION_INFO.SET_ACTION('SPAN:' || SUBSTR(g_span_stack(g_stack_ptr).operation, 1, 30));
        ELSE
            DBMS_APPLICATION_INFO.SET_ACTION(NULL);
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            log_internal_error('end_span error');
    END;

    PROCEDURE log_metric(
        p_name  IN VARCHAR2,
        p_value IN NUMBER,
        p_type  IN VARCHAR2, 
        p_unit  IN VARCHAR2 DEFAULT '1',
        p_attrs IN t_attributes DEFAULT CAST(NULL AS t_attributes)
    ) IS
        l_json_obj JSON_OBJECT_T;
        l_trace_id VARCHAR2(64);
        l_span_id  VARCHAR2(32);
    BEGIN
        IF g_stack_ptr > 0 THEN
            l_trace_id := g_span_stack(g_stack_ptr).trace_id;
            l_span_id  := g_span_stack(g_stack_ptr).span_id;
        END IF;

        l_json_obj := JSON_OBJECT_T();
        l_json_obj.put('name', p_name);
        l_json_obj.put('value', p_value);
        l_json_obj.put('type', p_type);
        l_json_obj.put('unit', p_unit);
        l_json_obj.put('tenant_id', g_tenant_id);
        l_json_obj.put('timestamp', iso_date(SYSTIMESTAMP));

        IF l_trace_id IS NOT NULL THEN
             l_json_obj.put('trace_id', l_trace_id);
             l_json_obj.put('span_id', l_span_id);
        END IF;

        IF p_attrs.COUNT > 0 THEN
            l_json_obj.put('attributes', attrs_to_json(p_attrs));
        END IF;

        enqueue('METRIC', l_json_obj.to_clob());
    EXCEPTION
        WHEN OTHERS THEN
            log_internal_error('log_metric error');
    END;

    PROCEDURE log(
        p_level   IN VARCHAR2,
        p_message IN VARCHAR2,
        p_attrs   IN t_attributes DEFAULT CAST(NULL AS t_attributes)
    ) IS
        l_json_obj JSON_OBJECT_T;
        l_trace_id VARCHAR2(64);
        l_span_id  VARCHAR2(32);
    BEGIN
        IF g_stack_ptr > 0 THEN
            l_trace_id := g_span_stack(g_stack_ptr).trace_id;
            l_span_id  := g_span_stack(g_stack_ptr).span_id;
        END IF;

        l_json_obj := JSON_OBJECT_T();
        l_json_obj.put('severity', p_level);
        l_json_obj.put('message', p_message);
        l_json_obj.put('tenant_id', g_tenant_id);
        l_json_obj.put('timestamp', iso_date(SYSTIMESTAMP));

        IF l_trace_id IS NOT NULL THEN
             l_json_obj.put('trace_id', l_trace_id);
             l_json_obj.put('span_id', l_span_id);
        END IF;

        IF p_attrs.COUNT > 0 THEN
            l_json_obj.put('attributes', attrs_to_json(p_attrs));
        END IF;
        
        enqueue('LOG', l_json_obj.to_clob());
    EXCEPTION
        WHEN OTHERS THEN
            log_internal_error('log error');
    END;

END PLTelemetry;
/