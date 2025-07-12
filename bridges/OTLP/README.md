# PLT_OTLP_BRIDGE

> **OpenTelemetry Protocol Bridge for Oracle PL/SQL**

A production-ready Oracle PL/SQL package that seamlessly connects [PLTelemetry](https://github.com/your-username/PLTelemetry) with any OpenTelemetry collector, enabling distributed tracing, metrics, and logging from Oracle databases to modern observability platforms with full multi-tenant support.

## 🎯 What It Does

PLT_OTLP_BRIDGE converts PLTelemetry's JSON telemetry data into full OTLP (OpenTelemetry Protocol) format and sends it to any OpenTelemetry collector. This enables Oracle databases to participate in enterprise distributed tracing ecosystems with complete multi-tenant support.

**Data Flow:**
```
Oracle PL/SQL → PLTelemetry → PLT_OTLP_BRIDGE → OTLP Collector → Grafana/Tempo/Jaeger
```

## ✨ Enterprise Features

### Multi-Tenant Architecture
- **Automatic tenant.id injection** in all telemetry data (traces, metrics, logs)
- **Tenant context propagation** across distributed systems
- **Grafana dashboard filtering** by tenant for enterprise isolation
- **Resource-level tenant attribution** following OTLP standards

### Production-Ready Design
- **Oracle 12c+ native JSON** objects only (JSON_OBJECT_T, JSON_ARRAY_T)
- **Never breaks business logic** - comprehensive error isolation
- **HTTP/1.1 with chunked transfer** for large payloads
- **Configurable timeouts** prevent hanging connections
- **Autonomous transaction error logging** for debugging

### Full OTLP Compliance
- **resourceSpans structure** with proper resource attributes
- **scopeSpans** with PLTelemetry identification
- **Proper OTLP status codes** (OK=1, ERROR=2, UNSET=0)
- **Unix nanosecond timestamps** for precise timing
- **Severity number mapping** for logs (TRACE=1, INFO=9, ERROR=17, etc.)

## 🚀 Quick Start

### Prerequisites
- Oracle Database 12c+ (native JSON support required)
- PLTelemetry core package installed
- UTL_HTTP privileges
- Network access to OpenTelemetry collector

### Installation

1. **Install the package:**
```sql
-- Install package specification
@PLT_OTLP_BRIDGE.pks

-- Install package body  
@PLT_OTLP_BRIDGE.pkb
```

2. **MANDATORY: Configure PLTelemetry routing:**
```sql
-- CRITICAL: Tell PLTelemetry to use the OTLP bridge
PLTelemetry.set_backend_url('OTLP_BRIDGE');
```

3. **MANDATORY: Set collector endpoint:**
```sql
-- CRITICAL: Configure your OpenTelemetry collector
PLT_OTLP_BRIDGE.set_otlp_collector('http://your-collector:4318');
```

4. **RECOMMENDED: Basic configuration:**
```sql
-- Sync mode for testing
PLTelemetry.set_async_mode(FALSE);

-- Debug output during setup
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);

-- Service identification
PLT_OTLP_BRIDGE.set_service_info('my-oracle-app', '1.0.0');
```

### ⚠️ Critical Configuration

**Without proper configuration, telemetry data will NOT reach your collector:**

**REQUIRED STEPS:**
- ✅ `PLTelemetry.set_backend_url('OTLP_BRIDGE')` - Routes data to bridge
- ✅ `PLT_OTLP_BRIDGE.set_otlp_collector(url)` - Sets collector endpoint

**MISSING EITHER = NO DATA IN GRAFANA**

**Data flow verification:**
```
✅ WITH CONFIG:   PLTelemetry → PLT_OTLP_BRIDGE → OTLP Collector → Grafana
❌ WITHOUT CONFIG: PLTelemetry → Default HTTP → Network Error
```

## 🏢 Multi-Tenant Setup

For enterprise multi-tenant deployments:

```sql
-- Configure tenant context (adds tenant.id to ALL telemetry)
PLT_OTLP_BRIDGE.set_tenant_context('TEST', 'TEST Environment');
```

**Results in:**
- **Traces:** resource.attributes contains `tenant.id="TEST"`
- **Metrics:** dataPoint.attributes contains `tenant.id="TEST"`
- **Logs:** resource.attributes contains `tenant.id="TEST"`

**Grafana queries:**
```logql
# Tenant-specific logs
{service_name="oracle-forms"} | json | resources_tenant_id="TEST"

# Tenant-specific metrics  
pltelemetry_metrics{tenant_id="TEST"}
```

## 📊 Basic Usage Example

### Step 1: Configure Bridge (Once per session)
```sql
BEGIN
    -- MANDATORY configuration
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    PLT_OTLP_BRIDGE.set_otlp_collector('http://tempo:4318');
    
    -- RECOMMENDED configuration
    PLT_OTLP_BRIDGE.set_service_info('oracle-erp', '2.1.0');
    PLT_OTLP_BRIDGE.set_tenant_context('tenant_001', 'Customer Portal');
    PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
    PLTelemetry.set_async_mode(FALSE);
END;
/
```

### Step 2: Use PLTelemetry Normally
```sql
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    -- Start distributed trace
    l_trace_id := PLTelemetry.start_trace('order_processing');
    l_span_id := PLTelemetry.start_span('validate_customer');
    
    -- Add business context
    l_attrs(1) := PLTelemetry.add_attribute('customer.id', '12345');
    l_attrs(2) := PLTelemetry.add_attribute('order.value', '299.99');
    
    -- Add timeline events  
    PLTelemetry.add_event(l_span_id, 'validation_started');
    PLTelemetry.add_event(l_span_id, 'customer_verified');
    
    -- Record business metrics
    PLTelemetry.log_metric('order_value', 299.99, 'currency', l_attrs);
    PLTelemetry.log_metric('validation_time_ms', 45.2, 'ms');
    
    -- Complete trace
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

## 🔗 Distributed Tracing Example

Cross-system tracing between Oracle Forms, PL/SQL APIs, and external services:

```sql
-- Forms starts trace
l_trace_id := PLTelemetry.start_trace('invoice_workflow');

-- PL/SQL API continues same trace  
l_span_id := PLTelemetry.continue_distributed_trace(
    p_trace_id => l_trace_id,
    p_operation => 'calculate_pricing',
    p_tenant_id => 'tenant_001'
);

-- Result: All operations appear in single Grafana timeline
-- Logs automatically correlated by trace_id
-- Metrics tagged with same tenant context
```

## 🔧 Configuration Options

### Collector Configuration
```sql
-- Basic setup (configures all endpoints)
PLT_OTLP_BRIDGE.set_otlp_collector('http://collector:4318');

-- This automatically configures:
-- Traces:  http://collector:4318/v1/traces
-- Metrics: http://collector:4318/v1/metrics  
-- Logs:    http://collector:4318/v1/logs
```

### Service Identification
```sql
PLT_OTLP_BRIDGE.set_service_info(
    p_service_name => 'order-api',
    p_service_version => '2.1.3'
);
```

### Tenant Context (Enterprise)
```sql
PLT_OTLP_BRIDGE.set_tenant_context(
    p_tenant_id => 'customer_portal',
    p_tenant_name => 'Customer Portal Environment'
);
```

### Performance Tuning
```sql
-- HTTP timeout (seconds)
PLT_OTLP_BRIDGE.set_timeout(45);

-- Debug output  
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
```

## 📈 Supported Data Types

### Traces and Spans
- **128-bit trace IDs, 64-bit span IDs** for OpenTelemetry compatibility
- **Parent-child span relationships** for nested operations
- **Span status mapping:** OK, ERROR, UNSET → OTLP codes (1, 2, 0)
- **Timeline events** with nanosecond timestamps
- **Resource attributes** with service and tenant context

### Metrics
- **Gauge metrics** for point-in-time measurements
- **Histogram metrics** for duration measurements  
- **Counter metrics** for accumulating values
- **Metric units** (ms, bytes, currency, count, etc.)
- **Automatic tenant.id injection** as dataPoint attribute
- **Trace correlation** via trace.id attribute

### Logs and Events
- **Structured log records** with OTLP severity numbers
- **Log levels:** TRACE(1), DEBUG(5), INFO(9), WARN(13), ERROR(17), FATAL(21)
- **Automatic trace/span correlation** for debugging
- **Tenant context** in resource attributes
- **Message escaping** for special characters

## 🏗️ OTLP Output Structure

### Traces (resourceSpans)
```json
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "oracle-erp"}},
        {"key": "service.version", "value": {"stringValue": "2.1.0"}},
        {"key": "tenant.id", "value": {"stringValue": "tenant_001"}},
        {"key": "telemetry.sdk.name", "value": {"stringValue": "PLTelemetry"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "PLTelemetry", "version": "2.0.0"},
      "spans": [{
        "traceId": "...",
        "spanId": "...", 
        "name": "order_processing",
        "startTimeUnixNano": "1752322142106000000",
        "endTimeUnixNano": "1752322143260000000",
        "status": {"code": 1},
        "events": [...]
      }]
    }]
  }]
}
```

### Metrics (resourceMetrics)
```json
{
  "resourceMetrics": [{
    "resource": {"attributes": [...]},
    "scopeMetrics": [{
      "scope": {"name": "PLTelemetry"},
      "metrics": [{
        "name": "order_value",
        "unit": "currency",
        "gauge": {
          "dataPoints": [{
            "timeUnixNano": "1752322142106000000",
            "asDouble": 299.99,
            "attributes": [
              {"key": "tenant.id", "value": {"stringValue": "tenant_001"}},
              {"key": "trace.id", "value": {"stringValue": "..."}}
            ]
          }]
        }
      }]
    }]
  }]
}
```

### Logs (resourceLogs)
```json
{
  "resourceLogs": [{
    "resource": {"attributes": [...]},
    "scopeLogs": [{
      "scope": {"name": "PLTelemetry"},
      "logRecords": [{
        "timeUnixNano": "1752322142106000000",
        "severityNumber": 9,
        "severityText": "INFO",
        "body": {"stringValue": "Order processed successfully"},
        "traceId": "...",
        "spanId": "...",
        "attributes": [...]
      }]
    }]
  }]
}
```

## 📊 Grafana Integration

The bridge provides complete integration with Grafana observability stack:

### Tempo (Distributed Tracing)
```
# Search by service
{.service.name="oracle-erp"}

