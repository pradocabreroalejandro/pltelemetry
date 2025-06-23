CREATE OR REPLACE PACKAGE PLT_POSTGRES_BRIDGE
AS
    /**
     * PLT_POSTGRES_BRIDGE - PostgreSQL/PostgREST Adapter for PLTelemetry
     *
     * This package provides PostgreSQL-specific implementations for PLTelemetry,
     * transforming generic telemetry data into PostgREST-compatible format.
     *
     * Version: 1.0
     * Dependencies: PLTelemetry, UTL_HTTP
     */

    --------------------------------------------------------------------------
    -- CONFIGURATION
    --------------------------------------------------------------------------

    -- PostgREST endpoints
    g_postgrest_base_url   VARCHAR2 (500) := 'http://localhost:3000';
    g_api_key              VARCHAR2 (100) := 'your-api-key';
    g_timeout              NUMBER := 30;

    --------------------------------------------------------------------------
    -- MAIN PROCEDURES
    --------------------------------------------------------------------------

    /**
     * Sends trace data to PostgreSQL via PostgREST
     * Transforms generic PLTelemetry format to PostgreSQL-specific format
     *
     * @param p_trace_id The trace ID
     * @param p_operation Root operation name
     * @param p_start_time Trace start timestamp
     * @param p_service_name Service name (default: 'oracle-plsql')
     */
    PROCEDURE send_trace_to_postgres (p_trace_id        VARCHAR2,
                                      p_operation       VARCHAR2,
                                      p_start_time      TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP,
                                      p_service_name    VARCHAR2 DEFAULT 'oracle-plsql');

    /**
     * Sends span data to PostgreSQL via PostgREST
     * Transforms from generic format to PostgreSQL-specific
     *
     * @param p_generic_json Generic span JSON from PLTelemetry
     */
    PROCEDURE send_span_to_postgres (p_generic_json VARCHAR2);

    /**
     * Sends metric data to PostgreSQL via PostgREST
     * Transforms from generic format to PostgreSQL-specific
     *
     * @param p_generic_json Generic metric JSON from PLTelemetry
     */
    PROCEDURE send_metric_to_postgres (p_generic_json VARCHAR2);

    /**
     * Interceptor for PLTelemetry.send_to_backend
     * Routes telemetry data to appropriate PostgreSQL endpoint
     *
     * @param p_json Generic JSON from PLTelemetry
     */
    PROCEDURE route_to_postgres (p_json VARCHAR2);

    /**
     * Enhanced start_trace that sends to both Oracle and PostgreSQL
     * Use this instead of PLTelemetry.start_trace for PostgreSQL integration
     *
     * @param p_operation The operation name
     * @return The generated trace ID
     */
    FUNCTION start_trace_with_postgres (p_operation VARCHAR2)
        RETURN VARCHAR2;

    /**
     * Main routing procedure to intercept PLTelemetry backend calls
     * This should replace PLTelemetry.send_to_backend when using PostgreSQL
     *
     * @param p_json JSON payload from PLTelemetry
     */
    PROCEDURE send_to_backend_with_routing (p_json VARCHAR2);

    --------------------------------------------------------------------------
    -- CONFIGURATION PROCEDURES
    --------------------------------------------------------------------------

    PROCEDURE set_postgrest_url (p_url VARCHAR2);

    PROCEDURE set_api_key (p_key VARCHAR2);

    PROCEDURE set_timeout (p_timeout NUMBER);

    FUNCTION escape_json_string (p_input VARCHAR2)
        RETURN VARCHAR2;
END PLT_POSTGRES_BRIDGE;
/