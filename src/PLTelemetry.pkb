CREATE OR REPLACE PACKAGE BODY PLTelemetry
AS

    /**
     * PLTelemetry - OpenTelemetry SDK for PL/SQL
     * 
     * This package provides a generic, backend-agnostic implementation of
     * distributed tracing for Oracle PL/SQL applications following OpenTelemetry standards.
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
   
   FUNCTION validate_attribute_key(p_key VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        -- OpenTelemetry attribute naming conventions
        RETURN REGEXP_LIKE(p_key, '^[a-zA-Z][a-zA-Z0-9._]*$')
               AND LENGTH(p_key) <= 255;
    END;
   
   /**
    * Generates a random ID of specified byte length
    * 
    * @param p_bytes Number of bytes (8 or 16)
    * @return Hex string representation of the random ID
    * @private
    */
   FUNCTION generate_id (p_bytes IN NUMBER)
       RETURN VARCHAR2
   IS
       l_random   RAW (16);  -- Max size we'll need
   BEGIN
       -- Validate input
       IF p_bytes NOT IN (8, 16)
       THEN
           RAISE_APPLICATION_ERROR (-20001, 'Size must be 8 or 16 bytes');
       END IF;

       -- Generate random bytes
       l_random := DBMS_CRYPTO.RANDOMBYTES (p_bytes);
       RETURN LOWER (RAWTOHEX (l_random));
   EXCEPTION
       WHEN OTHERS
       THEN
           -- Fallback: SYS_GUID gives us 16 bytes, truncate if needed
           RETURN LOWER (SUBSTR (RAWTOHEX (SYS_GUID ()), 1, p_bytes * 2));
   END generate_id;

   /**
    * Generates a 128-bit trace ID following OpenTelemetry spec
    * 
    * @return 32 character hex string trace ID
    * @private
    */
   FUNCTION generate_trace_id
       RETURN VARCHAR2
   IS
   BEGIN
       RETURN generate_id (16);
   END;

   /**
    * Generates a 64-bit span ID following OpenTelemetry spec
    * 
    * @return 16 character hex string span ID
    * @private
    */
   FUNCTION generate_span_id
       RETURN VARCHAR2
   IS
   BEGIN
       RETURN generate_id (8);
   END;

   /**
    * Sends telemetry data synchronously via HTTP
    * 
    * @param p_json JSON payload to send to backend
    * @private
    */
   -- MODIFICATION FOR PLTelemetry PACKAGE BODY
-- Replace the existing send_to_backend_sync procedure with this version

/**
 * Sends telemetry data synchronously via HTTP
 * 
 * @param p_json JSON payload to send to backend
 * @private
 */
PROCEDURE send_to_backend_sync (p_json VARCHAR2)
IS
    l_req          UTL_HTTP.REQ;
    l_res          UTL_HTTP.RESP;
    l_buffer       VARCHAR2 (32767);
    l_length       NUMBER;
    l_offset       NUMBER := 1;
    l_amount       NUMBER;
    l_error_msg    VARCHAR2 (4000);
    l_error_code   NUMBER;
    l_response_body  VARCHAR2(4000) := '';
    l_chunk          VARCHAR2(32767);
BEGIN
    -- Validate input
    IF p_json IS NULL
    THEN
        RETURN;
    END IF;

    -- ===== BRIDGE SUPPORT =====
    -- Check if using a custom bridge implementation
    IF g_backend_url = 'POSTGRES_BRIDGE' THEN
        BEGIN
            -- Route to PostgreSQL bridge
            -- The bridge handles transformation and ensures correct ordering
            PLT_POSTGRES_BRIDGE.send_to_backend_with_routing(p_json);
            RETURN;
        EXCEPTION
            WHEN OTHERS THEN
                -- Log bridge error but don't fail
                l_error_msg := SUBSTR(SQLERRM, 1, 4000);
                
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
                l_error_msg := SUBSTR(SQLERRM, 1, 4000);
                
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
    l_length := LENGTH (p_json);

    -- Validate URL before using
    IF g_backend_url IS NULL OR LENGTH (g_backend_url) < 10
    THEN
        -- Log configuration error
        INSERT INTO plt_telemetry_errors (error_time, error_message, module_name)
             VALUES (SYSTIMESTAMP, 'Invalid backend URL configured', 'send_to_backend_sync');

        IF g_autocommit
        THEN
            COMMIT;
        END IF;

        RETURN;
    END IF;

    -- Set timeout with validation
    UTL_HTTP.SET_TRANSFER_TIMEOUT (NVL (g_backend_timeout, 30));

    -- Send to backend
    l_req := UTL_HTTP.BEGIN_REQUEST (g_backend_url, 'POST', 'HTTP/1.1');

    -- Set headers - use LENGTHB for byte count
    UTL_HTTP.SET_HEADER (l_req, 'Content-Type', 'application/json; charset=utf-8');
    UTL_HTTP.SET_HEADER (l_req, 'Content-Length', LENGTHB (p_json));
    UTL_HTTP.SET_HEADER (l_req, 'X-OTel-Source', 'PLTelemetry');
    UTL_HTTP.SET_HEADER (l_req, 'X-PLSQL-API-KEY', NVL (g_api_key, 'not-configured'));
    UTL_HTTP.SET_HEADER (l_req, 'X-PLSQL-DB', SYS_CONTEXT ('USERENV', 'DB_NAME'));

    -- Send VARCHAR2 directly if small enough
    IF l_length <= 32767
    THEN
        UTL_HTTP.WRITE_TEXT (l_req, p_json);
    ELSE
        -- Send in chunks if larger
        WHILE l_offset <= l_length
        LOOP
            l_amount := LEAST (32767, l_length - l_offset + 1);
            l_buffer := SUBSTR (p_json, l_offset, l_amount);
            UTL_HTTP.WRITE_TEXT (l_req, l_buffer);
            l_offset := l_offset + l_amount;
        END LOOP;
    END IF;

    l_res := UTL_HTTP.GET_RESPONSE (l_req);

    -- Check response status
    IF l_res.status_code NOT IN (200, 201, 202, 204)
    THEN
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
                     SUBSTR (p_json, 1, 4000),
                     'HTTP ' || l_res.status_code || ': ' || SUBSTR(l_response_body, 1, 3000));
    END IF;

    UTL_HTTP.END_RESPONSE (l_res);
