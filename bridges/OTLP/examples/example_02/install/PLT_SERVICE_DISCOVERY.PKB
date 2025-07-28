CREATE OR REPLACE PACKAGE BODY PLT_SERVICE_DISCOVERY
AS
    /**
     * PLT_SERVICE_DISCOVERY - Service Discovery and Health Monitoring for PLTelemetry
     * Version: 1.0.0 - Enterprise Oracle 12c+ Edition
     * 
     * This package provides comprehensive service discovery and health monitoring
     * capabilities with full PLTelemetry integration, multi-tenant support,
     * and enterprise-grade error handling.
     * 
     * Requirements: Oracle 12c+ with native JSON support, PLTelemetry core package
     * 
     * Features:
     * - Individual service metrics (no aggregation for clean time series)
     * - Normalize & validate pattern for all inputs
     * - Multi-tenant support throughout
     * - Distributed tracing integration
     * - Enterprise error handling and recovery
     */

    --------------------------------------------------------------------------
    -- PRIVATE VARIABLES
    --------------------------------------------------------------------------
    
    g_telemetry_configured BOOLEAN := FALSE;
    g_current_tenant_id    VARCHAR2(100);
    g_current_tenant_name  VARCHAR2(255);

    --------------------------------------------------------------------------
    -- PRIVATE ERROR HANDLING HELPER
    --------------------------------------------------------------------------
    
    /**
     * Centralized error logging to avoid code duplication
     */
    PROCEDURE log_error_internal(
        p_module VARCHAR2,
        p_error_message VARCHAR2,
        p_trace_id VARCHAR2 DEFAULT NULL,
        p_span_id VARCHAR2 DEFAULT NULL
    )
    IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO plt_telemetry_errors (
            error_time,
            error_message,
            module_name,
            trace_id,
            span_id
        ) VALUES (
            SYSTIMESTAMP,
            SUBSTR(p_error_message, 1, 4000),
            SUBSTR(p_module, 1, 100),
            p_trace_id,
            p_span_id
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Never let error logging break anything
    END log_error_internal;

    --------------------------------------------------------------------------
    -- UTILITY FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Normalize input strings for safe processing
     */
    FUNCTION normalize_string(
        p_input      VARCHAR2,
        p_max_length NUMBER DEFAULT 4000,
        p_allow_null BOOLEAN DEFAULT TRUE
    ) RETURN VARCHAR2
    IS
        l_result VARCHAR2(32767);
    BEGIN
        -- Handle NULL input
        IF p_input IS NULL THEN
            RETURN CASE WHEN p_allow_null THEN NULL ELSE '' END;
        END IF;
        
        -- Minimal normalization - just the essentials
        l_result := TRIM(p_input);                    -- Remove leading/trailing spaces
        l_result := REPLACE(l_result, CHR(0), '');   -- Remove null terminators (Forms legacy)
        
        -- Apply length limit
        IF LENGTH(l_result) > p_max_length THEN
            l_result := SUBSTR(l_result, 1, p_max_length - 3) || '...';
        END IF;
        
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback: basic TRIM and length limit
            RETURN SUBSTR(TRIM(NVL(p_input, '')), 1, p_max_length);
    END normalize_string;

    /**
     * Parse JSON health response - Oracle 12c+ native
     */
    FUNCTION parse_health_response(p_json_response VARCHAR2, p_key VARCHAR2) 
    RETURN VARCHAR2 
    IS
        l_json_response VARCHAR2(4000);
        l_key VARCHAR2(100);
    BEGIN
        -- Normalize inputs
        l_json_response := normalize_string(p_json_response, p_max_length => 4000, p_allow_null => TRUE);
        l_key := normalize_string(p_key, p_max_length => 100, p_allow_null => FALSE);
        
        IF l_json_response IS NULL OR l_key IS NULL THEN
            RETURN NULL;
        END IF;
        
        -- Try native JSON parsing first (Oracle 12c+)
        RETURN JSON_VALUE(l_json_response, '$.' || l_key);
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback to regex parsing
            DECLARE
                l_pattern VARCHAR2(200);
                l_value VARCHAR2(4000);
            BEGIN
                l_pattern := '"' || l_key || '"\s*:\s*"([^"]+)"';
                l_value := REGEXP_SUBSTR(l_json_response, l_pattern, 1, 1, NULL, 1);
                RETURN l_value;
            EXCEPTION
                WHEN OTHERS THEN
                    RETURN NULL;
            END;
    END parse_health_response;

    /**
     * Calculate escalated check interval based on failure count
     */
    FUNCTION calculate_escalated_interval(
        p_base_interval NUMBER,
        p_consecutive_failures NUMBER,
        p_escalation_multiplier NUMBER,
        p_max_escalation_failures NUMBER
    ) RETURN NUMBER 
    IS
    BEGIN
        IF p_consecutive_failures = 0 THEN
            -- Normal operation
            RETURN p_base_interval;
        ELSIF p_consecutive_failures >= p_max_escalation_failures THEN
            -- Maximum escalation
            RETURN GREATEST(1, p_base_interval * p_escalation_multiplier);
        ELSE
            -- Gradual escalation
            RETURN GREATEST(1, p_base_interval * p_escalation_multiplier);
        END IF;
    END calculate_escalated_interval;

    --------------------------------------------------------------------------
    -- PRIVATE HELPER FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Load service runtime configuration from database
     */
    FUNCTION load_service_runtime(p_service_name VARCHAR2) 
    RETURN t_service_runtime 
    IS
        l_runtime t_service_runtime;
        l_service_name VARCHAR2(50);
    BEGIN
        -- Normalize input
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        
        IF l_service_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20100, 'Service name cannot be null or empty');
        END IF;
        
        SELECT 
            s.service_id,
            s.service_name,
            s.service_description,
            s.endpoint_url,
            s.criticality_code,
            s.timeout_seconds,
            s.is_enabled,
            s.tenant_id,
            s.last_check_time,
            s.consecutive_failures,
            -- Calculate escalation level
            CASE 
                WHEN s.consecutive_failures >= c.max_escalation_failures THEN 2
                WHEN s.consecutive_failures >= (c.max_escalation_failures / 2) THEN 1
                ELSE 0
            END,
            -- Calculate next check due time
            s.last_check_time + INTERVAL '1' MINUTE * 
                calculate_escalated_interval(
                    c.check_interval_minutes,
                    s.consecutive_failures,
                    c.escalation_multiplier,
                    c.max_escalation_failures
                ),
            -- Criticality settings
            c.check_interval_minutes,
            calculate_escalated_interval(
                c.check_interval_minutes,
                s.consecutive_failures,
                c.escalation_multiplier,
                c.max_escalation_failures
            ),
            c.escalation_multiplier,
            c.max_escalation_failures
        INTO 
            l_runtime.service_id,
            l_runtime.service_name,
            l_runtime.service_description,
            l_runtime.endpoint_url,
            l_runtime.criticality_code,
            l_runtime.timeout_seconds,
            l_runtime.is_enabled,
            l_runtime.tenant_id,
            l_runtime.last_check_time,
            l_runtime.consecutive_failures,
            l_runtime.escalation_level,
            l_runtime.next_check_due,
            l_runtime.base_check_interval,
            l_runtime.current_check_interval,
            l_runtime.escalation_multiplier,
            l_runtime.max_escalation_failures
        FROM plt_service_discovery_config s
        JOIN plt_service_discovery_crit_levels c ON s.criticality_code = c.criticality_code
        WHERE s.service_name = l_service_name;

        RETURN l_runtime;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20101, 'Service not found: ' || l_service_name);
        WHEN OTHERS THEN
            log_error_internal('load_service_runtime', 
                             'Error loading service runtime: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200),
                             NULL, NULL);
            RAISE_APPLICATION_ERROR(-20102, 'Error loading service runtime: ' || SUBSTR(SQLERRM, 1, 200));
    END load_service_runtime;

    /**
     * Create service-specific attributes for metrics (STABLE LABELS ONLY)
     */
    FUNCTION create_stable_service_attributes(
        p_service_name VARCHAR2,
        p_criticality VARCHAR2,
        p_endpoint VARCHAR2,
        p_tenant_id VARCHAR2 DEFAULT NULL
    ) RETURN PLTelemetry.t_attributes 
    IS
        l_attrs PLTelemetry.t_attributes;
        l_idx NUMBER := 1;
        l_service_name VARCHAR2(50);
        l_criticality VARCHAR2(10);
        l_endpoint VARCHAR2(300);
        l_tenant_id VARCHAR2(100);
    BEGIN
        -- Normalize all inputs
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        l_criticality := normalize_string(p_criticality, p_max_length => 10, p_allow_null => FALSE);
        l_endpoint := normalize_string(p_endpoint, p_max_length => 300, p_allow_null => FALSE);
        l_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => TRUE);
        
        l_attrs(l_idx) := PLTelemetry.add_attribute('service_name', l_service_name);
        l_idx := l_idx + 1;
        
        l_attrs(l_idx) := PLTelemetry.add_attribute('criticality', l_criticality);
        l_idx := l_idx + 1;
        
        -- Extract just the port from endpoint for cleaner labeling
        l_attrs(l_idx) := PLTelemetry.add_attribute('endpoint_port', 
            NVL(REGEXP_SUBSTR(l_endpoint, ':([0-9]+)', 1, 1, NULL, 1), 'unknown'));
        l_idx := l_idx + 1;
        
        -- Add tenant context if available (STABLE)
        IF l_tenant_id IS NOT NULL THEN
            l_attrs(l_idx) := PLTelemetry.add_attribute('tenant_id', l_tenant_id);
        ELSIF g_current_tenant_id IS NOT NULL THEN
            l_attrs(l_idx) := PLTelemetry.add_attribute('tenant_id', g_current_tenant_id);
        END IF;
        
        RETURN l_attrs;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('create_stable_service_attributes', 
                             'Failed to create service attributes: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            -- Return minimal attributes
            l_attrs(1) := PLTelemetry.add_attribute('service_name', NVL(l_service_name, 'unknown'));
            RETURN l_attrs;
    END create_stable_service_attributes;

    --------------------------------------------------------------------------
    -- CORE SERVICE DISCOVERY
    --------------------------------------------------------------------------

    /**
     * Initialize PLTelemetry configuration for service discovery
     */
    PROCEDURE configure_telemetry 
    IS
    BEGIN
        IF NOT g_telemetry_configured THEN

            -- Initialize PLTelemetry failover system
            --PLTelemetry.initialize_failover_system();

            -- Configure PLTelemetry for service discovery
            PLTelemetry.set_backend_url('OTLP_BRIDGE');
            PLT_OTLP_BRIDGE.set_otlp_collector('http://plt-otel-collector:4318');
            PLT_OTLP_BRIDGE.set_service_info('oracle-service-discovery', '1.0.0', 'production');
            --PLT_OTLP_BRIDGE.set_debug_mode(FALSE);
            PLTelemetry.set_async_mode(TRUE);

            PLT_OTLP_BRIDGE.set_metric_type_mapping('service_response_time_%', 'gauge');
            PLT_OTLP_BRIDGE.set_metric_type_mapping('service_status_%', 'gauge');
            PLT_OTLP_BRIDGE.set_metric_type_mapping('service_check_%', 'gauge');
            PLT_OTLP_BRIDGE.set_metric_type_mapping('service_healthy_%', 'gauge');
            PLT_OTLP_BRIDGE.set_metric_type_mapping('service_consecutive_%', 'gauge');
            PLT_OTLP_BRIDGE.set_metric_type_mapping('service_escalation_%', 'gauge');
            PLT_OTLP_BRIDGE.set_metric_type_mapping('service_downtime_%', 'gauge');
            PLT_OTLP_BRIDGE.set_metric_type_mapping('service_recovery_%', 'counter');
            
            g_telemetry_configured := TRUE;
        END IF;
    END configure_telemetry;

    /**
     * Main service discovery check procedure
     */
    PROCEDURE perform_discovery_checks(
        p_force_all_checks BOOLEAN DEFAULT FALSE,
        p_tenant_id VARCHAR2 DEFAULT NULL
    ) 
    IS
        l_trace_id VARCHAR2(32);
        l_span_id VARCHAR2(16);
        l_health_result t_health_result;
        l_attrs PLTelemetry.t_attributes;
        l_current_time TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
        l_start_time TIMESTAMP := SYSTIMESTAMP;
        l_cursor SYS_REFCURSOR;
        l_service_name VARCHAR2(50);
        l_criticality VARCHAR2(10);
        l_interval NUMBER;
        l_service_tenant_id VARCHAR2(100);
        l_cycle_attrs PLTelemetry.t_attributes;
        l_normalized_tenant_id VARCHAR2(100);
        l_services_checked NUMBER := 0;
        l_error_msg VARCHAR2(4000);
    BEGIN
        -- Normalize input
        l_normalized_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => TRUE);
        
        -- Ensure telemetry is configured
        configure_telemetry();

        -- Start service discovery trace
        l_trace_id := PLTelemetry.start_trace('service_discovery_cycle');
        l_span_id := PLTelemetry.start_span('monitor_services_batch');

        -- Add monitoring cycle context
        l_attrs(1) := PLTelemetry.add_attribute('monitoring.cycle_time', TO_CHAR(l_current_time, 'YYYY-MM-DD HH24:MI:SS'));
        l_attrs(2) := PLTelemetry.add_attribute('monitoring.force_all_checks', CASE WHEN p_force_all_checks THEN 'true' ELSE 'false' END);
        IF l_normalized_tenant_id IS NOT NULL THEN
            l_attrs(3) := PLTelemetry.add_attribute('monitoring.tenant_filter', l_normalized_tenant_id);
        END IF;
        PLTelemetry.add_event(l_span_id, 'discovery_cycle_started', l_attrs);

        -- Get services due for checking
        l_cursor := get_services_due_for_check(p_force_all_checks, l_normalized_tenant_id);

        LOOP
            FETCH l_cursor INTO l_service_name, l_criticality, l_interval, l_service_tenant_id;
            EXIT WHEN l_cursor%NOTFOUND;
            
            l_services_checked := l_services_checked + 1;
            
            -- Log service check start
            PLTelemetry.add_event(l_span_id, 'checking_service_' || l_service_name);

            -- Perform health check with distributed tracing
            l_health_result := check_service_health(l_service_name, l_trace_id);

            -- Handle result based on status
            IF l_health_result.status IN (C_HEALTHY, C_DEGRADED) THEN
                handle_service_recovery(l_service_name, l_health_result);
            ELSE
                handle_service_failure(l_service_name, l_health_result);
            END IF;

        END LOOP;

        CLOSE l_cursor;

        -- Service discovery cycle metrics
        l_cycle_attrs(1) := PLTelemetry.add_attribute('cycle_type', 'service_discovery');
        l_cycle_attrs(2) := PLTelemetry.add_attribute('force_all', CASE WHEN p_force_all_checks THEN 'true' ELSE 'false' END);
        IF l_normalized_tenant_id IS NOT NULL THEN
            l_cycle_attrs(3) := PLTelemetry.add_attribute('tenant_filter', l_normalized_tenant_id);
        END IF;

        -- Cycle duration metric
        PLTelemetry.log_metric(
            p_metric_name => 'discovery_cycle_duration',
            p_value => EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000,
            p_unit => 'ms',
            p_attributes => l_cycle_attrs,
            p_include_trace_correlation => FALSE
        );

        -- Services checked metric
        PLTelemetry.log_metric(
            p_metric_name => 'discovery_services_checked',
            p_value => l_services_checked,
            p_unit => 'count',
            p_attributes => l_cycle_attrs,
            p_include_trace_correlation => FALSE
        );

        -- Log cycle completion
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('cycle.duration', 
            TO_CHAR(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, '999999.99'));
        l_attrs(2) := PLTelemetry.add_attribute('cycle.services_checked', TO_CHAR(l_services_checked));
        PLTelemetry.add_event(l_span_id, 'discovery_cycle_completed', l_attrs);

        PLTelemetry.end_span(l_span_id, 'OK');
        PLTelemetry.end_trace(l_trace_id);

    EXCEPTION
        WHEN OTHERS THEN
            IF l_cursor%ISOPEN THEN
                CLOSE l_cursor;
            END IF;

            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('perform_discovery_checks', l_error_msg, l_trace_id, l_span_id);

            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SUBSTR(l_error_msg, 1, 200));
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            
            PLTelemetry.log_distributed(
                p_trace_id => l_trace_id,
                p_level => 'ERROR',
                p_message => 'Service discovery cycle failed: ' || SUBSTR(l_error_msg, 1, 200),
                p_system => 'PLT_SERVICE_DISCOVERY'
            );

            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            PLTelemetry.end_trace(l_trace_id);
    END perform_discovery_checks;

    /**
     * Check health of a specific service with full telemetry
     */
    FUNCTION check_service_health(
        p_service_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_health_result 
    IS
        l_service t_service_runtime;
        l_result t_health_result;
        l_req UTL_HTTP.REQ;
        l_resp UTL_HTTP.RESP;
        l_response_body VARCHAR2(4000);
        l_buffer VARCHAR2(32767);
        l_start_time TIMESTAMP := SYSTIMESTAMP;
        l_span_id VARCHAR2(16);
        l_attrs PLTelemetry.t_attributes;
        l_trace_id VARCHAR2(32);
        l_service_attrs PLTelemetry.t_attributes;
        l_service_name VARCHAR2(50);
        l_normalized_trace_id VARCHAR2(32);
        l_error_msg VARCHAR2(4000);
    BEGIN
        -- Normalize & validate input parameters
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        l_normalized_trace_id := normalize_string(p_trace_id, p_max_length => 32, p_allow_null => TRUE);
        
        IF l_service_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20103, 'Service name cannot be null or empty');
        END IF;
        
        -- Ensure telemetry is configured
        configure_telemetry();

        -- Load service configuration
        l_service := load_service_runtime(l_service_name);

        -- >>> FIXED: Route based on service type with proper RETURN <
        DECLARE
            l_service_type VARCHAR2(50);
        BEGIN
            -- Get service type from database
            SELECT service_type 
            INTO l_service_type
            FROM plt_service_discovery_config 
            WHERE service_name = l_service_name;
            
            -- Route to appropriate execution path
            IF l_service_type = 'CUSTOM' THEN
                -- Execute custom plan
                DECLARE
                    l_custom_plan_json VARCHAR2(4000);
                    l_skip_result t_health_result;
                BEGIN
                    SELECT custom_plan_json 
                    INTO l_custom_plan_json
                    FROM plt_service_discovery_config 
                    WHERE service_name = l_service_name;
                    
                    IF l_custom_plan_json IS NULL THEN
                        -- Skip check and return early with error state
                        l_skip_result.service_name := l_service_name;
                        l_skip_result.status := C_ERROR;
                        l_skip_result.check_timestamp := SYSTIMESTAMP;
                        l_skip_result.error_message := 'Custom plan JSON not ready - DataPerro processing pending';
                        l_skip_result.response_time_ms := 0;
                        l_skip_result.tenant_id := l_service.tenant_id;
                        
                        -- Log error for service discovery tracking
                        log_error_internal(
                            'check_service_health', 
                            'CUSTOM service ' || l_service_name || ' has no JSON plan ready. DataPerro may still be processing YAML.',
                            l_trace_id, 
                            l_span_id
                        );
                        
                        -- Log distributed error for observability
                        PLTelemetry.log_distributed(
                            p_trace_id => l_trace_id,
                            p_level => 'WARN',
                            p_message => 'CUSTOM service ' || l_service_name || ' skipped - JSON plan not ready',
                            p_system => 'PLT_SERVICE_DISCOVERY',
                            p_tenant_id => l_service.tenant_id
                        );
                        
                        -- Add telemetry event for debugging
                        l_attrs := PLTelemetry.t_attributes();
                        l_attrs(1) := PLTelemetry.add_attribute('service.name', l_service_name);
                        l_attrs(2) := PLTelemetry.add_attribute('service.type', 'CUSTOM');
                        l_attrs(3) := PLTelemetry.add_attribute('skip.reason', 'json_plan_not_ready');
                        PLTelemetry.add_event(l_span_id, 'custom_service_check_skipped', l_attrs);
                        
                        -- End span and trace
                        PLTelemetry.end_span(l_span_id, 'ERROR');
                        IF l_normalized_trace_id IS NULL THEN
                            PLTelemetry.end_trace(l_trace_id);
                        END IF;
                        
                        RETURN l_skip_result;
                    ELSE
                        -- 🔥 CRITICAL FIX: Execute custom plan and RETURN immediately
                        RETURN execute_custom_plan(l_service_name, l_custom_plan_json, l_normalized_trace_id);
                    END IF;
                    
                END;
            END IF;
            
            -- If not CUSTOM, continue with existing ENDPOINT logic below...
            
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- Service not found - this will be handled by existing code
                NULL;
        END;

        -- Initialize result (ONLY reached for non-CUSTOM services)
        l_result.service_name := l_service_name;
        l_result.check_timestamp := SYSTIMESTAMP;
        l_result.tenant_id := l_service.tenant_id;

        -- Start or continue distributed trace
        IF l_normalized_trace_id IS NOT NULL THEN
            l_trace_id := l_normalized_trace_id;
            l_span_id := PLTelemetry.continue_distributed_trace(
                p_trace_id => l_normalized_trace_id,
                p_operation => 'service_health_check_' || l_service_name,
                p_tenant_id => l_service.tenant_id
            );
        ELSE
            l_trace_id := PLTelemetry.start_trace('health_check_' || l_service_name);
            l_span_id := PLTelemetry.start_span('health_check_execution');
        END IF;

        -- Add service context
        l_attrs(1) := PLTelemetry.add_attribute('service.name', l_service_name);
        l_attrs(2) := PLTelemetry.add_attribute('service.criticality', l_service.criticality_code);
        l_attrs(3) := PLTelemetry.add_attribute('service.endpoint', l_service.endpoint_url);
        l_attrs(4) := PLTelemetry.add_attribute('check.timeout_seconds', TO_CHAR(l_service.timeout_seconds));
        l_attrs(5) := PLTelemetry.add_attribute('service.consecutive_failures', TO_CHAR(l_service.consecutive_failures));
        IF l_service.tenant_id IS NOT NULL THEN
            l_attrs(6) := PLTelemetry.add_attribute('service.tenant_id', l_service.tenant_id);
        END IF;
        PLTelemetry.add_event(l_span_id, 'health_check_started', l_attrs);

        BEGIN
            -- Set timeout
            UTL_HTTP.SET_TRANSFER_TIMEOUT(l_service.timeout_seconds);
            
            -- Make HTTP request to endpoint
            l_req := UTL_HTTP.BEGIN_REQUEST(l_service.endpoint_url, 'GET', 'HTTP/1.1');
            UTL_HTTP.SET_HEADER(l_req, 'User-Agent', 'PLTelemetry-ServiceDiscovery/1.0');
            UTL_HTTP.SET_HEADER(l_req, 'Accept', 'application/json');
            UTL_HTTP.SET_HEADER(l_req, 'X-Monitor-Source', 'Oracle-PLTelemetry');
            UTL_HTTP.SET_HEADER(l_req, 'X-Trace-ID', l_trace_id);
            
            PLTelemetry.add_event(l_span_id, 'http_request_sent');
            
            l_resp := UTL_HTTP.GET_RESPONSE(l_req);
            l_result.status_code := l_resp.status_code;

            -- Read response body
            BEGIN
                UTL_HTTP.READ_TEXT(l_resp, l_buffer, 4000);
                l_response_body := l_buffer;
            EXCEPTION
                WHEN UTL_HTTP.END_OF_BODY THEN
                    NULL; -- Normal end of response
            END;
            l_result.response_body := l_response_body;

            UTL_HTTP.END_RESPONSE(l_resp);

            -- Calculate response time
            l_result.response_time_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000;

            PLTelemetry.add_event(l_span_id, 'http_response_received');

            -- Analyze response
            IF l_result.status_code = 200 THEN
                -- Parse JSON response for detailed status
                DECLARE
                    l_service_status VARCHAR2(50);
                    l_uptime_str VARCHAR2(50);
                    l_version VARCHAR2(50);
                BEGIN
                    l_service_status := parse_health_response(l_response_body, 'status');
                    l_uptime_str := parse_health_response(l_response_body, 'uptime');
                    l_version := parse_health_response(l_response_body, 'version');

                    -- Determine final status
                    l_result.status := CASE UPPER(NVL(l_service_status, 'healthy'))
                        WHEN 'HEALTHY' THEN C_HEALTHY
                        WHEN 'DEGRADED' THEN C_DEGRADED
                        WHEN 'UNHEALTHY' THEN C_UNHEALTHY
                        ELSE C_HEALTHY
                    END;

                    -- Extract additional info
                    IF l_uptime_str IS NOT NULL THEN
                        BEGIN
                            l_result.service_uptime := TO_NUMBER(l_uptime_str);
                        EXCEPTION
                            WHEN OTHERS THEN
                                l_result.service_uptime := NULL;
                        END;
                    END IF;
                    l_result.service_version := normalize_string(l_version, p_max_length => 50, p_allow_null => TRUE);

                EXCEPTION
                    WHEN OTHERS THEN
                        -- JSON parsing failed, but HTTP was successful
                        l_result.status := C_HEALTHY;
                        l_result.error_message := 'JSON parsing failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
                END;
            ELSE
                -- Non-200 status code
                l_result.status := C_UNHEALTHY;
                l_result.error_message := 'HTTP ' || l_result.status_code || ': ' || l_resp.reason_phrase;
            END IF;

        EXCEPTION
            WHEN UTL_HTTP.TRANSFER_TIMEOUT THEN
                l_result.status := C_TIMEOUT;
                l_result.error_message := 'Request timeout after ' || l_service.timeout_seconds || ' seconds';
                l_result.response_time_ms := -1;
                PLTelemetry.add_event(l_span_id, 'request_timeout');

            WHEN UTL_HTTP.REQUEST_FAILED THEN
                l_result.status := C_DOWN;
                l_result.error_message := 'Service unreachable: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
                l_result.response_time_ms := -1;
                PLTelemetry.add_event(l_span_id, 'service_unreachable');

            WHEN OTHERS THEN
                l_result.status := C_ERROR;
                l_result.error_message := 'Health check error: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
                l_result.response_time_ms := -1;
                PLTelemetry.add_event(l_span_id, 'health_check_error');
        END;

        -- Create STABLE service-specific attributes (no changing labels)
        l_service_attrs := create_stable_service_attributes(
            p_service_name => l_service_name,
            p_criticality => l_service.criticality_code,
            p_endpoint => l_service.endpoint_url,
            p_tenant_id => l_service.tenant_id
        );

        -- Individual service metrics with stable labels
        PLTelemetry.log_metric(
            p_metric_name => 'service_response_time',
            p_value => NVL(l_result.response_time_ms, -1),
            p_unit => 'ms',
            p_attributes => l_service_attrs,
            p_include_trace_correlation => FALSE
        );

        PLTelemetry.log_metric(
            p_metric_name => 'service_status_gauge',
            p_value => CASE l_result.status 
                        WHEN C_HEALTHY THEN 1
                        WHEN C_DEGRADED THEN 0.5
                        ELSE 0
                    END,
            p_unit => 'status',
            p_attributes => l_service_attrs,
            p_include_trace_correlation => FALSE
        );

        PLTelemetry.log_metric(
            p_metric_name => 'service_check_performed',
            p_value => 1,
            p_unit => 'count',
            p_attributes => l_service_attrs,
            p_include_trace_correlation => FALSE
        );

        -- Success/failure counters
        IF l_result.status IN (C_HEALTHY, C_DEGRADED) THEN
            PLTelemetry.log_metric(
                p_metric_name => 'service_check_success',
                p_value => 1,
                p_unit => 'count',
                p_attributes => l_service_attrs,
                p_include_trace_correlation => FALSE
            );
        ELSE
            PLTelemetry.log_metric(
                p_metric_name => 'service_check_failure',
                p_value => 1,
                p_unit => 'count',
                p_attributes => l_service_attrs,
                p_include_trace_correlation => FALSE
            );
        END IF;

        -- Add final result attributes to span
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('result.status', l_result.status);
        l_attrs(2) := PLTelemetry.add_attribute('result.response_time', TO_CHAR(l_result.response_time_ms, '999999.99'));
        l_attrs(3) := PLTelemetry.add_attribute('result.status_code', TO_CHAR(l_result.status_code));
        IF l_result.service_version IS NOT NULL THEN
            l_attrs(4) := PLTelemetry.add_attribute('service.version', l_result.service_version);
        END IF;
        PLTelemetry.add_event(l_span_id, 'health_check_completed', l_attrs);

        -- End span based on result
        IF l_result.status IN (C_HEALTHY, C_DEGRADED) THEN
            PLTelemetry.end_span(l_span_id, 'OK');
        ELSE
            PLTelemetry.end_span(l_span_id, 'ERROR');
        END IF;

        -- End trace if we started it
        IF l_normalized_trace_id IS NULL THEN
            PLTelemetry.end_trace(l_trace_id);
        END IF;

        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            
            l_result.status := C_ERROR;
            l_result.error_message := 'Critical health check failure: ' || l_error_msg;
            l_result.response_time_ms := -1;
            
            -- Log error
            log_error_internal('check_service_health', l_error_msg, l_trace_id, l_span_id);
            
            -- Generate metrics even for catastrophic failures
            BEGIN
                l_service_attrs := create_stable_service_attributes(
                    p_service_name => l_service_name,
                    p_criticality => NVL(l_service.criticality_code, 'UNKNOWN'),
                    p_endpoint => NVL(l_service.endpoint_url, 'unknown'),
                    p_tenant_id => l_service.tenant_id
                );

                PLTelemetry.log_metric(
                    p_metric_name => 'service_response_time',
                    p_value => -1,
                    p_unit => 'milliseconds',
                    p_attributes => l_service_attrs,
                    p_include_trace_correlation => FALSE
                );

                PLTelemetry.log_metric(
                    p_metric_name => 'service_status_gauge',
                    p_value => 0,
                    p_unit => 'status',
                    p_attributes => l_service_attrs,
                    p_include_trace_correlation => FALSE
                );

                PLTelemetry.log_metric(
                    p_metric_name => 'service_check_failure',
                    p_value => 1,
                    p_unit => 'count',
                    p_attributes => l_service_attrs,
                    p_include_trace_correlation => FALSE
                );
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
            
            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SUBSTR(l_error_msg, 1, 200));
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            
            PLTelemetry.log_distributed(
                p_trace_id => l_trace_id,
                p_level => 'ERROR',
                p_message => 'Health check critical failure for ' || l_service_name || ': ' || SUBSTR(l_error_msg, 1, 200),
                p_system => 'PLT_SERVICE_DISCOVERY'
            );

            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            
            IF l_normalized_trace_id IS NULL THEN
                PLTelemetry.end_trace(l_trace_id);
            END IF;

            RETURN l_result;
    END check_service_health;

    /**
     * Handle service failure with escalation logic
     */
    PROCEDURE handle_service_failure(
        p_service_name IN VARCHAR2,
        p_health_result IN t_health_result
    ) 
    IS
        l_service t_service_runtime;
        l_attrs PLTelemetry.t_attributes;
        l_escalation_change BOOLEAN := FALSE;
        l_previous_escalation NUMBER;
        l_failure_attrs PLTelemetry.t_attributes;
        l_service_name VARCHAR2(50);
        l_error_msg VARCHAR2(4000);
    BEGIN
        -- Normalize input
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        
        IF l_service_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20104, 'Service name cannot be null or empty');
        END IF;
        
        l_service := load_service_runtime(l_service_name);
        l_previous_escalation := l_service.escalation_level;

        -- Update failure counters in database
        UPDATE plt_service_discovery_config 
        SET consecutive_failures = consecutive_failures + 1,
            last_check_time = SYSTIMESTAMP,
            last_failure_reason = SUBSTR(p_health_result.error_message, 1, 500)
        WHERE service_name = l_service_name;

        -- Reload to get updated values
        l_service := load_service_runtime(l_service_name);

        -- Check if escalation level changed
        l_escalation_change := (l_service.escalation_level != l_previous_escalation);

        -- Individual service failure metrics
        l_failure_attrs := create_stable_service_attributes(
            p_service_name => l_service_name,
            p_criticality => l_service.criticality_code,
            p_endpoint => l_service.endpoint_url,
            p_tenant_id => l_service.tenant_id
        );

        -- Consecutive failures metric
        PLTelemetry.log_metric(
            p_metric_name => 'service_consecutive_failures',
            p_value => l_service.consecutive_failures,
            p_unit => 'count',
            p_attributes => l_failure_attrs,
            p_include_trace_correlation => FALSE
        );

        -- Escalation level metric
        PLTelemetry.log_metric(
            p_metric_name => 'service_escalation_level',
            p_value => l_service.escalation_level,
            p_unit => 'level',
            p_attributes => l_failure_attrs,
            p_include_trace_correlation => FALSE
        );

        -- Escalation change event
        IF l_escalation_change THEN
            PLTelemetry.log_metric(
                p_metric_name => 'service_escalation_change',
                p_value => 1,
                p_unit => 'count',
                p_attributes => l_failure_attrs,
                p_include_trace_correlation => FALSE
            );
            
            PLTelemetry.add_event(
                PLTelemetry.get_current_span_id(),
                'service_escalation_level_changed',
                l_failure_attrs
            );
        END IF;

        -- Log failure with full context
        l_attrs(1) := PLTelemetry.add_attribute('service.name', l_service_name);
        l_attrs(2) := PLTelemetry.add_attribute('service.criticality', l_service.criticality_code);
        l_attrs(3) := PLTelemetry.add_attribute('failure.status', p_health_result.status);
        l_attrs(4) := PLTelemetry.add_attribute('failure.consecutive_count', TO_CHAR(l_service.consecutive_failures));
        l_attrs(5) := PLTelemetry.add_attribute('escalation.level', TO_CHAR(l_service.escalation_level));
        l_attrs(6) := PLTelemetry.add_attribute('escalation.changed', CASE WHEN l_escalation_change THEN 'true' ELSE 'false' END);
        IF l_service.tenant_id IS NOT NULL THEN
            l_attrs(7) := PLTelemetry.add_attribute('service.tenant_id', l_service.tenant_id);
        END IF;

        -- Determine log level based on criticality and escalation
        DECLARE
            l_log_level VARCHAR2(10);
            l_message VARCHAR2(1000);
        BEGIN
            IF l_service.escalation_level = 2 THEN
                l_log_level := 'ERROR';
                l_message := 'CRITICAL: Service ' || l_service_name || ' has failed ' || 
                            l_service.consecutive_failures || ' consecutive times';
            ELSIF l_service.escalation_level = 1 THEN
                l_log_level := 'WARN';
                l_message := 'WARNING: Service ' || l_service_name || ' is experiencing repeated failures (' || 
                            l_service.consecutive_failures || ' consecutive)';
            ELSE
                l_log_level := 'INFO';
                l_message := 'Service ' || l_service_name || ' health check failed: ' || p_health_result.status;
            END IF;

            PLTelemetry.log_distributed(
                p_trace_id => PLTelemetry.get_current_trace_id(),
                p_level => l_log_level,
                p_message => l_message,
                p_system => 'PLT_SERVICE_DISCOVERY',
                p_tenant_id => l_service.tenant_id
            );
        END;

        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('handle_service_failure', l_error_msg);
            
            PLTelemetry.log_distributed(
                p_trace_id => PLTelemetry.get_current_trace_id(),
                p_level => 'ERROR',
                p_message => 'Failed to handle service failure for ' || l_service_name || ': ' || SUBSTR(l_error_msg, 1, 200),
                p_system => 'PLT_SERVICE_DISCOVERY'
            );
    END handle_service_failure;

    /**
     * Handle service recovery
     */
    PROCEDURE handle_service_recovery(
        p_service_name IN VARCHAR2,
        p_health_result IN t_health_result
    ) 
    IS
        l_service t_service_runtime;
        l_attrs PLTelemetry.t_attributes;
        l_was_failing BOOLEAN := FALSE;
        l_downtime_minutes NUMBER;
        l_recovery_attrs PLTelemetry.t_attributes;
        l_service_name VARCHAR2(50);
        l_error_msg VARCHAR2(4000);
    BEGIN
        -- Normalize input
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        
        IF l_service_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20105, 'Service name cannot be null or empty');
        END IF;
        
        l_service := load_service_runtime(l_service_name);
        l_was_failing := (l_service.consecutive_failures > 0);

        -- Calculate downtime if service was failing
        IF l_was_failing AND l_service.last_check_time IS NOT NULL THEN
            l_downtime_minutes := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_service.last_check_time)) / 60;
        END IF;

        -- Reset failure counters in database
        UPDATE plt_service_discovery_config 
        SET consecutive_failures = 0,
            last_check_time = SYSTIMESTAMP,
            last_success_time = SYSTIMESTAMP,
            last_failure_reason = NULL
        WHERE service_name = l_service_name;

        -- Individual service recovery metrics
        l_recovery_attrs := create_stable_service_attributes(
            p_service_name => l_service_name,
            p_criticality => l_service.criticality_code,
            p_endpoint => l_service.endpoint_url,
            p_tenant_id => l_service.tenant_id
        );

        -- Always log healthy status
        PLTelemetry.log_metric(
            p_metric_name => 'service_healthy_status',
            p_value => 1,
            p_unit => 'status',
            p_attributes => l_recovery_attrs,
            p_include_trace_correlation => FALSE
        );

        -- Log recovery if service was previously failing
        IF l_was_failing THEN
            -- Recovery event metric
            PLTelemetry.log_metric(
                p_metric_name => 'service_recovery_event',
                p_value => 1,
                p_unit => 'count',
                p_attributes => l_recovery_attrs,
                p_include_trace_correlation => FALSE
            );

            -- Downtime metric if available
            IF l_downtime_minutes IS NOT NULL THEN
                PLTelemetry.log_metric(
                    p_metric_name => 'service_downtime_duration',
                    p_value => l_downtime_minutes,
                    p_unit => 'minutes',
                    p_attributes => l_recovery_attrs,
                    p_include_trace_correlation => FALSE
                );
            END IF;

            l_attrs(1) := PLTelemetry.add_attribute('service.name', l_service_name);
            l_attrs(2) := PLTelemetry.add_attribute('service.criticality', l_service.criticality_code);
            l_attrs(3) := PLTelemetry.add_attribute('recovery.status', p_health_result.status);
            l_attrs(4) := PLTelemetry.add_attribute('recovery.response_time', TO_CHAR(p_health_result.response_time_ms));
            IF l_service.tenant_id IS NOT NULL THEN
                l_attrs(5) := PLTelemetry.add_attribute('service.tenant_id', l_service.tenant_id);
            END IF;
            IF l_downtime_minutes IS NOT NULL THEN
                l_attrs(6) := PLTelemetry.add_attribute('downtime.minutes', TO_CHAR(l_downtime_minutes, '999999.99'));
            END IF;

            PLTelemetry.log_distributed(
                p_trace_id => PLTelemetry.get_current_trace_id(),
                p_level => 'INFO',
                p_message => 'Service ' || l_service_name || ' has recovered. Status: ' || p_health_result.status,
                p_system => 'PLT_SERVICE_DISCOVERY',
                p_tenant_id => l_service.tenant_id
            );

            PLTelemetry.add_event(
                PLTelemetry.get_current_span_id(),
                'service_recovery_detected',
                l_attrs
            );
        END IF;

        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('handle_service_recovery', l_error_msg);
            
            PLTelemetry.log_distributed(
                p_trace_id => PLTelemetry.get_current_trace_id(),
                p_level => 'ERROR',
                p_message => 'Failed to handle service recovery for ' || l_service_name || ': ' || SUBSTR(l_error_msg, 1, 200),
                p_system => 'PLT_SERVICE_DISCOVERY'
            );
    END handle_service_recovery;

    /**
     * Get list of services that should be checked now
     */
    FUNCTION get_services_due_for_check(
        p_force_all BOOLEAN DEFAULT FALSE,
        p_tenant_id VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR 
    IS
        l_cursor SYS_REFCURSOR;
        l_tenant_id VARCHAR2(100);
    BEGIN
        -- Normalize input
        l_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => TRUE);
        
        IF p_force_all THEN
            OPEN l_cursor FOR
                SELECT s.service_name, s.criticality_code, c.check_interval_minutes, s.tenant_id
                FROM plt_service_discovery_config s
                JOIN plt_service_discovery_crit_levels c ON s.criticality_code = c.criticality_code
                WHERE s.is_enabled = 1
                  AND (l_tenant_id IS NULL OR s.tenant_id = l_tenant_id)
                ORDER BY c.check_interval_minutes, s.service_name;
        ELSE
            OPEN l_cursor FOR
                SELECT s.service_name, s.criticality_code, 
                       calculate_escalated_interval(
                           c.check_interval_minutes,
                           s.consecutive_failures,
                           c.escalation_multiplier,
                           c.max_escalation_failures
                       ) as current_interval,
                       s.tenant_id
                FROM plt_service_discovery_config s
                JOIN plt_service_discovery_crit_levels c ON s.criticality_code = c.criticality_code
                WHERE s.is_enabled = 1
                  AND (l_tenant_id IS NULL OR s.tenant_id = l_tenant_id)
                  AND (s.last_check_time IS NULL 
                       OR s.last_check_time + INTERVAL '1' MINUTE * 
                          calculate_escalated_interval(
                              c.check_interval_minutes,
                              s.consecutive_failures,
                              c.escalation_multiplier,
                              c.max_escalation_failures
                          ) <= SYSTIMESTAMP)
                ORDER BY calculate_escalated_interval(
                             c.check_interval_minutes,
                             s.consecutive_failures,
                             c.escalation_multiplier,
                             c.max_escalation_failures
                         ), s.service_name;
        END IF;

        RETURN l_cursor;
    END get_services_due_for_check;

    --------------------------------------------------------------------------
    -- SERVICE MANAGEMENT (CRUD)
    --------------------------------------------------------------------------

    /**
     * Add a new service to discovery monitoring
     */
    PROCEDURE add_service(
        p_service_name VARCHAR2,
        p_description VARCHAR2,
        p_endpoint_url VARCHAR2,
        p_criticality_code VARCHAR2,
        p_timeout_seconds NUMBER DEFAULT 10,
        p_enabled NUMBER DEFAULT 1,
        p_tenant_id VARCHAR2 DEFAULT NULL
    ) 
    IS
        l_service_name VARCHAR2(50);
        l_description VARCHAR2(200);
        l_endpoint_url VARCHAR2(300);
        l_criticality_code VARCHAR2(10);
        l_tenant_id VARCHAR2(100);
    BEGIN
        -- Normalize & validate input parameters
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        l_description := normalize_string(p_description, p_max_length => 200, p_allow_null => FALSE);
        l_endpoint_url := normalize_string(p_endpoint_url, p_max_length => 300, p_allow_null => FALSE);
        l_criticality_code := normalize_string(p_criticality_code, p_max_length => 10, p_allow_null => FALSE);
        l_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => TRUE);
        
        IF l_service_name IS NULL OR l_description IS NULL OR l_endpoint_url IS NULL OR l_criticality_code IS NULL THEN
            RAISE_APPLICATION_ERROR(-20106, 'Service name, description, endpoint URL, and criticality code are required');
        END IF;
        
        INSERT INTO plt_service_discovery_config (
            service_name,
            service_description,
            endpoint_url,
            criticality_code,
            timeout_seconds,
            is_enabled,
            tenant_id,
            consecutive_failures
        ) VALUES (
            l_service_name,
            l_description,
            l_endpoint_url,
            l_criticality_code,
            NVL(p_timeout_seconds, 10),
            NVL(p_enabled, 1),
            l_tenant_id,
            0
        );

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Service added to discovery: ' || l_service_name,
            p_system => 'PLT_SERVICE_DISCOVERY',
            p_tenant_id => l_tenant_id
        );

        COMMIT;
        
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            RAISE_APPLICATION_ERROR(-20107, 'Service already exists: ' || l_service_name);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END add_service;

    /**
     * Remove a service from discovery monitoring
     */
    PROCEDURE remove_service(p_service_name VARCHAR2) 
    IS
        l_rows_deleted NUMBER;
        l_service_name VARCHAR2(50);
    BEGIN
        -- Normalize input
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        
        IF l_service_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20108, 'Service name cannot be null or empty');
        END IF;
        
        DELETE FROM plt_service_discovery_config 
        WHERE service_name = l_service_name;
        
        l_rows_deleted := SQL%ROWCOUNT;
        
        IF l_rows_deleted = 0 THEN
            RAISE_APPLICATION_ERROR(-20109, 'Service not found: ' || l_service_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'WARN',
            p_message => 'Service removed from discovery: ' || l_service_name,
            p_system => 'PLT_SERVICE_DISCOVERY'
        );

        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END remove_service;

    /**
     * Update service configuration
     */
    PROCEDURE update_service(
        p_service_name VARCHAR2,
        p_description VARCHAR2 DEFAULT NULL,
        p_endpoint_url VARCHAR2 DEFAULT NULL,
        p_criticality_code VARCHAR2 DEFAULT NULL,
        p_timeout_seconds NUMBER DEFAULT NULL,
        p_tenant_id VARCHAR2 DEFAULT NULL
    ) 
    IS
        l_rows_updated NUMBER;
        l_service_name VARCHAR2(50);
        l_description VARCHAR2(200);
        l_endpoint_url VARCHAR2(300);
        l_criticality_code VARCHAR2(10);
        l_tenant_id VARCHAR2(100);
    BEGIN
        -- Normalize input parameters
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        l_description := normalize_string(p_description, p_max_length => 200, p_allow_null => TRUE);
        l_endpoint_url := normalize_string(p_endpoint_url, p_max_length => 300, p_allow_null => TRUE);
        l_criticality_code := normalize_string(p_criticality_code, p_max_length => 10, p_allow_null => TRUE);
        l_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => TRUE);
        
        IF l_service_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20110, 'Service name cannot be null or empty');
        END IF;
        
        UPDATE plt_service_discovery_config 
        SET service_description = NVL(l_description, service_description),
            endpoint_url = NVL(l_endpoint_url, endpoint_url),
            criticality_code = NVL(l_criticality_code, criticality_code),
            timeout_seconds = NVL(p_timeout_seconds, timeout_seconds),
            tenant_id = NVL(l_tenant_id, tenant_id),
            updated_at = SYSTIMESTAMP
        WHERE service_name = l_service_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20111, 'Service not found: ' || l_service_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Service configuration updated: ' || l_service_name,
            p_system => 'PLT_SERVICE_DISCOVERY'
        );

        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END update_service;

    /**
     * Enable/disable monitoring for a specific service
     */
    PROCEDURE set_service_monitoring(
        p_service_name VARCHAR2, 
        p_enabled NUMBER
    ) 
    IS
        l_rows_updated NUMBER;
        l_service_name VARCHAR2(50);
    BEGIN
        -- Normalize input
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        
        IF l_service_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20112, 'Service name cannot be null or empty');
        END IF;
        
        UPDATE plt_service_discovery_config 
        SET is_enabled = p_enabled,
            updated_at = SYSTIMESTAMP
        WHERE service_name = l_service_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20113, 'Service not found: ' || l_service_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Service monitoring ' || 
                        CASE WHEN p_enabled = 1 THEN 'enabled' ELSE 'disabled' END || 
                        ' for: ' || l_service_name,
            p_system => 'PLT_SERVICE_DISCOVERY'
        );

        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END set_service_monitoring;

    /**
     * Reset failure counters for a service (emergency reset)
     */
    PROCEDURE reset_service_failures(p_service_name VARCHAR2) 
    IS
        l_rows_updated NUMBER;
        l_service_name VARCHAR2(50);
    BEGIN
        -- Normalize input
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        
        IF l_service_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20114, 'Service name cannot be null or empty');
        END IF;
        
        UPDATE plt_service_discovery_config 
        SET consecutive_failures = 0,
            last_failure_reason = NULL,
            updated_at = SYSTIMESTAMP
        WHERE service_name = l_service_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20115, 'Service not found: ' || l_service_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'WARN',
            p_message => 'Failure counters reset for service: ' || l_service_name,
            p_system => 'PLT_SERVICE_DISCOVERY'
        );

        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END reset_service_failures;

    --------------------------------------------------------------------------
    -- REPORTING AND ANALYTICS
    --------------------------------------------------------------------------

    /**
     * Generate comprehensive service discovery report from database tables
     */
    FUNCTION generate_discovery_report(
        p_hours_back NUMBER DEFAULT 24,
        p_tenant_id VARCHAR2 DEFAULT NULL
    ) RETURN CLOB 
    IS
        l_report CLOB;
        l_json_chunk VARCHAR2(4000);
        l_first_service BOOLEAN := TRUE;
        l_tenant_id VARCHAR2(100);
        l_error_msg VARCHAR2(4000);
    BEGIN
        -- Normalize input
        l_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => TRUE);
        
        DBMS_LOB.CREATETEMPORARY(l_report, TRUE);
        
        -- Build JSON report header
        l_json_chunk := '{'
            || '"report_timestamp":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'
            || '"hours_back":' || NVL(p_hours_back, 24) || ','
            || '"tenant_filter":"' || NVL(l_tenant_id, 'all') || '",'
            || '"services":[';
        DBMS_LOB.WRITEAPPEND(l_report, LENGTH(l_json_chunk), l_json_chunk);

        -- Add service details from database
        FOR rec IN (
            SELECT s.service_name,
                   s.service_description,
                   s.criticality_code,
                   c.check_interval_minutes,
                   s.consecutive_failures,
                   s.last_check_time,
                   s.last_success_time,
                   s.last_failure_reason,
                   s.is_enabled,
                   s.tenant_id,
                   CASE 
                       WHEN s.consecutive_failures >= c.max_escalation_failures THEN 2
                       WHEN s.consecutive_failures >= (c.max_escalation_failures / 2) THEN 1
                       ELSE 0
                   END as escalation_level
            FROM plt_service_discovery_config s
            JOIN plt_service_discovery_crit_levels c ON s.criticality_code = c.criticality_code
            WHERE (l_tenant_id IS NULL OR s.tenant_id = l_tenant_id)
            ORDER BY c.check_interval_minutes, s.service_name
        ) LOOP
            IF NOT l_first_service THEN
                DBMS_LOB.WRITEAPPEND(l_report, 1, ',');
            END IF;
            l_first_service := FALSE;
            
            l_json_chunk := '{'
                || '"name":"' || rec.service_name || '",'
                || '"description":"' || REPLACE(rec.service_description, '"', '\"') || '",'
                || '"criticality":"' || rec.criticality_code || '",'
                || '"check_interval_minutes":' || rec.check_interval_minutes || ','
                || '"consecutive_failures":' || rec.consecutive_failures || ','
                || '"escalation_level":' || rec.escalation_level || ','
                || '"enabled":' || CASE WHEN rec.is_enabled = 1 THEN 'true' ELSE 'false' END || ','
                || '"tenant_id":"' || NVL(rec.tenant_id, 'default') || '",'
                || '"last_check_time":"' || 
                   CASE WHEN rec.last_check_time IS NOT NULL 
                        THEN TO_CHAR(rec.last_check_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"')
                        ELSE 'never'
                   END || '",'
                || '"last_success_time":"' || 
                   CASE WHEN rec.last_success_time IS NOT NULL 
                        THEN TO_CHAR(rec.last_success_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"')
                        ELSE 'never'
                   END || '",'
                || '"last_failure_reason":"' || NVL(REPLACE(rec.last_failure_reason, '"', '\"'), 'none') || '"'
                || '}';
            
            DBMS_LOB.WRITEAPPEND(l_report, LENGTH(l_json_chunk), l_json_chunk);
        END LOOP;

        DBMS_LOB.WRITEAPPEND(l_report, 2, ']}');
        
        RETURN l_report;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('generate_discovery_report', l_error_msg);
            
            IF DBMS_LOB.ISTEMPORARY(l_report) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_report);
            END IF;
            
            DBMS_LOB.CREATETEMPORARY(l_report, TRUE);
            l_json_chunk := '{"error":"Failed to generate report: ' || REPLACE(SUBSTR(l_error_msg, 1, 200), '"', '\"') || '"}';
            DBMS_LOB.WRITEAPPEND(l_report, LENGTH(l_json_chunk), l_json_chunk);
            
            RETURN l_report;
    END generate_discovery_report;

    /**
     * Get current service runtime configuration
     */
    FUNCTION get_service_runtime(p_service_name VARCHAR2) 
    RETURN t_service_runtime 
    IS
    BEGIN
        RETURN load_service_runtime(p_service_name);
    END get_service_runtime;

    /**
     * Get service discovery health summary for all tenants
     */
    FUNCTION get_discovery_health_summary 
    RETURN CLOB 
    IS
        l_summary CLOB;
        l_json_chunk VARCHAR2(4000);
        l_first_tenant BOOLEAN := TRUE;
        l_error_msg VARCHAR2(4000);
    BEGIN
        DBMS_LOB.CREATETEMPORARY(l_summary, TRUE);
        
        -- Build JSON summary header
        l_json_chunk := '{'
            || '"summary_timestamp":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'
            || '"tenants":[';
        DBMS_LOB.WRITEAPPEND(l_summary, LENGTH(l_json_chunk), l_json_chunk);

        -- Add tenant summaries
        FOR rec IN (
            SELECT 
                NVL(s.tenant_id, 'default') as tenant_id,
                COUNT(*) as total_services,
                SUM(CASE WHEN s.is_enabled = 1 THEN 1 ELSE 0 END) as enabled_services,
                SUM(CASE WHEN s.consecutive_failures = 0 AND s.is_enabled = 1 THEN 1 ELSE 0 END) as healthy_services,
                SUM(CASE WHEN s.consecutive_failures > 0 AND s.is_enabled = 1 THEN 1 ELSE 0 END) as failing_services,
                AVG(CASE WHEN s.is_enabled = 1 THEN s.consecutive_failures ELSE NULL END) as avg_failures
            FROM plt_service_discovery_config s
            GROUP BY NVL(s.tenant_id, 'default')
            ORDER BY NVL(s.tenant_id, 'default')
        ) LOOP
            IF NOT l_first_tenant THEN
                DBMS_LOB.WRITEAPPEND(l_summary, 1, ',');
            END IF;
            l_first_tenant := FALSE;
            
            l_json_chunk := '{'
                || '"tenant_id":"' || rec.tenant_id || '",'
                || '"total_services":' || rec.total_services || ','
                || '"enabled_services":' || rec.enabled_services || ','
                || '"healthy_services":' || rec.healthy_services || ','
                || '"failing_services":' || rec.failing_services || ','
                || '"health_percentage":' || 
                   CASE WHEN rec.enabled_services > 0 
                        THEN ROUND((rec.healthy_services / rec.enabled_services) * 100, 2)
                        ELSE 0 
                   END || ','
                || '"avg_failures":' || NVL(ROUND(rec.avg_failures, 2), 0)
                || '}';
            
            DBMS_LOB.WRITEAPPEND(l_summary, LENGTH(l_json_chunk), l_json_chunk);
        END LOOP;

        DBMS_LOB.WRITEAPPEND(l_summary, 2, ']}');
        
        RETURN l_summary;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('get_discovery_health_summary', l_error_msg);
            
            IF DBMS_LOB.ISTEMPORARY(l_summary) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_summary);
            END IF;
            
            DBMS_LOB.CREATETEMPORARY(l_summary, TRUE);
            l_json_chunk := '{"error":"Failed to generate summary: ' || REPLACE(SUBSTR(l_error_msg, 1, 200), '"', '\"') || '"}';
            DBMS_LOB.WRITEAPPEND(l_summary, LENGTH(l_json_chunk), l_json_chunk);
            
            RETURN l_summary;
    END get_discovery_health_summary;

    --------------------------------------------------------------------------
    -- TENANT CONTEXT MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * Set tenant context for service discovery operations
     */
    PROCEDURE set_tenant_context(p_tenant_id VARCHAR2, p_tenant_name VARCHAR2 DEFAULT NULL)
    IS
        l_tenant_id VARCHAR2(100);
        l_tenant_name VARCHAR2(255);
    BEGIN
        -- Normalize & validate input parameters
        l_tenant_id := normalize_string(p_tenant_id, p_max_length => 100, p_allow_null => FALSE);
        l_tenant_name := normalize_string(p_tenant_name, p_max_length => 255, p_allow_null => TRUE);
        
        g_current_tenant_id := l_tenant_id;
        g_current_tenant_name := l_tenant_name;
        
        -- Also set PLTelemetry tenant context
        PLTelemetry.set_tenant_context(l_tenant_id, l_tenant_name);
    END set_tenant_context;

    /**
     * Clear tenant context
     */
    PROCEDURE clear_tenant_context
    IS
    BEGIN
        g_current_tenant_id := NULL;
        g_current_tenant_name := NULL;
        
        -- Also clear PLTelemetry tenant context
        PLTelemetry.clear_tenant_context();
    END clear_tenant_context;

    /**
     * Get current tenant ID
     */
    FUNCTION get_current_tenant_id 
    RETURN VARCHAR2 
    IS
    BEGIN
        RETURN g_current_tenant_id;
    END get_current_tenant_id;


    /**
    * Substitute template variables in a string
    */
    FUNCTION substitute_template_variables(
        p_template IN VARCHAR2,
        p_context IN t_execution_context
    ) RETURN VARCHAR2
    IS
        l_result VARCHAR2(4000);
        l_template VARCHAR2(4000);
    BEGIN
        -- Normalize input
        l_template := normalize_string(p_template, p_max_length => 4000, p_allow_null => TRUE);
        
        IF l_template IS NULL THEN
            RETURN NULL;
        END IF;
        
        l_result := l_template;
        
        -- Replace known template variables
        l_result := REPLACE(l_result, '{{http_status}}', TO_CHAR(NVL(p_context.http_status, 0)));
        l_result := REPLACE(l_result, '{{http_response_time}}', TO_CHAR(NVL(p_context.http_response_time, 0)));
        l_result := REPLACE(l_result, '{{service_name}}', NVL(p_context.service_name, 'unknown'));
        l_result := REPLACE(l_result, '{{tenant_id}}', NVL(p_context.tenant_id, 'default'));
        
        -- Add more variables as needed in the future
        -- l_result := REPLACE(l_result, '{{custom_var}}', p_context.custom_var);
        
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('substitute_template_variables', 
                            'Template substitution failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RETURN l_template; -- Return original on error
    END substitute_template_variables;

    /**
    * Execute HTTP call action from custom plan
    */
    FUNCTION execute_http_call_action(
        p_action_json IN VARCHAR2,
        p_context IN OUT t_execution_context,
        p_span_id IN VARCHAR2
    ) RETURN t_execution_context
    IS
        l_url VARCHAR2(300);
        l_timeout NUMBER;
        l_req UTL_HTTP.REQ;
        l_resp UTL_HTTP.RESP;
        l_response_body VARCHAR2(4000);
        l_buffer VARCHAR2(32767);
        l_start_time TIMESTAMP := SYSTIMESTAMP;
        l_attrs PLTelemetry.t_attributes;
        l_action_json VARCHAR2(4000);
        l_error_msg VARCHAR2(4000);
    BEGIN
        -- Normalize input
        l_action_json := normalize_string(p_action_json, p_max_length => 4000, p_allow_null => FALSE);
        
        IF l_action_json IS NULL THEN
            RAISE_APPLICATION_ERROR(-20200, 'HTTP call action JSON cannot be null');
        END IF;
        
        -- Parse HTTP call configuration
        BEGIN
            l_url := JSON_VALUE(l_action_json, '$.http_call.url');
            l_timeout := NVL(JSON_VALUE(l_action_json, '$.http_call.timeout'), 10);
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20201, 'Invalid http_call JSON configuration');
        END;
        
        -- Validate required fields
        IF l_url IS NULL THEN
            RAISE_APPLICATION_ERROR(-20202, 'http_call.url is required');
        END IF;
        
        -- Substitute template variables in URL
        l_url := substitute_template_variables(l_url, p_context);
        
        -- Add telemetry event
        l_attrs(1) := PLTelemetry.add_attribute('action.type', 'http_call');
        l_attrs(2) := PLTelemetry.add_attribute('http.url', l_url);
        l_attrs(3) := PLTelemetry.add_attribute('http.timeout', TO_CHAR(l_timeout));
        PLTelemetry.add_event(p_span_id, 'custom_plan_http_call_start', l_attrs);
        
        BEGIN
            -- Set timeout
            UTL_HTTP.SET_TRANSFER_TIMEOUT(l_timeout);
            
            -- Make HTTP request
            l_req := UTL_HTTP.BEGIN_REQUEST(l_url, 'GET', 'HTTP/1.1');
            UTL_HTTP.SET_HEADER(l_req, 'User-Agent', 'PLTelemetry-CustomPlan/1.0');
            UTL_HTTP.SET_HEADER(l_req, 'Accept', 'application/json');
            UTL_HTTP.SET_HEADER(l_req, 'X-Monitor-Source', 'Oracle-PLTelemetry-Custom');
            UTL_HTTP.SET_HEADER(l_req, 'X-Service-Name', p_context.service_name);
            
            l_resp := UTL_HTTP.GET_RESPONSE(l_req);
            p_context.http_status := l_resp.status_code;
            
            -- Read response body
            BEGIN
                UTL_HTTP.READ_TEXT(l_resp, l_buffer, 4000);
                l_response_body := l_buffer;
            EXCEPTION
                WHEN UTL_HTTP.END_OF_BODY THEN
                    NULL; -- Normal end of response
            END;
            p_context.http_response_body := l_response_body;
            
            UTL_HTTP.END_RESPONSE(l_resp);
            
            -- Calculate response time
            p_context.http_response_time := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000;
            
            -- Add success telemetry
            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('action.type', 'http_call');
            l_attrs(2) := PLTelemetry.add_attribute('http.status_code', TO_CHAR(p_context.http_status));
            l_attrs(3) := PLTelemetry.add_attribute('http.response_time_ms', TO_CHAR(p_context.http_response_time));
            PLTelemetry.add_event(p_span_id, 'custom_plan_http_call_success', l_attrs);
            
        EXCEPTION
            WHEN UTL_HTTP.TRANSFER_TIMEOUT THEN
                p_context.http_status := -1;
                p_context.http_response_time := -1;
                p_context.http_response_body := 'TIMEOUT';
                
                PLTelemetry.add_event(p_span_id, 'custom_plan_http_call_timeout');
                
            WHEN UTL_HTTP.REQUEST_FAILED THEN
                p_context.http_status := -2;
                p_context.http_response_time := -1;
                p_context.http_response_body := 'CONNECTION_FAILED';
                
                PLTelemetry.add_event(p_span_id, 'custom_plan_http_call_failed');
                
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200);
                p_context.http_status := -3;
                p_context.http_response_time := -1;
                p_context.http_response_body := 'ERROR: ' || l_error_msg;
                
                l_attrs := PLTelemetry.t_attributes();
                l_attrs(1) := PLTelemetry.add_attribute('action.type', 'http_call');
                l_attrs(2) := PLTelemetry.add_attribute('error.message', l_error_msg);
                PLTelemetry.add_event(p_span_id, 'custom_plan_http_call_error', l_attrs);
        END;
        
        RETURN p_context;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('execute_http_call_action', l_error_msg);
            
            -- Set error context
            p_context.http_status := -4;
            p_context.http_response_time := -1;
            p_context.http_response_body := 'CRITICAL_ERROR';
            
            RETURN p_context;
    END execute_http_call_action;

    /**
    * Execute send_metric action from custom plan
    */
    PROCEDURE execute_send_metric_action(
        p_action_json IN VARCHAR2,
        p_context IN t_execution_context,
        p_span_id IN VARCHAR2
    )
    IS
        l_metric_name VARCHAR2(255);
        l_metric_value VARCHAR2(100);
        l_metric_unit VARCHAR2(50);
        l_labels_json VARCHAR2(4000);
        l_labels_obj JSON_OBJECT_T;
        l_keys JSON_KEY_LIST;
        l_attrs PLTelemetry.t_attributes;
        l_idx NUMBER := 1;
        l_key VARCHAR2(255);
        l_value VARCHAR2(4000);
        l_final_value NUMBER;
        l_action_json VARCHAR2(4000);
        l_error_msg VARCHAR2(4000);
    BEGIN
        -- Normalize input
        l_action_json := normalize_string(p_action_json, p_max_length => 4000, p_allow_null => FALSE);
        
        IF l_action_json IS NULL THEN
            RAISE_APPLICATION_ERROR(-20203, 'Send metric action JSON cannot be null');
        END IF;
        
        -- Parse send_metric configuration
        BEGIN
            l_metric_name := JSON_VALUE(l_action_json, '$.send_metric.name');
            l_metric_value := JSON_VALUE(l_action_json, '$.send_metric.value');
            l_metric_unit := NVL(JSON_VALUE(l_action_json, '$.send_metric.unit'), 'unit');
            l_labels_json := JSON_QUERY(l_action_json, '$.send_metric.labels');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20204, 'Invalid send_metric JSON configuration');
        END;
        
        -- Validate required fields
        IF l_metric_name IS NULL OR l_metric_value IS NULL THEN
            RAISE_APPLICATION_ERROR(-20205, 'send_metric.name and send_metric.value are required');
        END IF;
        
        -- Substitute template variables
        l_metric_name := substitute_template_variables(l_metric_name, p_context);
        l_metric_value := substitute_template_variables(l_metric_value, p_context);
        l_metric_unit := substitute_template_variables(l_metric_unit, p_context);
        
        -- Convert metric value to number
        BEGIN
            l_final_value := TO_NUMBER(l_metric_value);
        EXCEPTION
            WHEN OTHERS THEN
                -- If conversion fails, use a sentinel value
                l_final_value := CASE 
                    WHEN UPPER(l_metric_value) = 'TRUE' THEN 1
                    WHEN UPPER(l_metric_value) = 'FALSE' THEN 0
                    ELSE -1
                END;
        END;
        
        -- Process labels if present
        IF l_labels_json IS NOT NULL AND l_labels_json != '{}' THEN
            l_labels_obj := JSON_OBJECT_T.parse(l_labels_json);
            l_keys := l_labels_obj.get_keys();
            
            FOR i IN 1 .. l_keys.COUNT LOOP
                l_key := l_keys(i);
                l_value := l_labels_obj.get_string(l_key);
                
                -- Substitute template variables in label values
                l_value := substitute_template_variables(l_value, p_context);
                
                l_attrs(l_idx) := PLTelemetry.add_attribute(l_key, l_value);
                l_idx := l_idx + 1;
            END LOOP;
        END IF;
        
        -- Add action context
        l_attrs(l_idx) := PLTelemetry.add_attribute('action.type', 'send_metric');
        l_idx := l_idx + 1;
        l_attrs(l_idx) := PLTelemetry.add_attribute('metric.source', 'custom_plan');
        
        -- Send the metric using PLTelemetry
        PLTelemetry.log_metric(
            p_metric_name => l_metric_name,
            p_value => l_final_value,
            p_unit => l_metric_unit,
            p_attributes => l_attrs,
            p_include_trace_correlation => FALSE  -- Stable labels for Grafana
        );
        
        -- Add telemetry event
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('action.type', 'send_metric');
        l_attrs(2) := PLTelemetry.add_attribute('metric.name', l_metric_name);
        l_attrs(3) := PLTelemetry.add_attribute('metric.value', TO_CHAR(l_final_value));
        l_attrs(4) := PLTelemetry.add_attribute('metric.unit', l_metric_unit);
        PLTelemetry.add_event(p_span_id, 'custom_plan_metric_sent', l_attrs);
        
    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            log_error_internal('execute_send_metric_action', l_error_msg);
            
            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('action.type', 'send_metric');
            l_attrs(2) := PLTelemetry.add_attribute('error.message', SUBSTR(l_error_msg, 1, 200));
            PLTelemetry.add_event(p_span_id, 'custom_plan_metric_error', l_attrs);
    END execute_send_metric_action;

    /**
    * Execute a custom monitoring plan from JSON configuration
    */
    FUNCTION execute_custom_plan(
        p_service_name IN VARCHAR2,
        p_custom_plan_json IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_health_result
    IS
        l_result t_health_result;
        l_context t_execution_context;
        l_plan_json VARCHAR2(4000);
        l_actions_array JSON_ARRAY_T;
        l_action_obj JSON_OBJECT_T;
        l_action_json VARCHAR2(4000);
        l_span_id VARCHAR2(16);
        l_trace_id VARCHAR2(32);
        l_attrs PLTelemetry.t_attributes;
        l_service_name VARCHAR2(50);
        l_plan_name VARCHAR2(100);
        l_plan_description VARCHAR2(500);
        l_action_count NUMBER := 0;
        l_error_msg VARCHAR2(4000);
        l_start_time TIMESTAMP := SYSTIMESTAMP;
    BEGIN
        -- Normalize & validate input parameters
        l_service_name := normalize_string(p_service_name, p_max_length => 50, p_allow_null => FALSE);
        l_plan_json := normalize_string(p_custom_plan_json, p_max_length => 4000, p_allow_null => FALSE);
        
        IF l_service_name IS NULL OR l_plan_json IS NULL THEN
            RAISE_APPLICATION_ERROR(-20206, 'Service name and custom plan JSON are required');
        END IF;
        
        -- Initialize result
        l_result.service_name := l_service_name;
        l_result.check_timestamp := SYSTIMESTAMP;
        l_result.status := C_HEALTHY; -- Assume success until proven otherwise
        
        -- Initialize execution context
        l_context.service_name := l_service_name;
        
        -- CRITICAL FIX: Get tenant_id from service config for OTLP bridge
        BEGIN
            SELECT tenant_id INTO l_context.tenant_id
            FROM plt_service_discovery_config 
            WHERE service_name = l_service_name;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                l_context.tenant_id := NULL;
        END;
        
        -- Start or continue distributed trace
        IF p_trace_id IS NOT NULL THEN
            l_trace_id := p_trace_id;
            l_span_id := PLTelemetry.continue_distributed_trace(
                p_trace_id => p_trace_id,
                p_operation => 'custom_plan_execution_' || l_service_name
            );
        ELSE
            l_trace_id := PLTelemetry.start_trace('custom_plan_' || l_service_name);
            l_span_id := PLTelemetry.start_span('custom_plan_execution');
        END IF;
        
        -- Parse plan metadata
        BEGIN
            l_plan_name := JSON_VALUE(l_plan_json, '$.name');
            l_plan_description := JSON_VALUE(l_plan_json, '$.description');
            l_actions_array := JSON_ARRAY_T.parse(JSON_QUERY(l_plan_json, '$.actions'));
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20207, 'Invalid custom plan JSON structure');
        END;
        
        -- Add plan context to telemetry
        l_attrs(1) := PLTelemetry.add_attribute('plan.name', NVL(l_plan_name, 'unnamed'));
        l_attrs(2) := PLTelemetry.add_attribute('plan.description', NVL(l_plan_description, 'no description'));
        l_attrs(3) := PLTelemetry.add_attribute('plan.action_count', TO_CHAR(l_actions_array.get_size()));
        l_attrs(4) := PLTelemetry.add_attribute('service.name', l_service_name);
        l_attrs(5) := PLTelemetry.add_attribute('execution.type', 'custom_plan');
        PLTelemetry.add_event(l_span_id, 'custom_plan_execution_started', l_attrs);
        
        -- Execute actions sequentially
        FOR i IN 0 .. l_actions_array.get_size() - 1 LOOP
            l_action_count := l_action_count + 1;
            l_action_obj := JSON_OBJECT_T(l_actions_array.get(i));
            l_action_json := l_action_obj.to_string();
            
            -- Determine action type and execute
            IF JSON_EXISTS(l_action_json, '$.http_call') THEN
                l_context := execute_http_call_action(l_action_json, l_context, l_span_id);
                
            ELSIF JSON_EXISTS(l_action_json, '$.send_metric') THEN
                execute_send_metric_action(l_action_json, l_context, l_span_id);
                
            ELSE
                -- Unknown action type - log but continue
                l_attrs := PLTelemetry.t_attributes();
                l_attrs(1) := PLTelemetry.add_attribute('action.index', TO_CHAR(i));
                l_attrs(2) := PLTelemetry.add_attribute('action.json', SUBSTR(l_action_json, 1, 200));
                PLTelemetry.add_event(l_span_id, 'custom_plan_unknown_action', l_attrs);
            END IF;
        END LOOP;
        
        -- Determine final result based on HTTP calls
        IF l_context.http_status > 0 THEN
            l_result.status_code := l_context.http_status;
            l_result.response_time_ms := l_context.http_response_time;
            l_result.response_body := l_context.http_response_body;
            
            -- Determine health status based on HTTP status
            IF l_context.http_status = 200 THEN
                l_result.status := C_HEALTHY;
            ELSIF l_context.http_status BETWEEN 201 AND 299 THEN
                l_result.status := C_HEALTHY;
            ELSIF l_context.http_status BETWEEN 400 AND 499 THEN
                l_result.status := C_DEGRADED;
                l_result.error_message := 'HTTP client error: ' || l_context.http_status;
            ELSIF l_context.http_status BETWEEN 500 AND 599 THEN
                l_result.status := C_UNHEALTHY;
                l_result.error_message := 'HTTP server error: ' || l_context.http_status;
            ELSE
                l_result.status := C_ERROR;
                l_result.error_message := 'Unexpected HTTP status: ' || l_context.http_status;
            END IF;
        ELSIF l_context.http_status = -1 THEN
            l_result.status := C_TIMEOUT;
            l_result.error_message := 'Request timeout';
            l_result.response_time_ms := -1;
        ELSIF l_context.http_status = -2 THEN
            l_result.status := C_DOWN;
            l_result.error_message := 'Connection failed';
            l_result.response_time_ms := -1;
        ELSE
            l_result.status := C_ERROR;
            l_result.error_message := 'Custom plan execution error';
            l_result.response_time_ms := -1;
        END IF;
        
        -- Calculate total execution time if not set by HTTP call
        IF l_result.response_time_ms IS NULL THEN
            l_result.response_time_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000;
        END IF;
        
        -- Add final result to telemetry
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('plan.actions_executed', TO_CHAR(l_action_count));
        l_attrs(2) := PLTelemetry.add_attribute('result.status', l_result.status);
        l_attrs(3) := PLTelemetry.add_attribute('result.http_status', TO_CHAR(NVL(l_result.status_code, 0)));
        l_attrs(4) := PLTelemetry.add_attribute('result.response_time_ms', TO_CHAR(NVL(l_result.response_time_ms, 0)));
        PLTelemetry.add_event(l_span_id, 'custom_plan_execution_completed', l_attrs);
        
        -- End span based on result
        IF l_result.status IN (C_HEALTHY, C_DEGRADED) THEN
            PLTelemetry.end_span(l_span_id, 'OK');
        ELSE
            PLTelemetry.end_span(l_span_id, 'ERROR');
        END IF;
        
        -- End trace if we started it
        IF p_trace_id IS NULL THEN
            PLTelemetry.end_trace(l_trace_id);
        END IF;
        
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
            
            l_result.status := C_ERROR;
            l_result.error_message := 'Custom plan execution failed: ' || SUBSTR(l_error_msg, 1, 500);
            l_result.response_time_ms := -1;
            
            -- Log error
            log_error_internal('execute_custom_plan', l_error_msg, l_trace_id, l_span_id);
            
            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SUBSTR(l_error_msg, 1, 200));
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            
            PLTelemetry.log_distributed(
                p_trace_id => l_trace_id,
                p_level => 'ERROR',
                p_message => 'Custom plan execution critical failure for ' || l_service_name || ': ' || SUBSTR(l_error_msg, 1, 200),
                p_system => 'PLT_SERVICE_DISCOVERY'
            );
            
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            
            IF p_trace_id IS NULL THEN
                PLTelemetry.end_trace(l_trace_id);
            END IF;
            
            RETURN l_result;
    END execute_custom_plan;


END PLT_SERVICE_DISCOVERY;
/