# Invoice Creation Workflow - Distributed Tracing Example

**Example 1: Complete invoice creation workflow with distributed tracing across Oracle Forms and PL/SQL APIs**

This example demonstrates PLTelemetry's distributed tracing capabilities by simulating a realistic invoice creation workflow that spans multiple systems:

```
Oracle Forms → API_PRICING → API_INVOICE → Oracle Reports → Oracle Forms
     ↓              ↓              ↓              ↓              ↓
          All correlated by the same trace_id in Grafana/Tempo
```

## What This Example Demonstrates

- **Distributed tracing** across Oracle Forms and PL/SQL packages
- **Complete workflow observability** with 18+ business events
- **Performance monitoring** of each operation (config loading, pricing, validations, PDF generation, printing)
- **Business metrics collection** (amounts, VAT, processing times, document sizes)
- **OTLP integration** with modern observability platforms (Grafana/Tempo)
- **Error-resilient telemetry** that never breaks business logic

## Architecture Overview

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Oracle Forms  │───▶│   API_PRICING   │───▶│   API_INVOICE   │
│ (Main Workflow) │    │ (Price Calc)    │    │ (Invoice Gen)   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
          │                       │                       │
          └───────────────────────┼───────────────────────┘
                                  ▼
                    ┌─────────────────────────┐
                    │     PLTelemetry        │
                    │   (Trace Collection)   │
                    └─────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │     OTLP Bridge        │
                    │  (Format Conversion)   │
                    └─────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │   Grafana + Tempo      │
                    │ (Timeline Visualization)│
                    └─────────────────────────┘
```

## Timeline Overview

**Total Duration:** ~14.3 seconds

| Step | Duration | Description |
|------|----------|-------------|
| Configuration Loading | 300ms | Form setup and configuration |
| Pricing Calculation | 1.1s | **Distributed call** to API_PRICING |
| Business Validations | 1.5s | Credit, inventory, pricing, tax validations |
| Invoice Creation | 2.3s | **Distributed call** to API_INVOICE |
| PDF Generation | 4.3s | Oracle Reports simulation |
| Printer Transmission | 4.3s | Document sending to printer |

## Expected Results

**Screenshot placeholder:** *Grafana timeline showing 3 correlated spans*

**Screenshot placeholder:** *Events list showing all 18 workflow milestones*

## Requirements

### Infrastructure

- **Oracle Database:** Enterprise Edition 12c+ (tested with 19c+)
  - *Note: Due to resource requirements, Oracle EE should run on a separate machine or robust container environment*
- **Observability Stack:** Can run on local containers
  - Grafana (dashboards and visualization)
  - Tempo (distributed tracing backend)
  - OTLP Collector (telemetry ingestion)
  - Prometheus (metrics storage) - optional

### Oracle Database Setup

- Oracle Database with PLTelemetry core packages installed
- Required privileges: `UTL_HTTP`, `DBMS_CRYPTO`, `CREATE TABLE`, `CREATE PROCEDURE`
- Network access to observability stack (HTTP outbound)

### Important Note

**This is a simulation:** The example uses `FORM_KEY_COMMIT` as a stored procedure to simulate Oracle Forms behavior. In a real environment, this would be a Forms trigger (`WHEN-BUTTON-PRESSED`, `KEY-COMMIT`, etc.) calling the PL/SQL APIs. The distributed tracing behavior and timeline results are identical.

## Installation

### 1. Install PLTelemetry Core

Ensure PLTelemetry core is already installed in your Oracle database:

```sql
-- Verify installation
SELECT COUNT(*) FROM user_objects WHERE object_name = 'PLTELEMETRY';
SELECT COUNT(*) FROM user_tables WHERE table_name LIKE 'PLT_%';
```

### 2. Install OTLP Bridge

```sql
-- Install OTLP bridge package
@bridges/OTLP/PLT_OTLP_BRIDGE.pks
@bridges/OTLP/PLT_OTLP_BRIDGE.pkb
```

### 3. Install Example Components

```sql
-- Install the example packages and procedure
@examples/invoice-creation/install.sql
```

This creates:
- `API_PRICING` package (pricing calculation with distributed tracing)
- `API_INVOICE` package (invoice creation with distributed tracing)  
- `FORM_KEY_COMMIT` procedure (main workflow simulation)

## Configuration

### 1. Configure PLTelemetry Backend

```sql
BEGIN
    -- Set OTLP bridge as backend
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    
    -- Configure your observability stack endpoint
    PLT_OTLP_BRIDGE.set_otlp_collector('http://your-tempo-host:4318');
    
    -- Set service identification
    PLT_OTLP_BRIDGE.set_service_info('oracle-forms-erp', '2.1.0', 'production');
    
    -- Performance settings
    PLTelemetry.set_async_mode(FALSE);  -- TRUE for background processing
    PLT_OTLP_BRIDGE.set_native_json_mode(TRUE);  -- Oracle 12c+ recommended
    
    -- Optional: Enable debug for troubleshooting
    PLT_OTLP_BRIDGE.set_debug_mode(FALSE);
