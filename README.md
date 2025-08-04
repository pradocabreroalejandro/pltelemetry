<p align="center">
  <img src="assets/PLT_logo.jpg" alt="PLTelemetry logo" width="200"/>
</p>


# PLTelemetry

> **Bringing observability to Oracle PL/SQL and legacy systems where standard tools don't reach**

PLTelemetry is a lightweight observability toolkit specifically designed for Oracle environments - PL/SQL packages, Oracle Forms, and Reports. It fills the gap where OpenTelemetry agents can't go: inside your database stored procedures and legacy applications.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Oracle](https://img.shields.io/badge/Oracle-12c%2B-red.svg)
![Status](https://img.shields.io/badge/status-production%20ready-green.svg)
![Oracle Forms](https://img.shields.io/badge/Oracle%20Forms-supported-orange.svg)
![Distributed Tracing](https://img.shields.io/badge/distributed%20tracing-ready-green.svg)
![Not affiliated with Oracle](https://img.shields.io/badge/affiliation-independent-blueviolet?logo=oracle&logoColor=white)


## Legal Disclaimer

**PLTelemetry** is an independent, community-driven project created and maintained by **Alejandro Prado Cabrero**.  

It is **not affiliated with, endorsed by, or officially supported by Oracle Corporation** in any form.  
References to Oracle® products (including Oracle Database, Oracle Forms, and Oracle Reports) are used **solely for integration and compatibility purposes**.  

Oracle and all related marks are **registered trademarks of Oracle Corporation**. All other trademarks mentioned belong to their respective owners.  

The author is **not an Oracle employee, partner, or representative**, and this software does **not contain any proprietary or confidential Oracle code**.  

This project is provided “**as is**”, without any warranty. Use at your own discretion and risk, especially in production environments.


## What PLTelemetry Actually Does

**Reality Check:** PLTelemetry is not trying to compete with DataDog or New Relic. It's a specialized tool for a specific problem: getting distributed tracing and structured observability out of Oracle PL/SQL environments.

- **Distributed Tracing**: Correlate operations across Oracle Forms → PL/SQL → external APIs → Reports
- **Structured Logging**: Get real logs with context from your stored procedures
- **Business Metrics**: Track what matters in your Oracle applications
- **Multi-tenant Support**: Separate telemetry by tenant/customer
- **Lightweight**: Designed not to get in your way or slow things down

## The Architecture (Simple & Honest)

```
Oracle PL/SQL → Queue Table → WoofyMetrics Agent → OTLP Collector → Grafana/Tempo
     ↓                              ↓
 Fallback to UTL_HTTP      Pulse Throttling System
                                    ↓
                         PULSE1 → PULSE2 → PULSE3 → PULSE4 → COMA
```

**Primary Flow**: PL/SQL writes to queue, WoofyMetrics processes asynchronously
**Pulse System**: Adaptive throttling based on system heat (CPU/Memory)
**Failover Logic**: Automatic detection and switching, no data loss

### Pulse Throttling System

PLTelemetry includes an intelligent **Pulse Throttling System** that automatically adapts processing intensity based on system load:

| Mode | Capacity | Batch Size | Description | Trigger |
|------|----------|------------|-------------|---------|
| **PULSE1** | 100% | Full | Maximum performance | Heat < 30% |
| **PULSE2** | 50% | Half | Moderate throttling | Heat 30-50% |
| **PULSE3** | 25% | Quarter | Reduced processing | Heat 50-70% |
| **PULSE4** | 10% | Minimal | Emergency throttling | Heat 70-90% |
| **COMA** | 0% | None | System hibernation | Heat > 90% |

**Heat Calculation**: Weighted combination of CPU (60%) and Memory (40%) usage
**Failover Integration**: PULSE4/COMA modes automatically trigger Oracle fallback
**Hysteresis**: 5% margin prevents mode flapping

## What's Actually Implemented

### ✅ Production Ready
- **Core PLTelemetry Package**: Full distributed tracing with spans, events, attributes
- **OTLP Bridge**: Native Oracle 12c+ JSON integration with Tempo/Jaeger/Grafana
- **WoofyMetrics Agent**: Async processing with circuit breakers, throttling, and health monitoring
- **Pulse Throttling System**: Adaptive system protection with 5 throttling modes (PULSE1→COMA)
- **Intelligent Failover**: Automatic agent health detection with Oracle fallback integration
- **Oracle Forms Integration**: Complete tracing across Forms workflows
- **Activation Manager**: Granular control over what gets traced (wildcards, sampling, tenant isolation)
- **Multi-tenant Support**: Tenant-aware tracing and filtering

### 🚧 In Development
- External queue processing agents in other languages
- Advanced sampling strategies
- Performance benchmarking suite

### ❌ Not Implemented (Yet)
- PostgreSQL bridge (referenced but not complete)
- Elasticsearch bridge (planned)
- Full APEX integration (possible but not tested)

## Quick Start

### 1. Install Core Package
```sql
-- Install as PLTELEMETRY user
@src/PLTelemetry.pks
@src/PLTelemetry.pkb
@install/tables/plt_tables.sql
```

### 2. Install OTLP Bridge
```sql
@bridges/OTLP/PLT_OTLP_BRIDGE.pks
@bridges/OTLP/PLT_OTLP_BRIDGE.pkb
```

### 3. Configure
```sql
BEGIN
    -- Tell PLTelemetry to use OTLP
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    
    -- Point to your Tempo/Jaeger endpoint
    PLT_OTLP_BRIDGE.set_otlp_collector('http://tempo:4318');
    
    -- Identify your service
    PLT_OTLP_BRIDGE.set_service_info('oracle-app', '1.0.0');
END;
/
```

### 4. Start Tracing
```sql
DECLARE
    l_trace_id VARCHAR2(32);
    l_span_id VARCHAR2(16);
BEGIN
    -- Simple tracing
    l_trace_id := PLTelemetry.start_trace('process_order');
    l_span_id := PLTelemetry.start_span('validate_customer');
    
    -- Your business logic here
    validate_customer_data(p_customer_id);
    
    PLTelemetry.end_span(l_span_id, 'OK');
    PLTelemetry.end_trace(l_trace_id);
END;
/
```

## Real-World Example: Oracle Forms to PL/SQL

**Oracle Forms (button trigger):**
```sql
DECLARE
    l_trace_id VARCHAR2(32);
BEGIN
    -- Start trace in Forms
    l_trace_id := PLTelemetry.start_trace('customer_lookup');
    
    -- Call PL/SQL API with trace context
    l_result := CUSTOMER_API.search(
        p_name => :SEARCH.CUSTOMER_NAME,
        p_trace_id => l_trace_id  -- Pass trace context
    );
    
    PLTelemetry.end_trace(l_trace_id);
END;
```

**PL/SQL Package:**
```sql
FUNCTION search(p_name VARCHAR2, p_trace_id VARCHAR2) RETURN VARCHAR2 IS
    l_span_id VARCHAR2(16);
BEGIN
    -- Continue the trace from Forms
    l_span_id := PLTelemetry.continue_distributed_trace(
        p_trace_id => p_trace_id,
        p_operation => 'database_search'
    );
    
    -- Your search logic
    perform_customer_search(p_name);
    
    PLTelemetry.end_span(l_span_id, 'OK');
    RETURN 'SUCCESS';
END;
```

**Result**: Complete timeline in Grafana showing Forms button click → database search, all correlated by trace ID.

## Performance & Overhead

**Honest Assessment:**
- **Async Mode**: ~1-2ms overhead per telemetry call (queued for background processing)
- **Sync Mode**: 10-50ms per call (immediate HTTP sending)
- **Memory**: Minimal - uses VARCHAR2/CLOB switching based on payload size
- **Network**: HTTP/1.1 with connection pooling
- **Error Isolation**: Telemetry failures never break your business logic

**Production Settings:**
```sql
-- Recommended for high-volume systems
PLTelemetry.set_async_mode(TRUE);
PLT_ACTIVATION_MANAGER.set_global_sampling_rate(0.1); -- 10% sampling
```

## Configuration Options

### Basic Setup
```sql
-- Backend routing
PLTelemetry.set_backend_url('OTLP_BRIDGE');

-- Processing mode
PLTelemetry.set_async_mode(TRUE);   -- Background processing
PLTelemetry.set_autocommit(FALSE);  -- Manual transaction control

-- OTLP endpoint
PLT_OTLP_BRIDGE.set_otlp_collector('http://tempo:4318');
PLT_OTLP_BRIDGE.set_service_info('your-app', '1.0.0');
```

### Activation Control
```sql
-- Enable tracing for specific packages
PLT_ACTIVATION_MANAGER.enable_telemetry(
    p_object_name => 'CUSTOMER_PKG.*',
    p_telemetry_type => 'TRACE',
    p_sampling_rate => 0.1
);

-- Enable only for specific tenant
PLT_ACTIVATION_MANAGER.enable_telemetry(
    p_object_name => 'ORDER_PROCESSING.*',
    p_telemetry_type => 'TRACE',
    p_tenant_id => 'customer_abc'
);
```

## Multi-Tenant Support

PLTelemetry includes built-in multi-tenancy:

```sql
-- Set tenant context
PLTelemetry.set_tenant_context('customer_123', 'ACME Corp');

-- All telemetry automatically tagged with tenant info
l_trace_id := PLTelemetry.start_trace('tenant_operation');

-- Search traces by tenant in Grafana
{.tenant.id="customer_123"}
```

## WoofyMetrics Agent with Pulse Throttling (Recommended)

For high-volume environments, use the included **WoofyMetrics Agent** with intelligent system protection:

```yaml
# config.yaml - WoofyMetrics Agent Configuration
oracle:
  dsn: "${ORACLE_DSN}"
  maxConnections: 10
  maxIdle: 5
  connTimeout: "30s"
  queryTimeout: "60s"
  
otlp:
  endpoint: "${OTLP_ENDPOINT:-http://localhost:4318}"
  timeout: "30s"
  retryCount: 3
  retryDelay: "1s"
  maxBodySize: 1048576  # 1MB
  rateLimit: 1000.0     # requests per second
  rateBurst: 50
  
processing:
  batchSize: 100
  pollInterval: "5s"
  maxErrors: 5
  retryDelay: "30s"
  tenantFilter: ""      # empty = process all tenants
  
agent:
  healthPort: 8080
  logLevel: "info"
  enableDebug: false
  
# Pulse Mode Throttling - Thermal-like CPU/Memory management
throttling:
  enabled: true
  
  # Heat thresholds (0.0 - 1.0)
  pulse1MaxHeat: 0.3    # 30% - enter moderate throttling
  pulse2MaxHeat: 0.5    # 50% - half capacity
  pulse3MaxHeat: 0.7    # 70% - quarter capacity  
  pulse4MaxHeat: 0.9    # 90% - emergency mode
  
  # Heat calculation weights
  cpuWeight: 0.6        # CPU influence (60%)
  memoryWeight: 0.4     # Memory influence (40%)
  
  # Behavior tuning
  heatCheckInterval: "30s"      # Monitor every 30 seconds
  cooldownFactor: 0.95          # 5% heat dissipation per check
  hysteresisMargin: 0.05        # 5% margin prevents flapping
```

### How Pulse Throttling Works

**WoofyMetrics Agent** continuously monitors system resources and automatically adjusts processing:

**Normal Operation** (PULSE1):
- Processes 100 items every 5 seconds
- Full telemetry collection
- Maximum performance

**System Under Load** (PULSE3):
- Reduces to 25 items every 20 seconds
- 50% sampling rate
- Gentler on resources

**Emergency Mode** (COMA):
- Suspends all telemetry processing
- Forces Oracle fallback activation
- Self-metrics only for monitoring

**Example WoofyMetrics Output:**
```
💓 System Pulse Changed from_mode=pulse1 to_mode=pulse3 system_heat=0.72 threshold_exceeded=0.7
🔄 Activating Oracle fallback due to PULSE4 mode - Agent stepping back
🛑 Pulse Throttler stopped
```

### Failover Integration

The pulse system seamlessly integrates with PLTelemetry's failover mechanism:

1. **High System Load**: WoofyMetrics detects CPU/Memory pressure
2. **Automatic Throttling**: Reduces processing to protect system
3. **Emergency Failover**: PULSE4/COMA modes trigger Oracle fallback
4. **Graceful Recovery**: When load decreases, WoofyMetrics resumes control

This ensures your Oracle database is never overwhelmed by telemetry processing.

## Requirements

### Database
- Oracle Database 12c+ (uses native JSON functions)
- Required privileges: `UTL_HTTP`, `CREATE TABLE`, `CREATE PROCEDURE`

### Network
- HTTP access to your OTLP collector (Tempo, Jaeger, etc.)
- Proper ACL configuration for outbound connections

### Grants Setup
```sql
-- Run as DBA
GRANT EXECUTE ON UTL_HTTP TO pltelemetry_user;

-- Network ACL for outbound HTTP
BEGIN
  DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(
    acl => 'pltelemetry_acl.xml',
    description => 'PLTelemetry HTTP access',
    principal => 'PLTELEMETRY_USER',
    is_grant => TRUE,
    privilege => 'connect'
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl => 'pltelemetry_acl.xml',
    host => 'your-tempo-host',
    lower_port => 4318,
    upper_port => 4318
  );
END;
/
```

## Limitations & Honest Assessment

**What PLTelemetry is NOT:**
- Not a replacement for APM tools like DataDog or New Relic
- Not suitable for high-frequency tracing (thousands of traces/second)
- Not a general-purpose observability platform
- PostgreSQL bridge exists in name only (not implemented)

**What PLTelemetry IS:**
- A specialized tool for Oracle/legacy observability
- Lightweight and non-intrusive
- Production-ready for moderate workloads
- Focused on solving specific pain points

**Performance Limitations:**
- Oracle UTL_HTTP is not the fastest HTTP client
- JSON parsing in PL/SQL has overhead  
- Not optimized for extreme high-volume scenarios
- Pulse throttling activates protective measures under load

**Smart Adaptations:**
- Automatically throttles when system is under pressure
- Intelligent failover ensures no data loss
- Pulse system protects Oracle database from being overwhelmed

## Troubleshooting

### Quick Health Check
```sql
-- Verify configuration
SELECT PLTelemetry.get_backend_url() FROM DUAL;

-- Check for errors
SELECT * FROM plt_telemetry_errors WHERE error_time > SYSDATE - 1/24;

-- Queue status (if using async)
SELECT COUNT(*) FROM plt_queue WHERE processed = 'N';
```

### Common Issues

1. **No traces in Grafana**: Check network connectivity and Tempo configuration
2. **Performance issues**: Enable async mode and adjust sampling rates  
3. **System overload**: Check pulse throttling modes - agent may be in COMA mode
4. **ACL errors**: Verify UTL_HTTP grants and network ACL setup
5. **Agent failover**: Check `plt_agent_registry` table for heartbeat status

### Monitoring System Health

```sql
-- Check current pulse mode and system status
SELECT 
    config_key,
    config_value,
    updated_at
FROM plt_failover_config
WHERE config_key IN ('PROCESSING_MODE', 'AGENT_PULSE_MODE');

-- Monitor agent health
SELECT 
    agent_id,
    last_heartbeat,
    status_message,
    items_processed
FROM plt_agent_registry;

-- Check throttling effectiveness
SELECT 
    metric_time,
    batch_size,
    items_processed,
    avg_latency_ms
FROM plt_fallback_metrics
WHERE metric_time > SYSDATE - 1/24;
```

## Contributing

PLTelemetry is open source and welcomes contributions, especially:

- Additional bridges for other observability backends
- Performance optimizations
- Oracle APEX integration
- Better documentation and examples

## License

MIT License - see [LICENSE](LICENSE) file for details.

---

**PLTelemetry** - Simple, honest observability for Oracle environments.

*Not trying to be everything to everyone. Just solving real problems for Oracle shops.*