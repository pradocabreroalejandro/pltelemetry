CREATE OR REPLACE PACKAGE BODY PLT_OTLP_BRIDGE
AS
    /**
     * PLT_OTLP_BRIDGE - Oracle 12c+ Native JSON Edition v2.0.0
     * Breaking changes: Complete rewrite using native JSON objects only
     * Optimized for Grafana standard dashboards and enterprise deployments
     */

    --------------------------------------------------------------------------
    -- PRIVATE VARIABLES (ENCAPSULATED)
    --------------------------------------------------------------------------
    
    g_traces_endpoint         VARCHAR2(500);
    g_metrics_endpoint        VARCHAR2(500);
    g_logs_endpoint           VARCHAR2(500);
    
    g_service_name            VARCHAR2(100) := 'oracle-plsql';
    g_service_version         VARCHAR2(50) := '1.0.0';
    g_deployment_environment  VARCHAR2(50) := 'unknown';
    g_service_instance        VARCHAR2(200);
    g_tenant_id               VARCHAR2(100);
    g_tenant_name             VARCHAR2(255);
    
    g_timeout                 NUMBER := C_DEFAULT_TIMEOUT;
    g_debug_mode              BOOLEAN := FALSE;
    
    -- Metric type mappings for Grafana dashboard compatibility
    TYPE t_metric_mappings IS TABLE OF VARCHAR2(20) INDEX BY VARCHAR2(100);
    g_metric_type_mappings    t_metric_mappings;

    --------------------------------------------------------------------------
    -- CENTRALIZED ERROR HANDLING
    --------------------------------------------------------------------------
    
    PROCEDURE log_error_internal(
        p_operation VARCHAR2,
        p_error_message VARCHAR2,
        p_context VARCHAR2 DEFAULT NULL
    )
    IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_error_msg VARCHAR2(4000);
    BEGIN
        l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
        
        INSERT INTO plt_telemetry_errors (
            error_time,
            error_message,
            error_stack,
            module_name
        ) VALUES (
            SYSTIMESTAMP,
            SUBSTR('OTLP Bridge [' || p_operation || ']: ' || p_error_message, 1, 4000),
            l_error_msg,
            'PLT_OTLP_BRIDGE'
        );
        
        COMMIT;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('ERROR [' || p_operation || ']: ' || p_error_message);
            IF p_context IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE('Context: ' || SUBSTR(p_context, 1, 200));
            END IF;
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Never let error logging break the bridge
    END log_error_internal;

    --------------------------------------------------------------------------
    -- JSON UTILITIES (ORACLE 12C+ NATIVE ONLY)
    --------------------------------------------------------------------------
    
    FUNCTION get_json_value(p_json VARCHAR2, p_key VARCHAR2) RETURN VARCHAR2
    IS
    BEGIN
        RETURN JSON_VALUE(p_json, '$.' || p_key);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END get_json_value;
    
    FUNCTION get_json_object(p_json VARCHAR2, p_key VARCHAR2) RETURN VARCHAR2
    IS
    BEGIN
        RETURN JSON_QUERY(p_json, '$.' || p_key);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END get_json_object;

    FUNCTION escape_json_string(p_input VARCHAR2) RETURN VARCHAR2
    IS
        l_output VARCHAR2(4000);
    BEGIN
        IF p_input IS NULL THEN
            RETURN NULL;
        END IF;
        
        l_output := p_input;
        l_output := REPLACE(l_output, '\', '\\');
        l_output := REPLACE(l_output, '"', '\"');
        l_output := REPLACE(l_output, CHR(10), '\n');
        l_output := REPLACE(l_output, CHR(13), '\r');
        l_output := REPLACE(l_output, CHR(9), '\t');
        
        -- Truncate if too long for Grafana display
        IF LENGTH(l_output) > 3900 THEN
            l_output := SUBSTR(l_output, 1, 3900) || '...[TRUNCATED]';
        END IF;
        
        RETURN l_output;
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN REPLACE(REPLACE(NVL(p_input, ''), '"', '\"'), CHR(10), ' ');
    END escape_json_string;

    --------------------------------------------------------------------------
    -- OTLP CONVERSION FUNCTIONS
    --------------------------------------------------------------------------
    
    FUNCTION to_unix_nano(p_timestamp VARCHAR2) RETURN VARCHAR2
    IS
        l_ts TIMESTAMP WITH TIME ZONE;
        l_unix_epoch TIMESTAMP WITH TIME ZONE := TIMESTAMP '1970-01-01 00:00:00 +00:00';
        l_interval INTERVAL DAY(9) TO SECOND(9);
        l_total_seconds NUMBER;
        l_nanoseconds NUMBER;
        l_result VARCHAR2(30);
    BEGIN
        -- Handle different timestamp formats
        BEGIN
            l_ts := TO_TIMESTAMP_TZ(p_timestamp, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZH:TZM');
        EXCEPTION
            WHEN OTHERS THEN
                BEGIN
                    l_ts := TO_TIMESTAMP_TZ(p_timestamp, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"');
                EXCEPTION
                    WHEN OTHERS THEN
                        l_ts := SYSTIMESTAMP;
                END;
        END;
        
        -- Calculate interval from Unix epoch
        l_interval := l_ts - l_unix_epoch;
        
        -- Extract total seconds more safely
        l_total_seconds := EXTRACT(DAY FROM l_interval) * 86400 +
                          EXTRACT(HOUR FROM l_interval) * 3600 +
                          EXTRACT(MINUTE FROM l_interval) * 60 +
                          EXTRACT(SECOND FROM l_interval);
        
        -- Convert to nanoseconds using safer arithmetic
        -- Split the calculation to avoid NUMBER overflow
        l_nanoseconds := l_total_seconds * 1000000000;
        
        -- Format without scientific notation and ensure it's a clean integer
        l_result := LTRIM(TO_CHAR(l_nanoseconds, '9999999999999999999999'));
        
        -- Validate result is numeric and reasonable length (Unix nano should be ~19 digits)
        IF l_result IS NULL OR LENGTH(l_result) > 20 OR LENGTH(l_result) < 10 THEN
            -- Fallback calculation using SYSDATE for better compatibility
            l_total_seconds := (SYSDATE - DATE '1970-01-01') * 86400;
            l_result := LTRIM(TO_CHAR(l_total_seconds * 1000000000, '9999999999999999999999'));
        END IF;
        
        -- Final validation - ensure no spaces or weird characters
        l_result := REPLACE(REPLACE(l_result, ' ', ''), CHR(9), '');
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Timestamp conversion: ' || p_timestamp || ' -> ' || l_result);
        END IF;
        
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Ultra-safe fallback using current time and simple math
            l_total_seconds := (SYSDATE - DATE '1970-01-01') * 86400;
            l_result := LTRIM(TO_CHAR(TRUNC(l_total_seconds) * 1000000000, '9999999999999999999999'));
            
            IF g_debug_mode THEN
                DBMS_OUTPUT.PUT_LINE('Timestamp fallback used: ' || l_result);
            END IF;
            
            RETURN NVL(l_result, '1640995200000000000'); -- Jan 1, 2022 as ultimate fallback
    END to_unix_nano;
    
    FUNCTION convert_attributes_to_otlp(p_attrs_json VARCHAR2) RETURN CLOB
    IS
        l_result CLOB;
        l_json_obj JSON_OBJECT_T;
        l_keys JSON_KEY_LIST;
        l_attrs_array JSON_ARRAY_T;
        l_attr_obj JSON_OBJECT_T;
        l_value_obj JSON_OBJECT_T;
        l_key VARCHAR2(255);
        l_value VARCHAR2(4000);
    BEGIN
        DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
        
        IF p_attrs_json IS NULL OR LENGTH(p_attrs_json) < 3 THEN
            l_result := TO_CLOB('[]');
            RETURN l_result;
        END IF;

        -- Parse using native JSON
        l_json_obj := JSON_OBJECT_T.parse(p_attrs_json);
        l_keys := l_json_obj.get_keys();
        l_attrs_array := JSON_ARRAY_T();
        
        -- Convert each attribute to OTLP format
        FOR i IN 1 .. l_keys.COUNT LOOP
            l_key := l_keys(i);
            l_value := l_json_obj.get_string(l_key);
            
            -- Create OTLP attribute object
            l_attr_obj := JSON_OBJECT_T();
            l_value_obj := JSON_OBJECT_T();
            
            l_attr_obj.put('key', l_key);
            l_value_obj.put('stringValue', NVL(l_value, ''));
            l_attr_obj.put('value', l_value_obj);
            
            l_attrs_array.append(l_attr_obj);
        END LOOP;

        l_result := l_attrs_array.to_clob();
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            IF DBMS_LOB.ISTEMPORARY(l_result) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_result);
            END IF;
            
            log_error_internal('convert_attributes_to_otlp', 
                             'Attribute conversion failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            
            DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
            l_result := TO_CLOB('[]');
            RETURN l_result;
    END convert_attributes_to_otlp;
    
    FUNCTION convert_events_to_otlp(p_events_json VARCHAR2) RETURN CLOB
    IS
        l_result CLOB;
        l_events_array JSON_ARRAY_T;
        l_otlp_events JSON_ARRAY_T;
        l_event_obj JSON_OBJECT_T;
        l_otlp_event JSON_OBJECT_T;
        l_event_name VARCHAR2(255);
        l_event_time VARCHAR2(50);
        l_event_attrs VARCHAR2(4000);
    BEGIN
        DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
        
        IF p_events_json IS NULL OR LENGTH(p_events_json) < 3 THEN
            l_result := TO_CLOB('[]');
            RETURN l_result;
        END IF;

        -- Parse events array
        l_events_array := JSON_ARRAY_T.parse(p_events_json);
        l_otlp_events := JSON_ARRAY_T();
        
        -- Convert each event to OTLP format
        FOR i IN 0 .. l_events_array.get_size() - 1 LOOP
            l_event_obj := JSON_OBJECT_T(l_events_array.get(i));
            l_otlp_event := JSON_OBJECT_T();
            
            l_event_name := l_event_obj.get_string('name');
            l_event_time := l_event_obj.get_string('time');
            
            l_otlp_event.put('timeUnixNano', to_unix_nano(l_event_time));
            l_otlp_event.put('name', NVL(l_event_name, 'unknown_event'));
            
            -- Handle event attributes if present
            l_event_attrs := l_event_obj.get_string('attributes');
            IF l_event_attrs IS NOT NULL THEN
                l_otlp_event.put('attributes', JSON_ARRAY_T.parse(convert_attributes_to_otlp(l_event_attrs)));
            ELSE
                l_otlp_event.put('attributes', JSON_ARRAY_T());
            END IF;
            
            l_otlp_events.append(l_otlp_event);
        END LOOP;

        l_result := l_otlp_events.to_clob();
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            IF DBMS_LOB.ISTEMPORARY(l_result) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_result);
            END IF;
            
            log_error_internal('convert_events_to_otlp', 
                             'Events conversion failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            
            DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
            l_result := TO_CLOB('[]');
            RETURN l_result;
    END convert_events_to_otlp;
    
    FUNCTION generate_resource_attributes RETURN CLOB
    IS
        l_attrs_array JSON_ARRAY_T;
        l_attr_obj JSON_OBJECT_T;
        l_value_obj JSON_OBJECT_T;
        l_result CLOB;
    BEGIN
        l_attrs_array := JSON_ARRAY_T();
        
        -- Service name
        l_attr_obj := JSON_OBJECT_T();
        l_value_obj := JSON_OBJECT_T();
        l_attr_obj.put('key', 'service.name');
        l_value_obj.put('stringValue', g_service_name);
        l_attr_obj.put('value', l_value_obj);
        l_attrs_array.append(l_attr_obj);
        
        -- Service version
        l_attr_obj := JSON_OBJECT_T();
        l_value_obj := JSON_OBJECT_T();
        l_attr_obj.put('key', 'service.version');
        l_value_obj.put('stringValue', g_service_version);
        l_attr_obj.put('value', l_value_obj);
        l_attrs_array.append(l_attr_obj);
        
        -- Deployment environment
        l_attr_obj := JSON_OBJECT_T();
        l_value_obj := JSON_OBJECT_T();
        l_attr_obj.put('key', 'deployment.environment');
        l_value_obj.put('stringValue', g_deployment_environment);
        l_attr_obj.put('value', l_value_obj);
        l_attrs_array.append(l_attr_obj);
        
        -- Telemetry SDK
        l_attr_obj := JSON_OBJECT_T();
        l_value_obj := JSON_OBJECT_T();
        l_attr_obj.put('key', 'telemetry.sdk.name');
        l_value_obj.put('stringValue', 'PLTelemetry');
        l_attr_obj.put('value', l_value_obj);
        l_attrs_array.append(l_attr_obj);
        
        l_attr_obj := JSON_OBJECT_T();
        l_value_obj := JSON_OBJECT_T();
        l_attr_obj.put('key', 'telemetry.sdk.version');
        l_value_obj.put('stringValue', '2.0.0');
        l_attr_obj.put('value', l_value_obj);
        l_attrs_array.append(l_attr_obj);
        
        -- Database info
        l_attr_obj := JSON_OBJECT_T();
        l_value_obj := JSON_OBJECT_T();
        l_attr_obj.put('key', 'db.name');
        l_value_obj.put('stringValue', SYS_CONTEXT('USERENV', 'DB_NAME'));
        l_attr_obj.put('value', l_value_obj);
        l_attrs_array.append(l_attr_obj);
        
        -- Tenant context if available
        IF g_tenant_id IS NOT NULL THEN
            l_attr_obj := JSON_OBJECT_T();
            l_value_obj := JSON_OBJECT_T();
            l_attr_obj.put('key', 'tenant.id');
            l_value_obj.put('stringValue', g_tenant_id);
            l_attr_obj.put('value', l_value_obj);
            l_attrs_array.append(l_attr_obj);
            
            IF g_tenant_name IS NOT NULL THEN
                l_attr_obj := JSON_OBJECT_T();
                l_value_obj := JSON_OBJECT_T();
                l_attr_obj.put('key', 'tenant.name');
                l_value_obj.put('stringValue', g_tenant_name);
                l_attr_obj.put('value', l_value_obj);
                l_attrs_array.append(l_attr_obj);
            END IF;
        END IF;
        
        l_result := l_attrs_array.to_clob();
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('generate_resource_attributes', 
                             'Resource attributes generation failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RETURN TO_CLOB('[]');
    END generate_resource_attributes;
    
    FUNCTION get_metric_type(p_metric_name VARCHAR2) RETURN VARCHAR2
    IS
        l_pattern VARCHAR2(100);
    BEGIN
        -- Check configured mappings FIRST (highest priority)
        l_pattern := g_metric_type_mappings.FIRST;
        WHILE l_pattern IS NOT NULL LOOP
            IF p_metric_name LIKE l_pattern THEN  -- Ya no necesitas REPLACE
                RETURN g_metric_type_mappings(l_pattern);
            END IF;
            l_pattern := g_metric_type_mappings.NEXT(l_pattern);
        END LOOP;
        
        -- Intelligent heuristics (fallback)
        IF REGEXP_LIKE(p_metric_name, '(total|count|requests|processed|sent|received)$', 'i') THEN
            RETURN 'counter';  -- Things that accumulate
        ELSIF REGEXP_LIKE(p_metric_name, '(bucket|_p\d+|percentile)', 'i') THEN
            RETURN 'histogram';  -- Explicit distribution metrics
        ELSE
            RETURN 'gauge';  -- Default: current state metrics
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN 'gauge';
    END get_metric_type;

    --------------------------------------------------------------------------
    -- UTILITY FUNCTIONS
    --------------------------------------------------------------------------
    
    FUNCTION get_otlp_status_code(p_status VARCHAR2) RETURN NUMBER
    IS
    BEGIN
        RETURN CASE UPPER(NVL(p_status, 'UNSET'))
                   WHEN 'OK' THEN C_STATUS_OK
                   WHEN 'ERROR' THEN C_STATUS_ERROR
                   WHEN 'CANCELLED' THEN C_STATUS_ERROR
                   ELSE C_STATUS_UNSET
               END;
    END get_otlp_status_code;
    
    FUNCTION get_otlp_severity_number(p_level VARCHAR2) RETURN NUMBER
    IS
    BEGIN
        RETURN CASE UPPER(NVL(p_level, 'INFO'))
                   WHEN 'TRACE' THEN C_SEVERITY_TRACE
                   WHEN 'DEBUG' THEN C_SEVERITY_DEBUG
                   WHEN 'INFO' THEN C_SEVERITY_INFO
                   WHEN 'WARN' THEN C_SEVERITY_WARN
                   WHEN 'WARNING' THEN C_SEVERITY_WARN
                   WHEN 'ERROR' THEN C_SEVERITY_ERROR
                   WHEN 'FATAL' THEN C_SEVERITY_FATAL
                   ELSE C_SEVERITY_INFO
               END;
    END get_otlp_severity_number;

    FUNCTION validate_collector_connectivity RETURN BOOLEAN
    IS
        l_req UTL_HTTP.REQ;
        l_res UTL_HTTP.RESP;
        l_test_url VARCHAR2(500);
    BEGIN
        -- Use traces endpoint for connectivity test
        l_test_url := REPLACE(g_traces_endpoint, '/v1/traces', '/');
        
        UTL_HTTP.SET_TRANSFER_TIMEOUT(5); -- Short timeout for test
        l_req := UTL_HTTP.BEGIN_REQUEST(l_test_url, 'GET', 'HTTP/1.1');
        UTL_HTTP.SET_HEADER(l_req, 'User-Agent', 'PLTelemetry-HealthCheck');
        
        l_res := UTL_HTTP.GET_RESPONSE(l_req);
        UTL_HTTP.END_RESPONSE(l_res);
        
        RETURN TRUE;
        
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                UTL_HTTP.END_RESPONSE(l_res);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            RETURN FALSE;
    END validate_collector_connectivity;

    --------------------------------------------------------------------------
    -- HTTP COMMUNICATION
    --------------------------------------------------------------------------
    
    PROCEDURE send_to_endpoint(p_endpoint VARCHAR2, p_content CLOB)
    IS
        l_req          UTL_HTTP.REQ;
        l_res          UTL_HTTP.RESP;
        l_buffer       VARCHAR2(32767);
        l_response     CLOB;
        l_content_size NUMBER;
        l_offset       NUMBER := 1;
        l_amount       NUMBER;
    BEGIN
        IF p_endpoint IS NULL THEN
            log_error_internal('send_to_endpoint', 'Endpoint not configured');
            RETURN;
        END IF;
        
        l_content_size := DBMS_LOB.GETLENGTH(p_content);
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== OTLP BRIDGE v2.0.0 ===');
            DBMS_OUTPUT.PUT_LINE('Sending ' || l_content_size || ' chars to: ' || p_endpoint);
            DBMS_OUTPUT.PUT_LINE('Payload preview: ' || DBMS_LOB.SUBSTR(p_content, 300, 1));
        END IF;
        
        UTL_HTTP.SET_TRANSFER_TIMEOUT(g_timeout);
        l_req := UTL_HTTP.BEGIN_REQUEST(p_endpoint, 'POST', 'HTTP/1.1');
        
        -- OTLP standard headers
        UTL_HTTP.SET_HEADER(l_req, 'Content-Type', 'application/json; charset=utf-8');
        UTL_HTTP.SET_HEADER(l_req, 'Content-Length', l_content_size);
        UTL_HTTP.SET_HEADER(l_req, 'User-Agent', 'PLTelemetry-OTLP-Bridge/2.0.0');
        UTL_HTTP.SET_HEADER(l_req, 'X-PLT-Source', 'Oracle-12c-Native-JSON');
        
        -- Send payload in chunks if needed
        IF l_content_size <= C_DEFAULT_CHUNK_SIZE THEN
            DBMS_LOB.READ(p_content, l_content_size, 1, l_buffer);
            UTL_HTTP.WRITE_TEXT(l_req, l_buffer);
        ELSE
            WHILE l_offset <= l_content_size LOOP
                l_amount := LEAST(C_DEFAULT_CHUNK_SIZE, l_content_size - l_offset + 1);
                DBMS_LOB.READ(p_content, l_amount, l_offset, l_buffer);
                UTL_HTTP.WRITE_TEXT(l_req, l_buffer);
                l_offset := l_offset + l_amount;
            END LOOP;
        END IF;
        
        l_res := UTL_HTTP.GET_RESPONSE(l_req);
        
        -- Handle response
        IF l_res.status_code NOT IN (200, 201, 202, 204) THEN
            DBMS_LOB.CREATETEMPORARY(l_response, TRUE);
            BEGIN
                LOOP
                    UTL_HTTP.READ_TEXT(l_res, l_buffer, 32767);
                    DBMS_LOB.WRITEAPPEND(l_response, LENGTH(l_buffer), l_buffer);
                END LOOP;
            EXCEPTION
                WHEN UTL_HTTP.END_OF_BODY THEN NULL;
            END;
            
            log_error_internal('send_to_endpoint', 
                             'HTTP ' || l_res.status_code || ': ' || l_res.reason_phrase, 
                             'Response: ' || DBMS_LOB.SUBSTR(l_response, 1000, 1));
            
            DBMS_LOB.FREETEMPORARY(l_response);
        ELSIF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('SUCCESS: HTTP ' || l_res.status_code || ' - ' || l_res.reason_phrase);
        END IF;
        
        UTL_HTTP.END_RESPONSE(l_res);
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('send_to_endpoint', 
                             'HTTP communication failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200), 
                             p_endpoint);
            BEGIN
                UTL_HTTP.END_RESPONSE(l_res);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
    END send_to_endpoint;

    --------------------------------------------------------------------------
    -- OTLP PROTOCOL SENDERS
    --------------------------------------------------------------------------
    
    /**
     * Send trace using Oracle 12c+ native JSON objects - FIXED VERSION
     */
    PROCEDURE send_trace_otlp(p_json VARCHAR2)
    IS
        l_trace_id     VARCHAR2(32);
        l_span_id      VARCHAR2(16);
        l_parent_id    VARCHAR2(16);
        l_operation    VARCHAR2(255);
        l_start_time   VARCHAR2(50);
        l_end_time     VARCHAR2(50);
        l_status       VARCHAR2(50);
        l_events_json  VARCHAR2(4000);
        l_attributes   VARCHAR2(4000);
        
        -- Native JSON objects
        l_otlp_obj     JSON_OBJECT_T;
        l_resource_spans JSON_ARRAY_T;
        l_resource_obj JSON_OBJECT_T;
        l_scope_spans  JSON_ARRAY_T;
        l_scope_obj    JSON_OBJECT_T;
        l_spans_array  JSON_ARRAY_T;
        l_span_obj     JSON_OBJECT_T;
        l_status_obj   JSON_OBJECT_T;
        l_resource_attrs JSON_ARRAY_T;
        l_span_attrs   JSON_ARRAY_T;
        l_events_array JSON_ARRAY_T;
        
        l_final_json   CLOB;
    BEGIN
        -- Extract data from PLTelemetry JSON
        l_trace_id := get_json_value(p_json, 'trace_id');
        l_span_id := get_json_value(p_json, 'span_id');
        l_parent_id := get_json_value(p_json, 'parent_span_id');
        l_operation := get_json_value(p_json, 'operation_name');
        l_start_time := get_json_value(p_json, 'start_time');
        l_end_time := get_json_value(p_json, 'end_time');
        l_status := get_json_value(p_json, 'status');
        l_events_json := get_json_object(p_json, 'events');
        l_attributes := get_json_object(p_json, 'attributes');
        
        IF l_trace_id IS NULL OR l_span_id IS NULL THEN
            log_error_internal('send_trace_otlp', 'Missing required trace fields: trace_id=' || l_trace_id || ', span_id=' || l_span_id);
            RETURN;
        END IF;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== TRACE DEBUG ===');
            DBMS_OUTPUT.PUT_LINE('Trace ID: ' || l_trace_id);
            DBMS_OUTPUT.PUT_LINE('Span ID: ' || l_span_id);
            DBMS_OUTPUT.PUT_LINE('Operation: ' || l_operation);
            DBMS_OUTPUT.PUT_LINE('Service: ' || g_service_name || ' v' || g_service_version);
            DBMS_OUTPUT.PUT_LINE('Tenant: ' || NVL(g_tenant_id, 'none'));
        END IF;
        
        -- Initialize JSON objects
        l_otlp_obj := JSON_OBJECT_T();
        l_resource_spans := JSON_ARRAY_T();
        l_resource_obj := JSON_OBJECT_T();
        l_scope_spans := JSON_ARRAY_T();
        l_scope_obj := JSON_OBJECT_T();
        l_spans_array := JSON_ARRAY_T();
        l_span_obj := JSON_OBJECT_T();
        l_status_obj := JSON_OBJECT_T();
        
        -- BUILD RESOURCE ATTRIBUTES (CRITICAL FIX)
        l_resource_attrs := JSON_ARRAY_T();
        
        -- Service identification
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"service.name","value":{"stringValue":"' || escape_json_string(g_service_name) || '"}}'));
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"service.version","value":{"stringValue":"' || escape_json_string(g_service_version) || '"}}'));
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"service.instance.id","value":{"stringValue":"' || escape_json_string(NVL(g_service_instance, SYS_CONTEXT('USERENV', 'HOST') || ':' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME'))) || '"}}'));
        
        -- Telemetry SDK info
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"telemetry.sdk.name","value":{"stringValue":"PLTelemetry"}}'));
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"telemetry.sdk.version","value":{"stringValue":"2.0.0"}}'));
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"telemetry.sdk.language","value":{"stringValue":"plsql"}}'));
        
        -- Tenant context (if available)
        IF g_tenant_id IS NOT NULL THEN
            l_resource_attrs.append(JSON_OBJECT_T('{"key":"tenant.id","value":{"stringValue":"' || escape_json_string(g_tenant_id) || '"}}'));
            IF g_tenant_name IS NOT NULL THEN
                l_resource_attrs.append(JSON_OBJECT_T('{"key":"tenant.name","value":{"stringValue":"' || escape_json_string(g_tenant_name) || '"}}'));
            END IF;
        END IF;
        
        -- Environment context
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"deployment.environment","value":{"stringValue":"production"}}'));
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== RESOURCE ATTRS DEBUG ===');
            DBMS_OUTPUT.PUT_LINE('Resource attrs count: ' || l_resource_attrs.get_size());
            DBMS_OUTPUT.PUT_LINE('Resource attrs JSON: ' || l_resource_attrs.to_string());
            DBMS_OUTPUT.PUT_LINE('=== COMPLETE STRUCTURE DEBUG ===');
            DBMS_OUTPUT.PUT_LINE('Resource object: ' || l_resource_obj.to_string());
        END IF;

        -- BUILD SPAN ATTRIBUTES
        l_span_attrs := JSON_ARRAY_T();
        
        -- Parse PLTelemetry attributes if present
        IF l_attributes IS NOT NULL AND l_attributes != '{}' THEN
            DECLARE
                l_attrs_obj JSON_OBJECT_T;
                l_keys      JSON_KEY_LIST;
                l_key       VARCHAR2(255);
                l_value     VARCHAR2(4000);
            BEGIN
                l_attrs_obj := JSON_OBJECT_T.parse(l_attributes);
                l_keys := l_attrs_obj.get_keys();
                
                FOR i IN 1 .. l_keys.COUNT LOOP
                    l_key := l_keys(i);
                    l_value := l_attrs_obj.get_string(l_key);
                    l_span_attrs.append(JSON_OBJECT_T('{"key":"' || escape_json_string(l_key) || '","value":{"stringValue":"' || escape_json_string(l_value) || '"}}'));
                END LOOP;
            EXCEPTION
                WHEN OTHERS THEN
                    log_error_internal('send_trace_otlp', 'Failed to parse span attributes: ' || SUBSTR(SQLERRM, 1, 200));
            END;
        END IF;
        
        -- BUILD EVENTS ARRAY
        l_events_array := JSON_ARRAY_T();

        IF l_events_json IS NOT NULL AND l_events_json != '[]' THEN
            DECLARE
                l_events_arr JSON_ARRAY_T;
                l_event_obj JSON_OBJECT_T;
                l_event_name VARCHAR2(255);
                l_event_time VARCHAR2(50);
                l_event_attrs VARCHAR2(4000);  
                l_attrs_otlp CLOB;          
            BEGIN
                l_events_arr := JSON_ARRAY_T.parse(l_events_json);
                
                FOR i IN 0 .. l_events_arr.get_size() - 1 LOOP
                    l_event_obj := JSON_OBJECT_T(l_events_arr.get(i));
                    l_event_name := l_event_obj.get_string('name');
                    l_event_time := l_event_obj.get_string('time');
                    l_event_attrs := NVL(l_event_obj.get_string('attributes'), '{}');

                    IF g_debug_mode THEN
                        DBMS_OUTPUT.PUT_LINE('=== EVENT DEBUG ===');
                        DBMS_OUTPUT.PUT_LINE('Event: ' || l_event_name);
                        DBMS_OUTPUT.PUT_LINE('Attributes JSON: ' || NVL(l_event_attrs, 'NULL'));
                        DBMS_OUTPUT.PUT_LINE('Attributes length: ' || NVL(LENGTH(l_event_attrs), 0));
                    END IF;
                    
                    l_attrs_otlp := convert_attributes_to_otlp(l_event_attrs);
                    
                    l_events_array.append(JSON_OBJECT_T('{
                        "timeUnixNano": "' || to_unix_nano(l_event_time) || '",
                        "name": "' || escape_json_string(l_event_name) || '",
                        "attributes": ' || l_attrs_otlp || '
                    }'));
                    
                    -- ← CLEANUP CLOB
                    IF DBMS_LOB.ISTEMPORARY(l_attrs_otlp) = 1 THEN
                        DBMS_LOB.FREETEMPORARY(l_attrs_otlp);
                    END IF;
                END LOOP;
            EXCEPTION
                WHEN OTHERS THEN
                    log_error_internal('send_trace_otlp', 'Failed to parse events: ' || SUBSTR(SQLERRM, 1, 200));
            END;
        END IF;
        -- BUILD SPAN OBJECT
        l_span_obj.put('traceId', l_trace_id);
        l_span_obj.put('spanId', l_span_id);
        
        IF l_parent_id IS NOT NULL AND LENGTH(l_parent_id) = 16 THEN
            l_span_obj.put('parentSpanId', l_parent_id);
        END IF;
        
        l_span_obj.put('name', NVL(l_operation, 'unknown_operation'));
        l_span_obj.put('kind', 1); -- SPAN_KIND_INTERNAL
        l_span_obj.put('startTimeUnixNano', to_unix_nano(l_start_time));
        l_span_obj.put('endTimeUnixNano', to_unix_nano(l_end_time));
        
        -- Add span attributes
        l_span_obj.put('attributes', l_span_attrs);
        
        -- Add events
        l_span_obj.put('events', l_events_array);
        
        -- Add status
        l_status_obj.put('code', get_otlp_status_code(l_status));
        IF l_status = 'ERROR' THEN
            l_status_obj.put('message', 'Span completed with error status');
        END IF;
        l_span_obj.put('status', l_status_obj);
        
        -- BUILD COMPLETE OTLP STRUCTURE
        l_spans_array.append(l_span_obj);
        
        -- Scope with proper identification
        l_scope_obj.put('name', 'PLTelemetry');
        l_scope_obj.put('version', '2.0.0');
        l_scope_obj.put('spans', l_spans_array);
        
        l_scope_spans.append(l_scope_obj);
        
        -- Resource with complete attributes
        l_resource_obj.put('resource', JSON_OBJECT_T('{"attributes":' || l_resource_attrs.to_string() || '}'));
        l_resource_obj.put('scopeSpans', l_scope_spans);
        
        l_resource_spans.append(l_resource_obj);
        
        -- Final OTLP object
        l_otlp_obj.put('resourceSpans', l_resource_spans);
        
        -- Convert to CLOB and send
        l_final_json := l_otlp_obj.to_clob();
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== COMPLETE TRACE JSON ===');
            DBMS_OUTPUT.PUT_LINE('Size: ' || DBMS_LOB.GETLENGTH(l_final_json) || ' chars');
            DBMS_OUTPUT.PUT_LINE('Preview: ' || DBMS_LOB.SUBSTR(l_final_json, 500, 1));
        END IF;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== FINAL JSON STRUCTURE ===');
            DBMS_OUTPUT.PUT_LINE('Resource spans array size: ' || l_resource_spans.get_size());
            DBMS_OUTPUT.PUT_LINE('Complete JSON preview: ' || DBMS_LOB.SUBSTR(l_final_json, 1000, 1));
        END IF;

        send_to_endpoint(g_traces_endpoint, l_final_json);
        
        IF DBMS_LOB.ISTEMPORARY(l_final_json) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_final_json);
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('send_trace_otlp', 'Native JSON trace failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000));
    END send_trace_otlp;
    
    PROCEDURE send_metric_otlp(p_json VARCHAR2)
    IS
        l_metric_name  VARCHAR2(255);
        l_value        NUMBER;
        l_timestamp    VARCHAR2(50);
        l_unit         VARCHAR2(50);
        l_trace_id     VARCHAR2(32);
        l_span_id      VARCHAR2(16);
        l_attrs_json   VARCHAR2(4000);
        l_metric_type  VARCHAR2(20);
        l_is_business_metric BOOLEAN := FALSE;
        
        l_otlp_obj     JSON_OBJECT_T;
        l_resource_metrics JSON_ARRAY_T;
        l_resource_obj JSON_OBJECT_T;
        l_scope_metrics JSON_ARRAY_T;
        l_scope_obj    JSON_OBJECT_T;
        l_metrics_array JSON_ARRAY_T;
        l_metric_obj   JSON_OBJECT_T;
        l_data_obj     JSON_OBJECT_T;
        l_data_points  JSON_ARRAY_T;
        l_point_obj    JSON_OBJECT_T;
        l_attributes   JSON_ARRAY_T;
        
        l_final_json   CLOB;
    BEGIN
        -- Extract PLTelemetry metric data
        l_metric_name := get_json_value(p_json, 'name');
        l_value := TO_NUMBER(get_json_value(p_json, 'value'));
        l_timestamp := get_json_value(p_json, 'timestamp');
        l_unit := get_json_value(p_json, 'unit');
        l_trace_id := get_json_value(p_json, 'trace_id');
        l_span_id := get_json_value(p_json, 'span_id');
        l_attrs_json := get_json_object(p_json, 'attributes');
        
        -- Determine if this is a business metric (no trace correlation)
        l_is_business_metric := (l_trace_id IS NULL OR l_trace_id IN ('no-trace', 'null'));
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== METRIC DEBUG ===');
            DBMS_OUTPUT.PUT_LINE('Name: ' || l_metric_name);
            DBMS_OUTPUT.PUT_LINE('Value: ' || l_value);
            DBMS_OUTPUT.PUT_LINE('Unit: ' || NVL(l_unit, 'NULL'));
            DBMS_OUTPUT.PUT_LINE('Trace ID: ' || NVL(l_trace_id, 'NULL'));
            DBMS_OUTPUT.PUT_LINE('Business metric: ' || CASE WHEN l_is_business_metric THEN 'YES' ELSE 'NO' END);
            DBMS_OUTPUT.PUT_LINE('Input JSON: ' || SUBSTR(p_json, 1, 200));
        END IF;

        IF l_metric_name IS NULL OR l_value IS NULL THEN
            log_error_internal('send_metric_otlp', 'Missing required metric fields (name or value)');
            RETURN;
        END IF;
        
        -- Determine metric type for Grafana compatibility
        l_metric_type := get_metric_type(l_metric_name);
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Metric type determined: ' || l_metric_type);
        END IF;
        
        -- Build OTLP metric structure
        l_otlp_obj := JSON_OBJECT_T();
        l_resource_metrics := JSON_ARRAY_T();
        l_resource_obj := JSON_OBJECT_T();
        l_scope_metrics := JSON_ARRAY_T();
        l_scope_obj := JSON_OBJECT_T();
        l_metrics_array := JSON_ARRAY_T();
        l_metric_obj := JSON_OBJECT_T();
        l_data_obj := JSON_OBJECT_T();
        l_data_points := JSON_ARRAY_T();
        l_point_obj := JSON_OBJECT_T();
        l_attributes := JSON_ARRAY_T();
        
        -- Build data point
        l_point_obj.put('timeUnixNano', to_unix_nano(NVL(l_timestamp, TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'))));
        
        -- Handle different metric types
        IF l_metric_type = 'counter' THEN
            l_point_obj.put('asInt', TRUNC(l_value));
        ELSE
            l_point_obj.put('asDouble', l_value);
        END IF;
        
        -- ============================================================
        -- 🎯 ENHANCED ATTRIBUTE HANDLING FOR GRAFANA DASHBOARDS
        -- ============================================================
        
        -- Add existing attributes if present
        IF l_attrs_json IS NOT NULL AND l_attrs_json != '{}' THEN
            l_attributes := JSON_ARRAY_T.parse(convert_attributes_to_otlp(l_attrs_json));
        END IF;
        
        -- Auto-inject tenant.id as dataPoint attribute (ALWAYS)
        IF g_tenant_id IS NOT NULL THEN
            l_attributes.append(JSON_OBJECT_T('{"key":"tenant.id","value":{"stringValue":"' || g_tenant_id || '"}}'));
        END IF;
        
        -- CRITICAL: Handle trace correlation vs business metrics differently
        IF l_is_business_metric THEN
            -- Business metrics: No trace correlation, add business flag
            l_attributes.append(JSON_OBJECT_T('{"key":"metric.category","value":{"stringValue":"business"}}'));
            l_attributes.append(JSON_OBJECT_T('{"key":"metric.aggregatable","value":{"stringValue":"true"}}'));
            
            IF g_debug_mode THEN
                DBMS_OUTPUT.PUT_LINE('✅ BUSINESS METRIC: No trace correlation added');
            END IF;
        ELSE
            -- Correlated metrics: Add trace/span correlation
            l_attributes.append(JSON_OBJECT_T('{"key":"trace.id","value":{"stringValue":"' || l_trace_id || '"}}'));
            l_attributes.append(JSON_OBJECT_T('{"key":"metric.category","value":{"stringValue":"traced"}}'));
            
            -- Only add span correlation if span_id is valid
            IF l_span_id IS NOT NULL AND l_span_id != 'no-span' THEN
                l_attributes.append(JSON_OBJECT_T('{"key":"span.id","value":{"stringValue":"' || l_span_id || '"}}'));
            END IF;
            
            IF g_debug_mode THEN
                DBMS_OUTPUT.PUT_LINE('🔗 TRACED METRIC: Added trace correlation: ' || l_trace_id);
            END IF;
        END IF;
        
        -- Add system context (useful for debugging)
        l_attributes.append(JSON_OBJECT_T('{"key":"db.name","value":{"stringValue":"' || SYS_CONTEXT('USERENV', 'DB_NAME') || '"}}'));
        
        l_point_obj.put('attributes', l_attributes);
        
        -- ============================================================
        
        l_data_points.append(l_point_obj);
        
        -- Choose appropriate OTLP metric type based on Grafana best practices
        IF l_metric_type = 'counter' THEN
            l_data_obj.put('dataPoints', l_data_points);
            l_data_obj.put('isMonotonic', TRUE);  -- Important for Grafana rate() functions
            l_metric_obj.put('sum', l_data_obj);
        ELSIF l_metric_type = 'histogram' THEN
            l_data_obj.put('dataPoints', l_data_points);
            l_metric_obj.put('histogram', l_data_obj);
        ELSE
            -- Default: gauge (most flexible for Grafana)
            l_data_obj.put('dataPoints', l_data_points);
            l_metric_obj.put('gauge', l_data_obj);
        END IF;
        
        -- Metric metadata optimized for Grafana discovery
        l_metric_obj.put('name', l_metric_name);
        l_metric_obj.put('description', 'PLTelemetry metric: ' || l_metric_name || 
                        CASE WHEN l_is_business_metric THEN ' (business)' ELSE ' (traced)' END);
        l_metric_obj.put('unit', NVL(l_unit, '1'));
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== FINAL OTLP METRIC ===');
            DBMS_OUTPUT.PUT_LINE('Name: ' || l_metric_obj.get_string('name'));
            DBMS_OUTPUT.PUT_LINE('Unit: ' || l_metric_obj.get_string('unit'));
            DBMS_OUTPUT.PUT_LINE('Type: ' || l_metric_type);
            DBMS_OUTPUT.PUT_LINE('Attributes count: ' || l_attributes.get_size());
        END IF;

        l_metrics_array.append(l_metric_obj);
        
        -- Build complete structure
        l_scope_obj.put('name', 'PLTelemetry');
        l_scope_obj.put('version', '2.0.0');
        l_scope_obj.put('metrics', l_metrics_array);
        
        l_scope_metrics.append(l_scope_obj);
        
        l_resource_obj.put('attributes', JSON_ARRAY_T.parse(generate_resource_attributes()));
        l_resource_obj.put('scopeMetrics', l_scope_metrics);
        
        l_resource_metrics.append(l_resource_obj);
        
        l_otlp_obj.put('resourceMetrics', l_resource_metrics);
        
        -- Convert to CLOB and send
        l_final_json := l_otlp_obj.to_clob();
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== SENDING TO GRAFANA ===');
            DBMS_OUTPUT.PUT_LINE('JSON size: ' || DBMS_LOB.GETLENGTH(l_final_json) || ' chars');
            DBMS_OUTPUT.PUT_LINE('Endpoint: ' || g_metrics_endpoint);
            DBMS_OUTPUT.PUT_LINE('Preview: ' || DBMS_LOB.SUBSTR(l_final_json, 300, 1));
        END IF;
        
        send_to_endpoint(g_metrics_endpoint, l_final_json);
        
        IF DBMS_LOB.ISTEMPORARY(l_final_json) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_final_json);
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('send_metric_otlp', 
                            'Metric sending failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
    END send_metric_otlp;
    
    /**
    * Send log using Oracle 12c+ native JSON objects with full OTLP compliance
    */
    PROCEDURE send_log_otlp(p_json VARCHAR2)
    IS
        l_message      VARCHAR2(4000);
        l_level        VARCHAR2(20);
        l_timestamp    VARCHAR2(50);
        l_trace_id     VARCHAR2(32);
        l_span_id      VARCHAR2(16);
        l_attrs_json   VARCHAR2(4000);
        
        -- Native JSON objects
        l_otlp_obj     JSON_OBJECT_T;
        l_resource_logs JSON_ARRAY_T;
        l_resource_obj JSON_OBJECT_T;
        l_scope_logs   JSON_ARRAY_T;
        l_scope_obj    JSON_OBJECT_T;
        l_log_records  JSON_ARRAY_T;
        l_log_record   JSON_OBJECT_T;
        l_body_obj     JSON_OBJECT_T;
        l_resource_attrs JSON_ARRAY_T;
        l_log_attrs    JSON_ARRAY_T;
        
        l_final_json   CLOB;
    BEGIN
        -- Extract PLTelemetry log data
        l_message := get_json_value(p_json, 'message');
        l_level := get_json_value(p_json, 'severity');
        l_timestamp := get_json_value(p_json, 'timestamp');
        l_trace_id := get_json_value(p_json, 'trace_id');
        l_span_id := get_json_value(p_json, 'span_id');
        l_attrs_json := get_json_object(p_json, 'attributes');
        
        IF l_message IS NULL OR l_level IS NULL THEN
            log_error_internal('send_log_otlp', 'Missing required log fields (message or severity)');
            RETURN;
        END IF;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Log: ' || l_level || ' - ' || SUBSTR(l_message, 1, 100));
            IF l_trace_id IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE('Trace correlation: ' || l_trace_id);
            END IF;
        END IF;
        
        -- Build OTLP log structure
        l_otlp_obj := JSON_OBJECT_T();
        l_resource_logs := JSON_ARRAY_T();
        l_resource_obj := JSON_OBJECT_T();
        l_scope_logs := JSON_ARRAY_T();
        l_scope_obj := JSON_OBJECT_T();
        l_log_records := JSON_ARRAY_T();
        l_log_record := JSON_OBJECT_T();
        l_body_obj := JSON_OBJECT_T();
        l_log_attrs := JSON_ARRAY_T();
        
        -- Build resource attributes (same pattern as traces/metrics)
        l_resource_attrs := JSON_ARRAY_T();
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"service.name","value":{"stringValue":"' || g_service_name || '"}}'));
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"service.version","value":{"stringValue":"' || g_service_version || '"}}'));
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"service.instance.id","value":{"stringValue":"' || NVL(g_service_instance, SYS_CONTEXT('USERENV', 'HOST') || ':' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME')) || '"}}'));
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"telemetry.sdk.name","value":{"stringValue":"PLTelemetry"}}'));
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"telemetry.sdk.version","value":{"stringValue":"2.0.0"}}'));
        l_resource_attrs.append(JSON_OBJECT_T('{"key":"telemetry.sdk.language","value":{"stringValue":"plsql"}}'));
        
        -- 🎯 AUTO-INJECT TENANT_ID (CRÍTICO)
        IF g_tenant_id IS NOT NULL THEN
            l_resource_attrs.append(JSON_OBJECT_T('{"key":"tenant.id","value":{"stringValue":"' || g_tenant_id || '"}}'));
        END IF;
        
        IF g_tenant_name IS NOT NULL THEN
            l_resource_attrs.append(JSON_OBJECT_T('{"key":"tenant.name","value":{"stringValue":"' || escape_json_string(g_tenant_name) || '"}}'));
        END IF;
        
        -- Build log record attributes
        IF l_attrs_json IS NOT NULL THEN
            l_log_attrs := JSON_ARRAY_T.parse(convert_attributes_to_otlp(l_attrs_json));
        END IF;
        
        -- Auto-inject correlation attributes
        IF l_trace_id IS NOT NULL THEN
            l_log_attrs.append(JSON_OBJECT_T('{"key":"trace.id","value":{"stringValue":"' || l_trace_id || '"}}'));
        END IF;
        
        IF l_span_id IS NOT NULL THEN
            l_log_attrs.append(JSON_OBJECT_T('{"key":"span.id","value":{"stringValue":"' || l_span_id || '"}}'));
        END IF;
        
        -- Build log record
        l_log_record.put('timeUnixNano', to_unix_nano(NVL(l_timestamp, TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'))));
        l_log_record.put('severityNumber', get_otlp_severity_number(l_level));
        l_log_record.put('severityText', UPPER(l_level));
        
        -- Message body
        l_body_obj.put('stringValue', escape_json_string(l_message));
        l_log_record.put('body', l_body_obj);
        
        -- Trace correlation
        IF l_trace_id IS NOT NULL THEN
            l_log_record.put('traceId', l_trace_id);
        END IF;
        
        IF l_span_id IS NOT NULL THEN
            l_log_record.put('spanId', l_span_id);
        END IF;
        
        -- Attributes
        l_log_record.put('attributes', l_log_attrs);
        
        l_log_records.append(l_log_record);
        
        -- Build complete structure
        l_scope_obj.put('name', 'PLTelemetry');
        l_scope_obj.put('version', '2.0.0');
        l_scope_obj.put('logRecords', l_log_records);
        
        l_scope_logs.append(l_scope_obj);
        
        l_resource_obj.put('resource', JSON_OBJECT_T('{"attributes":' || l_resource_attrs.to_string() || '}'));
        l_resource_obj.put('scopeLogs', l_scope_logs);
        
        l_resource_logs.append(l_resource_obj);
        
        l_otlp_obj.put('resourceLogs', l_resource_logs);
        
        -- Convert to CLOB and send
        l_final_json := l_otlp_obj.to_clob();
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== LOG OTLP DEBUG ===');
            DBMS_OUTPUT.PUT_LINE('Severity: ' || l_level || ' (' || get_otlp_severity_number(l_level) || ')');
            DBMS_OUTPUT.PUT_LINE('Message: ' || SUBSTR(l_message, 1, 200));
            DBMS_OUTPUT.PUT_LINE('Tenant: ' || NVL(g_tenant_id, 'none'));
            DBMS_OUTPUT.PUT_LINE('Trace correlation: ' || NVL(l_trace_id, 'none'));
            DBMS_OUTPUT.PUT_LINE('JSON size: ' || DBMS_LOB.GETLENGTH(l_final_json) || ' chars');
        END IF;
        
        send_to_endpoint(g_logs_endpoint, l_final_json);
        
        IF DBMS_LOB.ISTEMPORARY(l_final_json) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_final_json);
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('send_log_otlp', 
                            'Log sending failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
    END send_log_otlp;

    --------------------------------------------------------------------------
    -- MAIN ROUTING
    --------------------------------------------------------------------------
    
    PROCEDURE route_to_otlp(p_json VARCHAR2)
    IS
    BEGIN
        IF p_json IS NULL OR LENGTH(p_json) < 10 THEN
            RETURN;
        END IF;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== OTLP BRIDGE v2.0.0 ROUTING ===');
            DBMS_OUTPUT.PUT_LINE('Payload size: ' || LENGTH(p_json) || ' chars');
        END IF;
        
        -- Route based on PLTelemetry JSON structure
        IF INSTR(p_json, '"name"') > 0 AND INSTR(p_json, '"value"') > 0 AND INSTR(p_json, '"unit"') > 0 THEN
            -- This is a metric
            send_metric_otlp(p_json);
        ELSIF INSTR(p_json, '"span_id"') > 0 AND INSTR(p_json, '"operation_name"') > 0 THEN
            -- This is a trace/span
            send_trace_otlp(p_json);
        ELSIF INSTR(p_json, '"severity"') > 0 AND INSTR(p_json, '"message"') > 0 THEN
            -- This is a log
            send_log_otlp(p_json);
        ELSE
            log_error_internal('route_to_otlp', 'Unknown telemetry data type', SUBSTR(p_json, 1, 200));
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('route_to_otlp', 
                             'Routing failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
    END route_to_otlp;

    --------------------------------------------------------------------------
    -- CONFIGURATION PROCEDURES
    --------------------------------------------------------------------------
    
    PROCEDURE set_otlp_collector(p_base_url VARCHAR2)
    IS
    BEGIN
        IF p_base_url IS NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'OTLP collector URL cannot be null');
        END IF;
        
        -- Remove trailing slash if present
        DECLARE
            l_clean_url VARCHAR2(500) := RTRIM(p_base_url, '/');
        BEGIN
            g_traces_endpoint := l_clean_url || C_OTLP_TRACES_PATH;
            g_metrics_endpoint := l_clean_url || C_OTLP_METRICS_PATH;
            g_logs_endpoint := l_clean_url || C_OTLP_LOGS_PATH;
        END;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('OTLP Collector configured: ' || p_base_url);
            DBMS_OUTPUT.PUT_LINE('  Traces:  ' || g_traces_endpoint);
            DBMS_OUTPUT.PUT_LINE('  Metrics: ' || g_metrics_endpoint);
            DBMS_OUTPUT.PUT_LINE('  Logs:    ' || g_logs_endpoint);
        END IF;
    END set_otlp_collector;
    
    PROCEDURE set_service_info(
        p_service_name         VARCHAR2, 
        p_service_version      VARCHAR2 DEFAULT NULL, 
        p_deployment_environment VARCHAR2 DEFAULT NULL
    )
    IS
    BEGIN
        g_service_name := NVL(p_service_name, 'oracle-plsql');
        g_service_version := NVL(p_service_version, '1.0.0');
        g_deployment_environment := NVL(p_deployment_environment, 'unknown');
        
        -- Generate service instance ID
        g_service_instance := SYS_CONTEXT('USERENV', 'HOST') || ':' || 
                             SYS_CONTEXT('USERENV', 'INSTANCE_NAME') || ':' || 
                             SYS_CONTEXT('USERENV', 'SESSION_USER');
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Service configured: ' || g_service_name || ' v' || g_service_version);
            DBMS_OUTPUT.PUT_LINE('Environment: ' || g_deployment_environment);
            DBMS_OUTPUT.PUT_LINE('Instance: ' || g_service_instance);
        END IF;
    END set_service_info;
    
    PROCEDURE set_debug_mode(p_enabled BOOLEAN)
    IS
    BEGIN
        g_debug_mode := NVL(p_enabled, FALSE);
        DBMS_OUTPUT.PUT_LINE('OTLP Bridge v2.0.0 debug mode: ' || 
                           CASE WHEN g_debug_mode THEN 'ENABLED' ELSE 'DISABLED' END);
    END set_debug_mode;
    
    PROCEDURE set_timeout(p_timeout NUMBER)
    IS
    BEGIN
        g_timeout := NVL(p_timeout, C_DEFAULT_TIMEOUT);
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('HTTP timeout set to: ' || g_timeout || ' seconds');
        END IF;
    END set_timeout;
    
    PROCEDURE set_traces_endpoint(p_url VARCHAR2)
    IS
    BEGIN
        g_traces_endpoint := p_url;
    END set_traces_endpoint;
    
    PROCEDURE set_metrics_endpoint(p_url VARCHAR2)
    IS
    BEGIN
        g_metrics_endpoint := p_url;
    END set_metrics_endpoint;
    
    PROCEDURE set_logs_endpoint(p_url VARCHAR2)
    IS
    BEGIN
        g_logs_endpoint := p_url;
    END set_logs_endpoint;
    
    PROCEDURE set_metric_type_mapping(p_metric_name_pattern VARCHAR2, p_otlp_type VARCHAR2)
    IS
    BEGIN
        IF p_otlp_type NOT IN ('gauge', 'counter', 'histogram') THEN
            RAISE_APPLICATION_ERROR(-20002, 'Invalid OTLP metric type: ' || p_otlp_type);
        END IF;
        
        g_metric_type_mappings(p_metric_name_pattern) := p_otlp_type;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Metric mapping: ' || p_metric_name_pattern || ' -> ' || p_otlp_type);
        END IF;
    END set_metric_type_mapping;
    
    PROCEDURE set_tenant_context(p_tenant_id VARCHAR2, p_tenant_name VARCHAR2 DEFAULT NULL)
    IS
    BEGIN
        g_tenant_id := p_tenant_id;
        g_tenant_name := p_tenant_name;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Tenant context set: ' || p_tenant_id || 
                               CASE WHEN p_tenant_name IS NOT NULL THEN ' (' || p_tenant_name || ')' END);
        END IF;
    END set_tenant_context;
    
    PROCEDURE clear_tenant_context
    IS
    BEGIN
        g_tenant_id := NULL;
        g_tenant_name := NULL;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Tenant context cleared');
        END IF;
    END clear_tenant_context;

    --------------------------------------------------------------------------
    -- GETTERS
    --------------------------------------------------------------------------
    
    FUNCTION get_debug_mode RETURN BOOLEAN
    IS
    BEGIN
        RETURN g_debug_mode;
    END get_debug_mode;
    
    FUNCTION get_timeout RETURN NUMBER
    IS
    BEGIN
        RETURN g_timeout;
    END get_timeout;
    
    FUNCTION get_service_name RETURN VARCHAR2
    IS
    BEGIN
        RETURN g_service_name;
    END get_service_name;
    
    FUNCTION get_service_version RETURN VARCHAR2
    IS
    BEGIN
        RETURN g_service_version;
    END get_service_version;
    
    FUNCTION get_deployment_environment RETURN VARCHAR2
    IS
    BEGIN
        RETURN g_deployment_environment;
    END get_deployment_environment;
    
    FUNCTION get_tenant_id RETURN VARCHAR2
    IS
    BEGIN
        RETURN g_tenant_id;
    END get_tenant_id;
    
    FUNCTION get_tenant_name RETURN VARCHAR2
    IS
    BEGIN
        RETURN g_tenant_name;
    END get_tenant_name;

END PLT_OTLP_BRIDGE;
/