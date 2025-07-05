-- ============================================================================
-- PLTelemetry Invoice Creation Simulation
-- Distributed Tracing Demo: Oracle Forms → PL/SQL APIs → Oracle Forms
-- ============================================================================

-- ============================================================================
-- API_PRICING Package - Handles product repricing with distributed tracing
-- ============================================================================

CREATE OR REPLACE PACKAGE API_PRICING AS
    /**
     * Calculate prices for invoice items with distributed tracing support
     * 
     * @param p_customer_id Customer identifier for pricing rules
     * @param p_item_count Number of items to price
     * @param p_trace_id Distributed trace ID from calling system
     * @return SUCCESS/ERROR status
     */
    FUNCTION calculate_prices(
        p_customer_id IN NUMBER,
        p_item_count IN NUMBER,
        p_trace_id IN VARCHAR2
    ) RETURN VARCHAR2;
    
END API_PRICING;
/

CREATE OR REPLACE PACKAGE BODY API_PRICING AS

    FUNCTION calculate_prices(
        p_customer_id IN NUMBER,
        p_item_count IN NUMBER,
        p_trace_id IN VARCHAR2
    ) RETURN VARCHAR2
    IS
        l_span_id VARCHAR2(16);
        l_attrs PLTelemetry.t_attributes;
        l_base_amount NUMBER;
        l_discount_pct NUMBER;
        l_final_amount NUMBER;
        l_start_time TIMESTAMP := SYSTIMESTAMP;
    BEGIN
        -- Continue distributed trace from Forms
        l_span_id := PLTelemetry.continue_distributed_trace(
            p_trace_id => p_trace_id,
            p_operation => 'pricing_calculation',
            p_tenant_id => 'invoice_system'
        );
        
        -- Add pricing context
        l_attrs(1) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
        l_attrs(2) := PLTelemetry.add_attribute('pricing.item_count', TO_CHAR(p_item_count));
        l_attrs(3) := PLTelemetry.add_attribute('service.component', 'pricing_engine');
        PLTelemetry.add_event(l_span_id, 'pricing_calculation_started', l_attrs);
        
        -- Simulate pricing logic with realistic business rules
        PLTelemetry.add_event(l_span_id, 'loading_customer_pricing_rules');
        DBMS_LOCK.SLEEP(0.2); -- Customer rule lookup
        
        -- Calculate base pricing
        l_base_amount := p_item_count * 125.50; -- Base price per item
        
        PLTelemetry.add_event(l_span_id, 'applying_volume_discounts');
        DBMS_LOCK.SLEEP(0.3); -- Volume discount calculation
        
        -- Apply customer-specific discount
        l_discount_pct := CASE 
            WHEN p_customer_id <= 1000 THEN 0.15  -- Premium customers
            WHEN p_customer_id <= 5000 THEN 0.10  -- Standard customers  
            ELSE 0.05 -- Basic customers
        END;
        
        PLTelemetry.add_event(l_span_id, 'calculating_tax_implications');
        DBMS_LOCK.SLEEP(0.4); -- Tax calculation
        
        l_final_amount := l_base_amount * (1 - l_discount_pct);
        
        PLTelemetry.add_event(l_span_id, 'finalizing_price_structure');
        DBMS_LOCK.SLEEP(0.2); -- Final price structuring
        
        -- Log pricing metrics
        PLTelemetry.log_metric('pricing.base_amount', l_base_amount, 'currency');
        PLTelemetry.log_metric('pricing.discount_applied', l_discount_pct * 100, 'percentage');
        PLTelemetry.log_metric('pricing.final_amount', l_final_amount, 'currency');
        PLTelemetry.log_metric('pricing.calculation_time_ms', 
            EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, 'ms');
        
        -- Add final pricing attributes
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('pricing.base_amount', TO_CHAR(l_base_amount, '999999.99'));
        l_attrs(2) := PLTelemetry.add_attribute('pricing.discount_pct', TO_CHAR(l_discount_pct * 100, '99.99'));
        l_attrs(3) := PLTelemetry.add_attribute('pricing.final_amount', TO_CHAR(l_final_amount, '999999.99'));
        l_attrs(4) := PLTelemetry.add_attribute('pricing.currency', 'EUR');
        
        PLTelemetry.add_event(l_span_id, 'pricing_calculation_completed', l_attrs);
        
        -- Log distributed success
        PLTelemetry.log_distributed(
            p_trace_id => p_trace_id,
            p_level => 'INFO',
            p_message => 'Pricing calculation completed successfully',
            p_system => 'PRICING_ENGINE'
        );
        
        PLTelemetry.end_span(l_span_id, 'OK');
        
        RETURN 'SUCCESS';
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Log error details to DBMS_OUTPUT for debugging
            DBMS_OUTPUT.PUT_LINE('=== ERROR STACK ===');
            DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_STACK);
            DBMS_OUTPUT.PUT_LINE('=== ERROR BACKTRACE ===');
            DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);

            -- Handle pricing errors with full tracing context
            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('error.message', substr(SQLERRM, 1, 200));
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            l_attrs(3) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
            
            PLTelemetry.log_distributed(
                p_trace_id => p_trace_id,
                p_level => 'ERROR',
                p_message => 'Pricing calculation failed: ' || substr(SQLERRM, 1, 200),
                p_system => 'PRICING_ENGINE'
            );
            
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            
            RETURN 'ERROR: ' || substr(SQLERRM, 1, 200);
    END calculate_prices;
    
END API_PRICING;
/

-- ============================================================================
-- API_INVOICE Package - Handles invoice creation with distributed tracing
-- ============================================================================

CREATE OR REPLACE PACKAGE API_INVOICE AS
    /**
     * Create a new invoice with distributed tracing support
     * 
     * @param p_customer_id Customer identifier
     * @param p_amount Invoice total amount
     * @param p_item_count Number of items in invoice
     * @param p_trace_id Distributed trace ID from calling system
     * @return JSON with invoice details or error message
     */
    FUNCTION create_invoice(
        p_customer_id IN NUMBER,
        p_amount IN NUMBER,
        p_item_count IN NUMBER,
        p_trace_id IN VARCHAR2
    ) RETURN VARCHAR2;
    
END API_INVOICE;
/

CREATE OR REPLACE PACKAGE BODY API_INVOICE AS

    FUNCTION create_invoice(
        p_customer_id IN NUMBER,
        p_amount IN NUMBER,
        p_item_count IN NUMBER,
        p_trace_id IN VARCHAR2
    ) RETURN VARCHAR2
    IS
        l_span_id VARCHAR2(16);
        l_attrs PLTelemetry.t_attributes;
        l_invoice_number VARCHAR2(20);
        l_docket_number VARCHAR2(20);
        l_docket_date VARCHAR2(20);
        l_vat_amount NUMBER;
        l_total_value NUMBER;
        l_start_time TIMESTAMP := SYSTIMESTAMP;
        l_result_json VARCHAR2(4000);
    BEGIN
        -- Continue distributed trace from Forms
        l_span_id := PLTelemetry.continue_distributed_trace(
            p_trace_id => p_trace_id,
            p_operation => 'invoice_creation',
            p_tenant_id => 'invoice_system'
        );
        
        -- Add invoice context
        l_attrs(1) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
        l_attrs(2) := PLTelemetry.add_attribute('invoice.amount', TO_CHAR(p_amount, '999999.99'));
        l_attrs(3) := PLTelemetry.add_attribute('invoice.item_count', TO_CHAR(p_item_count));
        l_attrs(4) := PLTelemetry.add_attribute('service.component', 'invoice_generator');
        PLTelemetry.add_event(l_span_id, 'invoice_creation_started', l_attrs);
        
        -- Generate invoice number
        PLTelemetry.add_event(l_span_id, 'generating_invoice_number');
        DBMS_LOCK.SLEEP(0.3); -- Number generation simulation
        l_invoice_number := 'INV-' || TO_CHAR(SYSDATE, 'YYYY') || '-' || LPAD(DBMS_RANDOM.VALUE(100000, 999999), 6, '0');
        
        -- Generate docket information
        PLTelemetry.add_event(l_span_id, 'creating_docket_information');
        DBMS_LOCK.SLEEP(0.4); -- Docket creation simulation
        l_docket_number := 'DOC-' || LPAD(DBMS_RANDOM.VALUE(10000, 99999), 5, '0');
        l_docket_date := TO_CHAR(SYSDATE, 'YYYY-MM-DD');
        
        -- Calculate VAT and totals
        PLTelemetry.add_event(l_span_id, 'calculating_vat_and_totals');
        DBMS_LOCK.SLEEP(0.5); -- Tax calculation simulation
        l_vat_amount := p_amount * 0.21; -- 21% VAT
        l_total_value := p_amount + l_vat_amount;
        
        -- Validate business rules
        PLTelemetry.add_event(l_span_id, 'validating_business_rules');
        DBMS_LOCK.SLEEP(0.3); -- Business validation simulation
        
        -- Persist invoice to database (simulated)
        PLTelemetry.add_event(l_span_id, 'persisting_invoice_to_database');
        DBMS_LOCK.SLEEP(0.6); -- Database persistence simulation
        
        -- Generate audit trail
        PLTelemetry.add_event(l_span_id, 'creating_audit_trail');
        DBMS_LOCK.SLEEP(0.2); -- Audit creation simulation
        
        -- Log invoice metrics
        PLTelemetry.log_metric('invoice.net_amount', p_amount, 'currency');
        PLTelemetry.log_metric('invoice.vat_amount', l_vat_amount, 'currency');
        PLTelemetry.log_metric('invoice.total_value', l_total_value, 'currency');
        PLTelemetry.log_metric('invoice.creation_time_ms', 
            EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, 'ms');
        PLTelemetry.log_metric('invoices.created', 1, 'count');
        
        -- Build result JSON with all invoice details
        l_result_json := '{'
            || '"status":"SUCCESS",'
            || '"invoice_number":"' || l_invoice_number || '",'
            || '"customer_id":"' || p_customer_id || '",'
            || '"amount":"' || TO_CHAR(p_amount, '999999.99') || '",'
            || '"vat":"' || TO_CHAR(l_vat_amount, '999999.99') || '",'
            || '"value":"' || TO_CHAR(l_total_value, '999999.99') || '",'
            || '"docket_number":"' || l_docket_number || '",'
            || '"docket_date":"' || l_docket_date || '",'
            || '"item_count":"' || p_item_count || '"'
            || '}';
        
        -- Add final invoice attributes
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('invoice.number', l_invoice_number);
        l_attrs(2) := PLTelemetry.add_attribute('invoice.total_value', TO_CHAR(l_total_value, '999999.99'));
        l_attrs(3) := PLTelemetry.add_attribute('invoice.vat_amount', TO_CHAR(l_vat_amount, '999999.99'));
        l_attrs(4) := PLTelemetry.add_attribute('docket.number', l_docket_number);
        l_attrs(5) := PLTelemetry.add_attribute('docket.date', l_docket_date);
        l_attrs(6) := PLTelemetry.add_attribute('invoice.currency', 'EUR');
        
        PLTelemetry.add_event(l_span_id, 'invoice_creation_completed', l_attrs);
        
        -- Log distributed success
        PLTelemetry.log_distributed(
            p_trace_id => p_trace_id,
            p_level => 'INFO',
            p_message => 'Invoice ' || l_invoice_number || ' created successfully',
            p_system => 'INVOICE_ENGINE'
        );
        
        PLTelemetry.end_span(l_span_id, 'OK');
        
        RETURN l_result_json;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Handle invoice creation errors with full context
            l_attrs := PLTelemetry.t_attributes();
            l_attrs(1) := PLTelemetry.add_attribute('error.message', substr(SQLERRM, 1, 200));
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            l_attrs(3) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
            l_attrs(4) := PLTelemetry.add_attribute('invoice.amount', TO_CHAR(p_amount));
            
            PLTelemetry.log_distributed(
                p_trace_id => p_trace_id,
                p_level => 'ERROR',
                p_message => 'Invoice creation failed: ' || substr(SQLERRM, 1, 200),
                p_system => 'INVOICE_ENGINE'
            );
            
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            
            RETURN '{"status":"ERROR","message":"' || REPLACE(substr(SQLERRM, 1, 200), '"', '\"') || '"}';
    END create_invoice;
    
