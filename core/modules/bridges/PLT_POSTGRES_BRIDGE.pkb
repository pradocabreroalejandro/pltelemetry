CREATE OR REPLACE PACKAGE BODY PLT_POSTGRES_BRIDGE
AS
   --------------------------------------------------------------------------
   -- PRIVATE HELPERS
   --------------------------------------------------------------------------
   
   /**
    * Escapa caracteres especiales para JSON válido
    */
   FUNCTION escape_json_string(p_input VARCHAR2)
   RETURN VARCHAR2
   IS
       l_output VARCHAR2(4000);
   BEGIN
       IF p_input IS NULL THEN
           RETURN NULL;
       END IF;
       
       l_output := p_input;
       
       -- Importante: escapar backslash PRIMERO
       l_output := REPLACE(l_output, '\', '\\');
       l_output := REPLACE(l_output, '"', '\"');
       l_output := REPLACE(l_output, CHR(10), '\n');
       l_output := REPLACE(l_output, CHR(13), '\r');
       l_output := REPLACE(l_output, CHR(9), '\t');
       l_output := REPLACE(l_output, CHR(8), '\b');
       l_output := REPLACE(l_output, CHR(12), '\f');
       
       RETURN l_output;
   END escape_json_string;
   
   /**
    * Extracts field value from JSON string
    */
   FUNCTION get_json_value (p_json VARCHAR2, p_field VARCHAR2)
       RETURN VARCHAR2
   IS
       l_pattern   VARCHAR2(200);
       l_value     VARCHAR2(4000);
   BEGIN
       -- Pattern for quoted values
       l_pattern := '"' || p_field || '"\s*:\s*"([^"]+)"';
       l_value := REGEXP_SUBSTR(p_json, l_pattern, 1, 1, NULL, 1);
       
       IF l_value IS NOT NULL THEN
           RETURN l_value;
       END IF;
       
       -- Pattern for numeric values
       l_pattern := '"' || p_field || '"\s*:\s*([0-9.]+)';
       l_value := REGEXP_SUBSTR(p_json, l_pattern, 1, 1, NULL, 1);
       
       RETURN l_value;
   END get_json_value;

   /**
    * Sends HTTP POST request to PostgREST endpoint
    */
   PROCEDURE send_http_post (p_endpoint VARCHAR2, p_json VARCHAR2)
   IS
       l_req    UTL_HTTP.REQ;
       l_res    UTL_HTTP.RESP;
       l_url    VARCHAR2(600);
       l_response VARCHAR2(32767);
       l_buffer   VARCHAR2(32767);
   BEGIN
       l_url := g_postgrest_base_url || p_endpoint;
       
       UTL_HTTP.SET_TRANSFER_TIMEOUT(g_timeout);
       
       l_req := UTL_HTTP.BEGIN_REQUEST(l_url, 'POST', 'HTTP/1.1');
       UTL_HTTP.SET_HEADER(l_req, 'Content-Type', 'application/json; charset=utf-8');
       UTL_HTTP.SET_HEADER(l_req, 'Content-Length', LENGTHB(p_json));
       
       -- Solo agregar API key si está configurada
       IF g_api_key IS NOT NULL THEN
           UTL_HTTP.SET_HEADER(l_req, 'X-API-Key', g_api_key);
       END IF;
       
       UTL_HTTP.WRITE_TEXT(l_req, p_json);
       
       l_res := UTL_HTTP.GET_RESPONSE(l_req);
       
       IF l_res.status_code NOT IN (200, 201, 202, 204) THEN
           -- Capturar respuesta de error
           BEGIN
               LOOP
                   UTL_HTTP.READ_TEXT(l_res, l_buffer, 32767);
                   l_response := l_response || l_buffer;
               END LOOP;
           EXCEPTION
               WHEN UTL_HTTP.END_OF_BODY THEN
                   NULL;
           END;
           
           -- Log error detallado
           INSERT INTO plt_telemetry_errors (
               error_time, 
               error_message, 
               module_name
           ) VALUES (
               SYSTIMESTAMP,
               'PostgreSQL bridge HTTP ' || l_res.status_code || 
               ' for ' || p_endpoint || 
               '. Response: ' || SUBSTR(l_response, 1, 3000),
               'PLT_POSTGRES_BRIDGE'
           );
           
           IF PLTelemetry.get_autocommit THEN
               COMMIT;
           END IF;
       END IF;
       
       UTL_HTTP.END_RESPONSE(l_res);
       
   EXCEPTION
       WHEN OTHERS THEN
           BEGIN
               IF l_res.status_code IS NOT NULL THEN
                   UTL_HTTP.END_RESPONSE(l_res);
               END IF;
           EXCEPTION
               WHEN OTHERS THEN NULL;
           END;
           
           -- Log but don't propagate
           INSERT INTO plt_telemetry_errors (
               error_time, 
               error_message, 
               module_name
           ) VALUES (
               SYSTIMESTAMP,
               'PostgreSQL bridge error: ' || SUBSTR(DBMS_UTILITY.format_error_stack|| ' - '|| DBMS_UTILITY.format_error_backtrace, 1, 3000),
               'PLT_POSTGRES_BRIDGE.send_http_post'
           );
           
           IF PLTelemetry.get_autocommit THEN
               COMMIT;
           END IF;
   END send_http_post;

   --------------------------------------------------------------------------
   -- PUBLIC PROCEDURES
   --------------------------------------------------------------------------
   
   PROCEDURE send_trace_to_postgres (
       p_trace_id       VARCHAR2,
       p_operation      VARCHAR2,
       p_start_time     TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP,
       p_service_name   VARCHAR2 DEFAULT 'oracle-plsql'
   )
   IS
       l_json VARCHAR2(4000);
       l_service_instance VARCHAR2(500);
   BEGIN
       -- Construir y escapar service_instance
       l_service_instance := escape_json_string(
           SYS_CONTEXT('USERENV', 'HOST') || ':' || 
           SYS_CONTEXT('USERENV', 'INSTANCE_NAME')
       );
       
       -- Build PostgreSQL-specific JSON con escape
       l_json := '{'
           || '"trace_id":"' || p_trace_id || '",'
           || '"root_operation":"' || escape_json_string(p_operation) || '",'
           || '"start_time":"' || TO_CHAR(p_start_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'
           || '"service_name":"' || escape_json_string(p_service_name) || '",'
           || '"service_instance":"' || l_service_instance || '"'
           || '}';
       
       send_http_post('/traces', l_json);
   END send_trace_to_postgres;

   PROCEDURE send_span_to_postgres (p_generic_json VARCHAR2)
   IS
       l_json           VARCHAR2(32767);
       l_operation      VARCHAR2(255);
   BEGIN
       -- Extract values from generic JSON
       l_operation := get_json_value(p_generic_json, 'operation');
       
       -- Transform to PostgreSQL format con escape
       l_json := '{'
           || '"trace_id":"' || get_json_value(p_generic_json, 'trace_id') || '",'
           || '"span_id":"' || get_json_value(p_generic_json, 'span_id') || '",'
           || '"operation_name":"' || escape_json_string(l_operation) || '",'
           || '"start_time":"' || get_json_value(p_generic_json, 'start_time') || '",'
           || '"end_time":"' || get_json_value(p_generic_json, 'end_time') || '",'
           || '"duration_ms":' || NVL(get_json_value(p_generic_json, 'duration_ms'), '0') || ','
           || '"status":"' || get_json_value(p_generic_json, 'status') || '"'
           || '}';
       
       send_http_post('/spans', l_json);
   END send_span_to_postgres;

   PROCEDURE send_metric_to_postgres (p_generic_json VARCHAR2)
   IS
       l_json   VARCHAR2(32767);
   BEGIN
       -- Transform from generic to PostgreSQL format con escape
       l_json := '{'
           || '"metric_name":"' || escape_json_string(get_json_value(p_generic_json, 'name')) || '",'
           || '"metric_value":' || get_json_value(p_generic_json, 'value') || ','
           || '"metric_unit":"' || escape_json_string(get_json_value(p_generic_json, 'unit')) || '",'
           || '"timestamp":"' || get_json_value(p_generic_json, 'timestamp') || '",'
           || '"trace_id":"' || get_json_value(p_generic_json, 'trace_id') || '",'
           || '"span_id":"' || get_json_value(p_generic_json, 'span_id') || '"'
           || '}';
       
       send_http_post('/metrics', l_json);
   END send_metric_to_postgres;

   -- Resto de procedimientos sin cambios...
   
   PROCEDURE route_to_postgres (p_json VARCHAR2)
   IS
       l_trace_id   VARCHAR2(32);
       l_span_id    VARCHAR2(16);
       l_name       VARCHAR2(255);
   BEGIN
       l_trace_id := get_json_value(p_json, 'trace_id');
       l_span_id := get_json_value(p_json, 'span_id');
       l_name := get_json_value(p_json, 'name');
       
       IF l_name IS NOT NULL THEN
           send_metric_to_postgres(p_json);
       ELSIF l_span_id IS NOT NULL AND get_json_value(p_json, 'duration_ms') IS NOT NULL THEN
           send_span_to_postgres(p_json);
       ELSIF l_trace_id IS NOT NULL AND get_json_value(p_json, 'root_operation') IS NOT NULL THEN
           send_http_post('/traces', p_json);
       END IF;
   END route_to_postgres;

   FUNCTION start_trace_with_postgres (p_operation VARCHAR2)
       RETURN VARCHAR2
   IS
       l_trace_id VARCHAR2(32);
   BEGIN
       l_trace_id := PLTelemetry.start_trace(p_operation);
       
       send_trace_to_postgres(
           p_trace_id => l_trace_id,
           p_operation => p_operation,
           p_start_time => SYSTIMESTAMP,
           p_service_name => 'oracle-plsql'
       );
       
       RETURN l_trace_id;
   EXCEPTION
       WHEN OTHERS THEN
           RETURN l_trace_id;
   END start_trace_with_postgres;

   PROCEDURE send_to_backend_with_routing (p_json VARCHAR2)
   IS
   BEGIN
       IF PLTelemetry.get_backend_url() = 'POSTGRES_BRIDGE' THEN
           route_to_postgres(p_json);
       ELSE
           PLTelemetry.send_to_backend(p_json);
       END IF;
   END send_to_backend_with_routing;

   PROCEDURE set_postgrest_url (p_url VARCHAR2)
   IS
   BEGIN
       g_postgrest_base_url := p_url;
   END;

   PROCEDURE set_api_key (p_key VARCHAR2)
   IS
   BEGIN
       g_api_key := p_key;
   END;

   PROCEDURE set_timeout (p_timeout NUMBER)
   IS
   BEGIN
       g_timeout := p_timeout;
   END;

END PLT_POSTGRES_BRIDGE;