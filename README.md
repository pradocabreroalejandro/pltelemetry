<p align="center">
  <img src="assets/PLT_logo.jpg" alt="PLTelemetry logo" width="200"/>
</p>

# PLTelemetry

> **OpenTelemetry-style observability for Oracle PL/SQL**

PLTelemetry brings distributed tracing, metrics, and structured logging to Oracle PL/SQL applications. It's designed to fill the observability gap where traditional OpenTelemetry agents can't reach - inside your database stored procedures.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Oracle](https://img.shields.io/badge/Oracle-11g%2B-red.svg)
![Status](https://img.shields.io/badge/status-production%20ready-green.svg)

## What It Does

PLTelemetry is a PL/SQL package that captures telemetry data from your Oracle database operations and sends it to modern observability platforms. Think of it as adding `console.log()` and distributed tracing to your stored procedures.

**Simple example:**
```sql
-- Add observability to your existing PL/SQL
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
BEGIN
    l_trace_id := PLTelemetry.start_trace('process_order');
    l_span_id := PLTelemetry.start_span('validate_customer');
    
    -- Your existing business logic
    validate_customer_data(p_customer_id);
    
    PLTelemetry.end_span(l_span_id, 'OK');
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

## Architecture

```
Oracle PL/SQL → PLTelemetry → Bridge → Observability Platform
                    ↓            ↓           ↓
               Generic JSON  Transform   Grafana/Jaeger/Tempo
                                        Prometheus/Loki
```

PLTelemetry generates OpenTelemetry-compatible JSON and uses "bridges" to transform and send data to different backends.

## Available Bridges

| Bridge | Status | Best For | Documentation |
|--------|--------|----------|---------------|
| **OTLP** | ✅ Production | Modern observability stacks (Grafana, Tempo, Jaeger) | [README](bridges/OTLP/README.md) |
| **PostgreSQL** | ✅ Production | Custom dashboards, SQL analysis | [README](bridges/postgresql/README.md) |

## Quick Start with OTLP (Recommended)

The OTLP bridge connects PLTelemetry to any OpenTelemetry collector, giving you access to the entire observability ecosystem.

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
    
    -- MANDATORY: Set your OpenTelemetry collector endpoint
    PLT_OTLP_BRIDGE.set_otlp_collector('http://your-collector:4318');
    
    -- RECOMMENDED: Identify your service
    PLT_OTLP_BRIDGE.set_service_info('your-oracle-app', '1.0.0');
END;
/
```

### 4. Start Observing

```sql
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    -- Create a distributed trace
    l_trace_id := PLTelemetry.start_trace('user_registration');
    l_span_id := PLTelemetry.start_span('validate_email');
    
    -- Add context
    l_attrs(1) := PLTelemetry.add_attribute('user.email', 'user@example.com');
    
    -- Add timeline events
    PLTelemetry.add_event(l_span_id, 'validation_started');
    
    -- Your business logic here
    IF validate_email_format(p_email) THEN
        PLTelemetry.add_event(l_span_id, 'email_valid');
        PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    ELSE
        l_attrs(2) := PLTelemetry.add_attribute('error.reason', 'invalid_format');
        PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
    END IF;
    
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

## Core Features

### Distributed Tracing
- **Trace Context**: 128-bit trace IDs, 64-bit span IDs
- **Parent-Child Relationships**: Nested operations with proper hierarchy
- **Timeline Events**: Add contextual events within spans
- **Status Propagation**: OK, ERROR, CANCELLED with proper mapping

### Metrics Collection
- **Custom Metrics**: Business and performance metrics with attributes
- **Trace Correlation**: Link metrics to active traces automatically
- **Multiple Units**: Support for ms, bytes, requests, percentages, etc.

### Structured Logging
- **Severity Levels**: TRACE, DEBUG, INFO, WARN, ERROR, FATAL
- **Trace Context**: Automatic correlation with active traces
- **Structured Data**: Key-value attributes with proper JSON escaping

### Production Features
- **Async Processing**: Queue-based export to minimize performance impact
- **Error Isolation**: Telemetry failures never break business logic
- **Memory Efficient**: Automatic VARCHAR2/CLOB switching for large payloads
- **Configurable Timeouts**: Prevent hanging connections

## Common Use Cases

### API Monitoring
```sql
-- Track API response times and errors
DECLARE
    l_span_id VARCHAR2(16);
    l_start_time TIMESTAMP := SYSTIMESTAMP;
BEGIN
    l_span_id := PLTelemetry.start_span('api_get_customer');
    
    -- Your API logic
    get_customer_data(p_customer_id, l_result);
    
    -- Log response time
    PLTelemetry.log_metric(
        'api_response_time_ms',
        EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000,
        'ms'
    );
    
    PLTelemetry.end_span(l_span_id, 'OK');
END;
/
```

### Error Tracking
```sql
-- Capture and trace errors with context
DECLARE
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    l_span_id := PLTelemetry.start_span('process_payment');
    
    BEGIN
        process_credit_card_payment(p_amount, p_card_token);
        PLTelemetry.end_span(l_span_id, 'OK');
    EXCEPTION
        WHEN OTHERS THEN
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SQLERRM);
            l_attrs(2) := PLTelemetry.add_attribute('payment.amount', TO_CHAR(p_amount));
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            RAISE; -- Don't swallow the original error
    END;
END;
/
```

### Batch Job Monitoring
```sql
-- Monitor long-running batch processes
DECLARE
    l_trace_id VARCHAR2(32);
    l_records_processed NUMBER := 0;
BEGIN
    l_trace_id := PLTelemetry.start_trace('daily_customer_sync');
    
    FOR customer IN (SELECT * FROM customers_to_sync) LOOP
        -- Process each customer
        sync_customer_data(customer.customer_id);
        l_records_processed := l_records_processed + 1;
        
        -- Log progress every 100 records
        IF MOD(l_records_processed, 100) = 0 THEN
            PLTelemetry.log_metric('customers_synced', l_records_processed, 'count');
        END IF;
    END LOOP;
    
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

## Integration Examples

### With Grafana Stack
Using the OTLP bridge, PLTelemetry works seamlessly with:
- **Grafana** - Dashboards and alerting
- **Tempo** - Distributed tracing visualization  
- **Prometheus** - Metrics storage and alerting
- **Loki** - Log aggregation and search

### With Jaeger
```yaml
# OpenTelemetry Collector config
exporters:
  jaeger:
    endpoint: jaeger:14250
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [jaeger]
```

### With Custom Backends
Create your own bridge to send data anywhere:
```sql
-- Example: Custom HTTP bridge
PROCEDURE my_custom_bridge(p_json VARCHAR2) IS
BEGIN
    -- Transform PLTelemetry JSON to your format
    -- Send via UTL_HTTP to your backend
END;
```

## Requirements

### Database
- Oracle Database 11g or higher (12c+ recommended for better JSON support)
- Required privileges: `UTL_HTTP`, `DBMS_CRYPTO`, `CREATE TABLE`, `CREATE PROCEDURE`

### Network
- HTTP access to your observability collector/backend
- Proper ACL configuration for outbound connections

### Grants
```sql
-- Run as DBA
GRANT EXECUTE ON UTL_HTTP TO your_user;
GRANT EXECUTE ON DBMS_CRYPTO TO your_user;
GRANT CREATE JOB TO your_user;
```

## Configuration Options

```sql
-- Backend routing
PLTelemetry.set_backend_url('OTLP_BRIDGE');  -- or 'POSTGRES_BRIDGE'

-- Processing mode
PLTelemetry.set_async_mode(TRUE);   -- FALSE for immediate sending
PLTelemetry.set_autocommit(TRUE);   -- Commit after each telemetry operation

-- Performance tuning
PLTelemetry.set_backend_timeout(30);              -- HTTP timeout in seconds
PLT_OTLP_BRIDGE.set_native_json_mode(TRUE);       -- Use Oracle 12c+ JSON functions
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);             -- Enable detailed logging
```

## Performance Impact

PLTelemetry is designed to have minimal impact on your application:

- **Async mode**: Telemetry operations happen in background
- **Memory efficient**: Automatic switching between VARCHAR2 and CLOB
- **Error isolated**: Telemetry failures don't break business logic
- **Configurable**: Adjust timeouts and batch sizes for your environment

**Typical overhead**: < 1ms per telemetry operation in async mode.

## Troubleshooting

### Check Configuration
```sql
-- Verify current settings
SELECT PLTelemetry.get_backend_url() FROM DUAL;
SELECT COUNT(*) FROM plt_queue WHERE processed = 'N';
```

### Check for Errors
```sql
-- Look for telemetry errors
SELECT error_time, error_message, module_name 
FROM plt_telemetry_errors 
WHERE error_time > SYSDATE - 1  -- Last 24 hours
ORDER BY error_time DESC;
```

### Enable Debug Mode
```sql
-- See what's happening under the hood
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
```

## Project Status

**What Works Today:**
- ✅ Core PLTelemetry package (traces, spans, metrics, events, logs)
- ✅ OTLP bridge for modern observability stacks
- ✅ PostgreSQL bridge for custom analysis
- ✅ Async and sync processing modes
- ✅ Comprehensive error handling
- ✅ Production deployments

**What's Planned:**
- 🔄 Additional bridges (Elasticsearch, InfluxDB)
- 🔄 Sampling strategies for high-volume environments
- 🔄 gRPC support for better performance

## Contributing

PLTelemetry is open source and welcomes contributions:

1. **Report Issues** - Found a bug or have a feature request?
2. **Create Bridges** - Add support for new backends
3. **Improve Core** - Enhance the core PLTelemetry package
4. **Write Examples** - Help others learn with real-world examples

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

- OpenTelemetry community for the observability standards
- Oracle community for PL/SQL best practices
- All contributors who help make database observability better

---

**PLTelemetry** - Because your stored procedures deserve observability too.