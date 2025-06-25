# PLT_OTLP_BRIDGE

> **OpenTelemetry Protocol Bridge for Oracle PL/SQL**

A production-ready Oracle PL/SQL package that seamlessly connects [PLTelemetry](https://github.com/your-username/PLTelemetry) with any OpenTelemetry collector, enabling distributed tracing, metrics, and logging from Oracle databases to modern observability platforms.

## 🎯 What It Does

PLT_OTLP_BRIDGE converts PLTelemetry's JSON telemetry data into OTLP (OpenTelemetry Protocol) format and sends it to any OpenTelemetry collector via HTTP. This enables Oracle databases to participate in modern distributed tracing ecosystems.

**Data Flow:**
```
Oracle PL/SQL → PLTelemetry → PLT_OTLP_BRIDGE → OTLP Collector → Grafana/Jaeger/Tempo
```

## ✨ Features

### Core Capabilities
- **Distributed Tracing** - Converts PLTelemetry spans to OTLP traces with parent-child relationships
- **Metrics Export** - Transforms custom metrics to OTLP gauge format
- **Structured Logging** - Converts events and logs to OTLP log records with severity levels
- **Trace Context Propagation** - Maintains trace and span IDs across the observability stack

### Enterprise-Grade Architecture
- **Hybrid String Management** - Automatically switches between VARCHAR2 and CLOB for optimal memory usage
- **Dual JSON Parsing** - Native Oracle 12c+ JSON functions with regex fallback for older versions
- **Comprehensive Error Handling** - Never breaks business logic, includes autonomous transaction logging
- **HTTP Chunked Transfer** - Handles large payloads efficiently with automatic chunking
- **Configurable Timeouts** - Prevents hanging connections with adjustable timeout settings

### Production Features
- **Debug Mode** - Detailed logging for troubleshooting and performance monitoring
- **Resource Attribution** - Automatic service identification and metadata injection
- **Status Code Mapping** - Proper OTLP status code conversion (OK, ERROR, UNSET)
- **JSON Escaping** - Comprehensive handling of special characters and control sequences

## 🚀 Quick Start

### Prerequisites
- Oracle Database 12c+ (11g supported with legacy JSON mode)
- PLTelemetry core package installed
- UTL_HTTP and DBMS_CRYPTO privileges
- Network access to your OpenTelemetry collector

### Installation

1. **Install the package:**
```sql
-- Install package specification
@PLT_OTLP_BRIDGE.pks

-- Install package body  
@PLT_OTLP_BRIDGE.pkb
```

2. **REQUIRED: Configure PLTelemetry routing:**
```sql
-- MANDATORY: Tell PLTelemetry to use the OTLP bridge instead of direct HTTP
PLTelemetry.set_backend_url('OTLP_BRIDGE');
```

3. **REQUIRED: Configure collector endpoint:**
```sql
-- MANDATORY: Set your OpenTelemetry collector endpoint
PLT_OTLP_BRIDGE.set_otlp_collector('http://your-collector:4318');
```

4. **RECOMMENDED: Initial setup configuration:**
```sql
-- RECOMMENDED: Use sync mode for initial testing
PLTelemetry.set_async_mode(FALSE);

-- USEFUL: Enable debug output during setup
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);

-- OPTIONAL: Configure service identification
PLT_OTLP_BRIDGE.set_service_info(
    p_service_name => 'your-oracle-app',
    p_service_version => '1.0.0',
    p_tenant_id => 'production'
);
```

### ⚠️ Critical Configuration Notes

**Without proper configuration, telemetry data will not reach your collector:**

- **Missing `PLTelemetry.set_backend_url('OTLP_BRIDGE')`** → PLTelemetry sends to default HTTP endpoint (fails)
- **Missing `PLT_OTLP_BRIDGE.set_otlp_collector()`** → Bridge doesn't know where to send data (fails)

**Data Flow:**
```
✅ WITH CONFIG:  PLTelemetry → PLT_OTLP_BRIDGE → OTLP Collector → Success
❌ WITHOUT CONFIG: PLTelemetry → Default HTTP → Failure
```

### Basic Usage

Once configured, PLTelemetry automatically routes all telemetry through the OTLP bridge:

```sql
-- FIRST: Configure the bridge (run once)
BEGIN
    -- MANDATORY configuration
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    PLT_OTLP_BRIDGE.set_otlp_collector('http://your-collector:4318');
    
    -- OPTIONAL configuration  
    PLTelemetry.set_async_mode(FALSE);  -- Sync mode for testing
    PLT_OTLP_BRIDGE.set_debug_mode(TRUE);  -- See what's happening
    PLT_OTLP_BRIDGE.set_service_info('my-oracle-app', '1.0.0');
END;
/

-- THEN: Use PLTelemetry normally
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    -- Start distributed trace
    l_trace_id := PLTelemetry.start_trace('process_order');
    l_span_id := PLTelemetry.start_span('validate_customer');
    
    -- Add contextual attributes
    l_attrs(1) := PLTelemetry.add_attribute('customer.id', '12345');
    l_attrs(2) := PLTelemetry.add_attribute('order.value', '299.99');
    
    -- Add timeline events
    PLTelemetry.add_event(l_span_id, 'validation_started');
    PLTelemetry.add_event(l_span_id, 'customer_found');
    
    -- Record performance metrics
    PLTelemetry.log_metric('validation_duration_ms', 45.2, 'ms', l_attrs);
    
    -- Complete the trace
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

## 🔧 Configuration

### Collector Configuration
```sql
-- Basic collector setup
PLT_OTLP_BRIDGE.set_otlp_collector('http://localhost:4318');

-- Individual endpoint configuration
PLT_OTLP_BRIDGE.set_traces_endpoint('http://collector:4318/v1/traces');
PLT_OTLP_BRIDGE.set_metrics_endpoint('http://collector:4318/v1/metrics');
PLT_OTLP_BRIDGE.set_logs_endpoint('http://collector:4318/v1/logs');
```

### Service Identification
```sql
PLT_OTLP_BRIDGE.set_service_info(
    p_service_name => 'order-processing-api',
    p_service_version => '2.1.3',
    p_tenant_id => 'customer-portal'
);
```

### Performance Tuning
```sql
-- Set HTTP timeout (default: 30 seconds)
PLT_OTLP_BRIDGE.set_timeout(45);

-- Enable native JSON parsing for Oracle 12c+ (better performance)
PLT_OTLP_BRIDGE.set_native_json_mode(TRUE);

-- Enable debug mode for troubleshooting
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
```

## 📊 Supported Data Types

### Traces and Spans
- **Trace Context** - 128-bit trace IDs, 64-bit span IDs
- **Parent-Child Relationships** - Nested span hierarchies
- **Span Status** - OK, ERROR, UNSET with proper OTLP mapping
- **Timestamps** - Nanosecond precision Unix timestamps
- **Attributes** - Key-value metadata with JSON escaping

### Metrics
- **Gauge Metrics** - Point-in-time measurements
- **Units** - Metric units (ms, bytes, requests, etc.)
- **Trace Correlation** - Links metrics to active traces
- **Custom Attributes** - Dimensional metadata

### Events and Logs
- **Structured Events** - Timeline events within spans
- **Log Levels** - TRACE, DEBUG, INFO, WARN, ERROR, FATAL
- **Message Content** - Escaped log messages up to 4KB
- **Trace Context** - Automatic trace/span ID correlation

## 🏗️ Architecture Details

### Hybrid String Management
The bridge automatically chooses between VARCHAR2 and CLOB based on content size:
- **Small payloads** (< 32KB) - Fast VARCHAR2 processing
- **Large payloads** (> 32KB) - Automatic CLOB switching with chunked HTTP transfer

### Dual JSON Parsing
- **Native Mode** - Oracle 12c+ JSON_VALUE/JSON_QUERY functions (faster)
- **Legacy Mode** - Regex-based parsing for older Oracle versions
- **Automatic Fallback** - Graceful degradation when native parsing fails

### Error Handling
- **Never Fail** - Business logic continues even if telemetry fails
- **Autonomous Logging** - Errors logged to `plt_telemetry_errors` table
- **Context Preservation** - Error logs include JSON payload samples for debugging

## 📈 Performance Characteristics

### Throughput
- **Small spans** (< 1KB) - Processes ~1000/second
- **Large spans** (> 10KB) - Automatic chunking prevents memory issues
- **Batch Processing** - Single HTTP request per telemetry item

### Memory Usage
- **Adaptive** - VARCHAR2 for small payloads, CLOB for large ones
- **Cleanup** - Automatic temporary LOB cleanup
- **Buffer Management** - 8KB chunk size for optimal performance

### Network Efficiency
- **HTTP/1.1** - Keep-alive connections where supported
- **Content-Length** - Accurate size headers for optimal parsing
- **Chunked Transfer** - Large payloads sent in manageable chunks

## 🐛 Troubleshooting

### Enable Debug Mode
```sql
PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
```

Debug output includes:
- JSON payload sizes and processing mode
- HTTP endpoint targets and response codes
- Timing information for large transfers
- JSON parsing mode selection (native vs legacy)

### Check Error Logs
```sql
SELECT error_time, error_message, error_stack 
FROM plt_telemetry_errors 
WHERE module_name = 'PLT_OTLP_BRIDGE'
ORDER BY error_time DESC;
```

### Common Issues

**Connection refused:**
- Verify collector URL and port
- Check network connectivity from database server
- Ensure collector is running and listening

**JSON parsing errors:**
- Try switching JSON parsing mode: `PLT_OTLP_BRIDGE.set_native_json_mode(FALSE)`
- Check for special characters in attribute values
- Verify PLTelemetry JSON format

**Timeout errors:**
- Increase timeout: `PLT_OTLP_BRIDGE.set_timeout(60)`
- Check collector performance
- Consider collector queuing if using large payloads

## 🔌 Collector Configuration

### OTEL Collector Config Example
```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
        
exporters:
  jaeger:
    endpoint: jaeger:14250
    tls:
      insecure: true
  prometheus:
    endpoint: "0.0.0.0:8889"
  loki:
    endpoint: http://loki:3100/loki/api/v1/push

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [jaeger]
    metrics:
      receivers: [otlp]  
      exporters: [prometheus]
    logs:
      receivers: [otlp]
      exporters: [loki]
```

### Grafana Integration
The bridge works seamlessly with Grafana's observability stack:
- **Tempo** - Distributed tracing visualization
- **Prometheus** - Metrics collection and alerting
- **Loki** - Log aggregation and search

## 📋 Requirements

### Database Privileges
```sql
-- Required grants (run as DBA)
GRANT EXECUTE ON UTL_HTTP TO your_user;
GRANT EXECUTE ON DBMS_CRYPTO TO your_user;
GRANT EXECUTE ON DBMS_LOB TO your_user;
```

### Network ACLs
```sql
-- Allow HTTP access to collector
BEGIN
  DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(
    acl => 'otlp_collector_acl.xml',
    description => 'OTLP Collector Access',
    principal => 'YOUR_USER',
    is_grant => TRUE,
    privilege => 'connect'
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl => 'otlp_collector_acl.xml',
    host => 'your-collector-host'
  );
END;
/
```

## 🤝 Integration with PLTelemetry

This bridge is designed as a drop-in backend for [PLTelemetry](https://github.com/your-username/PLTelemetry). Simply configure PLTelemetry to use `'OTLP_BRIDGE'` as the backend URL, and all telemetry data will automatically flow through this bridge to your OpenTelemetry infrastructure.

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🚀 What's Next

- **gRPC Support** - Direct OTLP/gRPC protocol support
- **Batch Export** - Configurable batching for high-volume environments  
- **Sampling** - Built-in sampling strategies for production workloads
- **Compression** - GZIP compression for network efficiency
- **Authentication** - OIDC and API key authentication support