EXCEPTION
    WHEN UTL_HTTP.TRANSFER_TIMEOUT
    THEN
        -- Save error details before any operations
        l_error_msg := 'Backend timeout after ' || NVL (g_backend_timeout, 30) || ' seconds';

        -- Clean up connection if exists
        BEGIN
            IF l_res.status_code IS NOT NULL
            THEN
                UTL_HTTP.END_RESPONSE (l_res);
            END IF;
        EXCEPTION
            WHEN OTHERS
            THEN
                NULL;
        END;

        -- Log timeout
        BEGIN
            INSERT INTO plt_failed_exports (export_time, payload, error_message)
                 VALUES (SYSTIMESTAMP, SUBSTR (p_json, 1, 4000), l_error_msg);

            IF g_autocommit
            THEN
                COMMIT;
            END IF;
        EXCEPTION
            WHEN OTHERS
            THEN
                NULL;
        END;
    WHEN OTHERS
    THEN
        -- Save error details
        l_error_msg := SUBSTR (SQLERRM, 1, 4000);
        l_error_code := SQLCODE;

        -- Clean up connection if exists
        BEGIN
            IF l_res.status_code IS NOT NULL
            THEN
                UTL_HTTP.END_RESPONSE (l_res);
            END IF;
        EXCEPTION
            WHEN OTHERS
            THEN
                NULL;
        END;

        -- Log error but don't fail the business logic
        BEGIN
            INSERT INTO plt_failed_exports (export_time,
                                            payload,
                                            error_message,
                                            http_status)
                 VALUES (SYSTIMESTAMP,
                         SUBSTR (p_json, 1, 4000),
                         'Error (' || l_error_code || '): ' || l_error_msg,
                         -1  -- Indicate non-HTTP error
                           );

            IF g_autocommit
            THEN
                COMMIT;
            END IF;
        EXCEPTION
            WHEN OTHERS
            THEN
                NULL;
        END;
