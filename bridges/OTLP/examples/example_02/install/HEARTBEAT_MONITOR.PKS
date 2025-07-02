CREATE OR REPLACE PACKAGE HEARTBEAT_MONITOR AS
    /**
     * PLTelemetry-enabled heartbeat monitoring system for services
     * 
     * Features:
     * - Table-driven configuration (no hardcoded services)
     * - Criticality-based check intervals from heartbeat_criticality_levels
     * - Service definitions in heartbeat_services table
     * - Escalation logic for failed services
     * - Distributed tracing integration with PLTelemetry
     * - Silent failure detection and recovery
     */

    -- Service health statuses
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
        service_version    VARCHAR2(50)
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

    /**
     * Initialize PLTelemetry configuration for heartbeat monitoring
     * Must be called before any monitoring operations
     */
    PROCEDURE configure_telemetry;

    /**
     * Main heartbeat check procedure - called by scheduled job every minute
     * Reads service configuration from tables and performs checks based on criticality
     * 
     * @param p_force_all_checks Force check all services regardless of schedule
     */
    PROCEDURE perform_heartbeat_checks(p_force_all_checks BOOLEAN DEFAULT FALSE);

    /**
     * Check health of a specific service with full telemetry
     * 
     * @param p_service_name Name of service to check
     * @param p_trace_id Optional trace ID for distributed tracing
     * @return Health check result
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
     * Generate comprehensive monitoring report from database tables
     * 
     * @param p_hours_back Hours of history to include (default 24)
     * @return JSON report of service health status
     */
    FUNCTION generate_monitoring_report(p_hours_back NUMBER DEFAULT 24) RETURN CLOB;

    /**
     * Enable/disable monitoring for a specific service
     * Updates heartbeat_services.is_enabled flag
     * 
     * @param p_service_name Service to enable/disable
     * @param p_enabled 1 to enable, 0 to disable
     */
    PROCEDURE set_service_monitoring(
        p_service_name VARCHAR2, 
        p_enabled NUMBER
    );

    /**
     * Add a new service to monitoring
     * 
     * @param p_service_name Unique service name
     * @param p_description Service description
     * @param p_endpoint_url Health check endpoint URL
     * @param p_criticality_code Criticality level (HIGH, MEDIUM, LOW, VERY_LOW)
     * @param p_timeout_seconds Request timeout (default 10)
     * @param p_enabled Enable immediately (default 1)
     */
    PROCEDURE add_service(
        p_service_name VARCHAR2,
        p_description VARCHAR2,
        p_endpoint_url VARCHAR2,
        p_criticality_code VARCHAR2,
        p_timeout_seconds NUMBER DEFAULT 10,
        p_enabled NUMBER DEFAULT 1
    );

    /**
     * Remove a service from monitoring
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
     */
    PROCEDURE update_service(
        p_service_name VARCHAR2,
        p_description VARCHAR2 DEFAULT NULL,
        p_endpoint_url VARCHAR2 DEFAULT NULL,
        p_criticality_code VARCHAR2 DEFAULT NULL,
        p_timeout_seconds NUMBER DEFAULT NULL
    );

    /**
     * Get current service runtime configuration
     * Combines database config with runtime state
     * 
     * @param p_service_name Service name
     * @return Service runtime information
     */
    FUNCTION get_service_runtime(p_service_name VARCHAR2) RETURN t_service_runtime;

    /**
     * Reset failure counters for a service (emergency reset)
     * 
     * @param p_service_name Service to reset
     */
    PROCEDURE reset_service_failures(p_service_name VARCHAR2);

    /**
     * Get list of services that should be checked now
     * Based on last_check_time and criticality intervals
     * 
     * @param p_force_all Include all services regardless of schedule
     * @return Cursor with services due for checking
     */
    FUNCTION get_services_due_for_check(p_force_all BOOLEAN DEFAULT FALSE) 
    RETURN SYS_REFCURSOR;

END HEARTBEAT_MONITOR;
/