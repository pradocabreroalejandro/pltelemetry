CREATE OR REPLACE PACKAGE PLT_OTLP_BRIDGE
AS
    /**
     * PLT_OTLP_BRIDGE - OpenTelemetry Protocol Exporter for PLTelemetry
     *
     * Converts PLTelemetry JSON to OTLP format and sends to any OTEL Collector
     * Version: 0.0.1
     *
     */

    -- Configuration
    g_traces_endpoint    VARCHAR2 (500) := 'http://localhost:4318/v1/traces';
    g_metrics_endpoint   VARCHAR2 (500) := 'http://localhost:4318/v1/metrics';
    g_logs_endpoint      VARCHAR2 (500) := 'http://localhost:4318/v1/logs';
    g_timeout            NUMBER := 30;

    -- Service identification
    g_service_name       VARCHAR2 (100) := 'oracle-plsql';
    g_service_version    VARCHAR2 (50) := '1.0.0';
    g_service_instance   VARCHAR2 (200);
    g_tenant_id          VARCHAR2 (100);

    -- Debug mode
    g_debug_mode         BOOLEAN := FALSE;

    --------------------------------------------------------------------------
    -- PUBLIC PROCEDURES
    --------------------------------------------------------------------------

    /**
     * Main router - called by PLTelemetry when backend_url = 'OTLP_BRIDGE'
     */
    PROCEDURE route_to_otlp (p_json VARCHAR2);

    /**
     * Configuration procedures
     */
    PROCEDURE set_otlp_collector (p_base_url VARCHAR2);

    PROCEDURE set_service_info (p_service_name VARCHAR2, p_service_version VARCHAR2 DEFAULT NULL, p_tenant_id VARCHAR2 DEFAULT NULL);

    PROCEDURE set_timeout (p_timeout NUMBER);

    PROCEDURE set_debug_mode (p_enabled BOOLEAN);

    FUNCTION convert_attributes_legacy (p_attrs_json VARCHAR2)
        RETURN CLOB;

    FUNCTION convert_attributes_to_otlp_enhanced (p_attrs_json VARCHAR2)
        RETURN CLOB;

    /**
     * Direct send procedures (for testing)
     */
    PROCEDURE send_trace_otlp (p_json VARCHAR2);

    PROCEDURE send_metric_otlp (p_json VARCHAR2);

    PROCEDURE send_log_otlp (p_json VARCHAR2);

    FUNCTION to_unix_nano (p_timestamp VARCHAR2)
        RETURN VARCHAR2;
END PLT_OTLP_BRIDGE;
/