# Search by tenant  
{.tenant.id="tenant_001"}

# Search by operation
{.name="order_processing"}

# Direct trace lookup
abc123def456...
```

### Prometheus (Metrics)
```promql
# Tenant filtering
pltelemetry_metrics{tenant_id="tenant_001"}

# Service filtering  
pltelemetry_metrics{service_name="oracle-erp"}

# Trace correlation
pltelemetry_metrics{trace_id="..."}
```

### Loki (Logs)
```logql
# Tenant logs
{service_name="oracle-erp"} | json | resources_tenant_id="tenant_001"

# Trace correlation
{service_name="oracle-erp"} | json | traceid="..."

# Error logs
{service_name="oracle-erp"} | json | severity="ERROR"
```

## 🐛 Troubleshooting

### Enable Debug Mode
```sql
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
```

**Debug output shows:**
- JSON payload sizes and endpoint targets
- HTTP response codes and timing
- Tenant context injection status
- OTLP structure validation

### Check Error Logs
```sql
SELECT error_time, error_message, module_name 
FROM plt_telemetry_errors 
WHERE module_name = 'PLT_OTLP_BRIDGE'
ORDER BY error_time DESC;
```

### Common Issues

**Connection Refused:**
- Verify collector URL: `curl http://collector:4318/v1/traces`
- Check network connectivity from database server
- Ensure OTLP receiver is enabled in collector config

