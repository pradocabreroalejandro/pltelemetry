SHOW PDBS;

ALTER SESSION SET CONTAINER = FREEPDB1;

SELECT username FROM dba_users WHERE username = 'PLTELEMETRY';

GRANT SELECT_CATALOG_ROLE TO PLTELEMETRY;


GRANT SELECT ON SYS.V_$SESSION TO PLTELEMETRY;
GRANT SELECT ON SYS.V_$SYSMETRIC TO PLTELEMETRY;
GRANT SELECT ON SYS.V_$SGAINFO TO PLTELEMETRY;
GRANT SELECT ON SYS.V_$PGASTAT TO PLTELEMETRY;
GRANT SELECT ON SYS.V_$OSSTAT TO PLTELEMETRY;

GRANT SELECT ON dba_objects TO PLTELEMETRY;

GRANT SELECT ON dba_scheduler_job_run_details TO PLTELEMETRY;

GRANT SELECT ON dba_scheduler_jobs TO PLTELEMETRY;

-- not recommended for production, but useful for testing
-- GRANT SELECT ANY DICTIONARY TO PLTELEMETRY;

SELECT COUNT(*) FROM v$session;

SELECT COUNT(*) FROM v$sysmetric WHERE metric_name = 'Host CPU Utilization (%)';

SELECT COUNT(*) FROM v$sgainfo WHERE name = 'Total SGA Size';


-- Opción 1: v$osstat (más fiable)
SELECT 
    ROUND((busy.value / (busy.value + idle.value)) * 100, 2) as cpu_usage_pct
FROM 
    (SELECT value FROM v$osstat WHERE stat_name = 'BUSY_TIME') busy,
    (SELECT value FROM v$osstat WHERE stat_name = 'IDLE_TIME') idle;

-- Opción 2: v$sysstat 
SELECT 
    ROUND((cpu.value / elapsed.value) * 100, 2) as cpu_usage_pct
FROM 
    (SELECT value FROM v$sysstat WHERE name = 'CPU used by this session') cpu,
    (SELECT value FROM v$sysstat WHERE name = 'DB time') elapsed;

-- Opción 3: Verificar v$metric (vista nueva)
SELECT metric_name, value 
FROM v$metric 
WHERE UPPER(metric_name) LIKE '%CPU%';

-- Opción 4: AWR/ASH alternativo
SELECT *
FROM v$rsrcmgrmetric 
WHERE consumer_group_name = 'SYS_GROUP';


GRANT SELECT ON v_$metric TO pltelemetry;
GRANT SELECT ON v_$session TO pltelemetry;
GRANT SELECT ON v_$sgainfo TO pltelemetry;
GRANT SELECT ON v_$pgastat TO pltelemetry;