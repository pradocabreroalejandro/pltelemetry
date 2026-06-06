# PLTelemetry — Performance & Overhead Whitepaper

## 1. Objective

This document analyses the **runtime overhead and scalability characteristics** of PLTelemetry when instrumenting Oracle Database workloads.

The goal is to answer a simple question:

> *What is the real cost of observability when implemented natively in PL/SQL?*

All measurements focus exclusively on **in-database cost**, independent of external collectors, agents, or networks.

---

## 2. Scope & Non-Goals

### In Scope
- PL/SQL execution overhead
- Span, log, and metric creation cost
- Attribute serialization
- Queue insertion (`PLT_QUEUE`)
- Transaction coupling and commit behaviour
- Behaviour under increasing telemetry complexity
- Sequential and concurrent execution

### Out of Scope
- Go Agent performance
- Network latency
- OpenTelemetry Collector throughput
- Backend systems (Jaeger, Prometheus, etc.)

This document evaluates **only the database-side impact**.

---

## 3. Test Environment

- Execution context: Oracle Database (single instance)
- Instrumentation: Native PL/SQL (PLTelemetry)
- External agents: **disabled**
- Telemetry delivery: enqueue-only (store-and-forward)
- Tests executed entirely inside the database

All tests use a dedicated **PL/SQL benchmark package**:  
`PLT_PERF_SUITE`

---

## 4. Benchmark Design

### 4.1 Design Principles

The benchmark suite was designed to:

- Reflect **realistic usage patterns**
- Cover both typical and pathological cases
- Avoid artificial microbenchmarks
- Stress serialization, not just control flow

Each test scenario executes **fully instrumented code**, including:
- Span lifecycle
- Attribute logging
- Structured logs
- Metrics
- Error paths
- Nested spans
- Large payloads

---

### 4.2 Test Scenarios

| Scenario | Description |
|--------|-------------|
| **LIGHT** | Counters and short logs |
| **STANDARD** | Typical business transaction with nested spans |
| **HEAVY** | Large attributes, error handling, verbose logs |
| **SUPER_HEAVY** | Deep nesting, loops, large payloads, high volume |

All scenarios commit periodically to simulate realistic OLTP behaviour.

---

## 5. Sequential Performance Results

Sequential tests measure **raw per-operation overhead** without concurrency effects.

### 5.1 Results Summary

| Scenario | Iterations | Time (s) | Throughput |
|--------|------------|----------|------------|
| LIGHT | 5,000 | 0.76 | **6,536 ops/s** |
| STANDARD | 2,000 | 0.80 | **2,494 ops/s** |
| HEAVY | 1,000 | 1.04 | **965 ops/s** |
| SUPER_HEAVY | 500 | 1.65 | **304 ops/s** |

### 5.2 Interpretation

- **LIGHT** instrumentation is effectively transparent for most OLTP systems
- **STANDARD** scenarios remain well within acceptable overhead for business logic
- **HEAVY** scenarios show linear degradation proportional to payload size
- **SUPER_HEAVY** represents an upper bound, not a production target

At no point does the overhead grow non-linearly.

---

## 6. Payload Characteristics

The benchmark also measured the **volume and size of telemetry records** enqueued.

### 6.1 Queue Volume Breakdown

| Scenario | Item Type | Records | Avg Size |
|--------|-----------|---------|----------|
| LIGHT | LOG | 4,652 | 160 B |
| LIGHT | METRIC | 4,652 | 177 B |
| STANDARD | LOG | 6,000 | 262 B |
| STANDARD | TRACE | 6,000 | 281 B |
| HEAVY | LOG | 1,811 | ~1 KB |
| HEAVY | TRACE | 1,425 | ~285 B |
| SUPER_HEAVY | LOG | 11,000 | ~945 B |
| SUPER_HEAVY | TRACE | 9,500 | ~292 B |

### 6.2 Observations

- Trace records remain **compact and stable**
- Payload growth is driven almost exclusively by log attributes
- Span structure overhead is bounded and predictable
- Queue growth correlates with **verbosity**, not just transaction count

---

## 7. Concurrency Stress Test

A concurrent stress test executed the most demanding scenario.

### Configuration
- Scenario: SUPER_HEAVY
- Concurrent users: 5
- Iterations per user: 200
- Total executions: 1,000

### Outcome
- No blocking observed
- No error propagation to business logic
- All telemetry successfully enqueued
- Database stability preserved throughout execution

This validates PLTelemetry’s **constant-time enqueue design** under concurrency.

---

## 8. Architectural Implications

The observed performance characteristics confirm several design assumptions:

- Queue insertion cost is **bounded and predictable**
- Telemetry overhead scales **linearly with complexity**
- No synchronous I/O is introduced into business logic
- Failure scenarios remain isolated from application code

PLTelemetry behaves as **infrastructure**, not application logic.

---

## 9. Performance Model

From the measurements, the cost model can be summarised as:

