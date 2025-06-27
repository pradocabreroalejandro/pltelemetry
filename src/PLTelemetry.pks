CREATE OR REPLACE PACKAGE PLTelemetry
AS
    -- OpenTelemetry SDK for PL/SQL
    -- Version: 0.1
    -- Description: Provides distributed tracing capabilities for PL/SQL applications
    --              following OpenTelemetry standards

    --------------------------------------------------------------------------
    -- TYPE DEFINITIONS
    --------------------------------------------------------------------------

    -- Collection type for storing key-value attributes
    -- Each attribute should be in format 'key=value'
    TYPE t_attributes IS TABLE OF VARCHAR2 (4000)
        INDEX BY BINARY_INTEGER;

    --------------------------------------------------------------------------
    -- CONSTANTS
    --------------------------------------------------------------------------

    -- Standard OpenTelemetry semantic conventions for HTTP
    C_ATTR_HTTP_METHOD     CONSTANT VARCHAR2 (30) := 'http.method';
    C_ATTR_HTTP_URL        CONSTANT VARCHAR2 (30) := 'http.url';
    C_ATTR_HTTP_STATUS     CONSTANT VARCHAR2 (30) := 'http.status_code';

    -- Standard OpenTelemetry semantic conventions for database
    C_ATTR_DB_OPERATION    CONSTANT VARCHAR2 (30) := 'db.operation';
    C_ATTR_DB_STATEMENT    CONSTANT VARCHAR2 (30) := 'db.statement';

    -- Standard OpenTelemetry semantic conventions for user
    C_ATTR_USER_ID         CONSTANT VARCHAR2 (30) := 'user.id';
    C_ATTR_ERROR_MESSAGE   CONSTANT VARCHAR2 (30) := 'error.message';

    -- Span kind constants following OpenTelemetry specification
    C_SPAN_KIND_INTERNAL   CONSTANT VARCHAR2 (10) := 'INTERNAL';
    C_SPAN_KIND_SERVER     CONSTANT VARCHAR2 (10) := 'SERVER';
    C_SPAN_KIND_CLIENT     CONSTANT VARCHAR2 (10) := 'CLIENT';
    C_SPAN_KIND_PRODUCER   CONSTANT VARCHAR2 (10) := 'PRODUCER';
    C_SPAN_KIND_CONSUMER   CONSTANT VARCHAR2 (10) := 'CONSUMER';

    --------------------------------------------------------------------------
    -- GLOBAL VARIABLES
    --------------------------------------------------------------------------

    -- Current trace context
    g_current_trace_id              VARCHAR2 (32);
    g_current_span_id               VARCHAR2 (16);

    -- Configuration parameters
    g_autocommit                    BOOLEAN := FALSE;                                                                  -- Control auto-commit behavior
    g_backend_url                   VARCHAR2 (500) := 'http://your-backend:3000/plsql-otel/telemetry';
    g_backend_timeout               NUMBER := 30;                                                                                -- Timeout in seconds
    g_api_key                       VARCHAR2 (100) := 'your-secret-api-key';                                             -- API key for authentication
    g_async_mode                    BOOLEAN := TRUE;                                                                        -- Enable async by default

    --------------------------------------------------------------------------
    -- CORE TRACING FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Starts a new trace with the given operation name
     *
     * @param p_operation The name of the operation being traced
     * @return The generated trace ID (32 character hex string)
     * @example
     *   l_trace_id := PLTelemetry.start_trace('process_order');
     */
    FUNCTION start_trace (p_operation VARCHAR2)
        RETURN VARCHAR2;

    /**
      * Ends the current trace and clears context
      *
      * @param p_trace_id Optional trace ID to end (uses current if not provided)
      */
    PROCEDURE end_trace (p_trace_id VARCHAR2 DEFAULT NULL);

    /**
     * Starts a new span within a trace
     *
     * @param p_operation The name of the operation for this span
     * @param p_parent_span_id Optional parent span ID for nested spans
     * @param p_trace_id Optional trace ID (uses current if not provided)
     * @return The generated span ID (16 character hex string)
     * @example
     *   l_span_id := PLTelemetry.start_span('validate_customer');
     */
    FUNCTION start_span (p_operation VARCHAR2, p_parent_span_id VARCHAR2 DEFAULT NULL, p_trace_id VARCHAR2 DEFAULT NULL)
        RETURN VARCHAR2;

    /**
     * Ends an active span and records its duration
     *
     * @param p_span_id The ID of the span to end
     * @param p_status The final status of the span (OK, ERROR, etc.)
     * @param p_attributes Additional attributes to attach to the span
     * @example
     *   PLTelemetry.end_span(l_span_id, 'OK');
     */
    PROCEDURE end_span (p_span_id VARCHAR2, p_status VARCHAR2 DEFAULT 'OK', p_attributes t_attributes DEFAULT t_attributes ());

    /**
     * Adds an event to an active span
     *
     * @param p_span_id The ID of the span to add the event to
     * @param p_event_name The name of the event
     * @param p_attributes Optional attributes for the event
     * @example
     *   PLTelemetry.add_event(l_span_id, 'payment_processed');
     */
    PROCEDURE add_event (p_span_id VARCHAR2, p_event_name VARCHAR2, p_attributes t_attributes DEFAULT t_attributes ());

    /**
     * Records a metric value with associated metadata
     *
     * @param p_metric_name The name of the metric
     * @param p_value The numeric value of the metric
     * @param p_unit Optional unit of measurement
     * @param p_attributes Optional attributes for the metric
     * @example
     *   PLTelemetry.log_metric('order_total', 299.99, 'USD');
     */
    PROCEDURE log_metric (p_metric_name    VARCHAR2,
                          p_value          NUMBER,
                          p_unit           VARCHAR2 DEFAULT NULL,
                          p_attributes     t_attributes DEFAULT t_attributes ());

    --------------------------------------------------------------------------
    -- UTILITY FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Creates a key-value attribute string with proper escaping
     *
     * @param p_key The attribute key
     * @param p_value The attribute value
     * @return Escaped key=value string
     * @example
     *   l_attr := PLTelemetry.add_attribute('user.id', '12345');
     */
    FUNCTION add_attribute (p_key VARCHAR2, p_value VARCHAR2)
        RETURN VARCHAR2;

    /**
     * Converts an attributes collection to JSON format
     *
     * @param p_attributes Collection of key=value attributes
     * @return JSON string representation of attributes
     * @example
     *   l_json := PLTelemetry.attributes_to_json(l_attributes);
     */
    FUNCTION attributes_to_json (p_attributes t_attributes)
        RETURN VARCHAR2;

    /**
     * Sends telemetry data to the configured backend
     *
     * @param p_json JSON payload to send
     * @note Uses async mode by default, falls back to sync on failure
     */
    PROCEDURE send_to_backend (p_json VARCHAR2);

    /**
     * Sets the current trace context in Oracle session info
     *
     * @note Uses DBMS_APPLICATION_INFO for visibility in V$SESSION
     */
    PROCEDURE set_trace_context;

    /**
     * Clears the current trace context from session
     */
    PROCEDURE clear_trace_context;

    /**
     * Processes queued telemetry data in batches
     *
     * @param p_batch_size Number of queue entries to process (default 100)
     * @note Should be called periodically by a scheduled job
     * @example
     *   PLTelemetry.process_queue(500);
     */
    PROCEDURE process_queue (p_batch_size NUMBER DEFAULT 100);

    --------------------------------------------------------------------------
    -- CONFIGURATION GETTERS AND SETTERS
    --------------------------------------------------------------------------

    /**
     * Sets the auto-commit mode for telemetry operations
     *
     * @param p_value TRUE to enable auto-commit, FALSE to disable
     */
    PROCEDURE set_autocommit (p_value BOOLEAN);

    /**
     * Gets the current auto-commit mode setting
     *
     * @return Current auto-commit setting
     */
    FUNCTION get_autocommit
        RETURN BOOLEAN;

    /**
     * Sets the backend URL for telemetry export
     *
     * @param p_url The HTTP endpoint URL
     */
    PROCEDURE set_backend_url (p_url VARCHAR2);

    /**
     * Gets the current backend URL
     *
     * @return Current backend URL
     */
    FUNCTION get_backend_url
        RETURN VARCHAR2;

    /**
     * Sets the API key for backend authentication
     *
     * @param p_key The API key string
     */
    PROCEDURE set_api_key (p_key VARCHAR2);

    /**
     * Sets the HTTP timeout for backend calls
     *
     * @param p_timeout Timeout in seconds
     */
    PROCEDURE set_backend_timeout (p_timeout NUMBER);

    /**
     * Sets the async processing mode
     *
     * @param p_async TRUE for async mode, FALSE for synchronous
     */
    PROCEDURE set_async_mode (p_async BOOLEAN);

    /**
     * Gets the current trace ID
     *
     * @return Current trace ID or NULL if no active trace
     */
    FUNCTION get_current_trace_id
        RETURN VARCHAR2;

    /**
     * Gets the current span ID
     *
     * @return Current span ID or NULL if no active span
     */
    FUNCTION get_current_span_id
        RETURN VARCHAR2;

    /**
     * Logs with explicit trace context (cross-system correlation)
     * Use when you receive trace_id from external systems (Angular, etc.)
     *
     * @param p_trace_id The trace ID from external system
     * @param p_level Log level (DEBUG, INFO, WARN, ERROR, FATAL)
     * @param p_message Log message content
     * @param p_attributes Optional attributes for the log
     */
    PROCEDURE log_with_trace (p_trace_id      VARCHAR2,
                              p_level         VARCHAR2,
                              p_message       VARCHAR2,
                              p_attributes    t_attributes DEFAULT t_attributes ());

    /**
     * Logs attached to an active span (span-contextual logging)
     * Use when you're inside a span and want logs correlated to that span
     *
     * @param p_span_id The active span ID
     * @param p_level Log level (DEBUG, INFO, WARN, ERROR, FATAL)
     * @param p_message Log message content
     * @param p_attributes Optional attributes for the log
     */
    PROCEDURE add_log (p_span_id       VARCHAR2,
                       p_level         VARCHAR2,
                       p_message       VARCHAR2,
                       p_attributes    t_attributes DEFAULT t_attributes ());

    /**
     * Standalone logs without trace context (general purpose logging)
     * Use for background jobs, startup messages, or general application logs
     *
     * @param p_level Log level (DEBUG, INFO, WARN, ERROR, FATAL)
     * @param p_message Log message content
     * @param p_attributes Optional attributes for the log
     */
    PROCEDURE log_message (p_level VARCHAR2, p_message VARCHAR2, p_attributes t_attributes DEFAULT t_attributes ());
    
         /**
     * Continue an existing trace from an external system
     * Use this when receiving a trace_id from Forms or other systems
     *
     * @param p_trace_id The trace ID from the external system (Forms, etc.)
     * @param p_operation The operation name for this part of the trace
     * @param p_tenant_id Optional tenant identifier for multi-tenancy
     * @return The span ID for this operation
     * @example
     *   l_span_id := PLTelemetry.continue_distributed_trace('abc123...', 'process_order_db', 'tenant_001');
     */
    FUNCTION continue_distributed_trace(
        p_trace_id   VARCHAR2,
        p_operation  VARCHAR2,
        p_tenant_id  VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2;

    /**
     * Get trace context for passing to external systems
     * Returns JSON with trace_id, span_id, and tenant info
     *
     * @return JSON string with trace context
     * @example
     *   l_context := PLTelemetry.get_trace_context();
     *   -- Returns: {"trace_id":"abc123...", "span_id":"def456...", "tenant_id":"tenant_001"}
     */
    FUNCTION get_trace_context
    RETURN VARCHAR2;

    /**
     * Log with distributed trace context
     * Use this for logging that should be correlated across systems
     *
     * @param p_trace_id The distributed trace ID
     * @param p_level Log level
     * @param p_message Log message
     * @param p_system Source system identifier (Forms, PLSQL, etc.)
     * @param p_tenant_id Optional tenant identifier
     */
    PROCEDURE log_distributed(
        p_trace_id   VARCHAR2,
        p_level      VARCHAR2,
        p_message    VARCHAR2,
        p_system     VARCHAR2 DEFAULT 'PLSQL',
        p_tenant_id  VARCHAR2 DEFAULT NULL
    );
    
END PLTelemetry;
/