END;
/
```

### 2. Network Configuration

Ensure Oracle can reach your observability stack:

```sql
-- Test connectivity (optional)
SELECT UTL_HTTP.REQUEST('http://your-tempo-host:4318/v1/traces', 'GET') FROM DUAL;
```

## Running the Example

### Execute the Workflow

```sql
-- Run the complete invoice creation workflow
EXEC FORM_KEY_COMMIT;
```

### Expected Console Output

```
=== Invoice Creation Workflow Started ===
Trace ID: f9bc086f1facf6be34d006420205030c
Customer ID: 1234
Items: 5
→ Loading configuration...
✓ Configuration loaded (300ms)
→ Calling pricing engine...
✓ Repricing completed - Amount: €564.75
→ Performing validations...
✓ Validations completed (1500ms)
→ Creating invoice...
✓ Invoice created - Number: INV-2025-262196
→ Generating PDF with Oracle Reports...
✓ PDF generated - Size: 317KB (4300ms)
→ Sending to printer...
✓ Sent to printer: HP_LaserJet_Finance_Floor2 (4300ms)
=== Invoice Creation Workflow Completed ===
Invoice: INV-2025-262196
Total time: 14 seconds
Trace ID: f9bc086f1facf6be34d006420205030c
Status: SUCCESS
```

### View in Grafana

1. Open Grafana → Explore → Select Tempo datasource
2. Paste the trace ID from console output
3. Click "Run Query"

**Screenshot placeholder:** *Grafana query interface with trace ID*

## What You'll See

### Timeline View

**Screenshot placeholder:** *Complete timeline showing 3 spans over 14.3 seconds*

- **oracle-forms-erp: forms_invoice_processing** (14.3s) - Main workflow
- **pricing_calculation** (1.2s) - Pricing API span
- **invoice_creation** (2.3s) - Invoice API span

### Events Detail

**Screenshot placeholder:** *Events panel showing all workflow milestones*

The main span contains 18 events tracking every step:
- `invoice_workflow_started`
- `loading_form_configuration`
- `configuration_loaded`
- `calling_repricing_api`
- `repricing_completed_successfully`
- `performing_business_validations`
- `validating_customer_credit_limit`
- `validating_inventory_availability`
- `validating_pricing_rules`
- `validating_tax_compliance`
- `all_validations_passed`
- `calling_invoice_creation_api`
- `invoice_created_successfully`
- `generating_pdf_with_oracle_reports`
- `pdf_generation_completed`
- `sending_to_printer`
- `document_sent_to_printer`
- `invoice_workflow_completed`

### Attributes and Context

**Screenshot placeholder:** *Span attributes showing business context*

Each span includes rich business context:
- Customer ID, invoice number, amounts
- Processing times, document sizes
- System components, tenant information
- Error details (when applicable)

## Business Metrics

The example automatically collects relevant business metrics:

- **Financial:** `pricing.base_amount`, `invoice.vat_amount`, `invoice.total_value`
- **Performance:** `pricing.calculation_time_ms`, `workflow.total_time_ms`
- **Operational:** `reports.pdf_size_kb`, `invoices.created`, `validations.performed`

**Screenshot placeholder:** *Metrics in Grafana/Prometheus showing business KPIs*

## Troubleshooting

### No Traces Appearing

1. **Check configuration:**
```sql
SELECT PLTelemetry.get_backend_url() FROM DUAL;
SELECT PLT_OTLP_BRIDGE.get_native_json_mode() FROM DUAL;
```

2. **Enable debug mode:**
```sql
BEGIN
    PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
