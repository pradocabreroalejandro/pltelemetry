-- Conecta como SYS as SYSDBA
ALTER SESSION SET CONTAINER = FREEPDB1; -- Asegúrate de estar en la PDB correcta si usas la imagen free

-- Permisos para V$SYSMETRIC (CPU, Transacciones, AAS)
-- Nota: El objeto real se llama V_$SYSMETRIC (con guion bajo), V$ es un sinónimo.
GRANT SELECT ON V_$SYSMETRIC TO PLTELEMETRY;

-- Permisos para V$SESSION (Sesiones activas/bloqueadas)
GRANT SELECT ON V_$SESSION TO PLTELEMETRY;

-- Permisos para V$RESOURCE_LIMIT (Procesos)
GRANT SELECT ON V_$RESOURCE_LIMIT TO PLTELEMETRY;

-- Permisos para DBA_TABLESPACE_USAGE_METRICS (Espacio)
GRANT SELECT ON DBA_TABLESPACE_USAGE_METRICS TO PLTELEMETRY;

-- Opcional: Si vas a usar V$INSTANCE o V$PARAMETER en el futuro
GRANT SELECT ON V_$INSTANCE TO PLTELEMETRY;
GRANT SELECT ON V_$PARAMETER TO PLTELEMETRY;

-- Ejecutar como SYS
GRANT SELECT ON V_$SYSSTAT TO PLTELEMETRY;
GRANT SELECT ON V_$OSSTAT TO PLTELEMETRY;
GRANT SELECT ON V_$PROCESS TO PLTELEMETRY; -- Para contar procesos reales

BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*',
    ace  => xs$ace_type(
        privilege_list => xs$name_list('connect', 'resolve'),
        principal_name => 'PLTELEMETRY'
        -- Al quitar la línea, asume que es un usuario de BD normal
    )
  );
END;
/