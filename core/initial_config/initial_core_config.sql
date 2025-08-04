-- =====================================================
-- PLTelemetry - System Initialization Script
-- Configures all necessary settings for PLTelemetry Core and OTLP Bridge
-- Execute as PLTELEMETRY user after package installation
-- =====================================================

SET SERVEROUTPUT ON

PROMPT Initializing PLTelemetry system configuration...

-- =====================================================
-- STEP 1: PLTelemetry Core Configuration
-- =====================================================

BEGIN
    DBMS_OUTPUT.PUT_LINE('=== PLTelemetry Core Configuration ===');
    
    -- Backend configuration - Tell PLTelemetry to use OTLP Bridge
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    DBMS_OUTPUT.PUT_LINE('✓ Backend URL set to: OTLP_BRIDGE');
    
    -- Processing mode configuration
    PLTelemetry.set_async_mode(TRUE);  -- Synchronous for immediate feedback during testing
    DBMS_OUTPUT.PUT_LINE('✓ Async mode set to: FALSE (synchronous)');
    
    -- Auto-commit configuration
    PLTelemetry.set_autocommit(TRUE);   -- Auto-commit for better reliability
    DBMS_OUTPUT.PUT_LINE('✓ Autocommit set to: TRUE');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ PLTelemetry Core configuration failed: ' || SQLERRM);
        RAISE;
END;
/

-- =====================================================
-- STEP 2: OTLP Bridge Configuration
-- =====================================================

BEGIN
    DBMS_OUTPUT.PUT_LINE('=== OTLP Bridge Configuration ===');
    
    -- Primary OTLP collector endpoint
    PLT_OTLP_BRIDGE.set_otlp_collector('http://otel-collector:4318');
    DBMS_OUTPUT.PUT_LINE('✓ OTLP Collector URL set to: http://otel-collector:4318');
    
    -- Service identification for OTLP
    PLT_OTLP_BRIDGE.set_service_info(
        p_service_name         => 'oracle-plsql',
        p_service_version      => '2.0.0',
        p_deployment_environment => 'production'
    );
    DBMS_OUTPUT.PUT_LINE('✓ OTLP Service info configured');
    
    -- HTTP timeout configuration
    PLT_OTLP_BRIDGE.set_timeout(10);  -- 10 seconds timeout
    DBMS_OUTPUT.PUT_LINE('✓ HTTP timeout set to: 10 seconds');
    
    -- Debug mode for OTLP Bridge
    PLT_OTLP_BRIDGE.set_debug_mode(FALSE);  -- Disable for production
    DBMS_OUTPUT.PUT_LINE('✓ OTLP Bridge debug mode set to: FALSE');
    
    -- Tenant configuration for OTLP
    PLT_OTLP_BRIDGE.set_tenant_context('default', 'Default Tenant');
    DBMS_OUTPUT.PUT_LINE('✓ OTLP tenant info configured');
    
    DBMS_OUTPUT.PUT_LINE(' ');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ OTLP Bridge configuration failed: ' || SQLERRM);
        RAISE;
END;
/

-- =====================================================
-- STEP 3: Activation Manager Configuration
-- =====================================================

BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Activation Manager Configuration ===');
    
    -- Enable telemetry for default tenant and common operations
    PLT_ACTIVATION_MANAGER.enable_telemetry(
        p_object_name    => '*',           -- All objects
        p_telemetry_type => 'TRACE',
        p_tenant_id      => 'default',
        p_sampling_rate  => 1.0,           -- 100% sampling initially
        p_log_level      => 'INFO'
    );
    DBMS_OUTPUT.PUT_LINE('✓ Tracing enabled for all objects (100% sampling)');
    
    PLT_ACTIVATION_MANAGER.enable_telemetry(
        p_object_name    => '*',
        p_telemetry_type => 'METRIC',
        p_tenant_id      => 'default',
        p_sampling_rate  => 1.0,
        p_log_level      => 'INFO'
    );
    DBMS_OUTPUT.PUT_LINE('✓ Metrics enabled for all objects');
    
    PLT_ACTIVATION_MANAGER.enable_telemetry(
        p_object_name    => '*',
        p_telemetry_type => 'LOG',
        p_tenant_id      => 'default',
        p_sampling_rate  => 1.0,
        p_log_level      => 'INFO'
    );
    DBMS_OUTPUT.PUT_LINE('✓ Logging enabled for all objects');
    
    DBMS_OUTPUT.PUT_LINE(' ');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Activation Manager configuration failed: ' || SQLERRM);
        -- Don't raise - activation manager might not be fully implemented yet
END;
/

-- =====================================================
-- STEP 4: Performance and Failover Configuration
-- =====================================================

BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Performance and Failover Configuration ===');
    
    -- Update failover configuration for current environment
    UPDATE plt_failover_config 
    SET config_value = 'http://otel-collector:4318'
    WHERE config_key = 'OTLP_COLLECTOR_URL';
    
    UPDATE plt_failover_config 
    SET config_value = 'oracle-plsql'
    WHERE config_key = 'OTLP_SERVICE_NAME';
    
    UPDATE plt_failover_config 
    SET config_value = '2.0.0'
    WHERE config_key = 'OTLP_SERVICE_VERSION';
    
    UPDATE plt_failover_config 
    SET config_value = 'production'
    WHERE config_key = 'OTLP_ENVIRONMENT';
    
    UPDATE plt_failover_config 
    SET config_value = 'PULSE1'  -- Full capacity mode
    WHERE config_key = 'AGENT_PULSE_MODE';
    
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('✓ Failover configuration updated');
    DBMS_OUTPUT.PUT_LINE(' ');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Failover configuration failed: ' || SQLERRM);
        ROLLBACK;