**No Data in Grafana:**
- Verify `PLTelemetry.set_backend_url('OTLP_BRIDGE')` is configured
- Check `PLT_OTLP_BRIDGE.set_otlp_collector()` is set correctly  
- Enable debug mode and check HTTP response codes
- Verify collector is forwarding to Grafana backends

**Missing Tenant Context:**
- Ensure `PLT_OTLP_BRIDGE.set_tenant_context()` is called
- Check resource attributes in debug output
- Verify Grafana queries use correct tenant field names

## 🔌 Collector Configuration

### OTEL Collector Example
```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
        cors:
          allowed_origins: ["*"]

exporters:
  # Traces to Tempo  
  otlp/tempo:
    endpoint: http://tempo:4317
    tls:
      insecure: true
      
  # Metrics to Prometheus
  prometheus:
    endpoint: "0.0.0.0:8889"
    namespace: "pltelemetry"
    
  # Logs to Loki
  loki:
    endpoint: http://loki:3100/loki/api/v1/push

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlp/tempo]
    metrics:
      receivers: [otlp]
      exporters: [prometheus]
    logs:
      receivers: [otlp] 
      exporters: [loki]
```

## 📋 System Requirements

### Database Requirements
- Oracle Database 12c+ (native JSON support required)
- PLTelemetry core package installed

