-- Primero, habilitar REST para el esquema PLTELEMETRY
BEGIN
    ORDS.ENABLE_SCHEMA(
        p_enabled             => TRUE,
        p_schema              => 'PLTELEMETRY',
        p_url_mapping_type    => 'BASE_PATH',
        p_url_mapping_pattern => 'pltelemetry',
        p_auto_rest_auth      => FALSE
    );
    
    COMMIT;
END;
/

-- =============================================================================
-- PLTelemetry Example 04 - ORDS REST Endpoints Setup
-- Creates REST endpoints that bridge Node.js and Oracle PL/SQL
-- =============================================================================

-- Enable ORDS for the schema
BEGIN
    ORDS.ENABLE_SCHEMA(
        p_enabled             => TRUE,
        p_schema              => 'PLTELEMETRY',
        p_url_mapping_type    => 'BASE_PATH',
        p_url_mapping_pattern => 'pltelemetry',
        p_auto_rest_auth      => FALSE
    );
    
    COMMIT;
END;
/

-- =============================================================================
-- FINANCIAL REPORTS MODULE
-- =============================================================================

BEGIN
    ORDS.DEFINE_MODULE(
        p_module_name    => 'financial.reports',
        p_base_path      => '/financial/reports/',
        p_items_per_page => 25,
        p_status         => 'PUBLISHED',
        p_comments       => 'PLTelemetry Example 04 - Financial Reports API'
    );
    
    COMMIT;
END;
/

-- =============================================================================
-- FINANCIAL SUMMARY ENDPOINT
-- Receives trace context from Node.js and calls PL/SQL package
-- =============================================================================

BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name    => 'financial.reports',
        p_pattern        => 'summary',
        p_priority       => 0,
        p_etag_type      => 'HASH',
        p_etag_query     => NULL,
        p_comments       => 'Generate financial summary with distributed tracing'
    );
    
    COMMIT;
END;
/

BEGIN
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'financial.reports',
        p_pattern        => 'summary',
        p_method         => 'POST',
        p_source_type    => 'plsql/block',
        p_items_per_page => 0,
        p_mimes_allowed  => 'application/json',
        p_comments       => 'POST handler for financial summary generation',
        p_source         => q'[
DECLARE
    -- Input parameters from JSON body
    l_customer_id     VARCHAR2(32);
    l_period         VARCHAR2(10);
    l_include_metrics BOOLEAN := TRUE;
    
    -- Trace context from HTTP headers
    l_trace_id       VARCHAR2(32);
    l_span_id        VARCHAR2(16);
    l_traceparent    VARCHAR2(200);
    l_correlation_id VARCHAR2(100);
    
    -- Results
    l_result         CLOB;
    l_error_msg      VARCHAR2(4000);
    
BEGIN
    -- Extract input parameters from request body
    BEGIN
        l_customer_id := JSON_VALUE(:body, '$.customer_id');
        l_period := JSON_VALUE(:body, '$.period');
        l_include_metrics := CASE 
            WHEN JSON_VALUE(:body, '$.include_metrics') = 'false' THEN FALSE 
            ELSE TRUE 
        END;
    EXCEPTION
        WHEN OTHERS THEN
            :status := 400;
            :body := '{"error": "Invalid JSON body", "details": "' || 
                    REPLACE(SQLERRM, '"', '\"') || '"}';
            RETURN;
    END;
    
    -- Validate required parameters
    IF l_customer_id IS NULL OR l_period IS NULL THEN
        :status := 400;
        :body := '{"error": "Missing required parameters", ' ||
                '"details": "customer_id and period are required"}';
        RETURN;
    END IF;
    
    -- Extract trace context from HTTP headers
    -- ORDS provides access to headers via :header_name syntax
    l_traceparent := :traceparent;
    l_trace_id := :x_plt_trace_id;
    l_span_id := :x_plt_span_id;
    l_correlation_id := :x_correlation_id;
    
    -- Log the distributed tracing context received
    IF l_trace_id IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('🔗 Received distributed trace context:');
        DBMS_OUTPUT.PUT_LINE('   Trace ID: ' || l_trace_id);
        DBMS_OUTPUT.PUT_LINE('   Span ID: ' || NVL(l_span_id, 'none'));
        DBMS_OUTPUT.PUT_LINE('   Traceparent: ' || NVL(l_traceparent, 'none'));
        DBMS_OUTPUT.PUT_LINE('   Correlation: ' || NVL(l_correlation_id, 'none'));
    END IF;
    
    -- Call the PL/SQL API with trace context
    BEGIN
        l_result := FINANCIAL_API.generate_financial_summary(
            p_customer_id     => l_customer_id,
            p_period         => l_period,
            p_include_metrics => l_include_metrics,
            p_trace_id       => l_trace_id,
            p_span_id        => l_span_id
        );
        
        -- Success response
        :status := 200;
        :body := l_result;
        
        -- Add correlation header to response
        IF l_correlation_id IS NOT NULL THEN
            HTP.P('X-Correlation-ID: ' || l_correlation_id);
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || 
                          DBMS_UTILITY.format_error_backtrace, 1, 4000);
            
            :status := 500;
            :body := '{"error": "Internal server error", ' ||
                    '"details": "' || REPLACE(l_error_msg, '"', '\"') || '", ' ||
                    '"timestamp": "' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '"}';
            
            -- Log error for debugging
            DBMS_OUTPUT.PUT_LINE('❌ ORDS Handler Error: ' || l_error_msg);
    END;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Ultimate error handler
        :status := 500;
        :body := '{"error": "Critical ORDS handler failure", ' ||
                '"timestamp": "' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '"}';
