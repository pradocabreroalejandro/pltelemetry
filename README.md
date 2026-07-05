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
  Telemetry is enqueued into a high-throughput **partitioned staging queue**:
  `plt_queue_writer` (synonym → active partition) writes into `plt_queue_01` /
  `plt_queue_02`, swapped by `PLT_QUEUE_MAINTENANCE_JOB`. The agent and bridge
  read from the `plt_queue_reader` view (UNION of both partitions).
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
  An external **Go Agent** ([woofy-metrics](../woofy-metrics)) consumes data from the queue via OTLP **HTTP** (`POST /v1/{metrics,traces,logs}` on port `4318`) with maximum throughput.

- **Failover path**  
  If the agent becomes unavailable, the internal `PLT_FAILOVER_JOB` activates and delivers telemetry using `UTL_HTTP` via `PLT_OTLP_BRIDGE` (batched, 1 POST / 500 items).

- **Self-healing behaviour**  
  The agent writes a heartbeat row to `plt_agent_registry` (`agent_id = 'PRIMARY'`) on every poll cycle. `PLT_HEALTH_MONITOR` checks it via `PLTelemetry.is_agent_healthy`, which treats a heartbeat older than **45 seconds** (≈3 missed beats at the default 15s cadence) as stale and enables `PLT_FAILOVER_JOB`. When the agent resumes heartbeats, the fallback is disabled automatically — preventing data loss without manual intervention.

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
        SDK -->|2. INSERT (Fast)| Q[plt_queue_writer → plt_queue_01/02]
    end
    
    subgraph "Background Processing"
        Q -.->|3a. Bulk Fetch via plt_queue_reader| AGENT[Go Agent (Preferred)]
        Q -.->|3b. Failover Fetch| BRIDGE[PLT_OTLP_BRIDGE]
        JOB[PLT_FAILOVER_JOB] -->|Trigger| BRIDGE
    end

    AGENT -->|4. OTLP HTTP| COLLECTOR[OpenTelemetry Collector]
    BRIDGE -->|4. OTLP HTTP| COLLECTOR
    
    COLLECTOR --> JAEGER[Jaeger / Tempo (Traces)]
    COLLECTOR --> PROM[Prometheus (Metrics)]
    COLLECTOR --> LOKI[Loki (Logs)]
