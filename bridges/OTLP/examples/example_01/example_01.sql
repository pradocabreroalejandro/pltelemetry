-- ============================================================================
-- PLTelemetry Invoice Creation Simulation - FIXED PARENT-CHILD HIERARCHY
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
    * @param p_parent_span_id Parent span ID for proper hierarchy
    * @return SUCCESS/ERROR status
    */
   FUNCTION calculate_prices(
       p_customer_id IN NUMBER,
       p_item_count IN NUMBER,
       p_trace_id IN VARCHAR2,
       p_parent_span_id IN VARCHAR2
   ) RETURN VARCHAR2;
   
END API_PRICING;
/

CREATE OR REPLACE PACKAGE BODY API_PRICING AS

   FUNCTION calculate_prices(
       p_customer_id IN NUMBER,
       p_item_count IN NUMBER,
       p_trace_id IN VARCHAR2,
       p_parent_span_id IN VARCHAR2
   ) RETURN VARCHAR2
   IS
       l_span_id VARCHAR2(16);
       l_attrs PLTelemetry.t_attributes;
       l_base_amount NUMBER;
       l_discount_pct NUMBER;
       l_final_amount NUMBER;
       l_start_time TIMESTAMP := SYSTIMESTAMP;
   BEGIN
       -- Create child span under the Forms parent span
       l_span_id := PLTelemetry.start_span(
           p_operation => 'pricing_calculation',
           p_parent_span_id => p_parent_span_id,
           p_trace_id => p_trace_id
       );
       
       -- Set tenant context for this span
       PLTelemetry.set_tenant_context('invoice_system');
       
       -- Add pricing context
       l_attrs(1) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
       l_attrs(2) := PLTelemetry.add_attribute('pricing.item_count', TO_CHAR(p_item_count));
       l_attrs(3) := PLTelemetry.add_attribute('service.component', 'pricing_engine');
       l_attrs(4) := PLTelemetry.add_attribute('api.name', 'calculate_prices');
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
       
       -- Log pricing metrics with trace correlation
       PLTelemetry.log_metric('pricing.base_amount', l_base_amount, 'currency', PLTelemetry.t_attributes(), TRUE);
       PLTelemetry.log_metric('pricing.discount_applied', l_discount_pct * 100, 'percentage', PLTelemetry.t_attributes(), TRUE);
       PLTelemetry.log_metric('pricing.final_amount', l_final_amount, 'currency', PLTelemetry.t_attributes(), TRUE);
       PLTelemetry.log_metric('pricing.calculation_time_ms', 
           EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, 'ms', PLTelemetry.t_attributes(), TRUE);
       
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
           DBMS_OUTPUT.PUT_LINE('=== PRICING API ERROR STACK ===');
           DBMS_OUTPUT.PUT_LINE(SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));

           -- Handle pricing errors with full tracing context
           l_attrs := PLTelemetry.t_attributes();
           l_attrs(1) := PLTelemetry.add_attribute('error.message', SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
           l_attrs(2) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
           l_attrs(3) := PLTelemetry.add_attribute('api.name', 'calculate_prices');
           
           PLTelemetry.log_distributed(
               p_trace_id => p_trace_id,
               p_level => 'ERROR',
               p_message => 'Pricing calculation failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200),
               p_system => 'PRICING_ENGINE'
           );
           
           PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
           
           RETURN 'ERROR: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200);
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
    * @param p_parent_span_id Parent span ID for proper hierarchy
    * @return JSON with invoice details or error message
    */
   FUNCTION create_invoice(
       p_customer_id IN NUMBER,
       p_amount IN NUMBER,
       p_item_count IN NUMBER,
       p_trace_id IN VARCHAR2,
       p_parent_span_id IN VARCHAR2
   ) RETURN VARCHAR2;
   
END API_INVOICE;
/

CREATE OR REPLACE PACKAGE BODY API_INVOICE AS

   FUNCTION create_invoice(
       p_customer_id IN NUMBER,
       p_amount IN NUMBER,
       p_item_count IN NUMBER,
       p_trace_id IN VARCHAR2,
       p_parent_span_id IN VARCHAR2
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
       -- Create child span under the Forms parent span
       l_span_id := PLTelemetry.start_span(
           p_operation => 'invoice_creation',
           p_parent_span_id => p_parent_span_id,
           p_trace_id => p_trace_id
       );
       
       -- Set tenant context for this span
       PLTelemetry.set_tenant_context('invoice_system');
       
       -- Add invoice context
       l_attrs(1) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
       l_attrs(2) := PLTelemetry.add_attribute('invoice.amount', TO_CHAR(p_amount, '999999.99'));
       l_attrs(3) := PLTelemetry.add_attribute('invoice.item_count', TO_CHAR(p_item_count));
       l_attrs(4) := PLTelemetry.add_attribute('service.component', 'invoice_generator');
       l_attrs(5) := PLTelemetry.add_attribute('api.name', 'create_invoice');
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
       
       -- Log invoice metrics with trace correlation
       PLTelemetry.log_metric('invoice.net_amount', p_amount, 'currency', PLTelemetry.t_attributes(), TRUE);
       PLTelemetry.log_metric('invoice.vat_amount', l_vat_amount, 'currency', PLTelemetry.t_attributes(), TRUE);
       PLTelemetry.log_metric('invoice.total_value', l_total_value, 'currency', PLTelemetry.t_attributes(), TRUE);
       PLTelemetry.log_metric('invoice.creation_time_ms', 
           EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, 'ms', PLTelemetry.t_attributes(), TRUE);
       PLTelemetry.log_metric('invoices.created', 1, 'count', PLTelemetry.t_attributes(), TRUE);
       
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
           l_attrs(1) := PLTelemetry.add_attribute('error.message', SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
           l_attrs(2) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
           l_attrs(3) := PLTelemetry.add_attribute('invoice.amount', TO_CHAR(p_amount));
           l_attrs(4) := PLTelemetry.add_attribute('api.name', 'create_invoice');
           
           PLTelemetry.log_distributed(
               p_trace_id => p_trace_id,
               p_level => 'ERROR',
               p_message => 'Invoice creation failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200),
               p_system => 'INVOICE_ENGINE'
           );
           
           PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
           
           RETURN '{"status":"ERROR","message":"' || REPLACE(SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200), '"', '\"') || '"}';
   END create_invoice;
   
END API_INVOICE;
/

-- ============================================================================
-- FORM_KEY_COMMIT - Main Forms Trigger Procedure - FIXED HIERARCHY
-- Simulates complete invoice creation workflow with distributed tracing
-- ============================================================================

CREATE OR REPLACE PROCEDURE FORM_KEY_COMMIT AS
   -- Main trace and span variables
   l_trace_id VARCHAR2(32);
   l_main_span_id VARCHAR2(16);  -- Main Forms span (parent of all)
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
       PLT_OTLP_BRIDGE.set_debug_mode(FALSE); -- No debug spam
       PLTelemetry.set_async_mode(FALSE); -- Immediate sending for demo
   EXCEPTION
       WHEN OTHERS THEN
           DBMS_OUTPUT.PUT_LINE('Warning: PLTelemetry configuration failed - ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
   END;
   
   -- ========================================================================
   -- STEP 1: Start distributed trace for invoice creation workflow
   -- ========================================================================
   l_trace_id := PLTelemetry.start_trace('invoice_creation_workflow');
   l_main_span_id := PLTelemetry.start_span('forms_invoice_processing', NULL, l_trace_id);
   
   -- Add business context for the entire workflow
   l_attrs(1) := PLTelemetry.add_attribute('form.name', 'INVOICE_CREATION');
   l_attrs(2) := PLTelemetry.add_attribute('user.id', USER);
   l_attrs(3) := PLTelemetry.add_attribute('customer.id', TO_CHAR(l_customer_id));
   l_attrs(4) := PLTelemetry.add_attribute('workflow.type', 'invoice_creation');
   l_attrs(5) := PLTelemetry.add_attribute('system.component', 'oracle_forms');
   PLTelemetry.add_event(l_main_span_id, 'invoice_workflow_started', l_attrs);
   
   DBMS_OUTPUT.PUT_LINE('=== Invoice Creation Workflow Started ===');
   DBMS_OUTPUT.PUT_LINE('Trace ID: ' || l_trace_id);
   DBMS_OUTPUT.PUT_LINE('Main Span ID: ' || l_main_span_id);
   DBMS_OUTPUT.PUT_LINE('Customer ID: ' || l_customer_id);
   DBMS_OUTPUT.PUT_LINE('Items: ' || l_item_count);
   
   -- ========================================================================
   -- STEP 2: Load Configuration (0.3s)
   -- ========================================================================
   l_step_start := SYSTIMESTAMP;
   PLTelemetry.add_event(l_main_span_id, 'loading_form_configuration');
   
   DBMS_OUTPUT.PUT_LINE('→ Loading configuration...');
   DBMS_LOCK.SLEEP(0.3);
   
   -- Log configuration loading metrics
   PLTelemetry.log_metric('config.load_time_ms', 
       EXTRACT(SECOND FROM (SYSTIMESTAMP - l_step_start)) * 1000, 'ms', PLTelemetry.t_attributes(), TRUE);
   
   l_attrs := PLTelemetry.t_attributes();
   l_attrs(1) := PLTelemetry.add_attribute('config.version', '2.1.0');
   l_attrs(2) := PLTelemetry.add_attribute('config.environment', 'production');
   PLTelemetry.add_event(l_main_span_id, 'configuration_loaded', l_attrs);
   
   DBMS_OUTPUT.PUT_LINE('✓ Configuration loaded (300ms)');
   
   -- ========================================================================
   -- STEP 3: Call Repricing API (1.1s) - DISTRIBUTED CALL WITH PROPER PARENT
   -- ========================================================================
   l_step_start := SYSTIMESTAMP;
   PLTelemetry.add_event(l_main_span_id, 'calling_repricing_api');
   
   DBMS_OUTPUT.PUT_LINE('→ Calling pricing engine...');
   
   -- Call distributed API with trace context AND parent span for hierarchy
   l_pricing_result := API_PRICING.calculate_prices(
       p_customer_id => l_customer_id,
       p_item_count => l_item_count,
       p_trace_id => l_trace_id,
       p_parent_span_id => l_main_span_id  -- FIXED: Now has proper parent!
   );
   
   -- Handle pricing response
   IF l_pricing_result = 'SUCCESS' THEN
       l_amount := l_item_count * 125.50 * 0.90; -- Simulated final price
       PLTelemetry.add_event(l_main_span_id, 'repricing_completed_successfully');
       PLTelemetry.log_metric('pricing.api_calls', 1, 'count', PLTelemetry.t_attributes(), TRUE);
       DBMS_OUTPUT.PUT_LINE('✓ Repricing completed - Amount: €' || TO_CHAR(l_amount, '999999.99'));
   ELSE
       PLTelemetry.add_event(l_main_span_id, 'repricing_failed');
       RAISE_APPLICATION_ERROR(-20001, 'Pricing calculation failed: ' || l_pricing_result);
   END IF;
   
   -- ========================================================================
   -- STEP 4: Perform Validations (1.5s)
   -- ========================================================================
   l_step_start := SYSTIMESTAMP;
   PLTelemetry.add_event(l_main_span_id, 'performing_business_validations');
   
   DBMS_OUTPUT.PUT_LINE('→ Performing validations...');
   
   -- Simulate various validation steps
   PLTelemetry.add_event(l_main_span_id, 'validating_customer_credit_limit');
   DBMS_LOCK.SLEEP(0.4);
   
   PLTelemetry.add_event(l_main_span_id, 'validating_inventory_availability');
   DBMS_LOCK.SLEEP(0.5);
   
   PLTelemetry.add_event(l_main_span_id, 'validating_pricing_rules');
   DBMS_LOCK.SLEEP(0.3);
   
   PLTelemetry.add_event(l_main_span_id, 'validating_tax_compliance');
   DBMS_LOCK.SLEEP(0.3);
   
   -- Log validation metrics
   PLTelemetry.log_metric('validation.total_time_ms', 
       EXTRACT(SECOND FROM (SYSTIMESTAMP - l_step_start)) * 1000, 'ms', PLTelemetry.t_attributes(), TRUE);
   PLTelemetry.log_metric('validations.performed', 4, 'count', PLTelemetry.t_attributes(), TRUE);
   
   l_attrs := PLTelemetry.t_attributes();
   l_attrs(1) := PLTelemetry.add_attribute('validation.credit_status', 'approved');
   l_attrs(2) := PLTelemetry.add_attribute('validation.inventory_status', 'available');
   l_attrs(3) := PLTelemetry.add_attribute('validation.pricing_status', 'valid');
   l_attrs(4) := PLTelemetry.add_attribute('validation.tax_status', 'compliant');
   PLTelemetry.add_event(l_main_span_id, 'all_validations_passed', l_attrs);
   
   DBMS_OUTPUT.PUT_LINE('✓ Validations completed (1500ms)');
   
   -- ========================================================================
   -- STEP 5: Create Invoice API (2.3s) - DISTRIBUTED CALL WITH PROPER PARENT
   -- ========================================================================
   l_step_start := SYSTIMESTAMP;
   PLTelemetry.add_event(l_main_span_id, 'calling_invoice_creation_api');
   
   DBMS_OUTPUT.PUT_LINE('→ Creating invoice...');
   
   -- Call distributed API with trace context AND parent span for hierarchy
   l_invoice_result := API_INVOICE.create_invoice(
       p_customer_id => l_customer_id,
       p_amount => l_amount,
       p_item_count => l_item_count,
       p_trace_id => l_trace_id,
       p_parent_span_id => l_main_span_id  -- FIXED: Now has proper parent!
   );
   
   -- Parse invoice response (simplified)
   IF INSTR(l_invoice_result, '"status":"SUCCESS"') > 0 THEN
       -- Extract invoice number from JSON response
       l_invoice_number := REGEXP_SUBSTR(l_invoice_result, '"invoice_number":"([^"]+)"', 1, 1, NULL, 1);
       
       PLTelemetry.add_event(l_main_span_id, 'invoice_created_successfully');
       PLTelemetry.log_metric('invoices.created', 1, 'count', PLTelemetry.t_attributes(), TRUE);
       DBMS_OUTPUT.PUT_LINE('✓ Invoice created - Number: ' || l_invoice_number);
   ELSE
       PLTelemetry.add_event(l_main_span_id, 'invoice_creation_failed');
       RAISE_APPLICATION_ERROR(-20002, 'Invoice creation failed: ' || l_invoice_result);
   END IF;
   
   -- ========================================================================
   -- STEP 6: Generate PDF with Oracle Reports (4.3s)
   -- ========================================================================
   l_step_start := SYSTIMESTAMP;
   PLTelemetry.add_event(l_main_span_id, 'generating_pdf_with_oracle_reports');
   
   DBMS_OUTPUT.PUT_LINE('→ Generating PDF with Oracle Reports...');
   
   -- Simulate Oracle Reports PDF generation
   DBMS_LOCK.SLEEP(4.3);
   l_pdf_size := ROUND(DBMS_RANDOM.VALUE(150, 350)); -- KB
   
   -- Log Reports generation metrics
   PLTelemetry.log_metric('reports.generation_time_ms', 
       EXTRACT(SECOND FROM (SYSTIMESTAMP - l_step_start)) * 1000, 'ms', PLTelemetry.t_attributes(), TRUE);
   PLTelemetry.log_metric('reports.pdf_size_kb', l_pdf_size, 'kilobytes', PLTelemetry.t_attributes(), TRUE);
   PLTelemetry.log_metric('reports.generated', 1, 'count', PLTelemetry.t_attributes(), TRUE);
   
   l_attrs := PLTelemetry.t_attributes();
   l_attrs(1) := PLTelemetry.add_attribute('reports.engine', 'oracle_reports');
   l_attrs(2) := PLTelemetry.add_attribute('reports.template', 'invoice_template_v2.rdf');
   l_attrs(3) := PLTelemetry.add_attribute('pdf.size_kb', TO_CHAR(l_pdf_size));
   l_attrs(4) := PLTelemetry.add_attribute('pdf.format', 'A4');
   l_attrs(5) := PLTelemetry.add_attribute('invoice.number', l_invoice_number);
   PLTelemetry.add_event(l_main_span_id, 'pdf_generation_completed', l_attrs);
   
   DBMS_OUTPUT.PUT_LINE('✓ PDF generated - Size: ' || l_pdf_size || 'KB (4300ms)');
   
   -- ========================================================================
   -- STEP 7: Send to Printer (4.3s)
   -- ========================================================================
   l_step_start := SYSTIMESTAMP;
   PLTelemetry.add_event(l_main_span_id, 'sending_to_printer');
   
   DBMS_OUTPUT.PUT_LINE('→ Sending to printer...');
   
   -- Simulate printer communication
   DBMS_LOCK.SLEEP(4.3);
   
   -- Log printing metrics
   PLTelemetry.log_metric('printing.transmission_time_ms', 
       EXTRACT(SECOND FROM (SYSTIMESTAMP - l_step_start)) * 1000, 'ms', PLTelemetry.t_attributes(), TRUE);
   PLTelemetry.log_metric('documents.printed', 1, 'count', PLTelemetry.t_attributes(), TRUE);
   
   l_attrs := PLTelemetry.t_attributes();
   l_attrs(1) := PLTelemetry.add_attribute('printer.name', l_printer_name);
   l_attrs(2) := PLTelemetry.add_attribute('printer.location', 'Finance Floor 2');
   l_attrs(3) := PLTelemetry.add_attribute('print.job_id', 'PJ-' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'));
   l_attrs(4) := PLTelemetry.add_attribute('print.copies', '2');
   l_attrs(5) := PLTelemetry.add_attribute('print.paper_size', 'A4');
   PLTelemetry.add_event(l_main_span_id, 'document_sent_to_printer', l_attrs);
   
   DBMS_OUTPUT.PUT_LINE('✓ Sent to printer: ' || l_printer_name || ' (4300ms)');
   
   -- ========================================================================
   -- STEP 8: Complete workflow and finalize tracing
   -- ========================================================================
   
   -- Log final workflow metrics
   PLTelemetry.log_metric('workflow.total_time_ms', 
       EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, 'ms', PLTelemetry.t_attributes(), TRUE);
   PLTelemetry.log_metric('workflows.completed', 1, 'count', PLTelemetry.t_attributes(), TRUE);
   
   -- Add final workflow summary
   l_attrs := PLTelemetry.t_attributes();
   l_attrs(1) := PLTelemetry.add_attribute('workflow.status', 'completed');
   l_attrs(2) := PLTelemetry.add_attribute('invoice.number', l_invoice_number);
   l_attrs(3) := PLTelemetry.add_attribute('invoice.amount', TO_CHAR(l_amount, '999999.99'));
   l_attrs(4) := PLTelemetry.add_attribute('customer.id', TO_CHAR(l_customer_id));
   l_attrs(5) := PLTelemetry.add_attribute('workflow.duration_ms', 
       TO_CHAR(EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000, '99999'));
   PLTelemetry.add_event(l_main_span_id, 'invoice_workflow_completed', l_attrs);
   
   -- End the main Forms span and trace
   PLTelemetry.end_span(l_main_span_id, 'OK');
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
       l_attrs(1) := PLTelemetry.add_attribute('error.message', SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
       l_attrs(2) := PLTelemetry.add_attribute('workflow.status', 'failed');
       l_attrs(3) := PLTelemetry.add_attribute('customer.id', TO_CHAR(l_customer_id));
       
       PLTelemetry.log_distributed(
           p_trace_id => l_trace_id,
           p_level => 'ERROR',
           p_message => 'Invoice workflow failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200),
           p_system => 'ORACLE_FORMS'
       );
       
       PLTelemetry.add_event(l_main_span_id, 'workflow_failed', l_attrs);
       PLTelemetry.end_span(l_main_span_id, 'ERROR', l_attrs);
       PLTelemetry.end_trace(l_trace_id);
       
       DBMS_OUTPUT.PUT_LINE('=== Invoice Creation Workflow FAILED ===');
       DBMS_OUTPUT.PUT_LINE('Error: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
       DBMS_OUTPUT.PUT_LINE('Trace ID: ' || l_trace_id);
       
       -- Re-raise the error so Forms can handle it appropriately
       RAISE;
END FORM_KEY_COMMIT;
/