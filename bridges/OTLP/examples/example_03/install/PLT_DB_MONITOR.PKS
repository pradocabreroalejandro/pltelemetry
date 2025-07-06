CREATE OR REPLACE PACKAGE PLT_DB_MONITOR AS
    /**
     * PLTelemetry-enabled database validation monitoring system
     * 
     * Features:
     * - Table-driven configuration from db_validation_types/rules/instances
     * - Environment-specific thresholds (PROD vs TEST)
     * - Individual validation instances (all disabled by default)
     * - Extensible validation framework - add any custom checks
     * - Distributed tracing integration with PLTelemetry
     * - Individual metrics per validation instance (no aggregation)
     */

    -- Validation statuses
    SUBTYPE t_validation_status IS VARCHAR2(100);
    C_OK        CONSTANT t_validation_status := 'OK';
    C_WARNING   CONSTANT t_validation_status := 'WARNING';
    C_CRITICAL  CONSTANT t_validation_status := 'CRITICAL';
    C_ERROR     CONSTANT t_validation_status := 'ERROR';

    -- Environment detection
    SUBTYPE t_environment IS VARCHAR2(10);
    C_PROD      CONSTANT t_environment := 'PROD';
    C_TEST      CONSTANT t_environment := 'TEST';
    C_DEV       CONSTANT t_environment := 'DEV';

    -- Validation result record
    TYPE t_validation_result IS RECORD (
        validation_type_code    VARCHAR2(100),
        instance_name           VARCHAR2(100),
        target_identifier       VARCHAR2(200),
        current_value           NUMBER,
        warning_threshold       NUMBER,
        critical_threshold      NUMBER,
        threshold_unit          VARCHAR2(100),
        status                  t_validation_status,
        status_message          VARCHAR2(4000),
        check_timestamp         TIMESTAMP WITH TIME ZONE,
        response_time_ms        NUMBER,
        error_details           VARCHAR2(4000)
    );

    -- Validation instance runtime info
    TYPE t_validation_runtime IS RECORD (
        instance_id             NUMBER,
        validation_type_code    VARCHAR2(100),
        instance_name           VARCHAR2(100),
        target_identifier       VARCHAR2(200),
        is_enabled              NUMBER,
        validation_procedure    VARCHAR2(100),
        environment_name        VARCHAR2(10),
        warning_threshold       NUMBER,
        critical_threshold      NUMBER,
        threshold_unit          VARCHAR2(100),
        check_interval_minutes  NUMBER,
        last_check_time         TIMESTAMP WITH TIME ZONE,
        last_check_status       VARCHAR2(100),
        last_check_value        NUMBER,
        consecutive_failures    NUMBER
    );

    /**
     * Initialize PLTelemetry configuration for database monitoring
     * Must be called before any monitoring operations
     */
    PROCEDURE configure_telemetry;

    /**
     * Main database validation check procedure - called by scheduled job
     * Reads validation configuration from tables and performs checks
     * 
     * @param p_force_all_checks Force check all enabled validations regardless of schedule
     * @param p_environment_name Target environment (PROD, TEST, DEV) - auto-detected if null
     */
    PROCEDURE perform_database_validations(
        p_force_all_checks BOOLEAN DEFAULT FALSE,
        p_environment_name VARCHAR2 DEFAULT NULL
    );

    /**
     * Execute specific validation type for all enabled instances
     * 
     * @param p_validation_type_code Type of validation to run
     * @param p_environment_name Target environment 
     * @param p_trace_id Optional trace ID for distributed tracing
     */
    PROCEDURE execute_validation_type(
        p_validation_type_code IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    );

    /**
     * Execute validation for a specific instance
     * 
     * @param p_instance_name Specific validation instance to check
     * @param p_environment_name Target environment
     * @param p_trace_id Optional trace ID for distributed tracing
     * @return Validation result
     */
    FUNCTION execute_validation_instance(
        p_instance_name IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    -- =========================================================================
    -- INDIVIDUAL VALIDATION PROCEDURES
    -- =========================================================================

    /**
     * Validate tablespace usage percentage
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Tablespace name
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_tablespace_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate active sessions count
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Target identifier (usually 'ALL')
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_active_sessions(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate blocked sessions count
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Target identifier (usually 'ALL')
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_blocked_sessions(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate invalid objects count
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Target identifier (usually 'ALL')
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_invalid_objects(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate failed jobs count (granular with job details)
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Target identifier (usually 'ALL')
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_failed_jobs(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate memory usage percentage
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Memory type (SGA, PGA)
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_memory_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate CPU usage percentage
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier CPU target (usually 'DB_CPU')
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_cpu_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate certificate expiration (wildcard validation example)
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Certificate identifier
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_certificate_expiration(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    -- =========================================================================
    -- CONFIGURATION AND MANAGEMENT FUNCTIONS
    -- =========================================================================

    /**
     * Auto-detect current environment based on database name/context
     * 
     * @return Environment name (PROD, TEST, DEV)
     */
    FUNCTION detect_environment RETURN VARCHAR2;

    /**
     * Get validation runtime configuration for an instance
     * Combines database config with runtime state
     * 
     * @param p_instance_name Validation instance name
     * @param p_environment_name Environment name
     * @return Validation runtime information
     */
    FUNCTION get_validation_runtime(
        p_instance_name VARCHAR2,
        p_environment_name VARCHAR2
    ) RETURN t_validation_runtime;

    /**
     * Get list of validation instances due for checking
     * Based on last_check_time and check intervals
     * 
     * @param p_force_all Include all enabled instances regardless of schedule
     * @param p_environment_name Target environment
     * @return Cursor with instances due for checking
     */
    FUNCTION get_validations_due_for_check(
        p_force_all BOOLEAN DEFAULT FALSE,
        p_environment_name VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

    /**
     * Enable/disable monitoring for a specific validation instance
     * 
     * @param p_instance_name Validation instance to enable/disable
     * @param p_enabled 1 to enable, 0 to disable
     */
    PROCEDURE set_validation_monitoring(
        p_instance_name VARCHAR2,
        p_enabled NUMBER
    );

    /**
     * Add a new validation instance
     * 
     * @param p_validation_type_code Type of validation
     * @param p_instance_name Unique instance name
     * @param p_instance_description Description
     * @param p_target_identifier Database target identifier
     * @param p_enabled Enable immediately (default 0 - disabled)
     */
    PROCEDURE add_validation_instance(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2,
        p_instance_description VARCHAR2,
        p_target_identifier VARCHAR2,
        p_enabled NUMBER DEFAULT 0
    );

    /**
     * Remove a validation instance
     * 
     * @param p_instance_name Instance to remove
     */
    PROCEDURE remove_validation_instance(p_instance_name VARCHAR2);

    /**
     * Update validation instance configuration
     * 
     * @param p_instance_name Instance to update
     * @param p_instance_description New description (optional)
     * @param p_target_identifier New target identifier (optional)
     */
    PROCEDURE update_validation_instance(
        p_instance_name VARCHAR2,
        p_instance_description VARCHAR2 DEFAULT NULL,
        p_target_identifier VARCHAR2 DEFAULT NULL
    );

    /**
     * Reset failure counters for a validation instance
     * 
     * @param p_instance_name Instance to reset
     */
    PROCEDURE reset_validation_failures(p_instance_name VARCHAR2);

    /**
     * Update validation thresholds for an environment
     * 
     * @param p_validation_type_code Validation type
     * @param p_environment_name Environment
     * @param p_warning_threshold New warning threshold (optional)
     * @param p_critical_threshold New critical threshold (optional)
     * @param p_check_interval_minutes New check interval (optional)
     */
    PROCEDURE update_validation_thresholds(
        p_validation_type_code VARCHAR2,
        p_environment_name VARCHAR2,
        p_warning_threshold NUMBER DEFAULT NULL,
        p_critical_threshold NUMBER DEFAULT NULL,
        p_check_interval_minutes NUMBER DEFAULT NULL
    );

    /**
     * Generate comprehensive database monitoring report
     * 
     * @param p_hours_back Hours of history to include (default 24)
     * @param p_environment_name Target environment (auto-detected if null)
     * @return JSON report of database validation status
     */
    FUNCTION generate_monitoring_report(
        p_hours_back NUMBER DEFAULT 24,
        p_environment_name VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    /**
     * Populate tablespace instances automatically from DBA_TABLESPACES
     * Discovers all tablespaces and creates validation instances (disabled by default)
     * 
     * @param p_exclude_temp_tablespaces Exclude temporary tablespaces (default TRUE)
     */
    PROCEDURE auto_populate_tablespace_instances(
        p_exclude_temp_tablespaces BOOLEAN DEFAULT TRUE
    );

    /**
     * Populate scheduler job instances automatically from DBA_SCHEDULER_JOBS
     * Discovers all enabled jobs and creates validation instances (disabled by default)
     * 
     * @param p_exclude_system_jobs Exclude Oracle system jobs (default TRUE)
     */
    PROCEDURE auto_populate_job_instances(
        p_exclude_system_jobs BOOLEAN DEFAULT TRUE
    );

    /**
     * Validate database CPU time ratio (Oracle 23ai)
     */
    FUNCTION validate_database_cpu_ratio(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate CPU usage per transaction (Oracle 23ai)
     */
    FUNCTION validate_cpu_usage_per_txn(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate background CPU usage (Oracle 23ai)
     */
    FUNCTION validate_background_cpu_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate CPU time per user call (Oracle 23ai)
     */
    FUNCTION validate_cpu_time_per_call(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate PGA memory usage percentage
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Target identifier (usually 'PGA')
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_pga_memory_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate UGA memory usage percentage
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Target identifier (usually 'UGA')
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_uga_memory_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate memory sorts count
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Target identifier (usually 'MEMORY_SORTS')
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_memory_sorts_count(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

    /**
     * Validate work area memory allocated
     * 
     * @param p_instance_name Validation instance name
     * @param p_target_identifier Target identifier (usually 'WORKAREA')
     * @param p_environment_name Environment (PROD/TEST/DEV)
     * @param p_trace_id Optional trace ID
     * @return Validation result
     */
    FUNCTION validate_workarea_memory_allocated(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result;

END PLT_DB_MONITOR;
/