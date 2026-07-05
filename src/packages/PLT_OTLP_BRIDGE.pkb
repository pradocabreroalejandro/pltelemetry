SET DEFINE OFF;

CREATE OR REPLACE PACKAGE BODY PLT_OTLP_BRIDGE AS

    -- =========================================================================
    -- INTERNAL STATE
    -- =========================================================================
    -- We no longer store persistent package variables for config, 
    -- we trust PLT_CONFIGURATION's RESULT CACHE.
    g_cached_resource JSON_OBJECT_T;
    
    -- Overrides internal log
    g_debug_override  BOOLEAN := NULL; 

    -- =========================================================================
    -- PRIVATE UTILITIES
    -- =========================================================================

    FUNCTION is_debug_enabled RETURN BOOLEAN IS
    BEGIN
        -- Priority: 1. Manual override (set_debug), 2. DB Config
        IF g_debug_override IS NOT NULL THEN RETURN g_debug_override; END IF;
        RETURN PLT_CONFIGURATION.get_bool_param('GENERAL', 'DEBUG_MODE', FALSE);
    END;

    PROCEDURE log_debug(p_msg VARCHAR2) IS
    BEGIN
        IF is_debug_enabled() THEN 
            DBMS_OUTPUT.PUT_LINE('[BRIDGE] ' || p_msg); 
        END IF;
    END;

    FUNCTION random_hex(p_length NUMBER) RETURN VARCHAR2 IS
        l_hex VARCHAR2(100);
    BEGIN
        SELECT LISTAGG(TO_CHAR(ROUND(DBMS_RANDOM.VALUE(0, 15)), 'FMX'), '') 
               WITHIN GROUP (ORDER BY level)
        INTO l_hex
        FROM dual 
        CONNECT BY level <= p_length;
        RETURN SUBSTR(l_hex, 1, p_length);
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
        RETURN TO_CHAR(TRUNC(l_seconds)) || TO_CHAR(EXTRACT(SECOND FROM l_diff) - TRUNC(EXTRACT(SECOND FROM l_diff)), 'FM.000000000') * 1000000000;
    END;

    FUNCTION to_unix_nano(p_iso_ts VARCHAR2) RETURN VARCHAR2 IS
        l_ts TIMESTAMP WITH TIME ZONE;
    BEGIN
        IF p_iso_ts IS NULL THEN l_ts := SYSTIMESTAMP; 
        ELSE 
            BEGIN l_ts := TO_TIMESTAMP_TZ(p_iso_ts, 'YYYY-MM-DD"T"HH24:MI:SS.FF6"Z"');
            EXCEPTION WHEN OTHERS THEN l_ts := SYSTIMESTAMP; END;
        END IF;
        RETURN get_timestamp_nano(l_ts);
    END;

    -- =========================================================================
    -- RESOURCE BUILDER
    -- =========================================================================
    FUNCTION get_resource(p_tenant_id VARCHAR2) RETURN JSON_OBJECT_T IS
        l_res JSON_OBJECT_T;
        l_attrs JSON_ARRAY_T;
        
        -- We read the configuration INSIDE the function. Thanks to Result Cache it's free.
        l_svc_name VARCHAR2(100) := PLT_CONFIGURATION.get_param('OTLP', 'SERVICE_NAME', 'oracle-db');
        l_env      VARCHAR2(100) := PLT_CONFIGURATION.get_param('OTLP', 'ENVIRONMENT', 'prod');
        
        PROCEDURE add_attr(k VARCHAR2, v VARCHAR2) IS
            l_kv JSON_OBJECT_T := JSON_OBJECT_T();
            l_val JSON_OBJECT_T := JSON_OBJECT_T();
        BEGIN
            l_val.put('stringValue', v);
            l_kv.put('key', k); l_kv.put('value', l_val);
            l_attrs.append(l_kv);
        END;
    BEGIN
        -- Simple in-memory package cache for the base object, if we don't want to rebuild it always
        -- BUT since config can change, better to rebuild it quickly.
        l_res := JSON_OBJECT_T();
        l_attrs := JSON_ARRAY_T();

        add_attr('service.name', l_svc_name);
        add_attr('deployment.environment', l_env);
        add_attr('telemetry.sdk.language', 'plsql');
        add_attr('db.instance', SYS_CONTEXT('USERENV', 'INSTANCE_NAME'));
        add_attr('tenant.id', NVL(p_tenant_id, 'default'));

        l_res.put('attributes', l_attrs);
        RETURN l_res;
    END;

    -- =========================================================================
    -- HTTP SENDER (Now reads the URL from Config)
    -- =========================================================================
    PROCEDURE send_http(p_path VARCHAR2, p_payload CLOB) IS
        l_req  UTL_HTTP.REQ;
        l_res  UTL_HTTP.RESP;
        
        -- READ URL FROM CONFIG
        l_base_url VARCHAR2(500) := PLT_CONFIGURATION.get_param('OTLP', 'ENDPOINT_URL', 'http://localhost:4318');
        l_url      VARCHAR2(1000) := RTRIM(l_base_url, '/') || p_path;
        
        l_len  NUMBER := DBMS_LOB.GETLENGTH(p_payload);
        l_buff VARCHAR2(32000);
        l_off  NUMBER := 1;
        l_amt  NUMBER := 32000;
    BEGIN
        UTL_HTTP.SET_TRANSFER_TIMEOUT(PLT_CONFIGURATION.get_num_param('OTLP', 'TIMEOUT_MS', 5000) / 1000);
        
        l_req := UTL_HTTP.BEGIN_REQUEST(l_url, 'POST', 'HTTP/1.1');
        UTL_HTTP.SET_HEADER(l_req, 'Content-Type', 'application/json');
        UTL_HTTP.SET_HEADER(l_req, 'Content-Length', l_len);
        
        WHILE l_off <= l_len LOOP
            DBMS_LOB.READ(p_payload, l_amt, l_off, l_buff);
            UTL_HTTP.WRITE_TEXT(l_req, l_buff);
            l_off := l_off + l_amt;
        END LOOP;

        l_res := UTL_HTTP.GET_RESPONSE(l_req);
        l_buff := '';
        BEGIN LOOP
            DECLARE l_chunk VARCHAR2(32000);
            BEGIN UTL_HTTP.READ_TEXT(l_res, l_chunk, 32000); l_buff := l_buff || l_chunk; END;
        END LOOP; EXCEPTION WHEN UTL_HTTP.END_OF_BODY THEN NULL; END;
        UTL_HTTP.END_RESPONSE(l_res);

        DBMS_OUTPUT.PUT_LINE('[send_http] ' || p_path || ' status=' || l_res.status_code ||
            ' body=' || SUBSTR(l_buff, 1, 400));

        -- A 4xx/5xx means the collector rejected the WHOLE request (e.g. a malformed
        -- metric). UTL_HTTP only raises on NETWORK errors, NOT on HTTP error status,
        -- so without this check a 400 is silently swallowed and callers mark items
        -- PROCESSED even though nothing was ingested. Raise so process_queue can
        -- fall back to per-item sends and mark the offending item FAILED.
        IF l_res.status_code NOT BETWEEN 200 AND 299 THEN
            RAISE_APPLICATION_ERROR(-20003,
                'HTTP ' || l_res.status_code || ' from ' || l_url || ': ' || SUBSTR(l_buff, 1, 500));
        END IF;
    EXCEPTION WHEN OTHERS THEN
        BEGIN UTL_HTTP.END_RESPONSE(l_res); EXCEPTION WHEN OTHERS THEN NULL; END;
        IF SQLCODE = -20003 THEN
            RAISE;  -- our status-code error: propagate the clean message as-is
        ELSE
            RAISE_APPLICATION_ERROR(-20002, 'HTTP Fail to ' || l_url || ': ' ||
                SUBSTR('Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) ||
                       'Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000));
        END IF;
    END;

    -- =========================================================================
    -- TELEMETRY SENDERS (No logical changes, just use the functions above)
    -- =========================================================================

    -- Builds a single OTLP metric object (name + sum/gauge + one dataPoint) from a
    -- metric payload. Shared by send_metric (1-per-POST) and send_metrics_batch
    -- (N-per-POST). The dataPoint keeps the payload's emission timestamp
    -- (to_unix_nano(payload.timestamp)) — this is intentional OTel semantics.
    FUNCTION build_metric_obj(p_src JSON_OBJECT_T) RETURN JSON_OBJECT_T IS
        l_m_obj     JSON_OBJECT_T := JSON_OBJECT_T();
        l_data      JSON_OBJECT_T := JSON_OBJECT_T();
        l_pts       JSON_ARRAY_T  := JSON_ARRAY_T();
        l_pt        JSON_OBJECT_T := JSON_OBJECT_T();
        l_attrs     JSON_ARRAY_T  := JSON_ARRAY_T();

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
        -- A NULL value (e.g. oracle_rman_backup_status when there is no recent
        -- backup) cannot be represented in OTLP — asDouble:null / asInt:null are
        -- rejected by the collector with HTTP 400 "ReadUint64: unsupported value
        -- type", which drops the whole request. Per the project's "prefer losing
        -- metrics over faking them" principle, skip the metric entirely (return
        -- NULL) rather than coerce to 0. Callers must check for NULL and not
        -- append it to the OTLP arrays.
        IF l_val IS NULL THEN
            RETURN NULL;
        END IF;

        l_pt.put('timeUnixNano', to_unix_nano(p_src.get_string('timestamp')));
        -- OTLP asInt is a signed 64-bit INTEGER; the collector rejects a fractional
        -- value with HTTP 400 "assertInteger: can not decode float as int" — which
        -- drops the WHOLE /v1/metrics request, not just one metric. Producer counters
        -- are often fractional (e.g. 732500.78 seconds), so use asInt only when the
        -- value is a whole number within int64 range; otherwise asDouble. Gauges are
        -- always asDouble (handles both integer and fractional).
        IF l_type = 'COUNTER' AND l_val = TRUNC(l_val) AND ABS(l_val) < 9223372036854775807 THEN
            l_pt.put('asInt', l_val);
        ELSE
            l_pt.put('asDouble', l_val);
        END IF;

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
        RETURN l_m_obj;
    END;

    PROCEDURE send_metric(p_src JSON_OBJECT_T) IS
        l_otlp_root JSON_OBJECT_T := JSON_OBJECT_T();
        l_rm        JSON_ARRAY_T := JSON_ARRAY_T();
        l_rm_obj    JSON_OBJECT_T := JSON_OBJECT_T();
        l_sm        JSON_ARRAY_T := JSON_ARRAY_T();
        l_sm_obj    JSON_OBJECT_T := JSON_OBJECT_T();
        l_metrics   JSON_ARRAY_T := JSON_ARRAY_T();
        l_m         JSON_OBJECT_T;
    BEGIN
        l_m := build_metric_obj(p_src);
        IF l_m IS NULL THEN
            RETURN;  -- NULL-valued metric (e.g. no backup): skip, don't send
        END IF;
        l_metrics.append(l_m);
        l_sm_obj.put('metrics', l_metrics);
        l_sm.append(l_sm_obj);
        l_rm_obj.put('resource', get_resource(p_src.get_string('tenant_id')));
        l_rm_obj.put('scopeMetrics', l_sm);
        l_rm.append(l_rm_obj);
        l_otlp_root.put('resourceMetrics', l_rm);

        send_http('/v1/metrics', l_otlp_root.to_clob());
    END;

    -- Sends N metric payloads in a SINGLE /v1/metrics POST. Metrics are grouped by
    -- tenant_id so each tenant gets its own resourceMetrics block (resource attrs,
    -- incl. tenant.id, come from get_resource). Used by the failover path to drain
    -- the queue without 1-POST-per-metric overhead.
    PROCEDURE send_metrics_batch(p_metrics SYS.JSON_ARRAY_T) IS
        l_otlp_root JSON_OBJECT_T := JSON_OBJECT_T();
        l_rm        JSON_ARRAY_T  := JSON_ARRAY_T();

        TYPE t_metrics_by_tenant IS TABLE OF JSON_ARRAY_T INDEX BY VARCHAR2(100);
        l_by_tenant t_metrics_by_tenant;

        l_src       JSON_OBJECT_T;
        l_tenant    VARCHAR2(100);
        l_key       VARCHAR2(100);
        l_size      NUMBER;
        l_rm_obj    JSON_OBJECT_T;
        l_sm        JSON_ARRAY_T;
        l_sm_obj    JSON_OBJECT_T;
        l_m         JSON_OBJECT_T;
        l_skipped   NUMBER := 0;
    BEGIN
        l_size := p_metrics.get_size();
        FOR i IN 0..l_size-1 LOOP
            l_src := TREAT(p_metrics.get(i) AS JSON_OBJECT_T);
            l_m := build_metric_obj(l_src);
            IF l_m IS NULL THEN
                l_skipped := l_skipped + 1;  -- NULL-valued metric: skip, don't poison the batch
                CONTINUE;
            END IF;
            l_tenant := NVL(l_src.get_string('tenant_id'), 'default');
            IF NOT l_by_tenant.exists(l_tenant) THEN
                l_by_tenant(l_tenant) := JSON_ARRAY_T();
            END IF;
            l_by_tenant(l_tenant).append(l_m);
        END LOOP;
        -- If every metric in the batch was NULL-valued, there is nothing to send.
        -- Don't POST an empty resourceMetrics array (the collector would 400 on
        -- an empty request); just return.
        IF l_skipped = l_size THEN
            RETURN;
        END IF;

        l_key := l_by_tenant.first;
        WHILE l_key IS NOT NULL LOOP
            l_sm_obj := JSON_OBJECT_T();
            l_sm_obj.put('metrics', l_by_tenant(l_key));
            l_sm := JSON_ARRAY_T();
            l_sm.append(l_sm_obj);
            l_rm_obj := JSON_OBJECT_T();
            l_rm_obj.put('resource', get_resource(l_key));
            l_rm_obj.put('scopeMetrics', l_sm);
            l_rm.append(l_rm_obj);
            l_key := l_by_tenant.next(l_key);
        END LOOP;

        l_otlp_root.put('resourceMetrics', l_rm);
        send_http('/v1/metrics', l_otlp_root.to_clob());
    EXCEPTION WHEN OTHERS THEN
        log_debug('send_metrics_batch error: ' ||
            SUBSTR('Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) ||
                   'Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000));
        RAISE; -- Re-raise so process_queue can fall back to per-item send
    END;

    PROCEDURE send_trace(p_data JSON_OBJECT_T) IS
        l_otlp_payload   JSON_OBJECT_T := JSON_OBJECT_T();
        l_resource_spans JSON_ARRAY_T := JSON_ARRAY_T();
        l_scope_spans    JSON_ARRAY_T := JSON_ARRAY_T();
        l_spans          JSON_ARRAY_T := JSON_ARRAY_T();
        l_span           JSON_OBJECT_T := JSON_OBJECT_T();
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
        -- Use the REAL span timing emitted by PLTelemetry (ISO-8601 UTC "Z").
        -- to_unix_nano falls back to SYSTIMESTAMP if the field is missing/unparseable.
        l_start_time := to_unix_nano(p_data.get_String('start_time'));
        l_end_time := to_unix_nano(p_data.get_String('end_time'));

        l_span.put('traceId', l_trace_id);
        l_span.put('spanId', l_span_id);
        IF p_data.has('parent_span_id') THEN
            l_span.put('parentSpanId', p_data.get_String('parent_span_id'));
        END IF;
        l_span.put('name', NVL(p_data.get_String('operation_name'), 'oracle-db-operation')); -- Fixed key
        l_span.put('kind', 1); 
        l_span.put('startTimeUnixNano', l_start_time);
        l_span.put('endTimeUnixNano', l_end_time);
        
        l_spans.append(l_span);
        
        l_scope.put('name', 'oracle.plsql.bridge');
        l_scope.put('version', '2.0.0');
        l_scope_obj.put('scope', l_scope);
        l_scope_obj.put('spans', l_spans);
        l_scope_spans.append(l_scope_obj);
        
        l_res_span_obj.put('resource', get_resource(p_data.get_string('tenant_id')));
        l_res_span_obj.put('scopeSpans', l_scope_spans);
        l_resource_spans.append(l_res_span_obj);
        
        l_otlp_payload.put('resourceSpans', l_resource_spans);

        send_http('/v1/traces', l_otlp_payload.to_clob);
        
        IF is_debug_enabled() THEN log_debug('Trace sent: ' || l_trace_id); END IF;
    END;

    PROCEDURE send_log(p_data JSON_OBJECT_T) IS
        l_otlp_payload  JSON_OBJECT_T := JSON_OBJECT_T();
        l_resource_logs JSON_ARRAY_T := JSON_ARRAY_T();
        l_scope_logs    JSON_ARRAY_T := JSON_ARRAY_T();
        l_log_records   JSON_ARRAY_T := JSON_ARRAY_T();
        l_log           JSON_OBJECT_T := JSON_OBJECT_T();
        l_body          JSON_OBJECT_T := JSON_OBJECT_T();
        l_scope_log_obj JSON_OBJECT_T := JSON_OBJECT_T();
        l_res_log_obj   JSON_OBJECT_T := JSON_OBJECT_T();
    BEGIN
        -- Use the emission timestamp from the payload, not the processing time.
        l_log.put('timeUnixNano', to_unix_nano(p_data.get_String('timestamp')));
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
        
        IF is_debug_enabled() THEN log_debug('Log sent.'); END IF;
    END;

    -- =========================================================================
    -- PUBLIC INTERFACE
    -- =========================================================================

    -- Init is now "Legacy" or for temporary overrides, but it's not mandatory to call it
    -- to configure the URL, since it's read from the table.
    PROCEDURE init(
        p_otlp_endpoint VARCHAR2, 
        p_service_name  VARCHAR2 DEFAULT 'oracle-db',
        p_environment   VARCHAR2 DEFAULT 'production'
    ) IS
    BEGIN
        -- Optional: You could update the config table here if you wanted
        -- Or simply use these values to override the current session.
        -- For simplicity, and following your desire for "no hardcode", we'll ignore
        -- the arguments and log a warning if someone tries to use them.
        log_debug('WARN: init() parameters are ignored. Using PLT_SYS_CONFIG table values.');
    EXCEPTION
        WHEN OTHERS THEN log_debug('init fatal error '|| 
            SUBSTR('Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
                   'Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000));
    END;

    PROCEDURE set_debug(p_enabled BOOLEAN) IS 
    BEGIN 
        g_debug_override := p_enabled; 
    END;

    PROCEDURE process_payload(p_item_type VARCHAR2, p_json CLOB) IS
        l_obj JSON_OBJECT_T;
    BEGIN
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
            log_debug('Error processing payload: ' || 
                SUBSTR('Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
                       'Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000));
            RAISE; -- Re-raise so PLTelemetry marks it as FAILED
    END;

    PROCEDURE run_failover_processing IS
        l_is_alive BOOLEAN;
        l_batch_size NUMBER := 500;
    BEGIN
        l_is_alive := pltelemetry.is_agent_healthy();

        IF l_is_alive THEN
            RETURN;
        ELSE
            -- If we are in failover, maybe force debug on?
            log_debug('FAILOVER: Processing queue via PL/SQL Bridge');
            PLTelemetry.process_queue(p_batch_size => l_batch_size);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        PLTelemetry.log('ERROR', 'Failure in Failover: ' || 
            SUBSTR('Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK || CHR(10) || 
                   'Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000));
    END;

END PLT_OTLP_BRIDGE;
/