END;
]'
    );
    
    COMMIT;
END;
/

-- =============================================================================
-- HEALTH CHECK ENDPOINT
-- Simple health check for monitoring
-- =============================================================================

BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name    => 'financial.reports',
        p_pattern        => 'health',
        p_priority       => 0,
        p_etag_type      => 'HASH',
        p_etag_query     => NULL,
        p_comments       => 'Health check endpoint'
    );
    
    COMMIT;
END;
/

BEGIN
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'financial.reports',
        p_pattern        => 'health',
        p_method         => 'GET',
        p_source_type    => 'plsql/block',
        p_items_per_page => 0,
        p_mimes_allowed  => 'application/json',
        p_comments       => 'GET handler for health check',
        p_source         => q'[
BEGIN
    :status := 200;
    :body := FINANCIAL_API.health_check();
EXCEPTION
    WHEN OTHERS THEN
        :status := 500;
        :body := '{"status": "unhealthy", "error": "' || 
                REPLACE(SQLERRM, '"', '\"') || '"}';
END;
]'
    );
    
    COMMIT;
END;
/

-- =============================================================================
-- CONFIGURE CORS FOR CROSS-ORIGIN REQUESTS
-- =============================================================================

BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name    => 'financial.reports',
        p_pattern        => 'summary',
        p_priority       => 0,
        p_etag_type      => 'HASH',
        p_etag_query     => NULL,
        p_comments       => 'CORS preflight for summary endpoint'
    );
    
    COMMIT;
END;
/


-- Crear template para summary
BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name    => 'financial.reports',
        p_pattern        => 'summary',
        p_priority       => 0,
        p_etag_type      => 'HASH',
        p_etag_query     => NULL,
        p_comments       => 'Generate financial summary with distributed tracing'
    );
    COMMIT;
END;
/

-- Crear handler POST para summary
BEGIN
    ORDS.DEFINE_HANDLER(
        p_module_name    => 'financial.reports',
        p_pattern        => 'summary',
        p_method         => 'POST',
        p_source_type    => 'plsql/block',
        p_items_per_page => 0,
        p_mimes_allowed  => 'application/json',
        p_comments       => 'POST handler for financial summary generation',
        p_source         => 'DECLARE
    l_customer_id VARCHAR2(32);
    l_period VARCHAR2(10);
    l_result CLOB;
BEGIN
    l_customer_id := JSON_VALUE(:body, ''$.customer_id'');
    l_period := JSON_VALUE(:body, ''$.period'');
    
    IF l_customer_id IS NULL OR l_period IS NULL THEN
        :status := 400;
        :body := ''{"error": "Missing required parameters"}'';
        RETURN;
    END IF;
    
    l_result := FINANCIAL_API.generate_financial_summary(
        p_customer_id => l_customer_id,
        p_period => l_period
    );
    
    :status := 200;
    :body := l_result;
EXCEPTION
    WHEN OTHERS THEN
        :status := 500;
        :body := ''{"error": "Internal error"}'';
END;'
    );
    COMMIT;
END;
/

-- =============================================================================
-- VERIFICATION AND STATUS
-- =============================================================================

SELECT *
FROM user_ords_modules m
JOIN user_ords_templates t ON m.id = t.module_id
JOIN user_ords_handlers h ON t.id = h.template_id
--WHERE m.name = 'financial.reports'
ORDER BY t.uri_template, h.method;

-- Show created endpoints
SELECT 
    m.name as module_name,
    t.uri_template,
    h.method,
    h.source_type,
    'http://localhost:8080/ords/pltdb' || m.base_path || t.uri_template as full_url
FROM 
    user_ords_modules m
    JOIN user_ords_templates t ON m.name = t.module_name
    JOIN user_ords_handlers h ON t.id = h.template_id
WHERE 
    m.name = 'financial.reports'
ORDER BY 
    t.uri_template, h.method;

PROMPT
PROMPT ✅ ORDS Financial Reports API Setup Complete!
PROMPT
PROMPT 📋 Available endpoints:
PROMPT    POST http://localhost:8080/ords/pltdb/financial/reports/summary
PROMPT    GET  http://localhost:8080/ords/pltdb/financial/reports/health
PROMPT    OPTIONS http://localhost:8080/ords/pltdb/financial/reports/summary (CORS)
PROMPT
PROMPT 🔗 Trace context headers supported:
PROMPT    - traceparent (W3C standard)
PROMPT    - X-PLT-Trace-ID (PLTelemetry specific)
PROMPT    - X-PLT-Span-ID (PLTelemetry specific)
PROMPT    - X-Correlation-ID (Request correlation)
PROMPT
PROMPT 🚀 Ready for distributed tracing from Node.js!