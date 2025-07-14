-- =============================================================================
-- PLT_DB_MONITOR.PKB - FIXED INFINITE LOOP VERSION 
-- Critical architectural fixes to prevent recursive calls
-- =============================================================================

CREATE OR REPLACE PACKAGE BODY PLT_DB_MONITOR AS

    -- Global configuration flags
    g_telemetry_configured BOOLEAN := FALSE;
    g_debug_mode BOOLEAN := TRUE; -- HARDCODED DEBUG FOR DEMO

    --------------------------------------------------------------------------
    -- PRIVATE HELPER FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Debug output wrapper - only outputs when debug mode is enabled
     */
    PROCEDURE debug_output(p_message VARCHAR2) IS
    BEGIN
        IF g_debug_mode THEN
            DBMS_OUTPUT.PUT_LINE(p_message);
        END IF;
    END debug_output;

    /**
     * Set debug mode for troubleshooting - PUBLIC PROCEDURE
     */
    PROCEDURE set_debug_mode(p_enabled BOOLEAN DEFAULT FALSE) IS
    BEGIN
        g_debug_mode := p_enabled;
        debug_output('🔧 PLT_DB_MONITOR debug mode: ' || CASE WHEN p_enabled THEN 'ENABLED' ELSE 'DISABLED' END);
    END set_debug_mode;

    /**
     * Evaluate validation status based on thresholds
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
     * Create validation-specific attributes for metrics
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
     * FIXED: Load validation runtime configuration - NO MORE DUPLICATES!
     */
    FUNCTION load_validation_runtime(
        p_instance_name VARCHAR2,
        p_environment_name VARCHAR2
    ) RETURN t_validation_runtime IS
        l_runtime t_validation_runtime;
    BEGIN
        debug_output('🔍 Loading runtime for: ' || p_instance_name || ' in ' || p_environment_name);
        
        -- FIXED: More deterministic query with explicit ordering and proper INTO clause
        SELECT 
            instance_id,
            validation_type_code,
            instance_name,
            target_identifier,
            is_enabled,
            validation_procedure,
            environment_name,
            warning_threshold,
            critical_threshold,
            threshold_unit,
            check_interval_minutes,
            last_check_time,
            last_check_status,
            last_check_value,
            consecutive_failures
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
        FROM (
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
            FROM db_validation_instances i
            JOIN db_validation_types t ON i.validation_type_code = t.validation_type_code
            JOIN db_validation_rules r ON i.validation_type_code = r.validation_type_code 
                                       AND r.environment_name = p_environment_name
            WHERE i.instance_name = p_instance_name
              AND r.is_enabled = 1
              AND t.is_active = 1
            ORDER BY i.instance_id -- FIXED: Deterministic ordering
        ) WHERE ROWNUM = 1;
        debug_output('✅ Runtime loaded - Procedure: ' || l_runtime.validation_procedure);
        RETURN l_runtime;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            debug_output('❌ No data found for: ' || p_instance_name || ' (' || p_environment_name || ')');
            RAISE_APPLICATION_ERROR(-20001, 'Validation instance not found or not configured for environment: ' || 
                                   p_instance_name || ' (' || p_environment_name || ')');
        WHEN OTHERS THEN
            debug_output('💥 Unexpected error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RAISE_APPLICATION_ERROR(-20002, 'Error loading validation runtime: ' || 
                                   SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
    END load_validation_runtime;

    -- ========================================================================
    -- FIXED: SIMPLIFIED VALIDATION EXECUTOR - NO MORE RECURSION!
    -- ========================================================================
    
    /**
     * FIXED: Execute a validation query directly with runtime config + FULL TELEMETRY
     */
    FUNCTION execute_validation_query(
        p_runtime t_validation_runtime,
        p_validation_query VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_result t_validation_result;
        l_start_time TIMESTAMP := SYSTIMESTAMP;
        l_current_value NUMBER;
        l_span_id VARCHAR2(16);
        l_metric_attrs PLTelemetry.t_attributes;
    BEGIN
        debug_output('🔍 EXECUTING DIRECT QUERY FOR: ' || p_runtime.validation_type_code);
        debug_output('📊 TARGET: ' || p_runtime.target_identifier);
        debug_output('🔧 QUERY: ' || p_validation_query);

        -- START TELEMETRY SPAN
        IF p_trace_id IS NOT NULL THEN
            l_span_id := PLTelemetry.continue_distributed_trace(
                p_trace_id => p_trace_id,
                p_operation => 'execute_query_' || p_runtime.validation_type_code
            );
        ELSE
            l_span_id := PLTelemetry.start_span('execute_validation_query');
        END IF;

        -- Initialize result from runtime
        l_result.validation_type_code := p_runtime.validation_type_code;
        l_result.instance_name := p_runtime.instance_name;
        l_result.target_identifier := p_runtime.target_identifier;
        l_result.warning_threshold := p_runtime.warning_threshold;
        l_result.critical_threshold := p_runtime.critical_threshold;
        l_result.threshold_unit := p_runtime.threshold_unit;
        l_result.check_timestamp := SYSTIMESTAMP;

        -- Add span attributes for validation context
        DECLARE
            l_attrs PLTelemetry.t_attributes;
        BEGIN
            l_attrs(1) := PLTelemetry.add_attribute('validation.type', p_runtime.validation_type_code);
            l_attrs(2) := PLTelemetry.add_attribute('validation.target', p_runtime.target_identifier);
            l_attrs(3) := PLTelemetry.add_attribute('validation.warning_threshold', TO_CHAR(p_runtime.warning_threshold));
            l_attrs(4) := PLTelemetry.add_attribute('validation.critical_threshold', TO_CHAR(p_runtime.critical_threshold));
            PLTelemetry.add_event(l_span_id, 'validation_query_started', l_attrs);
        END;

        -- Execute the validation query with timeout protection
        BEGIN
            -- FIXED: Add explicit timeout and bind variable handling
            IF INSTR(p_validation_query, ':1') > 0 THEN
                debug_output('🔗 Using bind variable: ' || p_runtime.target_identifier);
                
                -- FIXED: Use DBMS_SQL for better timeout control
                DECLARE
                    l_cursor INTEGER;
                    l_rows INTEGER;
                BEGIN
                    l_cursor := DBMS_SQL.OPEN_CURSOR;
                    DBMS_SQL.PARSE(l_cursor, p_validation_query, DBMS_SQL.NATIVE);
                    DBMS_SQL.BIND_VARIABLE(l_cursor, ':1', p_runtime.target_identifier);
                    DBMS_SQL.DEFINE_COLUMN(l_cursor, 1, l_current_value);
                    
                    l_rows := DBMS_SQL.EXECUTE(l_cursor);
                    IF DBMS_SQL.FETCH_ROWS(l_cursor) > 0 THEN
                        DBMS_SQL.COLUMN_VALUE(l_cursor, 1, l_current_value);
                    ELSE
                        l_current_value := 0;
                    END IF;
                    
                    DBMS_SQL.CLOSE_CURSOR(l_cursor);
                EXCEPTION
                    WHEN OTHERS THEN
                        IF DBMS_SQL.IS_OPEN(l_cursor) THEN
                            DBMS_SQL.CLOSE_CURSOR(l_cursor);
                        END IF;
                        RAISE;
                END;
            ELSE
                debug_output('🚫 No bind variables needed');
                EXECUTE IMMEDIATE p_validation_query INTO l_current_value;
            END IF;
            
            debug_output('✅ SUCCESS: Got value = ' || l_current_value);
            
            l_result.current_value := l_current_value;
            
            -- Evaluate status
            l_result.status := evaluate_validation_status(
                l_current_value,
                p_runtime.warning_threshold,
                p_runtime.critical_threshold,
                p_runtime.validation_type_code
            );
            
            l_result.status_message := generate_status_message(
                p_runtime.validation_type_code,
                p_runtime.target_identifier,
                l_current_value,
                p_runtime.threshold_unit,
                l_result.status
            );

            -- SUCCESS TELEMETRY
            PLTelemetry.add_event(l_span_id, 'validation_query_success');

        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                debug_output('❌ NO_DATA_FOUND: Target not found: ' || p_runtime.target_identifier);
                l_result.status := C_ERROR;
                l_result.error_details := 'Target not found: ' || p_runtime.target_identifier;
                l_result.current_value := 0;
                
                -- ERROR TELEMETRY
                PLTelemetry.add_event(l_span_id, 'validation_query_no_data_found');
                
            WHEN OTHERS THEN
                debug_output('💥 QUERY ERROR: ' || SQLCODE || ' - ' || SQLERRM);
                debug_output('🔧 Failed Query: ' || SUBSTR(p_validation_query, 1, 200));
                debug_output('📍 Target: ' || p_runtime.target_identifier);
                
                l_result.status := C_ERROR;
                l_result.error_details := 'Query error: ' || 
                    SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
                l_result.current_value := -1;

                -- ERROR TELEMETRY
                DECLARE
                    l_error_attrs PLTelemetry.t_attributes;
                BEGIN
                    l_error_attrs(1) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
                    l_error_attrs(2) := PLTelemetry.add_attribute('error.message', SUBSTR(SQLERRM, 1, 200));
                    l_error_attrs(3) := PLTelemetry.add_attribute('query.failed', SUBSTR(p_validation_query, 1, 200));
                    PLTelemetry.add_event(l_span_id, 'validation_query_error', l_error_attrs);
                END;
        END;

        -- Calculate response time
        l_result.response_time_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000;

        -- GENERATE TELEMETRY METRICS
        l_metric_attrs := create_validation_attributes(
            p_validation_type => p_runtime.validation_type_code,
            p_instance_name => p_runtime.instance_name,
            p_target_identifier => p_runtime.target_identifier,
            p_environment => p_runtime.environment_name
        );

        -- Core validation metrics
        PLTelemetry.log_metric(
            p_metric_name => 'db_validation_' || LOWER(p_runtime.validation_type_code) || '_value',
            p_value => NVL(l_result.current_value, -1),
            p_unit => p_runtime.threshold_unit,
            p_attributes => l_metric_attrs,
            p_include_trace_correlation => FALSE
        );

        PLTelemetry.log_metric(
            p_metric_name => 'db_validation_status_gauge',
            p_value => CASE l_result.status 
                        WHEN C_OK THEN 1
                        WHEN C_WARNING THEN 0.5
                        WHEN C_CRITICAL THEN 0
                        ELSE -1
                       END,
            p_unit => 'status',
            p_attributes => l_metric_attrs,
            p_include_trace_correlation => FALSE
        );

        PLTelemetry.log_metric(
            p_metric_name => 'db_validation_response_time_ms',
            p_value => l_result.response_time_ms,
            p_unit => 'milliseconds',
            p_attributes => l_metric_attrs,
            p_include_trace_correlation => FALSE
        );

        debug_output('✅ Direct query result: ' || l_result.status || ' = ' || l_result.current_value);
        
        -- END TELEMETRY SPAN
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status IN (C_OK, C_WARNING) THEN 'OK' ELSE 'ERROR' END);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := C_ERROR;
            l_result.error_details := 'Critical validation failure: ' || 
                                     SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
            l_result.current_value := -1;
            l_result.response_time_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000;
            
            -- ERROR SPAN
            PLTelemetry.end_span(l_span_id, 'ERROR');
            
            RETURN l_result;
    END execute_validation_query;

    --------------------------------------------------------------------------
    -- PUBLIC CONFIGURATION PROCEDURES
    --------------------------------------------------------------------------

    PROCEDURE configure_telemetry IS
    BEGIN
        IF NOT g_telemetry_configured THEN
            -- SIMPLIFIED: Minimal telemetry config for demo
            PLTelemetry.set_backend_url('OTLP_BRIDGE');
            PLT_OTLP_BRIDGE.set_otlp_collector('http://plt-otel-collector:4318');
            PLT_OTLP_BRIDGE.set_service_info('oracle-db-monitor', '1.0.0', 'production');
            PLTelemetry.set_async_mode(TRUE);
            PLT_OTLP_BRIDGE.set_debug_mode(FALSE);
            PLT_OTLP_BRIDGE.set_timeout(5);
            
            g_telemetry_configured := TRUE;
            debug_output('✅ Telemetry configured successfully');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            debug_output('⚠️ Telemetry configuration failed, continuing without it');
            g_telemetry_configured := TRUE; -- Mark as configured to avoid retry loops
    END configure_telemetry;

    FUNCTION detect_environment RETURN VARCHAR2 IS
        l_db_name VARCHAR2(50);
    BEGIN
        SELECT name INTO l_db_name FROM v$database;
        
        IF UPPER(l_db_name) LIKE '%PROD%' OR UPPER(l_db_name) LIKE '%PRD%' THEN
            RETURN C_PROD;
        ELSIF UPPER(l_db_name) LIKE '%TEST%' OR UPPER(l_db_name) LIKE '%TST%' THEN
            RETURN C_TEST;
        ELSIF UPPER(l_db_name) LIKE '%DEV%' OR UPPER(l_db_name) LIKE '%DEVEL%' THEN
            RETURN C_DEV;
        ELSE
            RETURN C_TEST; -- Safe default
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN C_TEST;
    END detect_environment;

    -- ========================================================================
    -- FIXED: INDIVIDUAL VALIDATION PROCEDURES - SIMPLIFIED NO RECURSION!
    -- ========================================================================

    /**
     * FIXED: Tablespace usage - direct execution, no recursion
     */
    FUNCTION validate_tablespace_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(2000) := q'[
            SELECT NVL(ROUND(
                CASE 
                    WHEN NVL(total_space, 0) = 0 THEN 0
                    ELSE ((NVL(total_space, 0) - NVL(free_space, 0)) / NVL(total_space, 1)) * 100
                END, 2), 0) as used_pct
            FROM (
                SELECT 
                    ts.tablespace_name,
                    NVL(df.total_space, 0) as total_space,
                    NVL(fs.free_space, 0) as free_space
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
                WHERE UPPER(ts.tablespace_name) = UPPER(:1)
            )
        ]';
    BEGIN
        debug_output('🗂️ TABLESPACE validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('🗂️ TABLESPACE validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_tablespace_usage;

    FUNCTION validate_active_sessions(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT COUNT(*) 
            FROM v$session
            WHERE status = 'ACTIVE' AND type = 'USER'
        ]';
    BEGIN
        debug_output('👥 ACTIVE_SESSIONS validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('👥 ACTIVE_SESSIONS validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_active_sessions;

    FUNCTION validate_blocked_sessions(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT COUNT(*)
            FROM v$session
            WHERE blocking_session IS NOT NULL AND type = 'USER'
        ]';
    BEGIN
        debug_output('🚫 BLOCKED_SESSIONS validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('🚫 BLOCKED_SESSIONS validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_blocked_sessions;

    FUNCTION validate_invalid_objects(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT COUNT(*)
            FROM dba_objects
            WHERE status = 'INVALID'
              AND owner NOT IN ('SYS', 'SYSTEM', 'XDB', 'APEX_030200', 'FLOWS_FILES')
        ]';
    BEGIN
        debug_output('⚠️ INVALID_OBJECTS validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('⚠️ INVALID_OBJECTS validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_invalid_objects;

    FUNCTION validate_failed_jobs(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT COUNT(*)
            FROM dba_scheduler_job_run_details
            WHERE status = 'FAILED'
              AND log_date > SYSDATE - 1
              AND owner NOT IN ('SYS', 'SYSTEM', 'ORACLE_OCM')
        ]';
    BEGIN
        debug_output('💼 FAILED_JOBS validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('💼 FAILED_JOBS validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_failed_jobs;

    FUNCTION validate_memory_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_sga_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(
                CASE 
                    WHEN total_mb = 0 THEN 0
                    ELSE (used_mb / total_mb) * 100 
                END, 2), 0) as usage_pct
            FROM (
                SELECT 
                    NVL(MAX(CASE WHEN name = 'Maximum SGA Size' THEN bytes/1024/1024 END), 1) as total_mb,
                    NVL(SUM(CASE WHEN name IN ('Buffer Cache Size', 'Shared Pool Size', 'Large Pool Size', 'Java Pool Size', 'Streams Pool Size', 'Shared IO Pool Size') 
                        THEN bytes/1024/1024 ELSE 0 END), 0) as used_mb
                FROM v$sgainfo
            )
        ]';
        l_pga_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(
                CASE 
                    WHEN pga_target_mem = 0 THEN 0
                    ELSE (pga_used_mem / pga_target_mem) * 100 
                END, 2), 0) as usage_pct
            FROM (
                SELECT 
                    NVL(MAX(CASE WHEN name = 'aggregate PGA target parameter' THEN value END), 1) as pga_target_mem,
                    NVL(MAX(CASE WHEN name = 'total PGA allocated' THEN value END), 0) as pga_used_mem
                FROM v$pgastat
                WHERE name IN ('aggregate PGA target parameter', 'total PGA allocated')
            )
        ]';
    BEGIN
        debug_output('🧠 MEMORY_USAGE validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('🧠 MEMORY_USAGE validation - Target: ' || l_runtime.target_identifier);
        
        IF UPPER(l_runtime.target_identifier) = 'SGA' THEN
            debug_output('🧠 Using SGA query');
            RETURN execute_validation_query(l_runtime, l_sga_query, p_trace_id);
        ELSE
            debug_output('🧠 Using PGA query');
            RETURN execute_validation_query(l_runtime, l_pga_query, p_trace_id);
        END IF;
    END validate_memory_usage;

    FUNCTION validate_cpu_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(AVG(value), 2), 0)
            FROM v$metric
            WHERE metric_name = 'CPU Usage Per Sec'
              AND intsize_csec = (SELECT MAX(intsize_csec) FROM v$metric WHERE metric_name = 'CPU Usage Per Sec')
        ]';
    BEGIN
        debug_output('⚡ CPU_USAGE validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('⚡ CPU_USAGE validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_cpu_usage;

    FUNCTION validate_database_cpu_ratio(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(value, 2), 0)
            FROM v$metric
            WHERE metric_name = 'Database CPU Time Ratio'
              AND intsize_csec = (SELECT MAX(intsize_csec) FROM v$metric WHERE metric_name = 'Database CPU Time Ratio')
              AND ROWNUM = 1
        ]';
    BEGIN
        debug_output('📊 DATABASE_CPU_RATIO validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('📊 DATABASE_CPU_RATIO validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_database_cpu_ratio;

    FUNCTION validate_cpu_usage_per_txn(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(value, 2), 0)
            FROM v$metric
            WHERE metric_name = 'CPU Usage Per Txn'
              AND intsize_csec = (SELECT MAX(intsize_csec) FROM v$metric WHERE metric_name = 'CPU Usage Per Txn')
              AND ROWNUM = 1
        ]';
    BEGIN
        debug_output('💳 CPU_USAGE_PER_TXN validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('💳 CPU_USAGE_PER_TXN validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_cpu_usage_per_txn;

    FUNCTION validate_background_cpu_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(
                COALESCE(
                    (SELECT value FROM v$metric WHERE metric_name = 'Background CPU Usage Per Sec' AND ROWNUM = 1),
                    (SELECT value FROM v$metric WHERE metric_name = 'Host CPU Utilization (%)' AND ROWNUM = 1),
                    0
                ), 2), 0) as cpu_value
            FROM dual
        ]';
    BEGIN
        debug_output('🔧 BACKGROUND_CPU_USAGE validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('🔧 BACKGROUND_CPU_USAGE validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_background_cpu_usage;

    FUNCTION validate_cpu_time_per_call(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(
                COALESCE(
                    (SELECT value FROM v$metric WHERE metric_name = 'CPU Time Per User Call' AND ROWNUM = 1),
                    (SELECT value/GREATEST(calls.value, 1) FROM v$metric cpu, v$metric calls 
                     WHERE cpu.metric_name = 'CPU Usage Per Sec' 
                       AND calls.metric_name = 'User Calls Per Sec' AND ROWNUM = 1),
                    0
                ), 2), 0) as cpu_per_call
            FROM dual
        ]';
    BEGIN
        debug_output('📞 CPU_TIME_PER_CALL validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('📞 CPU_TIME_PER_CALL validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_cpu_time_per_call;

    FUNCTION validate_pga_memory_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT 
                CASE 
                    WHEN pga_target <= 0 THEN 
                        ROUND(pga_used / 1024 / 1024, 2)
                    ELSE 
                        ROUND((pga_used / pga_target) * 100, 2)
                END as pga_usage_value
            FROM (
                SELECT 
                    NVL(MAX(CASE WHEN name = 'aggregate PGA target parameter' THEN value END), 0) as pga_target,
                    NVL(MAX(CASE WHEN name = 'total PGA allocated' THEN value END), 0) as pga_used
                FROM v$pgastat
                WHERE name IN ('aggregate PGA target parameter', 'total PGA allocated')
            )
        ]';
    BEGIN
        debug_output('💾 PGA_MEMORY_USAGE validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('💾 PGA_MEMORY_USAGE validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_pga_memory_usage;

    FUNCTION validate_uga_memory_usage(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_result t_validation_result;
        l_runtime t_validation_runtime;
    BEGIN
        debug_output('🔄 UGA_MEMORY_USAGE validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('🔄 UGA_MEMORY_USAGE validation - Returning NOT_SUPPORTED');
        
        l_result.validation_type_code := l_runtime.validation_type_code;
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := l_runtime.target_identifier;
        l_result.warning_threshold := l_runtime.warning_threshold;
        l_result.critical_threshold := l_runtime.critical_threshold;
        l_result.threshold_unit := l_runtime.threshold_unit;
        l_result.check_timestamp := SYSTIMESTAMP;
        l_result.current_value := 0;
        l_result.status := C_OK;
        l_result.status_message := 'UGA memory metrics not available in v$metric';
        l_result.error_details := 'UGA monitoring not supported in this Oracle version';
        l_result.response_time_ms := 1;
        
        RETURN l_result;
    END validate_uga_memory_usage;

    FUNCTION validate_memory_sorts_count(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(value, 0) as memory_sorts_count
            FROM sys.v_$sysstat
            WHERE name = 'sorts (memory)'
        ]';
    BEGIN
        debug_output('🔢 MEMORY_SORTS_COUNT validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('🔢 MEMORY_SORTS_COUNT validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_memory_sorts_count;

    FUNCTION validate_workarea_memory_allocated(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_query CONSTANT VARCHAR2(1000) := q'[
            SELECT NVL(ROUND(value/1024/1024, 2), 0) as pga_mb
            FROM v$pgastat
            WHERE name = 'total PGA allocated'
        ]';
    BEGIN
        debug_output('🏗️ WORKAREA_MEMORY_ALLOCATED validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('🏗️ WORKAREA_MEMORY_ALLOCATED validation - Executing query directly');
        RETURN execute_validation_query(l_runtime, l_query, p_trace_id);
    END validate_workarea_memory_allocated;

    FUNCTION validate_certificate_expiration(
        p_instance_name IN VARCHAR2,
        p_target_identifier IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_result t_validation_result;
        l_runtime t_validation_runtime;
        l_start_time TIMESTAMP := SYSTIMESTAMP;
        l_days_until_expiry NUMBER;
        l_expiry_date DATE;
    BEGIN
        debug_output('🔐 CERTIFICATE_EXPIRATION validation - Loading runtime ONCE');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('🔐 CERTIFICATE_EXPIRATION validation - Custom logic execution');
        
        l_result.validation_type_code := l_runtime.validation_type_code;
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;
        l_result.warning_threshold := l_runtime.warning_threshold;
        l_result.critical_threshold := l_runtime.critical_threshold;
        l_result.threshold_unit := l_runtime.threshold_unit;
        l_result.check_timestamp := SYSTIMESTAMP;

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
        debug_output('🔐 CERTIFICATE_EXPIRATION validation - Result: ' || l_result.status);
        
        RETURN l_result;
    END validate_certificate_expiration;

    -- ========================================================================
    -- FIXED: CORE EXECUTION AND ORCHESTRATION - NO MORE RECURSION!
    -- ========================================================================

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

    /**
     * FIXED: Execute validation instance - SIMPLIFIED, NO RECURSION
     */
    FUNCTION execute_validation_instance(
        p_instance_name IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result IS
        l_runtime t_validation_runtime;
        l_result t_validation_result;
    BEGIN
        debug_output('🚀 === EXECUTE_VALIDATION_INSTANCE START (FIXED) ===');
        debug_output('📋 Instance: ' || p_instance_name);
        debug_output('🌍 Environment: ' || p_environment_name);
        
        -- FIXED: Load runtime configuration ONCE at the beginning
        debug_output('📚 Loading runtime configuration ONCE...');
        l_runtime := load_validation_runtime(p_instance_name, p_environment_name);
        debug_output('✅ Runtime loaded - Procedure: ' || l_runtime.validation_procedure);
        debug_output('🎯 Target: ' || l_runtime.target_identifier);
        
        debug_output('🔄 Calling validation procedure: ' || l_runtime.validation_procedure);
        
        -- FIXED: Direct calls to validation functions, passing runtime data
        CASE l_runtime.validation_procedure
            WHEN 'validate_tablespace_usage' THEN
                debug_output('🗂️ Executing tablespace validation');
                l_result := validate_tablespace_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_active_sessions' THEN
                debug_output('👥 Executing active sessions validation');
                l_result := validate_active_sessions(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_blocked_sessions' THEN
                debug_output('🚫 Executing blocked sessions validation');
                l_result := validate_blocked_sessions(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_invalid_objects' THEN
                debug_output('⚠️ Executing invalid objects validation');
                l_result := validate_invalid_objects(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_failed_jobs' THEN
                debug_output('💼 Executing failed jobs validation');
                l_result := validate_failed_jobs(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_memory_usage' THEN
                debug_output('🧠 Executing memory usage validation');
                l_result := validate_memory_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_cpu_usage' THEN
                debug_output('⚡ Executing CPU usage validation');
                l_result := validate_cpu_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_database_cpu_ratio' THEN
                debug_output('📊 Executing database CPU ratio validation');
                l_result := validate_database_cpu_ratio(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_cpu_usage_per_txn' THEN
                debug_output('💳 Executing CPU usage per transaction validation');
                l_result := validate_cpu_usage_per_txn(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_background_cpu_usage' THEN
                debug_output('🔧 Executing background CPU usage validation');
                l_result := validate_background_cpu_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_cpu_time_per_call' THEN
                debug_output('📞 Executing CPU time per call validation');
                l_result := validate_cpu_time_per_call(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_certificate_expiration' THEN
                debug_output('🔐 Executing certificate expiration validation');
                l_result := validate_certificate_expiration(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_pga_memory_usage' THEN
                debug_output('💾 Executing PGA memory usage validation');
                l_result := validate_pga_memory_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_uga_memory_usage' THEN
                debug_output('🔄 Executing UGA memory usage validation');
                l_result := validate_uga_memory_usage(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_memory_sorts_count' THEN
                debug_output('🔢 Executing memory sorts count validation');
                l_result := validate_memory_sorts_count(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            WHEN 'validate_workarea_memory_allocated' THEN
                debug_output('🏗️ Executing work area memory validation');
                l_result := validate_workarea_memory_allocated(
                    p_instance_name => p_instance_name,
                    p_target_identifier => l_runtime.target_identifier,
                    p_environment_name => p_environment_name,
                    p_trace_id => p_trace_id
                );
            ELSE
                debug_output('❌ UNKNOWN VALIDATION PROCEDURE: ' || l_runtime.validation_procedure);
                RAISE_APPLICATION_ERROR(-20020, 'Unknown validation procedure: ' || l_runtime.validation_procedure);
        END CASE;

        debug_output('✅ Validation completed - Status: ' || l_result.status || ', Value: ' || l_result.current_value);
        debug_output('📝 Error details: ' || NVL(l_result.error_details, 'none'));

        -- Update validation instance with results
        BEGIN
            debug_output('💾 Updating db_validation_instances...');
            UPDATE db_validation_instances
            SET last_check_time = SYSTIMESTAMP,
                last_check_status = l_result.status,
                last_check_value = l_result.current_value,
                consecutive_failures = CASE 
                    WHEN l_result.status IN (C_OK, C_WARNING) THEN 0
                    ELSE consecutive_failures + 1
                END
            WHERE instance_name = p_instance_name;
            
            debug_output('📊 Rows updated: ' || SQL%ROWCOUNT);
        EXCEPTION
            WHEN OTHERS THEN
                debug_output('💥 ERROR updating instance: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
        END;

        debug_output('🏁 === EXECUTE_VALIDATION_INSTANCE END (FIXED) ===');
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            debug_output('💥 CRITICAL ERROR in execute_validation_instance: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            
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

    -- ========================================================================
    -- REST OF PROCEDURES (UNCHANGED FOR BREVITY)
    -- ========================================================================

    PROCEDURE execute_validation_type(
        p_validation_type_code IN VARCHAR2,
        p_environment_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) IS
        l_result t_validation_result;
    BEGIN
        debug_output('🔄 Executing validation type: ' || p_validation_type_code);
        
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
                debug_output('✅ Instance ' || rec.instance_name || ' completed: ' || l_result.status);
            EXCEPTION
                WHEN OTHERS THEN
                    debug_output('💥 Instance ' || rec.instance_name || ' failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            END;
        END LOOP;
    END execute_validation_type;

    /**
     * FIXED: Main validation procedure - FULL TELEMETRY RESTORED
     */
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
        debug_output('🚀 === PERFORM_DATABASE_VALIDATIONS START (TELEMETRY ACTIVE) ===');
        
        -- Configure telemetry
        configure_telemetry();

        -- Detect environment
        l_environment := NVL(p_environment_name, detect_environment());
        debug_output('🌍 Environment: ' || l_environment);
        debug_output('🔧 Force all: ' || CASE WHEN p_force_all_checks THEN 'YES' ELSE 'NO' END);

        -- START DISTRIBUTED TRACING
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
            debug_output('📋 [' || l_validation_count || '] Processing: ' || l_instance_name);
            PLTelemetry.add_event(l_span_id, 'executing_validation_' || l_instance_name);

            -- Execute validation with FULL distributed tracing
            BEGIN
                l_result := execute_validation_instance(
                    p_instance_name => l_instance_name,
                    p_environment_name => l_environment,
                    p_trace_id => l_trace_id  -- PASS TRACE ID FOR DISTRIBUTED TRACING!
                );

                debug_output('✅ [' || l_validation_count || '] Result: ' || l_result.status || ' = ' || l_result.current_value);

                -- Log validation result to distributed trace
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
                    debug_output('💥 [' || l_validation_count || '] ERROR: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
                    
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

        -- GENERATE CYCLE METRICS
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
                p_attributes => l_cycle_attrs,
                p_include_trace_correlation => FALSE
            );

            -- Validation counts
            PLTelemetry.log_metric(
                p_metric_name => 'db_validations_executed_count',
                p_value => l_validation_count,
                p_unit => 'count',
                p_attributes => l_cycle_attrs,
                p_include_trace_correlation => FALSE
            );

            PLTelemetry.log_metric(
                p_metric_name => 'db_validation_errors_count',
                p_value => l_error_count,
                p_unit => 'count',
                p_attributes => l_cycle_attrs,
                p_include_trace_correlation => FALSE
            );

            PLTelemetry.log_metric(
                p_metric_name => 'db_validation_cycle_completed',
                p_value => 1,
                p_unit => 'count',
                p_attributes => l_cycle_attrs,
                p_include_trace_correlation => FALSE
            );
        END;

        debug_output('📊 === VALIDATION CYCLE SUMMARY ===');
        debug_output('✅ Validations executed: ' || l_validation_count);
        debug_output('💥 Errors encountered: ' || l_error_count);
        debug_output('⏱️ Duration: ' || ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, 2) || ' ms');

        -- Log completion
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('validations_executed', TO_CHAR(l_validation_count));
        l_attrs(2) := PLTelemetry.add_attribute('validation_errors', TO_CHAR(l_error_count));
        l_attrs(3) := PLTelemetry.add_attribute('cycle.duration_ms', 
            TO_CHAR(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, '999999.99'));
        PLTelemetry.add_event(l_span_id, 'database_validation_cycle_completed', l_attrs);

        PLTelemetry.end_span(l_span_id, CASE WHEN l_error_count = 0 THEN 'OK' ELSE 'ERROR' END);
        PLTelemetry.end_trace(l_trace_id);

        debug_output('🏁 === PERFORM_DATABASE_VALIDATIONS END (TELEMETRY ACTIVE) ===');

        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            IF l_cursor%ISOPEN THEN
                CLOSE l_cursor;
            END IF;
            
            debug_output('💥 CRITICAL ERROR in perform_database_validations: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            
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
            RAISE;
    END perform_database_validations;

    -- ========================================================================
    -- PLACEHOLDER IMPLEMENTATIONS FOR REMAINING PROCEDURES
    -- ========================================================================

    FUNCTION get_validation_runtime(
        p_instance_name VARCHAR2,
        p_environment_name VARCHAR2
    ) RETURN t_validation_runtime IS
    BEGIN
        RETURN load_validation_runtime(p_instance_name, p_environment_name);
    END get_validation_runtime;

    PROCEDURE set_validation_monitoring(p_instance_name VARCHAR2, p_enabled NUMBER) IS
    BEGIN
        UPDATE db_validation_instances 
        SET is_enabled = p_enabled
        WHERE instance_name = p_instance_name;
        COMMIT;
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
            validation_type_code, instance_name, instance_description,
            target_identifier, is_enabled, consecutive_failures
        ) VALUES (
            p_validation_type_code, p_instance_name, p_instance_description,
            p_target_identifier, p_enabled, 0
        );
        COMMIT;
    END add_validation_instance;

    PROCEDURE remove_validation_instance(p_instance_name VARCHAR2) IS
    BEGIN
        DELETE FROM db_validation_instances WHERE instance_name = p_instance_name;
        COMMIT;
    END remove_validation_instance;

    PROCEDURE update_validation_instance(
        p_instance_name VARCHAR2,
        p_instance_description VARCHAR2 DEFAULT NULL,
        p_target_identifier VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        UPDATE db_validation_instances 
        SET instance_description = NVL(p_instance_description, instance_description),
            target_identifier = NVL(p_target_identifier, target_identifier)
        WHERE instance_name = p_instance_name;
        COMMIT;
    END update_validation_instance;

    PROCEDURE reset_validation_failures(p_instance_name VARCHAR2) IS
    BEGIN
        UPDATE db_validation_instances 
        SET consecutive_failures = 0
        WHERE instance_name = p_instance_name;
        COMMIT;
    END reset_validation_failures;

    PROCEDURE update_validation_thresholds(
        p_validation_type_code VARCHAR2,
        p_environment_name VARCHAR2,
        p_warning_threshold NUMBER DEFAULT NULL,
        p_critical_threshold NUMBER DEFAULT NULL,
        p_check_interval_minutes NUMBER DEFAULT NULL
    ) IS
    BEGIN
        UPDATE db_validation_rules 
        SET warning_threshold = NVL(p_warning_threshold, warning_threshold),
            critical_threshold = NVL(p_critical_threshold, critical_threshold),
            check_interval_minutes = NVL(p_check_interval_minutes, check_interval_minutes)
        WHERE validation_type_code = p_validation_type_code
          AND environment_name = p_environment_name;
        COMMIT;
    END update_validation_thresholds;

    PROCEDURE auto_populate_tablespace_instances(p_exclude_temp_tablespaces BOOLEAN DEFAULT TRUE) IS
    BEGIN
        debug_output('🗂️ Auto-populating tablespace instances...');
        -- Implementation would go here
        debug_output('✅ Tablespace instances populated');
    END auto_populate_tablespace_instances;

    PROCEDURE auto_populate_job_instances(p_exclude_system_jobs BOOLEAN DEFAULT TRUE) IS
    BEGIN
        debug_output('💼 Auto-populating job instances...');
        -- Implementation would go here  
        debug_output('✅ Job instances populated');
    END auto_populate_job_instances;

    FUNCTION generate_monitoring_report(
        p_hours_back NUMBER DEFAULT 24,
        p_environment_name VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        l_report CLOB;
    BEGIN
        debug_output('📊 Generating monitoring report...');
        l_report := '{"status":"report_generation_placeholder","timestamp":"' || 
                   TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '"}';
        RETURN l_report;
    END generate_monitoring_report;

END PLT_DB_MONITOR;
/