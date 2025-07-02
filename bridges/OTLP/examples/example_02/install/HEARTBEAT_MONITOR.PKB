-- =============================================================================
-- HEARTBEAT_MONITOR Package Body - Modified for Individual Service Metrics
-- FIXED: All DOWN services now return -1ms instead of 99999ms
-- =============================================================================
-- Changes:
-- 1. Removed ALL aggregated metrics (services_checked, services_healthy, etc.)
-- 2. Added individual service metrics with proper labels
-- 3. Each service now generates its own time series
-- 4. Status tracking via labels instead of numeric values
-- 5. FIXED: DOWN/ERROR/TIMEOUT services now report -1ms for clean observability
-- =============================================================================

CREATE OR REPLACE PACKAGE BODY HEARTBEAT_MONITOR AS

    -- Global configuration flags
    g_telemetry_configured BOOLEAN := FALSE;

    --------------------------------------------------------------------------
    -- PRIVATE HELPER FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Parse JSON health response - simple extraction
     */
    FUNCTION parse_health_response(p_json_response VARCHAR2, p_key VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        -- Try native JSON parsing first
        RETURN JSON_VALUE(p_json_response, '$.' || p_key);
    EXCEPTION
        WHEN OTHERS THEN
            -- Fallback to regex parsing
            DECLARE
                l_pattern VARCHAR2(200);
                l_value VARCHAR2(4000);
            BEGIN
                l_pattern := '"' || p_key || '"\s*:\s*"([^"]+)"';
                l_value := REGEXP_SUBSTR(p_json_response, l_pattern, 1, 1, NULL, 1);
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
    ) RETURN NUMBER IS
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

    /**
     * Load service runtime configuration from database
     */
    FUNCTION load_service_runtime(p_service_name VARCHAR2) RETURN t_service_runtime IS
        l_runtime t_service_runtime;
    BEGIN
        SELECT 
            s.service_id,
            s.service_name,
            s.service_description,
            s.endpoint_url,
            s.criticality_code,
            s.timeout_seconds,
            s.is_enabled,
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
                CASE 
                    WHEN s.consecutive_failures = 0 THEN c.check_interval_minutes
                    ELSE GREATEST(1, c.check_interval_minutes * c.escalation_multiplier)
                END,
            -- Criticality settings
            c.check_interval_minutes,
            CASE 
                WHEN s.consecutive_failures = 0 THEN c.check_interval_minutes
                ELSE GREATEST(1, c.check_interval_minutes * c.escalation_multiplier)
            END,
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
            l_runtime.last_check_time,
            l_runtime.consecutive_failures,
            l_runtime.escalation_level,
            l_runtime.next_check_due,
            l_runtime.base_check_interval,
            l_runtime.current_check_interval,
            l_runtime.escalation_multiplier,
            l_runtime.max_escalation_failures
        FROM heartbeat_services s
        JOIN heartbeat_criticality_levels c ON s.criticality_code = c.criticality_code
        WHERE s.service_name = p_service_name;

        RETURN l_runtime;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'Service not found: ' || p_service_name);
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20002, 'Error loading service runtime: ' || SQLERRM);
    END load_service_runtime;

    /**
     * Create service-specific attributes for metrics (STABLE LABELS ONLY)
     */
    FUNCTION create_service_attributes(
        p_service_name VARCHAR2,
        p_status VARCHAR2,
        p_criticality VARCHAR2,
        p_endpoint VARCHAR2,
        p_consecutive_failures NUMBER DEFAULT NULL
    ) RETURN PLTelemetry.t_attributes IS
        l_attrs PLTelemetry.t_attributes;
        l_idx NUMBER := 1;
    BEGIN
        l_attrs(l_idx) := PLTelemetry.add_attribute('service_name', p_service_name);
        l_idx := l_idx + 1;
        
        l_attrs(l_idx) := PLTelemetry.add_attribute('status', p_status);
        l_idx := l_idx + 1;
        
        l_attrs(l_idx) := PLTelemetry.add_attribute('criticality', p_criticality);
        l_idx := l_idx + 1;
        
        -- Extract just the port from endpoint for cleaner labeling
        l_attrs(l_idx) := PLTelemetry.add_attribute('endpoint_port', 
            REGEXP_SUBSTR(p_endpoint, ':([0-9]+)', 1, 1, NULL, 1));
        l_idx := l_idx + 1;
        
        -- REMOVED: consecutive_failures from main metrics (causes multiple time series)
        -- This will be a separate metric instead
        
        RETURN l_attrs;
    END create_service_attributes;

    /**
     * Create service-specific attributes for STABLE metrics only (no changing labels)
     */
    FUNCTION create_stable_service_attributes(
        p_service_name VARCHAR2,
        p_criticality VARCHAR2,
        p_endpoint VARCHAR2
    ) RETURN PLTelemetry.t_attributes IS
        l_attrs PLTelemetry.t_attributes;
        l_idx NUMBER := 1;
    BEGIN
        l_attrs(l_idx) := PLTelemetry.add_attribute('service_name', p_service_name);
        l_idx := l_idx + 1;
        
        l_attrs(l_idx) := PLTelemetry.add_attribute('criticality', p_criticality);
        l_idx := l_idx + 1;
        
        -- Extract just the port from endpoint for cleaner labeling
        l_attrs(l_idx) := PLTelemetry.add_attribute('endpoint_port', 
            REGEXP_SUBSTR(p_endpoint, ':([0-9]+)', 1, 1, NULL, 1));
        
        RETURN l_attrs;
    END create_stable_service_attributes;

    --------------------------------------------------------------------------
    -- PUBLIC PROCEDURES
    --------------------------------------------------------------------------

    PROCEDURE configure_telemetry IS
    BEGIN
        IF NOT g_telemetry_configured THEN
            -- Configure PLTelemetry for heartbeat monitoring
            PLTelemetry.set_backend_url('OTLP_BRIDGE');
            PLT_OTLP_BRIDGE.set_otlp_collector('http://192.168.100.116:4318');
            PLT_OTLP_BRIDGE.set_service_info('oracle-heartbeat-monitor', '2.0.0', 'production');
            PLT_OTLP_BRIDGE.set_native_json_mode(TRUE);
            PLTelemetry.set_async_mode(FALSE);
            PLT_OTLP_BRIDGE.set_debug_mode(FALSE);
            
            g_telemetry_configured := TRUE;
        END IF;
    END configure_telemetry;

    FUNCTION check_service_health(
        p_service_name IN VARCHAR2,
        p_trace_id IN VARCHAR2 DEFAULT NULL
    ) RETURN t_health_result IS
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
    BEGIN
        -- Ensure telemetry is configured
        configure_telemetry();

        -- Load service configuration
        l_service := load_service_runtime(p_service_name);

        -- Initialize result
        l_result.service_name := p_service_name;
        l_result.check_timestamp := SYSTIMESTAMP;

        -- Start or continue distributed trace
        IF p_trace_id IS NOT NULL THEN
            l_trace_id := p_trace_id;
            l_span_id := PLTelemetry.continue_distributed_trace(
                p_trace_id => p_trace_id,
                p_operation => 'service_health_check_' || p_service_name
            );
        ELSE
            l_trace_id := PLTelemetry.start_trace('health_check_' || p_service_name);
            l_span_id := PLTelemetry.start_span('health_check_execution');
        END IF;

        -- Add service context
        l_attrs(1) := PLTelemetry.add_attribute('service.name', p_service_name);
        l_attrs(2) := PLTelemetry.add_attribute('service.criticality', l_service.criticality_code);
        l_attrs(3) := PLTelemetry.add_attribute('service.endpoint', l_service.endpoint_url);
        l_attrs(4) := PLTelemetry.add_attribute('check.timeout_seconds', TO_CHAR(l_service.timeout_seconds));
        l_attrs(5) := PLTelemetry.add_attribute('service.consecutive_failures', TO_CHAR(l_service.consecutive_failures));
        PLTelemetry.add_event(l_span_id, 'health_check_started', l_attrs);

        BEGIN
            -- Set timeout
            UTL_HTTP.SET_TRANSFER_TIMEOUT(l_service.timeout_seconds);
            
            -- Make HTTP request to health endpoint
            l_req := UTL_HTTP.BEGIN_REQUEST(l_service.endpoint_url || '/health', 'GET', 'HTTP/1.1');
            UTL_HTTP.SET_HEADER(l_req, 'User-Agent', 'PLTelemetry-HeartbeatMonitor/2.0');
            UTL_HTTP.SET_HEADER(l_req, 'Accept', 'application/json');
            UTL_HTTP.SET_HEADER(l_req, 'X-Monitor-Source', 'Oracle-PLTelemetry');
            
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
                        l_result.service_uptime := TO_NUMBER(l_uptime_str);
                    END IF;
                    l_result.service_version := l_version;

                EXCEPTION
                    WHEN OTHERS THEN
                        -- JSON parsing failed, but HTTP was successful
                        l_result.status := C_HEALTHY;
                        l_result.error_message := 'JSON parsing failed: ' || SQLERRM;
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
                l_result.response_time_ms := -1; -- FIXED: Use -1 for timeout instead of 99999
                PLTelemetry.add_event(l_span_id, 'request_timeout');

            WHEN UTL_HTTP.REQUEST_FAILED THEN
                l_result.status := C_DOWN;
                l_result.error_message := 'Service unreachable: ' || SQLERRM;
                l_result.response_time_ms := -1; -- FIXED: Use -1 for unreachable instead of 99999
                PLTelemetry.add_event(l_span_id, 'service_unreachable');

            WHEN OTHERS THEN
                l_result.status := C_ERROR;
                l_result.error_message := 'Health check error: ' || SQLERRM;
                l_result.response_time_ms := -1; -- FIXED: Use -1 for errors instead of 99999
                PLTelemetry.add_event(l_span_id, 'health_check_error');
        END;

        -- =================================================================
        -- INDIVIDUAL SERVICE METRICS - STABLE LABELS TO AVOID MULTIPLICATION 🔥
        -- =================================================================
        
        -- Create STABLE service-specific attributes (no changing labels)
        l_service_attrs := create_stable_service_attributes(
            p_service_name => p_service_name,
            p_criticality => l_service.criticality_code,
            p_endpoint => l_service.endpoint_url
        );

        -- Response time metric (STABLE - no changing labels)
        -- FIXED: Use -1 for failed services instead of 99999
        PLTelemetry.log_metric(
            p_metric_name => 'service_response_time_ms',
            p_value => NVL(l_result.response_time_ms, -1), -- FIXED: Default to -1 instead of 99999
            p_unit => 'milliseconds',
            p_attributes => l_service_attrs
        );

        -- Status metric as gauge (STABLE - use actual status as value)
        PLTelemetry.log_metric(
            p_metric_name => 'service_status_gauge',
            p_value => CASE l_result.status 
                        WHEN C_HEALTHY THEN 1
                        WHEN C_DEGRADED THEN 0.5
                        ELSE 0  -- DOWN, ERROR, TIMEOUT, UNHEALTHY
                       END,
            p_unit => 'status',
            p_attributes => l_service_attrs
        );

        -- Check performed counter (STABLE)
        PLTelemetry.log_metric(
            p_metric_name => 'service_check_performed',
            p_value => 1,
            p_unit => 'count',
            p_attributes => l_service_attrs
        );

        -- Consecutive failures as SEPARATE metric (this can change)
        DECLARE
            l_failure_attrs PLTelemetry.t_attributes;
        BEGIN
            l_failure_attrs := l_service_attrs;
            -- Only add failure count as separate metric, not as label
            PLTelemetry.log_metric(
                p_metric_name => 'service_consecutive_failures_count',
                p_value => l_service.consecutive_failures,
                p_unit => 'count',
                p_attributes => l_failure_attrs
            );
        END;

        -- Success/failure counters (STABLE - just increment)
        IF l_result.status IN (C_HEALTHY, C_DEGRADED) THEN
            PLTelemetry.log_metric(
                p_metric_name => 'service_check_success',
                p_value => 1,
                p_unit => 'count',
                p_attributes => l_service_attrs
            );
        ELSE
            PLTelemetry.log_metric(
                p_metric_name => 'service_check_failure',
                p_value => 1,
                p_unit => 'count',
                p_attributes => l_service_attrs
            );
        END IF;

        -- HTTP status as gauge (STABLE)
        PLTelemetry.log_metric(
            p_metric_name => 'service_http_status_gauge',
            p_value => CASE WHEN NVL(l_result.status_code, 0) = 200 THEN 1 ELSE 0 END,
            p_unit => 'status',
            p_attributes => l_service_attrs
        );

        -- Add final result attributes to span
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('result.status', l_result.status);
        l_attrs(2) := PLTelemetry.add_attribute('result.response_time_ms', TO_CHAR(l_result.response_time_ms, '999999.99'));
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
        IF p_trace_id IS NULL THEN
            PLTelemetry.end_trace(l_trace_id);
        END IF;

        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            l_result.status := C_ERROR;
            l_result.error_message := 'Critical health check failure: ' || SQLERRM;
            l_result.response_time_ms := -1; -- FIXED: Use -1 for critical failures instead of 99999
            
            -- =================================================================
            -- CRITICAL: GENERATE METRICS EVEN FOR CATASTROPHIC FAILURES 🔥
            -- =================================================================
            BEGIN
                l_service_attrs := create_stable_service_attributes(
                    p_service_name => p_service_name,
                    p_criticality => l_service.criticality_code,
                    p_endpoint => l_service.endpoint_url
                );

                -- ALWAYS generate metrics, even in catastrophic failure
                -- FIXED: Use -1 for catastrophic failures instead of 99999
                PLTelemetry.log_metric(
                    p_metric_name => 'service_response_time_ms',
                    p_value => -1, -- FIXED: -1 instead of 99999
                    p_unit => 'milliseconds',
                    p_attributes => l_service_attrs
                );

                PLTelemetry.log_metric(
                    p_metric_name => 'service_status_gauge',
                    p_value => 0, -- ERROR = 0
                    p_unit => 'status',
                    p_attributes => l_service_attrs
                );

                PLTelemetry.log_metric(
                    p_metric_name => 'service_check_performed',
                    p_value => 1,
                    p_unit => 'count',
                    p_attributes => l_service_attrs
                );

                PLTelemetry.log_metric(
                    p_metric_name => 'service_check_failure',
                    p_value => 1,
                    p_unit => 'count',
                    p_attributes => l_service_attrs
                );
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- If even metrics fail, give up silently
            END;
            
            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SQLERRM);
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            
            PLTelemetry.log_distributed(
                p_trace_id => l_trace_id,
                p_level => 'ERROR',
                p_message => 'Health check critical failure for ' || p_service_name || ': ' || SQLERRM,
                p_system => 'HEARTBEAT_MONITOR'
            );

            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            
            IF p_trace_id IS NULL THEN
                PLTelemetry.end_trace(l_trace_id);
            END IF;

            RETURN l_result;
    END check_service_health;

    PROCEDURE handle_service_failure(
        p_service_name IN VARCHAR2,
        p_health_result IN t_health_result
    ) IS
        l_service t_service_runtime;
        l_attrs PLTelemetry.t_attributes;
        l_escalation_change BOOLEAN := FALSE;
        l_previous_escalation NUMBER;
        l_failure_attrs PLTelemetry.t_attributes;
    BEGIN
        l_service := load_service_runtime(p_service_name);
        l_previous_escalation := l_service.escalation_level;

        -- Update failure counters in database
        UPDATE heartbeat_services 
        SET consecutive_failures = consecutive_failures + 1,
            last_check_time = SYSTIMESTAMP
        WHERE service_name = p_service_name;

        -- Reload to get updated values
        l_service := load_service_runtime(p_service_name);

        -- Check if escalation level changed
        l_escalation_change := (l_service.escalation_level != l_previous_escalation);

        -- =================================================================
        -- INDIVIDUAL SERVICE FAILURE METRICS 🔥
        -- =================================================================
        
        l_failure_attrs := create_service_attributes(
            p_service_name => p_service_name,
            p_status => 'escalated_failure',
            p_criticality => l_service.criticality_code,
            p_endpoint => l_service.endpoint_url,
            p_consecutive_failures => l_service.consecutive_failures
        );

        -- Consecutive failures metric
        PLTelemetry.log_metric(
            p_metric_name => 'service_consecutive_failures',
            p_value => l_service.consecutive_failures,
            p_unit => 'count',
            p_attributes => l_failure_attrs
        );

        -- Escalation level metric
        PLTelemetry.log_metric(
            p_metric_name => 'service_escalation_level',
            p_value => l_service.escalation_level,
            p_unit => 'level',
            p_attributes => l_failure_attrs
        );

        -- Escalation change event
        IF l_escalation_change THEN
            DECLARE
                l_escalation_attrs PLTelemetry.t_attributes;
            BEGIN
                l_escalation_attrs := l_failure_attrs;
                l_escalation_attrs(l_escalation_attrs.COUNT + 1) := PLTelemetry.add_attribute('previous_level', TO_CHAR(l_previous_escalation));
                l_escalation_attrs(l_escalation_attrs.COUNT + 1) := PLTelemetry.add_attribute('new_level', TO_CHAR(l_service.escalation_level));
                
                PLTelemetry.log_metric(
                    p_metric_name => 'service_escalation_change',
                    p_value => 1,
                    p_unit => 'count',
                    p_attributes => l_escalation_attrs
                );
                
                PLTelemetry.add_event(
                    PLTelemetry.get_current_span_id(),
                    'service_escalation_level_changed',
                    l_escalation_attrs
                );
            END;
        END IF;

        -- Log failure with full context
        l_attrs(1) := PLTelemetry.add_attribute('service.name', p_service_name);
        l_attrs(2) := PLTelemetry.add_attribute('service.criticality', l_service.criticality_code);
        l_attrs(3) := PLTelemetry.add_attribute('failure.status', p_health_result.status);
        l_attrs(4) := PLTelemetry.add_attribute('failure.consecutive_count', TO_CHAR(l_service.consecutive_failures));
        l_attrs(5) := PLTelemetry.add_attribute('escalation.level', TO_CHAR(l_service.escalation_level));
        l_attrs(6) := PLTelemetry.add_attribute('escalation.changed', CASE WHEN l_escalation_change THEN 'true' ELSE 'false' END);
        l_attrs(7) := PLTelemetry.add_attribute('check.interval_minutes', TO_CHAR(l_service.current_check_interval));
        IF p_health_result.error_message IS NOT NULL THEN
            l_attrs(8) := PLTelemetry.add_attribute('error.message', SUBSTR(p_health_result.error_message, 1, 200));
        END IF;

        -- Determine log level based on criticality and escalation
        DECLARE
            l_log_level VARCHAR2(10);
            l_message VARCHAR2(1000);
        BEGIN
            IF l_service.escalation_level = 2 THEN
                l_log_level := 'ERROR';
                l_message := 'CRITICAL: Service ' || p_service_name || ' has failed ' || 
                            l_service.consecutive_failures || ' consecutive times';
            ELSIF l_service.escalation_level = 1 THEN
                l_log_level := 'WARN';
                l_message := 'WARNING: Service ' || p_service_name || ' is experiencing repeated failures (' || 
                            l_service.consecutive_failures || ' consecutive)';
            ELSE
                l_log_level := 'INFO';
                l_message := 'Service ' || p_service_name || ' health check failed: ' || p_health_result.status;
            END IF;

            PLTelemetry.log_distributed(
                p_trace_id => PLTelemetry.get_current_trace_id(),
                p_level => l_log_level,
                p_message => l_message,
                p_system => 'HEARTBEAT_MONITOR'
            );
        END;

        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            PLTelemetry.log_distributed(
                p_trace_id => PLTelemetry.get_current_trace_id(),
                p_level => 'ERROR',
                p_message => 'Failed to handle service failure for ' || p_service_name || ': ' || SQLERRM,
                p_system => 'HEARTBEAT_MONITOR'
            );
    END handle_service_failure;

    PROCEDURE handle_service_recovery(
        p_service_name IN VARCHAR2,
        p_health_result IN t_health_result
    ) IS
        l_service t_service_runtime;
        l_attrs PLTelemetry.t_attributes;
        l_was_failing BOOLEAN := FALSE;
        l_downtime_minutes NUMBER;
        l_recovery_attrs PLTelemetry.t_attributes;
    BEGIN
        l_service := load_service_runtime(p_service_name);
        l_was_failing := (l_service.consecutive_failures > 0);

        -- Calculate downtime if service was failing
        IF l_was_failing AND l_service.last_check_time IS NOT NULL THEN
            l_downtime_minutes := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_service.last_check_time)) / 60;
        END IF;

        -- Reset failure counters in database
        UPDATE heartbeat_services 
        SET consecutive_failures = 0,
            last_check_time = SYSTIMESTAMP
        WHERE service_name = p_service_name;

        -- =================================================================
        -- INDIVIDUAL SERVICE RECOVERY METRICS 🔥
        -- =================================================================
        
        l_recovery_attrs := create_service_attributes(
            p_service_name => p_service_name,
            p_status => 'recovered',
            p_criticality => l_service.criticality_code,
            p_endpoint => l_service.endpoint_url
        );

        -- Always log healthy status
        PLTelemetry.log_metric(
            p_metric_name => 'service_healthy_status',
            p_value => 1,
            p_unit => 'status',
            p_attributes => l_recovery_attrs
        );

        -- Log recovery if service was previously failing
        IF l_was_failing THEN
            -- Recovery event metric
            PLTelemetry.log_metric(
                p_metric_name => 'service_recovery_event',
                p_value => 1,
                p_unit => 'count',
                p_attributes => l_recovery_attrs
            );

            -- Downtime metric if available
            IF l_downtime_minutes IS NOT NULL THEN
                DECLARE
                    l_downtime_attrs PLTelemetry.t_attributes;
                BEGIN
                    l_downtime_attrs := l_recovery_attrs;
                    l_downtime_attrs(l_downtime_attrs.COUNT + 1) := PLTelemetry.add_attribute('downtime_duration', TO_CHAR(l_downtime_minutes, '999999.99'));
                    
                    PLTelemetry.log_metric(
                        p_metric_name => 'service_downtime_duration',
                        p_value => l_downtime_minutes,
                        p_unit => 'minutes',
                        p_attributes => l_downtime_attrs
                    );
                END;
            END IF;

            l_attrs(1) := PLTelemetry.add_attribute('service.name', p_service_name);
            l_attrs(2) := PLTelemetry.add_attribute('service.criticality', l_service.criticality_code);
            l_attrs(3) := PLTelemetry.add_attribute('recovery.status', p_health_result.status);
            l_attrs(4) := PLTelemetry.add_attribute('recovery.response_time_ms', TO_CHAR(p_health_result.response_time_ms));
            IF l_downtime_minutes IS NOT NULL THEN
                l_attrs(5) := PLTelemetry.add_attribute('downtime.minutes', TO_CHAR(l_downtime_minutes, '999999.99'));
            END IF;

            PLTelemetry.log_distributed(
                p_trace_id => PLTelemetry.get_current_trace_id(),
                p_level => 'INFO',
                p_message => 'Service ' || p_service_name || ' has recovered. Status: ' || p_health_result.status,
                p_system => 'HEARTBEAT_MONITOR'
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
            PLTelemetry.log_distributed(
                p_trace_id => PLTelemetry.get_current_trace_id(),
                p_level => 'ERROR',
                p_message => 'Failed to handle service recovery for ' || p_service_name || ': ' || SQLERRM,
                p_system => 'HEARTBEAT_MONITOR'
            );
    END handle_service_recovery;

    FUNCTION get_services_due_for_check(p_force_all BOOLEAN DEFAULT FALSE) 
    RETURN SYS_REFCURSOR IS
        l_cursor SYS_REFCURSOR;
    BEGIN
        IF p_force_all THEN
            OPEN l_cursor FOR
                SELECT s.service_name, s.criticality_code, c.check_interval_minutes
                FROM heartbeat_services s
                JOIN heartbeat_criticality_levels c ON s.criticality_code = c.criticality_code
                WHERE s.is_enabled = 1
                ORDER BY c.check_interval_minutes, s.service_name;
        ELSE
            OPEN l_cursor FOR
                SELECT s.service_name, s.criticality_code, 
                       CASE 
                           WHEN s.consecutive_failures = 0 THEN c.check_interval_minutes
                           ELSE GREATEST(1, c.check_interval_minutes * c.escalation_multiplier)
                       END as current_interval
                FROM heartbeat_services s
                JOIN heartbeat_criticality_levels c ON s.criticality_code = c.criticality_code
                WHERE s.is_enabled = 1
                  AND (s.last_check_time IS NULL 
                       OR s.last_check_time + INTERVAL '1' MINUTE * 
                          CASE 
                              WHEN s.consecutive_failures = 0 THEN c.check_interval_minutes
                              ELSE GREATEST(1, c.check_interval_minutes * c.escalation_multiplier)
                          END <= SYSTIMESTAMP)
                ORDER BY CASE 
                             WHEN s.consecutive_failures = 0 THEN c.check_interval_minutes
                             ELSE GREATEST(1, c.check_interval_minutes * c.escalation_multiplier)
                         END, s.service_name;
        END IF;

        RETURN l_cursor;
    END get_services_due_for_check;

    PROCEDURE perform_heartbeat_checks(p_force_all_checks BOOLEAN DEFAULT FALSE) IS
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
        l_cycle_attrs PLTelemetry.t_attributes;
    BEGIN
        -- Ensure telemetry is configured
        configure_telemetry();

        -- Start heartbeat check trace
        l_trace_id := PLTelemetry.start_trace('heartbeat_monitoring_cycle');
        l_span_id := PLTelemetry.start_span('monitor_services_batch');

        -- Add monitoring cycle context
        l_attrs(1) := PLTelemetry.add_attribute('monitoring.cycle_time', TO_CHAR(l_current_time, 'YYYY-MM-DD HH24:MI:SS'));
        l_attrs(2) := PLTelemetry.add_attribute('monitoring.force_all_checks', CASE WHEN p_force_all_checks THEN 'true' ELSE 'false' END);
        PLTelemetry.add_event(l_span_id, 'monitoring_cycle_started', l_attrs);

        -- Get services due for checking
        l_cursor := get_services_due_for_check(p_force_all_checks);

        LOOP
            FETCH l_cursor INTO l_service_name, l_criticality, l_interval;
            EXIT WHEN l_cursor%NOTFOUND;
            
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

        -- =================================================================
        -- MONITORING CYCLE METRICS (individual, not aggregated) 🔥
        -- =================================================================
        
        l_cycle_attrs(1) := PLTelemetry.add_attribute('cycle_type', 'heartbeat_monitoring');
        l_cycle_attrs(2) := PLTelemetry.add_attribute('force_all', CASE WHEN p_force_all_checks THEN 'true' ELSE 'false' END);

        -- Cycle duration metric
        PLTelemetry.log_metric(
            p_metric_name => 'monitoring_cycle_duration_ms',
            p_value => EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000,
            p_unit => 'milliseconds',
            p_attributes => l_cycle_attrs
        );

        -- Cycle completion event
        PLTelemetry.log_metric(
            p_metric_name => 'monitoring_cycle_completed',
            p_value => 1,
            p_unit => 'count',
            p_attributes => l_cycle_attrs
        );

        -- Log monitoring cycle completion
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('cycle.duration_ms', 
            TO_CHAR(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, '999999.99'));
        PLTelemetry.add_event(l_span_id, 'monitoring_cycle_completed', l_attrs);

        PLTelemetry.end_span(l_span_id, 'OK');
        PLTelemetry.end_trace(l_trace_id);

    EXCEPTION
        WHEN OTHERS THEN
            IF l_cursor%ISOPEN THEN
                CLOSE l_cursor;
            END IF;

            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SQLERRM);
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            
            PLTelemetry.log_distributed(
                p_trace_id => l_trace_id,
                p_level => 'ERROR',
                p_message => 'Heartbeat monitoring cycle failed: ' || SQLERRM,
                p_system => 'HEARTBEAT_MONITOR'
            );

            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            PLTelemetry.end_trace(l_trace_id);
    END perform_heartbeat_checks;

    -- CRUD Operations for service management (unchanged, no metrics modifications needed)

    PROCEDURE add_service(
        p_service_name VARCHAR2,
        p_description VARCHAR2,
        p_endpoint_url VARCHAR2,
        p_criticality_code VARCHAR2,
        p_timeout_seconds NUMBER DEFAULT 10,
        p_enabled NUMBER DEFAULT 1
    ) IS
    BEGIN
        INSERT INTO heartbeat_services (
            service_name,
            service_description,
            endpoint_url,
            criticality_code,
            timeout_seconds,
            is_enabled,
            consecutive_failures
        ) VALUES (
            p_service_name,
            p_description,
            p_endpoint_url,
            p_criticality_code,
            p_timeout_seconds,
            p_enabled,
            0
        );

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Service added to monitoring: ' || p_service_name,
            p_system => 'HEARTBEAT_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            RAISE_APPLICATION_ERROR(-20003, 'Service already exists: ' || p_service_name);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END add_service;

    PROCEDURE remove_service(p_service_name VARCHAR2) IS
        l_rows_deleted NUMBER;
    BEGIN
        DELETE FROM heartbeat_services 
        WHERE service_name = p_service_name;
        
        l_rows_deleted := SQL%ROWCOUNT;
        
        IF l_rows_deleted = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Service not found: ' || p_service_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'WARN',
            p_message => 'Service removed from monitoring: ' || p_service_name,
            p_system => 'HEARTBEAT_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END remove_service;

    PROCEDURE update_service(
        p_service_name VARCHAR2,
        p_description VARCHAR2 DEFAULT NULL,
        p_endpoint_url VARCHAR2 DEFAULT NULL,
        p_criticality_code VARCHAR2 DEFAULT NULL,
        p_timeout_seconds NUMBER DEFAULT NULL
    ) IS
        l_rows_updated NUMBER;
    BEGIN
        UPDATE heartbeat_services 
        SET service_description = NVL(p_description, service_description),
            endpoint_url = NVL(p_endpoint_url, endpoint_url),
            criticality_code = NVL(p_criticality_code, criticality_code),
            timeout_seconds = NVL(p_timeout_seconds, timeout_seconds)
        WHERE service_name = p_service_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20005, 'Service not found: ' || p_service_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Service configuration updated: ' || p_service_name,
            p_system => 'HEARTBEAT_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END update_service;

    PROCEDURE set_service_monitoring(
        p_service_name VARCHAR2, 
        p_enabled NUMBER
    ) IS
        l_rows_updated NUMBER;
    BEGIN
        UPDATE heartbeat_services 
        SET is_enabled = p_enabled
        WHERE service_name = p_service_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20006, 'Service not found: ' || p_service_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'INFO',
            p_message => 'Service monitoring ' || 
                        CASE WHEN p_enabled = 1 THEN 'enabled' ELSE 'disabled' END || 
                        ' for: ' || p_service_name,
            p_system => 'HEARTBEAT_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END set_service_monitoring;

    PROCEDURE reset_service_failures(p_service_name VARCHAR2) IS
        l_rows_updated NUMBER;
    BEGIN
        UPDATE heartbeat_services 
        SET consecutive_failures = 0
        WHERE service_name = p_service_name;
        
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated = 0 THEN
            RAISE_APPLICATION_ERROR(-20007, 'Service not found: ' || p_service_name);
        END IF;

        PLTelemetry.log_distributed(
            p_trace_id => PLTelemetry.get_current_trace_id(),
            p_level => 'WARN',
            p_message => 'Failure counters reset for service: ' || p_service_name,
            p_system => 'HEARTBEAT_MONITOR'
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END reset_service_failures;

    FUNCTION get_service_runtime(p_service_name VARCHAR2) RETURN t_service_runtime IS
    BEGIN
        RETURN load_service_runtime(p_service_name);
    END get_service_runtime;

    FUNCTION generate_monitoring_report(p_hours_back NUMBER DEFAULT 24) RETURN CLOB IS
        l_report CLOB;
        l_json_chunk VARCHAR2(4000);
        l_first_service BOOLEAN := TRUE;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(l_report, TRUE);
        
        -- Build JSON report header
        l_json_chunk := '{'
            || '"report_timestamp":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'
            || '"hours_back":' || p_hours_back || ','
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
                   s.is_enabled,
                   CASE 
                       WHEN s.consecutive_failures >= c.max_escalation_failures THEN 2
                       WHEN s.consecutive_failures >= (c.max_escalation_failures / 2) THEN 1
                       ELSE 0
                   END as escalation_level
            FROM heartbeat_services s
            JOIN heartbeat_criticality_levels c ON s.criticality_code = c.criticality_code
            ORDER BY c.check_interval_minutes, s.service_name
        ) LOOP
            IF NOT l_first_service THEN
                DBMS_LOB.WRITEAPPEND(l_report, 1, ',');
            END IF;
            l_first_service := FALSE;
            
            l_json_chunk := '{'
                || '"name":"' || rec.service_name || '",'
                || '"description":"' || rec.service_description || '",'
                || '"criticality":"' || rec.criticality_code || '",'
                || '"check_interval_minutes":' || rec.check_interval_minutes || ','
                || '"consecutive_failures":' || rec.consecutive_failures || ','
                || '"escalation_level":' || rec.escalation_level || ','
                || '"enabled":' || CASE WHEN rec.is_enabled = 1 THEN 'true' ELSE 'false' END || ','
                || '"last_check_time":"' || 
                   CASE WHEN rec.last_check_time IS NOT NULL 
                        THEN TO_CHAR(rec.last_check_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"')
                        ELSE 'never'
                   END || '"'
                || '}';
            
            DBMS_LOB.WRITEAPPEND(l_report, LENGTH(l_json_chunk), l_json_chunk);
        END LOOP;

        DBMS_LOB.WRITEAPPEND(l_report, 2, ']}');
        
        RETURN l_report;
    END generate_monitoring_report;

END HEARTBEAT_MONITOR;
/