CREATE OR REPLACE PACKAGE PLT_OTLP_BRIDGE
AS
    /**
     * PLT_OTLP_BRIDGE - OpenTelemetry Protocol Bridge for PLTelemetry
     * Version: 2.0.0 - Oracle 12c+ Native Edition (Breaking Changes)
     * 
     * Converts PLTelemetry JSON to OTLP format and routes to OpenTelemetry collectors
     * Optimized for Grafana standard dashboards and enterprise observability
     * 
     * Requirements: Oracle 12c+ with native JSON support
     * Dependencies: PLTelemetry core package
     * 
     * Breaking Changes from v1.x:
     * - All functions use Oracle 12c+ native JSON only
     * - Configuration is enterprise-ready (no hardcoded defaults)
     * - Improved OTLP compatibility for Grafana dashboards
     * - Removed unused/zombie functions
     */

    --------------------------------------------------------------------------
    -- CONSTANTS
    --------------------------------------------------------------------------

    -- OTLP Protocol Constants
    C_OTLP_TRACES_PATH     CONSTANT VARCHAR2(50) := '/v1/traces';
    C_OTLP_METRICS_PATH    CONSTANT VARCHAR2(50) := '/v1/metrics';
    C_OTLP_LOGS_PATH       CONSTANT VARCHAR2(50) := '/v1/logs';

    -- OTLP Status Codes (OpenTelemetry standard)
    C_STATUS_UNSET         CONSTANT NUMBER := 0;
    C_STATUS_OK            CONSTANT NUMBER := 1;
    C_STATUS_ERROR         CONSTANT NUMBER := 2;

    -- OTLP Severity Numbers (OpenTelemetry standard)
    C_SEVERITY_TRACE       CONSTANT NUMBER := 1;
    C_SEVERITY_DEBUG       CONSTANT NUMBER := 5;
    C_SEVERITY_INFO        CONSTANT NUMBER := 9;
    C_SEVERITY_WARN        CONSTANT NUMBER := 13;
    C_SEVERITY_ERROR       CONSTANT NUMBER := 17;
    C_SEVERITY_FATAL       CONSTANT NUMBER := 21;

    -- HTTP and Performance Constants
    C_DEFAULT_TIMEOUT      CONSTANT NUMBER := 30;
    C_DEFAULT_CHUNK_SIZE   CONSTANT NUMBER := 32767;

    --------------------------------------------------------------------------
    -- CORE CONFIGURATION
    --------------------------------------------------------------------------

    /**
     * MANDATORY: Set OpenTelemetry collector base URL
     * This automatically configures all three endpoints (traces, metrics, logs)
     * 
     * @param p_base_url Base URL of your OTLP collector (e.g., 'http://tempo:4318')
     * @example PLT_OTLP_BRIDGE.set_otlp_collector('http://tempo:4318');
     */
    PROCEDURE set_otlp_collector(p_base_url VARCHAR2);

    /**
     * RECOMMENDED: Configure service identification metadata
     * This information appears in all telemetry data for service identification
     * 
     * @param p_service_name Name of your service/application
     * @param p_service_version Version of your service (optional)
     * @param p_deployment_environment Environment identifier (prod, test, dev)
     * @example PLT_OTLP_BRIDGE.set_service_info('oracle-erp', '2.1.0', 'production');
     */
    PROCEDURE set_service_info(
        p_service_name         VARCHAR2, 
        p_service_version      VARCHAR2 DEFAULT NULL, 
        p_deployment_environment VARCHAR2 DEFAULT NULL
    );

    /**
     * OPTIONAL: Configure HTTP timeout for collector communication
     * 
     * @param p_timeout Timeout in seconds (default: 30)
     */
    PROCEDURE set_timeout(p_timeout NUMBER);

    /**
     * OPTIONAL: Enable/disable debug mode for troubleshooting
     * When enabled, outputs detailed information about OTLP conversion and HTTP calls
     * 
     * @param p_enabled TRUE to enable debug output, FALSE to disable
     */
    PROCEDURE set_debug_mode(p_enabled BOOLEAN);

    --------------------------------------------------------------------------
    -- ADVANCED CONFIGURATION
    --------------------------------------------------------------------------

    /**
     * ADVANCED: Set individual OTLP endpoints (overrides set_otlp_collector)
     * Use when you need different collectors for different telemetry types
     * 
     * @param p_url Full URL including path (e.g., 'http://jaeger:4318/v1/traces')
     */
    PROCEDURE set_traces_endpoint(p_url VARCHAR2);
    PROCEDURE set_metrics_endpoint(p_url VARCHAR2);
    PROCEDURE set_logs_endpoint(p_url VARCHAR2);

    /**
     * ENTERPRISE: Configure metric type mapping for Grafana dashboards
     * Maps PLTelemetry metrics to OTLP metric types for optimal dashboard compatibility
     * 
     * @param p_metric_name_pattern Metric name pattern (supports wildcards)
     * @param p_otlp_type OTLP metric type ('gauge', 'counter', 'histogram')
     * @example PLT_OTLP_BRIDGE.set_metric_type_mapping('requests.%', 'counter');
     */
    PROCEDURE set_metric_type_mapping(p_metric_name_pattern VARCHAR2, p_otlp_type VARCHAR2);

    --------------------------------------------------------------------------
    -- MAIN ROUTING
    --------------------------------------------------------------------------

    /**
     * INTERNAL: Main router called by PLTelemetry core when backend_url = 'OTLP_BRIDGE'
     * This is the entry point for all PLTelemetry data
     * 
     * @param p_json PLTelemetry JSON payload to convert and send
     */
    PROCEDURE route_to_otlp(p_json VARCHAR2);

    --------------------------------------------------------------------------
    -- OTLP PROTOCOL SENDERS
    --------------------------------------------------------------------------

    /**
     * Send trace/span data in OTLP format optimized for Tempo/Jaeger
     * 
     * @param p_json PLTelemetry span JSON
     */
    PROCEDURE send_trace_otlp(p_json VARCHAR2);

    /**
     * Send metric data in OTLP format optimized for Prometheus/Grafana dashboards
     * 
     * @param p_json PLTelemetry metric JSON
     */
    PROCEDURE send_metric_otlp(p_json VARCHAR2);

    /**
     * Send log data in OTLP format optimized for Loki
     * 
     * @param p_json PLTelemetry log JSON
     */
    PROCEDURE send_log_otlp(p_json VARCHAR2);

    --------------------------------------------------------------------------
    -- OTLP CONVERSION (Oracle 12c+ Native)
    --------------------------------------------------------------------------

    /**
     * Convert PLTelemetry attributes to OTLP format using Oracle 12c+ native JSON
     * 
     * @param p_attrs_json PLTelemetry attributes JSON
     * @return CLOB with OTLP-formatted attributes array
     */
    FUNCTION convert_attributes_to_otlp(p_attrs_json VARCHAR2) RETURN CLOB;

    /**
     * Convert PLTelemetry events to OTLP format using Oracle 12c+ native JSON
     * 
     * @param p_events_json PLTelemetry events JSON array
     * @return CLOB with OTLP-formatted events array
     */
    FUNCTION convert_events_to_otlp(p_events_json VARCHAR2) RETURN CLOB;

    /**
     * Convert PLTelemetry timestamp to Unix nanoseconds (OTLP format)
     * 
     * @param p_timestamp PLTelemetry timestamp string
     * @return Unix nanoseconds as string
     */
    FUNCTION to_unix_nano(p_timestamp VARCHAR2) RETURN VARCHAR2;

    /**
     * Generate OTLP resource attributes for service identification
     * Includes service.name, service.version, deployment.environment, etc.
     * 
     * @return JSON array with OTLP resource attributes
     */
    FUNCTION generate_resource_attributes RETURN CLOB;

    /**
     * Determine OTLP metric type based on metric name and configured mappings
     * 
     * @param p_metric_name Metric name to evaluate
     * @return OTLP metric type ('gauge', 'counter', 'histogram')
     */
    FUNCTION get_metric_type(p_metric_name VARCHAR2) RETURN VARCHAR2;

    --------------------------------------------------------------------------
    -- MULTI-TENANT CONTEXT MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * MULTI-TENANT: Set tenant context for all telemetry data
     * All subsequent telemetry will automatically include tenant information
     * 
     * @param p_tenant_id Unique tenant identifier
     * @param p_tenant_name Optional human-readable tenant name
     * @example PLT_OTLP_BRIDGE.set_tenant_context('tenant_001', 'Acme Corp');
     */
    PROCEDURE set_tenant_context(p_tenant_id VARCHAR2, p_tenant_name VARCHAR2 DEFAULT NULL);

    /**
     * MULTI-TENANT: Clear tenant context
     */
    PROCEDURE clear_tenant_context;

    --------------------------------------------------------------------------
    -- CONFIGURATION GETTERS
    --------------------------------------------------------------------------

    /**
     * Get current debug mode setting
     * 
     * @return TRUE if debug mode is enabled
     */
    FUNCTION get_debug_mode RETURN BOOLEAN;

    /**
     * Get current timeout setting
     * 
     * @return Timeout in seconds
     */
    FUNCTION get_timeout RETURN NUMBER;

    /**
     * Get current service name
     * 
     * @return Configured service name
     */
    FUNCTION get_service_name RETURN VARCHAR2;

    /**
     * Get current service version
     * 
     * @return Configured service version
     */
    FUNCTION get_service_version RETURN VARCHAR2;

    /**
     * Get current deployment environment
     * 
     * @return Configured deployment environment
     */
    FUNCTION get_deployment_environment RETURN VARCHAR2;

    /**
     * Get current tenant ID
     * 
     * @return Configured tenant ID
     */
    FUNCTION get_tenant_id RETURN VARCHAR2;

    /**
     * Get current tenant name
     * 
     * @return Configured tenant name
     */
    FUNCTION get_tenant_name RETURN VARCHAR2;

    --------------------------------------------------------------------------
    -- UTILITY FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Escape JSON string values according to JSON specification
     * Handles quotes, backslashes, and control characters
     * 
     * @param p_input String to escape
     * @return JSON-safe escaped string
     */
    FUNCTION escape_json_string(p_input VARCHAR2) RETURN VARCHAR2;

    /**
     * Convert PLTelemetry status to OTLP status code
     * 
     * @param p_status PLTelemetry status ('OK', 'ERROR', etc.)
     * @return OTLP status code (0=UNSET, 1=OK, 2=ERROR)
     */
    FUNCTION get_otlp_status_code(p_status VARCHAR2) RETURN NUMBER;

    /**
     * Convert log level to OTLP severity number
     * 
     * @param p_level Log level ('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')
     * @return OTLP severity number
     */
    FUNCTION get_otlp_severity_number(p_level VARCHAR2) RETURN NUMBER;

    /**
     * Validate OTLP collector connectivity
     * 
     * @return TRUE if collector is reachable, FALSE otherwise
     */
    FUNCTION validate_collector_connectivity RETURN BOOLEAN;

END PLT_OTLP_BRIDGE;
/