```

### Data Flow

* **Instrumentation**
  Application code calls the PLTelemetry API.

* **Ingestion**
  Telemetry is persisted in the queue via `plt_queue_writer` (the active
  partition). The insert is part of the business transaction: if the
  transaction rolls back, telemetry is discarded.

* **Export**

  * The Go Agent exports records via **OTLP HTTP** (one POST per item to the collector's `/v1/{signal}` endpoints).
  * The PL/SQL bridge delivers data via **HTTP** (`UTL_HTTP`) if the agent is offline.

---

## 📦 Installation

### Prerequisites

* **Database**: Oracle Database 12c R2 or higher (19c / 21c / 23c / 23ai recommended; tested on 23ai Free)
* **Privileges**:
  `CREATE TABLE`, `CREATE PROCEDURE`, `CREATE TYPE`, `CREATE JOB`
* **Network access**:
  OpenTelemetry Collector (default HTTP port `4318`)
* **Optional (SYSDBA)**:
  Required only to collect system-level metrics from `V$` views

### Installer

An automated installer is provided:

```bash
python3 install.py            # uses install.yaml
# or edit install_template.yaml and point install.py at it
```

### Manual Installation Steps

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
* `PLT_CONFIGURATION.pks / pkb` — High-performance configuration manager (Oracle Result Cache)
* `PLT_OTLP_BRIDGE.pks / pkb` — Internal HTTP exporter (failover path)
* `PLT_ACTIVATION_MANAGER.pks / pkb` — Sampling / activation rules
* `PLT_QUEUE_MANAGER.pks / pkb` — Queue lifecycle (partition swap, cleanup)
* `PLT_DB_METRIC_READER.pks / pkb` — Metric extraction
* `PLT_DB_MONITOR_LOGIC.pks / pkb` — Metric orchestration
* `check_agent_health_proc.sql` — Agent-health check procedure

#### 5. Enable Background Jobs

```sql
@04_jobs.sql
```

#### 6. Queue Partitioning & Maintenance

```sql
@06_queue_config.sql
@07_queue_maintenace_job.sql
```

---

## ⚙️ Configuration

Configuration is stored in `PLT_SYS_CONFIG` (columns `CONFIG_GROUP`, `CONFIG_KEY`, `CONFIG_VALUE`) and served via **Oracle Result Cache**, ensuring near-zero overhead even under heavy load. The result cache is invalidated automatically on commit.

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

Telemetry behaviour is controlled via pulse modes defined in `PLT_PULSE_THROTTLING_CONFIG` (per-tenant, `GLOBAL` by default). Each mode sets a capacity multiplier (agent processing capacity), a batch multiplier, a poll-interval multiplier, and a sampling rate.

| Mode   | Capacity | Sampling | Behaviour                |
| ------ | -------- | -------- | ------------------------ |
| PULSE1 | 100%     | 100%     | Full speed — no throttling |
| PULSE2 | 50%      | 75%      | Moderate load             |
| PULSE3 | 25%      | 50%      | High load                 |
| PULSE4 | 10%      | 10%      | Critical load             |
| COMA   | 0%       | 0%       | System overload — hibernation (telemetry disabled) |

Modes can be switched dynamically without redeploying code.

---

## 💻 Usage Examples

See `docs/PLTelemetry_examples.sql` and `docs/OTLP_Bridge_examples.sql` for
more. A minimal distributed-tracing example:

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

## 🧪 Tests & Utilities

`src/utils/` contains diagnostic and benchmark tooling (run from sqlplus):

| File | Purpose |
|------|---------|
| `PLT_SMOKE_TEST.sql` | End-to-end smoke test: logs/metrics/traces, attrs, severity levels, tenant isolation, W3C context, export via `process_queue`, collector reachable. |
| `PLT_TPS_TEST.sql` | Throughput benchmark: per-signal TPS (LOG/METRIC/TRACE), OTLP/HTTP export TPS, concurrent scheduler-job TPS; reports min/max/avg + µs/op. |
| `PLT_PERF_SUITE.pks / .pkb` + `plt_perf_suite_run.sql` | In-database performance suite. |
| `PLT_DIAGNOSTIC.sql` | Health / configuration diagnostics. |
| `PLT_ENABLE_TRACING.sql` | Enable / disable tracing. |

For the runtime overhead analysis, see **[PERFORMANCE.md](PERFORMANCE.md)**.

The Go-agent side (smoke + TPS tests, measured throughput) is documented in
[woofy-metrics/README.md](../woofy-metrics/README.md).

---

## 🔍 Monitoring & Troubleshooting

* **Internal SDK errors**

```sql
SELECT *
FROM plt_telemetry_errors
ORDER BY error_time DESC;
```

* **Queue health** (read through the view that UNIONs both partitions)

```sql
SELECT status, COUNT(*)
FROM plt_queue_reader
GROUP BY status;
```

* **Active partition / queue registry**

```sql
SELECT * FROM plt_queue_registry;
```

* **Failover status**
  Inspect `plt_agent_registry` to determine whether the system is operating in
  **PRIMARY** (agent healthy) or **FAILOVER** (agent stale) mode:

```sql
SELECT agent_id, last_heartbeat, pulse_mode, status_message, items_processed
FROM plt_agent_registry
WHERE agent_id = 'PRIMARY';

SELECT PLTelemetry.is_agent_healthy AS agent_healthy FROM dual;

SELECT job_name, enabled, state, last_start_date, next_run_date
FROM user_scheduler_jobs
WHERE job_name IN ('PLT_HEALTH_MONITOR', 'PLT_FAILOVER_JOB');
```

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

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions are welcome: performance
optimisations, new metric collectors, documentation improvements, or
architectural discussions.

Open an Issue or submit a Pull Request.

---

## 📄 License

MIT License