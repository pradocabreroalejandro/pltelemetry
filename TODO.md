# TODO

> Pending tasks for PLTelemetry.

---

## Pending

- [ ] **Simplify the PL/SQL telemetry API to 1 line** — trace, log, and metric should ideally be emitted with a single call/procedure each.
- [ ] **Auto health-check of the PLTelemetry schema** — internal metrics to monitor the schema itself: tablespace usage, degradation in `plt_queue`, and other health conditions. Implement in the CORE of the DB metrics package or as a lighter version of it.
- [ ] **Refactor and simplify the code** — reduce complexity without losing functionality whenever possible.

## In Progress

- [ ] **Bulletproof installation script** — create a YAML/CFG template where the user enters the necessary data (schemas, tablespaces, endpoints, etc.) and a script that reads that file to perform an unattended installation of PLTelemetry.
- [ ] **Minimalist Ansible for provisioning** — playbook to provision an Oracle Linux 9.6 VM: read user config, connect to the VM, create user, install Podman, build WoofyMetrics images, and run the PLTelemetry installation.
- [ ] **Generate official PLTelemetry releases** — versioning, packaging, and publishing stable project releases.


## Completed

- [x] **Migrate from Docker to Podman** — the observability stack now runs with `podman-compose.yml` (see `docker/README-PODMAN.md`); `docker-compose.yml` was removed.