END API_INVOICE;
/

-- ============================================================================
-- FORM_KEY_COMMIT - Main Forms Trigger Procedure
-- Simulates complete invoice creation workflow with distributed tracing
-- ============================================================================

CREATE OR REPLACE PROCEDURE FORM_KEY_COMMIT AS
    -- Main trace and span variables
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
    
    -- Business data variables
    l_customer_id NUMBER := 1234;
    l_item_count NUMBER := 5;
    l_amount NUMBER;
    l_invoice_data VARCHAR2(4000);
    l_invoice_number VARCHAR2(20);
    l_pdf_size NUMBER;
    l_printer_name VARCHAR2(50) := 'HP_LaserJet_Finance_Floor2';
    
    -- Timing variables
    l_start_time TIMESTAMP := SYSTIMESTAMP;
    l_step_start TIMESTAMP;
    
    -- API response variables
    l_pricing_result VARCHAR2(100);
    l_invoice_result VARCHAR2(4000);
    
BEGIN
    -- ========================================================================
    -- STEP 0: Configure PLTelemetry (should be done once per session)
    -- ========================================================================
    BEGIN
        null; -- Placeholder for any session initialization logic
        --PLTelemetry.set_backend_url('OTLP_BRIDGE');
        --PLT_OTLP_BRIDGE.set_otlp_collector('http://plt-otel-collector:4318');
        --PLT_OTLP_BRIDGE.set_service_info('oracle-forms-erp', '2.1.0', 'production');
        PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
        PLTelemetry.set_async_mode(FALSE); -- Immediate sending for demo
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Warning: PLTelemetry configuration failed - ' || substr(SQLERRM, 1, 200));
    END;
    
    -- ========================================================================
    -- STEP 1: Start distributed trace for invoice creation workflow
    -- ========================================================================
    l_trace_id := PLTelemetry.start_trace('invoice_creation_workflow');
    l_span_id := PLTelemetry.start_span('forms_invoice_processing');
    
    -- Add business context for the entire workflow
    l_attrs(1) := PLTelemetry.add_attribute('form.name', 'INVOICE_CREATION');
    l_attrs(2) := PLTelemetry.add_attribute('user.id', USER);
    l_attrs(3) := PLTelemetry.add_attribute('customer.id', TO_CHAR(l_customer_id));
    l_attrs(4) := PLTelemetry.add_attribute('workflow.type', 'invoice_creation');
    l_attrs(5) := PLTelemetry.add_attribute('system.component', 'oracle_forms');
    PLTelemetry.add_event(l_span_id, 'invoice_workflow_started', l_attrs);
    
    DBMS_OUTPUT.PUT_LINE('=== Invoice Creation Workflow Started ===');
    DBMS_OUTPUT.PUT_LINE('Trace ID: ' || l_trace_id);
    DBMS_OUTPUT.PUT_LINE('Customer ID: ' || l_customer_id);
    DBMS_OUTPUT.PUT_LINE('Items: ' || l_item_count);
    
    -- ========================================================================
    -- STEP 2: Load Configuration (0.3s)
    -- ========================================================================
    l_step_start := SYSTIMESTAMP;
    PLTelemetry.add_event(l_span_id, 'loading_form_configuration');
    
    DBMS_OUTPUT.PUT_LINE('→ Loading configuration...');
    DBMS_LOCK.SLEEP(0.3);
    
    -- Log configuration loading metrics
    PLTelemetry.log_metric('config.load_time_ms', 
        EXTRACT(SECOND FROM (SYSTIMESTAMP - l_step_start)) * 1000, 'ms');
    
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('config.version', '2.1.0');
    l_attrs(2) := PLTelemetry.add_attribute('config.environment', 'production');
    PLTelemetry.add_event(l_span_id, 'configuration_loaded', l_attrs);
    
    DBMS_OUTPUT.PUT_LINE('✓ Configuration loaded (300ms)');
    
    -- ========================================================================
    -- STEP 3: Call Repricing API (1.1s) - DISTRIBUTED CALL
    -- ========================================================================
    l_step_start := SYSTIMESTAMP;
    PLTelemetry.add_event(l_span_id, 'calling_repricing_api');
    
    DBMS_OUTPUT.PUT_LINE('→ Calling pricing engine...');
    
    -- Call distributed API with trace context
    l_pricing_result := API_PRICING.calculate_prices(
        p_customer_id => l_customer_id,
        p_item_count => l_item_count,
        p_trace_id => l_trace_id -- Distributed tracing magic!
    );
    
    -- Handle pricing response
    IF l_pricing_result = 'SUCCESS' THEN
        l_amount := l_item_count * 125.50 * 0.90; -- Simulated final price
        PLTelemetry.add_event(l_span_id, 'repricing_completed_successfully');
        PLTelemetry.log_metric('pricing.api_calls', 1, 'count');
        DBMS_OUTPUT.PUT_LINE('✓ Repricing completed - Amount: €' || TO_CHAR(l_amount, '999999.99'));
    ELSE
        PLTelemetry.add_event(l_span_id, 'repricing_failed');
        RAISE_APPLICATION_ERROR(-20001, 'Pricing calculation failed: ' || l_pricing_result);
    END IF;
    
    -- ========================================================================
    -- STEP 4: Perform Validations (1.5s)
    -- ========================================================================
    l_step_start := SYSTIMESTAMP;
    PLTelemetry.add_event(l_span_id, 'performing_business_validations');
    
    DBMS_OUTPUT.PUT_LINE('→ Performing validations...');
    
    -- Simulate various validation steps
    PLTelemetry.add_event(l_span_id, 'validating_customer_credit_limit');
    DBMS_LOCK.SLEEP(0.4);
    
    PLTelemetry.add_event(l_span_id, 'validating_inventory_availability');
    DBMS_LOCK.SLEEP(0.5);
    
    PLTelemetry.add_event(l_span_id, 'validating_pricing_rules');
    DBMS_LOCK.SLEEP(0.3);
    
    PLTelemetry.add_event(l_span_id, 'validating_tax_compliance');
    DBMS_LOCK.SLEEP(0.3);
    
    -- Log validation metrics
    PLTelemetry.log_metric('validation.total_time_ms', 
        EXTRACT(SECOND FROM (SYSTIMESTAMP - l_step_start)) * 1000, 'ms');
    PLTelemetry.log_metric('validations.performed', 4, 'count');
    
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('validation.credit_status', 'approved');
    l_attrs(2) := PLTelemetry.add_attribute('validation.inventory_status', 'available');
    l_attrs(3) := PLTelemetry.add_attribute('validation.pricing_status', 'valid');
    l_attrs(4) := PLTelemetry.add_attribute('validation.tax_status', 'compliant');
    PLTelemetry.add_event(l_span_id, 'all_validations_passed', l_attrs);
    
    DBMS_OUTPUT.PUT_LINE('✓ Validations completed (1500ms)');
    
    -- ========================================================================
    -- STEP 5: Create Invoice API (2.3s) - DISTRIBUTED CALL
    -- ========================================================================
    l_step_start := SYSTIMESTAMP;
    PLTelemetry.add_event(l_span_id, 'calling_invoice_creation_api');
    
    DBMS_OUTPUT.PUT_LINE('→ Creating invoice...');
    
    -- Call distributed API with trace context
    l_invoice_result := API_INVOICE.create_invoice(
        p_customer_id => l_customer_id,
        p_amount => l_amount,
        p_item_count => l_item_count,
        p_trace_id => l_trace_id -- Distributed tracing magic!
    );
    
    -- Parse invoice response (simplified)
    IF INSTR(l_invoice_result, '"status":"SUCCESS"') > 0 THEN
        -- Extract invoice number from JSON response
        l_invoice_number := REGEXP_SUBSTR(l_invoice_result, '"invoice_number":"([^"]+)"', 1, 1, NULL, 1);
        
        PLTelemetry.add_event(l_span_id, 'invoice_created_successfully');
        PLTelemetry.log_metric('invoices.created', 1, 'count');
        DBMS_OUTPUT.PUT_LINE('✓ Invoice created - Number: ' || l_invoice_number);
    ELSE
        PLTelemetry.add_event(l_span_id, 'invoice_creation_failed');
        RAISE_APPLICATION_ERROR(-20002, 'Invoice creation failed: ' || l_invoice_result);
    END IF;
    
    -- ========================================================================
    -- STEP 6: Generate PDF with Oracle Reports (4.3s)
    -- ========================================================================
    l_step_start := SYSTIMESTAMP;
    PLTelemetry.add_event(l_span_id, 'generating_pdf_with_oracle_reports');
    
    DBMS_OUTPUT.PUT_LINE('→ Generating PDF with Oracle Reports...');
    
    -- Simulate Oracle Reports PDF generation
    DBMS_LOCK.SLEEP(4.3);
    l_pdf_size := ROUND(DBMS_RANDOM.VALUE(150, 350)); -- KB
    
    -- Log Reports generation metrics
    PLTelemetry.log_metric('reports.generation_time_ms', 
        EXTRACT(SECOND FROM (SYSTIMESTAMP - l_step_start)) * 1000, 'ms');
    PLTelemetry.log_metric('reports.pdf_size_kb', l_pdf_size, 'kilobytes');
    PLTelemetry.log_metric('reports.generated', 1, 'count');
    
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('reports.engine', 'oracle_reports');
    l_attrs(2) := PLTelemetry.add_attribute('reports.template', 'invoice_template_v2.rdf');
    l_attrs(3) := PLTelemetry.add_attribute('pdf.size_kb', TO_CHAR(l_pdf_size));
    l_attrs(4) := PLTelemetry.add_attribute('pdf.format', 'A4');
    l_attrs(5) := PLTelemetry.add_attribute('invoice.number', l_invoice_number);
    PLTelemetry.add_event(l_span_id, 'pdf_generation_completed', l_attrs);
    
    DBMS_OUTPUT.PUT_LINE('✓ PDF generated - Size: ' || l_pdf_size || 'KB (4300ms)');
    
    -- ========================================================================
    -- STEP 7: Send to Printer (4.3s)
    -- ========================================================================
    l_step_start := SYSTIMESTAMP;
    PLTelemetry.add_event(l_span_id, 'sending_to_printer');
    
    DBMS_OUTPUT.PUT_LINE('→ Sending to printer...');
    
    -- Simulate printer communication
    DBMS_LOCK.SLEEP(4.3);
    
    -- Log printing metrics
    PLTelemetry.log_metric('printing.transmission_time_ms', 
        EXTRACT(SECOND FROM (SYSTIMESTAMP - l_step_start)) * 1000, 'ms');
    PLTelemetry.log_metric('documents.printed', 1, 'count');
    
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('printer.name', l_printer_name);
    l_attrs(2) := PLTelemetry.add_attribute('printer.location', 'Finance Floor 2');
    l_attrs(3) := PLTelemetry.add_attribute('print.job_id', 'PJ-' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'));
    l_attrs(4) := PLTelemetry.add_attribute('print.copies', '2');
    l_attrs(5) := PLTelemetry.add_attribute('print.paper_size', 'A4');
    PLTelemetry.add_event(l_span_id, 'document_sent_to_printer', l_attrs);
    
    DBMS_OUTPUT.PUT_LINE('✓ Sent to printer: ' || l_printer_name || ' (4300ms)');
    
    -- ========================================================================
    -- STEP 8: Complete workflow and finalize tracing
    -- ========================================================================
    
    -- Log final workflow metrics
    PLTelemetry.log_metric('workflow.total_time_ms', 
        EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, 'ms');
    PLTelemetry.log_metric('workflows.completed', 1, 'count');
    
    -- Add final workflow summary
    l_attrs := PLTelemetry.t_attributes();
    l_attrs(1) := PLTelemetry.add_attribute('workflow.status', 'completed');
    l_attrs(2) := PLTelemetry.add_attribute('invoice.number', l_invoice_number);
    l_attrs(3) := PLTelemetry.add_attribute('invoice.amount', TO_CHAR(l_amount, '999999.99'));
    l_attrs(4) := PLTelemetry.add_attribute('customer.id', TO_CHAR(l_customer_id));
    l_attrs(5) := PLTelemetry.add_attribute('workflow.duration_ms', 
        TO_CHAR(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, '99999'));
    PLTelemetry.add_event(l_span_id, 'invoice_workflow_completed', l_attrs);
    
    -- End the main Forms span and trace
    PLTelemetry.end_span(l_span_id, 'OK');
    PLTelemetry.end_trace(l_trace_id);
    
    DBMS_OUTPUT.PUT_LINE('=== Invoice Creation Workflow Completed ===');
    DBMS_OUTPUT.PUT_LINE('Invoice: ' || l_invoice_number);
    DBMS_OUTPUT.PUT_LINE('Total time: ' || 
        ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time))) || ' seconds');
    DBMS_OUTPUT.PUT_LINE('Trace ID: ' || l_trace_id);
    DBMS_OUTPUT.PUT_LINE('Status: SUCCESS');
    
