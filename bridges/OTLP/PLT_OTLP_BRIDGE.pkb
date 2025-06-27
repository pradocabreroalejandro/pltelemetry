CREATE OR REPLACE PACKAGE BODY PLT_OTLP_BRIDGE
AS
    --------------------------------------------------------------------------
    -- HYBRID STRING MANAGEMENT TYPES
    --------------------------------------------------------------------------
    
    -- Type for handling large strings efficiently
    TYPE t_large_string IS RECORD (
        content     VARCHAR2(32767),
        overflow    CLOB,
        use_clob    BOOLEAN DEFAULT FALSE,
        total_size  NUMBER DEFAULT 0
    );
    
    -- Constants for size management
    C_VARCHAR_LIMIT     CONSTANT NUMBER := 32000; -- Leave some buffer
    C_CHUNK_SIZE        CONSTANT NUMBER := 8000;  -- For building strings
    
    --------------------------------------------------------------------------
    -- CONFIGURATION VARIABLES
    --------------------------------------------------------------------------
    
    -- JSON parsing mode configuration
    g_use_native_json   BOOLEAN := FALSE; -- Conservative default
    
    /**
     * Log error with context
     */
    PROCEDURE log_error (p_message VARCHAR2, p_context VARCHAR2 DEFAULT NULL, p_http_status NUMBER DEFAULT NULL)
    IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO plt_telemetry_errors (error_time,
                                          error_message,
                                          error_stack,
                                          module_name)
             VALUES (SYSTIMESTAMP,
                     SUBSTR ('OTLP Bridge: ' || p_message, 1, 4000),
                     SUBSTR (p_context, 1, 4000),
                     'PLT_OTLP_BRIDGE');

        COMMIT;

        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE ('OTLP Error: ' || p_message);
            IF p_context IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE ('Context: ' || SUBSTR (p_context, 1, 200));
            END IF;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Never fail on logging
    END log_error;

    
    --------------------------------------------------------------------------
    -- HYBRID STRING HELPER FUNCTIONS
    --------------------------------------------------------------------------
    
    /**
     * Initialize a large string
     */
    FUNCTION init_large_string
    RETURN t_large_string
    IS
        l_result t_large_string;
    BEGIN
        l_result.content := '';
        l_result.use_clob := FALSE;
        l_result.total_size := 0;
        DBMS_LOB.CREATETEMPORARY(l_result.overflow, TRUE);
        RETURN l_result;
    END init_large_string;
    
    /**
     * Append content to large string with automatic overflow handling
     */
    PROCEDURE append_to_large_string(
        p_large_string IN OUT NOCOPY t_large_string,
        p_content      IN VARCHAR2
    )
    IS
        l_content_size NUMBER;
    BEGIN
        IF p_content IS NULL THEN
            RETURN;
        END IF;
        
        l_content_size := LENGTH(p_content);
        
        -- Check if we need to switch to CLOB
        IF NOT p_large_string.use_clob AND 
           (p_large_string.total_size + l_content_size) > C_VARCHAR_LIMIT THEN
            
            -- Switch to CLOB mode
            p_large_string.use_clob := TRUE;
            
            -- Move existing content to CLOB if any
            IF LENGTH(p_large_string.content) > 0 THEN
                DBMS_LOB.WRITEAPPEND(p_large_string.overflow, 
                                   LENGTH(p_large_string.content), 
                                   p_large_string.content);
                p_large_string.content := NULL; -- Free memory
            END IF;
            
            -- Add new content to CLOB
            DBMS_LOB.WRITEAPPEND(p_large_string.overflow, l_content_size, p_content);
            
        ELSIF p_large_string.use_clob THEN
            -- Already in CLOB mode, append to CLOB
            DBMS_LOB.WRITEAPPEND(p_large_string.overflow, l_content_size, p_content);
            
        ELSE
            -- Still in VARCHAR2 mode, append normally
            p_large_string.content := p_large_string.content || p_content;
        END IF;
        
        p_large_string.total_size := p_large_string.total_size + l_content_size;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error('Error in append_to_large_string: ' || SQLERRM, 
                     'Content size: ' || l_content_size || ', Total: ' || p_large_string.total_size);
            RAISE;
    END append_to_large_string;
    
    /**
     * Append CLOB content to large string
     */
    PROCEDURE append_clob_to_large_string(
        p_large_string IN OUT NOCOPY t_large_string,
        p_clob         IN CLOB
    )
    IS
        l_clob_size NUMBER;
        l_buffer    VARCHAR2(32767);
        l_offset    NUMBER := 1;
        l_amount    NUMBER;
    BEGIN
        IF p_clob IS NULL THEN
            RETURN;
        END IF;
        
        l_clob_size := DBMS_LOB.GETLENGTH(p_clob);
        
        -- Force switch to CLOB mode for efficiency
        IF NOT p_large_string.use_clob THEN
            p_large_string.use_clob := TRUE;
            
            -- Move existing content to CLOB if any
            IF LENGTH(p_large_string.content) > 0 THEN
                DBMS_LOB.WRITEAPPEND(p_large_string.overflow, 
                                   LENGTH(p_large_string.content), 
                                   p_large_string.content);
                p_large_string.content := NULL;
            END IF;
        END IF;
        
        -- Append the CLOB content
        DBMS_LOB.APPEND(p_large_string.overflow, p_clob);
        p_large_string.total_size := p_large_string.total_size + l_clob_size;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error('Error in append_clob_to_large_string: ' || SQLERRM, 
                     'CLOB size: ' || l_clob_size);
            RAISE;
    END append_clob_to_large_string;
    
    /**
     * Get final content as appropriate type
     */
    FUNCTION get_large_string_content(p_large_string IN t_large_string)
    RETURN CLOB
    IS
        l_result CLOB;
    BEGIN
        IF p_large_string.use_clob THEN
            RETURN p_large_string.overflow;
        ELSE
            -- Convert VARCHAR2 to CLOB for consistent interface
            DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
            IF p_large_string.content IS NOT NULL THEN
                DBMS_LOB.WRITEAPPEND(l_result, LENGTH(p_large_string.content), p_large_string.content);
            END IF;
            RETURN l_result;
        END IF;
    END get_large_string_content;
    
    /**
     * Check if large string is using CLOB
     */
    FUNCTION is_using_clob(p_large_string IN t_large_string)
    RETURN BOOLEAN
    IS
    BEGIN
        RETURN p_large_string.use_clob;
    END is_using_clob;
    
    /**
     * Clean up large string resources
     */
    PROCEDURE cleanup_large_string(p_large_string IN OUT NOCOPY t_large_string)
    IS
    BEGIN
        IF DBMS_LOB.ISTEMPORARY(p_large_string.overflow) = 1 THEN
            DBMS_LOB.FREETEMPORARY(p_large_string.overflow);
        END IF;
        p_large_string.content := NULL;
        p_large_string.use_clob := FALSE;
        p_large_string.total_size := 0;
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Don't fail on cleanup
    END cleanup_large_string;

    --------------------------------------------------------------------------
    -- ENHANCED JSON ESCAPING
    --------------------------------------------------------------------------
    
    /**
     * Comprehensive JSON string escaping
     * Handles all JSON special characters and control sequences
     */
    FUNCTION escape_json_string (p_input VARCHAR2)
        RETURN VARCHAR2
    IS
        l_output   VARCHAR2 (4000);
    BEGIN
        IF p_input IS NULL THEN
            RETURN NULL;
        END IF;

        -- Handle empty string
        IF LENGTH(p_input) = 0 THEN
            RETURN '';
        END IF;

        l_output := p_input;
        
        -- CRITICAL: Backslash MUST be first to avoid double-escaping
        l_output := REPLACE (l_output, '\', '\\');
        
        -- JSON special characters
        l_output := REPLACE (l_output, '"', '\"');
        l_output := REPLACE (l_output, '/', '\/');  -- Optional but safe
        
        -- Control characters (required by JSON spec)
        l_output := REPLACE (l_output, CHR(8), '\b');   -- Backspace
        l_output := REPLACE (l_output, CHR(12), '\f');  -- Form feed
        l_output := REPLACE (l_output, CHR(10), '\n');  -- Line feed
        l_output := REPLACE (l_output, CHR(13), '\r');  -- Carriage return
        l_output := REPLACE (l_output, CHR(9), '\t');   -- Tab
        
        -- Additional control characters that could cause issues
        l_output := REPLACE (l_output, CHR(0), '\u0000');   -- Null
        l_output := REPLACE (l_output, CHR(1), '\u0001');   -- SOH
        l_output := REPLACE (l_output, CHR(2), '\u0002');   -- STX
        l_output := REPLACE (l_output, CHR(3), '\u0003');   -- ETX
        l_output := REPLACE (l_output, CHR(4), '\u0004');   -- EOT
        l_output := REPLACE (l_output, CHR(5), '\u0005');   -- ENQ
        l_output := REPLACE (l_output, CHR(6), '\u0006');   -- ACK
        l_output := REPLACE (l_output, CHR(7), '\u0007');   -- BEL
        l_output := REPLACE (l_output, CHR(11), '\u000B');  -- VT
        l_output := REPLACE (l_output, CHR(14), '\u000E');  -- SO
        l_output := REPLACE (l_output, CHR(15), '\u000F');  -- SI
        l_output := REPLACE (l_output, CHR(16), '\u0010');  -- DLE
        l_output := REPLACE (l_output, CHR(17), '\u0011');  -- DC1
        l_output := REPLACE (l_output, CHR(18), '\u0012');  -- DC2
        l_output := REPLACE (l_output, CHR(19), '\u0013');  -- DC3
        l_output := REPLACE (l_output, CHR(20), '\u0014');  -- DC4
        l_output := REPLACE (l_output, CHR(21), '\u0015');  -- NAK
        l_output := REPLACE (l_output, CHR(22), '\u0016');  -- SYN
        l_output := REPLACE (l_output, CHR(23), '\u0017');  -- ETB
        l_output := REPLACE (l_output, CHR(24), '\u0018');  -- CAN
        l_output := REPLACE (l_output, CHR(25), '\u0019');  -- EM
        l_output := REPLACE (l_output, CHR(26), '\u001A');  -- SUB
        l_output := REPLACE (l_output, CHR(27), '\u001B');  -- ESC
        l_output := REPLACE (l_output, CHR(28), '\u001C');  -- FS
        l_output := REPLACE (l_output, CHR(29), '\u001D');  -- GS
        l_output := REPLACE (l_output, CHR(30), '\u001E');  -- RS
        l_output := REPLACE (l_output, CHR(31), '\u001F');  -- US
        l_output := REPLACE (l_output, CHR(127), '\u007F'); -- DEL

        -- Truncate if too long (safety net)
        IF LENGTH(l_output) > 3900 THEN
            l_output := SUBSTR(l_output, 1, 3900) || '...[TRUNCATED]';
        END IF;

        RETURN l_output;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Emergency fallback - log the issue but don't break JSON
            log_error('escape_json_string failed for input: ' || SUBSTR(p_input, 1, 100), 
                     'Error: ' || SQLERRM);
            
            -- Return safe fallback
            RETURN REPLACE(REPLACE(REPLACE(NVL(p_input, ''), '\', '\\'), '"', '\"'), CHR(10), ' ');
    END escape_json_string;

    --------------------------------------------------------------------------
    -- DUAL JSON PARSING IMPLEMENTATION
    --------------------------------------------------------------------------
    
    /**
     * Legacy JSON value extraction using regex
     */
    FUNCTION get_json_value_legacy (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
        l_pattern   VARCHAR2 (200);
        l_value     VARCHAR2 (4000);
    BEGIN
        -- Try quoted value first
        l_pattern := '"' || p_key || '"\s*:\s*"([^"]+)"';
        l_value := REGEXP_SUBSTR (p_json, l_pattern, 1, 1, NULL, 1);

        IF l_value IS NOT NULL THEN
            RETURN l_value;
        END IF;

        -- Try numeric value
        l_pattern := '"' || p_key || '"\s*:\s*([0-9.-]+)';
        l_value := REGEXP_SUBSTR (p_json, l_pattern, 1, 1, NULL, 1);

        RETURN l_value;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END get_json_value_legacy;

    /**
     * Native JSON value extraction using Oracle 12c+ functions
     */
    FUNCTION get_json_value_native (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
        l_value VARCHAR2(4000);
    BEGIN
        -- Use JSON_VALUE for better parsing
        l_value := JSON_VALUE(p_json, '$.' || p_key);
        RETURN l_value;
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback to legacy if native fails
            IF g_debug_mode THEN
                DBMS_OUTPUT.PUT_LINE('Native JSON parsing failed for key: ' || p_key || ', falling back to legacy');
            END IF;
            RETURN get_json_value_legacy(p_json, p_key);
    END get_json_value_native;

    /**
     * Smart JSON value extraction with mode switching
     */
    FUNCTION get_json_value (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
    BEGIN
        IF g_use_native_json THEN
            RETURN get_json_value_native(p_json, p_key);
        ELSE
            RETURN get_json_value_legacy(p_json, p_key);
        END IF;
    END get_json_value;

    /**
     * Legacy JSON object extraction using manual parsing
     */
    FUNCTION get_json_object_legacy (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
        l_start   NUMBER;
        l_end     NUMBER;
        l_depth   NUMBER := 0;
        l_char    VARCHAR2 (1);
    BEGIN
        l_start := INSTR (p_json, '"' || p_key || '"');

        IF l_start = 0 THEN
            RETURN NULL;
        END IF;

        l_start := INSTR (p_json, '{', l_start);

        IF l_start = 0 THEN
            RETURN NULL;
        END IF;

        -- Find matching closing brace
        FOR i IN l_start .. LENGTH (p_json) LOOP
            l_char := SUBSTR (p_json, i, 1);

            IF l_char = '{' THEN
                l_depth := l_depth + 1;
            ELSIF l_char = '}' THEN
                l_depth := l_depth - 1;

                IF l_depth = 0 THEN
                    RETURN SUBSTR (p_json, l_start, i - l_start + 1);
                END IF;
            END IF;
        END LOOP;

        RETURN NULL;
    END get_json_object_legacy;

    /**
     * Native JSON object extraction using Oracle 12c+ functions
     */
    FUNCTION get_json_object_native (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
        l_result VARCHAR2(32767);
    BEGIN
        -- Use JSON_QUERY for object extraction
        l_result := JSON_QUERY(p_json, '$.' || p_key);
        RETURN l_result;
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback to legacy if native fails
            IF g_debug_mode THEN
                DBMS_OUTPUT.PUT_LINE('Native JSON object extraction failed for key: ' || p_key || ', falling back to legacy');
            END IF;
            RETURN get_json_object_legacy(p_json, p_key);
    END get_json_object_native;

    /**
     * Smart JSON object extraction with mode switching
     */
    FUNCTION get_json_object (p_json VARCHAR2, p_key VARCHAR2)
        RETURN VARCHAR2
    IS
    BEGIN
        IF g_use_native_json THEN
            RETURN get_json_object_native(p_json, p_key);
        ELSE
            RETURN get_json_object_legacy(p_json, p_key);
        END IF;
    END get_json_object;

    --------------------------------------------------------------------------
    -- ENHANCED ATTRIBUTES CONVERSION
    --------------------------------------------------------------------------

    /**
     * Legacy attributes conversion using manual parsing
     */
    FUNCTION convert_attributes_legacy(p_attrs_json VARCHAR2)
    RETURN CLOB
    IS
        l_result        t_large_string;
        l_final_clob    CLOB;
        l_key           VARCHAR2(255);
        l_value         VARCHAR2(4000);
        l_pos           NUMBER := 1;
        l_colon         NUMBER;
        l_comma         NUMBER;
        l_quote         NUMBER;
        l_first         BOOLEAN := TRUE;
        l_attr_json     VARCHAR2(1000);
    BEGIN
        l_result := init_large_string();
        
        append_to_large_string(l_result, '[');
        
        IF p_attrs_json IS NULL OR LENGTH(p_attrs_json) < 3 THEN
            append_to_large_string(l_result, ']');
            l_final_clob := get_large_string_content(l_result);
            cleanup_large_string(l_result);
            RETURN l_final_clob;
        END IF;

        -- Enhanced parser with better error handling
        WHILE l_pos < LENGTH(p_attrs_json) LOOP
            -- Find next key
            l_quote := INSTR(p_attrs_json, '"', l_pos);
            EXIT WHEN l_quote = 0;

            l_colon := INSTR(p_attrs_json, ':', l_quote);
            EXIT WHEN l_colon = 0;

            l_key := SUBSTR(p_attrs_json, l_quote + 1, 
                           INSTR(p_attrs_json, '"', l_quote + 1) - l_quote - 1);

            -- Find value
            l_quote := INSTR(p_attrs_json, '"', l_colon);

            IF l_quote > 0 THEN
                l_comma := INSTR(p_attrs_json, '"', l_quote + 1);
                l_value := SUBSTR(p_attrs_json, l_quote + 1, l_comma - l_quote - 1);

                -- Build attribute JSON chunk
                l_attr_json := '{"key":"' || escape_json_string(l_key) || 
                              '","value":{"stringValue":"' || escape_json_string(l_value) || '"}}';

                -- Add separator if needed
                IF NOT l_first THEN
                    append_to_large_string(l_result, ',');
                END IF;

                append_to_large_string(l_result, l_attr_json);
                l_first := FALSE;
                l_pos := l_comma + 1;
            ELSE
                EXIT;
            END IF;
        END LOOP;

        append_to_large_string(l_result, ']');
        l_final_clob := get_large_string_content(l_result);
        cleanup_large_string(l_result);
        
        -- DEBUG: Log what we're parsing
        IF g_debug_mode THEN
            log_error('DEBUG convert_attributes_legacy', 
                     'Input: ' || SUBSTR(p_attrs_json, 1, 200) || 
                     ' Output: ' || SUBSTR(DBMS_LOB.SUBSTR(l_final_clob, 200, 1), 1, 200));
        END IF;
        
        RETURN l_final_clob;
        
    EXCEPTION
        WHEN OTHERS THEN
            cleanup_large_string(l_result);
            log_error('Error in convert_attributes_legacy: ' || SQLERRM, 
                     SUBSTR(p_attrs_json, 1, 500));
            
            -- Return minimal valid JSON
            DBMS_LOB.CREATETEMPORARY(l_final_clob, TRUE);
            DBMS_LOB.WRITEAPPEND(l_final_clob, 2, '[]');
            RETURN l_final_clob;
    END convert_attributes_legacy;

    /**
     * Native attributes conversion using Oracle 12c+ JSON functions
     */
    FUNCTION convert_attributes_native(p_attrs_json VARCHAR2)
    RETURN CLOB
    IS
        l_result        t_large_string;
        l_final_clob    CLOB;
        l_json_obj      JSON_OBJECT_T;
        l_keys          JSON_KEY_LIST;
        l_key           VARCHAR2(255);
        l_value         VARCHAR2(4000);
        l_first         BOOLEAN := TRUE;
        l_attr_json     VARCHAR2(1000);
    BEGIN
        l_result := init_large_string();
        append_to_large_string(l_result, '[');
        
        IF p_attrs_json IS NULL OR LENGTH(p_attrs_json) < 3 THEN
            append_to_large_string(l_result, ']');
            l_final_clob := get_large_string_content(l_result);
            cleanup_large_string(l_result);
            RETURN l_final_clob;
        END IF;

        -- Parse using native JSON
        l_json_obj := JSON_OBJECT_T.parse(p_attrs_json);
        l_keys := l_json_obj.get_keys();
        
        -- Process each key-value pair
        FOR i IN 1 .. l_keys.COUNT LOOP
            l_key := l_keys(i);
            l_value := l_json_obj.get_string(l_key);
            
            -- Build OTLP attribute format
            l_attr_json := '{"key":"' || escape_json_string(l_key) || 
                          '","value":{"stringValue":"' || escape_json_string(l_value) || '"}}';

            IF NOT l_first THEN
                append_to_large_string(l_result, ',');
            END IF;

            append_to_large_string(l_result, l_attr_json);
            l_first := FALSE;
        END LOOP;

        append_to_large_string(l_result, ']');
        l_final_clob := get_large_string_content(l_result);
        cleanup_large_string(l_result);
        
        RETURN l_final_clob;
        
    EXCEPTION
        WHEN OTHERS THEN
            cleanup_large_string(l_result);
            
            -- Fallback to legacy parsing
            IF g_debug_mode THEN
                DBMS_OUTPUT.PUT_LINE('Native JSON attributes conversion failed, falling back to legacy');
            END IF;
            
            RETURN convert_attributes_legacy(p_attrs_json);
    END convert_attributes_native;

    /**
     * Smart attributes conversion with mode switching
     */
    FUNCTION convert_attributes_to_otlp_enhanced(p_attrs_json VARCHAR2)
    RETURN CLOB
    IS
    BEGIN

        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('convert_attributes_to_otlp_enhanced called with mode: ' || 
                                 CASE WHEN g_use_native_json THEN 'NATIVE' ELSE 'LEGACY' END);
            DBMS_OUTPUT.PUT_LINE('Input: ' || SUBSTR(p_attrs_json, 1, 200));
        END IF;

        IF g_use_native_json THEN
            RETURN convert_attributes_native(p_attrs_json);
        ELSE
            RETURN convert_attributes_legacy(p_attrs_json);
        END IF;
    END convert_attributes_to_otlp_enhanced;

    --------------------------------------------------------------------------
    -- UTILITY FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Convert timestamp to Unix nanoseconds
     */
    FUNCTION to_unix_nano (p_timestamp VARCHAR2)
        RETURN VARCHAR2
    IS
        l_ts              TIMESTAMP WITH TIME ZONE;
        l_epoch_seconds   NUMBER;
    BEGIN
        BEGIN
            -- Try PLTelemetry format first (with timezone)
            l_ts := TO_TIMESTAMP_TZ (p_timestamp, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZH:TZM');
        EXCEPTION
            WHEN OTHERS THEN
                -- Try UTC format
                l_ts := TO_TIMESTAMP_TZ (p_timestamp, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"');
        END;

        -- Calculate nanoseconds since epoch
        l_epoch_seconds :=
              EXTRACT (DAY FROM (l_ts - TIMESTAMP '1970-01-01 00:00:00 +00:00')) * 86400
            + EXTRACT (HOUR FROM (l_ts - TIMESTAMP '1970-01-01 00:00:00 +00:00')) * 3600
            + EXTRACT (MINUTE FROM (l_ts - TIMESTAMP '1970-01-01 00:00:00 +00:00')) * 60
            + EXTRACT (SECOND FROM (l_ts - TIMESTAMP '1970-01-01 00:00:00 +00:00'));

        RETURN TO_CHAR (l_epoch_seconds * 1000000000);
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback to current time
            RETURN TO_CHAR ( (SYSDATE - DATE '1970-01-01') * 86400 * 1000000000);
    END to_unix_nano;

    /**
     * Add milliseconds to Unix nano timestamp
     */
    FUNCTION to_unix_nano_plus_ms (p_timestamp VARCHAR2, p_duration_ms NUMBER)
        RETURN VARCHAR2
    IS
        l_start_nano   NUMBER;
    BEGIN
        l_start_nano := TO_NUMBER (to_unix_nano (p_timestamp));
        RETURN TO_CHAR (l_start_nano + (NVL (p_duration_ms, 0) * 1000000));
    END to_unix_nano_plus_ms;

    /**
     * Convert PLTelemetry status to OTLP status code
     */
    FUNCTION get_status_code (p_status VARCHAR2)
        RETURN NUMBER
    IS
    BEGIN
        RETURN CASE UPPER (NVL (p_status, 'UNSET')) 
                   WHEN 'OK' THEN 1 
                   WHEN 'ERROR' THEN 2 
                   ELSE 0  -- UNSET
               END;
    END get_status_code;

    /**
     * Generate resource attributes (enhanced with better size management)
     */
    FUNCTION generate_resource_attributes
        RETURN VARCHAR2
    IS
        l_attrs   VARCHAR2 (4000);
    BEGIN
        l_attrs := '{"key": "service.name", "value": {"stringValue": "' || 
                   escape_json_string (g_service_name) || '"}}';

        l_attrs := l_attrs || ',{"key": "service.version", "value": {"stringValue": "' || 
                   escape_json_string (g_service_version) || '"}}';

        -- Add instance info
        IF g_service_instance IS NULL THEN
            g_service_instance := SYS_CONTEXT ('USERENV', 'HOST') || ':' || 
                                 SYS_CONTEXT ('USERENV', 'INSTANCE_NAME');
        END IF;

        l_attrs := l_attrs || ',{"key": "service.instance.id", "value": {"stringValue": "' || 
                   escape_json_string (g_service_instance) || '"}}';

        -- Add tenant if configured
        IF g_tenant_id IS NOT NULL THEN
            l_attrs := l_attrs || ',{"key": "tenant.id", "value": {"stringValue": "' || 
                       escape_json_string (g_tenant_id) || '"}}';
        END IF;

        -- Add telemetry SDK info
        l_attrs := l_attrs || ',{"key": "telemetry.sdk.name", "value": {"stringValue": "PLTelemetry"}}';
        l_attrs := l_attrs || ',{"key": "telemetry.sdk.language", "value": {"stringValue": "plsql"}}';
        l_attrs := l_attrs || ',{"key": "telemetry.sdk.version", "value": {"stringValue": "1.0.0"}}';
        
        -- Add JSON parsing mode info for debugging
        l_attrs := l_attrs || ',{"key": "plt.json_mode", "value": {"stringValue": "' || 
                   CASE WHEN g_use_native_json THEN 'native' ELSE 'legacy' END || '"}}';

        RETURN '[' || l_attrs || ']';
    END generate_resource_attributes;

    
    --------------------------------------------------------------------------
    -- ENHANCED HTTP COMMUNICATION
    --------------------------------------------------------------------------

    /**
     * Smart HTTP sender with automatic chunking
     */
    PROCEDURE send_to_endpoint_enhanced(p_endpoint VARCHAR2, p_content CLOB)
    IS
        l_req           UTL_HTTP.REQ;
        l_res           UTL_HTTP.RESP;
        l_buffer        VARCHAR2(32767);
        l_response      CLOB;
        l_content_size  NUMBER;
        l_offset        NUMBER := 1;
        l_amount        NUMBER;
    BEGIN
        l_content_size := DBMS_LOB.GETLENGTH(p_content);
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Sending to: ' || p_endpoint);
            DBMS_OUTPUT.PUT_LINE('Content size: ' || l_content_size || ' chars');
            DBMS_OUTPUT.PUT_LINE('Using chunked transfer: ' || CASE WHEN l_content_size > 32767 THEN 'YES' ELSE 'NO' END);
            DBMS_OUTPUT.PUT_LINE('JSON parsing mode: ' || CASE WHEN g_use_native_json THEN 'NATIVE' ELSE 'LEGACY' END);
        END IF;

        -- Set timeout
        UTL_HTTP.SET_TRANSFER_TIMEOUT(g_timeout);

        -- Initialize request
        l_req := UTL_HTTP.BEGIN_REQUEST(p_endpoint, 'POST', 'HTTP/1.1');
        UTL_HTTP.SET_HEADER(l_req, 'Content-Type', 'application/json; charset=utf-8');
        UTL_HTTP.SET_HEADER(l_req, 'Content-Length', l_content_size);
        
        -- Add custom headers for debugging
        IF g_debug_mode THEN
            UTL_HTTP.SET_HEADER(l_req, 'X-PLT-Source', 'Oracle-OTLP-Bridge');
            UTL_HTTP.SET_HEADER(l_req, 'X-PLT-Size', TO_CHAR(l_content_size));
            UTL_HTTP.SET_HEADER(l_req, 'X-PLT-JSON-Mode', CASE WHEN g_use_native_json THEN 'native' ELSE 'legacy' END);
        END IF;

        -- Smart content sending
        IF l_content_size <= 32767 THEN
            -- Small content - send as VARCHAR2 (faster)
            DBMS_LOB.READ(p_content, l_content_size, 1, l_buffer);
            UTL_HTTP.WRITE_TEXT(l_req, l_buffer);
            
        ELSE
            -- Large content - chunked sending
            WHILE l_offset <= l_content_size LOOP
                l_amount := LEAST(32767, l_content_size - l_offset + 1);
                DBMS_LOB.READ(p_content, l_amount, l_offset, l_buffer);
                UTL_HTTP.WRITE_TEXT(l_req, l_buffer);
                l_offset := l_offset + l_amount;
                
                IF g_debug_mode AND MOD(l_offset, 100000) = 1 THEN
                    DBMS_OUTPUT.PUT_LINE('Sent chunk: ' || l_offset || '/' || l_content_size);
                END IF;
            END LOOP;
        END IF;

        -- Get response
        l_res := UTL_HTTP.GET_RESPONSE(l_req);

        -- Check status
        IF l_res.status_code NOT IN (200, 201, 202, 204) THEN
            -- Read error response
            DBMS_LOB.CREATETEMPORARY(l_response, TRUE);
            BEGIN
                LOOP
                    UTL_HTTP.READ_TEXT(l_res, l_buffer, 32767);
                    DBMS_LOB.WRITEAPPEND(l_response, LENGTH(l_buffer), l_buffer);
                END LOOP;
            EXCEPTION
                WHEN UTL_HTTP.END_OF_BODY THEN
                    NULL;
            END;

            log_error('HTTP ' || l_res.status_code || ': ' || l_res.reason_phrase, 
                     SUBSTR(l_response, 1, 4000), l_res.status_code);
            DBMS_LOB.FREETEMPORARY(l_response);
            
        ELSIF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Success: HTTP ' || l_res.status_code || 
                               ' (sent ' || l_content_size || ' chars)');
        END IF;

        UTL_HTTP.END_RESPONSE(l_res);
        
    EXCEPTION
        WHEN UTL_HTTP.TRANSFER_TIMEOUT THEN
            log_error('Request timeout after ' || g_timeout || ' seconds', 
                     'Endpoint: ' || p_endpoint || ', Size: ' || l_content_size);
            IF l_res.status_code IS NOT NULL THEN
                UTL_HTTP.END_RESPONSE(l_res);
            END IF;
            
        WHEN OTHERS THEN
            log_error('HTTP Error: ' || SQLERRM, 
                     'Endpoint: ' || p_endpoint || ', Backtrace: ' || 
                     DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            IF l_res.status_code IS NOT NULL THEN
                UTL_HTTP.END_RESPONSE(l_res);
            END IF;
    END send_to_endpoint_enhanced;

    FUNCTION convert_events_to_otlp(p_events_json VARCHAR2)
    RETURN CLOB
    IS
        l_result        t_large_string;
        l_final_clob    CLOB;
        l_json_array    JSON_ARRAY_T;
        l_event_obj     JSON_OBJECT_T;
        l_event_name    VARCHAR2(255);
        l_event_time    VARCHAR2(50);
        l_event_attrs   VARCHAR2(4000);
        l_first         BOOLEAN := TRUE;
        l_event_json    VARCHAR2(1000);
    BEGIN
        -- Initialize result
        l_result := init_large_string();
        append_to_large_string(l_result, '[');
        
        -- Handle null or empty events
        IF p_events_json IS NULL OR LENGTH(p_events_json) < 3 OR p_events_json = '[]' THEN
            append_to_large_string(l_result, ']');
            l_final_clob := get_large_string_content(l_result);
            cleanup_large_string(l_result);
            RETURN l_final_clob;
        END IF;

        -- Try native JSON parsing first, fall back to legacy if needed
        BEGIN
            IF g_use_native_json THEN
                -- Use Oracle 12c+ JSON functions
                l_json_array := JSON_ARRAY_T.parse(p_events_json);
                
                FOR i IN 0 .. l_json_array.get_size() - 1 LOOP
                    l_event_obj := JSON_OBJECT_T(l_json_array.get(i));
                    l_event_name := l_event_obj.get_string('name');
                    l_event_time := l_event_obj.get_string('time');
                    
                    -- Build OTLP event format
                    l_event_json := '{"timeUnixNano":"' || to_unix_nano(l_event_time) || '",' ||
                                   '"name":"' || escape_json_string(l_event_name) || '"}';
                    
                    IF NOT l_first THEN
                        append_to_large_string(l_result, ',');
                    END IF;
                    
                    append_to_large_string(l_result, l_event_json);
                    l_first := FALSE;
                END LOOP;
            ELSE
                -- Use legacy regex parsing
                DECLARE
                    l_pos         NUMBER := 1;
                    l_event_start NUMBER;
                    l_event_end   NUMBER;
                    l_event_str   VARCHAR2(500);
                    l_name_start  NUMBER;
                    l_name_end    NUMBER;
                    l_time_start  NUMBER;
                    l_time_end    NUMBER;
                BEGIN
                    -- Simple regex-based parsing for events array
                    WHILE l_pos < LENGTH(p_events_json) LOOP
                        -- Find next event object
                        l_event_start := INSTR(p_events_json, '{"name":', l_pos);
                        EXIT WHEN l_event_start = 0;
                        
                        l_event_end := INSTR(p_events_json, '}', l_event_start);
                        EXIT WHEN l_event_end = 0;
                        
                        l_event_str := SUBSTR(p_events_json, l_event_start, l_event_end - l_event_start + 1);
                        
                        -- Extract name
                        l_name_start := INSTR(l_event_str, '"name":"') + 8;
                        l_name_end := INSTR(l_event_str, '"', l_name_start);
                        l_event_name := SUBSTR(l_event_str, l_name_start, l_name_end - l_name_start);
                        
                        -- Extract time
                        l_time_start := INSTR(l_event_str, '"time":"') + 8;
                        l_time_end := INSTR(l_event_str, '"', l_time_start);
                        l_event_time := SUBSTR(l_event_str, l_time_start, l_time_end - l_time_start);
                        
                        -- Build OTLP event
                        l_event_json := '{"timeUnixNano":"' || to_unix_nano(l_event_time) || '",' ||
                                       '"name":"' || escape_json_string(l_event_name) || '"}';
                        
                        IF NOT l_first THEN
                            append_to_large_string(l_result, ',');
                        END IF;
                        
                        append_to_large_string(l_result, l_event_json);
                        l_first := FALSE;
                        
                        l_pos := l_event_end + 1;
                    END LOOP;
                END;
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                log_error('Error converting events to OTLP: ' || SQLERRM, 
                         'Events JSON: ' || SUBSTR(p_events_json, 1, 200));
                -- Continue with empty events array
        END;

        append_to_large_string(l_result, ']');
        l_final_clob := get_large_string_content(l_result);
        cleanup_large_string(l_result);
        
        RETURN l_final_clob;
        
    EXCEPTION
        WHEN OTHERS THEN
            cleanup_large_string(l_result);
            log_error('Critical error in convert_events_to_otlp: ' || SQLERRM, 
                     SUBSTR(p_events_json, 1, 200));
            
            -- Return empty events array as fallback
            DBMS_LOB.CREATETEMPORARY(l_final_clob, TRUE);
            DBMS_LOB.WRITEAPPEND(l_final_clob, 2, '[]');
            RETURN l_final_clob;
    END convert_events_to_otlp;

    --------------------------------------------------------------------------
    -- ENHANCED CORE PROCEDURES
    --------------------------------------------------------------------------

    /**
     * Enhanced trace/span sender using hybrid string management
     */
    PROCEDURE send_trace_otlp (p_json VARCHAR2)
    IS
        l_builder       t_large_string;
        l_final_json    CLOB;
        l_trace_id      VARCHAR2 (32);
        l_span_id       VARCHAR2 (16);
        l_parent_id     VARCHAR2 (16);
        l_operation     VARCHAR2 (255);
        l_timestamp     VARCHAR2 (50);
        l_end_time      VARCHAR2 (50);
        l_duration_ms   NUMBER;
        l_status        VARCHAR2 (50);
        l_attributes    VARCHAR2 (4000);
        l_events        VARCHAR2 (4000);  -- NEW: For events
        l_attr_clob     CLOB;
        l_events_otlp   CLOB;             -- NEW: For OTLP events
    BEGIN
        -- Extract values from PLTelemetry JSON
        l_trace_id := get_json_value (p_json, 'trace_id');
        l_span_id := get_json_value (p_json, 'span_id');
        l_parent_id := get_json_value (p_json, 'parent_span_id');
        l_operation := get_json_value (p_json, 'operation_name');
        l_timestamp := get_json_value (p_json, 'start_time');
        l_end_time := get_json_value (p_json, 'end_time');
        l_duration_ms := TO_NUMBER (get_json_value (p_json, 'duration_ms'));
        l_status := get_json_value (p_json, 'status');
        l_attributes := get_json_object (p_json, 'attributes');
        l_events := get_json_object (p_json, 'events');  -- NEW: Extract events
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Extracted start_time: [' || l_timestamp || ']');
            DBMS_OUTPUT.PUT_LINE('Unix nano result: [' || to_unix_nano(l_timestamp) || ']');
            DBMS_OUTPUT.PUT_LINE('Extracted end_time: [' || l_end_time || ']');
            DBMS_OUTPUT.PUT_LINE('Unix nano result: [' || to_unix_nano(l_end_time) || ']');
            DBMS_OUTPUT.PUT_LINE('Extracted events: [' || SUBSTR(NVL(l_events, 'null'), 1, 100) || ']');
        END IF;

        -- Validate required fields
        IF l_trace_id IS NULL OR l_span_id IS NULL THEN
            log_error ('Invalid trace data: missing trace_id or span_id', SUBSTR (p_json, 1, 500));
            RETURN;
        END IF;

        -- ===== NEW: Convert PLTelemetry events to OTLP format =====
        l_events_otlp := convert_events_to_otlp(l_events);

        -- Initialize large string builder
        l_builder := init_large_string();

        -- Build OTLP JSON using hybrid approach
        append_to_large_string(l_builder, '{' || CHR(10));
        append_to_large_string(l_builder, '  "resourceSpans": [{' || CHR(10));
        append_to_large_string(l_builder, '    "resource": {' || CHR(10));
        append_to_large_string(l_builder, '      "attributes": ' || generate_resource_attributes() || CHR(10));
        append_to_large_string(l_builder, '    },' || CHR(10));
        append_to_large_string(l_builder, '    "scopeSpans": [{' || CHR(10));
        append_to_large_string(l_builder, '      "scope": {' || CHR(10));
        append_to_large_string(l_builder, '        "name": "PLTelemetry",' || CHR(10));
        append_to_large_string(l_builder, '        "version": "1.0.0"' || CHR(10));
        append_to_large_string(l_builder, '      },' || CHR(10));
        append_to_large_string(l_builder, '      "spans": [{' || CHR(10));
        append_to_large_string(l_builder, '        "traceId": "' || l_trace_id || '",' || CHR(10));
        append_to_large_string(l_builder, '        "spanId": "' || l_span_id || '",' || CHR(10));

        -- Add parent span ID if present
        IF l_parent_id IS NOT NULL AND LENGTH(l_parent_id) > 0 THEN
            append_to_large_string(l_builder, '        "parentSpanId": "' || l_parent_id || '",' || CHR(10));
        END IF;

        append_to_large_string(l_builder, '        "name": "' || escape_json_string(NVL(l_operation, 'unknown')) || '",' || CHR(10));
        append_to_large_string(l_builder, '        "kind": 1,' || CHR(10)); -- SPAN_KIND_INTERNAL
        append_to_large_string(l_builder, '        "startTimeUnixNano": "' || to_unix_nano(l_timestamp) || '",' || CHR(10));
        append_to_large_string(l_builder, '        "endTimeUnixNano": "' || to_unix_nano(l_end_time) || '",' || CHR(10));
        append_to_large_string(l_builder, '        "status": {' || CHR(10));
        append_to_large_string(l_builder, '          "code": ' || get_status_code(l_status) || CHR(10));
        append_to_large_string(l_builder, '        }');

        -- ===== NEW: Add events if present =====
        IF l_events_otlp IS NOT NULL AND DBMS_LOB.GETLENGTH(l_events_otlp) > 2 THEN -- More than just "[]"
            append_to_large_string(l_builder, ',' || CHR(10) || '        "events": ');
            append_clob_to_large_string(l_builder, l_events_otlp);
            
            IF g_debug_mode THEN
                DBMS_OUTPUT.PUT_LINE('Added events to OTLP span');
            END IF;
        END IF;

        -- Add attributes if present
        IF l_attributes IS NOT NULL THEN
            l_attr_clob := convert_attributes_to_otlp_enhanced(l_attributes);
            append_to_large_string(l_builder, ',' || CHR(10) || '        "attributes": ');
            append_clob_to_large_string(l_builder, l_attr_clob);
            DBMS_LOB.FREETEMPORARY(l_attr_clob);
        END IF;

        append_to_large_string(l_builder, CHR(10) || '      }]' || CHR(10));
        append_to_large_string(l_builder, '    }]' || CHR(10));
        append_to_large_string(l_builder, '  }]' || CHR(10));
        append_to_large_string(l_builder, '}');

        -- Get final content and send
        l_final_json := get_large_string_content(l_builder);
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Trace JSON size: ' || DBMS_LOB.GETLENGTH(l_final_json) || 
                               ' chars, using CLOB: ' || CASE WHEN is_using_clob(l_builder) THEN 'YES' ELSE 'NO' END);
        END IF;
        
        IF g_debug_mode THEN
            DECLARE
                l_debug_chunk VARCHAR2(4000);
            BEGIN
                l_debug_chunk := DBMS_LOB.SUBSTR(l_final_json, 4000, 1);
                DBMS_OUTPUT.PUT_LINE('==== FINAL OTLP JSON (first 4000 chars) ====');
                DBMS_OUTPUT.PUT_LINE(l_debug_chunk);
                DBMS_OUTPUT.PUT_LINE('==== END OTLP JSON ====');
            END;
        END IF;
        
        send_to_endpoint_enhanced(g_traces_endpoint, l_final_json);
        
        -- Cleanup
        cleanup_large_string(l_builder);
        IF DBMS_LOB.ISTEMPORARY(l_final_json) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_final_json);
        END IF;
        IF l_events_otlp IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_events_otlp) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_events_otlp);
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            cleanup_large_string(l_builder);
            IF l_final_json IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_final_json) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_final_json);
            END IF;
            IF l_events_otlp IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_events_otlp) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_events_otlp);
            END IF;
            log_error ('Error in send_trace_otlp: ' || SQLERRM, SUBSTR (p_json, 1, 500));
    END send_trace_otlp;


    /**
     * Enhanced metric sender using hybrid string management
     */
    PROCEDURE send_metric_otlp (p_json VARCHAR2)
    IS
        l_builder       t_large_string;
        l_final_json    CLOB;
        l_metric_name   VARCHAR2 (255);
        l_value         NUMBER;
        l_timestamp     VARCHAR2 (50);
        l_unit          VARCHAR2 (50);
        l_trace_id      VARCHAR2 (32);
        l_span_id       VARCHAR2 (16);
        l_attributes    VARCHAR2 (4000);
        l_attr_clob     CLOB;
    BEGIN
        -- Extract values
        l_metric_name := get_json_value (p_json, 'name');
        l_value := TO_NUMBER (get_json_value (p_json, 'value'));
        l_timestamp := get_json_value (p_json, 'timestamp');
        l_unit := get_json_value (p_json, 'unit');
        l_trace_id := get_json_value (p_json, 'trace_id');
        l_span_id := get_json_value (p_json, 'span_id');
        l_attributes := get_json_object (p_json, 'attributes');

        -- Validate
        IF l_metric_name IS NULL OR l_value IS NULL THEN
            log_error ('Invalid metric data', SUBSTR (p_json, 1, 500));
            RETURN;
        END IF;

        -- Initialize builder
        l_builder := init_large_string();

        -- Build OTLP metrics JSON
        append_to_large_string(l_builder, '{' || CHR(10));
        append_to_large_string(l_builder, '  "resourceMetrics": [{' || CHR(10));
        append_to_large_string(l_builder, '    "resource": {' || CHR(10));
        append_to_large_string(l_builder, '      "attributes": ' || generate_resource_attributes() || CHR(10));
        append_to_large_string(l_builder, '    },' || CHR(10));
        append_to_large_string(l_builder, '    "scopeMetrics": [{' || CHR(10));
        append_to_large_string(l_builder, '      "scope": {' || CHR(10));
        append_to_large_string(l_builder, '        "name": "PLTelemetry",' || CHR(10));
        append_to_large_string(l_builder, '        "version": "1.0.0"' || CHR(10));
        append_to_large_string(l_builder, '      },' || CHR(10));
        append_to_large_string(l_builder, '      "metrics": [{' || CHR(10));
        append_to_large_string(l_builder, '        "name": "' || escape_json_string(l_metric_name) || '",' || CHR(10));
        append_to_large_string(l_builder, '        "unit": "' || escape_json_string(NVL(l_unit, '1')) || '",' || CHR(10));
        append_to_large_string(l_builder, '        "gauge": {' || CHR(10));
        append_to_large_string(l_builder, '          "dataPoints": [{' || CHR(10));
        append_to_large_string(l_builder, '            "timeUnixNano": "' || 
                              to_unix_nano(NVL(l_timestamp, TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'))) || '",' || CHR(10));
        append_to_large_string(l_builder, '            "asDouble": ' || TO_CHAR(l_value, 'FM99999999999999999990.099999999'));

        -- Add attributes
        IF l_attributes IS NOT NULL THEN
            l_attr_clob := convert_attributes_to_otlp_enhanced(l_attributes);
            append_to_large_string(l_builder, ',' || CHR(10) || '            "attributes": ');
            append_clob_to_large_string(l_builder, l_attr_clob);
            DBMS_LOB.FREETEMPORARY(l_attr_clob);
        ELSE
            append_to_large_string(l_builder, ',' || CHR(10) || '            "attributes": []');
        END IF;

        -- Add trace context if available
        IF l_trace_id IS NOT NULL THEN
            append_to_large_string(l_builder, ',' || CHR(10) || '            "traceId": "' || l_trace_id || '"');
            IF l_span_id IS NOT NULL THEN
                append_to_large_string(l_builder, ',' || CHR(10) || '            "spanId": "' || l_span_id || '"');
            END IF;
        END IF;

        append_to_large_string(l_builder, CHR(10) || '          }]' || CHR(10));
        append_to_large_string(l_builder, '        }' || CHR(10));
        append_to_large_string(l_builder, '      }]' || CHR(10));
        append_to_large_string(l_builder, '    }]' || CHR(10));
        append_to_large_string(l_builder, '  }]' || CHR(10));
        append_to_large_string(l_builder, '}');

        -- Send to collector
        l_final_json := get_large_string_content(l_builder);
        send_to_endpoint_enhanced(g_metrics_endpoint, l_final_json);
        
        -- Cleanup
        cleanup_large_string(l_builder);
        IF DBMS_LOB.ISTEMPORARY(l_final_json) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_final_json);
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            cleanup_large_string(l_builder);
            IF l_final_json IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_final_json) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_final_json);
            END IF;
            log_error ('Error in send_metric_otlp: ' || SQLERRM, SUBSTR (p_json, 1, 500));
    END send_metric_otlp;

    /**
     * Enhanced log sender using hybrid string management
     */
    PROCEDURE send_log_otlp (p_json VARCHAR2)
    IS
        l_builder       t_large_string;
        l_final_json    CLOB;
        l_event_name    VARCHAR2 (255);
        l_timestamp     VARCHAR2 (50);
        l_severity      VARCHAR2 (20);
        l_message       VARCHAR2 (4000);
        l_trace_id      VARCHAR2 (32);
        l_span_id       VARCHAR2 (16);
        l_attributes    VARCHAR2 (4000);
        l_attr_clob     CLOB;
    BEGIN
    
        -- ===== DEBUG BLOCK =====
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('=== SEND_LOG_OTLP DEBUG ===');
            DBMS_OUTPUT.PUT_LINE('Input JSON: ' || p_json);
            DBMS_OUTPUT.PUT_LINE('Has severity: ' || CASE WHEN INSTR(p_json, '"severity"') > 0 THEN 'YES' ELSE 'NO' END);
            DBMS_OUTPUT.PUT_LINE('Has message: ' || CASE WHEN INSTR(p_json, '"message"') > 0 THEN 'YES' ELSE 'NO' END);
        END IF;
    
        -- Extract values including trace context
        l_event_name := get_json_value (p_json, 'event_name');
        l_timestamp := get_json_value (p_json, 'timestamp');
        l_severity := NVL (get_json_value (p_json, 'severity'), 'INFO');
        l_message := NVL (get_json_value (p_json, 'message'), p_json);
        l_trace_id := get_json_value (p_json, 'trace_id'); -- Added trace context
        l_span_id := get_json_value (p_json, 'span_id');   -- Added trace context
        l_attributes := get_json_object (p_json, 'attributes');

        -- Initialize builder
        l_builder := init_large_string();

        -- Build OTLP logs JSON
        append_to_large_string(l_builder, '{' || CHR(10));
        append_to_large_string(l_builder, '  "resourceLogs": [{' || CHR(10));
        append_to_large_string(l_builder, '    "resource": {' || CHR(10));
        append_to_large_string(l_builder, '      "attributes": ' || generate_resource_attributes() || CHR(10));
        append_to_large_string(l_builder, '    },' || CHR(10));
        append_to_large_string(l_builder, '    "scopeLogs": [{' || CHR(10));
        append_to_large_string(l_builder, '      "scope": {' || CHR(10));
        append_to_large_string(l_builder, '        "name": "PLTelemetry",' || CHR(10));
        append_to_large_string(l_builder, '        "version": "1.0.0"' || CHR(10));
        append_to_large_string(l_builder, '      },' || CHR(10));
        append_to_large_string(l_builder, '      "logRecords": [{' || CHR(10));
        append_to_large_string(l_builder, '        "timeUnixNano": "' || 
                              to_unix_nano(NVL(l_timestamp, TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'))) || '",' || CHR(10));
        append_to_large_string(l_builder, '        "severityNumber": ' || 
                              CASE UPPER(l_severity)
                                  WHEN 'TRACE' THEN '1'
                                  WHEN 'DEBUG' THEN '5'
                                  WHEN 'INFO' THEN '9'
                                  WHEN 'WARN' THEN '13'
                                  WHEN 'ERROR' THEN '17'
                                  WHEN 'FATAL' THEN '21'
                                  ELSE '9'
                              END || ',' || CHR(10));
        append_to_large_string(l_builder, '        "severityText": "' || UPPER(l_severity) || '",' || CHR(10));
        append_to_large_string(l_builder, '        "body": {' || CHR(10));
        append_to_large_string(l_builder, '          "stringValue": "' || escape_json_string(SUBSTR(l_message, 1, 4000)) || '"' || CHR(10));
        append_to_large_string(l_builder, '        }');

        -- Add trace context if available
        IF l_trace_id IS NOT NULL THEN
            append_to_large_string(l_builder, ',' || CHR(10) || '        "traceId": "' || l_trace_id || '"');
            IF l_span_id IS NOT NULL THEN
                append_to_large_string(l_builder, ',' || CHR(10) || '        "spanId": "' || l_span_id || '"');
            END IF;
        END IF;

        -- Add event name and other attributes
        IF l_event_name IS NOT NULL OR l_attributes IS NOT NULL THEN
            append_to_large_string(l_builder, ',' || CHR(10) || '        "attributes": [');
            
            -- Add event name as attribute if present
            IF l_event_name IS NOT NULL THEN
                append_to_large_string(l_builder, '{' || CHR(10));
                append_to_large_string(l_builder, '          "key": "event.name",' || CHR(10));
                append_to_large_string(l_builder, '          "value": {"stringValue": "' || escape_json_string(l_event_name) || '"}' || CHR(10));
                append_to_large_string(l_builder, '        }');
                
                -- Add comma if we have more attributes
                IF l_attributes IS NOT NULL THEN
                    append_to_large_string(l_builder, ',');
                END IF;
            END IF;
            
            -- Add other attributes if present
            IF l_attributes IS NOT NULL THEN
                l_attr_clob := convert_attributes_to_otlp_enhanced(l_attributes);
                -- Remove the outer brackets from attributes and add the content
                DECLARE
                    l_attr_content VARCHAR2(32767);
                    l_attr_size NUMBER;
                    l_read_amount NUMBER;
                BEGIN
                    l_attr_size := DBMS_LOB.GETLENGTH(l_attr_clob);
                    IF l_attr_size > 2 THEN -- More than just "[]"
                        l_read_amount := l_attr_size - 2;
                        DBMS_LOB.READ(l_attr_clob, l_read_amount, 2, l_attr_content);
                        append_to_large_string(l_builder, l_attr_content);
                    END IF;
                END;
                DBMS_LOB.FREETEMPORARY(l_attr_clob);
            END IF;
            
            append_to_large_string(l_builder, ']');
        END IF;

        append_to_large_string(l_builder, CHR(10) || '      }]' || CHR(10));
        append_to_large_string(l_builder, '    }]' || CHR(10));
        append_to_large_string(l_builder, '  }]' || CHR(10));
        append_to_large_string(l_builder, '}');

        -- Send to collector
        l_final_json := get_large_string_content(l_builder);
        send_to_endpoint_enhanced(g_logs_endpoint, l_final_json);
        
        -- Cleanup
        cleanup_large_string(l_builder);
        IF DBMS_LOB.ISTEMPORARY(l_final_json) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_final_json);
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            cleanup_large_string(l_builder);
            IF l_final_json IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_final_json) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_final_json);
            END IF;
            log_error ('Error in send_log_otlp: ' || SQLERRM, SUBSTR (p_json, 1, 500));
    END send_log_otlp;

    --------------------------------------------------------------------------
    -- MAIN ROUTING
    --------------------------------------------------------------------------

    /**
     * Main router
     */
    PROCEDURE route_to_otlp (p_json VARCHAR2)
    IS
    BEGIN
    
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('JSON length: ' || LENGTH(p_json));
            DBMS_OUTPUT.PUT_LINE('Contains events: ' || CASE WHEN INSTR(p_json, '"events"') > 0 THEN 'YES' ELSE 'NO' END);
            IF LENGTH(p_json) > 200 THEN
                DBMS_OUTPUT.PUT_LINE('JSON start: ' || SUBSTR(p_json, 1, 200));
                DBMS_OUTPUT.PUT_LINE('JSON end: ' || SUBSTR(p_json, LENGTH(p_json)-200, 200));
            ELSE
                DBMS_OUTPUT.PUT_LINE('JSON full: ' || p_json);
            END IF;
        END IF;
    
        IF p_json IS NULL THEN
            RETURN;
        END IF;

        -- Route based on content
        -- Logs PRIMERO, antes que spans
        IF INSTR (p_json, '"name"') > 0 AND INSTR (p_json, '"value"') > 0 THEN
            send_metric_otlp (p_json);
        ELSIF INSTR(p_json, '"severity"') > 0 AND INSTR(p_json, '"message"') > 0 THEN
            send_log_otlp(p_json);
        ELSIF INSTR (p_json, '"span_id"') > 0 THEN
            send_trace_otlp (p_json);
        ELSE
            send_log_otlp (p_json);
        END IF;
        
    END route_to_otlp;

    --------------------------------------------------------------------------
    -- CONFIGURATION PROCEDURES (enhanced)
    --------------------------------------------------------------------------

    /**
     * Set collector endpoints in batch
     */
    PROCEDURE set_otlp_collector (p_base_url VARCHAR2)
    IS
    BEGIN
        g_traces_endpoint := p_base_url || '/v1/traces';
        g_metrics_endpoint := p_base_url || '/v1/metrics';
        g_logs_endpoint := p_base_url || '/v1/logs';
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('OTLP Collector configured:');
            DBMS_OUTPUT.PUT_LINE('  Traces: ' || g_traces_endpoint);
            DBMS_OUTPUT.PUT_LINE('  Metrics: ' || g_metrics_endpoint);
            DBMS_OUTPUT.PUT_LINE('  Logs: ' || g_logs_endpoint);
        END IF;
    END set_otlp_collector;

    /**
     * Set individual endpoints (new feature)
     */
    PROCEDURE set_traces_endpoint (p_url VARCHAR2)
    IS
    BEGIN
        g_traces_endpoint := p_url;
    END set_traces_endpoint;

    PROCEDURE set_metrics_endpoint (p_url VARCHAR2)
    IS
    BEGIN
        g_metrics_endpoint := p_url;
    END set_metrics_endpoint;

    PROCEDURE set_logs_endpoint (p_url VARCHAR2)
    IS
    BEGIN
        g_logs_endpoint := p_url;
    END set_logs_endpoint;

    PROCEDURE set_service_info (p_service_name VARCHAR2, p_service_version VARCHAR2 DEFAULT NULL, p_tenant_id VARCHAR2 DEFAULT NULL)
    IS
    BEGIN
        g_service_name := NVL (p_service_name, 'oracle-plsql');

        IF p_service_version IS NOT NULL THEN
            g_service_version := p_service_version;
        END IF;

        g_tenant_id := p_tenant_id;
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('Service info updated:');
            DBMS_OUTPUT.PUT_LINE('  Name: ' || g_service_name);
            DBMS_OUTPUT.PUT_LINE('  Version: ' || g_service_version);
            DBMS_OUTPUT.PUT_LINE('  Tenant: ' || NVL(g_tenant_id, 'not set'));
        END IF;
    END set_service_info;

    PROCEDURE set_timeout (p_timeout NUMBER)
    IS
    BEGIN
        g_timeout := NVL (p_timeout, 30);
    END set_timeout;

    PROCEDURE set_debug_mode (p_enabled BOOLEAN)
    IS
    BEGIN
        g_debug_mode := NVL (p_enabled, FALSE);
        DBMS_OUTPUT.PUT_LINE('OTLP Bridge debug mode: ' || CASE WHEN g_debug_mode THEN 'ENABLED' ELSE 'DISABLED' END);
    END set_debug_mode;

    /**
     * NEW: Set JSON parsing mode
     */
    PROCEDURE set_native_json_mode (p_enabled BOOLEAN)
    IS
    BEGIN
        g_use_native_json := NVL (p_enabled, FALSE);
        
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE('JSON parsing mode: ' || CASE WHEN g_use_native_json THEN 'NATIVE (Oracle 12c+)' ELSE 'LEGACY (Compatible)' END);
        END IF;
    END set_native_json_mode;

    /**
     * NEW: Get current JSON parsing mode
     */
    FUNCTION get_native_json_mode
    RETURN BOOLEAN
    IS
    BEGIN
        RETURN g_use_native_json;
    END get_native_json_mode;

END PLT_OTLP_BRIDGE;
/