### Required Privileges
```sql
-- Run as DBA
GRANT EXECUTE ON UTL_HTTP TO your_user;
GRANT EXECUTE ON DBMS_CRYPTO TO your_user;
GRANT CREATE JOB TO your_user;
```

### Network ACL (Oracle 11g+)
```sql
BEGIN
  DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(
    acl => 'otlp_bridge_acl.xml',
    description => 'OTLP Bridge Network Access',
    principal => 'YOUR_USER',
    is_grant => TRUE,
    privilege => 'connect'
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl => 'otlp_bridge_acl.xml',
    host => 'your-collector-host',
    lower_port => 4318,
    upper_port => 4318
  );
END;
/
```

## ⚡ Performance Characteristics

### Throughput
- **Small spans** (<1KB): ~500-1000 per second
- **Large spans** (>10KB): Limited by network bandwidth
- **Automatic HTTP chunking** for large payloads

### Memory Usage
- **Native JSON objects** minimize memory allocations
- **Automatic CLOB cleanup** prevents memory leaks
- **32KB VARCHAR2 threshold** for optimal performance

### Network Efficiency
- **Single HTTP request** per telemetry item
- **Proper Content-Length headers** for optimal parsing
- **Configurable timeouts** prevent hanging connections

### Error Isolation
- **Telemetry failures never impact business logic**
- **Autonomous transaction error logging**
- **Graceful degradation** on network issues

## 🏢 Enterprise Deployment

### Multi-Environment Configuration
```sql
-- Production
PLT_OTLP_BRIDGE.set_otlp_collector('http://prod-collector:4318');
PLT_OTLP_BRIDGE.set_tenant_context('prod_tenant', 'Production Environment');

-- Staging  
PLT_OTLP_BRIDGE.set_otlp_collector('http://staging-collector:4318');
PLT_OTLP_BRIDGE.set_tenant_context('staging_tenant', 'Staging Environment');
```

### High Availability
- Configure multiple collector endpoints for failover
- Use async mode for high-throughput environments
- Monitor `plt_telemetry_errors` table for issues

### Security Considerations
- Network ACLs restrict collector access
- No sensitive data in telemetry by default
- Tenant isolation at resource attribute level

## 🚀 What's Next

### Planned Features
- **Batch export** for high-volume environments
- **gRPC protocol support** (OTLP/gRPC)
- **Built-in sampling strategies** for production workloads
- **Compression support** for large payloads
- **Authentication** (API keys, OIDC tokens)

### Current Limitations
- HTTP/1.1 only (no HTTP/2)
- No built-in sampling (all spans exported)
- Single request per telemetry item (no batching)
- Basic authentication only (API key headers)

## 🤝 Integration Notes

This bridge is specifically designed for PLTelemetry and provides:
- **Drop-in backend replacement** (set backend_url to 'OTLP_BRIDGE')  
- **Zero code changes** to existing PLTelemetry usage
- **Full OpenTelemetry ecosystem compatibility**
- **Enterprise multi-tenant support**
- **Production-grade error handling and performance**

For more information about PLTelemetry core functionality, see the main PLTelemetry repository documentation.

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.