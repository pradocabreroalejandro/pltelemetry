-- =============================================================================
-- 03_permissions_sys.sql
-- Permisos de Sistema (Ejecutar como SYS / SYSDBA)
-- =============================================================================
-- NOTA: Ajusta 'PLTELEMETRY' al nombre real de tu usuario/esquema.

-- 1. VISTAS DE RENDIMIENTO (Performance Views)
GRANT SELECT ON V_$SYSMETRIC TO PLTELEMETRY;
GRANT SELECT ON V_$SESSION TO PLTELEMETRY;
GRANT SELECT ON V_$RESOURCE_LIMIT TO PLTELEMETRY;
GRANT SELECT ON DBA_TABLESPACE_USAGE_METRICS TO PLTELEMETRY;
GRANT SELECT ON V_$SYSSTAT TO PLTELEMETRY;
GRANT SELECT ON V_$OSSTAT TO PLTELEMETRY;
GRANT SELECT ON V_$PROCESS TO PLTELEMETRY;
-- Opcional pero útil para metadatos
GRANT SELECT ON V_$INSTANCE TO PLTELEMETRY;
GRANT CREATE JOB TO pltelemetry;
-- Para que pueda matarlos si se vuelven locos
GRANT MANAGE SCHEDULER TO pltelemetry;
GRANT CREATE SYNONYM TO PLTELEMETRY;
-- Opcional, pero ayuda si el CREATE OR REPLACE falla
GRANT DROP ANY SYNONYM TO PLTELEMETRY;

-- 2. ACLs PARA UTL_HTTP (Necesario para el Bridge PL/SQL)
BEGIN
  -- Nota: En Oracle 12c+ usar APPEND_HOST_ACE es la norma.
  -- Asegúrate de que el usuario PLTELEMETRY existe antes de correr esto.
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*', -- En prod, restringe esto a la IP del Collector
    ace  => xs$ace_type(
        privilege_list => xs$name_list('connect', 'resolve'),
        principal_name => 'PLTELEMETRY'
    )
  );
END;
/

PROMPT ✅ Permisos asignados.