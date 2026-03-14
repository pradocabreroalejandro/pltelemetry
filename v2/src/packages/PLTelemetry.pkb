CREATE OR REPLACE PACKAGE BODY PLTelemetry AS

    -- =========================================================================
    -- INTERNAL STATE (SESSION MEMORY)
    -- =========================================================================
    
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
    
    -- Variables para W3C Injection
    g_current_trace_id   VARCHAR2(32); 
    g_external_parent_id VARCHAR2(16);

    -- =========================================================================
    -- PRIVATE HELPERS
    -- =========================================================================

    PROCEDURE log_debug(p_msg VARCHAR2) IS
    BEGIN
        IF g_debug THEN DBMS_OUTPUT.PUT_LINE('[BRIDGE] ' || p_msg); END IF;
    END;

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

    -- =========================================================================
    -- [NUEVO] AUTO-DETECCIÓN DE CONTEXTO (Versión UTL_CALL_STACK Correcta)
    -- =========================================================================
    FUNCTION auto_detect_context RETURN VARCHAR2 IS
        l_depth      PLS_INTEGER;
        l_unit_name  VARCHAR2(4000);
    BEGIN
        -- 1. Obtenemos profundidad
        l_depth := UTL_CALL_STACK.DYNAMIC_DEPTH; 

        -- 2. Recorremos hacia arriba
        FOR i IN 2 .. l_depth LOOP
            
            -- Obtenemos el nombre cualificado (ESQUEMA.PAQUETE.PROCEDIMIENTO)
            l_unit_name := UTL_CALL_STACK.CONCATENATE_SUBPROGRAM(UTL_CALL_STACK.SUBPROGRAM(i));
            
            -- FILTRO: Ignorar al propio paquete
            IF l_unit_name IS NOT NULL AND UPPER(l_unit_name) NOT LIKE '%PLTELEMETRY%' THEN
                
                -- ¡DEVUELVE SOLO EL NOMBRE! (Sin línea de código)
                -- Esto facilita las reglas de activación exactas
                RETURN l_unit_name;
                
            END IF;
        END LOOP;

        RETURN 'ANONYMOUS_BLOCK';
        
    EXCEPTION 
        WHEN OTHERS THEN 
            RETURN 'UNKNOWN_CONTEXT';
    END;

    -- INTERNAL ERROR LOGGER (Captura Stack automáticamente)
    PROCEDURE log_internal_error(p_msg VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_full_msg VARCHAR2(4000); 
        l_tenant   VARCHAR2(100) := g_tenant_id;
        l_trace_id VARCHAR2(64); 
        l_span_id  VARCHAR2(32); 
    BEGIN
        IF g_stack_ptr > 0 THEN
            l_trace_id := g_span_stack(g_stack_ptr).trace_id;
            l_span_id  := g_span_stack(g_stack_ptr).span_id;
        END IF;

        -- AQUÍ CAPTURAMOS EL STACK (Sustituye al SQLERRM)
        l_full_msg := SUBSTR(
            p_msg || CHR(10) || 
            'Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
            'Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 
            1, 4000
        );

        INSERT INTO plt_telemetry_errors (
            error_message, module_name, tenant_id, trace_id, span_id
        ) VALUES (
            l_full_msg, 'PLTelemetry', l_tenant, l_trace_id, l_span_id
        );
        COMMIT;
    EXCEPTION WHEN OTHERS THEN ROLLBACK;
    END;

    -- MAIN QUEUE WRITER
    PROCEDURE enqueue(p_type VARCHAR2, p_payload CLOB) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_tenant_local VARCHAR2(100) := g_tenant_id;
    BEGIN
        INSERT INTO plt_queue_writer (item_type, payload, tenant_id)
        VALUES (p_type, p_payload, l_tenant_local);
        COMMIT;
    EXCEPTION WHEN OTHERS THEN ROLLBACK; log_internal_error('Enqueue failed');
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
    EXCEPTION WHEN OTHERS THEN RETURN JSON_OBJECT_T(); 
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

    -- W3C INJECTOR
    PROCEDURE w3c_inject_context(p_traceparent VARCHAR2) IS
        l_trace_id VARCHAR2(32);
        l_span_id  VARCHAR2(16);
    BEGIN
        IF p_traceparent IS NULL OR LENGTH(p_traceparent) < 55 THEN RETURN; END IF;
        l_trace_id := SUBSTR(p_traceparent, 4, 32);
        l_span_id  := SUBSTR(p_traceparent, 37, 16);
        g_current_trace_id   := l_trace_id;
        g_external_parent_id := l_span_id;
    EXCEPTION WHEN OTHERS THEN NULL; 
    END w3c_inject_context;

    -- START SPAN
    FUNCTION start_span(
        p_operation   IN VARCHAR2,
        p_force_trace IN BOOLEAN DEFAULT FALSE
    ) RETURN VARCHAR2 IS
        l_ctx     t_span_context;
        l_op_name VARCHAR2(1000);
        l_should  BOOLEAN;
    BEGIN
        -- 1. Auto-detección
        IF p_operation IS NULL THEN l_op_name := auto_detect_context(); ELSE l_op_name := p_operation; END IF;

        -- 2. VERIFICAR ACTIVACIÓN
        IF (g_current_trace_id IS NOT NULL AND g_external_parent_id IS NOT NULL) OR p_force_trace THEN
            l_should := TRUE; 
        ELSE
            l_should := PLT_ACTIVATION_MANAGER.should_trace(l_op_name);
        END IF;

        -- GESTIÓN DEL "NO" (Span Fantasma)
        IF NOT l_should THEN
            l_ctx.span_id := 'DISABLED'; 
            g_stack_ptr := g_stack_ptr + 1;
            g_span_stack(g_stack_ptr) := l_ctx;
            RETURN NULL; 
        END IF;

        -- Lógica Normal
        IF g_session_id IS NULL THEN g_session_id := generate_hex_id(16); END IF;

        l_ctx.operation  := SUBSTR(l_op_name, 1, 900); 
        l_ctx.start_time := SYSTIMESTAMP;
        l_ctx.start_cpu  := DBMS_UTILITY.GET_CPU_TIME;
        l_ctx.span_id    := generate_hex_id(16);

        IF g_stack_ptr > 0 THEN
            l_ctx.trace_id       := g_span_stack(g_stack_ptr).trace_id;
            l_ctx.parent_span_id := g_span_stack(g_stack_ptr).span_id;
        ELSIF g_current_trace_id IS NOT NULL AND g_external_parent_id IS NOT NULL THEN
            l_ctx.trace_id       := g_current_trace_id;
            l_ctx.parent_span_id := g_external_parent_id;
            g_external_parent_id := NULL; 
        ELSE
            l_ctx.trace_id       := generate_hex_id(32);
            l_ctx.parent_span_id := NULL;
        END IF;

        g_stack_ptr := g_stack_ptr + 1;
        g_span_stack(g_stack_ptr) := l_ctx;

        DBMS_APPLICATION_INFO.SET_ACTION('SPAN:' || SUBSTR(l_ctx.operation, 1, 30));
        RETURN l_ctx.span_id;
    EXCEPTION WHEN OTHERS THEN 
        log_internal_error('start_span critical error'); -- Ya captura stack dentro
        RETURN NULL;
    END;

    -- END SPAN
    PROCEDURE end_span(
        p_status_code IN VARCHAR2 DEFAULT 'OK',
        p_status_msg  IN VARCHAR2 DEFAULT NULL
    ) IS
        l_ctx         t_span_context;
        l_json_obj    JSON_OBJECT_T;
        l_duration_ms NUMBER;
        l_end_time    TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
    BEGIN
        IF g_stack_ptr IS NULL OR g_stack_ptr = 0 THEN RETURN; END IF;

        l_ctx := g_span_stack(g_stack_ptr);
        g_span_stack.DELETE(g_stack_ptr);
        g_stack_ptr := g_stack_ptr - 1;

        IF l_ctx.span_id = 'DISABLED' THEN RETURN; END IF;

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

        IF g_stack_ptr > 0 AND g_span_stack(g_stack_ptr).span_id != 'DISABLED' THEN
            DBMS_APPLICATION_INFO.SET_ACTION('SPAN:' || SUBSTR(g_span_stack(g_stack_ptr).operation, 1, 30));
        ELSE
            DBMS_APPLICATION_INFO.SET_ACTION(NULL);
        END IF;

    EXCEPTION WHEN OTHERS THEN 
        log_internal_error('end_span error'); -- Ya captura stack dentro
    END;

    -- LOG METRIC
    PROCEDURE log_metric(
        p_name  IN VARCHAR2,
        p_value IN NUMBER,
        p_type  IN VARCHAR2, 
        p_unit  IN VARCHAR2 DEFAULT '1',
        p_attrs IN t_attributes DEFAULT CAST(NULL AS t_attributes)
    ) IS
        l_json_obj   JSON_OBJECT_T;
        l_trace_id   VARCHAR2(64);
        l_span_id    VARCHAR2(32);
        l_context    VARCHAR2(200);
        l_should_log BOOLEAN := FALSE;
    BEGIN
        l_context := auto_detect_context();

        IF g_stack_ptr > 0 THEN
            IF g_span_stack(g_stack_ptr).span_id = 'DISABLED' THEN RETURN; END IF;
            l_should_log := TRUE;
            l_trace_id   := g_span_stack(g_stack_ptr).trace_id;
            l_span_id    := g_span_stack(g_stack_ptr).span_id;
        ELSE
            l_should_log := PLT_ACTIVATION_MANAGER.should_trace(l_context);
        END IF;

        IF NOT l_should_log THEN RETURN; END IF;

        l_json_obj := JSON_OBJECT_T();
        l_json_obj.put('name', p_name);
        l_json_obj.put('value', p_value);
        l_json_obj.put('type', p_type);
        l_json_obj.put('unit', p_unit);
        l_json_obj.put('tenant_id', NVL(g_tenant_id, 'default'));
        l_json_obj.put('timestamp', iso_date(SYSTIMESTAMP));
        l_json_obj.put('code_location', l_context); 

        IF l_trace_id IS NOT NULL THEN
             l_json_obj.put('trace_id', l_trace_id);
             l_json_obj.put('span_id', l_span_id);
        END IF;

        IF p_attrs.COUNT > 0 THEN l_json_obj.put('attributes', attrs_to_json(p_attrs)); END IF;

        enqueue('METRIC', l_json_obj.to_clob());
    EXCEPTION WHEN OTHERS THEN 
        log_internal_error('log_metric error'); -- Ya captura stack dentro
    END log_metric;

    -- LOG
    PROCEDURE log(
        p_level   IN VARCHAR2,
        p_message IN VARCHAR2,
        p_attrs   IN t_attributes DEFAULT CAST(NULL AS t_attributes)
    ) IS
        l_json_obj   JSON_OBJECT_T;
        l_trace_id   VARCHAR2(64);
        l_span_id    VARCHAR2(32);
        l_context    VARCHAR2(200);
        l_should_log BOOLEAN := FALSE;
    BEGIN
        l_context := auto_detect_context();

        IF g_stack_ptr > 0 THEN
            IF g_span_stack(g_stack_ptr).span_id = 'DISABLED' THEN RETURN; END IF;
            l_should_log := TRUE;
            l_trace_id   := g_span_stack(g_stack_ptr).trace_id;
            l_span_id    := g_span_stack(g_stack_ptr).span_id;
        ELSE
            l_should_log := PLT_ACTIVATION_MANAGER.should_trace(l_context);
        END IF;

        IF NOT l_should_log THEN RETURN; END IF;

        l_json_obj := JSON_OBJECT_T();
        l_json_obj.put('severity', p_level);
        l_json_obj.put('message', p_message);
        l_json_obj.put('code_location', l_context);
        l_json_obj.put('tenant_id', g_tenant_id);
        l_json_obj.put('timestamp', iso_date(SYSTIMESTAMP));

        IF l_trace_id IS NOT NULL THEN
             l_json_obj.put('trace_id', l_trace_id);
             l_json_obj.put('span_id', l_span_id);
        END IF;

        IF p_attrs.COUNT > 0 THEN l_json_obj.put('attributes', attrs_to_json(p_attrs)); END IF;
        
        enqueue('LOG', l_json_obj.to_clob());
    EXCEPTION WHEN OTHERS THEN 
        log_internal_error('log error'); -- Ya captura stack dentro
    END;

    -- PROCESS QUEUE (CORREGIDO - Sin SQLERRM en UPDATE)
    PROCEDURE process_queue(p_batch_size NUMBER DEFAULT 50) IS
        CURSOR c_pending IS
            SELECT id, item_type, payload
            FROM plt_queue_writer
            WHERE status = 'NEW'
            ORDER BY id ASC
            FETCH FIRST p_batch_size ROWS ONLY;
        
        l_err_msg  VARCHAR2(4000); -- Variable auxiliar para el error
    BEGIN
        PLT_OTLP_BRIDGE.init(NULL, NULL, NULL); 
        log_debug('process_queue() init executed');
        FOR r IN c_pending LOOP
            BEGIN

                log_debug('process_queue() processing row id'||r.id||' type '||r.item_type);

                PLT_OTLP_BRIDGE.process_payload(r.item_type, r.payload);

                UPDATE plt_queue_writer 
                SET status = 'PROCESSED', updated_at = SYSTIMESTAMP 
                WHERE id = r.id;
                
            EXCEPTION WHEN OTHERS THEN
                -- Capturamos el stack en variable local antes de usarlo en SQL
                l_err_msg := SUBSTR(
                    'Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
                    'Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 
                    1, 4000
                );

                UPDATE plt_queue_writer 
                SET status = 'FAILED', 
                    error_message = l_err_msg, 
                    retry_count = retry_count + 1,
                    updated_at = SYSTIMESTAMP
                WHERE id = r.id;
            END;
        END LOOP;
        COMMIT;
    EXCEPTION WHEN OTHERS THEN 
        ROLLBACK; 
        log_internal_error('Process queue fatal error');
    END process_queue;

    FUNCTION is_agent_healthy RETURN BOOLEAN IS
        l_mode      VARCHAR2(20);
        l_last_beat TIMESTAMP WITH TIME ZONE;
        l_seconds   NUMBER;
        l_threshold CONSTANT NUMBER := 45; -- Sincronizado con tu monitor
    BEGIN
        BEGIN
            SELECT pulse_mode, last_heartbeat 
              INTO l_mode, l_last_beat
              FROM plt_agent_registry
             WHERE agent_id = 'PRIMARY_AGENT' 
             FETCH FIRST 1 ROWS ONLY;
             
            -- Cálculo de diferencia en segundos (robusto)
            l_seconds := EXTRACT(DAY FROM (SYSTIMESTAMP - l_last_beat)) * 86400 +
                         EXTRACT(HOUR FROM (SYSTIMESTAMP - l_last_beat)) * 3600 +
                         EXTRACT(MINUTE FROM (SYSTIMESTAMP - l_last_beat)) * 60 +
                         EXTRACT(SECOND FROM (SYSTIMESTAMP - l_last_beat));
                       
            IF l_seconds > l_threshold THEN
                -- Está muerto, Jim.
                RETURN FALSE; 
            END IF;

            IF l_mode = 'COMA' THEN
                RETURN FALSE;
            END IF;
            
            RETURN TRUE;
            
        EXCEPTION WHEN NO_DATA_FOUND THEN
            -- Si nunca ha habido agente, asumimos que estamos en modo 'SOLO PLSQL' o arranque
            RETURN FALSE; -- Cambiado a FALSE por seguridad: si no hay agente, que procese el PLSQL.
        END;
    END;


END PLTelemetry;
/