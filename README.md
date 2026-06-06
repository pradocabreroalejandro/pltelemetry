````md
# PLTelemetry — Oracle PL/SQL OpenTelemetry SDK

Your database is already the **most critical service** in your system.  
Yet, in most observability stacks, it’s still a **black box**.

**PLTelemetry** removes that blind spot.

It is a high-performance, native **PL/SQL OpenTelemetry SDK** designed for enterprise Oracle environments, allowing you to instrument stored procedures, triggers, and jobs **directly from the database layer**, without Java, external runtimes, or performance penalties.

PLTelemetry integrates seamlessly with modern observability platforms such as **Jaeger, Prometheus, Grafana, Datadog, or Dynatrace**, turning Oracle Database into a first-class citizen in distributed tracing and metrics.

---

## 🚀 Key Features

PLTelemetry is built with a **Database-First mindset**: stability, performance, and operational safety come before everything else.

---

## 🛡️ Zero-Dependency Core

- **Pure PL/SQL implementation**  
  No Java in the database. No DLLs. No shared objects. No external binaries.

- **Self-contained by design**  
  All logic lives inside your schema, making it easy to audit, deploy, back up, and version using standard Oracle tooling.

- **Security-friendly**  
  By avoiding external runtimes, PLTelemetry preserves the native security posture of hardened Oracle environments.

---

## ⚡ Asynchronous Architecture (“Fire-and-Forget”)

- **Decoupled instrumentation**  
  Telemetry is enqueued into a high-throughput staging table (`PLT_QUEUE`).  
  Calls to `start_span` or `log` complete in microseconds.

- **Protected critical path**  
  JSON serialization and OTLP network delivery happen asynchronously in background components.  
  Your business transactions stay fast and predictable.

---

## 🔗 Automatic Context Propagation

- **W3C Trace Context compliant**  
  Incoming `traceparent` headers from Node.js, Java, or any OTel-enabled service are automatically continued.

- **Smart auto-instrumentation**  
  Leveraging `UTL_CALL_STACK`, PLTelemetry detects the running package and procedure and auto-populates:
  - `code.namespace`
  - `code.function`

  No manual wiring. No boilerplate.

---

## 🔄 Resilience & Failover

### Hybrid Delivery Model

- **Primary path**  
  An external **Go Agent** (recommended) consumes data from `PLT_QUEUE` with maximum throughput.

- **Failover path**  
  If the agent becomes unavailable, the internal `PLT_FAILOVER_JOB` activates and delivers telemetry using `UTL_HTTP`.

- **Self-healing behaviour**  
  Agent heartbeats are continuously monitored and delivery mode switches automatically to prevent data loss.

---

## 🏢 Multi-Tenant Support

- **SaaS-native by design**  
  Every span, metric, and log entry is tagged with a `tenant_id`.

- **Isolation & routing**  
  Telemetry can be filtered per tenant or routed to different backends without code changes.

---

## 📊 Automated Metric Collectors

- **Database & system metrics**  
  Background jobs collect internal Oracle statistics from:
  - `V$SYSSTAT`
  - `V$SESSION`
  - `V$OSSTAT`

  These are exposed as standard OpenTelemetry metrics.

- **Business metrics**  
  Define custom collectors to convert business data (for example, *orders per minute*) into Prometheus-ready gauges and counters.

---

## 🏗️ Architecture

PLTelemetry follows a strict **Store-and-Forward** pattern to minimise overhead on business transactions.

```mermaid
graph TD
    subgraph "Transaction Boundary (Microseconds)"
        APP[PL/SQL Application] -->|1. start_span / log| SDK[PLTelemetry API]
        SDK -->|2. INSERT (Fast)| Q[PLT_QUEUE Table]
    end
    
    subgraph "Background Processing"
        Q -.->|3a. Bulk Fetch| AGENT[Go Agent (Preferred)]
        Q -.->|3b. Failover Fetch| BRIDGE[PLT_OTLP_BRIDGE]
        JOB[PLT_FAILOVER_JOB] -->|Trigger| BRIDGE
    end

    AGENT -->|4. OTLP gRPC/HTTP| COLLECTOR[OpenTelemetry Collector]
    BRIDGE -->|4. OTLP HTTP| COLLECTOR
    
    COLLECTOR --> JAEGER[Jaeger (Traces)]
    COLLECTOR --> PROM[Prometheus (Metrics)]
````

### Data Flow

* **Instrumentation**
  Application code calls the PLTelemetry API.

* **Ingestion**
  Telemetry is persisted in `PLT_QUEUE`.
  The insert is part of the business transaction: if the transaction rolls back, telemetry is discarded.

* **Export**

  * The Go Agent batches and exports records via OTLP gRPC (preferred).
  * The PL/SQL bridge delivers data via HTTP if the agent is offline.

---

## 📦 Installation

### Prerequisites

* **Database**: Oracle Database 12c R2 or higher (19c / 21c / 23c recommended)
* **Privileges**:
  `CREATE TABLE`, `CREATE PROCEDURE`, `CREATE TYPE`, `CREATE JOB`
* **Network access**:
  OpenTelemetry Collector (default HTTP port `4318`)
* **Optional (SYSDBA)**:
  Required only to collect system-level metrics from `V$` views

---

### Installation Steps

#### 1. Create Types & Tables

```sql
@00_types.sql
@01_tables.sql
```

#### 2. Grant System Permissions (Run as SYS)

```sql
@03_permissions_sys.sql
```

#### 3. Seed Configuration Data

```sql
@02_data.sql
```

#### 4. Deploy Packages

* `PLTelemetry.pks / pkb` — Core SDK & public API
* `PLT_CONFIGURATION.pks / pkb` — High-performance configuration manager
* `PLT_OTLP_BRIDGE.pks / pkb` — Internal HTTP exporter
* `PLT_DB_METRIC_READER.pks / pkb` — Metric extraction
* `PLT_DB_MONITOR_LOGIC.pks / pkb` — Metric orchestration

#### 5. Enable Background Jobs

```sql
@04_jobs.sql
```

---

## ⚙️ Configuration

Configuration is stored in `PLT_SYS_CONFIG` and served via **Oracle Result Cache**, ensuring near-zero overhead even under heavy load.

### Connection Settings

```sql
BEGIN
    PLT_CONFIGURATION.set_param(
        'OTLP', 'ENDPOINT_URL', 'http://otel-collector:4318'
    );

    PLT_CONFIGURATION.set_param(
        'OTLP', 'SERVICE_NAME', 'oracle-db-prod'
    );

    COMMIT;
END;
/
```

---

## ⚙️ Throttling & Sampling (Adaptive Load Control)

Telemetry behaviour is controlled via pulse modes defined in `PLT_PULSE_THROTTLING_CONFIG`.

| Mode   | Behaviour          |
| ------ | ------------------ |
| PULSE1 | 100% sampling      |
| PULSE2 | 75% sampling       |
| PULSE3 | 50% sampling       |
| PULSE4 | 10% sampling       |
| COMA   | Telemetry disabled |

Modes can be switched dynamically without redeploying code.

---

## 💻 Usage Examples

### Distributed Tracing

```plsql
PROCEDURE process_large_order(p_order_id NUMBER) IS
    l_root_span_id VARCHAR2(64);
    l_child_span   VARCHAR2(64);
BEGIN
    l_root_span_id := PLTelemetry.start_span('process_large_order');

    PLTelemetry.attr('order.id', p_order_id);
    PLTelemetry.attr('db.user', USER);
    PLTelemetry.attr('meta.priority', 'HIGH');

    l_child_span := PLTelemetry.start_span('validate_inventory');
    -- complex logic
    PLTelemetry.end_span('OK');

    UPDATE orders SET status = 'PROCESSED' WHERE id = p_order_id;

    PLTelemetry.log(
        'INFO',
        'Order state updated',
        PLTelemetry.attr('old_status', 'NEW'),
        PLTelemetry.attr('new_status', 'PROCESSED')
    );

    PLTelemetry.end_span('OK');
EXCEPTION
    WHEN OTHERS THEN
        PLTelemetry.log(
            'ERROR',
            'Critical failure processing order: ' || SQLERRM
        );
        PLTelemetry.end_span('ERROR', SQLERRM);
        RAISE;
END;
```

---

## 🔍 Monitoring & Troubleshooting

* **Internal SDK errors**

```sql
SELECT *
FROM plt_telemetry_errors
ORDER BY error_time DESC;
```

* **Queue health**

```sql
SELECT status, COUNT(*)
FROM plt_queue
GROUP BY status;
```

* **Failover status**
  Inspect `PLT_AGENT_REGISTRY` to determine whether the system is operating in **PRIMARY** or **FAILOVER** mode.

---

## ❌ Who This Is NOT For

PLTelemetry is intentionally opinionated.

It is **not** designed for:

* Legacy systems with no OpenTelemetry backend
* Applications that rely on `DBMS_OUTPUT` for logging
* Environments where external collectors or agents are not allowed at all
* Teams looking for “quick debug logs” instead of long-term observability

---

## 🤝 Contributing

Contributions are welcome: performance optimisations, new metric collectors, documentation improvements, or architectural discussions.

Open an Issue or submit a Pull Request.

---

## 📄 License

MIT License

```