CREATE OR REPLACE PACKAGE BODY PLTelemetry
AS

    /**
     * PLTelemetry - OpenTelemetry SDK for PL/SQL
     * 
     * This package provides a generic, backend-agnostic implementation of
     * distributed tracing for Oracle PL/SQL applications following OpenTelemetry standards.
     * 
     * Requirements: Oracle 12c+ with native JSON support
     * 
     * JSON Format:
     * - Traces: {"trace_id", "operation", "start_time", "service_name"}
     * - Spans: {"trace_id", "span_id", "operation", "start_time", "end_time", "duration_ms", "status", "attributes"}
     * - Metrics: {"name", "value", "unit", "timestamp", "trace_id", "span_id", "attributes"}
     * 
     * Backend Integration:
     * The package sends JSON payloads to g_backend_url. Implement your own
     * backend adapter to transform this generic format to your specific needs.
     */

    --------------------------------------------------------------------------
    -- PRIVATE HELPER FUNCTIONS
    --------------------------------------------------------------------------
   
    /**
     * Validate attribute key follows OpenTelemetry naming conventions
     */
    FUNCTION validate_attribute_key(p_key VARCHAR2) 
        RETURN BOOLEAN 
    IS
    BEGIN
        -- OpenTelemetry attribute naming conventions
        RETURN REGEXP_LIKE(p_key, '^[a-zA-Z][a-zA-Z0-9._]*$')
               AND LENGTH(p_key) <= 255;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END validate_attribute_key;
   
    /**
     * Generates a random ID of specified byte length using Oracle 12c+ features
     * 
     * @param p_bytes Number of bytes (8 or 16)
     * @return Hex string representation of the random ID
     */
    FUNCTION generate_id (p_bytes IN NUMBER)
        RETURN VARCHAR2
    IS
        l_length NUMBER;
    BEGIN
        -- Validate input
        IF p_bytes NOT IN (8, 16) THEN
            RAISE_APPLICATION_ERROR (-20001, 'Size must be 8 or 16 bytes');
        END IF;
        
        -- Calculate hex string length (bytes * 2)
        l_length := p_bytes * 2;
        
        -- Generate proper hex string using Oracle 12c+ functions
        RETURN LOWER(
            TRANSLATE(
                DBMS_RANDOM.STRING('U', l_length), 
                'GHIJKLMNOPQRSTUVWXYZ', 
                '0123456789ABCDEF0123'
            )
        );
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback: SYS_GUID gives us 16 bytes, truncate if needed
            RETURN LOWER(SUBSTR(RAWTOHEX(SYS_GUID()), 1, p_bytes * 2));
    END generate_id;

    /**
     * Generates a 128-bit trace ID following OpenTelemetry spec
     * 
     * @return 32 character hex string trace ID
     */
    FUNCTION generate_trace_id
        RETURN VARCHAR2
    IS
    BEGIN
        RETURN generate_id(16);
    END generate_trace_id;

    /**
     * Generates a 64-bit span ID following OpenTelemetry spec
     * 
     * @return 16 character hex string span ID
     */
    FUNCTION generate_span_id
        RETURN VARCHAR2
    IS
    BEGIN
        RETURN generate_id(8);
    END generate_span_id;

    --------------------------------------------------------------------------
    -- JSON UTILITY FUNCTIONS (Native Oracle 12c+ only)
    --------------------------------------------------------------------------

    /**
     * Extract value from JSON using native Oracle JSON functions
     */
    FUNCTION get_json_value (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
    BEGIN
        -- Use JSON_VALUE for better parsing (Oracle 12c+)
        RETURN JSON_VALUE(p_json, '$.' || p_key);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END get_json_value;

    /**
     * Extract JSON object from JSON using native Oracle JSON functions
     */
    FUNCTION get_json_object (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
    BEGIN
        -- Use JSON_QUERY for object extraction (Oracle 12c+)
        RETURN JSON_QUERY(p_json, '$.' || p_key);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
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

        -- Parse using native JSON (Oracle 12c+)
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
            -- Return minimal valid JSON on error
            IF DBMS_LOB.ISTEMPORARY(l_result) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_result);
            END IF;
            
            DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
            DBMS_LOB.WRITEAPPEND(l_result, 2, '[]');
            RETURN l_result;
    END convert_attributes_to_otlp;

    --------------------------------------------------------------------------
    -- BACKEND COMMUNICATION
    --------------------------------------------------------------------------

    /**
     * Sends telemetry data synchronously via HTTP
     * 
     * @param p_json JSON payload to send to backend
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
    BEGIN
        -- Validate input
        IF p_json IS NULL THEN
            RETURN;
        END IF;

        -- ===== BRIDGE SUPPORT =====
        -- Check if using a custom bridge implementation
        IF g_backend_url = 'POSTGRES_BRIDGE' THEN
            BEGIN
                -- Route to PostgreSQL bridge
                PLT_POSTGRES_BRIDGE.send_to_backend_with_routing(p_json);
                RETURN;
            EXCEPTION
                WHEN OTHERS THEN
                    -- Log bridge error but don't fail
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                    
                    INSERT INTO plt_telemetry_errors (
                        error_time, 
                        error_message, 
                        module_name
                    ) VALUES (
                        SYSTIMESTAMP, 
                        'Bridge routing failed: ' || l_error_msg, 
                        'send_to_backend_sync'
                    );
                    
                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                    
                    -- Don't propagate - telemetry should never break the app
                    RETURN;
            END;
        ELSIF g_backend_url = 'OTLP_BRIDGE' THEN
            BEGIN
                -- Route to OTLP bridge
                PLT_OTLP_BRIDGE.route_to_otlp(p_json);
                RETURN;
            EXCEPTION
                WHEN OTHERS THEN
                    -- Log bridge error but don't fail
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                    
                    INSERT INTO plt_telemetry_errors (
                        error_time, 
                        error_message, 
                        module_name
                    ) VALUES (
                        SYSTIMESTAMP, 
                        'OTLP Bridge routing failed: ' || l_error_msg, 
                        'send_to_backend_sync'
                    );
                    
                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                    
                    RETURN;
            END;
        END IF;
        -- ===== END BRIDGE SUPPORT =====

        -- Original HTTP implementation continues here...
        
        -- Get length in characters
        l_length := LENGTH(p_json);

        -- Validate URL before using
        IF g_backend_url IS NULL OR LENGTH(g_backend_url) < 10 THEN
            -- Log configuration error
            INSERT INTO plt_telemetry_errors (error_time, error_message, module_name)
                 VALUES (SYSTIMESTAMP, 'Invalid backend URL configured', 'send_to_backend_sync');

            IF g_autocommit THEN
                COMMIT;
            END IF;

            RETURN;
        END IF;

        -- Set timeout with validation
        UTL_HTTP.SET_TRANSFER_TIMEOUT(NVL(g_backend_timeout, 30));

        -- Send to backend
        l_req := UTL_HTTP.BEGIN_REQUEST(g_backend_url, 'POST', 'HTTP/1.1');

        -- Set headers - use LENGTHB for byte count
        UTL_HTTP.SET_HEADER(l_req, 'Content-Type', 'application/json; charset=utf-8');
        UTL_HTTP.SET_HEADER(l_req, 'Content-Length', LENGTHB(p_json));
        UTL_HTTP.SET_HEADER(l_req, 'X-OTel-Source', 'PLTelemetry');
        UTL_HTTP.SET_HEADER(l_req, 'X-PLSQL-API-KEY', NVL(g_api_key, 'not-configured'));
        UTL_HTTP.SET_HEADER(l_req, 'X-PLSQL-DB', SYS_CONTEXT('USERENV', 'DB_NAME'));

        -- Send VARCHAR2 directly if small enough
        IF l_length <= 32767 THEN
            UTL_HTTP.WRITE_TEXT(l_req, p_json);
        ELSE
            -- Send in chunks if larger
            WHILE l_offset <= l_length LOOP
                l_amount := LEAST(32767, l_length - l_offset + 1);
                l_buffer := SUBSTR(p_json, l_offset, l_amount);
                UTL_HTTP.WRITE_TEXT(l_req, l_buffer);
                l_offset := l_offset + l_amount;
            END LOOP;
        END IF;

        l_res := UTL_HTTP.GET_RESPONSE(l_req);

        -- Check response status
        IF l_res.status_code NOT IN (200, 201, 202, 204) THEN
            -- Log failed send with truncated payload
            BEGIN
                LOOP
                    UTL_HTTP.READ_TEXT(l_res, l_chunk, 32767);
                    l_response_body := l_response_body || l_chunk;
                END LOOP;
            EXCEPTION
                WHEN UTL_HTTP.END_OF_BODY THEN
                    NULL;
            END;
            
            -- Log with response body
            INSERT INTO plt_failed_exports (export_time,
                                           http_status,
                                           payload,
                                           error_message)
                 VALUES (SYSTIMESTAMP,
                         l_res.status_code,
                         SUBSTR(p_json, 1, 4000),
                         'HTTP ' || l_res.status_code || ': ' || SUBSTR(l_response_body, 1, 3000));
        END IF;

        UTL_HTTP.END_RESPONSE(l_res);
    EXCEPTION
        WHEN UTL_HTTP.TRANSFER_TIMEOUT THEN
            -- Save error details before any operations
            l_error_msg := 'Backend timeout after ' || NVL(g_backend_timeout, 30) || ' seconds';

            -- Clean up connection if exists
            BEGIN
                IF l_res.status_code IS NOT NULL THEN
                    UTL_HTTP.END_RESPONSE(l_res);
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;

            -- Log timeout
            BEGIN
                INSERT INTO plt_failed_exports (export_time, payload, error_message)
                     VALUES (SYSTIMESTAMP, SUBSTR(p_json, 1, 4000), l_error_msg);

                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        WHEN OTHERS THEN
            -- Save error details
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

            -- Clean up connection if exists
            BEGIN
                IF l_res.status_code IS NOT NULL THEN
                    UTL_HTTP.END_RESPONSE(l_res);
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;

            -- Log error but don't fail the business logic
            BEGIN
                INSERT INTO plt_failed_exports (export_time,
                                                payload,
                                                error_message,
                                                http_status)
                     VALUES (SYSTIMESTAMP,
                             SUBSTR(p_json, 1, 4000),
                             'Error: ' || l_error_msg,
                             -1  -- Indicate non-HTTP error
                               );

                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
    END send_to_backend_sync;

    --------------------------------------------------------------------------
    -- CORE TRACING FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Starts a new trace with the given operation name
     */
    FUNCTION start_trace (p_operation VARCHAR2)
        RETURN VARCHAR2
    IS
        l_trace_id      VARCHAR2(32);
        l_retry_count   NUMBER := 0;
        l_max_retries   CONSTANT NUMBER := 3;
        l_error_msg     VARCHAR2(4000);
    BEGIN
        LOOP
            BEGIN
                l_trace_id := generate_trace_id();
                g_current_trace_id := l_trace_id;

                -- Set context for visibility
                set_trace_context();

                -- Log trace start
                INSERT INTO plt_traces (trace_id,
                                       root_operation,
                                       start_time,
                                       service_name,
                                       service_instance)
                     VALUES (l_trace_id,
                            p_operation,
                            SYSTIMESTAMP,
                            'oracle-plsql',
                            SYS_CONTEXT('USERENV', 'HOST') || ':' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME'));

                -- Paranoid check
                IF SQL%ROWCOUNT != 1 THEN
                    RAISE_APPLICATION_ERROR(-20001, 'PLTelemetry: Failed to insert trace - rowcount=' || SQL%ROWCOUNT);
                END IF;

                IF g_autocommit THEN
                    COMMIT;
                END IF;
                
                RETURN l_trace_id;  -- Success! Exit function
            EXCEPTION
                WHEN OTHERS THEN
                    l_retry_count := l_retry_count + 1;

                    -- Check if it's a DUP_VAL_ON_INDEX (without naming it)
                    IF SQLCODE = -1 AND l_retry_count < l_max_retries THEN
                        -- It's a unique constraint, retry with new ID
                        NULL;  -- Continue loop
                    ELSE
                        -- Any other error or max retries reached
                        BEGIN
                            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

                            INSERT INTO plt_telemetry_errors (error_time, 
                                                             error_message, 
                                                             module_name,
                                                             trace_id)
                                 VALUES (SYSTIMESTAMP, 
                                        l_error_msg, 
                                        'start_trace: ' || SUBSTR(NVL(p_operation, 'unknown'), 1, 80),
                                        l_trace_id);

                            IF g_autocommit THEN
                                COMMIT;
                            END IF;
                        EXCEPTION
                            WHEN OTHERS THEN
                                NULL;  -- Give up on error logging
                        END;

                        -- Exit loop and return the trace_id anyway
                        RETURN l_trace_id;
                    END IF;
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
            -- Update trace end time if not already set
            UPDATE plt_traces
            SET end_time = SYSTIMESTAMP
            WHERE trace_id = l_trace_id
              AND end_time IS NULL;
            
            -- Clear context if it's the current trace
            IF l_trace_id = g_current_trace_id THEN
                clear_trace_context();
            END IF;
            
            IF g_autocommit THEN
                COMMIT;
            END IF;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Never fail on trace cleanup
            NULL;
    END end_trace;

    /**
     * Starts a new span within a trace
     */
    FUNCTION start_span (p_operation VARCHAR2, p_parent_span_id VARCHAR2 DEFAULT NULL, p_trace_id VARCHAR2 DEFAULT NULL)
        RETURN VARCHAR2
    IS
        l_span_id       VARCHAR2(16);
        l_trace_id      VARCHAR2(32);
        l_retry_count   NUMBER := 0;
        l_max_retries   CONSTANT NUMBER := 3;
        l_error_msg     VARCHAR2(4000);
    BEGIN
        LOOP
            BEGIN
                l_span_id := generate_span_id();
                g_current_span_id := l_span_id;

                -- Use provided trace_id or current one
                l_trace_id := NVL(p_trace_id, NVL(g_current_trace_id, generate_trace_id()));
                g_current_trace_id := l_trace_id;

                -- Set context for visibility
                set_trace_context();

                -- Log span start
                INSERT INTO plt_spans (trace_id,
                                      span_id,
                                      parent_span_id,
                                      operation_name,
                                      start_time,
                                      status)
                     VALUES (l_trace_id,
                            l_span_id,
                            p_parent_span_id,
                            p_operation,
                            SYSTIMESTAMP,
                            'RUNNING');

                -- Paranoid check
                IF SQL%ROWCOUNT != 1 THEN
                    RAISE_APPLICATION_ERROR(-20002, 'PLTelemetry: Failed to insert span - rowcount=' || SQL%ROWCOUNT);
                END IF;

                IF g_autocommit THEN
                    COMMIT;
                END IF;

                RETURN l_span_id;  -- Success!
            EXCEPTION
                WHEN OTHERS THEN
                    l_retry_count := l_retry_count + 1;

                    -- Check if it's a unique constraint violation
                    IF SQLCODE = -1 AND l_retry_count < l_max_retries THEN
                        -- Retry with new span_id
                        NULL;  -- Continue loop
                    ELSE
                        -- Any other error or max retries reached
                        BEGIN
                            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

                            INSERT INTO plt_telemetry_errors (error_time,
                                                             error_message,
                                                             module_name,
                                                             trace_id,
                                                             span_id)
                                 VALUES (SYSTIMESTAMP,
                                        l_error_msg,
                                        'start_span: ' || SUBSTR(NVL(p_operation, 'unknown'), 1, 80),
                                        l_trace_id,
                                        l_span_id);

                            IF g_autocommit THEN
                                COMMIT;
                            END IF;
                        EXCEPTION
                            WHEN OTHERS THEN
                                NULL;  -- Give up on error logging
                        END;

                        -- Important: still set the context even if DB insert failed
                        g_current_span_id := l_span_id;
                        g_current_trace_id := l_trace_id;

                        -- Return the span_id anyway - telemetry must continue!
                        RETURN l_span_id;
                    END IF;
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
    BEGIN
        -- Validate input
        IF p_span_id IS NULL THEN
            RETURN;  -- Silent fail for null span_id
        END IF;

        BEGIN
            -- Get span info including operation_name and calculate duration
            SELECT start_time, 
                   operation_name,
                   parent_span_id,
                   EXTRACT(SECOND FROM (SYSTIMESTAMP - start_time)) * 1000
            INTO l_start_time, l_operation_name, l_parent_span_id, l_duration
            FROM plt_spans
            WHERE span_id = p_span_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- Span doesn't exist, log and exit
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time,
                                                      error_message,
                                                      module_name,
                                                      span_id)
                         VALUES (SYSTIMESTAMP,
                                 'end_span: Span not found',
                                 'end_span',
                                 p_span_id);

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;
                END;

                RETURN;
            WHEN TOO_MANY_ROWS THEN
                -- This should never happen with proper PK, but...
                l_duration := 0;
                l_operation_name := 'unknown_operation';
        END;

        -- Update span in Oracle
        UPDATE plt_spans
        SET end_time = SYSTIMESTAMP, duration_ms = l_duration, status = p_status
        WHERE span_id = p_span_id AND end_time IS NULL;  -- Don't update already ended spans

        -- Check if update actually did something
        IF SQL%ROWCOUNT = 0 THEN
            -- Span already ended or doesn't exist
            BEGIN
                INSERT INTO plt_telemetry_errors (error_time,
                                                  error_message,
                                                  module_name,
                                                  span_id)
                     VALUES (SYSTIMESTAMP,
                             'end_span: Span already ended or not found',
                             'end_span',
                             p_span_id);

                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;

            RETURN;
        END IF;

        -- Update trace end time (optional update, don't check rowcount)
        UPDATE plt_traces
        SET end_time = SYSTIMESTAMP
        WHERE trace_id = g_current_trace_id
          AND NOT EXISTS
              (SELECT 1
               FROM plt_spans
               WHERE trace_id = g_current_trace_id AND span_id != p_span_id AND end_time IS NULL);

        -- Build attributes JSON using native JSON
        BEGIN
            l_attrs_json := attributes_to_json(p_attributes);
        EXCEPTION
            WHEN OTHERS THEN
                l_attrs_json := '{}';  -- Empty JSON on error
        END;

        -- Build events JSON using native JSON
        BEGIN
            -- Get events for this span using native JSON functions
            SELECT JSON_ARRAYAGG(
                JSON_OBJECT(
                    'name' VALUE event_name,
                    'time' VALUE TO_CHAR(event_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'),
                    'attributes' VALUE CASE 
                        WHEN attributes IS NOT NULL AND attributes != '{}' 
                        THEN JSON_OBJECT('data' VALUE attributes)
                        ELSE JSON_OBJECT()
                    END
                )
                ORDER BY event_time
            ) INTO l_events_json
            FROM plt_events 
            WHERE span_id = p_span_id;
            
            -- If no events found, set empty array
            IF l_events_json IS NULL THEN
                l_events_json := '[]';
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                -- Fallback to empty events on any error
                l_events_json := '[]';
                
                -- Log the issue but don't fail
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time,
                                                      error_message,
                                                      module_name,
                                                      span_id)
                         VALUES (SYSTIMESTAMP,
                                 'Failed to build events JSON: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200),
                                 'end_span',
                                 p_span_id);
                    IF g_autocommit THEN 
                        COMMIT; 
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN 
                        NULL;
                END;
        END;

        -- Build complete JSON with all required fields including events
        l_json := '{'
            || '"trace_id":"' || NVL(g_current_trace_id, 'unknown') || '",'
            || '"span_id":"' || p_span_id || '",'
            || '"parent_span_id":"' || NVL(l_parent_span_id, '') || '",'
            || '"operation_name":"' || REPLACE(l_operation_name, '"', '\"') || '",' 
            || '"start_time":"' || TO_CHAR(l_start_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'  
            || '"end_time":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'   
            || '"duration_ms":' || NVL(TO_CHAR(l_duration), '0') || ','
            || '"status":"' || NVL(p_status, 'OK') || '",'
            || '"events":' || l_events_json || ','
            || '"attributes":' || l_attrs_json
            || '}';

        -- Validate JSON using native Oracle 12c+ functions
        BEGIN
            IF l_json IS NOT JSON THEN
                RAISE_APPLICATION_ERROR(-20003, 'Invalid JSON structure');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                -- Log invalid JSON
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time,
                                                      error_message,
                                                      module_name,
                                                      span_id)
                         VALUES (SYSTIMESTAMP,
                                 'Invalid JSON: ' || SUBSTR(l_json, 1, 200),
                                 'end_span',
                                 p_span_id);

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;
                END;

                RETURN;  -- Don't send invalid JSON
        END;

        -- Send to backend
        send_to_backend(l_json);

        IF g_autocommit THEN
            COMMIT;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Global exception handler
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

            BEGIN
                INSERT INTO plt_telemetry_errors (error_time,
                                                  error_message,
                                                  error_stack,
                                                  module_name,
                                                  span_id)
                     VALUES (SYSTIMESTAMP,
                             l_error_msg,
                             SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000),
                             'end_span',
                             p_span_id);

                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;

            -- Try to at least update the span as FAILED
            BEGIN
                UPDATE plt_spans
                SET end_time = SYSTIMESTAMP, status = 'ERROR', duration_ms = 0
                WHERE span_id = p_span_id AND end_time IS NULL;

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
    BEGIN
        -- Validate inputs
        IF p_span_id IS NULL OR p_event_name IS NULL THEN
            -- Silent fail for null required params
            RETURN;
        END IF;

        -- Convert attributes to JSON with protection
        BEGIN
            IF p_attributes.COUNT > 0 THEN
                l_attrs_varchar := attributes_to_json(p_attributes);
            ELSE
                l_attrs_varchar := '{}';
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                -- If attributes fail, use empty JSON
                l_attrs_varchar := '{}';

                -- Log the issue but continue
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time,
                                                     error_message,
                                                     module_name,
                                                     span_id)
                         VALUES (SYSTIMESTAMP,
                                'add_event: Failed to convert attributes - ' || SUBSTR(l_error_msg, 1, 200),
                                'add_event: ' || SUBSTR(p_event_name, 1, 80),
                                p_span_id);

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;
                END;
        END;

        -- Validate JSON if we have one
        IF l_attrs_varchar IS NOT NULL AND l_attrs_varchar != '{}' THEN
            BEGIN
                IF l_attrs_varchar IS NOT JSON THEN
                    l_attrs_varchar := '{}';  -- Fallback to empty
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    l_attrs_varchar := '{}';  -- Fallback on validation error
            END;
        END IF;

        -- Insert event
        BEGIN
            INSERT INTO plt_events (span_id,
                                   event_name,
                                   event_time,
                                   attributes)
                 VALUES (p_span_id,
                        SUBSTR(p_event_name, 1, 255),  -- Truncate if too long
                        SYSTIMESTAMP,
                        l_attrs_varchar);

            -- Paranoid check
            IF SQL%ROWCOUNT != 1 THEN
                RAISE_APPLICATION_ERROR(-20004, 'PLTelemetry: Failed to insert event - rowcount=' || SQL%ROWCOUNT);
            END IF;

            IF g_autocommit THEN
                COMMIT;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                -- Event logging failed, but don't crash the app
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time,
                                                     error_message,
                                                     module_name,
                                                     span_id)
                         VALUES (SYSTIMESTAMP,
                                l_error_msg,
                                'add_event: ' || SUBSTR(p_event_name, 1, 80),
                                p_span_id);

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;  -- Even error logging can fail
                END;
        END;
    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

            -- Global exception handler - should never reach here but...
            -- Log if possible but NEVER propagate
            BEGIN
                INSERT INTO plt_telemetry_errors (error_time,
                                                 error_message,
                                                 module_name,
                                                 span_id)
                     VALUES (SYSTIMESTAMP,
                            'add_event: Unexpected error - ' || SUBSTR(l_error_msg, 1, 200),
                            'add_event',
                            p_span_id);

                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
    END add_event;

    /**
     * Records a metric value with associated metadata
     */
    PROCEDURE log_metric (p_metric_name    VARCHAR2,
                         p_value          NUMBER,
                         p_unit           VARCHAR2 DEFAULT NULL,
                         p_attributes     t_attributes DEFAULT t_attributes())
    IS
        l_json         VARCHAR2(32767);
        l_attrs_json   VARCHAR2(4000);
        l_error_msg    VARCHAR2(4000);
        l_value_str    VARCHAR2(50);
    BEGIN
        -- Validate required inputs
        IF p_metric_name IS NULL OR p_value IS NULL THEN
            RETURN;  -- Silent fail for missing required params
        END IF;

        -- Convert attributes to JSON safely
        BEGIN
            l_attrs_json := attributes_to_json(p_attributes);
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                l_attrs_json := '{}';

                -- Log attribute conversion failure
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time, 
                                                     error_message, 
                                                     module_name)
                         VALUES (SYSTIMESTAMP,
                                'log_metric: Failed to convert attributes - ' || SUBSTR(l_error_msg, 1, 200),
                                'log_metric: ' || SUBSTR(p_metric_name, 1, 80));

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;
                END;
        END;

        -- Handle special number cases (NaN, Infinity, etc)
        BEGIN
            IF p_value IS NOT NULL THEN
                l_value_str := TO_CHAR(p_value, 'FM999999999999990.999999999', 'NLS_NUMERIC_CHARACTERS=''.,''');
            ELSE
                l_value_str := '0';
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                l_value_str := '0';  -- Default on conversion error
        END;

        -- Build metric JSON with escaping
        BEGIN
            l_json :=
                   '{'
                || '"name":"'
                || REPLACE(SUBSTR(p_metric_name, 1, 255), '"', '\"')
                || '",'
                || '"value":'
                || l_value_str
                || ','
                || '"unit":"'
                || REPLACE(NVL(SUBSTR(p_unit, 1, 50), 'unit'), '"', '\"')
                || '",'
                || '"timestamp":"'
                || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"')
                || '",'
                || '"trace_id":"'
                || NVL(g_current_trace_id, 'no-trace')
                || '",'
                || '"span_id":"'
                || NVL(g_current_span_id, 'no-span')
                || '",'
                || '"attributes":'
                || l_attrs_json
                || '}';

            -- Validate JSON using native Oracle 12c+ functions
            IF l_json IS NOT JSON THEN
                RAISE_APPLICATION_ERROR(-20005, 'Invalid metric JSON generated');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

                -- JSON build failed, log and bail
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time, 
                                                     error_message, 
                                                     module_name)
                         VALUES (SYSTIMESTAMP,
                                'log_metric: Failed to build JSON - ' || SUBSTR(l_error_msg, 1, 200),
                                'log_metric: ' || SUBSTR(p_metric_name, 1, 80));

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;
                END;

                RETURN;
        END;

        -- Log to metrics table
        BEGIN
            INSERT INTO plt_metrics (metric_name,
                                    metric_value,
                                    metric_unit,
                                    trace_id,
                                    span_id,
                                    timestamp,
                                    attributes)
                 VALUES (SUBSTR(p_metric_name, 1, 255),
                        p_value,
                        SUBSTR(NVL(p_unit, 'unit'), 1, 50),
                        g_current_trace_id,
                        g_current_span_id,
                        SYSTIMESTAMP,
                        l_attrs_json);

            -- Paranoid check
            IF SQL%ROWCOUNT != 1 THEN
                RAISE_APPLICATION_ERROR(-20006, 'PLTelemetry: Failed to insert metric - rowcount=' || SQL%ROWCOUNT);
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                -- Insert failed, but we still want to try sending to backend
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time,
                                                     error_message,
                                                     module_name)
                         VALUES (SYSTIMESTAMP,
                                l_error_msg,
                                'log_metric: ' || SUBSTR(p_metric_name, 1, 80));

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;
                END;
        -- Don't return here - still try to send to backend
        END;

        -- Send to backend (let it handle its own errors)
        BEGIN
            send_to_backend(l_json);
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

                -- Log send failure
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time, 
                                                     error_message, 
                                                     module_name)
                         VALUES (SYSTIMESTAMP,
                                'log_metric: Failed to send to backend - ' || SUBSTR(l_error_msg, 1, 200),
                                'log_metric: ' || SUBSTR(p_metric_name, 1, 80));

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;
                END;
        END;

        -- Final commit if needed
        IF g_autocommit THEN
            COMMIT;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Ultimate safety net
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

            BEGIN
                INSERT INTO plt_telemetry_errors (error_time,
                                                 error_message,
                                                 module_name)
                     VALUES (SYSTIMESTAMP,
                            'log_metric: Unexpected error - ' || SUBSTR(l_error_msg, 1, 200),
                            'log_metric: ' || SUBSTR(p_metric_name, 1, 80));

                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
    END log_metric;

    --------------------------------------------------------------------------
    -- UTILITY FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Creates a key-value attribute string with proper escaping
     */
    FUNCTION add_attribute (p_key VARCHAR2, p_value VARCHAR2)
        RETURN VARCHAR2
    IS
    BEGIN
        -- Validate key follows OpenTelemetry conventions
        IF NOT validate_attribute_key(p_key) THEN
            -- Log invalid key but don't fail
            BEGIN
                INSERT INTO plt_telemetry_errors (
                    error_time, 
                    error_message, 
                    module_name
                ) VALUES (
                    SYSTIMESTAMP, 
                    'Invalid attribute key: ' || SUBSTR(p_key, 1, 100) || 
                    ' - must start with letter and contain only letters, numbers, dots, or underscores',
                    'add_attribute'
                );
                IF g_autocommit THEN 
                    COMMIT; 
                END IF;
            EXCEPTION
                WHEN OTHERS THEN 
                    NULL;
            END;
            
            -- Return empty to skip this attribute
            RETURN NULL;
        END IF;
        
        -- Validate value is not null
        IF p_value IS NULL THEN
            RETURN p_key || '=';  -- Or return NULL to skip?
        END IF;
        
        -- Escape special characters
        RETURN p_key || '=' || REPLACE(REPLACE(p_value, '\', '\\'), '=', '\=');
    END add_attribute;

    /**
     * Converts an attributes collection to JSON format using native Oracle JSON
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

        IF p_attributes.COUNT > 0 THEN
            FOR i IN p_attributes.FIRST .. p_attributes.LAST LOOP
                IF p_attributes.EXISTS(i) AND p_attributes(i) IS NOT NULL THEN
                    -- Parse key=value
                    l_pos := INSTR(p_attributes(i), '=');

                    IF l_pos > 0 THEN
                        l_key := SUBSTR(p_attributes(i), 1, l_pos - 1);
                        l_value := SUBSTR(p_attributes(i), l_pos + 1);

                        -- First unescape our format
                        l_value := REPLACE(l_value, '\=', CHR(1));  -- Temporal marker
                        l_value := REPLACE(l_value, '\\', '\');
                        l_value := REPLACE(l_value, CHR(1), '=');

                        -- Add to JSON object using native functions
                        l_json_obj.put(l_key, l_value);
                    END IF;
                END IF;
            END LOOP;
        END IF;

        RETURN l_json_obj.to_string();
    EXCEPTION
        WHEN OTHERS THEN
            -- Never let telemetry break the main process
            -- Return minimal valid JSON with error info
            RETURN '{"_error":"' || REPLACE(SUBSTR(DBMS_UTILITY.format_error_stack, 1, 100), '"', '\"') || '"}';
    END attributes_to_json;

    /**
     * Sends telemetry data to the configured backend
     */
    PROCEDURE send_to_backend (p_json VARCHAR2)
    IS
        l_error_msg    VARCHAR2(4000);
        l_data_type    VARCHAR2(20);
    BEGIN
        -- Validate input
        IF p_json IS NULL THEN
            RETURN;
        END IF;

        -- ===== BRIDGE SUPPORT FOR ASYNC MODE =====
        -- If using bridge and async mode, we need special handling for ordering
        IF g_backend_url = 'POSTGRES_BRIDGE' AND g_async_mode THEN
            -- Determine data type for proper ordering
            IF p_json LIKE '%"duration_ms"%' THEN
                l_data_type := 'SPAN';
            ELSIF p_json LIKE '%"name"%' AND p_json LIKE '%"value"%' THEN
                l_data_type := 'METRIC';
            ELSE
                l_data_type := 'OTHER';
            END IF;
            
            -- Queue with metadata for ordered processing
            BEGIN
                INSERT INTO plt_queue (
                    payload,
                    -- Add a processing priority hint in process_attempts field
                    -- 0 = normal, but we can use it to hint at order
                    process_attempts,
                    created_at
                ) VALUES (
                    p_json,
                    CASE l_data_type
                        WHEN 'SPAN' THEN 0     -- Process spans first
                        WHEN 'METRIC' THEN 1   -- Process metrics after spans
                        ELSE 2                 -- Everything else last
                    END,
                    SYSTIMESTAMP
                );

                IF g_autocommit THEN
                    COMMIT;
                END IF;
                
                RETURN;  -- Don't continue with normal flow
            EXCEPTION
                WHEN OTHERS THEN
                    -- Queue insert failed, try sync as fallback
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                    
                    -- Log the queue failure
                    BEGIN
                        INSERT INTO plt_telemetry_errors (
                            error_time,
                            error_message,
                            module_name
                        ) VALUES (
                            SYSTIMESTAMP,
                            'Failed to queue for bridge, falling back to sync: ' || l_error_msg,
                            'send_to_backend'
                        );

                        IF g_autocommit THEN
                            COMMIT;
                        END IF;
                    EXCEPTION
                        WHEN OTHERS THEN
                            NULL;
                    END;

                    -- Fallback to synchronous
                    BEGIN
                        send_to_backend_sync(p_json);
                    EXCEPTION
                        WHEN OTHERS THEN
                            -- Both async and sync failed, give up silently
                            NULL;
                    END;
                    
                    RETURN;
            END;
        END IF;
        -- ===== END BRIDGE SUPPORT =====

        -- Original async/sync logic
        IF g_async_mode THEN
            -- Queue for async processing
            BEGIN
                INSERT INTO plt_queue (payload)
                     VALUES (p_json);

                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    -- Queue insert failed, try sync as fallback
                    l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

                    -- Log the queue failure
                    BEGIN
                        INSERT INTO plt_telemetry_errors (error_time,
                                                          error_message,
                                                          module_name)
                             VALUES (SYSTIMESTAMP,
                                     'Failed to queue telemetry, falling back to sync: ' || l_error_msg,
                                     'send_to_backend');

                        IF g_autocommit THEN
                            COMMIT;
                        END IF;
                    EXCEPTION
                        WHEN OTHERS THEN
                            NULL;
                    END;

                    -- Fallback to synchronous
                    BEGIN
                        send_to_backend_sync(p_json);
                    EXCEPTION
                        WHEN OTHERS THEN
                            -- Both async and sync failed, give up silently
                            NULL;
                    END;
            END;
        ELSE
            -- Original synchronous sending
            BEGIN
                send_to_backend_sync(p_json);
            EXCEPTION
                WHEN OTHERS THEN
                    -- Sync failed, but don't propagate
                    NULL;
            END;
        END IF;
    END send_to_backend;

    /**
     * Sets the current trace context in Oracle session info
     */
    PROCEDURE set_trace_context
    IS
    BEGIN
        -- Use SET_MODULE and SET_ACTION to avoid 64 byte limit
        DBMS_APPLICATION_INFO.SET_MODULE(module_name   => 'OTEL:' || SUBSTR(NVL(g_current_trace_id, 'none'), 1, 28),
                                         action_name   => 'SPAN:' || SUBSTR(NVL(g_current_span_id, 'none'), 1, 28));
    END set_trace_context;

    /**
     * Clears the current trace context from session
     */
    PROCEDURE clear_trace_context
    IS
    BEGIN
        g_current_trace_id := NULL;
        g_current_span_id := NULL;
        DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);
    END clear_trace_context;

    /**
    * Processes queued telemetry data in batches
    * Refactored to eliminate code duplication between bridge and normal backends
    */
    PROCEDURE process_queue (p_batch_size NUMBER DEFAULT 100)
    IS
        l_processed_count   NUMBER := 0;
        l_error_count       NUMBER := 0;
        l_error_msg         VARCHAR2(4000);
        l_batch_size        NUMBER;
        l_order_clause      VARCHAR2(200);
        l_sql               VARCHAR2(1000);
        
        TYPE t_queue_cursor IS REF CURSOR;
        l_cursor            t_queue_cursor;
        l_queue_id          NUMBER;
        l_payload           VARCHAR2(4000);
        
        /**
        * Internal procedure to process a single queue item
        * Eliminates code duplication between different backend types
        */
        PROCEDURE process_single_item(
            p_queue_id IN NUMBER,
            p_payload IN VARCHAR2,
            p_processed_count IN OUT NUMBER,
            p_error_count IN OUT NUMBER
        )
        IS
            l_local_error_msg VARCHAR2(4000);
        BEGIN
            -- Increment attempt counter
            UPDATE plt_queue
            SET    process_attempts = process_attempts + 1,
                last_attempt_time = SYSTIMESTAMP
            WHERE  queue_id = p_queue_id
            AND  processed = 'N';

            -- Only proceed if exactly one row was touched
            IF SQL%ROWCOUNT = 1 THEN
                -- Send payload
                send_to_backend_sync(p_payload);

                -- Mark as processed
                UPDATE plt_queue
                SET    processed = 'Y',
                    processed_time = SYSTIMESTAMP
                WHERE  queue_id = p_queue_id;

                p_processed_count := p_processed_count + 1;
            END IF;

            IF g_autocommit THEN
                COMMIT;
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                l_local_error_msg := SUBSTR(
                    DBMS_UTILITY.format_error_stack
                    || ' - '
                    || DBMS_UTILITY.format_error_backtrace,
                    1, 200);
                p_error_count := p_error_count + 1;

                UPDATE plt_queue
                SET    last_error = l_local_error_msg
                WHERE  queue_id = p_queue_id;

                IF g_autocommit THEN
                    COMMIT;
                END IF;
        END process_single_item;

    BEGIN
        -- Initialize
        l_batch_size := NVL(NULLIF(p_batch_size, 0), 100);

        -- Determine ordering strategy based on backend type
        IF g_backend_url = 'POSTGRES_BRIDGE' THEN
            -- Bridge-specific priority ordering: process_attempts first, then insertion order
            l_order_clause := 'ORDER BY process_attempts, queue_id';
        ELSE
            -- Normal backend: just honour insertion order
            l_order_clause := 'ORDER BY queue_id';
        END IF;

        -- Build dynamic SQL for the cursor
        l_sql := 'SELECT queue_id, payload ' ||
                'FROM ( ' ||
                    'SELECT queue_id, payload, process_attempts ' ||
                    'FROM plt_queue ' ||
                    'WHERE processed = ''N'' ' ||
                    '  AND process_attempts < 5 ' ||
                    l_order_clause ||
                ') ' ||
                'WHERE ROWNUM <= :batch_size';

        -- Open cursor and process items
        OPEN l_cursor FOR l_sql USING l_batch_size;
        
        LOOP
            FETCH l_cursor INTO l_queue_id, l_payload;
            EXIT WHEN l_cursor%NOTFOUND;
            
            -- Process single item using internal procedure
            process_single_item(
                p_queue_id => l_queue_id,
                p_payload => l_payload,
                p_processed_count => l_processed_count,
                p_error_count => l_error_count
            );
        END LOOP;
        
        CLOSE l_cursor;

        -- Summary logging
        IF l_processed_count > 0 OR l_error_count > 0 THEN
            INSERT INTO plt_telemetry_errors (error_time,
                                            error_message,
                                            module_name)
            VALUES (SYSTIMESTAMP,
                    'Queue processed: '
                    || l_processed_count
                    || ' success, '
                    || l_error_count
                    || ' errors',
                    'process_queue');
            IF g_autocommit THEN
                COMMIT;
            END IF;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            -- Clean up cursor if still open
            IF l_cursor%ISOPEN THEN
                CLOSE l_cursor;
            END IF;
            
            INSERT INTO plt_telemetry_errors (error_time,
                                            error_message,
                                            module_name)
            VALUES (SYSTIMESTAMP,
                    'process_queue error: '
                    || SUBSTR(DBMS_UTILITY.format_error_stack
                                || ' - '
                                || DBMS_UTILITY.format_error_backtrace,
                                1, 4000),
                    'process_queue');
            IF g_autocommit THEN
                COMMIT;
            END IF;
    END process_queue;

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

    --------------------------------------------------------------------------
    -- LOGGING FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Internal helper to build and send log JSON
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
    BEGIN
        -- Validate required inputs
        IF p_level IS NULL OR p_message IS NULL THEN
            RETURN; -- Silent fail for missing required params
        END IF;

        -- Convert attributes to JSON safely
        BEGIN
            l_attrs_json := attributes_to_json(p_attributes);
        EXCEPTION
            WHEN OTHERS THEN
                l_attrs_json := '{}';
                
                -- Log attribute conversion failure
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time, error_message, module_name)
                    VALUES (
                        SYSTIMESTAMP,
                        'send_log_internal: Failed to convert attributes - ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200),
                        'send_log_internal'
                    );
                    IF g_autocommit THEN COMMIT; END IF;
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
        END;

        -- Build log JSON
        l_json := '{'
            || '"severity":"' || UPPER(p_level) || '",'
            || '"message":"' || REPLACE(SUBSTR(p_message, 1, 4000), '"', '\"') || '",'
            || '"timestamp":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'
            || CASE 
                    WHEN p_trace_id IS NOT NULL AND LENGTH(p_trace_id) = 32 
                    THEN '"trace_id":"' || p_trace_id || '",'
                    ELSE ''
                END
            || CASE 
                    WHEN p_span_id IS NOT NULL AND LENGTH(p_span_id) = 16 
                    THEN '"span_id":"' || p_span_id || '",'
                    ELSE ''
                END
            || '"attributes":' || l_attrs_json
            || '}';

        -- Store in local logs table (optional - for Oracle-side querying)
        BEGIN
            INSERT INTO plt_logs (
                trace_id,
                span_id, 
                log_level,
                message,
                timestamp,
                attributes
            ) VALUES (
                p_trace_id,
                p_span_id,
                UPPER(p_level),
                SUBSTR(p_message, 1, 4000),
                SYSTIMESTAMP,
                l_attrs_json
            );
        EXCEPTION
            WHEN OTHERS THEN
                -- Log table insert failed, but don't stop the flow
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time, error_message, module_name)
                    VALUES (
                        SYSTIMESTAMP,
                        'send_log_internal: Failed to insert into plt_logs - ' || l_error_msg,
                        'send_log_internal'
                    );
                    IF g_autocommit THEN COMMIT; END IF;
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
        END;

        -- Send to backend (let it handle routing to logs endpoint)
        BEGIN
            send_to_backend(l_json);
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                
                -- Log send failure
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time, error_message, module_name)
                    VALUES (
                        SYSTIMESTAMP,
                        'send_log_internal: Failed to send to backend - ' || l_error_msg,
                        'send_log_internal'
                    );
                    IF g_autocommit THEN COMMIT; END IF;
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
        END;

        -- Final commit if needed
        IF g_autocommit THEN
            COMMIT;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            -- Ultimate safety net
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);

            BEGIN
                INSERT INTO plt_telemetry_errors (error_time, error_message, module_name)
                VALUES (
                    SYSTIMESTAMP,
                    'send_log_internal: Unexpected error - ' || l_error_msg,
                    'send_log_internal'
                );
                IF g_autocommit THEN COMMIT; END IF;
            EXCEPTION
                WHEN OTHERS THEN NULL;
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
        -- Use current trace context with the provided span
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

    --------------------------------------------------------------------------
    -- DISTRIBUTED TRACING FUNCTIONS
    --------------------------------------------------------------------------

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
        l_error_msg  VARCHAR2(4000);
    BEGIN
        -- Validate input
        IF p_trace_id IS NULL OR LENGTH(p_trace_id) != 32 THEN
            RAISE_APPLICATION_ERROR(-20100, 'Invalid trace_id: must be 32 character hex string');
        END IF;
        
        IF p_operation IS NULL THEN
            RAISE_APPLICATION_ERROR(-20101, 'Operation name is required');
        END IF;
        
        -- Set the distributed trace context
        g_current_trace_id := p_trace_id;
        
        -- Start a new span within the existing trace
        l_span_id := start_span(
            p_operation    => p_operation,
            p_parent_span_id => NULL,  -- No parent, this is a new span in distributed trace
            p_trace_id     => p_trace_id
        );
        
        -- Add distributed tracing attributes
        BEGIN
            INSERT INTO plt_span_attributes (
                span_id,
                attribute_key,
                attribute_value
            ) VALUES (
                l_span_id,
                'trace.distributed',
                'true'
            );
            
            -- Add system identifier
            INSERT INTO plt_span_attributes (
                span_id,
                attribute_key,
                attribute_value
            ) VALUES (
                l_span_id,
                'system.name',
                'oracle-plsql'
            );
            
            -- Add tenant if provided
            IF p_tenant_id IS NOT NULL THEN
                INSERT INTO plt_span_attributes (
                    span_id,
                    attribute_key,
                    attribute_value
                ) VALUES (
                    l_span_id,
                    'tenant.id',
                    p_tenant_id
                );
            END IF;
            
            -- Add database context
            INSERT INTO plt_span_attributes (
                span_id,
                attribute_key,
                attribute_value
            ) VALUES (
                l_span_id,
                'db.name',
                SYS_CONTEXT('USERENV', 'DB_NAME')
            );
            
            INSERT INTO plt_span_attributes (
                span_id,
                attribute_key,
                attribute_value
            ) VALUES (
                l_span_id,
                'db.user',
                SYS_CONTEXT('USERENV', 'SESSION_USER')
            );
            
            IF g_autocommit THEN
                COMMIT;
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                -- Don't fail the main operation if attributes fail
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
                
                BEGIN
                    INSERT INTO plt_telemetry_errors (
                        error_time,
                        error_message,
                        module_name,
                        trace_id,
                        span_id
                    ) VALUES (
                        SYSTIMESTAMP,
                        'Failed to add distributed trace attributes: ' || l_error_msg,
                        'continue_distributed_trace',
                        p_trace_id,
                        l_span_id
                    );
                    
                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL; -- Give up on error logging
                END;
        END;
        
        -- Log the continuation
        DECLARE
            l_attrs t_attributes;
        BEGIN
            l_attrs(1) := add_attribute('trace.source', 'external');
            l_attrs(2) := add_attribute('system.previous', 'oracle-forms');
            l_attrs(3) := add_attribute('tenant.id', NVL(p_tenant_id, 'default'));
            
            add_event(l_span_id, 'distributed_trace_continued', l_attrs);
        END;
        
        RETURN l_span_id;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            
            -- Log error but return a span anyway to keep telemetry flowing
            BEGIN
                INSERT INTO plt_telemetry_errors (
                    error_time,
                    error_message,
                    module_name,
                    trace_id
                ) VALUES (
                    SYSTIMESTAMP,
                    'continue_distributed_trace failed: ' || l_error_msg,
                    'continue_distributed_trace',
                    p_trace_id
                );
                
                IF g_autocommit THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
            
            -- Still try to create a basic span
            BEGIN
                l_span_id := generate_span_id();
                g_current_trace_id := p_trace_id;
                g_current_span_id := l_span_id;
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
    BEGIN
        -- Build JSON context for external systems using native Oracle JSON
        l_context := JSON_OBJECT_T();
        l_context.put('trace_id', NVL(g_current_trace_id, ''));
        l_context.put('span_id', NVL(g_current_span_id, ''));
        l_context.put('system', 'oracle-plsql');
        l_context.put('timestamp', TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
        l_context.put('db_name', SYS_CONTEXT('USERENV', 'DB_NAME'));
        
        -- Add tenant if configured (check for tenant in current span attributes)
        DECLARE
            l_tenant_id VARCHAR2(100);
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
    BEGIN
        -- Build distributed logging attributes
        l_attributes(l_idx) := add_attribute('system.name', p_system);
        l_idx := l_idx + 1;
        
        l_attributes(l_idx) := add_attribute('trace.distributed', 'true');
        l_idx := l_idx + 1;
        
        l_attributes(l_idx) := add_attribute('db.name', SYS_CONTEXT('USERENV', 'DB_NAME'));
        l_idx := l_idx + 1;
        
        l_attributes(l_idx) := add_attribute('db.user', SYS_CONTEXT('USERENV', 'SESSION_USER'));
        l_idx := l_idx + 1;
        
        IF p_tenant_id IS NOT NULL THEN
            l_attributes(l_idx) := add_attribute('tenant.id', p_tenant_id);
        END IF;
        
        -- Use existing log_with_trace functionality
        log_with_trace(p_trace_id, p_level, p_message, l_attributes);
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback to basic logging
            BEGIN
                log_message(p_level, 'DISTRIBUTED: ' || p_message);
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- Never fail on logging
            END;
    END log_distributed;

END PLTelemetry;
/