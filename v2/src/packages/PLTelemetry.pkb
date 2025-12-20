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

    
    g_current_trace_id   VARCHAR2(32); -- Para guardar el TraceID inyectado
    g_external_parent_id VARCHAR2(16); -- Para guardar el SpanID inyectado (el padre externo)

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
        l_ctx     t_span_context;
        l_op_name VARCHAR2(1000);
    BEGIN
        -- 1. AUTO-DETECCIÓN DE NOMBRE (EL DETECTIVE)
        -- Si viene NULL, miramos la pila de llamadas para saber quién somos
        IF p_operation IS NULL THEN
            l_op_name := auto_detect_context();
        ELSE
            l_op_name := p_operation;
        END IF;

        -- 2. INICIALIZACIÓN DE SESIÓN (Si es la primera vez)
        IF g_session_id IS NULL THEN g_session_id := generate_hex_id(16); END IF;

        -- 3. PREPARACIÓN DEL CONTEXTO BÁSICO
        l_ctx.operation  := SUBSTR(l_op_name, 1, 900); 
        l_ctx.start_time := SYSTIMESTAMP;
        l_ctx.start_cpu  := DBMS_UTILITY.GET_CPU_TIME;
        
        -- Generamos SIEMPRE un nuevo SpanID para esta operación concreta
        l_ctx.span_id    := generate_hex_id(16);

        -- 4. LÓGICA DE HERENCIA (EL CEREBRO DE LA TRAZA)
        IF g_stack_ptr > 0 THEN
            -- CASO A: Estamos dentro de una llamada PL/SQL anidada (Hijo interno)
            -- Heredamos el TraceID de la pila actual
            l_ctx.trace_id       := g_span_stack(g_stack_ptr).trace_id;
            -- Nuestro padre es el span que está en la cima de la pila
            l_ctx.parent_span_id := g_span_stack(g_stack_ptr).span_id;

        ELSIF g_current_trace_id IS NOT NULL AND g_external_parent_id IS NOT NULL THEN
            -- CASO B: Venimos inyectados desde fuera (Node.js/Java -> W3C)
            -- Adoptamos el TraceID que nos pasaron
            l_ctx.trace_id       := g_current_trace_id;
            -- Nuestro padre es el SpanID que nos pasaron (el de Node.js)
            l_ctx.parent_span_id := g_external_parent_id;

            -- IMPORTANTE: "Consumimos" el padre externo. 
            -- Las siguientes llamadas dentro de este PL/SQL caerán en el CASO A.
            g_external_parent_id := NULL; 

        ELSE
            -- CASO C: Traza Raíz (Nadie nos llamó, somos el origen del universo)
            l_ctx.trace_id       := generate_hex_id(32); -- Generamos traza nueva
            l_ctx.parent_span_id := NULL;                -- No tenemos padre
        END IF;

        -- 5. GUARDAR EN LA PILA (STACK PUSH)
        g_stack_ptr := g_stack_ptr + 1;
        g_span_stack(g_stack_ptr) := l_ctx;

        -- 6. VISIBILIDAD (Para que los DBAs lo vean en V$SESSION)
        DBMS_APPLICATION_INFO.SET_ACTION('SPAN:' || SUBSTR(l_ctx.operation, 1, 30));

        RETURN l_ctx.span_id;
    EXCEPTION
        WHEN OTHERS THEN
            -- Usamos SQLERRM aquí porque si start_span falla, log_internal_error podría fallar también
            -- si intenta leer el stack. Mejor ser defensivos.
            log_internal_error('start_span critical error: ' || SQLERRM);
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
        l_context  VARCHAR2(200); -- [NUEVO] Variable para el detective
    BEGIN
        -- [NUEVO] 1. Detectamos quién nos llama
        l_context := auto_detect_context();

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
        
        -- [NUEVO] 2. Lo añadimos al JSON
        l_json_obj.put('code_location', l_context);

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
        l_context  VARCHAR2(200); -- Para guardar el contexto detectado
    BEGIN
        -- [MAGIA] Detectamos dónde estamos
        l_context := auto_detect_context();

        IF g_stack_ptr > 0 THEN
            l_trace_id := g_span_stack(g_stack_ptr).trace_id;
            l_span_id  := g_span_stack(g_stack_ptr).span_id;
        END IF;

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

        IF p_attrs.COUNT > 0 THEN
            l_json_obj.put('attributes', attrs_to_json(p_attrs));
        END IF;
        
        enqueue('LOG', l_json_obj.to_clob());
    EXCEPTION
        WHEN OTHERS THEN
            log_internal_error('log error');
    END;

    -- =========================================================================
    -- PROCESADOR DE COLA (Versión Lite - Opción B)
    -- =========================================================================
    PROCEDURE process_queue(p_batch_size NUMBER DEFAULT 50) IS
        CURSOR c_pending IS
            SELECT id, item_type, payload
            FROM plt_queue
            WHERE status = 'NEW'
            ORDER BY id ASC
            FETCH FIRST p_batch_size ROWS ONLY;
            
        l_endpoint VARCHAR2(100) := 'http://otel-collector:4318'; -- Interno Docker
    BEGIN
        -- Inicializar puente una vez por lote
        -- Nota: En la versión simple asumimos mismo servicio. 
        -- Si tienes multi-tenant real, esto iría dentro del loop.
        PLT_OTLP_BRIDGE.init(l_endpoint, 'oracle-db-prod', 'prod');

        FOR r IN c_pending LOOP
            BEGIN
                -- Enviar al Collector
                PLT_OTLP_BRIDGE.process_payload(r.item_type, r.payload);

                -- Marcar como procesado (borrado lógico)
                UPDATE plt_queue 
                SET status = 'PROCESSED', 
                    updated_at = SYSTIMESTAMP 
                WHERE id = r.id;
                
            EXCEPTION WHEN OTHERS THEN
                -- Si falla, marcamos error y aumentamos retry
                UPDATE plt_queue 
                SET status = 'FAILED', 
                    error_message = SUBSTR('Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
            'Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 
            1, 4000
        ), 
                    retry_count = retry_count + 1,
                    updated_at = SYSTIMESTAMP
                WHERE id = r.id;
            END;
        END LOOP;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_internal_error('Process queue fatal error');
    END process_queue;

    -- =========================================================================
    -- [NUEVO] AUTO-DETECCIÓN DE CONTEXTO
    -- =========================================================================
    FUNCTION auto_detect_context RETURN VARCHAR2 IS
        l_stack       VARCHAR2(4000);
        l_line        VARCHAR2(4000);
        l_handle      VARCHAR2(100);
        l_linenum     VARCHAR2(100);
        l_obj_name    VARCHAR2(200);
        l_depth       PLS_INTEGER := 1;
        l_found       BOOLEAN := FALSE;
    BEGIN
        -- Obtenemos la pila completa
        l_stack := DBMS_UTILITY.FORMAT_CALL_STACK;
        
        -- Recorremos línea a línea (formato standard Oracle: Handle | Line | Object)
        LOOP
            -- Extraemos la línea número 'l_depth'
            l_line := REGEXP_SUBSTR(l_stack, '^.*$', 1, l_depth, 'm');
            EXIT WHEN l_line IS NULL;
            
            -- Buscamos el nombre del objeto (última columna, ignorando espacios)
            -- Ojo: El formato suele ser: hex_addr  line_num  object_name
            l_obj_name := REGEXP_SUBSTR(l_line, '[^ ]+$');
            
            -- CRITERIO DE FILTRADO:
            -- 1. Ignoramos cabeceras (contienen 'name' o 'object')
            -- 2. Ignoramos al propio paquete PLTELEMETRY
            -- 3. Ignoramos bloques anónimos si queremos (opcional)
            IF l_obj_name IS NOT NULL 
               AND UPPER(l_obj_name) NOT LIKE '%PLTELEMETRY%' 
               AND UPPER(l_line) NOT LIKE '%OBJECT HANDLE%' -- Cabecera
            THEN
                l_found := TRUE;
                EXIT; -- ¡Lo tenemos!
            END IF;
            
            l_depth := l_depth + 1;
        END LOOP;
        
        IF l_found THEN
            RETURN l_obj_name;
        ELSE
            RETURN 'ANONYMOUS_BLOCK';
        END IF;
    EXCEPTION 
        WHEN OTHERS THEN RETURN 'UNKNOWN_CONTEXT';
    END;

    -- =========================================================================
    -- W3C CONTEXT INJECTOR (Propagación Distribuida)
    -- Formato esperado: 00-{trace_id}-{span_id}-{flags}
    -- Ejemplo: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
    -- =========================================================================
    PROCEDURE w3c_inject_context(p_traceparent VARCHAR2) IS
        l_trace_id VARCHAR2(32);
        l_span_id  VARCHAR2(16);
    BEGIN
        IF p_traceparent IS NULL OR LENGTH(p_traceparent) < 55 THEN
            RETURN; 
        END IF;

        -- 1. Parseamos
        l_trace_id := SUBSTR(p_traceparent, 4, 32);
        l_span_id  := SUBSTR(p_traceparent, 37, 16);

        -- 2. Asignamos a las variables EXACTAS que start_span va a leer
        g_current_trace_id   := l_trace_id;
        g_external_parent_id := l_span_id; -- <--- ¡Aquí estaba el fallo antes!
        
        -- Debug visual para ti (opcional)
        DBMS_OUTPUT.PUT_LINE('💉 Inyectado: Trace=' || l_trace_id || ', Parent=' || l_span_id);

    EXCEPTION WHEN OTHERS THEN NULL; 
    END w3c_inject_context;

END PLTelemetry;
/