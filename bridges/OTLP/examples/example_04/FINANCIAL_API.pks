CREATE OR REPLACE PACKAGE FINANCIAL_API
AS
    /**
     * FINANCIAL_API - PLTelemetry Example 04
     * 
     * Simulates financial data processing with distributed tracing
     * Called from Node.js via ORDS with trace context propagation
     * 
     * Dependencies: PLTelemetry, PLT_OTLP_BRIDGE
     */

    --------------------------------------------------------------------------
    -- TYPE DEFINITIONS
    --------------------------------------------------------------------------
    
    -- Input parameters for financial summary
    TYPE t_summary_params IS RECORD (
        customer_id     VARCHAR2(32),
        period          VARCHAR2(10),  -- Format: YYYY-Q[1-4]
        include_metrics BOOLEAN DEFAULT TRUE
    );
    
    -- Financial transaction record
    TYPE t_transaction IS RECORD (
        transaction_id      VARCHAR2(32),
        transaction_date    DATE,
        amount             NUMBER(12,2),
        category           VARCHAR2(50),
        description        VARCHAR2(255),
        currency           VARCHAR2(3)
    );
    
    -- Collection of transactions
    TYPE t_transactions IS TABLE OF t_transaction;
    
    -- Financial summary result
    TYPE t_financial_summary IS RECORD (
        customer_id         VARCHAR2(32),
        period             VARCHAR2(10),
        total_revenue      NUMBER(12,2),
        transaction_count  NUMBER,
        average_transaction NUMBER(12,2),
        processing_time_ms NUMBER,
        generated_at       TIMESTAMP WITH TIME ZONE,
        trace_id          VARCHAR2(32),
        data_source       VARCHAR2(50)
    );

    --------------------------------------------------------------------------
    -- PUBLIC PROCEDURES AND FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Main entry point for financial summary generation
     * Called by ORDS endpoint with distributed trace context
     *
     * @param p_customer_id Customer identifier
     * @param p_period Reporting period (YYYY-Q[1-4])
     * @param p_include_metrics Include detailed metrics flag
     * @param p_trace_id Distributed trace ID from Node.js
     * @param p_span_id Parent span ID from Node.js
     * @return JSON string with financial summary
     */
    FUNCTION generate_financial_summary(
        p_customer_id     VARCHAR2,
        p_period         VARCHAR2,
        p_include_metrics BOOLEAN DEFAULT TRUE,
        p_trace_id       VARCHAR2 DEFAULT NULL,
        p_span_id        VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    /**
     * Fetch historical transactions for customer and period
     * Simulates heavy database queries with sleep
     *
     * @param p_customer_id Customer identifier
     * @param p_period Reporting period
     * @param p_trace_id Current trace ID
     * @return Collection of transactions
     */
    FUNCTION fetch_transactions(
        p_customer_id VARCHAR2,
        p_period     VARCHAR2,
        p_trace_id   VARCHAR2 DEFAULT NULL
    ) RETURN t_transactions;

    /**
     * Calculate financial metrics and ratios
     * Simulates complex calculations with sleep
     *
     * @param p_transactions Transaction data
     * @param p_customer_id Customer identifier
     * @param p_trace_id Current trace ID
     * @return Financial summary record
     */
    FUNCTION calculate_metrics(
        p_transactions t_transactions,
        p_customer_id  VARCHAR2,
        p_trace_id     VARCHAR2 DEFAULT NULL
    ) RETURN t_financial_summary;

    /**
     * Generate top spending categories analysis
     * 
     * @param p_transactions Transaction data
     * @param p_limit Maximum categories to return
     * @return JSON array of top categories
     */
    FUNCTION get_top_categories(
        p_transactions t_transactions,
        p_limit       NUMBER DEFAULT 5
    ) RETURN VARCHAR2;

    /**
     * Health check function for ORDS endpoint
     * 
     * @return Simple status JSON
     */
    FUNCTION health_check
    RETURN VARCHAR2;

    /**
     * Configure PLTelemetry for this package
     * Should be called once during setup
     */
    PROCEDURE configure_telemetry;

END FINANCIAL_API;
/