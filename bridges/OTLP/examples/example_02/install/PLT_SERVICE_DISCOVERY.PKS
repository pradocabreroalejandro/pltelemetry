CREATE OR REPLACE PACKAGE PLT_SERVICE_DISCOVERY
AS
    /**
     * PLT_SERVICE_DISCOVERY - Service Discovery and Health Monitoring for PLTelemetry
     * Version: 1.0.0 - Oracle 12c+ Enterprise Edition
     * 
     * Features:
     * - Table-driven configuration from plt_service_discovery_config
     * - Criticality-based check intervals from plt_service_discovery_crit_levels  
     * - Escalation logic for failed services with PLTelemetry integration
     * - Distributed tracing integration across service checks
     * - Individual service metrics (no aggregation for clean time series)
     * - Normalize & validate pattern for all inputs
     * - Multi-tenant support for enterprise environments
     * 
     * Requirements: Oracle 12c+ with native JSON support, PLTelemetry core package
     */

    --------------------------------------------------------------------------
    -- TYPE DEFINITIONS
    --------------------------------------------------------------------------

    -- Service health statuses (OpenTelemetry compliant)
    SUBTYPE t_health_status IS VARCHAR2(20);
    C_HEALTHY     CONSTANT t_health_status := 'HEALTHY';
    C_UNHEALTHY   CONSTANT t_health_status := 'UNHEALTHY'; 
    C_DEGRADED    CONSTANT t_health_status := 'DEGRADED';
    C_DOWN        CONSTANT t_health_status := 'DOWN';
    C_TIMEOUT     CONSTANT t_health_status := 'TIMEOUT';
    C_ERROR       CONSTANT t_health_status := 'ERROR';

    -- Health check result record
    TYPE t_health_result IS RECORD (
        service_name        VARCHAR2(50),
        status             t_health_status,
        response_time_ms   NUMBER,
        status_code        NUMBER,
        response_body      VARCHAR2(4000),
        error_message      VARCHAR2(4000),
        check_timestamp    TIMESTAMP WITH TIME ZONE,
        service_uptime     NUMBER,
        service_version    VARCHAR2(50),
        tenant_id          VARCHAR2(100)
    );

    -- Service runtime info (combines DB config with runtime state)
    TYPE t_service_runtime IS RECORD (
        service_id          NUMBER,
        service_name        VARCHAR2(50),
        service_description VARCHAR2(200),
        endpoint_url        VARCHAR2(300),
        criticality_code    VARCHAR2(10),
        timeout_seconds     NUMBER,
        is_enabled          NUMBER,
        tenant_id           VARCHAR2(100),
        -- Runtime state
        last_check_time     TIMESTAMP WITH TIME ZONE,
        consecutive_failures NUMBER,
        escalation_level    NUMBER,
        next_check_due      TIMESTAMP WITH TIME ZONE,
        -- Criticality settings
        base_check_interval NUMBER,
        current_check_interval NUMBER,
        escalation_multiplier NUMBER,
        max_escalation_failures NUMBER
    );

    -- Collection for runtime service info
    TYPE t_services_runtime IS TABLE OF t_service_runtime INDEX BY VARCHAR2(50);

    -- Custom plan execution context for variable substitution
    TYPE t_execution_context IS RECORD (
        http_status         NUMBER,
        http_response_time  NUMBER,
        http_response_body  VARCHAR2(4000),
        service_name        VARCHAR2(50),
        tenant_id           VARCHAR2(100)
    );

    --------------------------------------------------------------------------
    -- UTILITY FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Normalize input strings for safe processing
     * Removes leading/trailing spaces and null terminators from Forms
     * 
     * @param p_input Input string to normalize
     * @param p_max_length Maximum allowed length (default 4000)
     * @param p_allow_null Whether to allow NULL values (default TRUE)
     * @return Normalized string
     */
    FUNCTION normalize_string(
        p_input      VARCHAR2,
        p_max_length NUMBER DEFAULT 4000,
        p_allow_null BOOLEAN DEFAULT TRUE
    ) RETURN VARCHAR2;

    /**
     * Parse JSON health response for service status information
     * 
     * @param p_json_response JSON response body from health endpoint
     * @param p_key Key to extract from JSON
     * @return Extracted value or NULL if not found
     */
    FUNCTION parse_health_response(p_json_response VARCHAR2, p_key VARCHAR2) RETURN VARCHAR2;

    /**
     * Calculate escalated check interval based on failure count
     * 
     * @param p_base_interval Base check interval in minutes
     * @param p_consecutive_failures Number of consecutive failures
     * @param p_escalation_multiplier Escalation multiplier from config
     * @param p_max_escalation_failures Maximum escalation failures threshold
     * @return Calculated interval in minutes
     */
    FUNCTION calculate_escalated_interval(
        p_base_interval NUMBER,
        p_consecutive_failures NUMBER,
        p_escalation_multiplier NUMBER,
        p_max_escalation_failures NUMBER
    ) RETURN NUMBER;

    --------------------------------------------------------------------------
    -- CORE SERVICE DISCOVERY
    --------------------------------------------------------------------------

    /**
     * Initialize PLTelemetry configuration for service discovery
     * Must be called before any monitoring operations
     */
    PROCEDURE configure_telemetry;

    /**
     * Main service discovery check procedure - called by scheduled job
     * Reads service configuration from plt_service_discovery_config tables
     * 
     * @param p_force_all_checks Force check all services regardless of schedule
     * @param p_tenant_id Optional tenant filter for multi-tenant environments
     */
    PROCEDURE perform_discovery_checks(
        p_force_all_checks BOOLEAN DEFAULT FALSE,
        p_tenant_id VARCHAR2 DEFAULT NULL
    );

    /**
     * Check health of a specific service with full telemetry
     * 
     * @param p_service_name Name of service to check
     * @param p_trace_id Optional trace ID for distributed tracing
     * @return Health check result with full telemetry data
     */
    FUNCTION check_service_health(
        p_service_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_health_result;

    /**
     * Handle service failure with escalation logic
     * Updates consecutive_failures and calculates new check interval
     * 
     * @param p_service_name Service that failed
     * @param p_health_result Health check results
     */
    PROCEDURE handle_service_failure(
        p_service_name IN VARCHAR2,
        p_health_result IN t_health_result
    );

    /**
     * Handle service recovery
     * Resets failure counters and returns to normal check interval
     * 
     * @param p_service_name Service that recovered
     * @param p_health_result Health check results
     */
    PROCEDURE handle_service_recovery(
        p_service_name IN VARCHAR2,
        p_health_result IN t_health_result
    );

    /**
     * Get list of services that should be checked now
     * Based on last_check_time and criticality intervals
     * 
     * @param p_force_all Include all services regardless of schedule
     * @param p_tenant_id Optional tenant filter
     * @return Cursor with services due for checking
     */
    FUNCTION get_services_due_for_check(
        p_force_all BOOLEAN DEFAULT FALSE,
        p_tenant_id VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

    --------------------------------------------------------------------------
    -- SERVICE MANAGEMENT (CRUD)
    --------------------------------------------------------------------------

    /**
     * Add a new service to discovery monitoring
     * 
     * @param p_service_name Unique service name
     * @param p_description Service description
     * @param p_endpoint_url Health check endpoint URL
     * @param p_criticality_code Criticality level (CRITICAL, HIGH, MEDIUM, LOW)
     * @param p_timeout_seconds Request timeout (default 10)
     * @param p_enabled Enable immediately (default 1)
     * @param p_tenant_id Optional tenant identifier
     */
    PROCEDURE add_service(
        p_service_name VARCHAR2,
        p_description VARCHAR2,
        p_endpoint_url VARCHAR2,
        p_criticality_code VARCHAR2,
        p_timeout_seconds NUMBER DEFAULT 10,
        p_enabled NUMBER DEFAULT 1,
        p_tenant_id VARCHAR2 DEFAULT NULL
    );

    /**
     * Remove a service from discovery monitoring
     * 
     * @param p_service_name Service to remove
     */
    PROCEDURE remove_service(p_service_name VARCHAR2);

    /**
     * Update service configuration
     * 
     * @param p_service_name Service to update
     * @param p_description New description (optional)
     * @param p_endpoint_url New endpoint URL (optional)
     * @param p_criticality_code New criticality (optional)
     * @param p_timeout_seconds New timeout (optional)
     * @param p_tenant_id New tenant ID (optional)
     */
    PROCEDURE update_service(
        p_service_name VARCHAR2,
        p_description VARCHAR2 DEFAULT NULL,
        p_endpoint_url VARCHAR2 DEFAULT NULL,
        p_criticality_code VARCHAR2 DEFAULT NULL,
        p_timeout_seconds NUMBER DEFAULT NULL,
        p_tenant_id VARCHAR2 DEFAULT NULL
    );

    /**
     * Enable/disable monitoring for a specific service
     * Updates plt_service_discovery_config.is_enabled flag
     * 
     * @param p_service_name Service to enable/disable
     * @param p_enabled 1 to enable, 0 to disable
     */
    PROCEDURE set_service_monitoring(
        p_service_name VARCHAR2, 
        p_enabled NUMBER
    );

    /**
     * Reset failure counters for a service (emergency reset)
     * 
     * @param p_service_name Service to reset
     */
    PROCEDURE reset_service_failures(p_service_name VARCHAR2);

    --------------------------------------------------------------------------
    -- REPORTING AND ANALYTICS
    --------------------------------------------------------------------------

    /**
     * Generate comprehensive service discovery report from database tables
     * 
     * @param p_hours_back Hours of history to include (default 24)
     * @param p_tenant_id Optional tenant filter
     * @return JSON report of service health status
     */
    FUNCTION generate_discovery_report(
        p_hours_back NUMBER DEFAULT 24,
        p_tenant_id VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    /**
     * Get current service runtime configuration
     * Combines database config with runtime state
     * 
     * @param p_service_name Service name
     * @return Service runtime information
     */
    FUNCTION get_service_runtime(p_service_name VARCHAR2) RETURN t_service_runtime;

    /**
     * Get service discovery health summary for all tenants
     * 
     * @return JSON summary with service counts and health status by tenant
     */
    FUNCTION get_discovery_health_summary RETURN CLOB;

    --------------------------------------------------------------------------
    -- TENANT CONTEXT MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * Set tenant context for service discovery operations
     * All subsequent operations will include tenant information
     * 
     * @param p_tenant_id Tenant identifier
     * @param p_tenant_name Optional human-readable tenant name
     */
    PROCEDURE set_tenant_context(p_tenant_id VARCHAR2, p_tenant_name VARCHAR2 DEFAULT NULL);

    /**
     * Clear tenant context
     */
    PROCEDURE clear_tenant_context;

    /**
     * Get current tenant ID
     * 
     * @return Current tenant ID or NULL if no tenant context set
     */
    FUNCTION get_current_tenant_id RETURN VARCHAR2;

    -- =====================================================================
    -- PLT_SERVICE_DISCOVERY - Custom Plan Executor Extension
    -- Adding CUSTOM service support while maintaining ENDPOINT compatibility
    -- =====================================================================

    /**
    * Execute a custom monitoring plan from JSON configuration
    * Used for SERVICE_TYPE = 'CUSTOM' services
    * 
    * @param p_service_name Service name for context
    * @param p_custom_plan_json JSON plan configuration
    * @param p_trace_id Optional trace ID for distributed tracing
    * @return Health check result compatible with ENDPOINT services
    */
    FUNCTION execute_custom_plan(
        p_service_name IN VARCHAR2,
        p_custom_plan_json IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_health_result;

    /**
    * Execute HTTP call action from custom plan
    * 
    * @param p_action_json JSON configuration for http_call action
    * @param p_context Execution context for variable substitution
    * @param p_span_id Span ID for telemetry
    * @return Updated execution context with HTTP results
    */
    FUNCTION execute_http_call_action(
        p_action_json IN VARCHAR2,
        p_context IN OUT t_execution_context,
        p_span_id IN VARCHAR2
    ) RETURN t_execution_context;

    /**
    * Execute send_metric action from custom plan
    * 
    * @param p_action_json JSON configuration for send_metric action
    * @param p_context Execution context for variable substitution
    * @param p_span_id Span ID for telemetry
    */
    PROCEDURE execute_send_metric_action(
        p_action_json IN VARCHAR2,
        p_context IN t_execution_context,
        p_span_id IN VARCHAR2
    );

    /**
    * Substitute template variables in a string
    * Supports {{http_status}}, {{http_response_time}}, etc.
    * 
    * @param p_template Template string with {{variable}} placeholders
    * @param p_context Execution context with variable values
    * @return String with variables substituted
    */
    FUNCTION substitute_template_variables(
        p_template IN VARCHAR2,
        p_context IN t_execution_context
    ) RETURN VARCHAR2;

    

END PLT_SERVICE_DISCOVERY;
/