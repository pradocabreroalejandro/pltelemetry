CREATE OR REPLACE PACKAGE BODY PLT_DB_MONITOR AS

    -- Global configuration flags
    g_telemetry_configured BOOLEAN := FALSE;

    --------------------------------------------------------------------------
    -- PRIVATE HELPER FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Evaluate validation status based on thresholds
     * Handles both normal and inverted logic (like certificate expiration)
     */
    FUNCTION evaluate_validation_status(
        p_current_value NUMBER,
        p_warning_threshold NUMBER,
        p_critical_threshold NUMBER,
        p_validation_type VARCHAR2
    ) RETURN t_validation_status IS
    BEGIN
        -- Certificate expiration uses inverted logic (lower values are worse)
        IF p_validation_type = 'CERT_EXPIRATION' THEN
            IF p_current_value <= p_critical_threshold THEN
                RETURN C_CRITICAL;
            ELSIF p_current_value <= p_warning_threshold THEN
                RETURN C_WARNING;
            ELSE
                RETURN C_OK;
            END IF;
        ELSE
            -- Normal logic (higher values are worse)
            IF p_current_value >= p_critical_threshold THEN
                RETURN C_CRITICAL;
            ELSIF p_current_value >= p_warning_threshold THEN
                RETURN C_WARNING;
            ELSE
                RETURN C_OK;
            END IF;
        END IF;
    END evaluate_validation_status;

    /**
     * Create validation-specific attributes for metrics (STABLE LABELS ONLY)
     */
    FUNCTION create_validation_attributes(
        p_validation_type VARCHAR2,
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_environment VARCHAR2
    ) RETURN PLTelemetry.t_attributes IS
        l_attrs PLTelemetry.t_attributes;
        l_idx NUMBER := 1;
    BEGIN
        l_attrs(l_idx) := PLTelemetry.add_attribute('validation_type', p_validation_type);
        l_idx := l_idx + 1;
        
        l_attrs(l_idx) := PLTelemetry.add_attribute('instance_name', p_instance_name);
        l_idx := l_idx + 1;
        
        l_attrs(l_idx) := PLTelemetry.add_attribute('target_identifier', p_target_identifier);
        l_idx := l_idx + 1;
        
        l_attrs(l_idx) := PLTelemetry.add_attribute('environment', p_environment);
        
        RETURN l_attrs;
    END create_validation_attributes;

    /**
     * Generate validation status message
     */
    FUNCTION generate_status_message(
        p_validation_type VARCHAR2,
        p_target_identifier VARCHAR2,
        p_current_value NUMBER,
        p_threshold_unit VARCHAR2,
        p_status t_validation_status
    ) RETURN VARCHAR2 IS
    BEGIN
        RETURN p_validation_type || ' for ' || p_target_identifier || 
               ' is ' || p_status || ' with value ' || 
               TO_CHAR(p_current_value, '999999.99') || ' ' || p_threshold_unit;
    END generate_status_message;

    /**
     * Load validation runtime configuration from database tables
     */
    FUNCTION load_validation_runtime(
        p_instance_name VARCHAR2,
        p_environment_name VARCHAR2
    ) RETURN t_validation_runtime IS
        l_runtime t_validation_runtime;
    BEGIN
        SELECT 
            i.instance_id,
            i.validation_type_code,
            i.instance_name,
            i.target_identifier,
            i.is_enabled,
            t.validation_procedure,
            r.environment_name,
            r.warning_threshold,
            r.critical_threshold,
            r.threshold_unit,
            r.check_interval_minutes,
            i.last_check_time,
            i.last_check_status,
            i.last_check_value,
            i.consecutive_failures
        INTO 
            l_runtime.instance_id,
            l_runtime.validation_type_code,
            l_runtime.instance_name,
            l_runtime.target_identifier,
            l_runtime.is_enabled,
            l_runtime.validation_procedure,
            l_runtime.environment_name,
            l_runtime.warning_threshold,
            l_runtime.critical_threshold,
            l_runtime.threshold_unit,
            l_runtime.check_interval_minutes,
            l_runtime.last_check_time,
            l_runtime.last_check_status,
            l_runtime.last_check_value,
            l_runtime.consecutive_failures
        FROM db_validation_instances i
        JOIN db_validation_types t ON i.validation_type_code = t.validation_type_code
        JOIN db_validation_rules r ON i.validation_type_code = r.validation_type_code 
                                   AND r.environment_name = p_environment_name
        WHERE i.instance_name = p_instance_name
          AND r.is_enabled = 1;

        RETURN l_runtime;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'Validation instance not found or not configured for environment: ' || 
                                   p_instance_name || ' (' || p_environment_name || ')');
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20002, 'Error loading validation runtime: ' || 
                                   SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
    END load_validation_runtime;

    /**
     * Generic validation executor - eliminates duplication
     * This is the core validation engine that handles all common operations
     */
    FUNCTION execute_validation_with_telemetry(
        p_instance_name VARCHAR2,
        p_environment_name VARCHAR2,
        p_trace_id VARCHAR2,
        p_validation_query VARCHAR2,
        p_operation_name VARCHAR2
    ) RETURN t_validation_result IS
        l_result t_validation_result;
        l_runtime t_validation_runtime;
        l_span_id VARCHAR2(16);
        l_attrs PLTelemetry.t_attributes;
        l_start_time TIMESTAMP := SYSTIMESTAMP;
        l_current_value NUMBER;
        l_metric_attrs PLTelemetry.t_attributes;
    BEGIN
        -- Load configuration
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        
        -- Initialize result
        l_result.validation_type_code := l_runtime.validation_type_code;
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := l_runtime.target_identifier;
        l_result.warning_threshold := l_runtime.warning_threshold;
        l_result.critical_threshold := l_runtime.critical_threshold;
        l_result.threshold_unit := l_runtime.threshold_unit;
        l_result.check_timestamp := SYSTIMESTAMP;

        -- Start span for tracing
        IF p_trace_id IS NOT NULL THEN
            l_span_id := PLTelemetry.continue_distributed_trace(
                p_trace_id => p_trace_id,
                p_operation => p_operation_name || '_' || l_runtime.target_identifier
            );
        ELSE
            l_span_id := PLTelemetry.start_span(p_operation_name);
        END IF;

        -- Add validation context
        l_attrs(1) := PLTelemetry.add_attribute('validation.type', l_runtime.validation_type_code);
        l_attrs(2) := PLTelemetry.add_attribute('target.identifier', l_runtime.target_identifier);
        l_attrs(3) := PLTelemetry.add_attribute('environment', p_environment_name);
        PLTelemetry.add_event(l_span_id, 'validation_started', l_attrs);

        -- Execute the validation query
        BEGIN
            -- DEBUG: Show what we're about to execute
            DBMS_OUTPUT.PUT_LINE('🔍 EXECUTING QUERY FOR: ' || l_runtime.validation_type_code);
            DBMS_OUTPUT.PUT_LINE('📊 TARGET: ' || l_runtime.target_identifier);
            DBMS_OUTPUT.PUT_LINE('🔧 QUERY: ' || p_validation_query);

            -- Check if query contains bind variables (:1)
            IF INSTR(p_validation_query, ':1') > 0 THEN
                DBMS_OUTPUT.PUT_LINE('🔗 Using bind variable: ' || l_runtime.target_identifier);
                EXECUTE IMMEDIATE p_validation_query INTO l_current_value USING l_runtime.target_identifier;
            ELSE
                DBMS_OUTPUT.PUT_LINE('🚫 No bind variables needed');
                EXECUTE IMMEDIATE p_validation_query INTO l_current_value;
            END IF;
            
            DBMS_OUTPUT.PUT_LINE('✅ SUCCESS: Got value = ' || l_current_value);
            
            l_result.current_value := l_current_value;
            
            -- Evaluate status
            l_result.status := evaluate_validation_status(
                l_current_value,
                l_runtime.warning_threshold,
                l_runtime.critical_threshold,
                l_runtime.validation_type_code
            );
            
            l_result.status_message := generate_status_message(
                l_runtime.validation_type_code,
                l_runtime.target_identifier,
                l_current_value,
                l_runtime.threshold_unit,
                l_result.status
            );

        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                DBMS_OUTPUT.PUT_LINE('❌ NO_DATA_FOUND: Target not found: ' || l_runtime.target_identifier);
                DBMS_OUTPUT.PUT_LINE('🔧 Failed Query: ' || p_validation_query);
                l_result.status := C_ERROR;
                l_result.error_details := 'Target not found: ' || l_runtime.target_identifier;
                l_result.current_value := -1;
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('💥 QUERY ERROR: ' || SQLCODE || ' - ' || SQLERRM);
                DBMS_OUTPUT.PUT_LINE('🔧 Failed Query: ' || p_validation_query);
                DBMS_OUTPUT.PUT_LINE('📍 Target: ' || l_runtime.target_identifier);
                DBMS_OUTPUT.PUT_LINE('📚 Stack: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
                
                l_result.status := C_ERROR;
                l_result.error_details := 'Query error: ' || 
                    SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
                l_result.current_value := -1;
        END;

        -- Calculate response time
        l_result.response_time_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000;

        -- Generate metrics
        l_metric_attrs := create_validation_attributes(
            p_validation_type => l_runtime.validation_type_code,
            p_instance_name => p_instance_name,
            p_target_identifier => l_runtime.target_identifier,
            p_environment => p_environment_name
        );

        -- Core validation metrics
        PLTelemetry.log_metric(
            p_metric_name => 'db_' || LOWER(l_runtime.validation_type_code) || '_value',
            p_value => NVL(l_result.current_value, -1),
            p_unit => l_runtime.threshold_unit,
            p_attributes => l_metric_attrs
        );

        PLTelemetry.log_metric(
            p_metric_name => 'db_' || LOWER(l_runtime.validation_type_code) || '_status_gauge',
            p_value => CASE l_result.status 
                        WHEN C_OK THEN 1
                        WHEN C_WARNING THEN 0.5
                        WHEN C_CRITICAL THEN 0
                        ELSE -1
                       END,
            p_unit => 'status',
            p_attributes => l_metric_attrs
        );

        PLTelemetry.log_metric(
            p_metric_name => 'db_validation_check_performed',
            p_value => 1,
            p_unit => 'count',
            p_attributes => l_metric_attrs
        );

        -- Add final result to span
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('result.status', l_result.status);
        l_attrs(2) := PLTelemetry.add_attribute('result.value', TO_CHAR(l_result.current_value, '999999.99'));
        l_attrs(3) := PLTelemetry.add_attribute('result.response_time_ms', TO_CHAR(l_result.response_time_ms, '999999.99'));
        PLTelemetry.add_event(l_span_id, 'validation_completed', l_attrs);

        -- End span
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status IN (C_OK, C_WARNING) THEN 'OK' ELSE 'ERROR' END);

        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := C_ERROR;
            l_result.error_details := 'Critical validation failure: ' || 
                                     SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
            l_result.current_value := -1;
            l_result.response_time_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000;
            
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END execute_validation_with_telemetry;

    --------------------------------------------------------------------------
    -- PUBLIC CONFIGURATION PROCEDURES
    --------------------------------------------------------------------------

    PROCEDURE configure_telemetry IS
    BEGIN
        IF NOT g_telemetry_configured THEN
            -- Configure PLTelemetry for database monitoring
            PLTelemetry.set_backend_url('OTLP_BRIDGE');
            PLT_OTLP_BRIDGE.set_otlp_collector('http://plt-otel-collector:4318');
            PLT_OTLP_BRIDGE.set_service_info('oracle-db-monitor', '1.0.0', 'production');
            PLT_OTLP_BRIDGE.set_native_json_mode(TRUE);
            PLTelemetry.set_async_mode(FALSE);
            PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
            
            g_telemetry_configured := TRUE;
        END IF;
    END configure_telemetry;

    FUNCTION detect_environment RETURN VARCHAR2 IS
        l_db_name VARCHAR2(50);
    BEGIN
        SELECT name INTO l_db_name FROM v$database;
        
        -- Simple environment detection based on database name
        IF UPPER(l_db_name) LIKE '%PROD%' OR UPPER(l_db_name) LIKE '%PRD%' THEN
            RETURN C_PROD;
        ELSIF UPPER(l_db_name) LIKE '%TEST%' OR UPPER(l_db_name) LIKE '%TST%' THEN
            RETURN C_TEST;
        ELSIF UPPER(l_db_name) LIKE '%DEV%' OR UPPER(l_db_name) LIKE '%DEVEL%' THEN
            RETURN C_DEV;
        ELSE
            -- Default to TEST for safety
            RETURN C_TEST;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN C_TEST; -- Safe default
    END detect_environment;

    --------------------------------------------------------------------------
    -- INDIVIDUAL VALIDATION PROCEDURES - NOW CLEAN AND DRY! 🔥
    --------------------------------------------------------------------------

    FUNCTION validate_tablespace_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT ROUND((used_space / total_space) * 100, 2) as used_pct
            FROM (
                SELECT 
                    NVL(df.total_space, 0) as total_space,
                    NVL(df.total_space, 0) - NVL(fs.free_space, 0) as used_space
                FROM dba_tablespaces ts
                LEFT JOIN (
                    SELECT tablespace_name, SUM(bytes) as total_space
                    FROM dba_data_files
                    GROUP BY tablespace_name
                ) df ON ts.tablespace_name = df.tablespace_name
                LEFT JOIN (
                    SELECT tablespace_name, SUM(bytes) as free_space
                    FROM dba_free_space
                    GROUP BY tablespace_name
                ) fs ON ts.tablespace_name = fs.tablespace_name
                WHERE ts.tablespace_name = UPPER(:1)
            )
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_tablespace_usage'
        );
    END validate_tablespace_usage;

    FUNCTION validate_active_sessions(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT COUNT(*) 
            FROM v$session
            WHERE status = 'ACTIVE' AND type = 'USER'
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_active_sessions'
        );
    END validate_active_sessions;

    FUNCTION validate_blocked_sessions(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT COUNT(*)
            FROM v$session
            WHERE blocking_session IS NOT NULL AND type = 'USER'
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_blocked_sessions'
        );
    END validate_blocked_sessions;

    FUNCTION validate_invalid_objects(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT COUNT(*)
            FROM dba_objects
            WHERE status = 'INVALID'
              AND owner NOT IN ('SYS', 'SYSTEM', 'XDB', 'APEX_030200', 'FLOWS_FILES')
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_invalid_objects'
        );
    END validate_invalid_objects;

    FUNCTION validate_failed_jobs(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT COUNT(*)
            FROM dba_scheduler_job_run_details
            WHERE status = 'FAILED'
              AND log_date > SYSDATE - 1
              AND owner NOT IN ('SYS', 'SYSTEM', 'ORACLE_OCM')
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_failed_jobs'
        );
    END validate_failed_jobs;

    FUNCTION validate_memory_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_sga_query CONSTANT VARCHAR2(1000) := q'[
            SELECT ROUND((used_mb / total_mb) * 100, 2) as usage_pct
            FROM (
                SELECT 
                    SUM(CASE WHEN name = 'Maximum SGA Size' THEN bytes/1024/1024 END) as total_mb,
                    SUM(CASE WHEN name IN ('Buffer Cache Size', 'Shared Pool Size', 'Large Pool Size', 'Java Pool Size', 'Streams Pool Size', 'Shared IO Pool Size') 
                        THEN bytes/1024/1024 ELSE 0 END) as used_mb
                FROM v$sgainfo
            )
        ]';
        
        l_pga_query CONSTANT VARCHAR2(1000) := q'[
            SELECT ROUND((pga_used_mem / pga_target_mem) * 100, 2) as usage_pct
            FROM (
                SELECT 
                    SUM(CASE WHEN name = 'aggregate PGA target parameter' THEN value END) as pga_target_mem,
                    SUM(CASE WHEN name = 'total PGA allocated' THEN value END) as pga_used_mem
                FROM v$pgastat
                WHERE name IN ('aggregate PGA target parameter', 'total PGA allocated')
            )
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => CASE WHEN UPPER(p_target_identifier) = 'SGA' THEN l_sga_query ELSE l_pga_query END,
            p_operation_name => 'validate_memory_usage'
        );
    END validate_memory_usage;

    FUNCTION validate_cpu_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(AVG(value), 2), 0)
            FROM v$metric
            WHERE metric_name = 'CPU Usage Per Sec'
              AND ROWNUM <= 1
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_cpu_usage'
        );
    END validate_cpu_usage;

    FUNCTION validate_database_cpu_ratio(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(AVG(value), 2), 0)
            FROM v$metric
            WHERE metric_name = 'Database CPU Time Ratio'
              AND ROWNUM <= 1
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_database_cpu_ratio'
        );
    END validate_database_cpu_ratio;

    FUNCTION validate_cpu_usage_per_txn(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(AVG(value), 2), 0)
            FROM v$metric
            WHERE metric_name = 'CPU Usage Per Txn'
              AND ROWNUM <= 1
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_cpu_usage_per_txn'
        );
    END validate_cpu_usage_per_txn;

    FUNCTION validate_background_cpu_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(AVG(value), 2), 0)
            FROM v$metric
            WHERE metric_name = 'Background CPU Usage Per Sec'
              AND ROWNUM <= 1
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_background_cpu_usage'
        );
    END validate_background_cpu_usage;

    FUNCTION validate_cpu_time_per_call(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(AVG(value), 2), 0)
            FROM v$metric
            WHERE metric_name = 'CPU Time Per User Call'
              AND ROWNUM <= 1
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_cpu_time_per_call'
        );
    END validate_cpu_time_per_call;

    FUNCTION validate_certificate_expiration(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_result t_validation_result;
        l_runtime t_validation_runtime;
        l_span_id VARCHAR2(16);
        l_start_time TIMESTAMP := SYSTIMESTAMP;
        l_days_until_expiry NUMBER;
        l_expiry_date DATE;
        l_metric_attrs PLTelemetry.t_attributes;
    BEGIN
        -- This one needs custom logic, so we handle it separately
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        
        l_result.validation_type_code := l_runtime.validation_type_code;
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;
        l_result.warning_threshold := l_runtime.warning_threshold;
        l_result.critical_threshold := l_runtime.critical_threshold;
        l_result.threshold_unit := l_runtime.threshold_unit;
        l_result.check_timestamp := SYSTIMESTAMP;

        IF p_trace_id IS NOT NULL THEN
            l_span_id := PLTelemetry.continue_distributed_trace(
                p_trace_id => p_trace_id,
                p_operation => 'validate_certificate_' || p_target_identifier
            );
        ELSE
            l_span_id := PLTelemetry.start_span('validate_certificate_expiration');
        END IF;

        -- Mock certificate validation logic
        BEGIN
            CASE UPPER(p_target_identifier)
                WHEN 'MAIN_SSL_CERT' THEN l_expiry_date := SYSDATE + 45;
                WHEN 'TDE_WALLET' THEN l_expiry_date := SYSDATE + 15;
                ELSE l_expiry_date := SYSDATE + DBMS_RANDOM.VALUE(1, 365);
            END CASE;

            l_days_until_expiry := l_expiry_date - SYSDATE;
            l_result.current_value := l_days_until_expiry;
            
            l_result.status := evaluate_validation_status(
                l_days_until_expiry,
                l_runtime.warning_threshold,
                l_runtime.critical_threshold,
                'CERT_EXPIRATION'
            );
            
            l_result.status_message := generate_status_message(
                'Certificate ' || p_target_identifier,
                'expires in',
                l_days_until_expiry,
                'days',
                l_result.status
            );

            l_result.error_details := 'Certificate expires on: ' || TO_CHAR(l_expiry_date, 'YYYY-MM-DD');

        EXCEPTION
            WHEN OTHERS THEN
                l_result.status := C_ERROR;
                l_result.error_details := 'Certificate check error: ' || 
                    SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
                l_result.current_value := -1;
        END;

        l_result.response_time_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000;

        -- Generate metrics
        l_metric_attrs := create_validation_attributes(
            p_validation_type => 'CERT_EXPIRATION',
            p_instance_name => p_instance_name,
            p_target_identifier => p_target_identifier,
            p_environment => p_environment_name
        );

        PLTelemetry.log_metric(
            p_metric_name => 'db_certificate_days_until_expiry',
            p_value => NVL(l_result.current_value, -1),
            p_unit => 'days',
            p_attributes => l_metric_attrs
        );

        PLTelemetry.log_metric(
            p_metric_name => 'db_certificate_status_gauge',
            p_value => CASE l_result.status 
                        WHEN C_OK THEN 1
                        WHEN C_WARNING THEN 0.5
                        WHEN C_CRITICAL THEN 0
                        ELSE -1
                       END,
            p_unit => 'status',
            p_attributes => l_metric_attrs
        );

        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status IN (C_OK, C_WARNING) THEN 'OK' ELSE 'ERROR' END);
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := C_ERROR;
            l_result.error_details := 'Critical validation failure: ' || 
                                     SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
            l_result.current_value := -1;
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_certificate_expiration;

    --------------------------------------------------------------------------
    -- CORE EXECUTION AND ORCHESTRATION PROCEDURES
    --------------------------------------------------------------------------

    FUNCTION get_validations_due_for_check(
        p_force_all BOOLEAN DEFAULT FALSE,
        p_environment_name VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR IS
        l_cursor SYS_REFCURSOR;
        l_environment VARCHAR2(10);
    BEGIN
        l_environment := NVL(p_environment_name, detect_environment());
        
        IF p_force_all THEN
            OPEN l_cursor FOR
                SELECT 
                    i.instance_name,
                    i.validation_type_code,
                    t.validation_procedure,
                    r.check_interval_minutes
                FROM db_validation_instances i
                JOIN db_validation_types t ON i.validation_type_code = t.validation_type_code
                JOIN db_validation_rules r ON i.validation_type_code = r.validation_type_code 
                                           AND r.environment_name = l_environment
                WHERE i.is_enabled = 1
                  AND t.is_active = 1
                  AND r.is_enabled = 1
                ORDER BY r.check_interval_minutes, i.instance_name;
        ELSE
            OPEN l_cursor FOR
                SELECT 
                    i.instance_name,
                    i.validation_type_code,
                    t.validation_procedure,
                    r.check_interval_minutes
                FROM db_validation_instances i
                JOIN db_validation_types t ON i.validation_type_code = t.validation_type_code
                JOIN db_validation_rules r ON i.validation_type_code = r.validation_type_code 
                                           AND r.environment_name = l_environment
                WHERE i.is_enabled = 1
                  AND t.is_active = 1
                  AND r.is_enabled = 1
                  AND (i.last_check_time IS NULL 
                       OR i.last_check_time + INTERVAL '1' MINUTE * r.check_interval_minutes <= SYSTIMESTAMP)
                ORDER BY r.check_interval_minutes, i.instance_name;
        END IF;

        RETURN l_cursor;
    END get_validations_due_for_check;

    FUNCTION execute_validation_instance(
        p_instance_name IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_result t_validation_result;
    BEGIN
        -- Load validation configuration
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        
        -- Call the specific validation function based on type
        -- Call the specific validation function based on type
        CASE l_runtime.validation_procedure
            WHEN 'validate_tablespace_usage' THEN
                l_result := validate_tablespace_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_active_sessions' THEN
                l_result := validate_active_sessions(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_blocked_sessions' THEN
                l_result := validate_blocked_sessions(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_invalid_objects' THEN
                l_result := validate_invalid_objects(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_failed_jobs' THEN
                l_result := validate_failed_jobs(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_memory_usage' THEN
                l_result := validate_memory_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_cpu_usage' THEN
                l_result := validate_cpu_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_database_cpu_ratio' THEN
                l_result := validate_database_cpu_ratio(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_cpu_usage_per_txn' THEN
                l_result := validate_cpu_usage_per_txn(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_background_cpu_usage' THEN
                l_result := validate_background_cpu_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_cpu_time_per_call' THEN
                l_result := validate_cpu_time_per_call(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_certificate_expiration' THEN
                l_result := validate_certificate_expiration(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            -- 🔥 FIXED: Added missing memory validation cases
            WHEN 'validate_pga_memory_usage' THEN
                l_result := validate_pga_memory_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_uga_memory_usage' THEN
                l_result := validate_uga_memory_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_memory_sorts_count' THEN
                l_result := validate_memory_sorts_count(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_workarea_memory_allocated' THEN
                l_result := validate_workarea_memory_allocated(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            ELSE
                RAISE_APPLICATION_ERROR(-20020, 'Unknown validation procedure: ' || l_runtime.validation_procedure);
        END CASE;

        -- Update validation instance with results
        UPDATE db_validation_instances
        SET last_check_time = SYSTIMESTAMP,
            last_check_status = l_result.status,
            last_check_value = l_result.current_value,
            consecutive_failures = CASE 
                WHEN l_result.status IN (C_OK, C_WARNING) THEN 0
                ELSE consecutive_failures + 1
            END
        WHERE instance_name = p_instance_name;

        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            -- Create error result
            l_result.validation_type_code := NVL(l_runtime.validation_type_code, 'UNKNOWN');
            l_result.instance_name := p_instance_name;
            l_result.status := C_ERROR;
            l_result.error_details := 'Execution error: ' || 
                                     SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
            l_result.current_value := -1;
            l_result.check_timestamp := SYSTIMESTAMP;

            -- Update with error
            UPDATE db_validation_instances
            SET last_check_time = SYSTIMESTAMP,
                last_check_status = C_ERROR,
                last_check_value = -1,
                consecutive_failures = consecutive_failures + 1
            WHERE instance_name = p_instance_name;

            RETURN l_result;
    END execute_validation_instance;

    PROCEDURE execute_validation_type(
        p_validation_type_code IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) IS
        l_result t_validation_result;
        l_span_id VARCHAR2(16);
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        -- Start span for validation type execution
        IF p_trace_id IS NOT NULL THEN
            l_span_id := PLTelemetry.continue_distributed_trace(
                p_trace_id => p_trace_id,
                p_operation => 'execute_validation_type_' || p_validation_type_code
            );
        ELSE
            l_span_id := PLTelemetry.start_span('execute_validation_type');
        END IF;

        l_attrs(1) := PLTelemetry.add_attribute('validation_type', p_validation_type_code);
        l_attrs(2) := PLTelemetry.add_attribute('environment', p_environment_name);
        PLTelemetry.add_event(l_span_id, 'validation_type_execution_started', l_attrs);

        -- Execute all enabled instances of this validation type
        FOR rec IN (
            SELECT instance_name
            FROM db_validation_instances
            WHERE validation_type_code = p_validation_type_code
              AND is_enabled = 1
            ORDER BY instance_name
        ) LOOP
            BEGIN
                l_result := execute_validation_instance(
                    p_instance_name => rec.instance_name,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );

                PLTelemetry.add_event(l_span_id, 'validation_instance_completed_' || rec.instance_name);

            EXCEPTION
                WHEN OTHERS THEN
                    PLTelemetry.log_distributed(
                        p_trace_id => p_trace_id,
                        p_level => 'ERROR',
                        p_message => 'Failed to execute validation instance: ' || rec.instance_name || ' - ' || 
                                   SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200),
                        p_system => 'PLT_DB_MONITOR'
                    );
            END;
        END LOOP;

        PLTelemetry.add_event(l_span_id, 'validation_type_execution_completed');
        PLTelemetry.end_span(l_span_id, 'OK');

    EXCEPTION
        WHEN OTHERS THEN
            PLTelemetry.log_distributed(
                p_trace_id => p_trace_id,
                p_level => 'ERROR',
                p_message => 'Failed to execute validation type: ' || p_validation_type_code || ' - ' || 
                           SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200),
                p_system => 'PLT_DB_MONITOR'
            );
            PLTelemetry.end_span(l_span_id, 'ERROR');
    END execute_validation_type;

    PROCEDURE perform_database_validations(
        p_force_all_checks BOOLEAN DEFAULT FALSE,
        p_environment_name VARCHAR2 DEFAULT NULL
    ) IS
        l_trace_id VARCHAR2(32);
        l_span_id VARCHAR2(16);
        l_environment VARCHAR2(10);
        l_attrs PLTelemetry.t_attributes;
        l_start_time TIMESTAMP := SYSTIMESTAMP;
        l_cursor SYS_REFCURSOR;
        l_instance_name VARCHAR2(100);
        l_validation_type VARCHAR2(100);
        l_validation_procedure VARCHAR2(100);
        l_check_interval NUMBER;
        l_result t_validation_result;
        l_validation_count NUMBER := 0;
        l_error_count NUMBER := 0;
    BEGIN
        -- Ensure telemetry is configured
        configure_telemetry();

        -- Detect environment if not provided
        l_environment := NVL(p_environment_name, detect_environment());

        -- Start database validation trace
        l_trace_id := PLTelemetry.start_trace('database_validation_cycle');
        l_span_id := PLTelemetry.start_span('perform_database_validations');

        -- Add monitoring cycle context
        l_attrs(1) := PLTelemetry.add_attribute('validation.cycle_time', TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'));
        l_attrs(2) := PLTelemetry.add_attribute('validation.environment', l_environment);
        l_attrs(3) := PLTelemetry.add_attribute('validation.force_all_checks', CASE WHEN p_force_all_checks THEN 'true' ELSE 'false' END);
        PLTelemetry.add_event(l_span_id, 'database_validation_cycle_started', l_attrs);

        -- Get validations due for checking
        l_cursor := get_validations_due_for_check(p_force_all_checks, l_environment);

        LOOP
            FETCH l_cursor INTO l_instance_name, l_validation_type, l_validation_procedure, l_check_interval;
            EXIT WHEN l_cursor%NOTFOUND;

            l_validation_count := l_validation_count + 1;
            PLTelemetry.add_event(l_span_id, 'executing_validation_' || l_instance_name);

            -- Execute validation with distributed tracing
            BEGIN
                l_result := execute_validation_instance(
                    p_instance_name => l_instance_name,
                    p_environment_name => l_environment,
                    p_trace_id => l_trace_id
                );

                -- Log validation result
                PLTelemetry.log_distributed(
                    p_trace_id => l_trace_id,
                    p_level => CASE l_result.status 
                                WHEN C_OK THEN 'INFO'
                                WHEN C_WARNING THEN 'WARN'
                                WHEN C_CRITICAL THEN 'ERROR'
                                ELSE 'ERROR'
                               END,
                    p_message => 'Validation ' || l_instance_name || ': ' || l_result.status || 
                               ' (value: ' || TO_CHAR(l_result.current_value, '999999.99') || ')',
                    p_system => 'PLT_DB_MONITOR'
                );

            EXCEPTION
                WHEN OTHERS THEN
                    l_error_count := l_error_count + 1;
                    PLTelemetry.log_distributed(
                        p_trace_id => l_trace_id,
                        p_level => 'ERROR',
                        p_message => 'Validation execution failed for ' || l_instance_name || ': ' || 
                                   SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200),
                        p_system => 'PLT_DB_MONITOR'
                    );
            END;
        END LOOP;

        CLOSE l_cursor;

        -- Generate cycle metrics using native JSON
        DECLARE
            l_cycle_attrs PLTelemetry.t_attributes;
        BEGIN
            l_cycle_attrs(1) := PLTelemetry.add_attribute('cycle_type', 'database_validation');
            l_cycle_attrs(2) := PLTelemetry.add_attribute('environment', l_environment);
            l_cycle_attrs(3) := PLTelemetry.add_attribute('force_all', CASE WHEN p_force_all_checks THEN 'true' ELSE 'false' END);

            -- Cycle duration metric
            PLTelemetry.log_metric(
                p_metric_name => 'db_validation_cycle_duration_ms',
                p_value => EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000,
                p_unit => 'milliseconds',
                p_attributes => l_cycle_attrs
            );

            -- Validation counts
            PLTelemetry.log_metric(
                p_metric_name => 'db_validations_executed_count',
                p_value => l_validation_count,
                p_unit => 'count',
                p_attributes => l_cycle_attrs
            );

            PLTelemetry.log_metric(
                p_metric_name => 'db_validation_errors_count',
                p_value => l_error_count,
                p_unit => 'count',
                p_attributes => l_cycle_attrs
            );

            PLTelemetry.log_metric(
                p_metric_name => 'db_validation_cycle_completed',
                p_value => 1,
                p_unit => 'count',
                p_attributes => l_cycle_attrs
            );
        END;

        -- Log completion with native JSON
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('validations_executed', TO_CHAR(l_validation_count));
        l_attrs(2) := PLTelemetry.add_attribute('validation_errors', TO_CHAR(l_error_count));
        l_attrs(3) := PLTelemetry.add_attribute('cycle.duration_ms', 
            TO_CHAR(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, '999999.99'));
        PLTelemetry.add_event(l_span_id, 'database_validation_cycle_completed', l_attrs);

        PLTelemetry.end_span(l_span_id, CASE WHEN l_error_count = 0 THEN 'OK' ELSE 'ERROR' END);
        PLTelemetry.end_trace(l_trace_id);

        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            IF l_cursor%ISOPEN THEN
                CLOSE l_cursor;
            END IF;

            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('error.message', 
                SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            
            PLTelemetry.log_distributed(
                p_trace_id => l_trace_id,
                p_level => 'ERROR',
                p_message => 'Database validation cycle failed: ' || 
                           SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200),
                p_system => 'PLT_DB_MONITOR'
            );

            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            PLTelemetry.end_trace(l_trace_id);

            ROLLBACK;
    END perform_database_validations;

    --------------------------------------------------------------------------
    -- CONFIGURATION AND MANAGEMENT PROCEDURES
    --------------------------------------------------------------------------

    FUNCTION get_validation_runtime(
        p_instance_name VARCHAR2,
        p_environment_name VARCHAR2
    ) RETURN t_validation_runtime IS
    BEGIN
        RETURN load_validation_runtime(p_instance_name, p_environment_name);
    END get_validation_runtime;

    PROCEDURE set_validation_monitoring(
        p_instance_name VARCHAR2,
        p_enabled NUMBER
    ) IS
        l_rows_updated NUMBER;
    BEGIN
        UPDATE db_validation_instances 
        SET is_enabled = p_enabled
        WHERE instance_name = p_instance_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20030, 'Validation instance not found: ' || p_instance_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Validation monitoring ' || 
                        CASE WHEN p_enabled = 1 THEN 'enabled' ELSE 'disabled' END || 
                        ' for: ' || p_instance_name,
            p_system => 'PLT_DB_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END set_validation_monitoring;

    PROCEDURE add_validation_instance(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2,
        p_instance_description VARCHAR2,
        p_target_identifier VARCHAR2,
        p_enabled NUMBER DEFAULT 0
    ) IS
    BEGIN
        INSERT INTO db_validation_instances (
            validation_type_code,
            instance_name,
            instance_description,
            target_identifier,
            is_enabled,
            consecutive_failures
        ) VALUES (
            p_validation_type_code,
            p_instance_name,
            p_instance_description,
            p_target_identifier,
            p_enabled,
            0
        );

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Validation instance added: ' || p_instance_name || ' (' || p_validation_type_code || ')',
            p_system => 'PLT_DB_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            RAISE_APPLICATION_ERROR(-20031, 'Validation instance already exists: ' || p_instance_name);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END add_validation_instance;

    PROCEDURE remove_validation_instance(p_instance_name VARCHAR2) IS
        l_rows_deleted NUMBER;
    BEGIN
        DELETE FROM db_validation_instances 
        WHERE instance_name = p_instance_name;
        
        l_rows_deleted := SQL%ROWCOUNT;
        
        IF l_rows_deleted = 0 THEN
            RAISE_APPLICATION_ERROR(-20032, 'Validation instance not found: ' || p_instance_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'WARN',
            p_message => 'Validation instance removed: ' || p_instance_name,
            p_system => 'PLT_DB_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END remove_validation_instance;

    PROCEDURE update_validation_instance(
        p_instance_name VARCHAR2,
        p_instance_description VARCHAR2 DEFAULT NULL,
        p_target_identifier VARCHAR2 DEFAULT NULL
    ) IS
        l_rows_updated NUMBER;
    BEGIN
        UPDATE db_validation_instances 
        SET instance_description = NVL(p_instance_description, instance_description),
            target_identifier = NVL(p_target_identifier, target_identifier)
        WHERE instance_name = p_instance_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20033, 'Validation instance not found: ' || p_instance_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Validation instance updated: ' || p_instance_name,
            p_system => 'PLT_DB_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END update_validation_instance;

    PROCEDURE reset_validation_failures(p_instance_name VARCHAR2) IS
        l_rows_updated NUMBER;
    BEGIN
        UPDATE db_validation_instances 
        SET consecutive_failures = 0
        WHERE instance_name = p_instance_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20034, 'Validation instance not found: ' || p_instance_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'WARN',
            p_message => 'Failure counters reset for validation instance: ' || p_instance_name,
            p_system => 'PLT_DB_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END reset_validation_failures;

    PROCEDURE update_validation_thresholds(
        p_validation_type_code VARCHAR2,
        p_environment_name VARCHAR2,
        p_warning_threshold NUMBER DEFAULT NULL,
        p_critical_threshold NUMBER DEFAULT NULL,
        p_check_interval_minutes NUMBER DEFAULT NULL
    ) IS
        l_rows_updated NUMBER;
    BEGIN
        UPDATE db_validation_rules 
        SET warning_threshold = NVL(p_warning_threshold, warning_threshold),
            critical_threshold = NVL(p_critical_threshold, critical_threshold),
            check_interval_minutes = NVL(p_check_interval_minutes, check_interval_minutes)
        WHERE validation_type_code = p_validation_type_code
          AND environment_name = p_environment_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20035, 'Validation rule not found: ' || p_validation_type_code || ' (' || p_environment_name || ')');
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Validation thresholds updated: ' || p_validation_type_code || ' (' || p_environment_name || ')',
            p_system => 'PLT_DB_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END update_validation_thresholds;

    --------------------------------------------------------------------------
    -- AUTO-POPULATION PROCEDURES
    --------------------------------------------------------------------------

    PROCEDURE auto_populate_tablespace_instances(
        p_exclude_temp_tablespaces BOOLEAN DEFAULT TRUE
    ) IS
        l_count NUMBER := 0;
        l_exists NUMBER;
    BEGIN
        FOR rec IN (
            SELECT tablespace_name, 
                   CASE contents 
                       WHEN 'PERMANENT' THEN 'Permanent tablespace'
                       WHEN 'TEMPORARY' THEN 'Temporary tablespace'
                       WHEN 'UNDO' THEN 'Undo tablespace'
                       ELSE 'Unknown tablespace type'
                   END as description,
                   contents
            FROM dba_tablespaces
            WHERE (NOT p_exclude_temp_tablespaces OR contents != 'TEMPORARY')
            ORDER BY tablespace_name
        ) LOOP
            -- Check if instance already exists
            SELECT COUNT(*)
            INTO l_exists
            FROM db_validation_instances
            WHERE validation_type_code = 'TABLESPACE_USAGE'
              AND target_identifier = rec.tablespace_name;

            IF l_exists = 0 THEN
                INSERT INTO db_validation_instances (
                    validation_type_code,
                    instance_name,
                    instance_description,
                    target_identifier,
                    is_enabled
                ) VALUES (
                    'TABLESPACE_USAGE',
                    rec.tablespace_name || '_TABLESPACE',
                    rec.description || ' usage monitoring',
                    rec.tablespace_name,
                    0  -- DISABLED by default
                );
                l_count := l_count + 1;
            END IF;
        END LOOP;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Auto-populated ' || l_count || ' tablespace validation instances (all disabled)',
            p_system => 'PLT_DB_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END auto_populate_tablespace_instances;

    PROCEDURE auto_populate_job_instances(
        p_exclude_system_jobs BOOLEAN DEFAULT TRUE
    ) IS
        l_count NUMBER := 0;
        l_exists NUMBER;
    BEGIN
        FOR rec IN (
            SELECT job_name,
                   'Scheduler job: ' || NVL(comments, job_name) as description,
                   owner
            FROM dba_scheduler_jobs
            WHERE enabled = 'TRUE'
              AND (NOT p_exclude_system_jobs OR owner NOT IN ('SYS', 'SYSTEM', 'ORACLE_OCM', 'DBSNMP'))
            ORDER BY owner, job_name
        ) LOOP
            -- Check if instance already exists
            SELECT COUNT(*)
            INTO l_exists
            FROM db_validation_instances
            WHERE validation_type_code = 'FAILED_JOBS'
              AND target_identifier = rec.job_name;

            IF l_exists = 0 THEN
                INSERT INTO db_validation_instances (
                    validation_type_code,
                    instance_name,
                    instance_description,
                    target_identifier,
                    is_enabled
                ) VALUES (
                    'FAILED_JOBS',
                    'JOB_' || rec.job_name,
                    rec.description,
                    rec.job_name,
                    0  -- DISABLED by default
                );
                l_count := l_count + 1;
            END IF;
        END LOOP;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Auto-populated ' || l_count || ' job validation instances (all disabled)',
            p_system => 'PLT_DB_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END auto_populate_job_instances;

    

    /**
    * Fixed PGA Memory Usage - using "PGA used" metric from V$METRIC
    */
    FUNCTION validate_pga_memory_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(AVG(value/1024/1024), 2), 0) as pga_usage_mb
            FROM v$metric
            WHERE metric_name = 'PGA used'
            AND ROWNUM <= 1
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_pga_memory_usage'
        );
    END validate_pga_memory_usage;

    /**
    * Fixed UGA Memory Usage - Oracle 23ai doesn't expose UGA metrics in V$METRIC
    * Alternative: Use session count as a proxy or disable this validation
    */
    FUNCTION validate_uga_memory_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT -1 as uga_not_available FROM dual
        ]';
        l_result t_validation_result;
    BEGIN
        -- UGA metrics not available in Oracle 23ai V$METRIC
        -- Return -1 to indicate this validation is not supported
        l_result := execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_uga_memory_usage'
        );
        
        -- Override the result to indicate unsupported
        l_result.current_value := -1;
        l_result.status := 'UNSUPPORTED';
        l_result.error_details := 'UGA memory metrics not available in Oracle 23ai V$METRIC';
        
        RETURN l_result;
    END validate_uga_memory_usage;

    /**
    * Fixed Memory Sorts Count - using "Memory Sorts Ratio" from V$METRIC
    */
    FUNCTION validate_memory_sorts_count(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(AVG(value), 2), 0) as memory_sorts_ratio_pct
            FROM v$metric
            WHERE metric_name = 'Memory Sorts Ratio'
            AND ROWNUM <= 1
        ]';
    BEGIN
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_memory_sorts_count'
        );
    END validate_memory_sorts_count;

    /**
    * Fixed Work Area Memory Allocated - Oracle 23ai doesn't expose this in V$METRIC
    * Alternative: Use PGA used as proxy or disable this validation
    */
    FUNCTION validate_workarea_memory_allocated(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(AVG(value/1024/1024), 2), 0) as pga_proxy_mb
            FROM v$metric
            WHERE metric_name = 'PGA used'
            AND ROWNUM <= 1
        ]';
    BEGIN
        -- Use PGA used as a proxy for work area memory
        RETURN execute_validation_with_telemetry(
            p_instance_name => p_instance_name,
            p_environment_name => p_environment_name,
            p_trace_id => p_trace_id,
            p_validation_query => l_query,
            p_operation_name => 'validate_workarea_memory_allocated'
        );
    END validate_workarea_memory_allocated;



    --------------------------------------------------------------------------
    -- REPORTING FUNCTION - USING NATIVE JSON FUNCTIONS
    --------------------------------------------------------------------------

    FUNCTION generate_monitoring_report(
        p_hours_back NUMBER DEFAULT 24,
        p_environment_name VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        l_report CLOB;
        l_environment VARCHAR2(10);
        l_json_obj JSON_OBJECT_T;
        l_instances_array JSON_ARRAY_T;
        l_instance_obj JSON_OBJECT_T;
    BEGIN
        l_environment := NVL(p_environment_name, detect_environment());
        
        -- Create main JSON object using native functions
        l_json_obj := JSON_OBJECT_T();
        l_json_obj.put('report_timestamp', TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
        l_json_obj.put('hours_back', p_hours_back);
        l_json_obj.put('environment', l_environment);
        
        -- Create instances array
        l_instances_array := JSON_ARRAY_T();
        
        -- Add validation instance details using native JSON
        FOR rec IN (
            SELECT 
                i.instance_name,
                i.validation_type_code,
                i.instance_description,
                i.target_identifier,
                i.is_enabled,
                i.last_check_time,
                i.last_check_status,
                i.last_check_value,
                i.consecutive_failures,
                r.warning_threshold,
                r.critical_threshold,
                r.threshold_unit,
                r.check_interval_minutes
            FROM db_validation_instances i
            JOIN db_validation_rules r ON i.validation_type_code = r.validation_type_code 
                                       AND r.environment_name = l_environment
            ORDER BY i.validation_type_code, i.instance_name
        ) LOOP
            l_instance_obj := JSON_OBJECT_T();
            l_instance_obj.put('instance_name', rec.instance_name);
            l_instance_obj.put('validation_type', rec.validation_type_code);
            l_instance_obj.put('description', rec.instance_description);
            l_instance_obj.put('target_identifier', rec.target_identifier);
            l_instance_obj.put('enabled', CASE WHEN rec.is_enabled = 1 THEN 'true' ELSE 'false' END);
            l_instance_obj.put('warning_threshold', rec.warning_threshold);
            l_instance_obj.put('critical_threshold', rec.critical_threshold);
            l_instance_obj.put('threshold_unit', rec.threshold_unit);
            l_instance_obj.put('check_interval_minutes', rec.check_interval_minutes);
            l_instance_obj.put('last_check_time', 
                CASE WHEN rec.last_check_time IS NOT NULL 
                     THEN TO_CHAR(rec.last_check_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"')
                     ELSE 'never'
                END);
            l_instance_obj.put('last_check_status', NVL(rec.last_check_status, 'UNKNOWN'));
            l_instance_obj.put('last_check_value', rec.last_check_value);
            l_instance_obj.put('consecutive_failures', rec.consecutive_failures);
            
            l_instances_array.append(l_instance_obj);
        END LOOP;
        
        l_json_obj.put('validation_instances', l_instances_array);
        
        -- Convert to CLOB
        l_report := l_json_obj.to_clob();
        
        RETURN l_report;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Return error report using native JSON
            l_json_obj := JSON_OBJECT_T();
            l_json_obj.put('report_timestamp', TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'));
            l_json_obj.put('environment', l_environment);
            l_json_obj.put('error', 'Report generation failed');
            l_json_obj.put('error_details', 
                SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            
            RETURN l_json_obj.to_clob();
    END generate_monitoring_report;

END PLT_DB_MONITOR;
/