EXCEPTION
    WHEN OTHERS THEN
        -- Global error handler with full tracing context
        l_attrs := PLTelemetry.t_attributes();
        l_attrs(1) := PLTelemetry.add_attribute('error.message', substr(SQLERRM, 1, 200));
        l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
        l_attrs(3) := PLTelemetry.add_attribute('workflow.status', 'failed');
        l_attrs(4) := PLTelemetry.add_attribute('customer.id', TO_CHAR(l_customer_id));
        
        PLTelemetry.log_distributed(
            p_trace_id => l_trace_id,
            p_level => 'ERROR',
            p_message => 'Invoice workflow failed: ' || substr(SQLERRM, 1, 200),
            p_system => 'ORACLE_FORMS'
        );
        
        PLTelemetry.add_event(l_span_id, 'workflow_failed', l_attrs);
        PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
        PLTelemetry.end_trace(l_trace_id);
        
        DBMS_OUTPUT.PUT_LINE('=== Invoice Creation Workflow FAILED ===');
        DBMS_OUTPUT.PUT_LINE('Error: ' || substr(SQLERRM, 1, 200));
        DBMS_OUTPUT.PUT_LINE('Trace ID: ' || l_trace_id);
        
        -- Re-raise the error so Forms can handle it appropriately
        RAISE;
