CREATE OR REPLACE PACKAGE PLT_ACTIVATION_MANAGER
AS
    /**
     * PLT_ACTIVATION_MANAGER - Granular Telemetry Activation Control
     * Version: 1.0.0
     * 
     * Provides fine-grained control over PLTelemetry activation using whitelist approach.
     * Supports wildcards, inheritance, sampling, and temporal activation windows.
     * 
     * Requirements: Oracle 12c+
     * Dependencies: PLTelemetry core, PLT_OTLP_BRIDGE
     * 
     * Key Features:
     * - Whitelist approach: nothing active unless explicitly enabled
     * - Wildcard support: PKG.*, FORM.*, etc.
     * - Inheritance: PKG.* can be overridden by PKG.SPECIFIC_PROC
     * - Sampling rate: 0.0 to 1.0 for traffic control
     * - Temporal windows: time-based activation/deactivation
     * - Multi-tenant support
     */

    --------------------------------------------------------------------------
    -- TYPES AND CONSTANTS
    --------------------------------------------------------------------------

    -- Telemetry types supported
    C_TYPE_TRACE    CONSTANT VARCHAR2(10) := 'TRACE';
    C_TYPE_LOG      CONSTANT VARCHAR2(10) := 'LOG'; 
    C_TYPE_METRIC   CONSTANT VARCHAR2(10) := 'METRIC';

    -- Log levels for LOG telemetry
    C_LEVEL_TRACE   CONSTANT VARCHAR2(10) := 'TRACE';
    C_LEVEL_DEBUG   CONSTANT VARCHAR2(10) := 'DEBUG';
    C_LEVEL_INFO    CONSTANT VARCHAR2(10) := 'INFO';
    C_LEVEL_WARN    CONSTANT VARCHAR2(10) := 'WARN';
    C_LEVEL_ERROR   CONSTANT VARCHAR2(10) := 'ERROR';
    C_LEVEL_FATAL   CONSTANT VARCHAR2(10) := 'FATAL';

    

    --------------------------------------------------------------------------
    -- ACTIVATION MANAGEMENT - OVERLOADED PROCEDURES
    --------------------------------------------------------------------------

    /**
     * Enable telemetry with indefinite duration (until manually disabled)
     * 
     * @param p_object_name Object pattern (supports wildcards: PKG.*, FORM.*)
     * @param p_telemetry_type TRACE, LOG, or METRIC
     * @param p_tenant_id Tenant identifier
     * @param p_sampling_rate 0.0 to 1.0 (default 1.0 = 100%)
     * @param p_log_level Minimum log level for LOG type (default INFO)
     * @param p_enabled_from Start time (default SYSTIMESTAMP)
     * 
     * @example
     *   PLT_ACTIVATION_MANAGER.enable_telemetry(
     *       p_object_name => 'CUSTOMER_PKG.*',
     *       p_telemetry_type => 'TRACE',
     *       p_tenant_id => 'acme_corp',
     *       p_sampling_rate => 0.1
     *   );
     */
    PROCEDURE enable_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_sampling_rate     NUMBER DEFAULT 1.0,
        p_log_level         VARCHAR2 DEFAULT 'INFO',
        p_enabled_from      TIMESTAMP DEFAULT SYSTIMESTAMP
    );

    /**
     * Enable telemetry with duration in minutes
     * 
     * @param p_object_name Object pattern (supports wildcards)
     * @param p_telemetry_type TRACE, LOG, or METRIC
     * @param p_tenant_id Tenant identifier
     * @param p_sampling_rate 0.0 to 1.0 (default 1.0 = 100%)
     * @param p_log_level Minimum log level for LOG type (default INFO)
     * @param p_enabled_from Start time (default SYSTIMESTAMP)
     * @param p_duration_minutes Duration in minutes
     * 
     * @example
     *   PLT_ACTIVATION_MANAGER.enable_telemetry(
     *       p_object_name => 'DEBUG_PKG.*',
     *       p_telemetry_type => 'LOG',
     *       p_tenant_id => 'acme_corp',
     *       p_log_level => 'DEBUG',
     *       p_duration_minutes => 30
     *   );
     */
    PROCEDURE enable_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_sampling_rate     NUMBER DEFAULT 1.0,
        p_log_level         VARCHAR2 DEFAULT 'INFO',
        p_enabled_from      TIMESTAMP DEFAULT SYSTIMESTAMP,
        p_duration_minutes  NUMBER
    );

    /**
     * Enable telemetry with explicit end time
     * 
     * @param p_object_name Object pattern (supports wildcards)
     * @param p_telemetry_type TRACE, LOG, or METRIC
     * @param p_tenant_id Tenant identifier
     * @param p_sampling_rate 0.0 to 1.0 (default 1.0 = 100%)
     * @param p_log_level Minimum log level for LOG type (default INFO)
     * @param p_enabled_from Start time (default SYSTIMESTAMP)
     * @param p_enabled_to End time (explicit timestamp)
     * 
     * @example
     *   PLT_ACTIVATION_MANAGER.enable_telemetry(
     *       p_object_name => 'BATCH_PKG.PROCESS_ORDERS',
     *       p_telemetry_type => 'METRIC',
     *       p_tenant_id => 'acme_corp',
     *       p_enabled_from => TO_TIMESTAMP('2024-01-15 22:00:00', 'YYYY-MM-DD HH24:MI:SS'),
     *       p_enabled_to => TO_TIMESTAMP('2024-01-16 06:00:00', 'YYYY-MM-DD HH24:MI:SS')
     *   );
     */
    PROCEDURE enable_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_sampling_rate     NUMBER DEFAULT 1.0,
        p_log_level         VARCHAR2 DEFAULT 'INFO',
        p_enabled_from      TIMESTAMP DEFAULT SYSTIMESTAMP,
        p_enabled_to        TIMESTAMP
    );

    /**
     * Disable telemetry for specific object pattern
     * 
     * @param p_object_name Object pattern to disable
     * @param p_telemetry_type TRACE, LOG, or METRIC  
     * @param p_tenant_id Tenant identifier
     */
    PROCEDURE disable_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2
    );

    --------------------------------------------------------------------------
    -- ACTIVATION QUERIES - Core functions used by PLTelemetry
    --------------------------------------------------------------------------

    /**
     * Check if tracing is enabled for specific object
     * Uses wildcard matching and inheritance logic
     * 
     * @param p_object_name Full object name (e.g., 'CUSTOMER_PKG.GET_CUSTOMER')
     * @param p_tenant_id Tenant identifier
     * @return TRUE if tracing should be enabled
     */
    FUNCTION is_trace_enabled(
        p_object_name   VARCHAR2,
        p_tenant_id     VARCHAR2
    ) RETURN BOOLEAN;

    /**
     * Check if logging is enabled for specific object and level
     * 
     * @param p_object_name Full object name
     * @param p_tenant_id Tenant identifier
     * @param p_log_level Log level to check (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)
     * @return TRUE if logging should be enabled for this level
     */
    FUNCTION is_log_enabled(
        p_object_name   VARCHAR2,
        p_tenant_id     VARCHAR2,
        p_log_level     VARCHAR2
    ) RETURN BOOLEAN;

    /**
     * Check if metrics are enabled for specific object
     * 
     * @param p_object_name Full object name
     * @param p_tenant_id Tenant identifier
     * @return TRUE if metrics should be enabled
     */
    FUNCTION is_metric_enabled(
        p_object_name   VARCHAR2,
        p_tenant_id     VARCHAR2
    ) RETURN BOOLEAN;

    /**
     * Get sampling rate for specific object and telemetry type
     * 
     * @param p_object_name Full object name
     * @param p_telemetry_type TRACE, LOG, or METRIC
     * @param p_tenant_id Tenant identifier
     * @return Sampling rate (0.0 to 1.0) or 0.0 if disabled
     */
    FUNCTION get_sampling_rate(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2
    ) RETURN NUMBER;

    /**
     * Universal activation check - used internally by PLTelemetry core
     * Combines enabled check + sampling decision
     * 
     * @param p_object_name Full object name
     * @param p_telemetry_type TRACE, LOG, or METRIC
     * @param p_tenant_id Tenant identifier
     * @param p_log_level Log level (optional, for LOG type)
     * @return TRUE if telemetry should be generated and sent
     */
    FUNCTION should_generate_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_log_level         VARCHAR2 DEFAULT NULL
    ) RETURN BOOLEAN;

    --------------------------------------------------------------------------
    -- PATTERN MATCHING AND INHERITANCE
    --------------------------------------------------------------------------

    /**
     * Check if object name matches activation pattern
     * Supports wildcards: *, PKG.*, *.PROC, PKG.PROC
     * 
     * @param p_object_name Actual object name
     * @param p_pattern Pattern to match against
     * @return TRUE if pattern matches
     */
    FUNCTION matches_pattern(
        p_object_name   VARCHAR2,
        p_pattern       VARCHAR2
    ) RETURN BOOLEAN;

    /**
     * Find best matching activation rule using inheritance
     * Most specific match wins: PKG.PROC > PKG.* > *
     * 
     * @param p_object_name Full object name
     * @param p_telemetry_type TRACE, LOG, or METRIC
     * @param p_tenant_id Tenant identifier
     * @return Activation record (cursor row) or NULL if not found
     */
    FUNCTION find_best_activation_match(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2
    ) RETURN PLT_TELEMETRY_ACTIVATION%ROWTYPE;

    --------------------------------------------------------------------------
    -- MAINTENANCE AND CLEANUP
    --------------------------------------------------------------------------

    /**
     * Cleanup expired activation records
     * Called by scheduled job every 5 minutes
     * Sets enabled='N' for records past their enabled_time_to
     */
    PROCEDURE cleanup_expired_activations;

    /**
     * Purge old activation records and audit logs
     * 
     * @param p_keep_days Number of days to keep (default 90)
     */
    PROCEDURE purge_old_records(p_keep_days NUMBER DEFAULT 90);

    --------------------------------------------------------------------------
    -- REPORTING AND MONITORING
    --------------------------------------------------------------------------

    /**
     * Get activation summary for tenant
     * 
     * @param p_tenant_id Tenant identifier (NULL for all)
     * @return Cursor with activation statistics
     */
    FUNCTION get_activation_summary(
        p_tenant_id     VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

    /**
     * Get currently active telemetry configurations
     * 
     * @param p_tenant_id Tenant identifier (NULL for all)
     * @param p_telemetry_type Telemetry type filter (NULL for all)
     * @return Cursor with active configurations
     */
    FUNCTION get_active_configurations(
        p_tenant_id         VARCHAR2 DEFAULT NULL,
        p_telemetry_type    VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

    /**
     * Get recent activation changes (audit trail)
     * 
     * @param p_hours_back Number of hours to look back (default 24)
     * @param p_tenant_id Tenant filter (NULL for all)
     * @return Cursor with recent changes
     */
    FUNCTION get_recent_changes(
        p_hours_back    NUMBER DEFAULT 24,
        p_tenant_id     VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

    --------------------------------------------------------------------------
    -- BULK OPERATIONS
    --------------------------------------------------------------------------

    /**
     * Enable telemetry for multiple objects at once
     * 
     * @param p_object_patterns Array of object patterns
     * @param p_telemetry_type TRACE, LOG, or METRIC
     * @param p_tenant_id Tenant identifier
     * @param p_sampling_rate Sampling rate (default 1.0)
     * @param p_duration_minutes Duration in minutes (NULL for indefinite)
     */
    PROCEDURE enable_telemetry_bulk(
        p_object_patterns   SYS.ODCIVARCHAR2LIST,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_sampling_rate     NUMBER DEFAULT 1.0,
        p_duration_minutes  NUMBER DEFAULT NULL
    );

    /**
     * Disable all telemetry for tenant
     * Emergency stop function
     * 
     * @param p_tenant_id Tenant identifier
     * @param p_telemetry_type Specific type to disable (NULL for all)
     */
    PROCEDURE disable_all_telemetry(
        p_tenant_id         VARCHAR2,
        p_telemetry_type    VARCHAR2 DEFAULT NULL
    );

    --------------------------------------------------------------------------
    -- UTILITY FUNCTIONS
    --------------------------------------------------------------------------


    /**
     * Validate object name format
     * 
     * @param p_object_name Object name to validate
     * @return TRUE if valid format
     */
    FUNCTION is_valid_object_name(p_object_name VARCHAR2) RETURN BOOLEAN;

    /**
     * Validate telemetry type
     * 
     * @param p_telemetry_type Type to validate
     * @return TRUE if valid
     */
    FUNCTION is_valid_telemetry_type(p_telemetry_type VARCHAR2) RETURN BOOLEAN;

    /**
     * Convert log level to numeric priority for comparison
     * TRACE=1, DEBUG=2, INFO=3, WARN=4, ERROR=5, FATAL=6
     * 
     * @param p_log_level Log level string
     * @return Numeric priority
     */
    FUNCTION get_log_level_priority(p_log_level VARCHAR2) RETURN NUMBER;



END PLT_ACTIVATION_MANAGER;
/