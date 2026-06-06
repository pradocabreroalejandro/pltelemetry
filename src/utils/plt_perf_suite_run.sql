-- =============================================================================
-- GUÍA DE PRUEBAS DE RENDIMIENTO COMPARATIVAS
-- =============================================================================

SET SERVEROUTPUT ON SIZE 1000000;
SET LINESIZE 200;
SET PAGESIZE 100;

-- 0. Limpieza inicial para resultados puros
EXEC PLT_PERF_SUITE.reset_queue;

PROMPT
PROMPT =========================================================================
PROMPT 🏎️  INICIANDO RONDA DE PRUEBAS SECUENCIALES (LATENCIA BASE)
PROMPT =========================================================================

PROMPT 1. Ejecutando LIGHT (Métricas simples)...
EXEC PLT_PERF_SUITE.run_test_session(5000, 'LIGHT');

PROMPT 2. Ejecutando STANDARD (Trazas anidadas)...
EXEC PLT_PERF_SUITE.run_test_session(2000, 'STANDARD');

PROMPT 3. Ejecutando HEAVY (LOBs y Errores)...
EXEC PLT_PERF_SUITE.run_test_session(1000, 'HEAVY');

PROMPT 4. Ejecutando SUPER_HEAVY (Deep Nesting + Loops)...
EXEC PLT_PERF_SUITE.run_test_session(500, 'SUPER_HEAVY');

PROMPT
PROMPT =========================================================================
PROMPT 🏆 RESULTADOS FINALES (OPS = Operaciones Por Segundo)
PROMPT =========================================================================
PROMPT * OPS más alto = Menor sobrecarga para la BD
PROMPT

COL error_message FORMAT A80 HEADING "Detalle de Ejecución"
COL error_time FORMAT A25

SELECT to_char(error_time, 'HH24:MI:SS.FF3') as hora, error_message 
FROM plt_telemetry_errors 
WHERE module_name = 'PERF_TEST' 
ORDER BY error_time ASC;

PROMPT
PROMPT =========================================================================
PROMPT 📦 VOLUMEN GENERADO EN COLA
PROMPT =========================================================================

SELECT 
    tenant_id, 
    item_type, 
    count(*) as total_items, 
    round(avg(sys.dbms_lob.getlength(payload)),0) as avg_bytes
FROM plt_queue
WHERE tenant_id LIKE 'PERF_%'
GROUP BY tenant_id, item_type
ORDER BY tenant_id, item_type;

PROMPT
PROMPT =========================================================================
PROMPT 🔥 PRUEBA DE ESTRÉS FINAL (SUPER_HEAVY CONCURRENTE)
PROMPT =========================================================================
PROMPT Lanzando 5 usuarios simultáneos en modo SUPER_HEAVY...

BEGIN
    PLT_PERF_SUITE.spawn_load_test(
        p_concurrent_users    => 5,
        p_iterations_per_user => 200, -- 200 x 5 = 1000 transacciones monstruosas
        p_scenario            => 'SUPER_HEAVY'
    );
END;
/