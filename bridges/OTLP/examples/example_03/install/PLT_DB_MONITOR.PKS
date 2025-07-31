CREATE OR REPLACE PACKAGE PLT_DB_MONITOR
AS
    /**
     * PLT_DB_MONITOR - Tenant-Aware Database Monitoring Package
     * Version: 2.0.0 - Multi-Tenant Edition
     * 
     * Provides comprehensive database monitoring with tenant context.
     * Each database instance monitors for a specific tenant/environment combination.
     * 
     * Key Features:
     * - Automatic tenant context detection
     * - Environment-aware validation rules
     * - Tenant-specific validation instances
     * - Integration with PLTelemetry for observability
     * - Configurable thresholds per tenant/environment
     */

    --------------------------------------------------------------------------
    -- TYPE DEFINITIONS
    --------------------------------------------------------------------------

    -- Tenant context record
    TYPE t_tenant_context IS RECORD (
        tenant_id VARCHAR2(100),
        environment_name VARCHAR2(10),
        instance_identifier VARCHAR2(100)
    );

    -- Validation result record
    TYPE t_validation_result IS RECORD (
        validation_type VARCHAR2(100),
        instance_name VARCHAR2(100),
        target_identifier VARCHAR2(200),
        measured_value NUMBER,
        warning_threshold NUMBER,
        critical_threshold NUMBER,
        status VARCHAR2(20),
        message VARCHAR2(500)
    );

    --------------------------------------------------------------------------
    -- TENANT CONTEXT MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * Detect current tenant context from configuration
     * Replaces the old detect_environment() function
     *
     * @return t_tenant_context record with tenant_id, environment_name, instance_identifier
     * @example
     *   l_context := PLT_DB_MONITOR.detect_tenant_context();
     */
    FUNCTION detect_tenant_context RETURN t_tenant_context;

    /**
     * Get current tenant ID for this database instance
     *
     * @return VARCHAR2 tenant identifier
     */
    FUNCTION get_current_tenant_id RETURN VARCHAR2;

    /**
     * Get current environment name for this database instance
     *
     * @return VARCHAR2 environment name (PROD, UAT, DEV, TEST)
     */
    FUNCTION get_current_environment_name RETURN VARCHAR2;

    /**
     * Get current instance identifier
     *
     * @return VARCHAR2 instance identifier
     */
    FUNCTION get_current_instance_identifier RETURN VARCHAR2;

    /**
     * Update tenant context configuration
     *
     * @param p_tenant_id New tenant identifier
     * @param p_environment_name New environment name
     * @param p_instance_identifier New instance identifier
     * @param p_description Optional description
     */
    PROCEDURE update_tenant_context(
        p_tenant_id VARCHAR2,
        p_environment_name VARCHAR2,
        p_instance_identifier VARCHAR2 DEFAULT NULL,
        p_description VARCHAR2 DEFAULT NULL
    );

    --------------------------------------------------------------------------
    -- MAIN VALIDATION ORCHESTRATOR
    --------------------------------------------------------------------------

    /**
     * Perform all database validations for current tenant/environment
     * This is the main entry point called by scheduler jobs
     *
     * @param p_force_all_checks Force all checks regardless of intervals (default FALSE)
     * @param p_trace_id Optional trace ID for distributed tracing
     */
    PROCEDURE perform_database_validations(
        p_force_all_checks BOOLEAN DEFAULT FALSE,
        p_trace_id VARCHAR2 DEFAULT NULL
    );

    /**
     * Perform specific validation type for current tenant/environment
     *
     * @param p_validation_type_code Validation type to execute
     * @param p_instance_name Optional specific instance name
     * @param p_trace_id Optional trace ID for distributed tracing
     */
    PROCEDURE perform_validation_type(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2 DEFAULT NULL,
        p_trace_id VARCHAR2 DEFAULT NULL
    );

    --------------------------------------------------------------------------
    -- SPECIFIC VALIDATION PROCEDURES
    --------------------------------------------------------------------------

    /**
     * Validate tablespace usage for current tenant
     *
     * @param p_instance_name Specific tablespace instance name
     * @param p_target_identifier Tablespace name to validate
     * @param p_trace_id Optional trace ID for tracing
     * @return t_validation_result with validation outcome
     */
    FUNCTION validate_tablespace_usage(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate active sessions count for current tenant
     *
     * @param p_instance_name Instance name
     * @param p_target_identifier Target identifier (usually 'ALL')
     * @param p_trace_id Optional trace ID for tracing
     * @return t_validation_result with validation outcome
     */
    FUNCTION validate_active_sessions(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate blocked sessions count for current tenant
     *
     * @param p_instance_name Instance name
     * @param p_target_identifier Target identifier (usually 'ALL')
     * @param p_trace_id Optional trace ID for tracing
     * @return t_validation_result with validation outcome
     */
    FUNCTION validate_blocked_sessions(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate invalid objects count for current tenant
     *
     * @param p_instance_name Instance name
     * @param p_target_identifier Target identifier (usually 'ALL')
     * @param p_trace_id Optional trace ID for tracing
     * @return t_validation_result with validation outcome
     */
    FUNCTION validate_invalid_objects(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate failed scheduler jobs for current tenant
     *
     * @param p_instance_name Instance name
     * @param p_target_identifier Target identifier (usually 'ALL')
     * @param p_trace_id Optional trace ID for tracing
     * @return t_validation_result with validation outcome
     */
    FUNCTION validate_failed_jobs(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate memory usage for current tenant
     *
     * @param p_instance_name Instance name
     * @param p_target_identifier Memory type (SGA, PGA, etc.)
     * @param p_trace_id Optional trace ID for tracing
     * @return t_validation_result with validation outcome
     */
    FUNCTION validate_memory_usage(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate CPU usage for current tenant
     *
     * @param p_instance_name Instance name
     * @param p_target_identifier CPU type identifier
     * @param p_trace_id Optional trace ID for tracing
     * @return t_validation_result with validation outcome
     */
    FUNCTION validate_cpu_usage(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate database CPU ratio for current tenant
     *
     * @param p_instance_name Instance name
     * @param p_target_identifier Target identifier
     * @param p_trace_id Optional trace ID for tracing
     * @return t_validation_result with validation outcome
     */
    FUNCTION validate_database_cpu_ratio(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate PGA memory usage for current tenant
     *
     * @param p_instance_name Instance name
     * @param p_target_identifier Target identifier
     * @param p_trace_id Optional trace ID for tracing
     * @return t_validation_result with validation outcome
     */
    FUNCTION validate_pga_memory_usage(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    --------------------------------------------------------------------------
    -- UTILITY AND HELPER FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Get validation rules for current tenant/environment
     *
     * @param p_validation_type_code Validation type code
     * @return Cursor with warning_threshold, critical_threshold, check_interval_minutes
     */
    FUNCTION get_validation_rules_for_current_tenant(p_validation_type_code VARCHAR2)
        RETURN SYS_REFCURSOR;

    /**
     * Get enabled validation instances for current tenant/environment
     *
     * @param p_validation_type_code Optional filter by validation type
     * @return Cursor with instance details
     */
    FUNCTION get_enabled_instances_for_current_tenant(p_validation_type_code VARCHAR2 DEFAULT NULL)
        RETURN SYS_REFCURSOR;

    /**
     * Check if validation is due for execution based on interval
     *
     * @param p_validation_type_code Validation type
     * @param p_instance_name Instance name
     * @param p_force_check Force check regardless of interval
     * @return TRUE if validation should be executed
     */
    FUNCTION is_validation_due(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2,
        p_force_check BOOLEAN DEFAULT FALSE
    ) RETURN BOOLEAN;

    /**
     * Update validation instance results
     *
     * @param p_validation_type_code Validation type
     * @param p_instance_name Instance name
     * @param p_status Validation status (OK, WARNING, CRITICAL, ERROR)
     * @param p_measured_value Measured value
     * @param p_error_message Optional error message
     */
    PROCEDURE update_validation_result(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2,
        p_status VARCHAR2,
        p_measured_value NUMBER DEFAULT NULL,
        p_error_message VARCHAR2 DEFAULT NULL
    );

    /**
     * Send validation metrics to PLTelemetry
     *
     * @param p_validation_result Validation result record
     * @param p_trace_id Optional trace ID for correlation
     */
    PROCEDURE send_validation_metrics(
        p_validation_result t_validation_result,
        p_trace_id VARCHAR2 DEFAULT NULL
    );

    /**
     * Log validation events to PLTelemetry
     *
     * @param p_validation_type Validation type
     * @param p_instance_name Instance name
     * @param p_event_name Event name
     * @param p_message Event message
     * @param p_trace_id Optional trace ID for correlation
     */
    PROCEDURE log_validation_event(
        p_validation_type VARCHAR2,
        p_instance_name VARCHAR2,
        p_event_name VARCHAR2,
        p_message VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    );

    --------------------------------------------------------------------------
    -- CONFIGURATION AND MAINTENANCE
    --------------------------------------------------------------------------

    /**
     * Enable/disable validation instance for current tenant
     *
     * @param p_validation_type_code Validation type
     * @param p_instance_name Instance name
     * @param p_enabled TRUE to enable, FALSE to disable
     */
    PROCEDURE set_validation_instance_enabled(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2,
        p_enabled BOOLEAN
    );

    /**
     * Get tenant monitoring status summary
     *
     * @return Cursor with monitoring summary for current tenant
     */
    FUNCTION get_tenant_monitoring_status RETURN SYS_REFCURSOR;

    /**
     * Validate tenant configuration and setup
     *
     * @return TRUE if configuration is valid
     */
    FUNCTION validate_tenant_configuration RETURN BOOLEAN;

    /**
     * Initialize monitoring for current tenant
     * Creates default validation instances based on detected database objects
     *
     * @param p_auto_enable_instances Automatically enable created instances (default FALSE)
     */
    PROCEDURE initialize_tenant_monitoring(p_auto_enable_instances BOOLEAN DEFAULT FALSE);

END PLT_DB_MONITOR;
/