END;
/
EXEC FORM_KEY_COMMIT;
```

3. **Check for errors:**
```sql
SELECT error_time, error_message, module_name 
FROM plt_telemetry_errors 
WHERE error_time > SYSDATE - 1/24
ORDER BY error_time DESC;
```

### Connectivity Issues

```sql
-- Test Tempo connectivity
SELECT UTL_HTTP.REQUEST('http://your-tempo-host:4318', 'GET') FROM DUAL;

-- Check ACL configuration (Oracle 11g+)
SELECT acl, principal, privilege, is_grant 
FROM dba_network_acl_privileges 
WHERE principal = USER;
```

### Performance Issues

```sql
-- Switch to async mode for better performance
BEGIN
    PLTelemetry.set_async_mode(TRUE);
END;
/

-- Check queue status
SELECT COUNT(*) as pending_items FROM plt_queue WHERE processed = 'N';

-- Process queue manually if needed
EXEC PLTelemetry.process_queue(100);
```

## Real-World Usage

### Oracle Forms Integration

In a real Oracle Forms application, replace the `FORM_KEY_COMMIT` procedure with appropriate triggers:

```plsql
-- In WHEN-BUTTON-PRESSED trigger
DECLARE
    l_trace_id VARCHAR2(32);
BEGIN
    -- Configure PLTelemetry (once per session)
    configure_pltelemetry();
    
    -- Start distributed trace
    l_trace_id := PLTelemetry.start_trace('invoice_creation_workflow');
    
    -- Call your business APIs with trace context
    l_result := API_PRICING.calculate_prices(
        p_customer_id => :CUSTOMER.ID,
        p_item_count => :INVOICE.ITEM_COUNT,
        p_trace_id => l_trace_id
    );
    
    -- Continue workflow...
END;
```

### Multi-Environment Setup

```sql
-- Environment-specific configuration
DECLARE
    l_env VARCHAR2(10) := SYS_CONTEXT('USERENV', 'DB_NAME');
BEGIN
    IF l_env LIKE '%PROD%' THEN
        PLT_OTLP_BRIDGE.set_otlp_collector('http://prod-tempo:4318');
        PLTelemetry.set_async_mode(TRUE);
    ELSE
        PLT_OTLP_BRIDGE.set_otlp_collector('http://dev-tempo:4318');
        PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
    END IF;
END;
/
```

## Next Steps

- **Example 2:** Error handling and resilience scenarios
- **Example 3:** Multi-tenant and batch processing
- **Production deployment:** Performance tuning and monitoring

## Technical Notes

- **Oracle Version:** Requires 12c+ for optimal JSON parsing (native mode)
- **Performance Impact:** < 1ms per telemetry operation in async mode
- **Network Requirements:** HTTP access to observability stack
- **Resource Usage:** Minimal - PLTelemetry is designed for production use

## Why This Matters

PLTelemetry enables Oracle-based systems—often seen as legacy black boxes—to speak the language of modern observability. This is not about replacing Oracle Forms, Reports, or PL/SQL APIs, but making them observable, auditable, and transparent in real-time.

**Before PLTelemetry:**
- Oracle workflows are invisible to modern monitoring
- Debugging requires log diving across multiple systems
- Performance bottlenecks are hard to identify
- Business processes lack end-to-end visibility

**With PLTelemetry:**
- Complete timeline visibility across your Oracle stack
- Correlation with modern microservices and APIs
- Business metrics alongside technical metrics
- Debugging with distributed tracing standards

This example demonstrates how a 20+ year old Oracle Forms application can provide the same observability as a modern React + Node.js app—without changing the business logic.

---

**Note:** This example simulates Oracle Forms behavior using PL/SQL procedures. In actual Oracle Forms environments, the same distributed tracing patterns apply with identical results.