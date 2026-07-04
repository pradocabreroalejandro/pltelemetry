# PLTelemetry — Podman Stack

## Quick Start

```bash
# Start the observability stack
cd docker
podman-compose -f podman-compose.yml up -d

# Check status
podman ps

# Stop the stack
podman-compose -f podman-compose.yml down
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     HOST (Podman rootless)                    │
│                                                               │
│  ┌──────────────┐    ┌──────────────────────────────────────┐ │
│  │  oracle23ai   │    │  pltelemetry-network (172.22.0.0/16) │ │
│  │  (slirp4netns)│    │                                      │ │
│  │  Volume:      │    │  ┌──────────┐  ┌──────────┐         │ │
│  │  oracle23ai-  │    │  │  tempo   │  │  loki    │         │ │
│  │  data         │    │  │  :3200   │  │  :3100   │         │ │
│  │  (READ ONLY!) │    │  └────┬─────┘  └────┬─────┘         │ │
│  │               │    │       │              │               │ │
│  │  Connects to  │    │  ┌────┴──────────────┴─────┐        │ │
│  │  collector via│    │  │   otel-collector        │        │ │
│  │  host IP:     │    │  │   :4317 (gRPC)          │        │ │
│  │  192.168.x.x: │    │  │   :4318 (HTTP) ← PL/SQL │        │ │
│  │  4318         │    │  └────┬────────────────────┘        │ │
│  └──────────────┘    │       │                             │ │
│       │              │  ┌────┴─────┐  ┌──────────┐         │ │
│       │              │  │prometheus│  │ grafana  │         │ │
│       │              │  │  :9090   │  │  :3020   │         │ │
│       │              │  └──────────┘  └──────────┘         │ │
│       │              │  ┌──────────┐                       │ │
│       │              │  │ mailhog  │                       │ │
│       │              │  │ :1025    │                       │ │
│       │              │  │ :8025    │                       │ │
│       │              │  └──────────┘                       │ │
│       │              └──────────────────────────────────────┘ │
│       │                                                       │
│       └────────────── 192.168.x.x:4318 ──────────────────────┘
│                       (host IP)
└─────────────────────────────────────────────────────────────┘
```

## Containers

| Container          | Image                          | Port  | Purpose              |
|--------------------|--------------------------------|-------|----------------------|
| `plt-otel-collector` | otel/opentelemetry-collector | 4318  | OTLP HTTP receiver   |
| `plt-tempo`        | grafana/tempo                  | 3200  | Trace storage        |
| `plt-loki`         | grafana/loki                   | 3100  | Log storage          |
| `plt-prometheus`   | prom/prometheus                | 9090  | Metric storage       |
| `plt-grafana`      | grafana/grafana                | 3020  | Visualization        |
| `plt-mailhog`      | mailhog/mailhog                | 8025  | Email testing        |
| `oracle23ai`       | oriolrt/oracle-23ai            | 1521  | Database (external)  |

## Persistent Volumes

| Volume               | Container     | Mount path        |
|----------------------|---------------|-------------------|
| `plt_grafana-data`   | plt-grafana   | /var/lib/grafana  |
| `plt_prometheus-data`| plt-prometheus| /prometheus       |
| `plt_loki-data`      | plt-loki      | /loki             |
| `plt_tempo-data`     | plt-tempo     | /var/tempo        |
| `oracle23ai-data`    | oracle23ai    | /opt/oracle/oradata (**DO NOT DELETE**) |

## Oracle → Collector Connectivity

The Oracle container runs with `slirp4netns` networking (rootless), which means it
**cannot** join the `pltelemetry-network` bridge. Instead, it reaches the collector
via the **host IP**:

```sql
-- In Oracle, configure the endpoint to use your host IP:
BEGIN
    PLT_CONFIGURATION.set_param(
        'OTLP', 'ENDPOINT_URL',
        'http://192.168.100.135:4318'
    );
    COMMIT;
END;
/
```

To find your host IP:
```bash
hostname -I | awk '{print $1}'
```

## Config Files

All configs live in `docker/configs/`:

- `otel-collector-config.yaml` — Collector pipelines (traces → Tempo, metrics → Prometheus, logs → Loki)
- `tempo.yaml` — Tempo trace storage
- `loki.yaml` — Loki log storage (schema v13 + tsdb for OTLP)
- `prometheus.yml` — Prometheus scrape targets

## Notes

- The `loki` exporter was removed in recent OTel Collector versions.
  Logs are now sent via `otlphttp/loki` to Loki's native OTLP endpoint (`/otlp`).
- Tempo v3 removed legacy `overrides` format. Limits are set to defaults.
- `host.docker.internal` was replaced with `host.containers.internal` (Podman equivalent).
- The Oracle volume (`oracle23ai-data`) is managed externally and is **never** touched
  by this compose file.