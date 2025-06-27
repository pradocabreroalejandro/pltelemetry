<p align="center">
  <img src="assets/PLT_logo.jpg" alt="PLTelemetry logo" width="200"/>
</p>

# PLTelemetry

> **OpenTelemetry-style observability for Oracle PL/SQL**

PLTelemetry brings distributed tracing, metrics, and structured logging to Oracle PL/SQL applications. It's designed to fill the observability gap where traditional OpenTelemetry agents can't reach - inside your database stored procedures, Oracle Forms, and Reports.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Oracle](https://img.shields.io/badge/Oracle-11g%2B-red.svg)
![Status](https://img.shields.io/badge/status-production%20ready-green.svg)
![Oracle Forms](https://img.shields.io/badge/Oracle%20Forms-supported-orange.svg)
![Distributed Tracing](https://img.shields.io/badge/distributed%20tracing-ready-green.svg)

## What It Does

PLTelemetry is not a replacement for OpenTelemetry - it's a **specialized implementation** that brings modern observability to Oracle PL/SQL environments where standard OTEL doesn't reach. Think of it as adding distributed tracing and structured logging to your stored procedures, Forms, and Reports.

**Distributed tracing across your Oracle stack:**
```sql
-- Oracle Forms starts a trace
l_trace_id := PLTelemetry.start_trace('customer_order_process');

-- Continues in PL/SQL API
l_span_id := PLTelemetry.continue_distributed_trace(
    p_trace_id => l_trace_id,
    p_operation => 'validate_customer_data'
);

-- All correlated in your observability platform
PLTelemetry.end_span(l_span_id, 'OK');
```

## Real-World Distributed Tracing

**Complete Oracle ecosystem observability:**

```
Oracle Forms → PL/SQL API → Oracle Reports → Node.js → Oracle Forms
      ↓             ↓              ↓           ↓           ↓
   trace_id ══════════════════ same trace_id ══════════════
              
              All visible in Grafana/Tempo as one unified trace
```

### Example: Order Processing Flow

```sql
-- In Oracle Forms (trigger)
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
BEGIN
    -- Configure PLTelemetry (one-time setup)
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    PLT_OTLP_BRIDGE.set_otlp_collector('http://tempo:4318');
    PLT_OTLP_BRIDGE.set_service_info('oracle-forms-erp', '2.1.0');
    
    -- Start distributed trace
    l_trace_id := PLTelemetry.start_trace('order_processing');
    l_span_id := PLTelemetry.start_span('forms_validation');
    
    -- Add business context
    DECLARE
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_attrs(1) := PLTelemetry.add_attribute('form.name', 'ORDER_ENTRY');
        l_attrs(2) := PLTelemetry.add_attribute('user.id', USER);
        l_attrs(3) := PLTelemetry.add_attribute('customer.id', :ORDER.CUSTOMER_ID);
        PLTelemetry.add_event(l_span_id, 'validation_started', l_attrs);
    END;
    
    -- Your existing Forms logic
    validate_order_data();
    
    PLTelemetry.end_span(l_span_id, 'OK');
    
    -- Call PL/SQL API, passing the trace_id
    l_result := ORDER_API.process_order(
        p_customer_id => :ORDER.CUSTOMER_ID,
        p_trace_id => l_trace_id  -- Distributed tracing magic
    );
    
    PLTelemetry.end_trace(l_trace_id);
END;
```

```sql
-- In PL/SQL API (database package)
FUNCTION process_order(
    p_customer_id NUMBER,
    p_trace_id VARCHAR2
) RETURN VARCHAR2
IS
    l_span_id VARCHAR2(16);
BEGIN
    -- Continue the distributed trace from Forms
    l_span_id := PLTelemetry.continue_distributed_trace(
        p_trace_id => p_trace_id,
        p_operation => 'database_order_processing'
    );
    
    -- Add database-specific context
    PLTelemetry.log_distributed(
        p_trace_id => p_trace_id,
        p_level => 'INFO',
        p_message => 'Processing order in database',
        p_system => 'ORACLE_DB'
    );
    
    -- Your business logic with observability
    PLTelemetry.add_event(l_span_id, 'inventory_check_start');
    
    IF check_inventory(p_customer_id) THEN
        PLTelemetry.add_event(l_span_id, 'inventory_available');
        -- Process order...
        PLTelemetry.log_metric('orders.processed', 1, 'count');
        PLTelemetry.end_span(l_span_id, 'OK');
        RETURN 'SUCCESS';
    ELSE
        PLTelemetry.add_event(l_span_id, 'inventory_insufficient');
        PLTelemetry.end_span(l_span_id, 'ERROR');
        RETURN 'INSUFFICIENT_INVENTORY';
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        PLTelemetry.log_distributed(
            p_trace_id => p_trace_id,
            p_level => 'ERROR',
            p_message => 'Order processing failed: ' || SQLERRM,
            p_system => 'ORACLE_DB'
        );
        PLTelemetry.end_span(l_span_id, 'ERROR');
        RETURN 'ERROR: ' || SQLERRM;
END process_order;
```

**Result**: A complete timeline showing the entire journey from Forms button click to database completion, all correlated by trace_id and visible in Grafana/Tempo.

## Architecture

```
Oracle Forms ━━━━━━━━━━━┓
                      ┃
Oracle Reports ━━━━━━━┫ PLTelemetry ━━━ OTLP Bridge ━━━ Tempo/Grafana
                      ┃      ↓              ↓             ↓
PL/SQL APIs ━━━━━━━━━━┛  Generic JSON    Transform   Distributed Tracing
                                                    Metrics & Logs
                         ↓
              PostgreSQL Bridge ━━━ PostgreSQL ━━━ Custom Dashboards
```

PLTelemetry generates OpenTelemetry-compatible JSON and uses "bridges" to send data to different observability platforms.

## Available Bridges

| Bridge | Status | Best For | Production Use |
|--------|--------|----------|---------------|
| **OTLP** | ✅ Production | Grafana, Tempo, Jaeger, Prometheus | ✅ Tested in enterprise |
| **PostgreSQL** | ✅ Production | Custom analysis, SQL dashboards | ✅ Tested in enterprise |

## Quick Start with Grafana Stack (Recommended)

The OTLP bridge connects PLTelemetry to Tempo, giving you distributed tracing visualization that works with your existing Grafana setup.

### 1. Install PLTelemetry Core

```sql
-- Install the core package
@src/PLTelemetry.pks
@src/PLTelemetry.pkb

-- Install database tables
@install/tables/plt_tables.sql
@install/tables/plt_indexes.sql
```

### 2. Install OTLP Bridge

```sql
-- Install the OTLP bridge
@bridges/OTLP/PLT_OTLP_BRIDGE.pks
@bridges/OTLP/PLT_OTLP_BRIDGE.pkb
```

### 3. Configure (Required)

```sql
BEGIN
    -- MANDATORY: Tell PLTelemetry to use the OTLP bridge
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    
    -- MANDATORY: Set your Tempo endpoint
    PLT_OTLP_BRIDGE.set_otlp_collector('http://tempo:4318');
    
    -- RECOMMENDED: Identify your service
    PLT_OTLP_BRIDGE.set_service_info('your-oracle-app', '1.0.0');
    
    -- OPTIONAL: Performance tuning
    PLTelemetry.set_async_mode(FALSE);  -- TRUE for background processing
    PLT_OTLP_BRIDGE.set_debug_mode(FALSE);  -- TRUE for troubleshooting
END;
/
```

### 4. Start Observing

**Simple single-system tracing:**
```sql
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
BEGIN
    -- Create a trace
    l_trace_id := PLTelemetry.start_trace('user_registration');
    l_span_id := PLTelemetry.start_span('validate_email');
    
    -- Add events and context
    PLTelemetry.add_event(l_span_id, 'validation_started');
    
    -- Your business logic
    validate_email_format(p_email);
    
    PLTelemetry.add_event(l_span_id, 'validation_completed');
    PLTelemetry.end_span(l_span_id, 'OK');
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

**Distributed tracing across systems:**
```sql
-- System A (Oracle Forms) starts trace
l_trace_id := PLTelemetry.start_trace('cross_system_operation');

-- System B (PL/SQL) continues trace
l_span_id := PLTelemetry.continue_distributed_trace(
    p_trace_id => l_trace_id,
    p_operation => 'database_processing'
);

-- System C (Reports) continues same trace
-- All operations appear in the same timeline in Grafana
```

## Core Features

### Distributed Tracing
- **128-bit Trace IDs**: OpenTelemetry-compatible trace correlation
- **Cross-System Tracing**: Pass trace context between Forms, PL/SQL, Reports, and external APIs
- **Timeline Events**: Add contextual events within spans for detailed observability
- **Parent-Child Relationships**: Nested operations with proper hierarchy
- **Status Propagation**: OK, ERROR, CANCELLED with proper OTLP mapping

### Enhanced for Oracle Ecosystem
- **Oracle Forms Integration**: Full support for Forms-based applications
- **Oracle Reports Support**: Trace report generation and processing
- **Database API Tracing**: Instrument your PL/SQL packages and procedures
- **Multi-Tenant Support**: Trace and correlate data across different tenants
- **Error Correlation**: Automatic linking of errors to traces for faster debugging

### Metrics Collection
- **Business Metrics**: Track orders processed, customers served, revenue, etc.
- **Performance Metrics**: Response times, database query durations, batch processing rates
- **Trace-Correlated Metrics**: Automatically link metrics to active traces
- **Multiple Units**: Support for ms, bytes, requests, percentages, currency

### Structured Logging
- **Severity Levels**: TRACE, DEBUG, INFO, WARN, ERROR, FATAL
- **Distributed Logging**: Logs automatically correlated to traces across systems
- **Contextual Data**: Key-value attributes with proper JSON escaping
- **System Identification**: Automatic tagging of log source (Forms, PL/SQL, Reports)

### Production-Ready Features
- **Async Processing**: Queue-based export to minimize performance impact
- **Error Isolation**: Telemetry failures never break business logic
- **Memory Efficient**: Automatic VARCHAR2/CLOB switching for large payloads
- **Configurable Timeouts**: Prevent hanging connections
- **Bridge Architecture**: Easy to add new observability backends

## Real-World Use Cases

### Oracle Forms Application Monitoring
```sql
-- In WHEN-BUTTON-PRESSED trigger
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
BEGIN
    -- Configure telemetry (one-time setup)
    configure_telemetry();
    
    -- Start tracing the user workflow
    l_trace_id := PLTelemetry.start_trace('customer_lookup');
    l_span_id := PLTelemetry.start_span('form_validation');
    
    -- Add user context
    DECLARE
        l_attrs PLTelemetry.t_attributes;
    BEGIN
        l_attrs(1) := PLTelemetry.add_attribute('form.name', 'CUSTOMER_SEARCH');
        l_attrs(2) := PLTelemetry.add_attribute('user.id', USER);
        l_attrs(3) := PLTelemetry.add_attribute('search.criteria', :SEARCH.CUSTOMER_NAME);
        PLTelemetry.add_event(l_span_id, 'search_initiated', l_attrs);
    END;
    
    -- Call database API with trace context
    l_result := CUSTOMER_API.search_customers(
        p_name => :SEARCH.CUSTOMER_NAME,
        p_trace_id => l_trace_id
    );
    
    -- Measure and log results
    IF l_result = 'SUCCESS' THEN
        PLTelemetry.add_event(l_span_id, 'search_completed');
        PLTelemetry.log_metric('customer_searches.success', 1, 'count');
        PLTelemetry.end_span(l_span_id, 'OK');
    ELSE
        PLTelemetry.add_event(l_span_id, 'search_failed');
        PLTelemetry.end_span(l_span_id, 'ERROR');
    END IF;
    
    PLTelemetry.end_trace(l_trace_id);
END;
```

### End-to-End Transaction Monitoring
```sql
-- Track complete business transactions across multiple systems
-- Forms → PL/SQL → External API → Reports → Forms

-- 1. Forms initiates
l_trace_id := PLTelemetry.start_trace('order_fulfillment');

-- 2. PL/SQL processes
FUNCTION process_order(p_trace_id VARCHAR2) RETURN VARCHAR2 IS
    l_span_id VARCHAR2(16);
BEGIN
    l_span_id := PLTelemetry.continue_distributed_trace(
        p_trace_id => p_trace_id,
        p_operation => 'inventory_allocation'
    );
    
    -- Call external inventory system
    l_context := PLTelemetry.get_trace_context();
    call_external_api(
        p_endpoint => 'http://inventory-api/allocate',
        p_trace_context => l_context
    );
    
    PLTelemetry.end_span(l_span_id, 'OK');
    RETURN 'SUCCESS';
END;

-- 3. Reports generates invoice (with same trace_id)
-- 4. All steps visible as one timeline in Grafana
```

### Performance Analysis
```sql
-- Identify slow operations across your Oracle stack
DECLARE
    l_span_id VARCHAR2(16);
    l_start_time TIMESTAMP := SYSTIMESTAMP;
BEGIN
    l_span_id := PLTelemetry.start_span('complex_calculation');
    
    -- Your existing slow operation
    perform_complex_business_logic();
    
    -- Measure actual duration
    PLTelemetry.log_metric(
        'calculation_duration_ms',
        EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000,
        'ms'
    );
    
    PLTelemetry.end_span(l_span_id, 'OK');
END;
/
```

### Error Tracking and Correlation
```sql
-- Capture errors with full context across distributed systems
DECLARE
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    l_span_id := PLTelemetry.start_span('payment_processing');
    
    BEGIN
        process_payment(p_amount, p_card_token);
        PLTelemetry.end_span(l_span_id, 'OK');
    EXCEPTION
        WHEN OTHERS THEN
            -- Capture error with full context
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SQLERRM);
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            l_attrs(3) := PLTelemetry.add_attribute('payment.amount', TO_CHAR(p_amount));
            l_attrs(4) := PLTelemetry.add_attribute('customer.id', TO_CHAR(p_customer_id));
            
            PLTelemetry.log_distributed(
                p_trace_id => PLTelemetry.get_current_trace_id(),
                p_level => 'ERROR',
                p_message => 'Payment processing failed: ' || SQLERRM,
                p_system => 'PAYMENT_ENGINE'
            );
            
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            RAISE; -- Don't swallow the original error
    END;
END;
/
```

## Integration with Modern Observability

### Grafana + Tempo Setup
```yaml
# docker-compose.yml for local development
version: '3.8'
services:
  tempo:
    image: grafana/tempo:latest
    command: [ "-config.file=/etc/tempo.yaml" ]
    ports:
      - "3200:3200"   # Tempo API
      - "4317:4317"   # OTLP gRPC receiver
      - "4318:4318"   # OTLP HTTP receiver (PLTelemetry uses this)
    volumes:
      - ./tempo.yaml:/etc/tempo.yaml

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - grafana-storage:/var/lib/grafana

volumes:
  grafana-storage:
```

### Searching Your Traces
Once configured, you can search your Oracle application traces in Grafana:

```bash
# Search by service
{.service.name="oracle-forms-erp"}

# Search by operation
{.name="order_processing"}

# Search by customer
{.customer.id="12345"}

# Search by error status
{.status="ERROR"}

# Search by trace ID directly
d60b2ad673a213990ebfb38c4273b172
```

### Creating Dashboards
Use the PostgreSQL bridge for custom dashboards:
```sql
-- Query your telemetry data directly
SELECT 
    trace_id,
    operation_name,
    duration_ms,
    status,
    start_time
FROM plt_spans 
WHERE start_time > CURRENT_DATE - 1
  AND status = 'ERROR'
ORDER BY duration_ms DESC;
```

## Configuration Options

### Basic Configuration
```sql
-- Backend routing
PLTelemetry.set_backend_url('OTLP_BRIDGE');

-- Processing mode
PLTelemetry.set_async_mode(TRUE);   -- FALSE for immediate sending
PLTelemetry.set_autocommit(FALSE);  -- TRUE to commit after each operation

-- OTLP Bridge settings
PLT_OTLP_BRIDGE.set_otlp_collector('http://tempo:4318');
PLT_OTLP_BRIDGE.set_service_info('your-app', '1.0.0', 'prod');
PLT_OTLP_BRIDGE.set_timeout(30);
```

### Advanced Configuration
```sql
-- Performance tuning
PLT_OTLP_BRIDGE.set_native_json_mode(TRUE);  -- Use Oracle 12c+ JSON functions

-- Debugging
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);        -- Enable detailed logging

-- Multi-tenant setup
PLT_OTLP_BRIDGE.set_service_info(
    p_service_name => 'erp-system',
    p_service_version => '2.1.0',
    p_tenant_id => 'customer_abc'
);
```

## Performance Impact

PLTelemetry is designed for production use with minimal overhead:

- **Async Mode**: < 1ms per telemetry operation (queued for background processing)
- **Sync Mode**: 10-50ms per operation (immediate sending)
- **Memory Efficient**: Automatic VARCHAR2/CLOB switching based on payload size
- **Error Isolated**: Telemetry failures never affect business logic
- **Network Optimized**: HTTP/1.1 with keep-alive and configurable timeouts

### Recommended Settings
```sql
-- For high-volume production systems
PLTelemetry.set_async_mode(TRUE);
PLTelemetry.set_autocommit(FALSE);
PLT_OTLP_BRIDGE.set_native_json_mode(TRUE);

-- For development/debugging
PLTelemetry.set_async_mode(FALSE);
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
```

## Troubleshooting

### Quick Health Check
```sql
-- Verify configuration
SELECT PLTelemetry.get_backend_url() FROM DUAL;
SELECT PLTelemetry.get_current_trace_id() FROM DUAL;

-- Check queue status (if using async mode)
SELECT COUNT(*) as pending_exports FROM plt_queue WHERE processed = 'N';

-- Check for recent errors
SELECT error_time, error_message, module_name 
FROM plt_telemetry_errors 
WHERE error_time > SYSDATE - 1/24  -- Last hour
ORDER BY error_time DESC;
```

### Common Issues

#### Traces not appearing in Grafana
1. **Check network connectivity**: Can Oracle reach your Tempo endpoint?
2. **Verify timestamps**: Oracle and Grafana should have synchronized time
3. **Check Tempo configuration**: Is the OTLP receiver enabled on port 4318?

```sql
-- Debug what's being sent
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);

-- Manual test
BEGIN
    PLT_OTLP_BRIDGE.route_to_otlp('{"trace_id":"test123","span_id":"span123","operation_name":"test","status":"OK"}');
END;
/
```

#### Performance issues
```sql
-- Check queue backlog
SELECT process_attempts, COUNT(*) 
FROM plt_queue 
WHERE processed = 'N' 
GROUP BY process_attempts;

-- Process queue manually if needed
PLTelemetry.process_queue(100);
```

#### Oracle Forms integration
```plsql
-- Common mistake: forgetting to configure before first use
PROCEDURE configure_telemetry IS
BEGIN
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    PLT_OTLP_BRIDGE.set_otlp_collector('http://tempo:4318');
    PLT_OTLP_BRIDGE.set_service_info('oracle-forms', '1.0.0');
END;

-- Call this in WHEN-NEW-FORM-INSTANCE or similar
```

## Requirements

### Database
- Oracle Database 11g or higher (12c+ recommended for better JSON support)
- Required privileges: `UTL_HTTP`, `DBMS_CRYPTO`, `CREATE TABLE`, `CREATE PROCEDURE`

### Network
- HTTP access to your observability collector (Tempo, Jaeger, etc.)
- Proper ACL configuration for outbound connections

### Oracle Forms
- Oracle Forms 6i or higher
- Network access from Forms client/server to database

### Grants
```sql
-- Run as DBA
GRANT EXECUTE ON UTL_HTTP TO your_plsql_user;
GRANT EXECUTE ON DBMS_CRYPTO TO your_plsql_user;
GRANT CREATE JOB TO your_plsql_user;

-- ACL for outbound HTTP (Oracle 11g+)
BEGIN
  DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(
    acl         => 'pltelemetry_acl.xml',
    description => 'PLTelemetry HTTP access',
    principal   => 'YOUR_PLSQL_USER',
    is_grant    => TRUE,
    privilege   => 'connect',
    start_date  => NULL,
    end_date    => NULL
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl  => 'pltelemetry_acl.xml',
    host => 'your-tempo-host',
    lower_port => 4318,
    upper_port => 4318
  );
  
  COMMIT;
END;
/
```

## Production Deployments

### Multi-Environment Setup
```sql
-- Environment-specific configuration
DECLARE
    l_environment VARCHAR2(10) := SYS_CONTEXT('USERENV', 'DB_NAME');
BEGIN
    IF l_environment LIKE '%PROD%' THEN
        PLT_OTLP_BRIDGE.set_otlp_collector('http://prod-tempo:4318');
        PLT_OTLP_BRIDGE.set_service_info('erp-prod', '2.1.0');
        PLTelemetry.set_async_mode(TRUE);
    ELSIF l_environment LIKE '%TEST%' THEN
        PLT_OTLP_BRIDGE.set_otlp_collector('http://test-tempo:4318');
        PLT_OTLP_BRIDGE.set_service_info('erp-test', '2.1.0');
        PLTelemetry.set_async_mode(FALSE);
        PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
    END IF;
END;
/
```

### Queue Management Job
```sql
-- Scheduled job to process async queue
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'PLT_QUEUE_PROCESSOR',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN PLTelemetry.process_queue(500); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=1',
    enabled         => TRUE,
    comments        => 'Process PLTelemetry async queue'
  );
