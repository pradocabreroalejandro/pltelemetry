<p align="center">
  <img src="assets/PLT_logo.jpg" alt="PLTelemetry logo" width="200"/>
</p>

# PLTelemetry

Bring distributed observability to Oracle PL/SQL with OpenTelemetry-style traces and metrics

> ⚠️ **Note**  
> PLTelemetry is *not* a replacement for OpenTelemetry.  
> It's a lightweight implementation focused on **bringing observability to Oracle PL/SQL**, where OTEL doesn't reach.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Oracle](https://img.shields.io/badge/Oracle-12c%2B-red.svg)
![Version](https://img.shields.io/badge/version-1.0.0-green.svg)

## 🚀 Overview

PLTelemetry brings modern observability to Oracle PL/SQL applications. It provides OpenTelemetry-compatible distributed tracing capabilities with a pluggable backend architecture through bridges.

### ✨ Key Features

- 🔍 **Distributed Tracing**: Full OpenTelemetry-compatible trace and span management
- 📊 **Metrics Collection**: Record custom metrics with attributes and units
- 🌉 **Pluggable Bridges**: Connect to any backend (PostgreSQL, Elasticsearch, Jaeger, etc.)
- 🎯 **Event Logging**: Add contextual events to spans for detailed observability
- 🚀 **Async Processing**: Queue-based telemetry export for minimal performance impact
- ⚡ **Sync Mode**: Immediate export when needed
- 🛡️ **Robust Error Handling**: Never breaks your business logic
- 🔧 **Backend Agnostic**: Generic JSON format works with any backend via bridges

## 📦 Architecture

```
Your PL/SQL App → PLTelemetry → Bridge → Your Backend
                       ↓           ↓           ↓
                  Generic JSON   Transform    PostgreSQL
                                to backend    TODO: Elasticsearch
                                  format      TODO: InfluxDB
                                              TODO: Jaeger
```

## 🏃 Quick Start

### 1. Install Core PLTelemetry

```sql
-- Install tables and package
cd core/oracle
sqlplus your_user/your_pass @install.sql
```

### 2. Choose and Install a Bridge

For example, PostgreSQL bridge:
```sql
cd bridges/postgresql/oracle
sqlplus your_user/your_pass @install.sql
```

### 3. Configure

```sql
BEGIN
    -- Configure PLTelemetry to use your bridge
    PLTelemetry.set_backend_url('POSTGRES_BRIDGE');
    PLTelemetry.set_async_mode(TRUE);
    PLTelemetry.set_autocommit(TRUE);
    
    -- Configure the bridge (example for PostgreSQL)
    PLT_POSTGRES_BRIDGE.set_postgrest_url('http://localhost:3000');
END;
/
```

### 4. Start Tracing!

```sql
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    -- Start a new trace
    l_trace_id := PLTelemetry.start_trace('process_order');
    
    -- Create a span
    l_span_id := PLTelemetry.start_span('validate_customer');
    
    -- Add attributes
    l_attrs(1) := PLTelemetry.add_attribute('customer.id', '12345');
    l_attrs(2) := PLTelemetry.add_attribute('order.total', '299.99');
    
    -- Your business logic here
    validate_customer(12345);
    
    -- End span with status
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    
    -- Log a metric
    PLTelemetry.log_metric('order_value', 299.99, 'USD', l_attrs);
END;
/
```

## 🌉 Available Bridges

| Bridge | Status | Backend | Features |
|--------|--------|---------|----------|
| [PostgreSQL](bridges/postgresql/) | ✅ Production Ready | PostgreSQL + PostgREST | Full traces, spans, metrics |
| [Elasticsearch](bridges/elasticsearch/) | 🚧 In Development | Elasticsearch 8.x | Full-text search |
| [InfluxDB](bridges/influxdb/) | 📋 Planned | InfluxDB 2.x | Time-series optimized |
| [Jaeger](bridges/jaeger/) | 📋 Planned | Jaeger | Native UI |

## 📖 Documentation

- 📚 [Core PLTelemetry](core/README.md) - Core package documentation
- 🌉 [Bridges Overview](bridges/README.md) - How bridges work
- 🔧 [API Reference](#api-reference) - Complete API documentation
- 📝 [Examples](core/oracle/examples/) - Working examples

## 🔧 API Reference

### Core Tracing Functions

```sql
-- Start a new trace
FUNCTION start_trace(p_operation VARCHAR2) RETURN VARCHAR2;

-- Start a span (with optional parent)
FUNCTION start_span(
    p_operation VARCHAR2, 
    p_parent_span_id VARCHAR2 DEFAULT NULL,
    p_trace_id VARCHAR2 DEFAULT NULL
) RETURN VARCHAR2;

-- End a span
PROCEDURE end_span(
    p_span_id VARCHAR2, 
    p_status VARCHAR2 DEFAULT 'OK',
    p_attributes t_attributes DEFAULT t_attributes()
);

-- Add an event to a span
PROCEDURE add_event(
    p_span_id VARCHAR2,
    p_event_name VARCHAR2,
    p_attributes t_attributes DEFAULT t_attributes()
);

-- Log a metric
PROCEDURE log_metric(
    p_metric_name VARCHAR2,
    p_value NUMBER,
    p_unit VARCHAR2 DEFAULT NULL,
    p_attributes t_attributes DEFAULT t_attributes()
);
```

### Configuration

```sql
-- Backend configuration
PROCEDURE set_backend_url(p_url VARCHAR2);
PROCEDURE set_api_key(p_key VARCHAR2);
PROCEDURE set_backend_timeout(p_timeout NUMBER);

-- Processing modes
PROCEDURE set_async_mode(p_async BOOLEAN);
PROCEDURE set_autocommit(p_value BOOLEAN);

-- Queue management (async mode)
PROCEDURE process_queue(p_batch_size NUMBER DEFAULT 100);
```

## 🎯 Common Use Cases

### Error Tracking

```sql
DECLARE
    l_span_id VARCHAR2(16);
    l_attrs PLTelemetry.t_attributes;
BEGIN
    l_span_id := PLTelemetry.start_span('risky_operation');
    
    BEGIN
        -- Your code here
        risky_business_logic();
        PLTelemetry.end_span(l_span_id, 'OK');
    EXCEPTION
        WHEN OTHERS THEN
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SQLERRM);
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            RAISE;
    END;
END;
/
```

### Performance Monitoring

```sql
DECLARE
    l_start_time TIMESTAMP := SYSTIMESTAMP;
    l_span_id VARCHAR2(16);
BEGIN
    l_span_id := PLTelemetry.start_span('batch_process');
    
    -- Process your batch
    process_large_batch();
    
    -- Log execution time
    PLTelemetry.log_metric(
        'batch_processing_time',
        EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_time)) * 1000,
        'ms'
    );
    
    PLTelemetry.end_span(l_span_id, 'OK');
END;
/
```

## 🏗️ Creating Your Own Bridge

Want to send telemetry to a backend we don't support yet? Create your own bridge!

1. Copy the [template](bridges/template/)
2. Implement the transformation functions
3. Handle your backend's authentication
4. Share it with the community!

See the [Bridge Development Guide](bridges/template/BRIDGE_DEVELOPMENT.md) for details.

## 📋 Requirements

- Oracle Database 12c or higher
- `UTL_HTTP` package access for HTTP backends
- `DBMS_CRYPTO` package for ID generation
- `DBMS_SCHEDULER` access for async queue processing

### Required Grants

```sql
GRANT EXECUTE ON UTL_HTTP TO your_user;
GRANT EXECUTE ON DBMS_CRYPTO TO your_user;
GRANT CREATE JOB TO your_user;
```

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md).

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- OpenTelemetry community for the specification
- Oracle community for PL/SQL best practices
- All contributors who make this project better

## 📞 Support

- 📖 [Documentation Wiki](https://github.com/pradocabreroalejandro/pltelemetry/wiki)
- 🐛 [Report Issues](https://github.com/pradocabreroalejandro/pltelemetry/issues)
- 💬 [Discussions](https://github.com/pradocabreroalejandro/pltelemetry/discussions)
- ⭐ Star us on GitHub if you find this useful!

---

<p align="center">
Made with ❤️ for the Oracle PL/SQL community
</p>