# TODO

> Lista de tareas pendientes para PLTelemetry.

---

## Pendientes

- [ ] **Simplificar la API de telemetría en PL/SQL a 1 línea** — traza, log y métrica deberían poder emitirse idealmente con una sola llamada/procedimiento cada uno.
- [ ] **Auto health-check del esquema PLTelemetry** — métricas internas para monitorizar el propio esquema: uso de tablespace, degradación en `plt_queue`, y otras condiciones de salud. Implementar en el CORE del paquete de métricas de BD o como una versión más ligera del mismo.
- [ ] **Refactorizar y simplificar el código** — reducir complejidad sin perder funcionalidad siempre que sea posible.
- [ ] **Migrar de Docker a Podman** — adaptar el `docker-compose.yml` y las configuraciones para que funcionen con Podman en lugar de Docker.
## En progreso

- [ ] **Script de instalación a prueba de bombas** — crear un template YAML/CFG donde el usuario introduzca los datos necesarios (schemas, tablespaces, endpoints, etc.) y un script que lea ese fichero para realizar una instalación desatendida de PLTelemetry.
- [ ] **Ansible minimalista para provisioning** — playbook para provisionar una VM Oracle Linux 9.6: leer config del usuario, conectar a la VM, crear usuario, instalar Podman, construir imágenes de WoofyMetrics y ejecutar la instalación de PLTelemetry.
- [ ] **Generar releases oficiales de PLTelemetry** — versionado, empaquetado y publicación de releases estables del proyecto.


## Completadas

- [x] *(mover aquí cuando se terminen)*
