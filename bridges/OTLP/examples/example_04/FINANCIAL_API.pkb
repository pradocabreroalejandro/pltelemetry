CREATE OR REPLACE PACKAGE BODY FINANCIAL_API
AS
    /**
     * FINANCIAL_API - PLTelemetry Example 04 Implementation
     * 
     * Demonstrates distributed tracing from Node.js → Oracle PL/SQL
     * All heavy operations are simulated with DBMS_LOCK.SLEEP
     */

    --------------------------------------------------------------------------
    -- PRIVATE HELPER FUNCTIONS
    --------------------------------------------------------------------------
    
    /**
     * JSON escape helper for safe string output
     */
    FUNCTION escape_json_string(p_input VARCHAR2)
    RETURN VARCHAR2
    IS
    BEGIN
        IF p_input IS NULL THEN
            RETURN '';
        END IF;
        
        RETURN REPLACE(
                   REPLACE(
                       REPLACE(
                           REPLACE(
                               REPLACE(p_input, '\', '\\'),
                               '"', '\"'),
                           CHR(10), '\n'),
                       CHR(13), '\r'),
                   CHR(9), '\t');
    END escape_json_string;

    /**
     * Simulate heavy database work with sleep
     */
    PROCEDURE simulate_processing(p_milliseconds NUMBER)
    IS
    BEGIN
        -- Convert milliseconds to seconds for DBMS_LOCK.SLEEP
        DBMS_LOCK.SLEEP(p_milliseconds / 1000);
    END simulate_processing;

    /**
     * Get current timestamp in ISO format
     */
    FUNCTION get_iso_timestamp
    RETURN VARCHAR2
    IS
    BEGIN
        RETURN TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"');
    END get_iso_timestamp;

    --------------------------------------------------------------------------
    -- PUBLIC FUNCTIONS IMPLEMENTATION
    --------------------------------------------------------------------------

    /**
     * Main entry point for financial summary generation
     */
    FUNCTION generate_financial_summary(
        p_customer_id     VARCHAR2,
        p_period         VARCHAR2,
        p_include_metrics BOOLEAN DEFAULT TRUE,
        p_trace_id       VARCHAR2 DEFAULT NULL,
        p_span_id        VARCHAR2 DEFAULT NULL
    ) RETURN CLOB
    IS
        l_span_id           VARCHAR2(16);
        l_transactions      t_transactions;
        l_summary          t_financial_summary;
        l_top_categories   VARCHAR2(4000);
        l_result           CLOB;
        l_start_time       TIMESTAMP := SYSTIMESTAMP;
        l_attrs            PLTelemetry.t_attributes;
    BEGIN
        -- Continue distributed trace from Node.js
        IF p_trace_id IS NOT NULL THEN
            l_span_id := PLTelemetry.continue_distributed_trace(
                p_trace_id => p_trace_id,
                p_operation => 'oracle_financial_summary_generation',
                p_tenant_id => 'financial_dept'
            );
        ELSE
            -- Fallback: start new trace if no context provided
            l_span_id := PLTelemetry.start_span('financial_summary_standalone');
        END IF;

        -- Add business context to the span
        l_attrs(1) := PLTelemetry.add_attribute('customer.id', p_customer_id);
        l_attrs(2) := PLTelemetry.add_attribute('report.period', p_period);
        l_attrs(3) := PLTelemetry.add_attribute('oracle.package', 'FINANCIAL_API');
        l_attrs(4) := PLTelemetry.add_attribute('oracle.function', 'generate_financial_summary');
        l_attrs(5) := PLTelemetry.add_attribute('system.type', 'oracle-plsql');
        
        PLTelemetry.add_event(l_span_id, 'financial_processing_started', l_attrs);

        -- Step 1: Fetch transaction data (heavy operation)
        PLTelemetry.add_event(l_span_id, 'fetching_transactions_started');
        l_transactions := fetch_transactions(p_customer_id, p_period, p_trace_id);
        PLTelemetry.add_event(l_span_id, 'transactions_fetched');

        -- Step 2: Calculate metrics (complex calculations)
        PLTelemetry.add_event(l_span_id, 'calculating_metrics_started');
        l_summary := calculate_metrics(l_transactions, p_customer_id, p_trace_id);
        PLTelemetry.add_event(l_span_id, 'metrics_calculated');

        -- Step 3: Generate category analysis if requested
        IF p_include_metrics THEN
            PLTelemetry.add_event(l_span_id, 'generating_categories_analysis');
            l_top_categories := get_top_categories(l_transactions, 5);
        ELSE
            l_top_categories := '[]';
        END IF;

        -- Build comprehensive JSON response
        DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
        
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('{'), '{');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"success": true,'), '"success": true,');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"customer_id": "' || escape_json_string(p_customer_id) || '",'), 
                           '"customer_id": "' || escape_json_string(p_customer_id) || '",');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"period": "' || escape_json_string(p_period) || '",'), 
                           '"period": "' || escape_json_string(p_period) || '",');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"total_revenue": ' || TO_CHAR(l_summary.total_revenue) || ','), 
                           '"total_revenue": ' || TO_CHAR(l_summary.total_revenue) || ',');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"transaction_count": ' || TO_CHAR(l_summary.transaction_count) || ','), 
                           '"transaction_count": ' || TO_CHAR(l_summary.transaction_count) || ',');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"average_transaction": ' || TO_CHAR(l_summary.average_transaction) || ','), 
                           '"average_transaction": ' || TO_CHAR(l_summary.average_transaction) || ',');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"top_categories": ' || l_top_categories || ','), 
                           '"top_categories": ' || l_top_categories || ',');
        
        -- Add fake transactions array (hardcoded for demo)
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"transactions": ['), '"transactions": [');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH(
            '{"id": "TXN001", "date": "2024-10-15", "amount": 1250.00, "category": "Software", "description": "License renewal"},'||
            '{"id": "TXN002", "date": "2024-10-20", "amount": 2500.00, "category": "Consulting", "description": "Technical consulting"},'||
            '{"id": "TXN003", "date": "2024-11-05", "amount": 750.00, "category": "Training", "description": "Staff training program"}'
        ), 
        '{"id": "TXN001", "date": "2024-10-15", "amount": 1250.00, "category": "Software", "description": "License renewal"},'||
        '{"id": "TXN002", "date": "2024-10-20", "amount": 2500.00, "category": "Consulting", "description": "Technical consulting"},'||
        '{"id": "TXN003", "date": "2024-11-05", "amount": 750.00, "category": "Training", "description": "Staff training program"}'
        );
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('],'), '],');

        -- Add metadata
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"metadata": {'), '"metadata": {');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"generated_at": "' || get_iso_timestamp() || '",'), 
                           '"generated_at": "' || get_iso_timestamp() || '",');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"processing_time_ms": ' || 
                           TO_CHAR(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000) || ','), 
                           '"processing_time_ms": ' || 
                           TO_CHAR(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000) || ',');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"data_source": "oracle-plsql",'), '"data_source": "oracle-plsql",');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"trace_id": "' || NVL(p_trace_id, 'none') || '",'), 
                           '"trace_id": "' || NVL(p_trace_id, 'none') || '",');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"db_instance": "' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME') || '"'), 
                           '"db_instance": "' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME') || '"');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('}'), '}');
        DBMS_LOB.WRITEAPPEND(l_result, LENGTH('}'), '}');

        -- Log completion metrics
        l_attrs(1) := PLTelemetry.add_attribute('response.size_bytes', TO_CHAR(DBMS_LOB.GETLENGTH(l_result)));
        l_attrs(2) := PLTelemetry.add_attribute('transactions.processed', TO_CHAR(l_summary.transaction_count));
        l_attrs(3) := PLTelemetry.add_attribute('processing.duration_ms', 
                     TO_CHAR(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000));
        
        PLTelemetry.add_event(l_span_id, 'financial_summary_completed', l_attrs);
        PLTelemetry.end_span(l_span_id, 'OK', l_attrs);

        RETURN l_result;

    EXCEPTION
        WHEN OTHERS THEN
            -- Error handling with proper tracing
            l_attrs(1) := PLTelemetry.add_attribute('error.type', 'oracle_exception');
            l_attrs(2) := PLTelemetry.add_attribute('error.message', SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            
            PLTelemetry.add_event(l_span_id, 'financial_summary_failed', l_attrs);
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);

            -- Return error JSON instead of propagating exception
            DBMS_LOB.CREATETEMPORARY(l_result, TRUE);
            DBMS_LOB.WRITEAPPEND(l_result, LENGTH('{"success": false, "error": "'), '{"success": false, "error": "');
            DBMS_LOB.WRITEAPPEND(l_result, LENGTH(escape_json_string(SQLERRM)), escape_json_string(SQLERRM));
            DBMS_LOB.WRITEAPPEND(l_result, LENGTH('", "timestamp": "'), '", "timestamp": "');
            DBMS_LOB.WRITEAPPEND(l_result, LENGTH(get_iso_timestamp()), get_iso_timestamp());
            DBMS_LOB.WRITEAPPEND(l_result, LENGTH('"}'), '"}');
            
            RETURN l_result;
    END generate_financial_summary;

    /**
     * Fetch historical transactions - simulates heavy DB queries
     */
    FUNCTION fetch_transactions(
        p_customer_id VARCHAR2,
        p_period     VARCHAR2,
        p_trace_id   VARCHAR2 DEFAULT NULL
    ) RETURN t_transactions
    IS
        l_span_id      VARCHAR2(16);
        l_transactions t_transactions;
        l_attrs        PLTelemetry.t_attributes;
    BEGIN
        l_span_id := PLTelemetry.start_span('fetch_historical_transactions');
        
        l_attrs(1) := PLTelemetry.add_attribute('db.operation', 'SELECT');
        l_attrs(2) := PLTelemetry.add_attribute('db.table', 'financial_transactions');
        l_attrs(3) := PLTelemetry.add_attribute('customer.id', p_customer_id);
        l_attrs(4) := PLTelemetry.add_attribute('query.period', p_period);
        
        PLTelemetry.add_event(l_span_id, 'query_execution_started', l_attrs);

        -- Simulate heavy database query with 300ms delay
        simulate_processing(300);

        -- Generate fake transaction data
        l_transactions := t_transactions();
        l_transactions.EXTEND(3);
        
        l_transactions(1).transaction_id := 'TXN001';
        l_transactions(1).transaction_date := SYSDATE - 10;
        l_transactions(1).amount := 1250.00;
        l_transactions(1).category := 'Software';
        l_transactions(1).description := 'License renewal';
        l_transactions(1).currency := 'EUR';
        
        l_transactions(2).transaction_id := 'TXN002';
        l_transactions(2).transaction_date := SYSDATE - 5;
        l_transactions(2).amount := 2500.00;
        l_transactions(2).category := 'Consulting';
        l_transactions(2).description := 'Technical consulting';
        l_transactions(2).currency := 'EUR';
        
        l_transactions(3).transaction_id := 'TXN003';
        l_transactions(3).transaction_date := SYSDATE - 1;
        l_transactions(3).amount := 750.00;
        l_transactions(3).category := 'Training';
        l_transactions(3).description := 'Staff training program';
        l_transactions(3).currency := 'EUR';

        l_attrs(1) := PLTelemetry.add_attribute('query.rows_returned', TO_CHAR(l_transactions.COUNT));
        l_attrs(2) := PLTelemetry.add_attribute('query.duration_ms', '300');
        
        PLTelemetry.add_event(l_span_id, 'query_execution_completed', l_attrs);
        PLTelemetry.end_span(l_span_id, 'OK', l_attrs);

        RETURN l_transactions;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            RAISE;
    END fetch_transactions;

    /**
     * Calculate financial metrics - simulates complex calculations
     */
    FUNCTION calculate_metrics(
        p_transactions t_transactions,
        p_customer_id  VARCHAR2,
        p_trace_id     VARCHAR2 DEFAULT NULL
    ) RETURN t_financial_summary
    IS
        l_span_id VARCHAR2(16);
        l_summary t_financial_summary;
        l_total   NUMBER := 0;
        l_attrs   PLTelemetry.t_attributes;
    BEGIN
        l_span_id := PLTelemetry.start_span('calculate_financial_metrics');
        
        l_attrs(1) := PLTelemetry.add_attribute('calculation.type', 'financial_ratios');
        l_attrs(2) := PLTelemetry.add_attribute('input.transactions', TO_CHAR(p_transactions.COUNT));
        l_attrs(3) := PLTelemetry.add_attribute('customer.id', p_customer_id);
        
        PLTelemetry.add_event(l_span_id, 'metric_calculation_started', l_attrs);

        -- Simulate complex calculations with 150ms delay
        simulate_processing(150);

        -- Calculate totals from fake data
        FOR i IN 1..p_transactions.COUNT LOOP
            l_total := l_total + p_transactions(i).amount;
        END LOOP;

        -- Build summary record
        l_summary.customer_id := p_customer_id;
        l_summary.period := NULL; -- Will be set by caller
        l_summary.total_revenue := l_total;
        l_summary.transaction_count := p_transactions.COUNT;
        l_summary.average_transaction := CASE 
            WHEN p_transactions.COUNT > 0 THEN l_total / p_transactions.COUNT 
            ELSE 0 
        END;
        l_summary.processing_time_ms := 150;
        l_summary.generated_at := SYSTIMESTAMP;
        l_summary.trace_id := p_trace_id;
        l_summary.data_source := 'oracle-simulated';

        l_attrs(1) := PLTelemetry.add_attribute('metrics.total_revenue', TO_CHAR(l_summary.total_revenue));
        l_attrs(2) := PLTelemetry.add_attribute('metrics.avg_transaction', TO_CHAR(l_summary.average_transaction));
        l_attrs(3) := PLTelemetry.add_attribute('calculation.duration_ms', '150');
        
        PLTelemetry.add_event(l_span_id, 'metrics_calculation_completed', l_attrs);
        PLTelemetry.end_span(l_span_id, 'OK', l_attrs);

        RETURN l_summary;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            RAISE;
    END calculate_metrics;

    /**
     * Generate top spending categories analysis
     */
    FUNCTION get_top_categories(
        p_transactions t_transactions,
        p_limit       NUMBER DEFAULT 5
    ) RETURN VARCHAR2
    IS
        l_result VARCHAR2(4000);
    BEGIN
        -- Return hardcoded categories for demo
        l_result := '[' ||
            '{"category": "Consulting", "amount": 2500.00, "percentage": 55.56},' ||
            '{"category": "Software", "amount": 1250.00, "percentage": 27.78},' ||
            '{"category": "Training", "amount": 750.00, "percentage": 16.67}' ||
            ']';
            
        RETURN l_result;
    END get_top_categories;

    /**
     * Health check function
     */
    FUNCTION health_check
    RETURN VARCHAR2
    IS
    BEGIN
        RETURN '{"status": "healthy", "service": "financial-api", "timestamp": "' || 
               get_iso_timestamp() || '", "version": "1.0.0"}';
    END health_check;

    /**
     * Configure PLTelemetry for this package
     */
    PROCEDURE configure_telemetry
    IS
    BEGIN
        -- Configure PLTelemetry to use OTLP bridge
        PLTelemetry.set_backend_url('OTLP_BRIDGE');
        PLTelemetry.set_async_mode(FALSE); -- Sync for demo clarity
        
        -- Configure OTLP bridge
        PLT_OTLP_BRIDGE.set_otlp_collector('http://tempo:4318');
        PLT_OTLP_BRIDGE.set_service_info(
            p_service_name => 'oracle-financial-api',
            p_service_version => '1.0.0',
            p_tenant_id => 'financial_dept'
        );
        PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
        
        DBMS_OUTPUT.PUT_LINE('🚀 FINANCIAL_API telemetry configured');
        DBMS_OUTPUT.PUT_LINE('📊 Traces will flow: Oracle → OTLP Bridge → Tempo');
    END configure_telemetry;

END FINANCIAL_API;
/