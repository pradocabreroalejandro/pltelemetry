-- =============================================================================
-- COMPARATIVE PERFORMANCE TESTING GUIDE
-- =============================================================================

SET SERVEROUTPUT ON SIZE 1000000;
SET LINESIZE 200;
SET PAGESIZE 100;

-- 0. Initial cleanup for clean results
EXEC PLT_PERF_SUITE.reset_queue;

PROMPT
PROMPT =========================================================================
PROMPT 🏎️  STARTING SEQUENTIAL TEST ROUND (BASELINE LATENCY)
PROMPT =========================================================================

PROMPT 1. Running LIGHT (Simple metrics)...
EXEC PLT_PERF_SUITE.run_test_session(5000, 'LIGHT');

PROMPT 2. Running STANDARD (Nested traces)...
EXEC PLT_PERF_SUITE.run_test_session(2000, 'STANDARD');

PROMPT 3. Running HEAVY (LOBs and Errors)...
EXEC PLT_PERF_SUITE.run_test_session(1000, 'HEAVY');

PROMPT 4. Running SUPER_HEAVY (Deep Nesting + Loops)...
EXEC PLT_PERF_SUITE.run_test_session(500, 'SUPER_HEAVY');

PROMPT
PROMPT =========================================================================
PROMPT 🏆 FINAL RESULTS (OPS = Operations Per Second)
PROMPT =========================================================================
PROMPT * Higher OPS = Lower overhead for the DB
PROMPT

COL error_message FORMAT A80 HEADING "Execution Detail"
COL error_time FORMAT A25

SELECT to_char(error_time, 'HH24:MI:SS.FF3') as time, error_message 
FROM plt_telemetry_errors 
WHERE module_name = 'PERF_TEST' 
ORDER BY error_time ASC;

PROMPT
PROMPT =========================================================================
PROMPT 📦 VOLUME GENERATED IN QUEUE
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
PROMPT 🔥 FINAL STRESS TEST (CONCURRENT SUPER_HEAVY)
PROMPT =========================================================================
PROMPT Launching 5 simultaneous users in SUPER_HEAVY mode...

BEGIN
    PLT_PERF_SUITE.spawn_load_test(
        p_concurrent_users    => 5,
        p_iterations_per_user => 200, -- 200 x 5 = 1000 monstrous transactions
        p_scenario            => 'SUPER_HEAVY'
    );
END;
/