END FORM_KEY_COMMIT;
/

-- ============================================================================
-- Usage Example and Demo
-- ============================================================================

/*
-- To run the complete simulation:

-- 1. First ensure PLTelemetry is properly configured
BEGIN
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    PLT_OTLP_BRIDGE.set_otlp_collector('http://plt-otel-collector:4318');
    PLT_OTLP_BRIDGE.set_service_info('oracle-forms-erp', '2.1.0');
END;
/

-- 2. Execute the complete invoice workflow
EXEC FORM_KEY_COMMIT;

-- 3. Check telemetry data was generated
SELECT COUNT(*) as traces_created FROM plt_traces WHERE service_name = 'oracle-plsql';
SELECT COUNT(*) as spans_created FROM plt_spans WHERE operation_name LIKE '%invoice%';
SELECT COUNT(*) as events_created FROM plt_events WHERE span_id IN 
    (SELECT span_id FROM plt_spans WHERE operation_name LIKE '%invoice%');

-- 4. View the trace in Grafana/Tempo using the trace_id from the output

-- Expected timeline in Grafana:
-- ├── forms_invoice_processing (13.8s total)
--     ├── loading_form_configuration (0.3s)
--     ├── pricing_calculation (1.1s) [distributed to API_PRICING]
--     ├── performing_business_validations (1.5s)
--     ├── invoice_creation (2.3s) [distributed to API_INVOICE]
--     ├── generating_pdf_with_oracle_reports (4.3s)
--     └── sending_to_printer (4.3s)

-- All operations will be correlated by the same trace_id and visible as 
-- a complete distributed timeline across Oracle Forms and PL/SQL APIs!
*/