END send_to_backend_sync;

   --------------------------------------------------------------------------
   -- CORE TRACING FUNCTIONS
   --------------------------------------------------------------------------

   /**
    * Starts a new trace with the given operation name
    *
    * @param p_operation The name of the operation being traced
    * @return The generated trace ID (32 character hex string)
    */
   FUNCTION start_trace (p_operation VARCHAR2)
       RETURN VARCHAR2
   IS
       l_trace_id               VARCHAR2 (32);
       l_retry_count            NUMBER := 0;
       l_max_retries   CONSTANT NUMBER := 3;
       l_error_msg              VARCHAR2 (4000);
   BEGIN
       LOOP
           BEGIN
               l_trace_id := generate_trace_id ();
               g_current_trace_id := l_trace_id;

               -- Set context for visibility
               set_trace_context ();

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
                            SYS_CONTEXT ('USERENV', 'HOST') || ':' || SYS_CONTEXT ('USERENV', 'INSTANCE_NAME'));

               -- Paranoid check
               IF SQL%ROWCOUNT != 1
               THEN
                   RAISE_APPLICATION_ERROR (-20001, 'PLTelemetry: Failed to insert trace - rowcount=' || SQL%ROWCOUNT);
               END IF;

               IF g_autocommit
               THEN
                   COMMIT;
               END IF;
               
               RETURN l_trace_id;  -- Success! Exit function
           EXCEPTION
               WHEN OTHERS
               THEN
                   l_retry_count := l_retry_count + 1;

                   -- Check if it's a DUP_VAL_ON_INDEX (without naming it)
                   IF SQLCODE = -1 AND l_retry_count < l_max_retries
                   THEN
                       -- It's a unique constraint, retry with new ID
                       NULL;  -- Continue loop
                   ELSE
                       -- Any other error or max retries reached
                       BEGIN
                           l_error_msg := SUBSTR (SQLERRM, 1, 4000);

                           INSERT INTO plt_telemetry_errors (error_time, error_message, error_stack)
                                VALUES (SYSTIMESTAMP, l_error_msg, SUBSTR (DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000));

                           IF g_autocommit
                           THEN
                               COMMIT;
                           END IF;
                       EXCEPTION
                           WHEN OTHERS
                           THEN
                               NULL;  -- Give up
                       END;

                       -- Exit loop and return the trace_id anyway
                       RETURN l_trace_id;
                   END IF;
           END;
       END LOOP;
   END start_trace;

    /**
     * Ends the current trace and clears context
     * 
     * @param p_trace_id Optional trace ID to end (uses current if not provided)
     */
    PROCEDURE end_trace(p_trace_id VARCHAR2 DEFAULT NULL) IS
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
    *
    * @param p_operation The name of the operation for this span
    * @param p_parent_span_id Optional parent span ID for nested spans
    * @param p_trace_id Optional trace ID (uses current if not provided)
    * @return The generated span ID (16 character hex string)
    */
   FUNCTION start_span (p_operation VARCHAR2, p_parent_span_id VARCHAR2 DEFAULT NULL, p_trace_id VARCHAR2 DEFAULT NULL)
       RETURN VARCHAR2
   IS
       l_span_id                VARCHAR2 (16);
       l_trace_id               VARCHAR2 (32);
       l_retry_count            NUMBER := 0;
       l_max_retries   CONSTANT NUMBER := 3;
       l_error_msg              VARCHAR2 (4000);
       l_error_code             NUMBER;
   BEGIN
       LOOP
           BEGIN
               l_span_id := generate_span_id ();
               g_current_span_id := l_span_id;

               -- Use provided trace_id or current one
               l_trace_id := NVL (p_trace_id, NVL (g_current_trace_id, generate_trace_id ()));
               g_current_trace_id := l_trace_id;

               -- Set context for visibility
               set_trace_context ();

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
               IF SQL%ROWCOUNT != 1
               THEN
                   RAISE_APPLICATION_ERROR (-20002, 'PLTelemetry: Failed to insert span - rowcount=' || SQL%ROWCOUNT);
               END IF;

               IF g_autocommit
               THEN
                   COMMIT;
               END IF;

               RETURN l_span_id;  -- Success!
           EXCEPTION
               WHEN OTHERS
               THEN
                   l_retry_count := l_retry_count + 1;

                   -- Check if it's a unique constraint violation
                   IF SQLCODE = -1 AND l_retry_count < l_max_retries
                   THEN
                       -- Retry with new span_id
                       NULL;  -- Continue loop
                   ELSE
                       -- Any other error or max retries reached
                       BEGIN
                           l_error_msg := SUBSTR (SQLERRM, 1, 4000);
                           l_error_code := SQLCODE;

                           INSERT INTO plt_telemetry_errors (error_time,
                                                             error_message,
                                                             error_stack,
                                                             error_code,
                                                             module_name,
                                                             trace_id,
                                                             span_id)
                                VALUES (SYSTIMESTAMP,
                                        l_error_msg,
                                        SUBSTR (DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000),
                                        l_error_code,
                                        'start_span: ' || SUBSTR (p_operation, 1, 80),
                                        l_trace_id,
                                        l_span_id);

                           IF g_autocommit
                           THEN
                               COMMIT;
                           END IF;
                       EXCEPTION
                           WHEN OTHERS
                           THEN
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
    *
    * @param p_span_id The ID of the span to end
    * @param p_status The final status of the span (OK, ERROR, etc.)
    * @param p_attributes Additional attributes to attach to the span
    */
   PROCEDURE end_span (p_span_id VARCHAR2, p_status VARCHAR2 DEFAULT 'OK', p_attributes t_attributes DEFAULT t_attributes ())
    IS
        l_json           VARCHAR2 (32767);
        l_duration       NUMBER;
        l_attrs_json     VARCHAR2 (4000);
        l_events_json    VARCHAR2 (4000);  -- New for events
        l_start_time     TIMESTAMP WITH TIME ZONE;
        l_operation_name VARCHAR2(255);
        l_error_msg      VARCHAR2 (4000);
        l_error_code     NUMBER;
        l_json_valid     NUMBER;
        l_parent_span_id VARCHAR2(16); 
    BEGIN
        -- Validate input
        IF p_span_id IS NULL
        THEN
            RETURN;  -- Silent fail for null span_id
        END IF;

        BEGIN
            -- Get span info including operation_name and calculate duration
            SELECT start_time, 
                   operation_name,
                   parent_span_id,
                   EXTRACT (SECOND FROM (SYSTIMESTAMP - start_time)) * 1000
            INTO l_start_time, l_operation_name, l_parent_span_id, l_duration
            FROM plt_spans
            WHERE span_id = p_span_id;
        EXCEPTION
            WHEN NO_DATA_FOUND
            THEN
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

                    IF g_autocommit
                    THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS
                    THEN
                        NULL;
                END;

                RETURN;
            WHEN TOO_MANY_ROWS
            THEN
                -- This should never happen with proper PK, but...
                l_duration := 0;
                l_operation_name := 'unknown_operation';
        END;

        -- Update span in Oracle
        UPDATE plt_spans
        SET end_time = SYSTIMESTAMP, duration_ms = l_duration, status = p_status
        WHERE span_id = p_span_id AND end_time IS NULL;  -- Don't update already ended spans

        -- Check if update actually did something
        IF SQL%ROWCOUNT = 0
        THEN
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

                IF g_autocommit
                THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS
                THEN
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

        -- Build attributes JSON
        BEGIN
            l_attrs_json := attributes_to_json (p_attributes);
        EXCEPTION
            WHEN OTHERS
            THEN
                l_attrs_json := '{}';  -- Empty JSON on error
        END;

        -- ===== NEW: Build events JSON =====
        BEGIN
            -- Get events for this span
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
                                 'Failed to build events JSON: ' || SUBSTR(DBMS_UTILITY.format_error_stack|| ' - '|| DBMS_UTILITY.format_error_backtrace, 1, 200),
                                 'end_span',
                                 p_span_id);
                    IF g_autocommit THEN COMMIT; END IF;
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
        END;

        -- Build complete JSON with all required fields including events
        l_json := '{'
            || '"trace_id":"' || NVL (g_current_trace_id, 'unknown') || '",'
            || '"span_id":"' || p_span_id || '",'
            || '"parent_span_id":"' || NVL(l_parent_span_id, '') || '",'
            || '"operation_name":"' || REPLACE(l_operation_name, '"', '\"') || '",' 
            || '"start_time":"' || TO_CHAR(l_start_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'  
            || '"end_time":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'   
            || '"duration_ms":' || NVL (TO_CHAR (l_duration), '0') || ','
            || '"status":"' || NVL (p_status, 'OK') || '",'
            || '"events":' || l_events_json || ','  -- ? NEW: Include events
            || '"attributes":' || l_attrs_json
            || '}';

        -- Debug log
        cent_dbg_pkg.dbg_log('PLTELEMETRY', 'END_SPAN JSON[' || l_json || ']'); -- ##MDEBUG

        -- Validate JSON
        BEGIN
            IF l_json IS NOT JSON
            THEN
                RAISE_APPLICATION_ERROR (-20003, 'Invalid JSON structure');
            END IF;
        EXCEPTION
            WHEN OTHERS
            THEN
                -- Log invalid JSON
                BEGIN
                    INSERT INTO plt_telemetry_errors (error_time,
                                                      error_message,
                                                      module_name,
                                                      span_id)
                         VALUES (SYSTIMESTAMP,
                                 'Invalid JSON: ' || SUBSTR (l_json, 1, 200),
                                 'end_span',
                                 p_span_id);

                    IF g_autocommit
                    THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS
                    THEN
                        NULL;
                END;

                RETURN;  -- Don't send invalid JSON
        END;

        -- Send to backend
        send_to_backend (l_json);

        IF g_autocommit
        THEN
            COMMIT;
        END IF;
    EXCEPTION
        WHEN OTHERS
        THEN
            -- Global exception handler
            l_error_msg := SUBSTR (SQLERRM, 1, 4000);
            l_error_code := SQLCODE;

            BEGIN
                INSERT INTO plt_telemetry_errors (error_time,
                                                  error_message,
                                                  error_code,
                                                  error_stack,
                                                  module_name,
                                                  span_id)
                     VALUES (SYSTIMESTAMP,
                             l_error_msg,
                             l_error_code,
                             SUBSTR (DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000),
                             'end_span',
                             p_span_id);

                IF g_autocommit
                THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS
                THEN
                    NULL;
            END;

            -- Try to at least update the span as FAILED
            BEGIN
                UPDATE plt_spans
                SET end_time = SYSTIMESTAMP, status = 'ERROR', duration_ms = 0
                WHERE span_id = p_span_id AND end_time IS NULL;

                IF g_autocommit
                THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS
                THEN
                    NULL;
            END;
    END end_span;

   /**
    * Adds an event to an active span
    *
    * @param p_span_id The ID of the span to add the event to
    * @param p_event_name The name of the event
    * @param p_attributes Optional attributes for the event
    */
   PROCEDURE add_event (p_span_id VARCHAR2, p_event_name VARCHAR2, p_attributes t_attributes DEFAULT t_attributes ())
   IS
       l_attrs_varchar   VARCHAR2 (4000);
       l_error_msg       VARCHAR2 (4000);
       l_error_code      NUMBER;
   BEGIN
       -- Validate inputs
       IF p_span_id IS NULL OR p_event_name IS NULL
       THEN
           -- Silent fail for null required params
           RETURN;
       END IF;

       -- Convert attributes to JSON with protection
       BEGIN
           IF p_attributes.COUNT > 0
           THEN
               l_attrs_varchar := attributes_to_json (p_attributes);
           ELSE
               l_attrs_varchar := '{}';
           END IF;
       EXCEPTION
           WHEN OTHERS
           THEN
               l_error_msg := SUBSTR (SQLERRM, 1, 4000);
               -- If attributes fail, use empty JSON
               l_attrs_varchar := '{}';

               -- Log the issue but continue
               BEGIN
                   INSERT INTO plt_telemetry_errors (error_time,
                                                     error_message,
                                                     module_name,
                                                     span_id)
                        VALUES (SYSTIMESTAMP,
                                'add_event: Failed to convert attributes - ' || SUBSTR (l_error_msg, 1, 200),
                                'add_event: ' || SUBSTR (p_event_name, 1, 80),
                                p_span_id);

                   IF g_autocommit
                   THEN
                       COMMIT;
                   END IF;
               EXCEPTION
                   WHEN OTHERS
                   THEN
                       NULL;
               END;
       END;

       -- Validate JSON if we have one
       IF l_attrs_varchar IS NOT NULL AND l_attrs_varchar != '{}'
       THEN
           IF l_attrs_varchar IS NOT JSON
           THEN
               l_attrs_varchar := '{}';  -- Fallback to empty
           END IF;
       END IF;

       -- Insert event
       BEGIN
           INSERT INTO plt_events (span_id,
                                   event_name,
                                   event_time,
                                   attributes)
                VALUES (p_span_id,
                        SUBSTR (p_event_name, 1, 255),  -- Truncate if too long
                        SYSTIMESTAMP,
                        l_attrs_varchar);

           -- Paranoid check
           IF SQL%ROWCOUNT != 1
           THEN
               RAISE_APPLICATION_ERROR (-20004, 'PLTelemetry: Failed to insert event - rowcount=' || SQL%ROWCOUNT);
           END IF;

           IF g_autocommit
           THEN
               COMMIT;
           END IF;
       EXCEPTION
           WHEN OTHERS
           THEN
               -- Event logging failed, but don't crash the app
               l_error_msg := SUBSTR (SQLERRM, 1, 4000);
               l_error_code := SQLCODE;

               BEGIN
                   INSERT INTO plt_telemetry_errors (error_time,
                                                     error_message,
                                                     error_code,
                                                     error_stack,
                                                     module_name,
                                                     span_id)
                        VALUES (SYSTIMESTAMP,
                                l_error_msg,
                                l_error_code,
                                SUBSTR (DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000),
                                'add_event: ' || SUBSTR (p_event_name, 1, 80),
                                p_span_id);

                   IF g_autocommit
                   THEN
                       COMMIT;
                   END IF;
               EXCEPTION
                   WHEN OTHERS
                   THEN
                       NULL;  -- Even error logging can fail
               END;
       END;
   EXCEPTION
       WHEN OTHERS
       THEN
           l_error_msg := SUBSTR (SQLERRM, 1, 4000);
           l_error_code := SQLCODE;

           -- Global exception handler - should never reach here but...
           -- Log if possible but NEVER propagate
           BEGIN
               INSERT INTO plt_telemetry_errors (error_time,
                                                 error_message,
                                                 error_code,
                                                 module_name)
                    VALUES (SYSTIMESTAMP,
                            'add_event: Unexpected error - ' || SUBSTR (l_error_msg, 1, 200),
                            l_error_code,
                            'add_event');

               IF g_autocommit
               THEN
                   COMMIT;
               END IF;
           EXCEPTION
               WHEN OTHERS
               THEN
                   NULL;
           END;
   END add_event;

   /**
    * Records a metric value with associated metadata
    *
    * @param p_metric_name The name of the metric
    * @param p_value The numeric value of the metric
    * @param p_unit Optional unit of measurement
    * @param p_attributes Optional attributes for the metric
    */
   PROCEDURE log_metric (p_metric_name    VARCHAR2,
                         p_value          NUMBER,
                         p_unit           VARCHAR2 DEFAULT NULL,
                         p_attributes     t_attributes DEFAULT t_attributes ())
   IS
       l_json         VARCHAR2 (32767);
       l_attrs_json   VARCHAR2 (4000);
       l_error_msg    VARCHAR2 (4000);
       l_error_code   NUMBER;
       l_value_str    VARCHAR2 (50);
   BEGIN
       -- Validate required inputs
       IF p_metric_name IS NULL OR p_value IS NULL
       THEN
           RETURN;  -- Silent fail for missing required params
       END IF;

       -- Convert attributes to JSON safely
       BEGIN
           l_attrs_json := attributes_to_json (p_attributes);
       EXCEPTION
           WHEN OTHERS
           THEN
               l_error_msg := SUBSTR (SQLERRM, 1, 4000);

               l_attrs_json := '{}';

               -- Log attribute conversion failure
               BEGIN
                   INSERT INTO plt_telemetry_errors (error_time, error_message, module_name)
                            VALUES (
                                       SYSTIMESTAMP,
                                       'log_metric: Failed to convert attributes - ' || SUBSTR (l_error_msg, 1, 200),
                                       'log_metric: ' || SUBSTR (p_metric_name, 1, 80));

                   IF g_autocommit
                   THEN
                       COMMIT;
                   END IF;
               EXCEPTION
                   WHEN OTHERS
                   THEN
                       NULL;
               END;
       END;

       -- Handle special number cases (NaN, Infinity, etc)
       BEGIN
           IF p_value IS NOT NULL
           THEN
               l_value_str := TO_CHAR (p_value, 'FM999999999999990.999999999', 'NLS_NUMERIC_CHARACTERS=''.,''');
           ELSE
               l_value_str := '0';
           END IF;
       EXCEPTION
           WHEN OTHERS
           THEN
               l_value_str := '0';  -- Default on conversion error
       END;

       -- Build metric JSON with escaping
       BEGIN
           l_json :=
                  '{'
               || '"name":"'
               || REPLACE (SUBSTR (p_metric_name, 1, 255), '"', '\"')
               || '",'
               || '"value":'
               || l_value_str
               || ','
               || '"unit":"'
               || REPLACE (NVL (SUBSTR (p_unit, 1, 50), 'unit'), '"', '\"')
               || '",'
               || '"timestamp":"'
               || TO_CHAR (SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"')
               || '",'
               || '"trace_id":"'
               || NVL (g_current_trace_id, 'no-trace')
               || '",'
               || '"span_id":"'
               || NVL (g_current_span_id, 'no-span')
               || '",'
               || '"attributes":'
               || l_attrs_json
               || '}';

           cent_dbg_pkg.dbg_log('PLTELEMETRY', 'LOG_METRIC 010 l_json['||l_json||']'); -- ##MDEBUG

           -- Validate JSON
           IF l_json IS NOT JSON
           THEN
               RAISE_APPLICATION_ERROR (-20005, 'Invalid metric JSON generated');
           END IF;
       EXCEPTION
           WHEN OTHERS
           THEN
               l_error_msg := SUBSTR (SQLERRM, 1, 4000);

               -- JSON build failed, log and bail
               BEGIN
                   INSERT INTO plt_telemetry_errors (error_time, error_message, module_name)
                            VALUES (
                                       SYSTIMESTAMP,
                                       'log_metric: Failed to build JSON - ' || SUBSTR (l_error_msg, 1, 200),
                                       'log_metric: ' || SUBSTR (p_metric_name, 1, 80));

                   IF g_autocommit
                   THEN
                       COMMIT;
                   END IF;
               EXCEPTION
                   WHEN OTHERS
                   THEN
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
                VALUES (SUBSTR (p_metric_name, 1, 255),
                        p_value,
                        SUBSTR (NVL (p_unit, 'unit'), 1, 50),
                        g_current_trace_id,
                        g_current_span_id,
                        SYSTIMESTAMP,
                        l_attrs_json);

           -- Paranoid check
           IF SQL%ROWCOUNT != 1
           THEN
               RAISE_APPLICATION_ERROR (-20006, 'PLTelemetry: Failed to insert metric - rowcount=' || SQL%ROWCOUNT);
           END IF;
       EXCEPTION
           WHEN OTHERS
           THEN
               -- Insert failed, but we still want to try sending to backend
               l_error_msg := SUBSTR (SQLERRM, 1, 4000);
               l_error_code := SQLCODE;

               BEGIN
                   INSERT INTO plt_telemetry_errors (error_time,
                                                     error_message,
                                                     error_code,
                                                     error_stack,
                                                     module_name)
                        VALUES (SYSTIMESTAMP,
                                l_error_msg,
                                l_error_code,
                                SUBSTR (DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000),
                                'log_metric: ' || SUBSTR (p_metric_name, 1, 80));

                   IF g_autocommit
                   THEN
                       COMMIT;
                   END IF;
               EXCEPTION
                   WHEN OTHERS
                   THEN
                       NULL;
               END;
       -- Don't return here - still try to send to backend
       END;

       -- Send to backend (let it handle its own errors)
       BEGIN
           send_to_backend (l_json);
       EXCEPTION
           WHEN OTHERS
           THEN
               l_error_msg := SUBSTR (SQLERRM, 1, 4000);

               -- Log send failure
               BEGIN
                   INSERT INTO plt_telemetry_errors (error_time, error_message, module_name)
                            VALUES (
                                       SYSTIMESTAMP,
                                       'log_metric: Failed to send to backend - ' || SUBSTR (l_error_msg, 1, 200),
                                       'log_metric: ' || SUBSTR (p_metric_name, 1, 80));

                   IF g_autocommit
                   THEN
                       COMMIT;
                   END IF;
               EXCEPTION
                   WHEN OTHERS
                   THEN
                       NULL;
               END;
       END;

       -- Final commit if needed
       IF g_autocommit
       THEN
           COMMIT;
       END IF;
   EXCEPTION
       WHEN OTHERS
       THEN
           -- Ultimate safety net
           BEGIN
               l_error_code := SQLCODE;
               l_error_msg := SUBSTR (SQLERRM, 1, 4000);

               INSERT INTO plt_telemetry_errors (error_time,
                                                 error_message,
                                                 error_code,
                                                 module_name)
                    VALUES (SYSTIMESTAMP,
                            'log_metric: Unexpected error - ' || SUBSTR (l_error_msg, 1, 200),
                            l_error_code,
                            'log_metric');

               IF g_autocommit
               THEN
                   COMMIT;
               END IF;
           EXCEPTION
               WHEN OTHERS
               THEN
                   NULL;
           END;
   END log_metric;

   --------------------------------------------------------------------------
   -- UTILITY FUNCTIONS
   --------------------------------------------------------------------------

   /**
    * Creates a key-value attribute string with proper escaping
    *
    * @param p_key The attribute key
    * @param p_value The attribute value
    * @return Escaped key=value string
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
        RETURN p_key || '=' || REPLACE (REPLACE (p_value, '\', '\\'), '=', '\=');
    END add_attribute;
   /**
    * Converts an attributes collection to JSON format
    *
    * @param p_attributes Collection of key=value attributes
    * @return JSON string representation of attributes
    */
   FUNCTION attributes_to_json (p_attributes t_attributes)
       RETURN VARCHAR2
   IS
       l_json        VARCHAR2 (32767);
       l_key         VARCHAR2 (255);
       l_value       VARCHAR2 (4000);
       l_pos         NUMBER;
       l_temp_attr   VARCHAR2 (4000);
   BEGIN
       l_json := '{';

       IF p_attributes.COUNT > 0
       THEN
           FOR i IN p_attributes.FIRST .. p_attributes.LAST
           LOOP
               IF p_attributes.EXISTS (i) AND p_attributes (i) IS NOT NULL
               THEN
                   -- Parse key=value
                   l_pos := INSTR (p_attributes (i), '=');

                   IF l_pos > 0
                   THEN
                       l_key := SUBSTR (p_attributes (i), 1, l_pos - 1);
                       l_value := SUBSTR (p_attributes (i), l_pos + 1);

                       -- First unescape our format
                       l_value := REPLACE (l_value, '\=', CHR (1));  -- Temporal marker
                       l_value := REPLACE (l_value, '\\', '\');
                       l_value := REPLACE (l_value, CHR (1), '=');

                       -- Then escape for JSON
                       l_value := REPLACE (l_value, '\', '\\');
                       l_value := REPLACE (l_value, '"', '\"');
                       l_value := REPLACE (l_value, CHR (10), '\n');
                       l_value := REPLACE (l_value, CHR (13), '\r');
                       l_value := REPLACE (l_value, CHR (9), '\t');
                       l_value := REPLACE (l_value, CHR (8), '\b');
                       l_value := REPLACE (l_value, CHR (12), '\f');

                       -- Truncate individual attribute if too long
                       l_temp_attr := '"' || SUBSTR (l_key, 1, 100) || '":"' || SUBSTR (l_value, 1, 500) || '"';

                       -- Check if adding this would exceed our limit
                       IF LENGTH (l_json) + LENGTH (l_temp_attr) + 10 > 3990
                       THEN
                           -- Maybe add a "truncated":true attribute?
                           IF LENGTH (l_json) + 20 < 3990
                           THEN
                               l_json := l_json || ',"_truncated":true';
                           END IF;

                           EXIT;  -- Stop adding more attributes
                       END IF;

                       IF l_json != '{'
                       THEN
                           l_json := l_json || ',';
                       END IF;

                       l_json := l_json || l_temp_attr;
                   END IF;
               END IF;
           END LOOP;
       END IF;

       l_json := l_json || '}';
       RETURN SUBSTR (l_json, 1, 4000);  -- Final safety net
   EXCEPTION
       WHEN OTHERS
       THEN
           -- Never let telemetry break the main process
           -- Return minimal valid JSON with error info
           RETURN SUBSTR ('{"_error":"' || REPLACE (SUBSTR (SQLERRM, 1, 100), '"', '\"') || '","_error_code":"' || SQLCODE || '"}', 1, 4000);
   END;


    /**
     * Sends telemetry data to the configured backend
     *
     * @param p_json JSON payload to send
     * @note Uses async mode by default, falls back to sync on failure
     */
    PROCEDURE send_to_backend (p_json VARCHAR2)
    IS
        l_error_msg    VARCHAR2 (4000);
        l_error_code   NUMBER;
        l_data_type    VARCHAR2(20);
    BEGIN
        -- Validate input
        IF p_json IS NULL
        THEN
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
                    l_error_msg := SUBSTR(SQLERRM, 1, 4000);
                    l_error_code := SQLCODE;
                    
                    -- Log the queue failure
                    BEGIN
                        INSERT INTO plt_telemetry_errors (
                            error_time,
                            error_message,
                            error_code,
                            module_name
                        ) VALUES (
                            SYSTIMESTAMP,
                            'Failed to queue for bridge, falling back to sync: ' || l_error_msg,
                            l_error_code,
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
        IF g_async_mode
        THEN
            -- Queue for async processing
            BEGIN
                INSERT INTO plt_queue (payload)
                     VALUES (p_json);

                IF g_autocommit
                THEN
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS
                THEN
                    -- Queue insert failed, try sync as fallback
                    l_error_msg := SUBSTR (SQLERRM, 1, 4000);
                    l_error_code := SQLCODE;

                    -- Log the queue failure
                    BEGIN
                        INSERT INTO plt_telemetry_errors (error_time,
                                                          error_message,
                                                          error_code,
                                                          module_name)
                             VALUES (SYSTIMESTAMP,
                                     'Failed to queue telemetry, falling back to sync: ' || l_error_msg,
                                     l_error_code,
                                     'send_to_backend');

                        IF g_autocommit
                        THEN
                            COMMIT;
                        END IF;
                    EXCEPTION
                        WHEN OTHERS
                        THEN
                            NULL;
                    END;

                    -- Fallback to synchronous
                    BEGIN
                        send_to_backend_sync (p_json);
                    EXCEPTION
                        WHEN OTHERS
                        THEN
                            -- Both async and sync failed, give up silently
                            NULL;
                    END;
            END;
        ELSE
            -- Original synchronous sending
            BEGIN
                send_to_backend_sync (p_json);
            EXCEPTION
                WHEN OTHERS
                THEN
                    -- Sync failed, but don't propagate
                    NULL;
            END;
        END IF;
    END send_to_backend;

   /**
    * Sets the current trace context in Oracle session info
    *
    * @note Uses DBMS_APPLICATION_INFO for visibility in V$SESSION
    */
   PROCEDURE set_trace_context
   IS
   BEGIN
       -- Use SET_MODULE and SET_ACTION to avoid 64 byte limit
       DBMS_APPLICATION_INFO.SET_MODULE (module_name   => 'OTEL:' || SUBSTR (NVL (g_current_trace_id, 'none'), 1, 28),
                                         action_name   => 'SPAN:' || SUBSTR (NVL (g_current_span_id, 'none'), 1, 28));
   END;

   /**
    * Clears the current trace context from session
    */
   PROCEDURE clear_trace_context
   IS
   BEGIN
       g_current_trace_id := NULL;
       g_current_span_id := NULL;
       DBMS_APPLICATION_INFO.SET_MODULE (NULL, NULL);
   END;

   /**
    * Processes queued telemetry data in batches
    *
    * @param p_batch_size Number of queue entries to process (default 100)
    * @note Should be called periodically by a scheduled job
    */
    PROCEDURE process_queue (p_batch_size NUMBER DEFAULT 100)
    IS
        l_processed_count   NUMBER := 0;
        l_error_count       NUMBER := 0;
        l_error_msg         VARCHAR2(4000);
        l_batch_size        NUMBER;
    BEGIN
        -- -------- Init --------
        l_batch_size := NVL(NULLIF(p_batch_size, 0), 100);

        /* --------------------------------------------------------------------
           FIRST CASE: using the bridge ¿ keep original insertion order *and*
           prioritise by process_attempts so the bridge groups similar payloads
           -------------------------------------------------------------------- */
        IF g_backend_url = 'POSTGRES_BRIDGE' THEN
            FOR rec IN (
                SELECT queue_id, payload
                FROM (
                    SELECT queue_id,
                           payload,
                           process_attempts
                    FROM   plt_queue
                    WHERE  processed = 'N'
                       AND process_attempts < 5
                    ORDER  BY process_attempts,        -- bridge-specific priority
                              queue_id                -- stable insertion order
                )
                WHERE ROWNUM <= l_batch_size
            )
            LOOP
                -- same processing block -----------------------------
                BEGIN
                    -- 1) Increment attempt counter
                    UPDATE plt_queue
                    SET    process_attempts = process_attempts + 1,
                           last_attempt_time = SYSTIMESTAMP
                    WHERE  queue_id  = rec.queue_id
                      AND  processed = 'N';

                    -- 2) Only proceed if exactly one row was touched
                    IF SQL%ROWCOUNT = 1 THEN
                        -- send payload
                        send_to_backend_sync(rec.payload);

                        -- mark as processed
                        UPDATE plt_queue
                        SET    processed      = 'Y',
                               processed_time = SYSTIMESTAMP
                        WHERE  queue_id = rec.queue_id;

                        l_processed_count := l_processed_count + 1;
                    END IF;

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        l_error_msg := SUBSTR(
                            DBMS_UTILITY.format_error_stack
                            || ' - '
                            || DBMS_UTILITY.format_error_backtrace,
                            1, 200);
                        l_error_count := l_error_count + 1;

                        UPDATE plt_queue
                        SET    last_error = l_error_msg
                        WHERE  queue_id   = rec.queue_id;

                        IF g_autocommit THEN
                            COMMIT;
                        END IF;
                END;
            END LOOP;

        /* --------------------------------------------------------------------
           SECOND CASE: normal backend ¿ just honour insertion order
           -------------------------------------------------------------------- */
        ELSE
            FOR rec IN (
                SELECT queue_id, payload
                FROM (
                    SELECT queue_id,
                           payload
                    FROM   plt_queue
                    WHERE  processed = 'N'
                       AND process_attempts < 5
                    ORDER  BY queue_id                  -- insertion order only
                )
                WHERE ROWNUM <= l_batch_size
            )
            LOOP
                -- same processing block -----------------------------
                BEGIN
                    -- 1) Increment attempt counter
                    UPDATE plt_queue
                    SET    process_attempts = process_attempts + 1,
                           last_attempt_time = SYSTIMESTAMP
                    WHERE  queue_id  = rec.queue_id
                      AND  processed = 'N';

                    -- 2) Only proceed if exactly one row was touched
                    IF SQL%ROWCOUNT = 1 THEN
                        -- send payload
                        send_to_backend_sync(rec.payload);

                        -- mark as processed
                        UPDATE plt_queue
                        SET    processed      = 'Y',
                               processed_time = SYSTIMESTAMP
                        WHERE  queue_id = rec.queue_id;

                        l_processed_count := l_processed_count + 1;
                    END IF;

                    IF g_autocommit THEN
                        COMMIT;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        l_error_msg := SUBSTR(
                            DBMS_UTILITY.format_error_stack
                            || ' - '
                            || DBMS_UTILITY.format_error_backtrace,
                            1, 200);
                        l_error_count := l_error_count + 1;

                        UPDATE plt_queue
                        SET    last_error = l_error_msg
                        WHERE  queue_id   = rec.queue_id;

                        IF g_autocommit THEN
                            COMMIT;
                        END IF;
                END;
            END LOOP;
        END IF;

        -- -------- Summary logging --------
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
    *
    * @param p_value TRUE to enable auto-commit, FALSE to disable
    */
   PROCEDURE set_autocommit (p_value BOOLEAN)
   IS
   BEGIN
       g_autocommit := p_value;
   END;

   /**
    * Gets the current auto-commit mode setting
    *
    * @return Current auto-commit setting
    */
   FUNCTION get_autocommit
       RETURN BOOLEAN
   IS
   BEGIN
       RETURN g_autocommit;
   END;

   /**
    * Sets the backend URL for telemetry export
    *
    * @param p_url The HTTP endpoint URL
    */
   PROCEDURE set_backend_url (p_url VARCHAR2)
   IS
   BEGIN
       g_backend_url := p_url;
   END;

   /**
    * Gets the current backend URL
    *
    * @return Current backend URL
    */
   FUNCTION get_backend_url
       RETURN VARCHAR2
   IS
   BEGIN
       RETURN g_backend_url;
   END;

   /**
    * Sets the API key for backend authentication
    *
    * @param p_key The API key string
    */
   PROCEDURE set_api_key (p_key VARCHAR2)
   IS
   BEGIN
       g_api_key := p_key;
   END;

   /**
    * Sets the HTTP timeout for backend calls
    *
    * @param p_timeout Timeout in seconds
    */
   PROCEDURE set_backend_timeout (p_timeout NUMBER)
   IS
   BEGIN
       g_backend_timeout := p_timeout;
   END;

   /**
    * Sets the async processing mode
    *
    * @param p_async TRUE for async mode, FALSE for synchronous
    */
   PROCEDURE set_async_mode (p_async BOOLEAN)
   IS
   BEGIN
       g_async_mode := p_async;
   END;

   /**
    * Gets the current trace ID
    *
    * @return Current trace ID or NULL if no active trace
    */
   FUNCTION get_current_trace_id
       RETURN VARCHAR2
   IS
   BEGIN
       RETURN g_current_trace_id;
   END get_current_trace_id;

   /**
    * Gets the current span ID
    *
    * @return Current span ID or NULL if no active span
    */
   FUNCTION get_current_span_id
       RETURN VARCHAR2
   IS
   BEGIN
       RETURN g_current_span_id;
   END get_current_span_id;

        
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
        l_error_code   NUMBER;
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
                        'send_log_internal: Failed to convert attributes - ' || SUBSTR(DBMS_UTILITY.format_error_stack|| ' - '|| DBMS_UTILITY.format_error_backtrace, 1, 200),
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
                l_error_msg := SUBSTR(SQLERRM, 1, 4000);
                
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
                l_error_msg := SUBSTR(SQLERRM, 1, 4000);
                
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
            l_error_code := SQLCODE;
            l_error_msg := SUBSTR(SQLERRM, 1, 4000);

            BEGIN
                INSERT INTO plt_telemetry_errors (error_time, error_message, error_code, module_name)
                VALUES (
                    SYSTIMESTAMP,
                    'send_log_internal: Unexpected error - ' || l_error_msg,
                    l_error_code,
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

END PLTelemetry;
/
