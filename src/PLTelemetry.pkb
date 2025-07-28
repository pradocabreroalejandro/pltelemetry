CREATE OR REPLACE PACKAGE BODY PLTelemetry
AS
    /**
     * PLTelemetry - OpenTelemetry SDK for PL/SQL
     * Version: 0.3.1 - Normalized Input Edition
     * 
     * This package provides distributed tracing capabilities for Oracle PL/SQL
     * applications following OpenTelemetry standards.
     * 
     * Requirements: Oracle 12c+ with native JSON support
     * 
     * JSON Format:
     * - Traces: {"trace_id", "operation", "start_time", "service_name"}
     * - Spans: {"trace_id", "span_id", "operation", "start_time", "end_time", "duration_ms", "status", "attributes"}
     * - Metrics: {"name", "value", "unit", "timestamp", "trace_id", "span_id", "attributes"}
     * - Logs: {"severity", "message", "timestamp", "trace_id", "span_id", "attributes"}
     */

    --------------------------------------------------------------------------
    -- PRIVATE ERROR HANDLING HELPER
    --------------------------------------------------------------------------
    
    /**
     * Centralized error logging to avoid code duplication
     */
    PROCEDURE log_error_internal(
        p_module VARCHAR2,
        p_error_message VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL,
        p_span_id VARCHAR2 DEFAULT NULL
    )
    IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO plt_telemetry_errors (
            error_time,
            error_message,
            module_name,
            trace_id,
            span_id
        ) VALUES (
            SYSTIMESTAMP,
            SUBSTR(p_error_message, 1, 4000),
            SUBSTR(p_module, 1, 100),
            p_trace_id,
            p_span_id
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Never let error logging break anything
    END log_error_internal;

    /**
    * Safely free temporary CLOB to prevent memory leaks
    */
    PROCEDURE safe_free_temp_clob(p_clob IN OUT CLOB)
    IS
    BEGIN
        IF p_clob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(p_clob) = 1 THEN
            DBMS_LOB.FREETEMPORARY(p_clob);
        END IF;
        p_clob := NULL;
    EXCEPTION
        WHEN OTHERS THEN
            p_clob := NULL; -- At least clear the reference
    END safe_free_temp_clob;

    /**
    * Properly escape string for JSON (handles newlines, tabs, quotes, etc.)
    */
    FUNCTION escape_json_string(p_input VARCHAR2) RETURN VARCHAR2
    IS
        l_output VARCHAR2(4000);
    BEGIN
        IF p_input IS NULL THEN
            RETURN '';
        END IF;
        
        l_output := p_input;
        
        -- Escape in correct order (backslash FIRST!)
        l_output := REPLACE(l_output, '\', '\\');     -- \ -> \\
        l_output := REPLACE(l_output, '"', '\"');     -- " -> \"
        l_output := REPLACE(l_output, CHR(10), '\n'); -- newline -> \n
        l_output := REPLACE(l_output, CHR(13), '\r'); -- carriage return -> \r
        l_output := REPLACE(l_output, CHR(9), '\t');  -- tab -> \t
        l_output := REPLACE(l_output, CHR(8), '\b');  -- backspace -> \b
        l_output := REPLACE(l_output, CHR(12), '\f'); -- form feed -> \f
        
        -- Truncate if too long
        IF LENGTH(l_output) > 3900 THEN
            l_output := SUBSTR(l_output, 1, 3900) || '...[TRUNCATED]';
        END IF;
        
        RETURN l_output;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Ultra-safe fallback: just remove problematic chars
            RETURN REPLACE(REPLACE(REPLACE(NVL(p_input, ''), '"', '\"'), CHR(10), ' '), CHR(13), ' ');
    END escape_json_string;

    --------------------------------------------------------------------------
    -- CORE ID GENERATION
    --------------------------------------------------------------------------

    /**
     * Generates a random ID of specified byte length using Oracle 12c+ features
     */
    FUNCTION generate_id (p_bytes IN NUMBER)
        RETURN VARCHAR2
    IS
        l_length NUMBER;
    BEGIN
        -- Validate input
        IF p_bytes NOT IN (8, 16) THEN
            RAISE_APPLICATION_ERROR(-20001, 'Size must be 8 or 16 bytes');
        END IF;
        
        -- Calculate hex string length (bytes * 2)
        l_length := p_bytes * 2;
        
        -- Generate proper hex string using Oracle 12c+ features
        RETURN LOWER(
            TRANSLATE(
                DBMS_RANDOM.STRING('U', l_length), 
                'GHIJKLMNOPQRSTUVWXYZ', 
                '0123456789ABCDEF0123'
            )
        );
    END generate_id;

    /**
     * Generates a 128-bit trace ID following OpenTelemetry spec
     */
    FUNCTION generate_trace_id
        RETURN VARCHAR2
    IS
    BEGIN
        RETURN generate_id(16);
    END generate_trace_id;

    /**
     * Generates a 64-bit span ID following OpenTelemetry spec
     */
    FUNCTION generate_span_id
        RETURN VARCHAR2
    IS
    BEGIN
        RETURN generate_id(8);
    END generate_span_id;

    --------------------------------------------------------------------------
    -- JSON UTILITY FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Normalize input strings for safe processing
     */
    FUNCTION normalize_string(
        p_input      VARCHAR2,
        p_max_length NUMBER DEFAULT 4000,
        p_allow_null BOOLEAN DEFAULT TRUE
    ) RETURN VARCHAR2
    IS
        l_result VARCHAR2(32767);
    BEGIN
        -- Handle NULL input
        IF p_input IS NULL THEN
            RETURN CASE WHEN p_allow_null THEN NULL ELSE '' END;
        END IF;
        
        -- Minimal normalization - just the essentials
        l_result := TRIM(p_input);                    -- Remove leading/trailing spaces
        l_result := REPLACE(l_result, CHR(0), '');   -- Remove null terminators (Forms legacy)
        
        -- Apply length limit
        IF LENGTH(l_result) > p_max_length THEN
            l_result := SUBSTR(l_result, 1, p_max_length - 3) || '...';
        END IF;
        
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback: basic TRIM and length limit
            RETURN SUBSTR(TRIM(NVL(p_input, '')), 1, p_max_length);
    END normalize_string;

    /**
     * Validate attribute key follows OpenTelemetry naming conventions
     */
    FUNCTION validate_attribute_key(p_key VARCHAR2) 
        RETURN BOOLEAN 
    IS
    BEGIN
        RETURN REGEXP_LIKE(p_key, '^[a-zA-Z][a-zA-Z0-9._]*$')
               AND LENGTH(p_key) <= 255;
    END validate_attribute_key;

    /**
     * Extract value from JSON using native Oracle JSON functions
     */
    FUNCTION get_json_value (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
    BEGIN
        RETURN JSON_VALUE(p_json, '$.' || p_key);
    END get_json_value;

    /**
     * Extract JSON object from JSON using native Oracle JSON functions
     */
    FUNCTION get_json_object (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
    BEGIN
        RETURN JSON_QUERY(p_json, '$.' || p_key);
    END get_json_object;

    /**
     * Convert attributes to OTLP format using native Oracle JSON
     */
    FUNCTION convert_attributes_to_otlp(p_attrs_json VARCHAR2)
        RETURN CLOB
    IS
        l_result        CLOB;
        l_json_obj      JSON_OBJECT_T;
        l_keys          JSON_KEY_LIST;
        l_key           VARCHAR2(255);
        l_value         VARCHAR2(4000);
        l_first         BOOLEAN := TRUE;
        l_attr_json     VARCHAR2(1000);
    BEGIN
        DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
        DBMS_LOB.WRITEAPPEND(l_result, 1, '[');
        
        IF p_attrs_json IS NULL OR LENGTH(p_attrs_json) < 3 THEN
            DBMS_LOB.WRITEAPPEND(l_result, 1, ']');
            RETURN l_result;
        END IF;

        -- Parse using native JSON
        l_json_obj := JSON_OBJECT_T.parse(p_attrs_json);
        l_keys := l_json_obj.get_keys();
        
        -- Process each key-value pair
        FOR i IN 1 .. l_keys.COUNT LOOP
            l_key := l_keys(i);
            l_value := l_json_obj.get_string(l_key);
            
            -- Build OTLP attribute format
            l_attr_json := '{"key":"' || REPLACE(l_key, '"', '\"') || 
                          '","value":{"stringValue":"' || REPLACE(l_value, '"', '\"') || '"}}';

            IF NOT l_first THEN
                DBMS_LOB.WRITEAPPEND(l_result, 1, ',');
            END IF;

            DBMS_LOB.WRITEAPPEND(l_result, LENGTH(l_attr_json), l_attr_json);
            l_first := FALSE;
        END LOOP;

        DBMS_LOB.WRITEAPPEND(l_result, 1, ']');
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Clean up and return minimal valid JSON
            IF DBMS_LOB.ISTEMPORARY(l_result) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_result);
            END IF;
            
            DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
            DBMS_LOB.WRITEAPPEND(l_result, 2, '[]');
            RETURN l_result;
    END convert_attributes_to_otlp;

    /**
     * Creates a key-value attribute string with proper escaping
     */
    FUNCTION add_attribute (p_key VARCHAR2, p_value VARCHAR2)
        RETURN VARCHAR2
    IS
        l_key   VARCHAR2(255);
        l_value VARCHAR2(4000);
    BEGIN
        -- Normalize & validate input parameters
        l_key := normalize_string(p_key, p_max_length => 255, p_allow_null => FALSE);
        l_value := normalize_string(p_value, p_max_length => 4000, p_allow_null => TRUE);
        
        -- Validate key follows OpenTelemetry conventions
        IF NOT validate_attribute_key(l_key) THEN
            log_error_internal(
                'add_attribute',
                'Invalid attribute key: ' || SUBSTR(l_key, 1, 100) || 
                ' - must start with letter and contain only letters, numbers, dots, or underscores'
            );
            RETURN NULL;
        END IF;
        
        -- Handle null value
        IF l_value IS NULL THEN
            RETURN l_key || '=';
        END IF;
        
        -- Escape special characters and return
        RETURN l_key || '=' || REPLACE(REPLACE(l_value, '\', '\\'), '=', '\=');
    END add_attribute;

    /**
     * Converts an attributes collection to JSON format using native Oracle JSON
     * Automatically includes tenant context if available
     */
    FUNCTION attributes_to_json (p_attributes t_attributes)
        RETURN VARCHAR2
    IS
        l_json_obj     JSON_OBJECT_T;
        l_key          VARCHAR2(255);
        l_value        VARCHAR2(4000);
        l_pos          NUMBER;
    BEGIN
        l_json_obj := JSON_OBJECT_T();

        -- Auto-inject tenant context if available
        IF g_current_tenant_id IS NOT NULL THEN
            l_json_obj.put('tenant.id', g_current_tenant_id);
            
            IF g_current_tenant_name IS NOT NULL THEN
                l_json_obj.put('tenant.name', g_current_tenant_name);
            END IF;
        END IF;

        -- Process user-provided attributes
        IF p_attributes.COUNT > 0 THEN
            FOR i IN p_attributes.FIRST .. p_attributes.LAST LOOP
                IF p_attributes.EXISTS(i) AND p_attributes(i) IS NOT NULL THEN
                    -- Parse key=value
                    l_pos := INSTR(p_attributes(i), '=');

                    IF l_pos > 0 THEN
                        l_key := SUBSTR(p_attributes(i), 1, l_pos - 1);
                        l_value := SUBSTR(p_attributes(i), l_pos + 1);

                        -- Skip if trying to override tenant context
                        IF l_key NOT IN ('tenant.id', 'tenant.name') THEN
                            -- Unescape our format
                            l_value := REPLACE(l_value, '\=', CHR(1));  -- Temporal marker
                            l_value := REPLACE(l_value, '\\', '\');
                            l_value := REPLACE(l_value, CHR(1), '=');

                            -- Add to JSON object
                            l_json_obj.put(l_key, l_value);
                        END IF;
                    END IF;
                END IF;
            END LOOP;
        END IF;

        RETURN l_json_obj.to_string();
    EXCEPTION
        WHEN OTHERS THEN
            -- Return minimal valid JSON with error info
            RETURN '{"_error":"' || REPLACE(SUBSTR(DBMS_UTILITY.format_error_stack, 1, 100), '"', '\"') || '"}';
    END attributes_to_json;

    --------------------------------------------------------------------------
    -- BACKEND COMMUNICATION
    --------------------------------------------------------------------------

    /**
    * Sends telemetry data synchronously via HTTP with pulse throttling
    * Updated to respect pulse mode capacity and apply intelligent retry logic
    */
    PROCEDURE send_to_backend_sync (p_json VARCHAR2)
    IS
        l_req           UTL_HTTP.REQ;
        l_res           UTL_HTTP.RESP;
        l_buffer        VARCHAR2(32767);
        l_length        NUMBER;
        l_offset        NUMBER := 1;
        l_amount        NUMBER;
        l_error_msg     VARCHAR2(4000);
        l_response_body VARCHAR2(4000) := '';
        l_chunk         VARCHAR2(32767);
        l_current_mode  VARCHAR2(50);
        l_effective_backend VARCHAR2(500);
        l_pulse_mode    VARCHAR2(10);
        l_config        plt_pulse_config_t;
        l_timeout       NUMBER;
        l_chunk_size    NUMBER;
        l_retry_delay   NUMBER;
        l_start_time    TIMESTAMP := SYSTIMESTAMP;
        l_end_time      TIMESTAMP;
        l_duration_ms   NUMBER;
    BEGIN
        -- Validate input
        IF p_json IS NULL THEN
            RETURN;
        END IF;

        -- ========================================================================
        -- PULSE THROTTLING ANALYSIS AND CONFIGURATION
        -- ========================================================================
        
        -- Get current pulse mode and configuration
        l_pulse_mode := get_agent_pulse_mode();
        l_config := get_pulse_throttling_config(l_pulse_mode);
        
        -- Apply pulse-aware timeout adjustments
        l_timeout := CASE l_pulse_mode
            WHEN 'PULSE1' THEN NVL(g_backend_timeout, 30)        -- Normal timeout
            WHEN 'PULSE2' THEN NVL(g_backend_timeout, 30) * 1.5  -- 50% longer timeout
            WHEN 'PULSE3' THEN NVL(g_backend_timeout, 30) * 2    -- Double timeout
            WHEN 'PULSE4' THEN NVL(g_backend_timeout, 30) * 3    -- Triple timeout
            WHEN 'COMA'   THEN NVL(g_backend_timeout, 30) * 5    -- Very long timeout (if processing at all)
            ELSE NVL(g_backend_timeout, 30)
        END;
        
        -- Apply pulse-aware chunk size (smaller chunks in throttled modes)
        l_chunk_size := CASE l_pulse_mode
            WHEN 'PULSE1' THEN 32767
            WHEN 'PULSE2' THEN 16384  -- 16KB chunks
            WHEN 'PULSE3' THEN 8192   -- 8KB chunks
            WHEN 'PULSE4' THEN 4096   -- 4KB chunks
            WHEN 'COMA'   THEN 2048   -- 2KB chunks
            ELSE 32767
        END;
        
        -- Calculate retry delay based on pulse mode
        l_retry_delay := CASE l_pulse_mode
            WHEN 'PULSE1' THEN 0.1    -- 100ms
            WHEN 'PULSE2' THEN 0.2    -- 200ms
            WHEN 'PULSE3' THEN 0.5    -- 500ms
            WHEN 'PULSE4' THEN 1.0    -- 1 second
            WHEN 'COMA'   THEN 2.0    -- 2 seconds
            ELSE 0.1
        END;

        -- ========================================================================
        -- BACKEND SELECTION WITH PULSE AWARENESS
        -- ========================================================================
        
        -- Check if we're in fallback mode
        l_current_mode := get_processing_mode();
        
        -- Determine which backend to use with pulse context
        IF l_current_mode = 'ORACLE_FALLBACK' THEN
            -- Use the fallback backend (OTLP Bridge by default)
            l_effective_backend := NVL(get_failover_config('FALLBACK_BACKEND'), 'OTLP_BRIDGE');
            
            IF l_effective_backend = 'OTLP_BRIDGE' THEN

                -- Route through OTLP Bridge with pulse-aware configuration
                BEGIN
                    -- Configure OTLP Bridge for current pulse mode
                    PLT_OTLP_BRIDGE.set_timeout(TRUNC(l_timeout));
                    --PLT_OTLP_BRIDGE.set_debug_mode(l_pulse_mode IN ('PULSE4', 'COMA'));
                    
                    PLT_OTLP_BRIDGE.route_to_otlp(p_json);

                    RETURN;
                EXCEPTION
                    WHEN OTHERS THEN
                        
                        l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                        log_error_internal('send_to_backend_sync', 
                            'OTLP bridge routing failed in fallback mode (Pulse: ' || l_pulse_mode || '): ' || l_error_msg);
                        RETURN;
                END;
            ELSE
                -- Fallback might be configured to use a different backend
                l_effective_backend := l_effective_backend;
            END IF;
        ELSE
            -- Normal mode - use configured backend
            l_effective_backend := g_backend_url;

        END IF;

        -- ========================================================================
        -- BRIDGE SUPPORT WITH PULSE CONTEXT
        -- ========================================================================
        
        IF l_effective_backend = 'POSTGRES_BRIDGE' THEN
            BEGIN
                PLT_POSTGRES_BRIDGE.send_to_backend_with_routing(p_json);
                RETURN;
            EXCEPTION
                WHEN OTHERS THEN
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                    log_error_internal('send_to_backend_sync', 
                        'Postgres bridge routing failed (Pulse: ' || l_pulse_mode || '): ' || l_error_msg);
                    RETURN;
            END;
        ELSIF l_effective_backend = 'OTLP_BRIDGE' THEN
            BEGIN
                -- Configure OTLP Bridge for current pulse mode
                PLT_OTLP_BRIDGE.set_timeout(TRUNC(l_timeout));
                --PLT_OTLP_BRIDGE.set_debug_mode(l_pulse_mode IN ('PULSE4', 'COMA'));
                
                PLT_OTLP_BRIDGE.route_to_otlp(p_json);
                RETURN;
            EXCEPTION
                WHEN OTHERS THEN
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                    log_error_internal('send_to_backend_sync', 
                        'OTLP bridge routing failed (Pulse: ' || l_pulse_mode || '): ' || l_error_msg);
                    RETURN;
            END;
        END IF;

        -- ========================================================================
        -- HTTP TRANSMISSION WITH PULSE THROTTLING
        -- ========================================================================
        
        -- Get length and validate URL (for HTTP backends)
        l_length := LENGTH(p_json);

        IF l_effective_backend IS NULL OR LENGTH(l_effective_backend) < 10 THEN
            log_error_internal('send_to_backend_sync', 
                'Invalid backend URL configured (Pulse: ' || l_pulse_mode || '): ' || NVL(l_effective_backend, 'NULL'));
            RETURN;
        END IF;

        -- Add pre-transmission delay in high-throttling modes
        IF l_pulse_mode IN ('PULSE4', 'COMA') THEN
            DBMS_LOCK.SLEEP(l_retry_delay * 0.1); -- Small delay before even starting
        END IF;

        -- Set timeout and begin request with pulse-aware settings
        UTL_HTTP.SET_TRANSFER_TIMEOUT(l_timeout);
        l_req := UTL_HTTP.BEGIN_REQUEST(l_effective_backend, 'POST', 'HTTP/1.1');

        -- Set headers with pulse context
        UTL_HTTP.SET_HEADER(l_req, 'Content-Type', 'application/json; charset=utf-8');
        UTL_HTTP.SET_HEADER(l_req, 'Content-Length', LENGTHB(p_json));
        UTL_HTTP.SET_HEADER(l_req, 'User-Agent', 'PLTelemetry-Pulse-' || l_pulse_mode);
        UTL_HTTP.SET_HEADER(l_req, 'X-OTel-Source', 'PLTelemetry');
        UTL_HTTP.SET_HEADER(l_req, 'X-PLSQL-API-KEY', NVL(g_api_key, 'not-configured'));
        UTL_HTTP.SET_HEADER(l_req, 'X-PLSQL-DB', SYS_CONTEXT('USERENV', 'DB_NAME'));
        UTL_HTTP.SET_HEADER(l_req, 'X-PLT-Pulse-Mode', l_pulse_mode);
        UTL_HTTP.SET_HEADER(l_req, 'X-PLT-Capacity', TO_CHAR(l_config.capacity_multiplier, 'FM0.9999'));

        -- Send data with pulse-aware chunking
        IF l_length <= l_chunk_size THEN
            UTL_HTTP.WRITE_TEXT(l_req, p_json);
        ELSE
            -- Send in pulse-aware chunks with optional delays
            WHILE l_offset <= l_length LOOP
                l_amount := LEAST(l_chunk_size, l_length - l_offset + 1);
                l_buffer := SUBSTR(p_json, l_offset, l_amount);
                UTL_HTTP.WRITE_TEXT(l_req, l_buffer);
                l_offset := l_offset + l_amount;
                
                -- Add micro-delay between chunks in throttled modes
                IF l_pulse_mode IN ('PULSE3', 'PULSE4', 'COMA') AND l_offset <= l_length THEN
                    DBMS_LOCK.SLEEP(0.001); -- 1ms delay between chunks
                END IF;
            END LOOP;
        END IF;

        l_res := UTL_HTTP.GET_RESPONSE(l_req);

        -- ========================================================================
        -- RESPONSE HANDLING WITH PULSE CONTEXT
        -- ========================================================================
        
        -- Calculate duration for metrics
        l_end_time := SYSTIMESTAMP;
        l_duration_ms := EXTRACT(SECOND FROM (l_end_time - l_start_time)) * 1000;

        -- Check response status with pulse-aware error handling
        IF l_res.status_code NOT IN (200, 201, 202, 204) THEN
            -- Read response body
            BEGIN
                LOOP
                    UTL_HTTP.READ_TEXT(l_res, l_chunk, 32767);
                    l_response_body := l_response_body || l_chunk;
                END LOOP;
            EXCEPTION
                WHEN UTL_HTTP.END_OF_BODY THEN
                    NULL;
            END;
            
            -- Log failed export with pulse context
            INSERT INTO plt_failed_exports (
                export_time,
                http_status,
                payload,
                error_message
            ) VALUES (
                SYSTIMESTAMP,
                l_res.status_code,
                SUBSTR(p_json, 1, 4000),
                'HTTP ' || l_res.status_code || ': ' || SUBSTR(l_response_body, 1, 3000) ||
                ' (Pulse: ' || l_pulse_mode || ', Duration: ' || ROUND(l_duration_ms, 1) || 'ms)'
            );
        END IF;

        UTL_HTTP.END_RESPONSE(l_res);

        -- ========================================================================
        -- PULSE PERFORMANCE METRICS
        -- ========================================================================
        
        -- Record pulse-aware performance metrics (sampled)
        IF should_process_telemetry('METRICS') AND MOD(EXTRACT(SECOND FROM SYSTIMESTAMP), 30) = 0 THEN
            BEGIN
                log_metric(
                    p_metric_name => 'pltelemetry.http.request_duration',
                    p_value => l_duration_ms,
                    p_unit => 'ms',
                    p_include_trace_correlation => FALSE
                );
                
                log_metric(
                    p_metric_name => 'pltelemetry.http.payload_size',
                    p_value => l_length,
                    p_unit => 'bytes',
                    p_include_trace_correlation => FALSE
                );
                
                -- Pulse effectiveness metric
                log_metric(
                    p_metric_name => 'pltelemetry.http.pulse_timeout_used',
                    p_value => l_timeout,
                    p_unit => 'seconds',
                    p_include_trace_correlation => FALSE
                );
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- Don't fail on metrics
            END;
        END IF;

        IF g_autocommit THEN
            COMMIT;
        END IF;

    -- Fix for send_to_backend_sync() - UTL_HTTP resource protection
    -- Replace the existing exception handling block with this:

    EXCEPTION
        WHEN UTL_HTTP.TRANSFER_TIMEOUT THEN
            l_error_msg := 'Backend timeout after ' || l_timeout || ' seconds (Pulse: ' || l_pulse_mode || ')';
            
            -- Clean up resources properly
            BEGIN
                UTL_HTTP.END_RESPONSE(l_res);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            
            BEGIN
                UTL_HTTP.END_REQUEST(l_req);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;

            -- Log timeout with pulse context
            INSERT INTO plt_failed_exports (export_time, payload, error_message)
            VALUES (SYSTIMESTAMP, SUBSTR(p_json, 1, 4000), l_error_msg);

            -- Add retry delay in throttled modes
            IF l_pulse_mode IN ('PULSE3', 'PULSE4', 'COMA') THEN
                DBMS_LOCK.SLEEP(l_retry_delay);
            END IF;

            IF g_autocommit THEN
                COMMIT;
            END IF;

        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

            -- Clean up resources properly
            BEGIN
                UTL_HTTP.END_RESPONSE(l_res);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            
            BEGIN
                UTL_HTTP.END_REQUEST(l_req);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;

            -- Log error with pulse context
            INSERT INTO plt_failed_exports (
                export_time,
                payload,
                error_message,
                http_status
            ) VALUES (
                SYSTIMESTAMP,
                SUBSTR(p_json, 1, 4000),
                'Error (Pulse: ' || l_pulse_mode || ', Duration: ' || 
                EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000 || 'ms): ' || l_error_msg,
                -1
            );

            -- Add retry delay in throttled modes
            IF l_pulse_mode IN ('PULSE3', 'PULSE4', 'COMA') THEN
                DBMS_LOCK.SLEEP(l_retry_delay);
            END IF;

            IF g_autocommit THEN
                COMMIT;
            END IF;
    END send_to_backend_sync;

    /**
    * Sends telemetry data to the configured backend
    * Updated with pulse throttling and intelligent queuing decisions
    */
    PROCEDURE send_to_backend (p_json VARCHAR2)
    IS
        l_error_msg    VARCHAR2(4000);
        l_data_type    VARCHAR2(20);
        l_pulse_mode   VARCHAR2(10);
        l_should_queue BOOLEAN := FALSE;
        l_config       plt_pulse_config_t;
        l_payload_size NUMBER;
    BEGIN
        IF p_json IS NULL THEN
            RETURN;
        END IF;

        -- ========================================================================
        -- PULSE THROTTLING ANALYSIS
        -- ========================================================================
        
        -- Get current pulse mode and configuration
        l_pulse_mode := get_agent_pulse_mode();
        l_config := get_pulse_throttling_config(l_pulse_mode);
        l_payload_size := LENGTH(p_json);
        
        -- Determine data type for intelligent routing
        l_data_type := CASE 
            WHEN p_json LIKE '%"duration_ms"%' THEN 'SPAN'
            WHEN p_json LIKE '%"name"%' AND p_json LIKE '%"value"%' THEN 'METRIC'
            WHEN p_json LIKE '%"severity"%' AND p_json LIKE '%"message"%' THEN 'LOG'
            ELSE 'OTHER'
        END;
        
        -- Apply telemetry type throttling
        IF NOT should_process_telemetry(l_data_type) THEN
            -- In COMA mode or if this telemetry type is disabled, drop silently
            -- Only log if in debug mode and not in COMA (to avoid log spam)
            IF l_pulse_mode != 'COMA' THEN
                log_error_internal('send_to_backend', 
                    'Telemetry type ' || l_data_type || ' dropped due to pulse throttling: ' || l_pulse_mode);
            END IF;
            RETURN;
        END IF;
        
        -- ========================================================================
        -- INTELLIGENT QUEUING DECISIONS BASED ON PULSE MODE
        -- ========================================================================
        
        -- In low capacity modes, prefer async to reduce immediate load
        l_should_queue := CASE
            WHEN l_pulse_mode IN ('PULSE4', 'COMA') THEN TRUE  -- Always queue in critical modes
            WHEN l_pulse_mode = 'PULSE3' AND l_payload_size > 1000 THEN TRUE  -- Queue large payloads
            WHEN l_pulse_mode = 'PULSE2' AND l_payload_size > 2000 THEN TRUE  -- Queue very large payloads
            ELSE g_async_mode  -- Use configured mode for normal operation
        END;

        -- ========================================================================
        -- BRIDGE-SPECIFIC HANDLING WITH THROTTLING
        -- ========================================================================
        
        -- Bridge-specific async handling with pulse awareness
        IF g_backend_url = 'POSTGRES_BRIDGE' AND l_should_queue THEN
            -- Queue with priority adjusted by pulse mode
            BEGIN
                INSERT INTO plt_queue (
                    payload,
                    process_attempts,
                    created_at
                ) VALUES (
                    p_json,
                    CASE l_data_type
                        WHEN 'SPAN' THEN 0
                        WHEN 'METRIC' THEN 1
                        ELSE 2
                    END + CASE l_pulse_mode  -- Adjust priority by pulse mode
                        WHEN 'PULSE1' THEN 0
                        WHEN 'PULSE2' THEN 0
                        WHEN 'PULSE3' THEN 1
                        WHEN 'PULSE4' THEN 2
                        WHEN 'COMA' THEN 3
                        ELSE 0
                    END,
                    SYSTIMESTAMP
                );

                IF g_autocommit THEN
                    COMMIT;
                END IF;
                RETURN;
            EXCEPTION
                WHEN OTHERS THEN
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                    log_error_internal('send_to_backend', 
                        'Failed to queue for bridge (Pulse: ' || l_pulse_mode || '), falling back to sync: ' || l_error_msg);
                    send_to_backend_sync(p_json);
                    RETURN;
            END;
        END IF;

        -- ========================================================================
        -- STANDARD ASYNC/SYNC LOGIC WITH PULSE THROTTLING
        -- ========================================================================
        
        -- Standard async/sync logic with pulse-aware decisions
        IF l_should_queue THEN
            BEGIN
                INSERT INTO plt_queue (
                    payload,
                    created_at
                ) VALUES (
                    p_json,
                    SYSTIMESTAMP
                );
                
                IF g_autocommit THEN
                    COMMIT;
                END IF;
                
                -- In high-throttling modes, add a small delay to reduce burst load
                IF l_pulse_mode IN ('PULSE4', 'COMA') THEN
                    -- Add microsecond delay to spread load (Oracle 11g+ compatible)
                    DBMS_LOCK.SLEEP(0.001); -- 1ms delay
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                    log_error_internal('send_to_backend', 
                        'Failed to queue telemetry (Pulse: ' || l_pulse_mode || '), falling back to sync: ' || l_error_msg);
                    send_to_backend_sync(p_json);
            END;
        ELSE
            -- Send synchronously but with pulse context
            send_to_backend_sync(p_json);
        END IF;

        -- ========================================================================
        -- PULSE THROTTLING METRICS (SELF-MONITORING)
        -- ========================================================================
        
        -- Record throttling effectiveness (only if metrics enabled and not in COMA)
        IF should_process_telemetry('METRICS') AND l_pulse_mode != 'COMA' THEN
            BEGIN
                -- Only sample these internal metrics to avoid recursion
                IF MOD(EXTRACT(SECOND FROM SYSTIMESTAMP), 30) = 0 THEN -- Every 30 seconds
                    INSERT INTO plt_metrics (
                        metric_name,
                        metric_value,
                        metric_unit,
                        timestamp,
                        attributes
                    ) VALUES (
                        'pltelemetry.backend.payload_size',
                        l_payload_size,
                        'bytes',
                        SYSTIMESTAMP,
                        '{"pulse_mode":"' || l_pulse_mode || 
                        '","data_type":"' || l_data_type || 
                        '","queued":"' || CASE WHEN l_should_queue THEN 'true' ELSE 'false' END || '"}'
                    );
                    
                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- Don't fail on self-monitoring
            END;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('send_to_backend', 
                'Critical error in send_to_backend (Pulse: ' || get_agent_pulse_mode() || '): ' || l_error_msg);
    END send_to_backend;

    /**
    * Processes queued telemetry data in batches with pulse throttling
    * Updated to respect agent pulse mode and apply coordinated throttling
    */
    PROCEDURE process_queue (p_batch_size NUMBER DEFAULT 100)
    IS
        l_processed_count   NUMBER := 0;
        l_error_count       NUMBER := 0;
        l_error_msg         VARCHAR2(4000);
        l_effective_batch   NUMBER;
        l_pulse_mode        VARCHAR2(10);
        l_order_clause      VARCHAR2(200);
        l_sql               VARCHAR2(1000);
        
        TYPE t_queue_cursor IS REF CURSOR;
        l_cursor            t_queue_cursor;
        l_queue_id          NUMBER;
        l_payload           VARCHAR2(4000);
        
    BEGIN
        -- ========================================================================
        -- PULSE THROTTLING INTEGRATION
        -- ========================================================================
        
        -- Check if queue processing is enabled for current pulse mode
        IF NOT should_process_telemetry('QUEUE') THEN
            log_error_internal('process_queue', 
                'Queue processing disabled for current pulse mode: ' || get_agent_pulse_mode());
            RETURN;
        END IF;
        
        -- Get effective batch size based on pulse throttling
        l_effective_batch := get_effective_batch_size(NVL(NULLIF(p_batch_size, 0), 100));
        l_pulse_mode := get_agent_pulse_mode();
        
        -- Log throttling application
        IF l_effective_batch != NVL(p_batch_size, 100) THEN
            log_error_internal('process_queue', 
                'Pulse throttling applied - Original: ' || NVL(p_batch_size, 100) || 
                ', Effective: ' || l_effective_batch || 
                ', Mode: ' || l_pulse_mode);
        END IF;

        -- ========================================================================
        -- EXISTING LOGIC WITH THROTTLED BATCH SIZE
        -- ========================================================================
        
        -- Determine ordering strategy (existing logic)
        l_order_clause := CASE 
            WHEN g_backend_url = 'POSTGRES_BRIDGE' THEN 'ORDER BY process_attempts, queue_id'
            ELSE 'ORDER BY queue_id'
        END;

        -- Build dynamic SQL with effective batch size
        l_sql := 'SELECT queue_id, payload ' ||
                'FROM ( ' ||
                    'SELECT queue_id, payload, process_attempts ' ||
                    'FROM plt_queue ' ||
                    'WHERE processed = ''N'' ' ||
                    '  AND process_attempts < 5 ' ||
                    l_order_clause ||
                ') ' ||
                'WHERE ROWNUM <= :batch_size';

        -- Process items with throttled batch size
        OPEN l_cursor FOR l_sql USING l_effective_batch;
        
        LOOP
            FETCH l_cursor INTO l_queue_id, l_payload;
            EXIT WHEN l_cursor%NOTFOUND;
            
            BEGIN
                -- Increment attempt counter
                UPDATE plt_queue
                SET process_attempts = process_attempts + 1,
                    last_attempt_time = SYSTIMESTAMP
                WHERE queue_id = l_queue_id
                AND processed = 'N';

                IF SQL%ROWCOUNT = 1 THEN
                    -- Send payload (this will also respect pulse throttling in send_to_backend_sync)
                    send_to_backend_sync(l_payload);

                    -- Mark as processed
                    UPDATE plt_queue
                    SET processed = 'Y',
                        processed_time = SYSTIMESTAMP
                    WHERE queue_id = l_queue_id;

                    l_processed_count := l_processed_count + 1;
                END IF;

                IF g_autocommit THEN
                    COMMIT;
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
                    l_error_count := l_error_count + 1;

                    UPDATE plt_queue
                    SET last_error = l_error_msg
                    WHERE queue_id = l_queue_id;

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
            END;
        END LOOP;
        
        CLOSE l_cursor;

        -- ========================================================================
        -- THROTTLING-AWARE SUMMARY LOGGING
        -- ========================================================================
        
        -- Summary logging with pulse mode context
        IF l_processed_count > 0 OR l_error_count > 0 THEN
            log_error_internal(
                'process_queue',
                'Queue processed: ' || l_processed_count || ' success, ' || l_error_count || ' errors' ||
                ' (Pulse: ' || l_pulse_mode || ', Batch: ' || l_effective_batch || ')'
            );
            
            -- Send throttling metrics (only if metrics are enabled for current pulse)
            IF should_process_telemetry('METRICS') THEN
                -- Record throttling effectiveness
                log_metric(
                    p_metric_name => 'pltelemetry.queue.effective_batch_size',
                    p_value => l_effective_batch,
                    p_unit => 'items',
                    p_include_trace_correlation => FALSE
                );
                
                log_metric(
                    p_metric_name => 'pltelemetry.queue.items_processed',
                    p_value => l_processed_count,
                    p_unit => 'items',
                    p_include_trace_correlation => FALSE
                );
                
                -- Pulse mode tracking metric
                log_metric(
                    p_metric_name => 'pltelemetry.pulse.current_mode',
                    p_value => CASE l_pulse_mode
                        WHEN 'PULSE1' THEN 1
                        WHEN 'PULSE2' THEN 2  
                        WHEN 'PULSE3' THEN 3
                        WHEN 'PULSE4' THEN 4
                        WHEN 'COMA' THEN 0
                        ELSE -1
                    END,
                    p_unit => 'mode',
                    p_include_trace_correlation => FALSE
                );
            END IF;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            IF l_cursor%ISOPEN THEN
                CLOSE l_cursor;
            END IF;
            
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('process_queue', 
                'Process queue error (Pulse: ' || get_agent_pulse_mode() || '): ' || l_error_msg);
    END process_queue;

    --------------------------------------------------------------------------
    -- TRACE MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * Starts a new trace with the given operation name
     */
    FUNCTION start_trace (p_operation VARCHAR2)
        RETURN VARCHAR2
    IS
        l_trace_id      VARCHAR2(32);
        l_operation     VARCHAR2(255);
        l_retry_count   NUMBER := 0;
        l_max_retries   CONSTANT NUMBER := 3;
        l_error_msg     VARCHAR2(4000);
    BEGIN
        -- Normalize & validate input parameters
        l_operation := normalize_string(p_operation, p_max_length => 255, p_allow_null => FALSE);
        
        IF l_operation IS NULL OR LENGTH(l_operation) = 0 THEN
            RAISE_APPLICATION_ERROR(-20102, 'Operation name cannot be null or empty');
        END IF;
        
        LOOP
            BEGIN
                l_trace_id := generate_trace_id();
                set_internal_trace_context(l_trace_id, NULL);
                set_trace_context();

                INSERT INTO plt_traces (
                    trace_id,
                    root_operation,
                    start_time,
                    service_name,
                    service_instance
                ) VALUES (
                    l_trace_id,
                    l_operation,  -- Using normalized operation
                    SYSTIMESTAMP,
                    'oracle-plsql',
                    SYS_CONTEXT('USERENV', 'HOST') || ':' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME')
                );

                IF g_autocommit THEN
                    COMMIT;
                END IF;
                
                RETURN l_trace_id;
                
            EXCEPTION
                WHEN DUP_VAL_ON_INDEX THEN
                    l_retry_count := l_retry_count + 1;
                    IF l_retry_count < l_max_retries THEN
                        NULL; -- Retry with new ID
                    ELSE
                        l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                        log_error_internal('start_trace', l_error_msg, l_trace_id);
                        RETURN l_trace_id; -- Return anyway
                    END IF;
                WHEN OTHERS THEN
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                    log_error_internal('start_trace', l_error_msg, l_trace_id);
                    RETURN l_trace_id; -- Return anyway
            END;
        END LOOP;
    END start_trace;

    /**
     * Ends the current trace and clears context
     */
    PROCEDURE end_trace(p_trace_id VARCHAR2 DEFAULT NULL) 
    IS
        l_trace_id VARCHAR2(32);
    BEGIN
        l_trace_id := NVL(p_trace_id, g_current_trace_id);
        
        IF l_trace_id IS NOT NULL THEN
            UPDATE plt_traces
            SET end_time = SYSTIMESTAMP
            WHERE trace_id = l_trace_id
              AND end_time IS NULL;
            
            IF l_trace_id = g_current_trace_id THEN
                clear_trace_context();
            END IF;
            
            IF g_autocommit THEN
                COMMIT;
            END IF;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Never fail on trace cleanup
    END end_trace;

    /**
     * Continue an existing trace from an external system
     */
    FUNCTION continue_distributed_trace(
        p_trace_id   VARCHAR2,
        p_operation  VARCHAR2,
        p_tenant_id  VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2
    IS
        l_span_id    VARCHAR2(16);
        l_trace_id   VARCHAR2(32);
        l_operation  VARCHAR2(255);
        l_tenant_id  VARCHAR2(100);
        l_error_msg  VARCHAR2(4000);
    BEGIN
        -- Normalize & validate input parameters
        l_trace_id := normalize_string(p_trace_id, p_max_length => 32, p_allow_null => FALSE);
        l_operation := normalize_string(p_operation, p_max_length => 255, p_allow_null => FALSE);
        l_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => TRUE);
        
        -- Validate input
        IF l_trace_id IS NULL OR LENGTH(l_trace_id) != 32 THEN
            RAISE_APPLICATION_ERROR(-20100, 'Invalid trace_id: must be 32 character hex string');
        END IF;
        
        IF l_operation IS NULL OR LENGTH(l_operation) = 0 THEN
            RAISE_APPLICATION_ERROR(-20101, 'Operation name is required');
        END IF;
        
        -- Set context and start span
        set_internal_trace_context(l_trace_id, NULL);
        l_span_id := start_span(l_operation, NULL, l_trace_id);
        
        -- Add distributed tracing attributes
        BEGIN
            INSERT INTO plt_span_attributes (span_id, attribute_key, attribute_value)
            VALUES (l_span_id, 'trace.distributed', 'true');
            
            INSERT INTO plt_span_attributes (span_id, attribute_key, attribute_value)
            VALUES (l_span_id, 'system.name', 'oracle-plsql');
            
            IF l_tenant_id IS NOT NULL THEN
                INSERT INTO plt_span_attributes (span_id, attribute_key, attribute_value)
                VALUES (l_span_id, 'tenant.id', l_tenant_id);
            END IF;
            
            INSERT INTO plt_span_attributes (span_id, attribute_key, attribute_value)
            VALUES (l_span_id, 'db.name', SYS_CONTEXT('USERENV', 'DB_NAME'));
            
            INSERT INTO plt_span_attributes (span_id, attribute_key, attribute_value)
            VALUES (l_span_id, 'db.user', SYS_CONTEXT('USERENV', 'SESSION_USER'));
            
            IF g_autocommit THEN
                COMMIT;
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                log_error_internal('continue_distributed_trace', 'Failed to add distributed trace attributes: ' || l_error_msg, l_trace_id, l_span_id);
        END;
        
        -- Log the continuation
        DECLARE
            l_attrs t_attributes;
        BEGIN
            l_attrs(1) := add_attribute('trace.source', 'external');
            l_attrs(2) := add_attribute('system.previous', 'oracle-forms');
            l_attrs(3) := add_attribute('tenant.id', NVL(l_tenant_id, 'default'));
            add_event(l_span_id, 'distributed_trace_continued', l_attrs);
        END;
        
        RETURN l_span_id;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('continue_distributed_trace', l_error_msg, l_trace_id);
            
            -- Still try to create a basic span
            BEGIN
                l_span_id := generate_span_id();
                set_internal_trace_context(l_trace_id, l_span_id);
                RETURN l_span_id;
            EXCEPTION
                WHEN OTHERS THEN
                    RETURN 'error_span_' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS');
            END;
    END continue_distributed_trace;

    /**
     * Get trace context for passing to external systems
     */
    FUNCTION get_trace_context
    RETURN VARCHAR2
    IS
        l_context JSON_OBJECT_T;
        l_tenant_id VARCHAR2(100);
    BEGIN
        l_context := JSON_OBJECT_T();
        l_context.put('trace_id', NVL(g_current_trace_id, ''));
        l_context.put('span_id', NVL(g_current_span_id, ''));
        l_context.put('system', 'oracle-plsql');
        l_context.put('timestamp', TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
        l_context.put('db_name', SYS_CONTEXT('USERENV', 'DB_NAME'));
        
        -- Add tenant if configured
        BEGIN
            SELECT attribute_value
            INTO l_tenant_id
            FROM plt_span_attributes
            WHERE span_id = g_current_span_id
              AND attribute_key = 'tenant.id'
              AND ROWNUM = 1;
            
            l_context.put('tenant_id', l_tenant_id);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                NULL; -- No tenant configured
            WHEN OTHERS THEN
                NULL; -- Don't fail on tenant lookup
        END;
        
        RETURN l_context.to_string();
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Return minimal context on error
            RETURN '{"trace_id":"' || NVL(g_current_trace_id, 'error') || 
                   '","system":"oracle-plsql","error":"context_failed"}';
    END get_trace_context;

    --------------------------------------------------------------------------
    -- SPAN MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * Starts a new span within a trace
     */
    FUNCTION start_span (p_operation VARCHAR2, p_parent_span_id VARCHAR2 DEFAULT NULL, p_trace_id VARCHAR2 DEFAULT NULL)
        RETURN VARCHAR2
    IS
        l_span_id       VARCHAR2(16);
        l_trace_id      VARCHAR2(32);
        l_operation     VARCHAR2(255);
        l_parent_span_id VARCHAR2(16);
        l_retry_count   NUMBER := 0;
        l_max_retries   CONSTANT NUMBER := 3;
        l_error_msg     VARCHAR2(4000);
    BEGIN
        -- Normalize & validate input parameters
        l_operation := normalize_string(p_operation, p_max_length => 255, p_allow_null => FALSE);
        l_parent_span_id := normalize_string(p_parent_span_id, p_max_length => 16, p_allow_null => TRUE);
        l_trace_id := normalize_string(p_trace_id, p_max_length => 32, p_allow_null => TRUE);
        
        IF l_operation IS NULL OR LENGTH(l_operation) = 0 THEN
            RAISE_APPLICATION_ERROR(-20103, 'Operation name cannot be null or empty');
        END IF;
        
        LOOP
            BEGIN
                l_span_id := generate_span_id();
                
                -- Use provided trace_id or current one
                l_trace_id := NVL(l_trace_id, NVL(g_current_trace_id, generate_trace_id()));
                set_internal_trace_context(l_trace_id, l_span_id);
                set_trace_context();

                INSERT INTO plt_spans (
                    trace_id,
                    span_id,
                    parent_span_id,
                    operation_name,
                    start_time,
                    status
                ) VALUES (
                    l_trace_id,
                    l_span_id,
                    l_parent_span_id,
                    l_operation,  -- Using normalized operation
                    SYSTIMESTAMP,
                    'RUNNING'
                );

                IF g_autocommit THEN
                    COMMIT;
                END IF;

                RETURN l_span_id;
                
            EXCEPTION
                WHEN DUP_VAL_ON_INDEX THEN
                    l_retry_count := l_retry_count + 1;
                    IF l_retry_count < l_max_retries THEN
                        NULL; -- Retry with new span_id
                    ELSE
                        l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                        log_error_internal('start_span', l_error_msg, l_trace_id, l_span_id);
                        set_internal_trace_context(l_trace_id, l_span_id);
                        RETURN l_span_id;
                    END IF;
                WHEN OTHERS THEN
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                    log_error_internal('start_span', l_error_msg, l_trace_id, l_span_id);
                    set_internal_trace_context(l_trace_id, l_span_id);
                    RETURN l_span_id;
            END;
        END LOOP;
    END start_span;

    /**
     * Ends an active span and records its duration
     */
    PROCEDURE end_span (p_span_id VARCHAR2, p_status VARCHAR2 DEFAULT 'OK', p_attributes t_attributes DEFAULT t_attributes())
    IS
        l_json           VARCHAR2(32767);
        l_duration       NUMBER;
        l_attrs_json     VARCHAR2(4000);
        l_events_json    VARCHAR2(4000);
        l_start_time     TIMESTAMP WITH TIME ZONE;
        l_operation_name VARCHAR2(255);
        l_error_msg      VARCHAR2(4000);
        l_parent_span_id VARCHAR2(16);
        l_span_id        VARCHAR2(16);
        l_status         VARCHAR2(50);
    BEGIN
        -- Normalize & validate input parameters
        l_span_id := normalize_string(p_span_id, p_max_length => 16, p_allow_null => FALSE);
        l_status := normalize_string(p_status, p_max_length => 50, p_allow_null => TRUE);
        
        IF l_span_id IS NULL THEN
            RETURN;
        END IF;
        
        l_status := NVL(l_status, 'OK');

        -- Get span info and calculate duration
        BEGIN
            SELECT start_time, operation_name, parent_span_id,
                   EXTRACT(SECOND FROM (SYSTIMESTAMP - start_time)) * 1000
            INTO l_start_time, l_operation_name, l_parent_span_id, l_duration
            FROM plt_spans
            WHERE span_id = l_span_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                log_error_internal('end_span', 'Span not found', NULL, l_span_id);
                RETURN;
            WHEN TOO_MANY_ROWS THEN
                l_duration := 0;
                l_operation_name := 'unknown_operation';
        END;

        -- Update span
        UPDATE plt_spans
        SET end_time = SYSTIMESTAMP, duration_ms = l_duration, status = l_status
        WHERE span_id = l_span_id AND end_time IS NULL;

        IF SQL%ROWCOUNT = 0 THEN
            log_error_internal('end_span', 'Span already ended or not found', NULL, l_span_id);
            RETURN;
        END IF;

        -- Update trace end time if all spans are complete
        UPDATE plt_traces
        SET end_time = SYSTIMESTAMP
        WHERE trace_id = g_current_trace_id
          AND NOT EXISTS (
              SELECT 1 FROM plt_spans
              WHERE trace_id = g_current_trace_id 
                AND span_id != l_span_id 
                AND end_time IS NULL
          );

        -- Build attributes JSON
        l_attrs_json := attributes_to_json(p_attributes);

        -- Build events JSON
        BEGIN
            SELECT JSON_ARRAYAGG(
                JSON_OBJECT(
                    'name' VALUE event_name,
                    'time' VALUE TO_CHAR(event_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'),
                    'attributes' VALUE CASE 
                        WHEN attributes IS NOT NULL AND attributes != '{}' 
                        THEN attributes
                        ELSE JSON_OBJECT()
                    END
                )
                ORDER BY event_time
            ) INTO l_events_json
            FROM plt_events 
            WHERE span_id = l_span_id;
            
            IF l_events_json IS NULL THEN
                l_events_json := '[]';
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                l_events_json := '[]';
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
                log_error_internal('end_span', 'Failed to build events JSON: ' || l_error_msg, NULL, l_span_id);
        END;

        -- Build complete JSON
        l_json := '{'
            || '"trace_id":"' || NVL(g_current_trace_id, 'unknown') || '",'
            || '"span_id":"' || l_span_id || '",'
            || '"parent_span_id":"' || NVL(l_parent_span_id, '') || '",'
            || '"operation_name":"' || escape_json_string(l_operation_name) || '",' 
            || '"start_time":"' || TO_CHAR(l_start_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'  
            || '"end_time":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'   
            || '"duration_ms":' || NVL(RTRIM(TO_CHAR(l_duration, 'FM99999999999990.999999'), '.'), '0') || ','
            || '"status":"' || l_status || '",'
            || '"events":' || l_events_json || ','
            || '"attributes":' || l_attrs_json
            || '}';

        -- Validate JSON
        IF l_json IS NOT JSON THEN
            -- Fix span as ERROR if JSON is invalid
            UPDATE plt_spans
            SET end_time = SYSTIMESTAMP, 
                status = 'ERROR',
                duration_ms = 0
            WHERE span_id = l_span_id AND end_time IS NULL;
            
            log_error_internal('end_span', 'Invalid JSON generated - span marked as ERROR');
            
            IF g_autocommit THEN
                COMMIT;
            END IF;
            RETURN;
        END IF;

        -- Send to backend
        send_to_backend(l_json);

        IF g_autocommit THEN
            COMMIT;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('end_span', l_error_msg, NULL, l_span_id);

            -- Try to at least update the span as ERROR
            BEGIN
                UPDATE plt_spans
                SET end_time = SYSTIMESTAMP, status = 'ERROR', duration_ms = 0
                WHERE span_id = l_span_id AND end_time IS NULL;

                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
    END end_span;

    /**
     * Adds an event to an active span
     */
    PROCEDURE add_event (p_span_id VARCHAR2, p_event_name VARCHAR2, p_attributes t_attributes DEFAULT t_attributes())
    IS
        l_attrs_varchar   VARCHAR2(4000);
        l_error_msg       VARCHAR2(4000);
        l_span_id         VARCHAR2(16);
        l_event_name      VARCHAR2(255);
    BEGIN
        -- Normalize & validate input parameters
        l_span_id := normalize_string(p_span_id, p_max_length => 16, p_allow_null => FALSE);
        l_event_name := normalize_string(p_event_name, p_max_length => 255, p_allow_null => FALSE);
        
        IF l_span_id IS NULL OR l_event_name IS NULL THEN
            RETURN;
        END IF;

        -- Convert attributes to JSON
        BEGIN
            l_attrs_varchar := CASE 
                WHEN p_attributes.COUNT > 0 THEN attributes_to_json(p_attributes)
                ELSE '{}'
            END;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                l_attrs_varchar := '{}';
                log_error_internal('add_event', 'Failed to convert attributes - ' || SUBSTR(l_error_msg, 1, 200), NULL, l_span_id);
        END;

        -- Validate JSON
        IF l_attrs_varchar != '{}' AND l_attrs_varchar IS NOT JSON THEN
            l_attrs_varchar := '{}';
        END IF;

        -- Insert event
        INSERT INTO plt_events (
            span_id,
            event_name,
            event_time,
            attributes
        ) VALUES (
            l_span_id,
            l_event_name,
            SYSTIMESTAMP,
            l_attrs_varchar
        );

        IF g_autocommit THEN
            COMMIT;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('add_event', l_error_msg, NULL, l_span_id);
    END add_event;

    --------------------------------------------------------------------------
    -- METRICS
    --------------------------------------------------------------------------

    /**
    * Records a metric value with associated metadata
    * Updated with pulse throttling and dynamic sampling
    */
    PROCEDURE log_metric (p_metric_name    VARCHAR2,
                    p_value          NUMBER,
                    p_unit           VARCHAR2 DEFAULT NULL,
                    p_attributes     t_attributes DEFAULT t_attributes(),
                    p_include_trace_correlation BOOLEAN DEFAULT TRUE)
    IS
        l_json         VARCHAR2(32767);
        l_attrs_json   VARCHAR2(4000);
        l_error_msg    VARCHAR2(4000);
        l_value_str    VARCHAR2(50);
        l_metric_name  VARCHAR2(255);
        l_unit         VARCHAR2(50);
        l_trace_id     VARCHAR2(32);
        l_span_id      VARCHAR2(16);
        l_pulse_mode   VARCHAR2(10);
        l_sampled      BOOLEAN := TRUE;
        l_attrs_enhanced t_attributes;
        l_attr_idx     NUMBER;
    BEGIN
        -- ========================================================================
        -- PULSE THROTTLING PRE-CHECKS
        -- ========================================================================
        
        -- Check if metrics are enabled for current pulse mode
        IF NOT should_process_telemetry('METRICS') THEN
            -- In COMA mode or if metrics disabled, drop the metric silently
            RETURN;
        END IF;
        
        -- Get current pulse mode for context
        l_pulse_mode := get_agent_pulse_mode();
        
        -- Apply dynamic sampling based on pulse mode
        IF NOT should_sample_telemetry() THEN
            -- Metric was sampled out - increment dropped counter if we can
            BEGIN
                -- Try to record a sampling metric (only if we're in a mode that allows it)
                IF l_pulse_mode IN ('PULSE1', 'PULSE2') THEN
                    -- Only track sampling stats in higher capacity modes to avoid recursion
                    INSERT INTO plt_metrics (
                        metric_name,
                        metric_value,
                        metric_unit,
                        timestamp,
                        attributes
                    ) VALUES (
                        'pltelemetry.sampling.dropped_metrics',
                        1,
                        'count',
                        SYSTIMESTAMP,
                        '{"pulse_mode":"' || l_pulse_mode || '","original_metric":"' || 
                        REPLACE(SUBSTR(p_metric_name, 1, 100), '"', '\"') || '"}'
                    );
                    
                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- Don't fail on sampling stats
            END;
            
            RETURN; -- Drop this metric due to sampling
        END IF;

        -- ========================================================================
        -- EXISTING VALIDATION AND PROCESSING WITH ENHANCEMENTS
        -- ========================================================================
        
        -- Normalize & validate input parameters (existing logic)
        l_metric_name := normalize_string(p_metric_name, p_max_length => 255, p_allow_null => FALSE);
        l_unit := normalize_string(p_unit, p_max_length => 50, p_allow_null => TRUE);
        
        IF l_metric_name IS NULL OR p_value IS NULL THEN
            RETURN;
        END IF;
        
        l_unit := NVL(l_unit, 'unit');

        -- Conditional trace correlation (existing logic)
        IF p_include_trace_correlation THEN
            l_trace_id := g_current_trace_id;
            l_span_id := g_current_span_id;
        ELSE
            l_trace_id := NULL;
            l_span_id := NULL;
        END IF;

        -- ========================================================================
        -- ENHANCE ATTRIBUTES WITH PULSE CONTEXT
        -- ========================================================================
        
        -- Copy original attributes and add pulse context
        l_attrs_enhanced := p_attributes;
        l_attr_idx := NVL(l_attrs_enhanced.LAST, 0) + 1;
        
        -- Add pulse mode context to all metrics
        l_attrs_enhanced(l_attr_idx) := add_attribute('pulse.mode', l_pulse_mode);
        l_attr_idx := l_attr_idx + 1;
        
        -- Add sampling rate for observability
        DECLARE
            l_config plt_pulse_config_t;
        BEGIN
            l_config := get_pulse_throttling_config(l_pulse_mode);
            l_attrs_enhanced(l_attr_idx) := add_attribute('pulse.sampling_rate',
                                            CASE 
                                            WHEN l_config.sampling_rate = TRUNC(l_config.sampling_rate) THEN 
                                                TO_CHAR(TRUNC(l_config.sampling_rate))  -- "1" para números enteros
                                            ELSE 
                                                TO_CHAR(l_config.sampling_rate, 'FM0.999999999')  -- "0.75" para decimales
                                            END);
            l_attr_idx := l_attr_idx + 1;
            
            -- Add capacity context for system monitoring
            l_attrs_enhanced(l_attr_idx) := add_attribute('pulse.capacity_multiplier',
                                            CASE 
                                            WHEN l_config.capacity_multiplier = TRUNC(l_config.capacity_multiplier) THEN 
                                                TO_CHAR(TRUNC(l_config.capacity_multiplier))
                                            ELSE 
                                                TO_CHAR(l_config.capacity_multiplier, 'FM0.999999999')
                                            END);
        EXCEPTION
            WHEN OTHERS THEN
                -- Don't fail on pulse context addition
                NULL;
        END;

        -- Convert enhanced attributes to JSON
        l_attrs_json := attributes_to_json(l_attrs_enhanced);

        -- ========================================================================
        -- EXISTING JSON BUILDING AND SENDING LOGIC
        -- ========================================================================
        
        -- Handle number formatting (existing logic)
        BEGIN
            l_value_str := NVL(RTRIM(TO_CHAR(p_value, 'FM99999999999990.999999'), '.'), '0');
        EXCEPTION
            WHEN OTHERS THEN
                l_value_str := '0';
        END;

        -- Build metric JSON - conditional trace/span fields (existing logic)
        l_json := '{'
            || '"name":"' || escape_json_string(l_metric_name) || '",'
            || '"value":' || l_value_str || ','
            || '"unit":"' || REPLACE(l_unit, '"', '\"') || '",'
            || '"timestamp":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'
            || CASE WHEN l_trace_id IS NOT NULL THEN '"trace_id":"' || l_trace_id || '",' ELSE '' END
            || CASE WHEN l_span_id IS NOT NULL THEN '"span_id":"' || l_span_id || '",' ELSE '' END
            || '"attributes":' || l_attrs_json
            || '}';

        -- Validate JSON (existing logic)
        IF l_json IS NOT JSON THEN
            log_error_internal('log_metric', 'Invalid metric JSON generated for pulse mode: ' || l_pulse_mode);
            RETURN;
        END IF;

        -- Log to metrics table (existing logic)
        INSERT INTO plt_metrics (
            metric_name,
            metric_value,
            metric_unit,
            trace_id,
            span_id,
            timestamp,
            attributes
        ) VALUES (
            l_metric_name,
            p_value,
            l_unit,
            l_trace_id,  -- Can be NULL
            l_span_id,   -- Can be NULL
            SYSTIMESTAMP,
            l_attrs_json
        );

        -- Send to backend (existing logic)
        send_to_backend(l_json);

        IF g_autocommit THEN
            COMMIT;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('log_metric', 
                'Metric error (Pulse: ' || get_agent_pulse_mode() || '): ' || l_error_msg);
    END log_metric;

    --------------------------------------------------------------------------
    -- LOGGING FUNCTIONS
    --------------------------------------------------------------------------

    /**
    * Internal helper to build and send log JSON with pulse throttling
    * Updated with intelligent log sampling and pulse-aware processing
    */
    PROCEDURE send_log_internal(
        p_trace_id   VARCHAR2,
        p_span_id    VARCHAR2,
        p_level      VARCHAR2,
        p_message    VARCHAR2,
        p_attributes t_attributes
    )
    IS
        l_json         VARCHAR2(32767);
        l_attrs_json   VARCHAR2(4000);
        l_error_msg    VARCHAR2(4000);
        l_trace_id     VARCHAR2(32);
        l_span_id      VARCHAR2(16);
        l_level        VARCHAR2(10);
        l_message      VARCHAR2(4000);
        l_pulse_mode   VARCHAR2(10);
        l_config       plt_pulse_config_t;
        l_should_sample BOOLEAN := TRUE;
        l_level_priority NUMBER;
        l_attrs_enhanced t_attributes;
        l_attr_idx     NUMBER;
        l_message_size NUMBER;
    BEGIN
        -- ========================================================================
        -- INPUT NORMALIZATION AND VALIDATION
        -- ========================================================================
        
        -- Normalize & validate input parameters
        l_trace_id := normalize_string(p_trace_id, p_max_length => 32, p_allow_null => TRUE);
        l_span_id := normalize_string(p_span_id, p_max_length => 16, p_allow_null => TRUE);
        l_level := normalize_string(p_level, p_max_length => 10, p_allow_null => FALSE);
        l_message := normalize_string(p_message, p_max_length => 4000, p_allow_null => FALSE);
        
        IF l_level IS NULL OR l_message IS NULL THEN
            RETURN;
        END IF;

        l_message_size := LENGTH(l_message);

        -- ========================================================================
        -- PULSE THROTTLING PRE-CHECKS
        -- ========================================================================
        
        -- Get current pulse mode and configuration
        l_pulse_mode := get_agent_pulse_mode();
        l_config := get_pulse_throttling_config(l_pulse_mode);
        
        -- Check if logs are enabled for current pulse mode
        IF l_config.logs_enabled = 'N' THEN
            -- In COMA mode or if logs disabled, drop silently
            RETURN;
        END IF;
        
        -- ========================================================================
        -- INTELLIGENT LOG LEVEL SAMPLING
        -- ========================================================================
        
        -- Assign priority to log levels (higher number = more important)
        l_level_priority := CASE UPPER(l_level)
            WHEN 'TRACE' THEN 1
            WHEN 'DEBUG' THEN 2
            WHEN 'INFO' THEN 3
            WHEN 'WARN' THEN 4
            WHEN 'WARNING' THEN 4
            WHEN 'ERROR' THEN 5
            WHEN 'FATAL' THEN 6
            ELSE 3  -- Default to INFO level
        END;
        
        -- Apply intelligent sampling based on log level and pulse mode
        CASE l_pulse_mode
            WHEN 'PULSE1' THEN
                -- Full capacity - sample all logs
                l_should_sample := TRUE;
                
            WHEN 'PULSE2' THEN
                -- 50% capacity - sample based on level and general sampling
                l_should_sample := (l_level_priority >= 4) OR should_sample_telemetry();
                
            WHEN 'PULSE3' THEN
                -- 25% capacity - only WARN+ guaranteed, others sampled
                l_should_sample := (l_level_priority >= 4) OR 
                                (l_level_priority >= 3 AND should_sample_telemetry());
                
            WHEN 'PULSE4' THEN
                -- 10% capacity - only ERROR+ guaranteed, others heavily sampled
                l_should_sample := (l_level_priority >= 5) OR 
                                (l_level_priority >= 3 AND DBMS_RANDOM.VALUE(0, 1) <= 0.1);
                
            WHEN 'COMA' THEN
                -- Hibernation - only FATAL guaranteed
                l_should_sample := (l_level_priority >= 6);
                
            ELSE
                l_should_sample := TRUE;
        END CASE;
        
        -- Override: Always sample errors from PLTelemetry itself for debugging
        IF UPPER(l_message) LIKE '%PLTELEMETRY%' AND l_level_priority >= 5 THEN
            l_should_sample := TRUE;
        END IF;
        
        -- Apply sampling decision
        IF NOT l_should_sample THEN
            -- Log was sampled out - track sampling stats (avoid recursion)
            BEGIN
                IF l_pulse_mode IN ('PULSE1', 'PULSE2') AND l_level_priority <= 3 THEN
                    -- Only track sampling stats in higher capacity modes for low-priority logs
                    INSERT INTO plt_logs (
                        log_level,
                        message,
                        timestamp,
                        attributes
                    ) VALUES (
                        'DEBUG',
                        'Log sampling: dropped ' || UPPER(l_level) || ' log',
                        SYSTIMESTAMP,
                        '{"pulse_mode":"' || l_pulse_mode || '","original_level":"' || UPPER(l_level) || 
                        '","message_size":' || l_message_size || '}'
                    );
                    
                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- Don't fail on sampling stats
            END;
            
            RETURN; -- Drop this log due to sampling
        END IF;

        -- ========================================================================
        -- ENHANCE ATTRIBUTES WITH PULSE CONTEXT
        -- ========================================================================
        
        -- Copy original attributes and add pulse context
        l_attrs_enhanced := p_attributes;
        l_attr_idx := NVL(l_attrs_enhanced.LAST, 0) + 1;
        
        -- Add pulse mode context to logs
        l_attrs_enhanced(l_attr_idx) := add_attribute('pulse.mode', l_pulse_mode);
        l_attr_idx := l_attr_idx + 1;
        
        l_attrs_enhanced(l_attr_idx) := add_attribute('pulse.log_sampling_rate', 
            TO_CHAR(l_config.sampling_rate, 'FM0.9999'));
        l_attr_idx := l_attr_idx + 1;
        
        -- Add log processing context
        l_attrs_enhanced(l_attr_idx) := add_attribute('log.level_priority', TO_CHAR(l_level_priority));
        l_attr_idx := l_attr_idx + 1;
        
        l_attrs_enhanced(l_attr_idx) := add_attribute('log.message_size', TO_CHAR(l_message_size));
        l_attr_idx := l_attr_idx + 1;
        
        -- Add system context for correlation
        l_attrs_enhanced(l_attr_idx) := add_attribute('system.processing_mode', get_processing_mode());

        -- Convert enhanced attributes to JSON
        l_attrs_json := attributes_to_json(l_attrs_enhanced);

        -- ========================================================================
        -- JSON BUILDING WITH PULSE CONTEXT
        -- ========================================================================
        
        -- Build log JSON with enhanced attributes
        l_json := '{'
            || '"severity":"' || UPPER(l_level) || '",'
            || '"message":"' || escape_json_string(l_message) || '",'
            || '"timestamp":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'
            || CASE 
                    WHEN l_trace_id IS NOT NULL AND LENGTH(l_trace_id) = 32 
                    THEN '"trace_id":"' || l_trace_id || '",'
                    ELSE ''
                END
            || CASE 
                    WHEN l_span_id IS NOT NULL AND LENGTH(l_span_id) = 16 
                    THEN '"span_id":"' || l_span_id || '",'
                    ELSE ''
                END
            || '"attributes":' || l_attrs_json
            || '}';

        -- ========================================================================
        -- DATABASE STORAGE WITH PULSE AWARENESS
        -- ========================================================================
        
        -- Store in local logs table (always store, even if backend fails)
        BEGIN
            INSERT INTO plt_logs (
                trace_id,
                span_id, 
                log_level,
                message,
                timestamp,
                attributes
            ) VALUES (
                l_trace_id,
                l_span_id,
                UPPER(l_level),
                l_message,
                SYSTIMESTAMP,
                l_attrs_json
            );
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                -- Use plt_telemetry_errors as ultimate fallback (avoid recursion)
                INSERT INTO plt_telemetry_errors (
                    error_time,
                    error_message,
                    module_name
                ) VALUES (
                    SYSTIMESTAMP,
                    'Failed to insert into plt_logs (Pulse: ' || l_pulse_mode || '): ' || l_error_msg,
                    'send_log_internal'
                );
        END;

        -- ========================================================================
        -- BACKEND SENDING WITH PULSE THROTTLING
        -- ========================================================================
        
        -- Send to backend (this will respect pulse throttling internally)
        send_to_backend(l_json);

        IF g_autocommit THEN
            COMMIT;
        END IF;

        -- ========================================================================
        -- LOG VOLUME METRICS (SELF-MONITORING)
        -- ========================================================================
        
        -- Record log volume metrics (sampled to avoid metric explosion)
        IF should_process_telemetry('METRICS') AND MOD(EXTRACT(SECOND FROM SYSTIMESTAMP), 60) = 0 THEN
            BEGIN
                log_metric(
                    p_metric_name => 'pltelemetry.logs.processed_by_level',
                    p_value => 1,
                    p_unit => 'logs',
                    p_include_trace_correlation => FALSE
                );
                
                -- Track pulse effectiveness on log volume
                log_metric(
                    p_metric_name => 'pltelemetry.logs.pulse_capacity',
                    p_value => l_config.capacity_multiplier * 100,
                    p_unit => 'percent',
                    p_include_trace_correlation => FALSE
                );
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- Don't fail on self-monitoring
            END;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            
            -- Ultimate fallback - direct insert to error table to avoid recursion
            BEGIN
                INSERT INTO plt_telemetry_errors (
                    error_time,
                    error_message,
                    module_name
                ) VALUES (
                    SYSTIMESTAMP,
                    'Critical error in send_log_internal (Pulse: ' || get_agent_pulse_mode() || '): ' || l_error_msg,
                    'send_log_internal'
                );
                
                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- Absolute last resort - don't fail
            END;
    END send_log_internal;

    /**
     * Logs with explicit trace context
     */
    PROCEDURE log_with_trace(
        p_trace_id   VARCHAR2,
        p_level      VARCHAR2,
        p_message    VARCHAR2,
        p_attributes t_attributes DEFAULT t_attributes()
    )
    IS
    BEGIN
        send_log_internal(p_trace_id, NULL, p_level, p_message, p_attributes);
    END log_with_trace;

    /**
     * Logs attached to an active span
     */
    PROCEDURE add_log(
        p_span_id    VARCHAR2,
        p_level      VARCHAR2,
        p_message    VARCHAR2, 
        p_attributes t_attributes DEFAULT t_attributes()
    )
    IS
    BEGIN
        send_log_internal(g_current_trace_id, p_span_id, p_level, p_message, p_attributes);
    END add_log;

    /**
     * Standalone logs without trace context
     */
    PROCEDURE log_message(
        p_level      VARCHAR2,
        p_message    VARCHAR2,
        p_attributes t_attributes DEFAULT t_attributes()
    )
    IS
    BEGIN
        send_log_internal(NULL, NULL, p_level, p_message, p_attributes);
    END log_message;

    /**
     * Log with distributed trace context
     */
    PROCEDURE log_distributed(
        p_trace_id   VARCHAR2,
        p_level      VARCHAR2,
        p_message    VARCHAR2,
        p_system     VARCHAR2 DEFAULT 'PLSQL',
        p_tenant_id  VARCHAR2 DEFAULT NULL
    )
    IS
        l_attributes t_attributes;
        l_idx        NUMBER := 1;
        l_system     VARCHAR2(50);
        l_tenant_id  VARCHAR2(100);
    BEGIN
        -- Normalize & validate input parameters
        l_system := normalize_string(p_system, p_max_length => 50, p_allow_null => TRUE);
        l_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => TRUE);
        
        l_system := NVL(l_system, 'PLSQL');
        
        -- Build distributed logging attributes
        l_attributes(l_idx) := add_attribute('system.name', l_system);
        l_idx := l_idx + 1;
        
        l_attributes(l_idx) := add_attribute('trace.distributed', 'true');
        l_idx := l_idx + 1;
        
        l_attributes(l_idx) := add_attribute('db.name', SYS_CONTEXT('USERENV', 'DB_NAME'));
        l_idx := l_idx + 1;
        
        l_attributes(l_idx) := add_attribute('db.user', SYS_CONTEXT('USERENV', 'SESSION_USER'));
        l_idx := l_idx + 1;
        
        IF l_tenant_id IS NOT NULL THEN
            l_attributes(l_idx) := add_attribute('tenant.id', l_tenant_id);
        END IF;
        
        log_with_trace(p_trace_id, p_level, p_message, l_attributes);
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback to basic logging
            log_message(p_level, 'DISTRIBUTED: ' || p_message);
    END log_distributed;

    --------------------------------------------------------------------------
    -- SESSION CONTEXT MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * Private setter for internal trace context variables
     */
    PROCEDURE set_internal_trace_context(p_trace_id VARCHAR2, p_span_id VARCHAR2)
    IS
    BEGIN
        g_current_trace_id := p_trace_id;
        g_current_span_id := p_span_id;
        
        -- Optional: Add future validation or logging here
        -- log_error_internal('context_change', 'Trace context updated to: ' || p_trace_id || '/' || p_span_id);
    END set_internal_trace_context;

    /**
     * Clears internal trace context variables
     */
    PROCEDURE clear_internal_trace_context
    IS
    BEGIN
        g_current_trace_id := NULL;
        g_current_span_id := NULL;
    END clear_internal_trace_context;

    --------------------------------------------------------------------------
    -- TENANT CONTEXT MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * Sets the tenant context for the current session
     */
    PROCEDURE set_tenant_context(p_tenant_id VARCHAR2, p_tenant_name VARCHAR2 DEFAULT NULL)
    IS
        l_tenant_id   VARCHAR2(100);
        l_tenant_name VARCHAR2(255);
    BEGIN
        -- Normalize & validate input parameters
        l_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => FALSE);
        l_tenant_name := normalize_string(p_tenant_name, p_max_length => 255, p_allow_null => TRUE);
        
        g_current_tenant_id := l_tenant_id;
        g_current_tenant_name := l_tenant_name;
        
        -- Update session context to include tenant
        set_trace_context();
    END set_tenant_context;

    /**
     * Clears the tenant context for the current session
     */
    PROCEDURE clear_tenant_context
    IS
    BEGIN
        g_current_tenant_id := NULL;
        g_current_tenant_name := NULL;
        
        -- Update session context
        set_trace_context();
    END clear_tenant_context;

    /**
     * Gets the current tenant ID
     */
    FUNCTION get_current_tenant_id
        RETURN VARCHAR2
    IS
    BEGIN
        RETURN g_current_tenant_id;
    END get_current_tenant_id;

    /**
     * Gets the current tenant name
     */
    FUNCTION get_current_tenant_name
        RETURN VARCHAR2
    IS
    BEGIN
        RETURN g_current_tenant_name;
    END get_current_tenant_name;

    /**
     * Sets the current trace context in Oracle session info
     */
    PROCEDURE set_trace_context
    IS
        l_module_name VARCHAR2(64);
        l_action_name VARCHAR2(64);
    BEGIN
        -- Build module name with tenant info if available
        l_module_name := 'OTEL:' || SUBSTR(NVL(g_current_trace_id, 'none'), 1, 28);
        
        -- Build action name with span and tenant info
        l_action_name := 'SPAN:' || SUBSTR(NVL(g_current_span_id, 'none'), 1, 12);
        
        -- Add tenant suffix if available (keeping within 64 char limit)
        IF g_current_tenant_id IS NOT NULL THEN
            l_action_name := l_action_name || '|T:' || SUBSTR(g_current_tenant_id, 1, 8);
        END IF;
        
        DBMS_APPLICATION_INFO.SET_MODULE(
            module_name => l_module_name,
            action_name => l_action_name
        );
    END set_trace_context;

    /**
     * Clears the current trace context from session
     */
    PROCEDURE clear_trace_context
    IS
    BEGIN
        clear_internal_trace_context();
        DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);
    END clear_trace_context;

    --------------------------------------------------------------------------
    -- CONFIGURATION GETTERS AND SETTERS
    --------------------------------------------------------------------------

    /**
     * Sets the auto-commit mode for telemetry operations
     */
    PROCEDURE set_autocommit (p_value BOOLEAN)
    IS
    BEGIN
        g_autocommit := p_value;
    END set_autocommit;

    /**
     * Gets the current auto-commit mode setting
     */
    FUNCTION get_autocommit
        RETURN BOOLEAN
    IS
    BEGIN
        RETURN g_autocommit;
    END get_autocommit;

    /**
     * Sets the backend URL for telemetry export
     */
    PROCEDURE set_backend_url (p_url VARCHAR2)
    IS
    BEGIN
        g_backend_url := p_url;
    END set_backend_url;

    /**
     * Gets the current backend URL
     */
    FUNCTION get_backend_url
        RETURN VARCHAR2
    IS
    BEGIN
        RETURN g_backend_url;
    END get_backend_url;

    /**
    * Gets the current async processing mode
    */
    FUNCTION get_async_mode RETURN VARCHAR2
    IS
    BEGIN
        RETURN CASE WHEN g_async_mode THEN 'Y' ELSE 'N' END;
    END get_async_mode;

    /**
    * Sets the API key for backend authentication
    */
   PROCEDURE set_api_key (p_key VARCHAR2)
   IS
   BEGIN
       g_api_key := p_key;
   END set_api_key;

   /**
    * Sets the HTTP timeout for backend calls
    */
   PROCEDURE set_backend_timeout (p_timeout NUMBER)
   IS
   BEGIN
       g_backend_timeout := p_timeout;
   END set_backend_timeout;

   /**
    * Sets the async processing mode
    */
   PROCEDURE set_async_mode (p_async BOOLEAN)
   IS
   BEGIN
       g_async_mode := p_async;
   END set_async_mode;

   /**
    * Gets the current trace ID
    */
   FUNCTION get_current_trace_id
       RETURN VARCHAR2
   IS
   BEGIN
       RETURN g_current_trace_id;
   END get_current_trace_id;

   /**
    * Gets the current span ID
    */
   FUNCTION get_current_span_id
       RETURN VARCHAR2
   IS
   BEGIN
       RETURN g_current_span_id;
   END get_current_span_id;

    -- ========================================================================
    -- AGENT FAILOVER MANAGEMENT - BODY IMPLEMENTATION
    -- ========================================================================

    /**
    * Get agent health based on heartbeat and performance metrics
    */
    FUNCTION get_agent_health RETURN VARCHAR2
    IS
        l_last_heartbeat    TIMESTAMP WITH TIME ZONE;
        l_process_interval  NUMBER;
        l_missed_runs       NUMBER := 0;
        l_max_missed        NUMBER;
        l_items_processed   NUMBER;
        l_items_planned     NUMBER;
        l_performance_ratio NUMBER;
    BEGIN
        -- Get agent data
        BEGIN
            SELECT last_heartbeat, process_interval, items_processed, items_planned
            INTO l_last_heartbeat, l_process_interval, l_items_processed, l_items_planned
            FROM plt_agent_registry
            WHERE agent_id = 'PRIMARY';
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN 'UNKNOWN';
        END;
        
        -- Check if heartbeat is recent
        IF l_last_heartbeat IS NULL THEN
            RETURN 'UNKNOWN';
        END IF;
        
        -- Calculate missed runs based on process interval
        IF l_process_interval > 0 THEN
            l_missed_runs := FLOOR(
                (CAST(SYSTIMESTAMP AS DATE) - CAST(l_last_heartbeat AS DATE)) * 86400 / l_process_interval
            );
            /*l_missed_runs := FLOOR(
                EXTRACT(SECOND FROM (SYSTIMESTAMP - l_last_heartbeat)) / l_process_interval
            );*/
        END IF;
        
        -- Get max missed runs from config
        l_max_missed := TO_NUMBER(NVL(get_failover_config('MAX_MISSED_RUNS'), '3'));
        /*
        log_error_internal('get_agent_health', 'l_missed_runs: ' || SUBSTR(l_missed_runs, 1, 50)||
            ', l_max_missed: ' || SUBSTR(l_max_missed, 1, 50) ||
            ', l_items_processed: ' || SUBSTR(l_items_processed, 1, 50) ||
            ', l_items_planned: ' || SUBSTR(l_items_planned, 1, 50));
        */
        -- Determine health status
        IF l_missed_runs >= l_max_missed THEN
            RETURN 'DEAD';
        END IF;

        
        
        -- Check performance ratio if agent reported metrics
        IF l_items_planned > 0 THEN
            l_performance_ratio := l_items_processed / l_items_planned;
            IF l_performance_ratio < 0.7 THEN  -- Less than 70% of planned
                RETURN 'DEGRADED';
            END IF;
        END IF;
        
        RETURN 'HEALTHY';
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('get_agent_health', 
                'Error checking agent health: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RETURN 'UNKNOWN';
    END get_agent_health;

    /**
    * Determine if fallback should be activated
    */
    FUNCTION should_activate_fallback RETURN BOOLEAN
    IS
        l_agent_health   VARCHAR2(20);
        l_queue_size     NUMBER;
        l_queue_threshold NUMBER;
        l_enabled        VARCHAR2(1);
    BEGIN
        -- Check if failover is enabled
        l_enabled := NVL(get_failover_config('ENABLED'), 'Y');
        IF l_enabled != 'Y' THEN
            RETURN FALSE;
        END IF;
        
        -- Get agent health
        l_agent_health := get_agent_health();
        
        -- Dead agent = activate fallback
        IF l_agent_health = 'DEAD' THEN
            RETURN TRUE;
        END IF;
        
        -- Check queue size for degraded agents
        IF l_agent_health IN ('DEGRADED', 'UNKNOWN') THEN
            SELECT COUNT(*) 
            INTO l_queue_size
            FROM plt_queue
            WHERE processed = 'N';
            
            l_queue_threshold := TO_NUMBER(NVL(get_failover_config('QUEUE_THRESHOLD'), '1000'));
            
            IF l_queue_size > l_queue_threshold THEN
                RETURN TRUE;
            END IF;
        END IF;
        
        RETURN FALSE;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('should_activate_fallback', 
                'Error evaluating fallback need: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RETURN FALSE;
    END should_activate_fallback;

    /**
    * Activate Oracle-based queue processing
    */
    PROCEDURE activate_oracle_fallback
    IS
        l_current_mode VARCHAR2(50);
        l_fallback_backend VARCHAR2(100);
    BEGIN
        -- Check current mode to avoid duplicate activation
        l_current_mode := get_processing_mode();
        IF l_current_mode = 'ORACLE_FALLBACK' THEN
            RETURN;  -- Already active
        END IF;
        
        -- Enable the scheduler job
        BEGIN
            DBMS_SCHEDULER.ENABLE('PLT_QUEUE_PROCESSOR');
        EXCEPTION
            WHEN OTHERS THEN
                -- Job might not exist, try to create it
                BEGIN
                    DBMS_SCHEDULER.CREATE_JOB(
                        job_name        => 'PLT_QUEUE_PROCESSOR',
                        job_type        => 'PLSQL_BLOCK',
                        job_action      => 'BEGIN PLTelemetry.process_queue_fallback(500); END;',
                        start_date      => SYSTIMESTAMP,
                        repeat_interval => 'FREQ=MINUTELY;INTERVAL=1',
                        enabled         => TRUE,
                        comments        => 'Fallback queue processor when external agent is down'
                    );
                EXCEPTION
                    WHEN OTHERS THEN
                        log_error_internal('activate_oracle_fallback', 
                            'Failed to create/enable job: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
                        RAISE;
                END;
        END;
        
        -- Update processing mode in config
        MERGE INTO plt_failover_config fc
        USING (SELECT 'PROCESSING_MODE' as key_val FROM dual) src
        ON (fc.config_key = src.key_val)
        WHEN MATCHED THEN
            UPDATE SET config_value = 'ORACLE_FALLBACK', updated_at = SYSTIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (config_key, config_value, description)
            VALUES ('PROCESSING_MODE', 'ORACLE_FALLBACK', 'Current processing mode');
        
        -- Log which backend will be used
        l_fallback_backend := NVL(get_failover_config('FALLBACK_BACKEND'), 'OTLP_BRIDGE');
        
        -- Log the transition
        log_error_internal('activate_oracle_fallback', 
            'Fallback activated. Agent health caused switch to Oracle processing. Using backend: ' || l_fallback_backend);
        
        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('activate_oracle_fallback', 
                'Critical error activating fallback: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END activate_oracle_fallback;

    /**
    * Deactivate Oracle-based queue processing
    */
    PROCEDURE deactivate_oracle_fallback
    IS
        l_current_mode VARCHAR2(50);
    BEGIN
        -- Check current mode
        l_current_mode := get_processing_mode();
        IF l_current_mode != 'ORACLE_FALLBACK' THEN
            RETURN;  -- Not active
        END IF;
        
        -- Disable the scheduler job
        BEGIN
            DBMS_SCHEDULER.DISABLE('PLT_QUEUE_PROCESSOR', TRUE);  -- TRUE = force
        EXCEPTION
            WHEN OTHERS THEN
                -- Log but don't fail
                log_error_internal('deactivate_oracle_fallback', 
                    'Warning: Could not disable job: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
        END;
        
        -- Update processing mode
        UPDATE plt_failover_config
        SET config_value = 'AGENT_PRIMARY', 
            updated_at = SYSTIMESTAMP
        WHERE config_key = 'PROCESSING_MODE';
        
        -- Log the transition
        log_error_internal('deactivate_oracle_fallback', 
            'Fallback deactivated. Agent recovered, switching back to external processing');
        
        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('deactivate_oracle_fallback', 
                'Error deactivating fallback: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END deactivate_oracle_fallback;

    /**
    * Main orchestrator for queue processing management with pulse throttling
    * Auto-initializes the failover system and coordinates with agent pulse mode
    * Updated to make intelligent decisions based on both agent health AND pulse mode
    */

    PROCEDURE manage_queue_processor
    IS
        l_should_fallback BOOLEAN;
        l_current_mode    VARCHAR2(50);
        l_agent_health    VARCHAR2(20);
        l_job_exists      NUMBER;
        l_queue_size      NUMBER;
        l_trace_id        VARCHAR2(32);
        l_span_id         VARCHAR2(16);
        l_attrs           t_attributes;
        l_original_async  BOOLEAN;
        l_pulse_mode      VARCHAR2(10);
        l_pulse_config    plt_pulse_config_t;
        l_agent_overridden BOOLEAN := FALSE;
        l_pulse_forced_fallback BOOLEAN := FALSE;
        l_state_changed  BOOLEAN := FALSE;
        -- FIXED: Remove undefined variable l_should_change_mode
    BEGIN
        -- Store original async mode for restoration
        l_original_async := CASE WHEN get_async_mode = 'Y' THEN TRUE ELSE FALSE END;

        -- ========================================================================
        -- SYSTEM INITIALIZATION CHECK
        -- ========================================================================
        
        -- Check if system is initialized (lazy initialization)
        BEGIN
            SELECT COUNT(*) INTO l_job_exists
            FROM user_scheduler_jobs
            WHERE job_name = 'PLT_QUEUE_PROCESSOR';
            
            IF l_job_exists = 0 THEN
                -- Auto-initialize on first call
                initialize_failover_system();
                
                -- Log the auto-initialization
                log_error_internal('manage_queue_processor', 
                    'Failover system auto-initialized on first run');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                -- Don't fail if we can't check, just try to proceed
                NULL;
        END;
        
        -- ========================================================================
        -- PULSE MODE ANALYSIS AND INTEGRATION
        -- ========================================================================
        
        -- Get current pulse mode and configuration
        l_pulse_mode := get_agent_pulse_mode();
        l_pulse_config := get_pulse_throttling_config(l_pulse_mode);
        
        -- Get current state (existing logic)
        l_current_mode := get_processing_mode();
        l_agent_health := get_agent_health();
        l_should_fallback := should_activate_fallback();
        
        -- ========================================================================
        -- PULSE-ENHANCED FAILOVER DECISION LOGIC
        -- ========================================================================
        
        -- CRITICAL: Override agent health assessment based on pulse mode
        IF l_pulse_mode = 'COMA' THEN
            l_pulse_forced_fallback := TRUE;
            l_should_fallback := TRUE;
            l_agent_overridden := TRUE;
            
            log_error_internal('manage_queue_processor', 
                'PULSE COMA DETECTED - Forcing Oracle fallback regardless of agent health. Agent health: ' || l_agent_health);
        
        ELSIF l_pulse_mode = 'PULSE4' AND l_agent_health IN ('DEGRADED', 'UNKNOWN') THEN
            l_pulse_forced_fallback := TRUE;
            l_should_fallback := TRUE;
            l_agent_overridden := TRUE;
            
            log_error_internal('manage_queue_processor', 
                'PULSE4 with degraded agent - Forcing failover for system protection');
        
        ELSIF l_pulse_mode IN ('PULSE2', 'PULSE3') AND l_current_mode = 'ORACLE_FALLBACK' THEN
            IF l_agent_health != 'HEALTHY' THEN
                l_should_fallback := TRUE; -- Stay in fallback
                log_error_internal('manage_queue_processor', 
                    'Pulse ' || l_pulse_mode || ' - Keeping Oracle fallback due to non-healthy agent');
            END IF;
        END IF;
        
        -- Get queue size for context
        SELECT COUNT(*) INTO l_queue_size
        FROM plt_queue
        WHERE processed = 'N';
        
        -- ========================================================================
        -- ENHANCED STATE MACHINE LOGIC WITH SESSION PROTECTION
        -- ========================================================================
        
        IF l_current_mode = 'AGENT_PRIMARY' AND l_should_fallback THEN
            -- ACTIVATION: Switch to fallback
            
            -- FIXED: Proper session state management
            set_async_mode(TRUE);
            l_state_changed := TRUE;
            
            BEGIN
                -- Create a trace for this state change with pulse context
                l_trace_id := start_trace('pltelemetry.failover.activation');
                l_span_id := start_span('activate_oracle_fallback');
                
                -- Add enhanced events with pulse context
                add_event(l_span_id, 'pulse_mode_detected');
                add_event(l_span_id, CASE 
                    WHEN l_pulse_forced_fallback THEN 'pulse_forced_fallback'
                    ELSE 'agent_health_check_failed' 
                END);
                add_event(l_span_id, 'initiating_fallback_mode');
                
                -- Perform the activation
                activate_oracle_fallback();
                
                add_event(l_span_id, 'scheduler_job_enabled');
                add_event(l_span_id, 'fallback_mode_active');
                
                -- Add enhanced context attributes
                l_attrs(1) := add_attribute('previous.mode', l_current_mode);
                l_attrs(2) := add_attribute('new.mode', 'ORACLE_FALLBACK');
                l_attrs(3) := add_attribute('agent.health', l_agent_health);
                l_attrs(4) := add_attribute('queue.pending_items', TO_CHAR(l_queue_size));
                l_attrs(5) := add_attribute('pulse.mode', l_pulse_mode);
                l_attrs(6) := add_attribute('pulse.capacity', TO_CHAR(l_pulse_config.capacity_multiplier));
                l_attrs(7) := add_attribute('trigger.reason', CASE 
                    WHEN l_pulse_forced_fallback THEN 'pulse_mode_override'
                    ELSE 'agent_heartbeat_missing' 
                END);
                l_attrs(8) := add_attribute('agent.overridden', CASE WHEN l_agent_overridden THEN 'true' ELSE 'false' END);
                
                end_span(l_span_id, 'OK', l_attrs);
                end_trace(l_trace_id);
                
                -- Enhanced structured log with pulse context
                log_message(
                    p_level => 'WARN',
                    p_message => 'Fallback activated - ' || CASE 
                        WHEN l_pulse_forced_fallback THEN 'Pulse mode ' || l_pulse_mode || ' forced fallback'
                        ELSE 'Agent appears dead, Oracle taking over queue processing'
                    END,
                    p_attributes => l_attrs
                );
                
            EXCEPTION
                WHEN OTHERS THEN
                    -- FIXED: Guaranteed session state restoration
                    IF l_state_changed THEN
                        BEGIN
                            set_async_mode(l_original_async);
                        EXCEPTION WHEN OTHERS THEN NULL; END;
                    END IF;
                    RAISE;
            END;
            
            -- FIXED: Always restore original async mode
            IF l_state_changed THEN
                set_async_mode(l_original_async);
            END IF;
            
        ELSIF l_current_mode = 'ORACLE_FALLBACK' AND NOT l_should_fallback AND l_agent_health = 'HEALTHY' THEN
            -- RECOVERY: Agent recovered, switch back (but only if pulse mode allows)
            
            -- Additional pulse mode safety check for recovery
            IF l_pulse_mode IN ('PULSE4', 'COMA') THEN
                log_error_internal('manage_queue_processor', 
                    'Agent healthy but pulse mode ' || l_pulse_mode || ' indicates system stress - staying in fallback');
                RETURN; -- Don't switch back yet
            END IF;
            
            -- FIXED: Same session protection pattern for recovery
            set_async_mode(TRUE);
            l_state_changed := TRUE;
            
            BEGIN
                -- Create a trace for recovery with pulse context
                l_trace_id := start_trace('pltelemetry.failover.recovery');
                l_span_id := start_span('deactivate_oracle_fallback');
                
                -- Add recovery events with pulse awareness
                add_event(l_span_id, 'agent_heartbeat_detected');
                add_event(l_span_id, 'agent_health_verified');
                add_event(l_span_id, 'pulse_mode_compatible');
                add_event(l_span_id, 'initiating_recovery');
                
                -- Perform the deactivation
                deactivate_oracle_fallback();
                
                add_event(l_span_id, 'scheduler_job_disabled');
                add_event(l_span_id, 'control_returned_to_agent');
                
                -- Add enhanced context
                l_attrs(1) := add_attribute('previous.mode', l_current_mode);
                l_attrs(2) := add_attribute('new.mode', 'AGENT_PRIMARY');
                l_attrs(3) := add_attribute('agent.health', l_agent_health);
                l_attrs(4) := add_attribute('queue.pending_items', TO_CHAR(l_queue_size));
                l_attrs(5) := add_attribute('pulse.mode', l_pulse_mode);
                l_attrs(6) := add_attribute('pulse.capacity', TO_CHAR(l_pulse_config.capacity_multiplier));
                l_attrs(7) := add_attribute('recovery.reason', 'agent_healthy_and_pulse_compatible');
                
                end_span(l_span_id, 'OK', l_attrs);
                end_trace(l_trace_id);
                
                -- Enhanced structured log
                log_message(
                    p_level => 'INFO',
                    p_message => 'Agent recovered and pulse mode compatible - Switching back to external processing',
                    p_attributes => l_attrs
                );
                
            EXCEPTION
                WHEN OTHERS THEN
                    -- FIXED: Guaranteed session state restoration
                    IF l_state_changed THEN
                        BEGIN
                            set_async_mode(l_original_async);
                        EXCEPTION WHEN OTHERS THEN NULL; END;
                    END IF;
                    RAISE;
            END;
            
            -- FIXED: Always restore original async mode
            IF l_state_changed THEN
                set_async_mode(l_original_async);
            END IF;
        END IF;
        
        -- Rest of the function continues...
        
    EXCEPTION
        WHEN OTHERS THEN
            -- FIXED: Ultimate session state protection
            IF l_state_changed THEN
                BEGIN
                    set_async_mode(l_original_async);
                EXCEPTION WHEN OTHERS THEN NULL; END;
            END IF;
            
            log_error_internal('manage_queue_processor', 
                'Error in queue processor management (Pulse: ' || get_agent_pulse_mode() || '): ' || 
                SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
    END manage_queue_processor;



    /**
    * Get current processing mode
    */
    FUNCTION get_processing_mode RETURN VARCHAR2
    IS
        l_mode VARCHAR2(50);
    BEGIN
        SELECT config_value
        INTO l_mode
        FROM plt_failover_config
        WHERE config_key = 'PROCESSING_MODE';
        
        RETURN l_mode;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 'AGENT_PRIMARY';  -- Default mode
        WHEN OTHERS THEN
            RETURN 'AGENT_PRIMARY';
    END get_processing_mode;

    /**
    * Oracle-based queue processor (fallback implementation) with pulse throttling
    * Updated to coordinate with agent pulse mode and apply intelligent throttling
    */
    PROCEDURE process_queue_fallback(p_batch_size NUMBER DEFAULT 100)
    IS
        l_processed_count NUMBER := 0;
        l_error_count     NUMBER := 0;
        l_queue_id        NUMBER;
        l_payload         VARCHAR2(4000);
        l_total_processed NUMBER := 0;
        l_pulse_mode      VARCHAR2(10);
        l_config          plt_pulse_config_t;
        l_effective_batch NUMBER;
        l_processing_delay NUMBER;
        l_start_time      TIMESTAMP := SYSTIMESTAMP;
        l_end_time        TIMESTAMP;
        l_total_duration  NUMBER;
        
        TYPE t_queue_ids IS TABLE OF NUMBER;
        TYPE t_payloads IS TABLE OF VARCHAR2(4000);
        l_queue_ids t_queue_ids;
        l_payloads  t_payloads;
    BEGIN
        -- ========================================================================
        -- PULSE THROTTLING PRE-CHECKS AND CONFIGURATION
        -- ========================================================================
        
        -- Get current pulse configuration
        l_pulse_mode := get_agent_pulse_mode();
        l_config := get_pulse_throttling_config(l_pulse_mode);
        
        -- Check if queue processing is enabled for current pulse mode
        IF l_config.queue_processing = 'N' THEN
            log_error_internal('process_queue_fallback', 
                'Fallback queue processing disabled for pulse mode: ' || l_pulse_mode);
            RETURN;
        END IF;
        
        -- Calculate effective batch size with pulse throttling
        l_effective_batch := get_effective_batch_size(NVL(NULLIF(p_batch_size, 0), 100));
        
        -- Calculate processing delay based on pulse mode (micro-throttling)
        l_processing_delay := CASE l_pulse_mode
            WHEN 'PULSE1' THEN 0.001    -- 1ms between items
            WHEN 'PULSE2' THEN 0.002    -- 2ms between items  
            WHEN 'PULSE3' THEN 0.005    -- 5ms between items
            WHEN 'PULSE4' THEN 0.010    -- 10ms between items
            WHEN 'COMA'   THEN 0.100    -- 100ms between items (if somehow enabled)
            ELSE 0.001
        END;
        
        -- Log throttling application
        log_error_internal('process_queue_fallback', 
            'Fallback processing - Pulse: ' || l_pulse_mode || 
            ', Batch: ' || l_effective_batch || '/' || NVL(p_batch_size, 100) ||
            ', Delay: ' || (l_processing_delay * 1000) || 'ms');

        -- ========================================================================
        -- OTLP BRIDGE AUTO-CONFIGURATION WITH PULSE AWARENESS
        -- ========================================================================
        
        DECLARE
            l_collector_url VARCHAR2(500);
            l_service_name VARCHAR2(100);
            l_service_version VARCHAR2(50);
            l_environment VARCHAR2(50);
            l_debug_mode BOOLEAN := FALSE;
        BEGIN
            -- Get config from database
            SELECT MAX(CASE WHEN config_key = 'OTLP_COLLECTOR_URL' THEN config_value END),
                MAX(CASE WHEN config_key = 'OTLP_SERVICE_NAME' THEN config_value END),
                MAX(CASE WHEN config_key = 'OTLP_SERVICE_VERSION' THEN config_value END),
                MAX(CASE WHEN config_key = 'OTLP_ENVIRONMENT' THEN config_value END)
            INTO l_collector_url, l_service_name, l_service_version, l_environment
            FROM plt_failover_config
            WHERE config_key IN ('OTLP_COLLECTOR_URL', 'OTLP_SERVICE_NAME', 
                                'OTLP_SERVICE_VERSION', 'OTLP_ENVIRONMENT');
            
            -- Enable debug mode in high-throttling situations
            l_debug_mode := l_pulse_mode IN ('PULSE4', 'COMA');
            
            -- Configure OTLP Bridge if values found
            IF l_collector_url IS NOT NULL THEN
                PLT_OTLP_BRIDGE.set_otlp_collector(l_collector_url);
                PLT_OTLP_BRIDGE.set_service_info(
                    p_service_name => NVL(l_service_name, 'oracle-plsql-fallback'),
                    p_service_version => NVL(l_service_version, '1.0.0'),
                    p_deployment_environment => NVL(l_environment, 'production')
                );
                
                -- Only override debug mode if not already enabled
                /*
                IF NOT PLT_OTLP_BRIDGE.get_debug_mode() THEN
                    PLT_OTLP_BRIDGE.set_debug_mode(l_debug_mode);
                END IF;*/
                
                -- Set tenant context from pulse mode (for correlation)
                /* remove this if not needed
                PLT_OTLP_BRIDGE.set_tenant_context('pulse-' || LOWER(l_pulse_mode), 
                    'Pulse Mode ' || l_pulse_mode);*/
                PLT_OTLP_BRIDGE.clear_tenant_context();

            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                -- Log but don't fail - use defaults
                log_error_internal('process_queue_fallback', 
                    'Failed to configure OTLP Bridge for pulse ' || l_pulse_mode || ': ' || 
                    SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
        END;
        
        -- ========================================================================
        -- THROTTLED QUEUE PROCESSING
        -- ========================================================================
        
        -- Fetch items with throttled batch size
        SELECT queue_id, payload
        BULK COLLECT INTO l_queue_ids, l_payloads
        FROM (
            SELECT queue_id, payload
            FROM plt_queue
            WHERE processed = 'N'
            AND process_attempts < 5
            ORDER BY queue_id
        )
        WHERE ROWNUM <= l_effective_batch;
        
        -- Process each item with pulse-aware throttling
        FOR i IN 1..l_queue_ids.COUNT LOOP
            BEGIN
                -- Update attempt count
                UPDATE plt_queue
                SET process_attempts = process_attempts + 1,
                    last_attempt_time = SYSTIMESTAMP
                WHERE queue_id = l_queue_ids(i);
                
                -- Send to backend (this respects pulse throttling internally)
                send_to_backend_sync(l_payloads(i));
                
                -- Mark as processed
                UPDATE plt_queue
                SET processed = 'Y',
                    processed_time = SYSTIMESTAMP
                WHERE queue_id = l_queue_ids(i);
                
                l_processed_count := l_processed_count + 1;
                
                -- Apply micro-throttling delay between items
                IF l_processing_delay > 0 AND i < l_queue_ids.COUNT THEN
                    DBMS_LOCK.SLEEP(l_processing_delay);
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    UPDATE plt_queue
                    SET last_error = SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200)
                    WHERE queue_id = l_queue_ids(i);
                    
                    l_error_count := l_error_count + 1;
            END;
            
            -- Commit with pulse-aware frequency
            IF MOD(l_processed_count, CASE l_pulse_mode 
                WHEN 'PULSE1' THEN 50
                WHEN 'PULSE2' THEN 25  
                WHEN 'PULSE3' THEN 10
                WHEN 'PULSE4' THEN 5
                WHEN 'COMA' THEN 1
                ELSE 50
            END) = 0 THEN
                COMMIT;
            END IF;
        END LOOP;
        
        COMMIT;
        
        -- ========================================================================
        -- PULSE-AWARE REPORTING AND METRICS
        -- ========================================================================
        
        l_end_time := SYSTIMESTAMP;
        l_total_duration := EXTRACT(SECOND FROM (l_end_time - l_start_time)) * 1000; -- milliseconds
        
        -- Log summary with pulse context
        IF l_processed_count > 0 OR l_error_count > 0 THEN
            log_error_internal('process_queue_fallback', 
                'Fallback completed - Pulse: ' || l_pulse_mode || 
                ', Processed: ' || l_processed_count || 
                ', Errors: ' || l_error_count ||
                ', Duration: ' || ROUND(l_total_duration, 1) || 'ms' ||
                ', Throttled Batch: ' || l_effective_batch);
            
            -- Send enhanced metrics (only if metrics enabled for current pulse)
            IF should_process_telemetry('METRICS') THEN
                -- Fallback processing metrics
                log_metric(
                    p_metric_name => 'pltelemetry.fallback.items_processed',
                    p_value => l_processed_count,
                    p_unit => 'items',
                    p_include_trace_correlation => FALSE
                );
                
                -- Throttling effectiveness metrics
                log_metric(
                    p_metric_name => 'pltelemetry.fallback.effective_batch_size',
                    p_value => l_effective_batch,
                    p_unit => 'items',
                    p_include_trace_correlation => FALSE
                );
                
                log_metric(
                    p_metric_name => 'pltelemetry.fallback.processing_duration',
                    p_value => l_total_duration,
                    p_unit => 'ms',
                    p_include_trace_correlation => FALSE
                );
                
                -- Pulse mode tracking
                log_metric(
                    p_metric_name => 'pltelemetry.fallback.pulse_capacity',
                    p_value => l_config.capacity_multiplier * 100,
                    p_unit => 'percent',
                    p_include_trace_correlation => FALSE
                );
                
                IF l_error_count > 0 THEN
                    log_metric(
                        p_metric_name => 'pltelemetry.fallback.items_failed',
                        p_value => l_error_count,
                        p_unit => 'items',
                        p_include_trace_correlation => FALSE
                    );
                END IF;
            END IF;
            
            -- Record fallback metrics for circuit breaker and optimization
            BEGIN
                INSERT INTO plt_fallback_metrics (
                    metric_time,
                    batch_size,
                    items_processed,
                    items_failed,
                    avg_latency_ms,
                    http_errors,
                    total_duration_ms
                ) VALUES (
                    SYSTIMESTAMP,
                    l_effective_batch,
                    l_processed_count,
                    l_error_count,
                    CASE WHEN l_processed_count > 0 THEN l_total_duration / l_processed_count ELSE 0 END,
                    l_error_count, -- Simplified: treating all errors as HTTP errors for circuit breaker
                    l_total_duration
                );
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- Don't fail on metrics recording
            END;
        END IF;

        -- ========================================================================
        -- PULSE MODE ADAPTATION LOGGING
        -- ========================================================================
        
        -- In critical modes, log additional context for troubleshooting
        IF l_pulse_mode IN ('PULSE4', 'COMA') THEN
            DECLARE
                l_queue_remaining NUMBER;
            BEGIN
                SELECT COUNT(*) INTO l_queue_remaining
                FROM plt_queue WHERE processed = 'N';
                
                log_error_internal('process_queue_fallback', 
                    'Critical pulse mode active - Queue remaining: ' || l_queue_remaining || 
                    ' items, System under high load');
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        END IF;
            
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('process_queue_fallback', 
                'Critical error in fallback processor (Pulse: ' || get_agent_pulse_mode() || '): ' || 
                SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            ROLLBACK;
    END process_queue_fallback;

    /**
    * Initialize the failover system
    */
    PROCEDURE initialize_failover_system
    IS
    BEGIN

        -- Check if already initialized
        BEGIN
            DBMS_SCHEDULER.DROP_JOB('PLT_HEALTH_MONITOR', TRUE); -- TRUE = force
        EXCEPTION
            WHEN OTHERS THEN NULL; -- Job doesn't exist, that's fine
        END;

        -- Create health monitor job
        BEGIN
            DBMS_SCHEDULER.CREATE_JOB(
                job_name        => 'PLT_HEALTH_MONITOR',
                job_type        => 'PLSQL_BLOCK',
                job_action      => 'BEGIN PLTelemetry.manage_queue_processor; END;',
                start_date      => SYSTIMESTAMP,
                repeat_interval => 'FREQ=SECONDLY;INTERVAL=30',
                enabled         => TRUE,
                comments        => 'Monitor external agent health and manage failover'
            );
        EXCEPTION
            WHEN OTHERS THEN
                -- Job might already exist
                NULL;
        END;
        
        -- Create queue processor job (disabled initially)
        BEGIN
            DBMS_SCHEDULER.CREATE_JOB(
                job_name        => 'PLT_QUEUE_PROCESSOR',
                job_type        => 'PLSQL_BLOCK',
                job_action      => 'BEGIN PLTelemetry.process_queue_fallback(500); END;',
                start_date      => SYSTIMESTAMP,
                repeat_interval => 'FREQ=MINUTELY;INTERVAL=1',
                enabled         => FALSE,  -- Disabled by default
                comments        => 'Fallback queue processor when external agent is down'
            );
        EXCEPTION
            WHEN OTHERS THEN
                -- Job might already exist
                NULL;
        END;
        
        -- Initialize default config if not exists
        MERGE INTO plt_failover_config fc
        USING (SELECT 'PROCESSING_MODE' as key_val FROM dual) src
        ON (fc.config_key = src.key_val)
        WHEN NOT MATCHED THEN
            INSERT (config_key, config_value, description)
            VALUES ('PROCESSING_MODE', 'AGENT_PRIMARY', 'Current processing mode');
        
        COMMIT;
        
        log_error_internal('initialize_failover_system', 'Failover system initialized successfully');
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('initialize_failover_system', 
                'Error initializing failover system: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END initialize_failover_system;

    /**
    * Get failover configuration value
    */
    FUNCTION get_failover_config(p_key VARCHAR2) RETURN VARCHAR2
    IS
        l_value VARCHAR2(200);
    BEGIN
        SELECT config_value
        INTO l_value
        FROM plt_failover_config
        WHERE config_key = p_key;
        
        RETURN l_value;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
        WHEN OTHERS THEN
            RETURN NULL;
    END get_failover_config;

    /**
    * Set failover configuration value
    */
    PROCEDURE set_failover_config(p_key VARCHAR2, p_value VARCHAR2)
    IS
    BEGIN
        MERGE INTO plt_failover_config fc
        USING (SELECT p_key as key_val FROM dual) src
        ON (fc.config_key = src.key_val)
        WHEN MATCHED THEN
            UPDATE SET config_value = p_value, updated_at = SYSTIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (config_key, config_value, updated_at)
            VALUES (p_key, p_value, SYSTIMESTAMP);
        
        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('set_failover_config', 
                'Error setting config ' || p_key || ': ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END set_failover_config;

    FUNCTION calculate_optimal_batch_size RETURN NUMBER
    IS
        l_avg_latency    NUMBER;
        l_error_rate     NUMBER;
        l_optimal_size   NUMBER;
        l_min_batch      NUMBER;
        l_max_batch      NUMBER;
        l_total_items    NUMBER;
        l_failed_items   NUMBER;
    BEGIN
        -- Get metrics from last 5 minutes with proper aggregation
        SELECT 
            AVG(avg_latency_ms),
            SUM(items_failed),
            SUM(items_processed + items_failed)
        INTO l_avg_latency, l_failed_items, l_total_items
        FROM plt_fallback_metrics
        WHERE metric_time > SYSTIMESTAMP - INTERVAL '5' MINUTE;
        
        -- FIXED: Safe division by zero check
        IF l_total_items IS NULL OR l_total_items = 0 THEN
            l_error_rate := 0;
        ELSE
            l_error_rate := NVL(l_failed_items, 0) / l_total_items;
        END IF;
        
        -- Get configured limits
        l_min_batch := TO_NUMBER(NVL(get_failover_config('MIN_BATCH_SIZE'), '10'));
        l_max_batch := TO_NUMBER(NVL(get_failover_config('MAX_BATCH_SIZE'), '1000'));
        
        -- Get optimal size based on latency thresholds
        IF l_avg_latency IS NULL THEN
            -- No metrics yet, use conservative default
            l_optimal_size := TO_NUMBER(NVL(get_failover_config('DEFAULT_BATCH_SIZE'), '100'));
        ELSE
            -- Find the appropriate batch size based on latency
            BEGIN
                SELECT optimal_batch_size
                INTO l_optimal_size
                FROM (
                    SELECT optimal_batch_size
                    FROM plt_rate_limit_config
                    WHERE is_active = 'Y'
                    AND latency_threshold_ms >= l_avg_latency
                    ORDER BY priority
                )
                WHERE ROWNUM = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    -- Fallback if no config matches
                    l_optimal_size := TO_NUMBER(NVL(get_failover_config('DEFAULT_BATCH_SIZE'), '100'));
            END;
        END IF;
        
        -- Apply error rate penalty (now safe from division by zero)
        IF l_error_rate > 0.1 THEN -- More than 10% errors
            l_optimal_size := l_optimal_size * 0.5;
        ELSIF l_error_rate > 0.05 THEN -- More than 5% errors
            l_optimal_size := l_optimal_size * 0.75;
        END IF;
        
        -- Respect configured bounds
        RETURN GREATEST(l_min_batch, LEAST(l_max_batch, TRUNC(l_optimal_size)));
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Ultimate fallback
            RETURN NVL(TO_NUMBER(get_failover_config('DEFAULT_BATCH_SIZE')), 50);
    END calculate_optimal_batch_size;

    
    FUNCTION is_circuit_open RETURN BOOLEAN
    IS
        l_recent_errors     NUMBER;
        l_total_attempts    NUMBER;
        l_error_rate        NUMBER;
        l_circuit_state     VARCHAR2(20);
        l_last_state_change TIMESTAMP WITH TIME ZONE;
        l_threshold         NUMBER;
        l_recovery_time     NUMBER;
    BEGIN
        -- Get current circuit state
        l_circuit_state := NVL(get_failover_config('CIRCUIT_STATE'), 'CLOSED');
        
        -- Get circuit breaker thresholds from config
        l_threshold := TO_NUMBER(NVL(get_failover_config('CIRCUIT_ERROR_THRESHOLD'), '0.5')); -- 50% default
        l_recovery_time := TO_NUMBER(NVL(get_failover_config('CIRCUIT_RECOVERY_MINUTES'), '5')); -- 5 min default
        
        -- Check recent error rate (configurable window)
        SELECT 
            SUM(http_errors),
            SUM(items_processed + items_failed)
        INTO l_recent_errors, l_total_attempts
        FROM plt_fallback_metrics
        WHERE metric_time > SYSTIMESTAMP - INTERVAL '2' MINUTE;
        
        -- Calculate error rate
        IF l_total_attempts > 0 THEN
            l_error_rate := l_recent_errors / l_total_attempts;
        ELSE
            l_error_rate := 0;
        END IF;
        
        -- Circuit breaker state machine
        CASE l_circuit_state
            WHEN 'OPEN' THEN
                -- Check if enough time has passed to try recovery
                BEGIN
                    SELECT TO_TIMESTAMP_TZ(config_value, 'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM')
                    INTO l_last_state_change
                    FROM plt_failover_config
                    WHERE config_key = 'CIRCUIT_OPEN_TIME';
                    
                    IF l_last_state_change < SYSTIMESTAMP - (l_recovery_time / 1440) THEN  -- 1440 minutos en un día
                        -- Try half-open state
                        set_failover_config('CIRCUIT_STATE', 'HALF_OPEN');
                        log_error_internal('is_circuit_open', 'Circuit breaker: OPEN -> HALF_OPEN');
                        RETURN FALSE; -- Allow limited traffic
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        -- If no timestamp, close the circuit
                        set_failover_config('CIRCUIT_STATE', 'CLOSED');
                        RETURN FALSE;
                END;
                RETURN TRUE; -- Still open
                
            WHEN 'HALF_OPEN' THEN
                -- In half-open state, check if we should fully open or close
                IF l_total_attempts >= 10 THEN -- Need some attempts to decide
                    IF l_error_rate > l_threshold * 0.5 THEN -- Still failing (use lower threshold)
                        -- Back to open
                        set_failover_config('CIRCUIT_STATE', 'OPEN');
                        set_failover_config('CIRCUIT_OPEN_TIME', TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM'));
                        log_error_internal('is_circuit_open', 'Circuit breaker: HALF_OPEN -> OPEN (error rate: ' || ROUND(l_error_rate * 100, 1) || '%)');
                        RETURN TRUE;
                    ELSE
                        -- Recovery successful, close circuit
                        set_failover_config('CIRCUIT_STATE', 'CLOSED');
                        log_error_internal('is_circuit_open', 'Circuit breaker: HALF_OPEN -> CLOSED (recovered)');
                        RETURN FALSE;
                    END IF;
                END IF;
                RETURN FALSE; -- Continue in half-open
                
            ELSE -- CLOSED
                -- Check if we should open the circuit
                IF l_total_attempts > TO_NUMBER(NVL(get_failover_config('CIRCUIT_MIN_ATTEMPTS'), '50')) 
                AND l_error_rate > l_threshold THEN
                    -- Open the circuit
                    set_failover_config('CIRCUIT_STATE', 'OPEN');
                    set_failover_config('CIRCUIT_OPEN_TIME', TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM'));
                    log_error_internal('is_circuit_open', 'Circuit breaker: CLOSED -> OPEN (error rate: ' || ROUND(l_error_rate * 100, 1) || '%)');
                    RETURN TRUE;
                END IF;
                RETURN FALSE; -- Circuit remains closed
        END CASE;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- On any error, default to closed (allow traffic)
            log_error_internal('is_circuit_open', 
                'Circuit breaker check failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RETURN FALSE;
    END is_circuit_open;

    -- ========================================================================
    -- PULSE THROTTLING MANAGEMENT - BODY IMPLEMENTATION
    -- ========================================================================

    /**
     * Get current agent pulse mode from failover config
     */
    FUNCTION get_agent_pulse_mode RETURN VARCHAR2
    IS
        l_pulse_mode VARCHAR2(10);
    BEGIN
        SELECT config_value
        INTO l_pulse_mode
        FROM plt_failover_config
        WHERE config_key = 'AGENT_PULSE_MODE';
        
        RETURN l_pulse_mode;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 'PULSE1';  -- Default to full capacity
        WHEN OTHERS THEN
            log_error_internal('get_agent_pulse_mode', 
                'Error reading agent pulse mode: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RETURN 'PULSE1';  -- Safe fallback
    END get_agent_pulse_mode;

    /**
     * Get throttling configuration for specific pulse mode
     */
    FUNCTION get_pulse_throttling_config(p_pulse_mode VARCHAR2) RETURN plt_pulse_config_t
    IS
        l_config plt_pulse_config_t;
    BEGIN
        SELECT plt_pulse_config_t(
            pulse_mode,
            capacity_multiplier,
            batch_multiplier,
            interval_multiplier,
            sampling_rate,
            metrics_enabled,
            logs_enabled,
            queue_processing,
            description
        )
        INTO l_config
        FROM plt_pulse_throttling_config
        WHERE pulse_mode = p_pulse_mode
          AND is_active = 'Y';
        
        RETURN l_config;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- Return default PULSE1 config
            SELECT plt_pulse_config_t(
                'PULSE1', 1.0, 1.0, 1.0, 1.0, 'Y', 'Y', 'Y', 'Default fallback config'
            ) INTO l_config FROM dual;
            
            log_error_internal('get_pulse_throttling_config', 
                'Pulse mode not found: ' || p_pulse_mode || ', using PULSE1 defaults');
            RETURN l_config;
            
        WHEN OTHERS THEN
            -- Return safe fallback
            SELECT plt_pulse_config_t(
                'PULSE1', 1.0, 1.0, 1.0, 1.0, 'Y', 'Y', 'Y', 'Error fallback config'
            ) INTO l_config FROM dual;
            
            log_error_internal('get_pulse_throttling_config', 
                'Error getting pulse config: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RETURN l_config;
    END get_pulse_throttling_config;

    /**
     * Apply pulse throttling to a numeric value
     */
    FUNCTION apply_pulse_throttling(
        p_original_value NUMBER, 
        p_multiplier_type VARCHAR2
    ) RETURN NUMBER
    IS
        l_pulse_mode VARCHAR2(10);
        l_config plt_pulse_config_t;
        l_multiplier NUMBER;
        l_result NUMBER;
    BEGIN
        -- Get current pulse mode
        l_pulse_mode := get_agent_pulse_mode();
        
        -- Get throttling config
        l_config := get_pulse_throttling_config(l_pulse_mode);
        
        -- Select appropriate multiplier
        l_multiplier := CASE UPPER(p_multiplier_type)
            WHEN 'BATCH' THEN l_config.batch_multiplier
            WHEN 'INTERVAL' THEN l_config.interval_multiplier
            WHEN 'SAMPLING' THEN l_config.sampling_rate
            WHEN 'CAPACITY' THEN l_config.capacity_multiplier
            ELSE 1.0  -- No throttling for unknown types
        END;
        
        -- Apply multiplier with bounds checking
        l_result := p_original_value * l_multiplier;
        
        -- Ensure minimum values for certain types
        IF UPPER(p_multiplier_type) = 'BATCH' THEN
            l_result := GREATEST(l_result, 1);  -- Minimum batch size of 1
        ELSIF UPPER(p_multiplier_type) = 'INTERVAL' THEN
            l_result := GREATEST(l_result, 1);  -- Minimum interval of 1 second
        END IF;
        
        RETURN TRUNC(l_result);
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('apply_pulse_throttling', 
                'Error applying throttling: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RETURN p_original_value;  -- Return original on error
    END apply_pulse_throttling;

    /**
     * Check if specific telemetry type should be processed based on pulse mode
     */
    FUNCTION should_process_telemetry(p_telemetry_type VARCHAR2) RETURN BOOLEAN
    IS
        l_pulse_mode VARCHAR2(10);
        l_config plt_pulse_config_t;
    BEGIN
        l_pulse_mode := get_agent_pulse_mode();
        l_config := get_pulse_throttling_config(l_pulse_mode);
        
        RETURN CASE UPPER(p_telemetry_type)
            WHEN 'METRICS' THEN l_config.metrics_enabled = 'Y'
            WHEN 'LOGS' THEN l_config.logs_enabled = 'Y'
            WHEN 'QUEUE' THEN l_config.queue_processing = 'Y'
            ELSE TRUE  -- Allow unknown types
        END;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('should_process_telemetry', 
                'Error checking telemetry processing: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RETURN TRUE;  -- Safe fallback - allow processing
    END should_process_telemetry;

    /**
     * Get effective batch size based on current pulse mode
     */
    FUNCTION get_effective_batch_size(p_requested_batch_size NUMBER) RETURN NUMBER
    IS
    BEGIN
        RETURN apply_pulse_throttling(p_requested_batch_size, 'BATCH');
    END get_effective_batch_size;

    /**
     * Check if telemetry should be sampled based on pulse mode
     */
    FUNCTION should_sample_telemetry RETURN BOOLEAN
    IS
        l_pulse_mode VARCHAR2(10);
        l_config plt_pulse_config_t;
        l_random NUMBER;
    BEGIN
        l_pulse_mode := get_agent_pulse_mode();
        l_config := get_pulse_throttling_config(l_pulse_mode);
        
        -- Generate random number between 0 and 1
        l_random := DBMS_RANDOM.VALUE(0, 1);
        
        -- Sample if random number is less than sampling rate
        RETURN l_random <= l_config.sampling_rate;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('should_sample_telemetry', 
                'Error in telemetry sampling: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RETURN TRUE;  -- Safe fallback - always sample on error
    END should_sample_telemetry;

    /**
     * Update scheduler job intervals based on current pulse mode
     */
    PROCEDURE update_job_interval_for_pulse(p_job_name VARCHAR2)
    IS
        l_pulse_mode VARCHAR2(10);
        l_config plt_pulse_config_t;
        l_base_interval NUMBER := 60; -- Base interval in seconds
        l_new_interval NUMBER;
        l_interval_string VARCHAR2(100);
    BEGIN
        l_pulse_mode := get_agent_pulse_mode();
        l_config := get_pulse_throttling_config(l_pulse_mode);
        
        -- Calculate new interval
        l_new_interval := l_base_interval * l_config.interval_multiplier;
        
        -- Build interval string for DBMS_SCHEDULER
        l_interval_string := 'FREQ=SECONDLY;INTERVAL=' || TRUNC(l_new_interval);
        
        -- Update the job
        DBMS_SCHEDULER.SET_ATTRIBUTE(
            name => p_job_name,
            attribute => 'repeat_interval',
            value => l_interval_string
        );
        
        log_error_internal('update_job_interval_for_pulse', 
            'Updated job ' || p_job_name || ' interval to ' || l_new_interval || 's for pulse ' || l_pulse_mode);
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('update_job_interval_for_pulse', 
                'Error updating job interval: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
    END update_job_interval_for_pulse;

END PLTelemetry;
/