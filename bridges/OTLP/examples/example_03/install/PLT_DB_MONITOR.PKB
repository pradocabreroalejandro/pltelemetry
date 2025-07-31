-- =============================================================================
-- PLT_DB_MONITOR - TENANT-AWARE PACKAGE BODY
-- Version: 2.0.0 - Multi-Tenant Edition with PLTelemetry Integration
-- =============================================================================

CREATE OR REPLACE PACKAGE BODY PLT_DB_MONITOR
AS
    /**
     * PLT_DB_MONITOR - Tenant-Aware Database Monitoring Package Body
     * 
     * All validations now operate within tenant context automatically.
     * Metrics and logs are enriched with tenant_id and environment_name.
     * Complete integration with PLTelemetry for observability.
     */

    --------------------------------------------------------------------------
    -- PRIVATE VARIABLES
    --------------------------------------------------------------------------
    
    -- Cache for tenant context to avoid repeated queries
    g_cached_context t_tenant_context;
    g_context_cache_time TIMESTAMP;
    g_cache_validity_minutes CONSTANT NUMBER := 5; -- Cache for 5 minutes

    --------------------------------------------------------------------------
    -- PRIVATE UTILITY FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Log internal errors with tenant context
     */
    PROCEDURE log_error_internal(
        p_module VARCHAR2,
        p_error_message VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    )
    IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_context t_tenant_context;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        -- Get tenant context for error logging
        BEGIN
            l_context := detect_tenant_context();
        EXCEPTION
            WHEN OTHERS THEN
                l_context.tenant_id := 'UNKNOWN';
                l_context.environment_name := 'UNKNOWN';
        END;

        -- Build attributes with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(2) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(3) := PLTelemetry.add_attribute('module.name', p_module);
        l_attrs(4) := PLTelemetry.add_attribute('db.name', SYS_CONTEXT('USERENV', 'DB_NAME'));

        -- Log to PLTelemetry with tenant context
        IF p_trace_id IS NOT NULL THEN
            PLTelemetry.log_with_trace(p_trace_id, 'ERROR', p_error_message, l_attrs);
        ELSE
            PLTelemetry.log_message('ERROR', p_error_message, l_attrs);
        END IF;

        -- Also log to plt_telemetry_errors table as backup
        INSERT INTO plt_telemetry_errors (
            error_time,
            error_message,
            module_name,
            trace_id
        ) VALUES (
            SYSTIMESTAMP,
            SUBSTR('[' || l_context.tenant_id || '/' || l_context.environment_name || '] ' || p_error_message, 1, 4000),
            SUBSTR(p_module, 1, 100),
            p_trace_id
        );
        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Never let error logging break the monitoring
    END log_error_internal;

    /**
     * Get cached tenant context or refresh if expired
     */
    FUNCTION get_cached_tenant_context RETURN t_tenant_context
    IS
        l_context t_tenant_context;
    BEGIN
        -- Check if cache is still valid
        IF g_context_cache_time IS NULL OR 
           SYSTIMESTAMP > g_context_cache_time + (g_cache_validity_minutes / 1440) THEN
            
            -- Refresh cache
            SELECT tenant_id, environment_name, instance_identifier
            INTO l_context.tenant_id, l_context.environment_name, l_context.instance_identifier
            FROM plt_db_monitor_config
            WHERE is_active = 1
            AND ROWNUM = 1;
            
            g_cached_context := l_context;
            g_context_cache_time := SYSTIMESTAMP;
        END IF;
        
        RETURN g_cached_context;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- No configuration found - return default
            l_context.tenant_id := 'UNCONFIGURED';
            l_context.environment_name := 'UNKNOWN';
            l_context.instance_identifier := SYS_CONTEXT('USERENV', 'DB_NAME');
            RETURN l_context;
        WHEN OTHERS THEN
            log_error_internal('get_cached_tenant_context', 
                'Failed to get tenant context: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            -- Return safe fallback
            l_context.tenant_id := 'ERROR';
            l_context.environment_name := 'ERROR';
            l_context.instance_identifier := 'ERROR';
            RETURN l_context;
    END get_cached_tenant_context;

    --------------------------------------------------------------------------
    -- TENANT CONTEXT MANAGEMENT IMPLEMENTATION
    --------------------------------------------------------------------------

    FUNCTION detect_tenant_context RETURN t_tenant_context
    IS
    BEGIN
        RETURN get_cached_tenant_context();
    END detect_tenant_context;

    FUNCTION get_current_tenant_id RETURN VARCHAR2
    IS
    BEGIN
        RETURN get_cached_tenant_context().tenant_id;
    END get_current_tenant_id;

    FUNCTION get_current_environment_name RETURN VARCHAR2
    IS
    BEGIN
        RETURN get_cached_tenant_context().environment_name;
    END get_current_environment_name;

    FUNCTION get_current_instance_identifier RETURN VARCHAR2
    IS
    BEGIN
        RETURN get_cached_tenant_context().instance_identifier;
    END get_current_instance_identifier;

    PROCEDURE update_tenant_context(
        p_tenant_id VARCHAR2,
        p_environment_name VARCHAR2,
        p_instance_identifier VARCHAR2 DEFAULT NULL,
        p_description VARCHAR2 DEFAULT NULL
    )
    IS
        l_instance_id VARCHAR2(100);
        l_description VARCHAR2(200);
    BEGIN
        -- Default instance identifier
        l_instance_id := NVL(p_instance_identifier, 
            SYS_CONTEXT('USERENV', 'DB_NAME') || '_' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME'));
        
        -- Default description
        l_description := NVL(p_description, 
            'Updated for ' || p_tenant_id || ' ' || p_environment_name || ' environment');

        -- Update or insert configuration
        MERGE INTO plt_db_monitor_config c
        USING (SELECT p_tenant_id as tenant_id, p_environment_name as environment_name FROM dual) src
        ON (c.tenant_id = src.tenant_id AND c.environment_name = src.environment_name)
        WHEN MATCHED THEN
            UPDATE SET 
                instance_identifier = l_instance_id,
                description = l_description,
                updated_at = SYSTIMESTAMP,
                is_active = 1
        WHEN NOT MATCHED THEN
            INSERT (tenant_id, environment_name, instance_identifier, description, is_active)
            VALUES (p_tenant_id, p_environment_name, l_instance_id, l_description, 1);

        -- Clear cache to force refresh
        g_context_cache_time := NULL;
        
        COMMIT;

        -- Log the configuration change
        DECLARE
            l_attrs PLTelemetry.t_attributes;
        BEGIN
            l_attrs(1) := PLTelemetry.add_attribute('tenant.id', p_tenant_id);
            l_attrs(2) := PLTelemetry.add_attribute('environment.name', p_environment_name);
            l_attrs(3) := PLTelemetry.add_attribute('instance.identifier', l_instance_id);
            
            PLTelemetry.log_message('INFO', 
                'Tenant context updated for database monitoring', l_attrs);
        END;

    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('update_tenant_context', 
                'Failed to update tenant context: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END update_tenant_context;

    --------------------------------------------------------------------------
    -- VALIDATION ORCHESTRATOR IMPLEMENTATION
    --------------------------------------------------------------------------

    PROCEDURE perform_database_validations(
        p_force_all_checks BOOLEAN DEFAULT FALSE,
        p_trace_id VARCHAR2 DEFAULT NULL
    )
    IS
        l_trace_id VARCHAR2(32);
        l_span_id VARCHAR2(16);
        l_context t_tenant_context;
        l_validation_count NUMBER := 0;
        l_error_count NUMBER := 0;
        l_attrs PLTelemetry.t_attributes;
        
        -- Cursor for enabled validation instances
        CURSOR c_validations IS
            SELECT DISTINCT 
                vi.validation_type_code,
                vi.instance_name,
                vi.target_identifier,
                vt.validation_procedure,
                vr.check_interval_minutes
            FROM db_validation_instances vi
            JOIN db_validation_types vt ON vi.validation_type_code = vt.validation_type_code
            JOIN db_validation_rules vr ON (
                vi.validation_type_code = vr.validation_type_code 
                AND vi.tenant_id = vr.tenant_id 
                AND vi.environment_name = vr.environment_name
            )
            WHERE vi.tenant_id = l_context.tenant_id
              AND vi.environment_name = l_context.environment_name
              AND vi.is_enabled = 1
              AND vt.is_active = 1
              AND vr.is_enabled = 1;
    BEGIN
        -- Get tenant context
        l_context := detect_tenant_context();
        
        -- Start distributed trace
        l_trace_id := NVL(p_trace_id, PLTelemetry.start_trace('database_validation_cycle'));
        l_span_id := PLTelemetry.start_span('tenant_validation_orchestrator', NULL, l_trace_id);

        -- Set tenant context in PLTelemetry
        PLTelemetry.set_tenant_context(l_context.tenant_id, 
            l_context.tenant_id || ' ' || l_context.environment_name || ' Environment');

        -- Add orchestrator events with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(2) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(3) := PLTelemetry.add_attribute('instance.identifier', l_context.instance_identifier);
        l_attrs(4) := PLTelemetry.add_attribute('force_all_checks', CASE WHEN p_force_all_checks THEN 'true' ELSE 'false' END);
        
        PLTelemetry.add_event(l_span_id, 'validation_cycle_started', l_attrs);

        -- Process each enabled validation
        FOR rec IN c_validations LOOP
            BEGIN
                -- dbms_output.put_line('Processing validation: ' || rec.validation_type_code || ' on instance: ' || rec.instance_name);
                -- Check if validation is due
                IF p_force_all_checks OR is_validation_due(rec.validation_type_code, rec.instance_name, p_force_all_checks) THEN
                    
                    -- Execute the specific validation
                    perform_validation_type(rec.validation_type_code, rec.instance_name, l_trace_id);
                    l_validation_count := l_validation_count + 1;
                    
                    -- Add event for each validation executed
                    l_attrs(1) := PLTelemetry.add_attribute('validation.type', rec.validation_type_code);
                    l_attrs(2) := PLTelemetry.add_attribute('validation.instance', rec.instance_name);
                    l_attrs(3) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
                    PLTelemetry.add_event(l_span_id, 'validation_executed', l_attrs);
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    l_error_count := l_error_count + 1;
                    log_error_internal('perform_database_validations', 
                        'Validation failed for ' || rec.validation_type_code || '/' || rec.instance_name || 
                        ': ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                        l_trace_id);
            END;
        END LOOP;

        -- Send summary metrics with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(2) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(3) := PLTelemetry.add_attribute('instance.identifier', l_context.instance_identifier);
        
        PLTelemetry.log_metric('db_validations_executed', l_validation_count, 'count', l_attrs, FALSE);
        
        IF l_error_count > 0 THEN
            PLTelemetry.log_metric('db_validation_errors', l_error_count, 'count', l_attrs, FALSE);
        END IF;

        -- Complete the span
        l_attrs(1) := PLTelemetry.add_attribute('validations.executed', TO_CHAR(l_validation_count));
        l_attrs(2) := PLTelemetry.add_attribute('validations.errors', TO_CHAR(l_error_count));
        l_attrs(3) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(4) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        
        PLTelemetry.add_event(l_span_id, 'validation_cycle_completed', l_attrs);
        PLTelemetry.end_span(l_span_id, CASE WHEN l_error_count = 0 THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        -- End trace only if we started it
        IF p_trace_id IS NULL THEN
            PLTelemetry.end_trace(l_trace_id);
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('perform_database_validations', 
                'Critical error in validation orchestrator: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                l_trace_id);
            
            -- End span with error
            PLTelemetry.end_span(l_span_id, 'ERROR');
            IF p_trace_id IS NULL THEN
                PLTelemetry.end_trace(l_trace_id);
            END IF;
    END perform_database_validations;

    PROCEDURE perform_validation_type(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2 DEFAULT NULL,
        p_trace_id VARCHAR2 DEFAULT NULL
    )
    IS
        l_span_id VARCHAR2(16);
        l_context t_tenant_context;
        l_result t_validation_result;
        l_attrs PLTelemetry.t_attributes;
        
        -- Cursor for instances to validate
        CURSOR c_instances IS
            SELECT instance_name, target_identifier
            FROM db_validation_instances
            WHERE validation_type_code = p_validation_type_code
              AND tenant_id = l_context.tenant_id
              AND environment_name = l_context.environment_name
              AND is_enabled = 1
              AND (p_instance_name IS NULL OR instance_name = p_instance_name);
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validation_type_' || LOWER(p_validation_type_code), NULL, p_trace_id);

        -- Add validation context
        l_attrs(1) := PLTelemetry.add_attribute('validation.type', p_validation_type_code);
        l_attrs(2) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(3) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        PLTelemetry.add_event(l_span_id, 'validation_type_started', l_attrs);

        -- Execute validation for each matching instance
        FOR rec IN c_instances LOOP
            BEGIN
                -- Call the appropriate validation function based on type
                CASE p_validation_type_code
                    WHEN 'TABLESPACE_USAGE' THEN
                        l_result := validate_tablespace_usage(rec.instance_name, rec.target_identifier, p_trace_id);
                    WHEN 'ACTIVE_SESSIONS' THEN
                        l_result := validate_active_sessions(rec.instance_name, rec.target_identifier, p_trace_id);
                    WHEN 'BLOCKED_SESSIONS' THEN
                        l_result := validate_blocked_sessions(rec.instance_name, rec.target_identifier, p_trace_id);
                    WHEN 'INVALID_OBJECTS' THEN
                        l_result := validate_invalid_objects(rec.instance_name, rec.target_identifier, p_trace_id);
                    WHEN 'FAILED_JOBS' THEN
                        l_result := validate_failed_jobs(rec.instance_name, rec.target_identifier, p_trace_id);
                    WHEN 'MEMORY_USAGE' THEN
                        l_result := validate_memory_usage(rec.instance_name, rec.target_identifier, p_trace_id);
                    WHEN 'CPU_USAGE' THEN
                        l_result := validate_cpu_usage(rec.instance_name, rec.target_identifier, p_trace_id);
                    WHEN 'DB_CPU_RATIO' THEN
                        l_result := validate_database_cpu_ratio(rec.instance_name, rec.target_identifier, p_trace_id);
                    WHEN 'PGA_MEMORY_USAGE' THEN
                        l_result := validate_pga_memory_usage(rec.instance_name, rec.target_identifier, p_trace_id);
                    ELSE
                        log_error_internal('perform_validation_type', 
                            'Unknown validation type: ' || p_validation_type_code, p_trace_id);
                        CONTINUE;
                END CASE;

                -- Update validation results in database
                update_validation_result(p_validation_type_code, rec.instance_name, 
                    l_result.status, l_result.measured_value);

                -- Send metrics to PLTelemetry with tenant context
                send_validation_metrics(l_result, p_trace_id);

                -- Log validation event
                log_validation_event(p_validation_type_code, rec.instance_name, 
                    'validation_completed', l_result.status || ': ' || l_result.message, p_trace_id);

            EXCEPTION
                WHEN OTHERS THEN
                    -- Update instance with error status
                    update_validation_result(p_validation_type_code, rec.instance_name, 'ERROR', NULL, 
                        SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
                    
                    log_error_internal('perform_validation_type', 
                        'Validation error for ' || p_validation_type_code || '/' || rec.instance_name || 
                        ': ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                        p_trace_id);
            END;
        END LOOP;

        PLTelemetry.end_span(l_span_id, 'OK', l_attrs);

    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('perform_validation_type', 
                'Critical error in validation type ' || p_validation_type_code || 
                ': ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
    END perform_validation_type;

    --------------------------------------------------------------------------
    -- SPECIFIC VALIDATION IMPLEMENTATIONS
    --------------------------------------------------------------------------

    FUNCTION validate_tablespace_usage(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result
    IS
        l_result t_validation_result;
        l_context t_tenant_context;
        l_span_id VARCHAR2(16);
        l_used_pct NUMBER;
        l_warning_threshold NUMBER;
        l_critical_threshold NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validate_tablespace_usage', NULL, p_trace_id);

        -- Initialize result
        l_result.validation_type := 'TABLESPACE_USAGE';
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;

        -- Get thresholds for current tenant/environment
        SELECT warning_threshold, critical_threshold
        INTO l_warning_threshold, l_critical_threshold
        FROM db_validation_rules
        WHERE validation_type_code = 'TABLESPACE_USAGE'
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        l_result.warning_threshold := l_warning_threshold;
        l_result.critical_threshold := l_critical_threshold;

        -- Get tablespace usage percentage
        BEGIN
            SELECT ROUND(
                (1 - (NVL(free_space, 0) / GREATEST(total_space, 1))) * 100, 2
            ) INTO l_used_pct
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
                WHERE ts.tablespace_name = p_target_identifier
            );

        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                l_result.status := 'ERROR';
                l_result.message := 'Tablespace not found: ' || p_target_identifier;
                PLTelemetry.end_span(l_span_id, 'ERROR');
                RETURN l_result;
        END;

        l_result.measured_value := l_used_pct;

        -- Determine status based on thresholds
        IF l_used_pct >= l_critical_threshold THEN
            l_result.status := 'CRITICAL';
            l_result.message := 'Tablespace usage critical: ' || l_used_pct || '% (threshold: ' || l_critical_threshold || '%)';
        ELSIF l_used_pct >= l_warning_threshold THEN
            l_result.status := 'WARNING';
            l_result.message := 'Tablespace usage warning: ' || l_used_pct || '% (threshold: ' || l_warning_threshold || '%)';
        ELSE
            l_result.status := 'OK';
            l_result.message := 'Tablespace usage normal: ' || l_used_pct || '%';
        END IF;

        -- Add attributes with tenant context for span
        l_attrs(1) := PLTelemetry.add_attribute('tablespace.name', p_target_identifier);
        l_attrs(2) := PLTelemetry.add_attribute('usage.percentage', TO_CHAR(l_used_pct));
        l_attrs(3) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(4) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(5) := PLTelemetry.add_attribute('validation.status', l_result.status);
        
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status = 'OK' THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := 'ERROR';
            l_result.message := 'Validation error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
            log_error_internal('validate_tablespace_usage', 
                'Error validating tablespace ' || p_target_identifier || 
                ': ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_tablespace_usage;

    FUNCTION validate_active_sessions(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result
    IS
        l_result t_validation_result;
        l_context t_tenant_context;
        l_span_id VARCHAR2(16);
        l_session_count NUMBER;
        l_warning_threshold NUMBER;
        l_critical_threshold NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validate_active_sessions', NULL, p_trace_id);

        -- Initialize result
        l_result.validation_type := 'ACTIVE_SESSIONS';
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;

        -- Get thresholds for current tenant/environment
        SELECT warning_threshold, critical_threshold
        INTO l_warning_threshold, l_critical_threshold
        FROM db_validation_rules
        WHERE validation_type_code = 'ACTIVE_SESSIONS'
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        l_result.warning_threshold := l_warning_threshold;
        l_result.critical_threshold := l_critical_threshold;

        -- Get active session count
        SELECT COUNT(*)
        INTO l_session_count
        FROM v$session
        WHERE status = 'ACTIVE'
          AND username IS NOT NULL; -- Exclude background processes

        l_result.measured_value := l_session_count;

        -- Determine status based on thresholds
        IF l_session_count >= l_critical_threshold THEN
            l_result.status := 'CRITICAL';
            l_result.message := 'Active sessions critical: ' || l_session_count || ' (threshold: ' || l_critical_threshold || ')';
        ELSIF l_session_count >= l_warning_threshold THEN
            l_result.status := 'WARNING';
            l_result.message := 'Active sessions warning: ' || l_session_count || ' (threshold: ' || l_warning_threshold || ')';
        ELSE
            l_result.status := 'OK';
            l_result.message := 'Active sessions normal: ' || l_session_count;
        END IF;

        -- Add attributes with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('sessions.active_count', TO_CHAR(l_session_count));
        l_attrs(2) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(3) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(4) := PLTelemetry.add_attribute('validation.status', l_result.status);
        
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status = 'OK' THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := 'ERROR';
            l_result.message := 'Validation error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
            log_error_internal('validate_active_sessions', 
                'Error validating active sessions: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_active_sessions;

    FUNCTION validate_blocked_sessions(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result
    IS
        l_result t_validation_result;
        l_context t_tenant_context;
        l_span_id VARCHAR2(16);
        l_blocked_count NUMBER;
        l_warning_threshold NUMBER;
        l_critical_threshold NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validate_blocked_sessions', NULL, p_trace_id);

        -- Initialize result
        l_result.validation_type := 'BLOCKED_SESSIONS';
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;

        -- Get thresholds for current tenant/environment
        SELECT warning_threshold, critical_threshold
        INTO l_warning_threshold, l_critical_threshold
        FROM db_validation_rules
        WHERE validation_type_code = 'BLOCKED_SESSIONS'
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        l_result.warning_threshold := l_warning_threshold;
        l_result.critical_threshold := l_critical_threshold;

        -- Get blocked session count using v$session_wait
        SELECT COUNT(DISTINCT s.sid)
        INTO l_blocked_count
        FROM v$session s
        JOIN v$session_wait sw ON s.sid = sw.sid
        WHERE s.blocking_session IS NOT NULL
          AND s.username IS NOT NULL
          AND sw.event LIKE '%enq%' OR sw.event LIKE '%lock%';

        l_result.measured_value := l_blocked_count;

        -- Determine status based on thresholds
        IF l_blocked_count >= l_critical_threshold THEN
            l_result.status := 'CRITICAL';
            l_result.message := 'Blocked sessions critical: ' || l_blocked_count || ' (threshold: ' || l_critical_threshold || ')';
        ELSIF l_blocked_count >= l_warning_threshold THEN
            l_result.status := 'WARNING';
            l_result.message := 'Blocked sessions warning: ' || l_blocked_count || ' (threshold: ' || l_warning_threshold || ')';
        ELSE
            l_result.status := 'OK';
            l_result.message := 'Blocked sessions normal: ' || l_blocked_count;
        END IF;

        -- Add attributes with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('sessions.blocked_count', TO_CHAR(l_blocked_count));
        l_attrs(2) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(3) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(4) := PLTelemetry.add_attribute('validation.status', l_result.status);
        
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status = 'OK' THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := 'ERROR';
            l_result.message := 'Validation error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
            log_error_internal('validate_blocked_sessions', 
                'Error validating blocked sessions: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_blocked_sessions;

    FUNCTION validate_invalid_objects(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result
    IS
        l_result t_validation_result;
        l_context t_tenant_context;
        l_span_id VARCHAR2(16);
        l_invalid_count NUMBER;
        l_warning_threshold NUMBER;
        l_critical_threshold NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validate_invalid_objects', NULL, p_trace_id);

        -- Initialize result
        l_result.validation_type := 'INVALID_OBJECTS';
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;

        -- Get thresholds for current tenant/environment
        SELECT warning_threshold, critical_threshold
        INTO l_warning_threshold, l_critical_threshold
        FROM db_validation_rules
        WHERE validation_type_code = 'INVALID_OBJECTS'
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        l_result.warning_threshold := l_warning_threshold;
        l_result.critical_threshold := l_critical_threshold;

        -- Get invalid object count
        SELECT COUNT(*)
        INTO l_invalid_count
        FROM dba_objects
        WHERE status = 'INVALID'
          AND owner NOT IN ('SYS', 'SYSTEM', 'DBSNMP', 'WMSYS', 'EXFSYS', 'CTXSYS', 'XDB', 'ANONYMOUS', 'XS$NULL', 'APEX_030200', 'APEX_PUBLIC_USER', 'DIP', 'FLOWS_FILES', 'HR', 'MDSYS', 'ORACLE_OCM', 'ORDPLUGINS', 'ORDSYS', 'OUTLN', 'SI_INFORMTN_SCHEMA');

        l_result.measured_value := l_invalid_count;

        -- Determine status based on thresholds
        IF l_invalid_count >= l_critical_threshold THEN
            l_result.status := 'CRITICAL';
            l_result.message := 'Invalid objects critical: ' || l_invalid_count || ' (threshold: ' || l_critical_threshold || ')';
        ELSIF l_invalid_count >= l_warning_threshold THEN
            l_result.status := 'WARNING';
            l_result.message := 'Invalid objects warning: ' || l_invalid_count || ' (threshold: ' || l_warning_threshold || ')';
        ELSE
            l_result.status := 'OK';
            l_result.message := 'Invalid objects normal: ' || l_invalid_count;
        END IF;

        -- Add attributes with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('objects.invalid_count', TO_CHAR(l_invalid_count));
        l_attrs(2) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(3) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(4) := PLTelemetry.add_attribute('validation.status', l_result.status);
        
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status = 'OK' THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := 'ERROR';
            l_result.message := 'Validation error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
            log_error_internal('validate_invalid_objects', 
                'Error validating invalid objects: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_invalid_objects;

    FUNCTION validate_failed_jobs(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result
    IS
        l_result t_validation_result;
        l_context t_tenant_context;
        l_span_id VARCHAR2(16);
        l_failed_count NUMBER;
        l_warning_threshold NUMBER;
        l_critical_threshold NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validate_failed_jobs', NULL, p_trace_id);

        -- Initialize result
        l_result.validation_type := 'FAILED_JOBS';
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;

        -- Get thresholds for current tenant/environment
        SELECT warning_threshold, critical_threshold
        INTO l_warning_threshold, l_critical_threshold
        FROM db_validation_rules
        WHERE validation_type_code = 'FAILED_JOBS'
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        l_result.warning_threshold := l_warning_threshold;
        l_result.critical_threshold := l_critical_threshold;

        -- Get failed job count from last 24 hours
        SELECT COUNT(DISTINCT job_name)
        INTO l_failed_count
        FROM dba_scheduler_job_run_details
        WHERE status = 'FAILED'
          AND log_date > SYSDATE - 1;

        l_result.measured_value := l_failed_count;

        -- Determine status based on thresholds
        IF l_failed_count >= l_critical_threshold THEN
            l_result.status := 'CRITICAL';
            l_result.message := 'Failed jobs critical: ' || l_failed_count || ' (threshold: ' || l_critical_threshold || ')';
        ELSIF l_failed_count >= l_warning_threshold THEN
            l_result.status := 'WARNING';
            l_result.message := 'Failed jobs warning: ' || l_failed_count || ' (threshold: ' || l_warning_threshold || ')';
        ELSE
            l_result.status := 'OK';
            l_result.message := 'Failed jobs normal: ' || l_failed_count;
        END IF;

        -- Add attributes with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('jobs.failed_count', TO_CHAR(l_failed_count));
        l_attrs(2) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(3) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(4) := PLTelemetry.add_attribute('validation.status', l_result.status);
        
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status = 'OK' THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := 'ERROR';
            l_result.message := 'Validation error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
            log_error_internal('validate_failed_jobs', 
                'Error validating failed jobs: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_failed_jobs;

    FUNCTION validate_memory_usage(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result
    IS
        l_result t_validation_result;
        l_context t_tenant_context;
        l_span_id VARCHAR2(16);
        l_memory_pct NUMBER;
        l_warning_threshold NUMBER;
        l_critical_threshold NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validate_memory_usage', NULL, p_trace_id);

        -- Initialize result
        l_result.validation_type := 'MEMORY_USAGE';
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;

        -- Get thresholds for current tenant/environment
        SELECT warning_threshold, critical_threshold
        INTO l_warning_threshold, l_critical_threshold
        FROM db_validation_rules
        WHERE validation_type_code = 'MEMORY_USAGE'
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        l_result.warning_threshold := l_warning_threshold;
        l_result.critical_threshold := l_critical_threshold;

        -- Get memory usage based on target type
        IF UPPER(p_target_identifier) = 'SGA' THEN
            -- SGA memory usage
            SELECT ROUND(
                (SELECT value FROM v$sga WHERE name = 'Variable Size') /
                (SELECT value FROM v$sga WHERE name = 'Total System Global Area') * 100, 2
            ) INTO l_memory_pct FROM dual;
        ELSIF UPPER(p_target_identifier) = 'PGA' THEN
            -- PGA memory usage - approximate based on available statistics
            SELECT ROUND(NVL(
                (SELECT value FROM v$pgastat WHERE name = 'total PGA allocated') /
                NULLIF((SELECT value FROM v$pgastat WHERE name = 'aggregate PGA target parameter'), 0) * 100,
                0
            ), 2) INTO l_memory_pct FROM dual;
        ELSE
            -- Default to SGA
            SELECT ROUND(
                (SELECT SUM(bytes) FROM v$sgastat WHERE pool = 'shared pool') /
                (SELECT value FROM v$sga WHERE name = 'Total System Global Area') * 100, 2
            ) INTO l_memory_pct FROM dual;
        END IF;

        l_result.measured_value := l_memory_pct;

        -- Determine status based on thresholds
        IF l_memory_pct >= l_critical_threshold THEN
            l_result.status := 'CRITICAL';
            l_result.message := 'Memory usage critical: ' || l_memory_pct || '% (threshold: ' || l_critical_threshold || '%)';
        ELSIF l_memory_pct >= l_warning_threshold THEN
            l_result.status := 'WARNING';
            l_result.message := 'Memory usage warning: ' || l_memory_pct || '% (threshold: ' || l_warning_threshold || '%)';
        ELSE
            l_result.status := 'OK';
            l_result.message := 'Memory usage normal: ' || l_memory_pct || '%';
        END IF;

        -- Add attributes with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('memory.type', p_target_identifier);
        l_attrs(2) := PLTelemetry.add_attribute('memory.usage_percentage', TO_CHAR(l_memory_pct));
        l_attrs(3) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(4) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(5) := PLTelemetry.add_attribute('validation.status', l_result.status);
        
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status = 'OK' THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := 'ERROR';
            l_result.message := 'Validation error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
            log_error_internal('validate_memory_usage', 
                'Error validating memory usage: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_memory_usage;

    FUNCTION validate_cpu_usage(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result
    IS
        l_result t_validation_result;
        l_context t_tenant_context;
        l_span_id VARCHAR2(16);
        l_cpu_pct NUMBER;
        l_warning_threshold NUMBER;
        l_critical_threshold NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validate_cpu_usage', NULL, p_trace_id);

        -- Initialize result
        l_result.validation_type := 'CPU_USAGE';
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;

        -- Get thresholds for current tenant/environment
        SELECT warning_threshold, critical_threshold
        INTO l_warning_threshold, l_critical_threshold
        FROM db_validation_rules
        WHERE validation_type_code = 'CPU_USAGE'
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        l_result.warning_threshold := l_warning_threshold;
        l_result.critical_threshold := l_critical_threshold;

        -- Get CPU usage from v$sysmetric (Host CPU Utilization)
        BEGIN
            SELECT ROUND(value, 2)
            INTO l_cpu_pct
            FROM v$sysmetric
            WHERE metric_name = 'Host CPU Utilization (%)'
              AND group_id = 2
              AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- Fallback to database CPU time ratio
                SELECT ROUND(
                    (SELECT value FROM v$sysstat WHERE name = 'CPU used by this session') /
                    NULLIF((SELECT value FROM v$sysstat WHERE name = 'DB time'), 0) * 100,
                    2
                ) INTO l_cpu_pct FROM dual;
        END;

        l_result.measured_value := NVL(l_cpu_pct, 0);

        -- Determine status based on thresholds
        IF l_cpu_pct >= l_critical_threshold THEN
            l_result.status := 'CRITICAL';
            l_result.message := 'CPU usage critical: ' || l_cpu_pct || '% (threshold: ' || l_critical_threshold || '%)';
        ELSIF l_cpu_pct >= l_warning_threshold THEN
            l_result.status := 'WARNING';
            l_result.message := 'CPU usage warning: ' || l_cpu_pct || '% (threshold: ' || l_warning_threshold || '%)';
        ELSE
            l_result.status := 'OK';
            l_result.message := 'CPU usage normal: ' || l_cpu_pct || '%';
        END IF;

        -- Add attributes with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('cpu.usage_percentage', TO_CHAR(l_cpu_pct));
        l_attrs(2) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(3) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(4) := PLTelemetry.add_attribute('validation.status', l_result.status);
        
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status = 'OK' THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := 'ERROR';
            l_result.message := 'Validation error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
            log_error_internal('validate_cpu_usage', 
                'Error validating CPU usage: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_cpu_usage;

    FUNCTION validate_database_cpu_ratio(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result
    IS
        l_result t_validation_result;
        l_context t_tenant_context;
        l_span_id VARCHAR2(16);
        l_cpu_ratio NUMBER;
        l_warning_threshold NUMBER;
        l_critical_threshold NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validate_database_cpu_ratio', NULL, p_trace_id);

        -- Initialize result
        l_result.validation_type := 'DB_CPU_RATIO';
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;

        -- Get thresholds for current tenant/environment
        SELECT warning_threshold, critical_threshold
        INTO l_warning_threshold, l_critical_threshold
        FROM db_validation_rules
        WHERE validation_type_code = 'DB_CPU_RATIO'
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        l_result.warning_threshold := l_warning_threshold;
        l_result.critical_threshold := l_critical_threshold;

        -- Get database CPU ratio
        SELECT ROUND(
            (cpu_time.value / NULLIF(db_time.value, 0)) * 100, 2
        ) INTO l_cpu_ratio
        FROM 
            (SELECT value FROM v$sysstat WHERE name = 'CPU used by this session') cpu_time,
            (SELECT value FROM v$sysstat WHERE name = 'DB time') db_time;

        l_result.measured_value := NVL(l_cpu_ratio, 0);

        -- Determine status based on thresholds
        IF l_cpu_ratio >= l_critical_threshold THEN
            l_result.status := 'CRITICAL';
            l_result.message := 'DB CPU ratio critical: ' || l_cpu_ratio || '% (threshold: ' || l_critical_threshold || '%)';
        ELSIF l_cpu_ratio >= l_warning_threshold THEN
            l_result.status := 'WARNING';
            l_result.message := 'DB CPU ratio warning: ' || l_cpu_ratio || '% (threshold: ' || l_warning_threshold || '%)';
        ELSE
            l_result.status := 'OK';
            l_result.message := 'DB CPU ratio normal: ' || l_cpu_ratio || '%';
        END IF;

        -- Add attributes with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('db_cpu.ratio_percentage', TO_CHAR(l_cpu_ratio));
        l_attrs(2) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(3) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(4) := PLTelemetry.add_attribute('validation.status', l_result.status);
        
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status = 'OK' THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := 'ERROR';
            l_result.message := 'Validation error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
            log_error_internal('validate_database_cpu_ratio', 
                'Error validating DB CPU ratio: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_database_cpu_ratio;

    FUNCTION validate_pga_memory_usage(
        p_instance_name VARCHAR2,
        p_target_identifier VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    ) RETURN t_validation_result
    IS
        l_result t_validation_result;
        l_context t_tenant_context;
        l_span_id VARCHAR2(16);
        l_pga_pct NUMBER;
        l_warning_threshold NUMBER;
        l_critical_threshold NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_span_id := PLTelemetry.start_span('validate_pga_memory_usage', NULL, p_trace_id);

        -- Initialize result
        l_result.validation_type := 'PGA_MEMORY_USAGE';
        l_result.instance_name := p_instance_name;
        l_result.target_identifier := p_target_identifier;

        -- Get thresholds for current tenant/environment
        SELECT warning_threshold, critical_threshold
        INTO l_warning_threshold, l_critical_threshold
        FROM db_validation_rules
        WHERE validation_type_code = 'PGA_MEMORY_USAGE'
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        l_result.warning_threshold := l_warning_threshold;
        l_result.critical_threshold := l_critical_threshold;

        -- Get PGA memory usage percentage
        SELECT ROUND(
            (allocated.value / NULLIF(target.value, 0)) * 100, 2
        ) INTO l_pga_pct
        FROM 
            (SELECT value FROM v$pgastat WHERE name = 'total PGA allocated') allocated,
            (SELECT value FROM v$pgastat WHERE name = 'aggregate PGA target parameter') target;

        l_result.measured_value := NVL(l_pga_pct, 0);

        -- Determine status based on thresholds
        IF l_pga_pct >= l_critical_threshold THEN
            l_result.status := 'CRITICAL';
            l_result.message := 'PGA memory usage critical: ' || l_pga_pct || '% (threshold: ' || l_critical_threshold || '%)';
        ELSIF l_pga_pct >= l_warning_threshold THEN
            l_result.status := 'WARNING';
            l_result.message := 'PGA memory usage warning: ' || l_pga_pct || '% (threshold: ' || l_warning_threshold || '%)';
        ELSE
            l_result.status := 'OK';
            l_result.message := 'PGA memory usage normal: ' || l_pga_pct || '%';
        END IF;

        -- Add attributes with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('pga.usage_percentage', TO_CHAR(l_pga_pct));
        l_attrs(2) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(3) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(4) := PLTelemetry.add_attribute('validation.status', l_result.status);
        
        PLTelemetry.end_span(l_span_id, CASE WHEN l_result.status = 'OK' THEN 'OK' ELSE 'ERROR' END, l_attrs);
        
        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := 'ERROR';
            l_result.message := 'Validation error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
            log_error_internal('validate_pga_memory_usage', 
                'Error validating PGA memory usage: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            RETURN l_result;
    END validate_pga_memory_usage;

    --------------------------------------------------------------------------
    -- UTILITY AND HELPER FUNCTIONS IMPLEMENTATION
    --------------------------------------------------------------------------

    FUNCTION get_validation_rules_for_current_tenant(p_validation_type_code VARCHAR2)
        RETURN SYS_REFCURSOR
    IS
        l_cursor SYS_REFCURSOR;
        l_context t_tenant_context;
    BEGIN
        l_context := detect_tenant_context();
        
        OPEN l_cursor FOR
            SELECT 
                validation_type_code,
                warning_threshold,
                critical_threshold,
                threshold_unit,
                check_interval_minutes,
                is_enabled
            FROM db_validation_rules
            WHERE validation_type_code = p_validation_type_code
              AND tenant_id = l_context.tenant_id
              AND environment_name = l_context.environment_name;
        
        RETURN l_cursor;
    END get_validation_rules_for_current_tenant;

    FUNCTION get_enabled_instances_for_current_tenant(p_validation_type_code VARCHAR2 DEFAULT NULL)
        RETURN SYS_REFCURSOR
    IS
        l_cursor SYS_REFCURSOR;
        l_context t_tenant_context;
    BEGIN
        l_context := detect_tenant_context();
        
        OPEN l_cursor FOR
            SELECT 
                vi.validation_type_code,
                vi.instance_name,
                vi.target_identifier,
                vi.instance_description,
                vi.is_enabled,
                vi.last_check_time,
                vi.last_check_status,
                vi.last_check_value,
                vi.consecutive_failures
            FROM db_validation_instances vi
            WHERE vi.tenant_id = l_context.tenant_id
              AND vi.environment_name = l_context.environment_name
              AND vi.is_enabled = 1
              AND (p_validation_type_code IS NULL OR vi.validation_type_code = p_validation_type_code)
            ORDER BY vi.validation_type_code, vi.instance_name;
        
        RETURN l_cursor;
    END get_enabled_instances_for_current_tenant;

    FUNCTION is_validation_due(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2,
        p_force_check BOOLEAN DEFAULT FALSE
    ) RETURN BOOLEAN
    IS
        l_context t_tenant_context;
        l_last_check_time TIMESTAMP;
        l_check_interval NUMBER;
        l_next_check_time TIMESTAMP;
    BEGIN
        -- Force check overrides all timing logic
        IF p_force_check THEN
            RETURN TRUE;
        END IF;
        
        l_context := detect_tenant_context();
        
        -- Get last check time and interval
        SELECT vi.last_check_time, vr.check_interval_minutes
        INTO l_last_check_time, l_check_interval
        FROM db_validation_instances vi
        JOIN db_validation_rules vr ON (
            vi.validation_type_code = vr.validation_type_code
            AND vi.tenant_id = vr.tenant_id
            AND vi.environment_name = vr.environment_name
        )
        WHERE vi.validation_type_code = p_validation_type_code
          AND vi.instance_name = p_instance_name
          AND vi.tenant_id = l_context.tenant_id
          AND vi.environment_name = l_context.environment_name;

        -- If never checked, validation is due
        IF l_last_check_time IS NULL THEN
            RETURN TRUE;
        END IF;

        -- Calculate next check time
        l_next_check_time := l_last_check_time + (l_check_interval / 1440); -- Convert minutes to days
        
        -- Check if current time is past next check time
        RETURN SYSTIMESTAMP >= l_next_check_time;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- Instance or rule not found, assume validation is due
            RETURN TRUE;
        WHEN OTHERS THEN
            log_error_internal('is_validation_due', 
                'Error checking validation timing: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RETURN TRUE; -- Default to checking when in doubt
    END is_validation_due;

    PROCEDURE update_validation_result(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2,
        p_status VARCHAR2,
        p_measured_value NUMBER DEFAULT NULL,
        p_error_message VARCHAR2 DEFAULT NULL
    )
    IS
        l_context t_tenant_context;
        l_consecutive_failures NUMBER := 0;
    BEGIN
        l_context := detect_tenant_context();

        -- Calculate consecutive failures
        IF p_status IN ('WARNING', 'CRITICAL', 'ERROR') THEN
            SELECT NVL(consecutive_failures, 0) + 1
            INTO l_consecutive_failures
            FROM db_validation_instances
            WHERE validation_type_code = p_validation_type_code
              AND instance_name = p_instance_name
              AND tenant_id = l_context.tenant_id
              AND environment_name = l_context.environment_name;
        END IF;

        -- Update validation instance results
        UPDATE db_validation_instances
        SET last_check_time = SYSTIMESTAMP,
            last_check_status = p_status,
            last_check_value = p_measured_value,
            consecutive_failures = l_consecutive_failures,
            updated_at = SYSTIMESTAMP
        WHERE validation_type_code = p_validation_type_code
          AND instance_name = p_instance_name
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name;

        -- Log error message if provided
        IF p_error_message IS NOT NULL THEN
            log_error_internal('update_validation_result', 
                'Validation result error for ' || p_validation_type_code || '/' || p_instance_name || ': ' || p_error_message);
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('update_validation_result', 
                'Failed to update validation result: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
    END update_validation_result;

    PROCEDURE send_validation_metrics(
        p_validation_result t_validation_result,
        p_trace_id VARCHAR2 DEFAULT NULL
    )
    IS
        l_context t_tenant_context;
        l_attrs PLTelemetry.t_attributes;
        l_metric_name VARCHAR2(200);
        l_status_value NUMBER;
    BEGIN
        l_context := detect_tenant_context();

        -- Build comprehensive attributes with tenant context (CRITICAL!)
        l_attrs(1) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(2) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(3) := PLTelemetry.add_attribute('validation.type', p_validation_result.validation_type);
        l_attrs(4) := PLTelemetry.add_attribute('validation.instance', p_validation_result.instance_name);
        l_attrs(5) := PLTelemetry.add_attribute('validation.target', p_validation_result.target_identifier);
        l_attrs(6) := PLTelemetry.add_attribute('validation.status', p_validation_result.status);
        l_attrs(7) := PLTelemetry.add_attribute('db.name', SYS_CONTEXT('USERENV', 'DB_NAME'));
        l_attrs(8) := PLTelemetry.add_attribute('instance.identifier', l_context.instance_identifier);

        -- Send measured value metric with tenant context
        l_metric_name := 'db_' || LOWER(p_validation_result.validation_type) || '_value';
        PLTelemetry.log_metric(l_metric_name, p_validation_result.measured_value, 
            CASE p_validation_result.validation_type
                WHEN 'TABLESPACE_USAGE' THEN 'percentage'
                WHEN 'ACTIVE_SESSIONS' THEN 'count'
                WHEN 'BLOCKED_SESSIONS' THEN 'count'
                WHEN 'INVALID_OBJECTS' THEN 'count'
                WHEN 'FAILED_JOBS' THEN 'count'
                WHEN 'MEMORY_USAGE' THEN 'percentage'
                WHEN 'CPU_USAGE' THEN 'percentage'
                WHEN 'DB_CPU_RATIO' THEN 'percentage'
                WHEN 'PGA_MEMORY_USAGE' THEN 'percentage'
                ELSE 'unit'
            END, 
            l_attrs, FALSE);

        -- Send status metric (0=OK, 1=WARNING, 2=CRITICAL, 3=ERROR)
        l_status_value := CASE p_validation_result.status
            WHEN 'OK' THEN 0
            WHEN 'WARNING' THEN 1
            WHEN 'CRITICAL' THEN 2
            WHEN 'ERROR' THEN 3
            ELSE 3
        END;

        l_metric_name := 'db_' || LOWER(p_validation_result.validation_type) || '_status';
        PLTelemetry.log_metric(l_metric_name, l_status_value, 'status', l_attrs, FALSE);

        -- Send threshold metrics for alerting context
        IF p_validation_result.warning_threshold IS NOT NULL THEN
            l_metric_name := 'db_' || LOWER(p_validation_result.validation_type) || '_warning_threshold';
            PLTelemetry.log_metric(l_metric_name, p_validation_result.warning_threshold, 'threshold', l_attrs, FALSE);
        END IF;

        IF p_validation_result.critical_threshold IS NOT NULL THEN
            l_metric_name := 'db_' || LOWER(p_validation_result.validation_type) || '_critical_threshold';
            PLTelemetry.log_metric(l_metric_name, p_validation_result.critical_threshold, 'threshold', l_attrs, FALSE);
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('send_validation_metrics', 
                'Failed to send validation metrics: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
    END send_validation_metrics;

    PROCEDURE log_validation_event(
        p_validation_type VARCHAR2,
        p_instance_name VARCHAR2,
        p_event_name VARCHAR2,
        p_message VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL
    )
    IS
        l_context t_tenant_context;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();

        -- Build event attributes with tenant context (CRITICAL!)
        l_attrs(1) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(2) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(3) := PLTelemetry.add_attribute('validation.type', p_validation_type);
        l_attrs(4) := PLTelemetry.add_attribute('validation.instance', p_instance_name);
        l_attrs(5) := PLTelemetry.add_attribute('event.name', p_event_name);
        l_attrs(6) := PLTelemetry.add_attribute('db.name', SYS_CONTEXT('USERENV', 'DB_NAME'));

        -- Log event with tenant context
        IF p_trace_id IS NOT NULL THEN
            PLTelemetry.log_with_trace(p_trace_id, 'INFO', p_message, l_attrs);
        ELSE
            PLTelemetry.log_message('INFO', p_message, l_attrs);
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('log_validation_event', 
                'Failed to log validation event: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                p_trace_id);
    END log_validation_event;

    --------------------------------------------------------------------------
    -- CONFIGURATION AND MAINTENANCE IMPLEMENTATION
    --------------------------------------------------------------------------

    PROCEDURE set_validation_instance_enabled(
        p_validation_type_code VARCHAR2,
        p_instance_name VARCHAR2,
        p_enabled BOOLEAN
    )
    IS
        l_context t_tenant_context;
        l_enabled_flag NUMBER;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();
        l_enabled_flag := CASE WHEN p_enabled THEN 1 ELSE 0 END;

        UPDATE db_validation_instances
        SET is_enabled = l_enabled_flag,
            updated_at = SYSTIMESTAMP
        WHERE validation_type_code = p_validation_type_code
          AND instance_name = p_instance_name
          AND tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Validation instance not found: ' || p_validation_type_code || '/' || p_instance_name);
        END IF;

        -- Log configuration change with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(2) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(3) := PLTelemetry.add_attribute('validation.type', p_validation_type_code);
        l_attrs(4) := PLTelemetry.add_attribute('validation.instance', p_instance_name);
        l_attrs(5) := PLTelemetry.add_attribute('enabled', CASE WHEN p_enabled THEN 'true' ELSE 'false' END);

        PLTelemetry.log_message('INFO', 
            'Validation instance ' || CASE WHEN p_enabled THEN 'enabled' ELSE 'disabled' END, l_attrs);

    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('set_validation_instance_enabled', 
                'Failed to update validation instance: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END set_validation_instance_enabled;

    FUNCTION get_tenant_monitoring_status RETURN SYS_REFCURSOR
    IS
        l_cursor SYS_REFCURSOR;
        l_context t_tenant_context;
    BEGIN
        l_context := detect_tenant_context();
        
        OPEN l_cursor FOR
            SELECT 
                l_context.tenant_id as tenant_id,
                l_context.environment_name as environment_name,
                l_context.instance_identifier as instance_identifier,
                vt.validation_type_code,
                vt.description,
                COUNT(vi.instance_id) as total_instances,
                SUM(CASE WHEN vi.is_enabled = 1 THEN 1 ELSE 0 END) as enabled_instances,
                SUM(CASE WHEN vi.last_check_status = 'OK' THEN 1 ELSE 0 END) as ok_instances,
                SUM(CASE WHEN vi.last_check_status = 'WARNING' THEN 1 ELSE 0 END) as warning_instances,
                SUM(CASE WHEN vi.last_check_status = 'CRITICAL' THEN 1 ELSE 0 END) as critical_instances,
                SUM(CASE WHEN vi.last_check_status = 'ERROR' THEN 1 ELSE 0 END) as error_instances,
                MAX(vi.last_check_time) as last_validation_time,
                vr.check_interval_minutes,
                CASE WHEN vr.is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END as rule_status
            FROM db_validation_types vt
            LEFT JOIN db_validation_rules vr ON (
                vt.validation_type_code = vr.validation_type_code
                AND vr.tenant_id = l_context.tenant_id
                AND vr.environment_name = l_context.environment_name
            )
            LEFT JOIN db_validation_instances vi ON (
                vt.validation_type_code = vi.validation_type_code
                AND vi.tenant_id = l_context.tenant_id
                AND vi.environment_name = l_context.environment_name
            )
            WHERE vt.is_active = 1
            GROUP BY vt.validation_type_code, vt.description, vr.check_interval_minutes, vr.is_enabled
            ORDER BY vt.validation_type_code;
        
        RETURN l_cursor;
    END get_tenant_monitoring_status;

    FUNCTION validate_tenant_configuration RETURN BOOLEAN
    IS
        l_context t_tenant_context;
        l_config_count NUMBER;
        l_rules_count NUMBER;
        l_instances_count NUMBER;
        l_validation_ok BOOLEAN := TRUE;
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_context := detect_tenant_context();

        -- Check if tenant configuration exists
        SELECT COUNT(*)
        INTO l_config_count
        FROM plt_db_monitor_config
        WHERE tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_active = 1;

        IF l_config_count = 0 THEN
            l_validation_ok := FALSE;
            log_error_internal('validate_tenant_configuration', 
                'No active configuration found for tenant ' || l_context.tenant_id || '/' || l_context.environment_name);
        END IF;

        -- Check if validation rules exist
        SELECT COUNT(*)
        INTO l_rules_count
        FROM db_validation_rules
        WHERE tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        IF l_rules_count = 0 THEN
            l_validation_ok := FALSE;
            log_error_internal('validate_tenant_configuration', 
                'No validation rules found for tenant ' || l_context.tenant_id || '/' || l_context.environment_name);
        END IF;

        -- Check if validation instances exist
        SELECT COUNT(*)
        INTO l_instances_count
        FROM db_validation_instances
        WHERE tenant_id = l_context.tenant_id
          AND environment_name = l_context.environment_name
          AND is_enabled = 1;

        IF l_instances_count = 0 THEN
            l_validation_ok := FALSE;
            log_error_internal('validate_tenant_configuration', 
                'No enabled validation instances found for tenant ' || l_context.tenant_id || '/' || l_context.environment_name);
        END IF;

        -- Log configuration validation result with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(2) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(3) := PLTelemetry.add_attribute('config.valid', CASE WHEN l_validation_ok THEN 'true' ELSE 'false' END);
        l_attrs(4) := PLTelemetry.add_attribute('config.rules_count', TO_CHAR(l_rules_count));
        l_attrs(5) := PLTelemetry.add_attribute('config.instances_count', TO_CHAR(l_instances_count));

        PLTelemetry.log_message(
            CASE WHEN l_validation_ok THEN 'INFO' ELSE 'WARN' END,
            'Tenant configuration validation: ' || CASE WHEN l_validation_ok THEN 'VALID' ELSE 'INVALID' END,
            l_attrs
        );

        RETURN l_validation_ok;

    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('validate_tenant_configuration', 
                'Error validating tenant configuration: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RETURN FALSE;
    END validate_tenant_configuration;

    PROCEDURE initialize_tenant_monitoring(p_auto_enable_instances BOOLEAN DEFAULT FALSE)
    IS
        l_context t_tenant_context;
        l_trace_id VARCHAR2(32);
        l_span_id VARCHAR2(16);
        l_attrs PLTelemetry.t_attributes;
        l_instances_created NUMBER := 0;
        l_enabled_flag NUMBER;
        
        -- Cursor for discovered tablespaces
        CURSOR c_tablespaces IS
            SELECT tablespace_name
            FROM dba_tablespaces
            WHERE status = 'ONLINE'
              AND contents IN ('PERMANENT', 'TEMPORARY')
              AND tablespace_name NOT IN ('SYSTEM', 'SYSAUX', 'UNDOTBS1', 'TEMP');
    BEGIN
        l_context := detect_tenant_context();
        l_enabled_flag := CASE WHEN p_auto_enable_instances THEN 1 ELSE 0 END;

        -- Start trace for initialization
        l_trace_id := PLTelemetry.start_trace('initialize_tenant_monitoring');
        l_span_id := PLTelemetry.start_span('tenant_monitoring_initialization', NULL, l_trace_id);

        -- Set tenant context
        PLTelemetry.set_tenant_context(l_context.tenant_id, l_context.tenant_id || ' ' || l_context.environment_name);

        -- Add initialization event with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(2) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(3) := PLTelemetry.add_attribute('auto_enable', CASE WHEN p_auto_enable_instances THEN 'true' ELSE 'false' END);
        PLTelemetry.add_event(l_span_id, 'tenant_initialization_started', l_attrs);

        -- Create tablespace monitoring instances
        FOR rec IN c_tablespaces LOOP
            BEGIN
                -- Insert tablespace instance if not exists
                INSERT INTO db_validation_instances (
                    validation_type_code,
                    tenant_id,
                    environment_name,
                    instance_name,
                    instance_description,
                    target_identifier,
                    is_enabled
                ) 
                SELECT 
                    'TABLESPACE_USAGE',
                    l_context.tenant_id,
                    l_context.environment_name,
                    l_context.tenant_id || '_' || l_context.environment_name || '_' || rec.tablespace_name || '_TS',
                    'Auto-created tablespace monitoring for ' || rec.tablespace_name,
                    rec.tablespace_name,
                    l_enabled_flag
                FROM dual
                WHERE NOT EXISTS (
                    SELECT 1 FROM db_validation_instances
                    WHERE validation_type_code = 'TABLESPACE_USAGE'
                      AND tenant_id = l_context.tenant_id
                      AND environment_name = l_context.environment_name
                      AND target_identifier = rec.tablespace_name
                );

                IF SQL%ROWCOUNT > 0 THEN
                    l_instances_created := l_instances_created + 1;
                END IF;

            EXCEPTION
                WHEN OTHERS THEN
                    log_error_internal('initialize_tenant_monitoring', 
                        'Failed to create tablespace instance for ' || rec.tablespace_name || 
                        ': ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200), l_trace_id);
            END;
        END LOOP;

        -- Create global monitoring instances
        BEGIN
            -- Active sessions monitoring
            INSERT INTO db_validation_instances (
                validation_type_code, tenant_id, environment_name, instance_name, 
                instance_description, target_identifier, is_enabled
            ) 
            SELECT 
                'ACTIVE_SESSIONS', l_context.tenant_id, l_context.environment_name,
                l_context.tenant_id || '_' || l_context.environment_name || '_ACTIVE_SESSIONS',
                'Auto-created active sessions monitoring', 'ALL', l_enabled_flag
            FROM dual
            WHERE NOT EXISTS (
                SELECT 1 FROM db_validation_instances
                WHERE validation_type_code = 'ACTIVE_SESSIONS'
                  AND tenant_id = l_context.tenant_id
                  AND environment_name = l_context.environment_name
            );

            IF SQL%ROWCOUNT > 0 THEN
                l_instances_created := l_instances_created + 1;
            END IF;

            -- Memory usage monitoring
            INSERT INTO db_validation_instances (
                validation_type_code, tenant_id, environment_name, instance_name, 
                instance_description, target_identifier, is_enabled
            ) 
            SELECT 
                'MEMORY_USAGE', l_context.tenant_id, l_context.environment_name,
                l_context.tenant_id || '_' || l_context.environment_name || '_SGA_MEMORY',
                'Auto-created SGA memory monitoring', 'SGA', l_enabled_flag
            FROM dual
            WHERE NOT EXISTS (
                SELECT 1 FROM db_validation_instances
                WHERE validation_type_code = 'MEMORY_USAGE'
                  AND tenant_id = l_context.tenant_id
                  AND environment_name = l_context.environment_name
                  AND target_identifier = 'SGA'
            );

            IF SQL%ROWCOUNT > 0 THEN
                l_instances_created := l_instances_created + 1;
            END IF;

            -- CPU usage monitoring
            INSERT INTO db_validation_instances (
                validation_type_code, tenant_id, environment_name, instance_name, 
                instance_description, target_identifier, is_enabled
            ) 
            SELECT 
                'CPU_USAGE', l_context.tenant_id, l_context.environment_name,
                l_context.tenant_id || '_' || l_context.environment_name || '_DATABASE_CPU',
                'Auto-created database CPU monitoring', 'DB_CPU', l_enabled_flag
            FROM dual
            WHERE NOT EXISTS (
                SELECT 1 FROM db_validation_instances
                WHERE validation_type_code = 'CPU_USAGE'
                  AND tenant_id = l_context.tenant_id
                  AND environment_name = l_context.environment_name
            );

            IF SQL%ROWCOUNT > 0 THEN
                l_instances_created := l_instances_created + 1;
            END IF;

        EXCEPTION
            WHEN OTHERS THEN
                log_error_internal('initialize_tenant_monitoring', 
                    'Failed to create global monitoring instances: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                    l_trace_id);
        END;

        COMMIT;

        -- Log completion with tenant context
        l_attrs(1) := PLTelemetry.add_attribute('tenant.id', l_context.tenant_id);
        l_attrs(2) := PLTelemetry.add_attribute('environment.name', l_context.environment_name);
        l_attrs(3) := PLTelemetry.add_attribute('instances.created', TO_CHAR(l_instances_created));
        l_attrs(4) := PLTelemetry.add_attribute('instances.auto_enabled', CASE WHEN p_auto_enable_instances THEN 'true' ELSE 'false' END);

        PLTelemetry.add_event(l_span_id, 'tenant_initialization_completed', l_attrs);
        PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
        PLTelemetry.end_trace(l_trace_id);

        -- Send summary metrics with tenant context
        PLTelemetry.log_metric('db_instances_created', l_instances_created, 'count', l_attrs, FALSE);

        -- Log summary message
        PLTelemetry.log_message('INFO', 
            'Tenant monitoring initialized: ' || l_instances_created || ' instances created', l_attrs);

    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('initialize_tenant_monitoring', 
                'Critical error initializing tenant monitoring: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200), 
                l_trace_id);
            PLTelemetry.end_span(l_span_id, 'ERROR');
            PLTelemetry.end_trace(l_trace_id);
            RAISE;
    END initialize_tenant_monitoring;

END PLT_DB_MONITOR;
/