END;
/
```

## Project Status

**Production Ready:**
- ✅ Core PLTelemetry package with distributed tracing
- ✅ OTLP bridge for Grafana/Tempo/Jaeger integration
- ✅ PostgreSQL bridge for custom analytics
- ✅ Oracle Forms integration and distributed tracing
- ✅ Async and sync processing modes
- ✅ Comprehensive error handling and isolation
- ✅ Multi-tenant support
- ✅ Production deployments in enterprise environments

**Roadmap:**
- 🔄 Elasticsearch bridge for log analytics
- 🔄 InfluxDB bridge for metrics storage
- 🔄 Sampling strategies for high-volume environments
- 🔄 gRPC support for better performance
- 🔄 Oracle APEX integration

## Contributing

PLTelemetry is open source and welcomes contributions:

1. **Report Issues** - Found a bug or have a feature request?
2. **Create Bridges** - Add support for new observability backends
3. **Improve Core** - Enhance the core PLTelemetry package
4. **Write Examples** - Help others with real-world integration examples
5. **Documentation** - Improve setup guides and troubleshooting

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## Success Stories

> "PLTelemetry helped us identify a 10-second bottleneck in our Oracle Forms order processing that was hidden across 3 different systems. We reduced order processing time by 80%." - *Enterprise ERP Team*

> "Distributed tracing across Forms → PL/SQL → Reports finally gave us end-to-end visibility into our customer onboarding process." - *Financial Services Company*

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

- OpenTelemetry community for the observability standards
- Oracle community for PL/SQL best practices and Forms integration guidance
- Grafana Labs for Tempo and excellent observability tools
- All contributors who help make Oracle database observability better

---

**PLTelemetry** - Because your Oracle ecosystem deserves modern observability.

*Distributed tracing • Metrics • Structured logging • Oracle Forms • PL/SQL • Reports*