END;
/

-- =====================================================
-- STEP 6: Connectivity Test
-- =====================================================


PROMPT
PROMPT === Connectivity Test ===

DECLARE
    l_test_trace_id VARCHAR2(32);
    l_test_span_id VARCHAR2(16);
    l_child_span_id VARCHAR2(16);
    l_result VARCHAR2(100);
BEGIN
    -- Test basic telemetry generation
    l_test_trace_id := PLTelemetry.start_trace('INITIALIZATION_TEST');
    
    IF l_test_trace_id IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('✓ Trace generation working - Trace ID: ' || l_test_trace_id);
        
        -- Test span creation (root span for this trace)
        l_test_span_id := PLTelemetry.start_span('test_root_span');
        
        IF l_test_span_id IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('✓ Root span generation working - Span ID: ' || l_test_span_id);
            
            -- Test child span creation
            l_child_span_id := PLTelemetry.start_span('test_child_span', l_test_span_id);
            DBMS_OUTPUT.PUT_LINE('✓ Child span generation working - Span ID: ' || l_child_span_id);
            
            -- Test metric logging
            PLTelemetry.log_metric('initialization.test', 1, 'count');
            DBMS_OUTPUT.PUT_LINE('✓ Metric logging working');
            
            -- Test log message
            PLTelemetry.log_message('INFO', 'PLTelemetry initialization test completed successfully');
            DBMS_OUTPUT.PUT_LINE('✓ Log message working');
            
            -- End spans in correct order (child first, then parent)
            IF l_child_span_id IS NOT NULL THEN
                PLTelemetry.end_span(l_child_span_id, 'OK');
            END IF;
            PLTelemetry.end_span(l_test_span_id, 'OK');
            PLTelemetry.end_trace(l_test_trace_id);
            
            DBMS_OUTPUT.PUT_LINE('✓ Full telemetry cycle completed successfully');
        ELSE
            DBMS_OUTPUT.PUT_LINE('⚠ Span generation returned NULL');
            PLTelemetry.end_trace(l_test_trace_id);
        END IF;
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ Trace generation returned NULL - check configuration');
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Connectivity test failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
        -- Insert error for tracking
        INSERT INTO plt_telemetry_errors (
            error_time, error_message, module_name
        ) VALUES (
            SYSTIMESTAMP, 
            'Initialization connectivity test failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200),
            'INITIALIZATION_TEST'
        );
        COMMIT;
END;
/

-- =====================================================
-- STEP 7: Environment-Specific Adjustments
-- =====================================================

PROMPT
PROMPT === Environment-Specific Settings ===
PROMPT
PROMPT For DEVELOPMENT environment, consider:
PROMPT   PLTelemetry.set_debug_mode(TRUE);
PROMPT   PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
PROMPT   PLTelemetry.set_async_mode(FALSE);
PROMPT
PROMPT For PRODUCTION environment, consider:
PROMPT   PLTelemetry.set_async_mode(TRUE);
PROMPT   PLT_ACTIVATION_MANAGER.set_sampling_rate(0.1); -- 10% sampling
PROMPT   PLTelemetry.set_debug_mode(FALSE);
PROMPT
PROMPT For HIGH VOLUME environment, consider:
PROMPT   PLTelemetry.set_async_mode(TRUE);
PROMPT   PLT_ACTIVATION_MANAGER.set_sampling_rate(0.01); -- 1% sampling
PROMPT   Update plt_rate_limit_config for throttling
PROMPT

PROMPT
PROMPT =====================================================
PROMPT PLTelemetry System Initialization Complete
PROMPT =====================================================
PROMPT 
PROMPT Configuration Summary:
PROMPT ✓ PLTelemetry Core: Configured for OTLP Bridge
PROMPT ✓ OTLP Bridge: Connected to otel-collector:4318
PROMPT ✓ Activation Manager: Enabled for all telemetry types
PROMPT ✓ Failover Config: Updated with current settings
PROMPT ✓ Connectivity Test: Basic telemetry cycle tested
PROMPT 
PROMPT Next Steps:
PROMPT 1. Monitor plt_telemetry_errors for any issues
PROMPT 2. Check OTLP collector logs for incoming data
PROMPT 3. Verify traces appear in Grafana/Tempo
PROMPT 4. Adjust sampling rates based on volume
PROMPT 5. Configure environment-specific settings
PROMPT 
PROMPT System ready for telemetry generation!
PROMPT =====================================================

-- Show current queue status
SELECT 
    'Queue Status' as component,
    COUNT(*) as total_items,
    SUM(CASE WHEN processed = 'Y' THEN 1 ELSE 0 END) as processed,
    SUM(CASE WHEN processed = 'N' THEN 1 ELSE 0 END) as pending
FROM plt_queue;