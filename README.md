# PLTelemetry

OpenTelemetry SDK for Oracle PL/SQL - Distributed tracing, metrics, and observability for Oracle Database applications.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Oracle](https://img.shields.io/badge/Oracle-12c%2B-red.svg)
![Version](https://img.shields.io/badge/version-0.1.0-green.svg)

## Overview

PLTelemetry provides OpenTelemetry-compatible distributed tracing capabilities for PL/SQL applications. It enables you to instrument your Oracle Database code with traces, spans, events, and metrics that can be exported to modern observability platforms.

### Key Features

- 🔍 **Distributed Tracing**: Full OpenTelemetry-compatible trace and span management
- 📊 **Metrics Collection**: Record custom metrics with attributes and units
- 🎯 **Event Logging**: Add contextual events to spans for detailed observability
- 🚀 **Async Processing**: Queue-based telemetry export for minimal performance impact
- ⚡ **Sync Fallback**: Automatic fallback to synchronous mode on queue failures
- 🛡️ **Robust Error Handling**: Never fails your business logic due to telemetry issues
- 🔧 **Configurable**: Adjustable backends, timeouts, and processing modes
- 📈 **Performance Optimized**: Minimal overhead on your production workloads

## Quick Start

### For DBAs - Installation

1. **Create required tables**:
```sql
-- Run the provided DDL script
@install_tables.sql
```

2. **Install the package**:
```sql
-- Install package specification
@PLTelemetry.pks

-- Install package body  
@PLTelemetry.pkb
```

3. **Configure backend endpoint**:
```sql
BEGIN
    PLTelemetry.set_backend_url('https://your-telemetry-backend.com/api/traces');
    PLTelemetry.set_api_key('your-secret-api-key');
    PLTelemetry.set_async_mode(TRUE);  -- Recommended for production
END;
/
```

4. **Set up queue processing job**:
```sql
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'PLT_QUEUE_PROCESSOR',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLTelemetry.process_queue(100); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=1',
        enabled         => TRUE,
        comments        => 'Process PLTelemetry queue every minute'
    );
END;
/
```

### For Developers - Basic Usage

```sql
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    -- Start a new trace
    l_trace_id := PLTelemetry.start_trace('process_customer_order');
    
    -- Start a span for validation
    l_span_id := PLTelemetry.start_span('validate_customer');
    
    -- Add some attributes
    l_attrs(1) := PLTelemetry.add_attribute('customer.id', '12345');
    l_attrs(2) := PLTelemetry.add_attribute('order.total', '299.99');
    
    -- Your business logic here
    validate_customer(p_customer_id => 12345);
    
    -- Add an event
    PLTelemetry.add_event(l_span_id, 'customer_validated', l_attrs);
    
    -- End the span
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    
    -- Record a metric
    PLTelemetry.log_metric('order_value', 299.99, 'USD', l_attrs);
    
    -- End the trace
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

## API Reference

### Core Functions

#### `start_trace(p_operation VARCHAR2) RETURN VARCHAR2`
Starts a new distributed trace.

**Parameters:**
- `p_operation`: Name of the root operation being traced

**Returns:** 32-character hex trace ID

#### `start_span(p_operation VARCHAR2, p_parent_span_id VARCHAR2, p_trace_id VARCHAR2) RETURN VARCHAR2`
Starts a new span within a trace.

**Parameters:**
- `p_operation`: Name of the operation for this span
- `p_parent_span_id`: Optional parent span ID for nested spans
- `p_trace_id`: Optional trace ID (uses current if not provided)

**Returns:** 16-character hex span ID

#### `end_span(p_span_id VARCHAR2, p_status VARCHAR2, p_attributes t_attributes)`
Ends an active span and records its duration.

**Parameters:**
- `p_span_id`: The span ID to end
- `p_status`: Final status ('OK', 'ERROR', etc.)
- `p_attributes`: Optional attributes collection

#### `add_event(p_span_id VARCHAR2, p_event_name VARCHAR2, p_attributes t_attributes)`
Adds an event to an active span.

#### `log_metric(p_metric_name VARCHAR2, p_value NUMBER, p_unit VARCHAR2, p_attributes t_attributes)`
Records a metric with metadata.

### Configuration Functions

```sql
-- Set backend configuration
PLTelemetry.set_backend_url('https://api.example.com/telemetry');
PLTelemetry.set_api_key('your-api-key');
PLTelemetry.set_backend_timeout(30);

-- Configure processing mode
PLTelemetry.set_async_mode(TRUE);
PLTelemetry.set_autocommit(FALSE);

-- Get current settings
l_url := PLTelemetry.get_backend_url();
l_trace_id := PLTelemetry.get_current_trace_id();
```

## Advanced Usage

### Error Handling Pattern

```sql
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    l_trace_id := PLTelemetry.start_trace('risky_operation');
    l_span_id := PLTelemetry.start_span('database_transaction');
    
    BEGIN
        -- Your risky business logic
        execute_complex_transaction();
        
        PLTelemetry.add_event(l_span_id, 'transaction_completed');
        PLTelemetry.end_span(l_span_id, 'OK');
        
    EXCEPTION
        WHEN OTHERS THEN
            l_attrs(1) := PLTelemetry.add_attribute('error.message', SQLERRM);
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            
            PLTelemetry.add_event(l_span_id, 'transaction_failed', l_attrs);
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            
            RAISE; -- Re-raise the original exception
    END;
    
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

### Nested Spans for Complex Operations

```sql
DECLARE
    l_trace_id     VARCHAR2(32);
    l_main_span    VARCHAR2(16);
    l_db_span      VARCHAR2(16);
    l_api_span     VARCHAR2(16);
BEGIN
    l_trace_id := PLTelemetry.start_trace('order_processing');
    l_main_span := PLTelemetry.start_span('process_order');
    
    -- Database operations
    l_db_span := PLTelemetry.start_span('save_order', l_main_span);
    save_order_to_database();
    PLTelemetry.end_span(l_db_span, 'OK');
    
    -- External API call
    l_api_span := PLTelemetry.start_span('notify_external_system', l_main_span);
    call_external_api();
    PLTelemetry.end_span(l_api_span, 'OK');
    
    PLTelemetry.end_span(l_main_span, 'OK');
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

## JSON Output Examples

### Span End Event
```json
{
  "trace_id": "a1b2c3d4e5f6789012345678901234ab",
  "span_id": "a1b2c3d4e5f67890",
  "operation": "end_span",
  "status": "OK",
  "duration_ms": 245.67,
  "timestamp": "2025-06-20T14:30:15.123Z",
  "attributes": {
    "customer.id": "12345",
    "order.total": "299.99",
    "db.operation": "INSERT"
  }
}
```

### Metric Event
```json
{
  "metric_name": "order_processing_time",
  "value": 1234.56,
  "unit": "milliseconds",
  "timestamp": "2025-06-20T14:30:15.123Z",
  "trace_id": "a1b2c3d4e5f6789012345678901234ab",
  "span_id": "a1b2c3d4e5f67890",
  "attributes": {
    "customer.type": "premium",
    "order.items": "3"
  }
}
```

## Performance Considerations

### Async Mode (Recommended)
- Minimal impact on business logic performance
- Telemetry data queued locally and processed in batches
- Automatic retry on failures
- Requires scheduled job for queue processing

### Sync Mode
- Immediate export to backend
- Higher latency impact on business operations
- Useful for debugging or low-volume scenarios

### Queue Management
The async queue should be monitored and maintained:

```sql
-- Check queue status
SELECT 
    COUNT(*) as total_entries,
    SUM(CASE WHEN processed = 'N' THEN 1 ELSE 0 END) as pending,
    SUM(CASE WHEN process_attempts >= 3 THEN 1 ELSE 0 END) as failed
FROM plt_queue;

-- Manual queue processing
BEGIN
    PLTelemetry.process_queue(500); -- Process up to 500 entries
END;
/
```

## OpenTelemetry Compatibility

PLTelemetry follows OpenTelemetry semantic conventions:

- **Trace IDs**: 128-bit (32 hex characters)
- **Span IDs**: 64-bit (16 hex characters)  
- **Attribute naming**: Standard semantic conventions
- **HTTP attributes**: `http.method`, `http.url`, `http.status_code`
- **Database attributes**: `db.operation`, `db.statement`
- **Error attributes**: `error.message`

## Requirements

- Oracle Database 12c or higher
- `UTL_HTTP` package access for backend communication
- `DBMS_CRYPTO` package for ID generation
- `DBMS_SCHEDULER` access for queue processing jobs

## Database Permissions

The user installing PLTelemetry needs:
```sql
GRANT EXECUTE ON UTL_HTTP TO your_user;
GRANT EXECUTE ON DBMS_CRYPTO TO your_user;
GRANT CREATE JOB TO your_user;
```

## Components

**PLTelemetry Package**: Oracle PL/SQL package for telemetry generation
**[Bridge](./bridge/)**: Node.js service to convert PLTelemetry JSON to OpenTelemetry format


## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Support

- 📖 Documentation: [GitHub Wiki](https://github.com/pradocabreroalejandro/pltelemetry/wiki)
- 🐛 Issues: [GitHub Issues](https://github.com/pradocabreroalejandro/pltelemetry/issues)
- 💬 Discussions: [GitHub Discussions](https://github.com/pradocabreroalejandro/pltelemetry/discussions)