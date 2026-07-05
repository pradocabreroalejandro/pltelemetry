-- =============================================================================
-- PLT_TPS_TEST.sql — Throughput (TPS) Benchmark Suite
-- =============================================================================
-- Measures min / max / avg TPS for the three telemetry signals (logs, metrics,
-- traces) across three stages:
--
--   PHASE 1: Sequential enqueue TPS per signal (pure PL/SQL producer cost)
--   PHASE 2: Export TPS (process_queue -> OTLP collector over HTTP)
--   PHASE 3: Concurrent enqueue TPS (N scheduler jobs hammering the queue)
--
-- Method: each phase runs in fixed-size batches; each batch's elapsed time
-- yields one TPS sample. Min/max/avg are computed across samples.
--
-- Run as: sqlplus PLTELEMETRY/plt@//localhost:1521/FREEPDB1 @PLT_TPS_TEST.sql
-- WARNING: truncates plt_queue_01/02 (development environments only).
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET LINESIZE 200;
SET PAGESIZE 100;
SET DEFINE OFF;
SET TIMING ON;

PROMPT
PROMPT =========================================================================
PROMPT PLTELEMETRY TPS BENCHMARK SUITE
PROMPT =========================================================================
PROMPT

-- Results table for the concurrent phase (must exist before the package
-- compiles: job_worker references it statically). Dropped at the end.
BEGIN EXECUTE IMMEDIATE 'DROP TABLE plt_tps_results PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE plt_tps_results (
    job_id     NUMBER,
    batch_no   NUMBER,
    ops        NUMBER,
    elapsed_s  NUMBER,
    tps        NUMBER,
    started_at TIMESTAMP,
    ended_at   TIMESTAMP
);

CREATE OR REPLACE PACKAGE PLT_TPS_TEST AS
    PROCEDURE run_all;
    -- Public: invoked by the scheduler jobs of the concurrent phase
    PROCEDURE job_worker(p_job_id NUMBER, p_batches PLS_INTEGER, p_iters_per_batch PLS_INTEGER);
END PLT_TPS_TEST;
/

CREATE OR REPLACE PACKAGE BODY PLT_TPS_TEST AS

    -- =========================================================================
    -- TUNING KNOBS
    -- =========================================================================
    c_tenant            CONSTANT VARCHAR2(30) := 'TPS_TEST';

    -- Phase 1: sequential enqueue (per signal)
    c_seq_batches       CONSTANT PLS_INTEGER := 10;
    c_seq_ops_log       CONSTANT PLS_INTEGER := 1000;  -- logs per batch
    c_seq_ops_metric    CONSTANT PLS_INTEGER := 1000;  -- metrics per batch
    c_seq_ops_trace     CONSTANT PLS_INTEGER := 500;   -- spans per batch (start+end)

    -- Phase 2: export (HTTP-bound, keep volume moderate)
    c_exp_items_per_sig CONSTANT PLS_INTEGER := 500;   -- items per signal to export
    c_exp_batch_size    CONSTANT PLS_INTEGER := 250;   -- process_queue batch size
    c_exp_max_rounds    CONSTANT PLS_INTEGER := 60;    -- safety stop

    -- Phase 3: concurrent enqueue
    c_conc_jobs         CONSTANT PLS_INTEGER := 4;
    c_conc_batches      CONSTANT PLS_INTEGER := 5;
    c_conc_iters        CONSTANT PLS_INTEGER := 300;   -- iterations per batch
                                                       -- (1 iter = 1 log + 1 metric + 1 span = 3 ops)
    c_conc_timeout_s    CONSTANT PLS_INTEGER := 180;

    TYPE t_num_tab IS TABLE OF NUMBER;

    -- Rolled-up figures for the final summary
    g_summary_lines t_num_tab := t_num_tab();
    TYPE t_str_tab IS TABLE OF VARCHAR2(200);
    g_summary_text t_str_tab := t_str_tab();

    -- =========================================================================
    -- HELPERS
    -- =========================================================================
    FUNCTION elapsed_s(p_from TIMESTAMP, p_to TIMESTAMP) RETURN NUMBER IS
        l_iv INTERVAL DAY TO SECOND := p_to - p_from;
    BEGIN
        RETURN EXTRACT(DAY FROM l_iv) * 86400
             + EXTRACT(HOUR FROM l_iv) * 3600
             + EXTRACT(MINUTE FROM l_iv) * 60
             + EXTRACT(SECOND FROM l_iv);
    END;

    PROCEDURE section(p_title VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(CHR(10) || '--- ' || p_title || ' ---');
    END;

    FUNCTION fmt(p_n NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(ROUND(p_n, 1), 'FM9999990.0');
    END;

    -- Prints min/max/avg over the TPS samples and stores a summary line
    PROCEDURE report_stats(
        p_label       VARCHAR2,
        p_samples     t_num_tab,
        p_total_ops   NUMBER,
        p_total_secs  NUMBER
    ) IS
        l_min NUMBER := NULL;
        l_max NUMBER := NULL;
        l_sum NUMBER := 0;
        l_avg NUMBER;
        l_overall NUMBER;
    BEGIN
        FOR i IN 1..p_samples.COUNT LOOP
            l_sum := l_sum + p_samples(i);
            IF l_min IS NULL OR p_samples(i) < l_min THEN l_min := p_samples(i); END IF;
            IF l_max IS NULL OR p_samples(i) > l_max THEN l_max := p_samples(i); END IF;
        END LOOP;
        l_avg     := l_sum / GREATEST(p_samples.COUNT, 1);
        l_overall := p_total_ops / GREATEST(p_total_secs, 0.001);

        DBMS_OUTPUT.PUT_LINE(
            '  ' || RPAD(p_label, 22)
            || ' | ops='     || LPAD(p_total_ops, 7)
            || ' | time='    || LPAD(fmt(p_total_secs), 8) || 's'
            || ' | TPS min=' || LPAD(fmt(l_min), 9)
            || ' | avg='     || LPAD(fmt(l_avg), 9)
            || ' | max='     || LPAD(fmt(l_max), 9)
            || ' | us/op='   || LPAD(fmt(p_total_secs * 1000000 / GREATEST(p_total_ops, 1)), 8));

        g_summary_text.EXTEND;
        g_summary_text(g_summary_text.COUNT) :=
            RPAD(p_label, 22)
            || ' | TPS min=' || LPAD(fmt(l_min), 9)
            || ' | avg='     || LPAD(fmt(l_avg), 9)
            || ' | max='     || LPAD(fmt(l_max), 9);
    END;

    PROCEDURE truncate_queues IS
    BEGIN
        BEGIN EXECUTE IMMEDIATE 'TRUNCATE TABLE plt_queue_01'; EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN EXECUTE IMMEDIATE 'TRUNCATE TABLE plt_queue_02'; EXCEPTION WHEN OTHERS THEN NULL; END;
    END;

    -- =========================================================================
    -- SIGNAL EMITTERS (one op each)
    -- =========================================================================
    PROCEDURE emit_log(p_i PLS_INTEGER) IS
    BEGIN
        PLTelemetry.log('INFO', 'TPS bench log #' || p_i,
            p_attrs_json => '{"bench":"tps","seq":"' || p_i || '"}',
            p_tenant_id  => c_tenant);
    END;

    PROCEDURE emit_metric(p_i PLS_INTEGER) IS
    BEGIN
        PLTelemetry.log_metric('tps.bench.gauge', MOD(p_i, 100),
            p_type      => PLTelemetry.c_metric_gauge,
            p_unit      => 'ops',
            p_tenant_id => c_tenant);
    END;

    PROCEDURE emit_trace IS
    BEGIN
        PLTelemetry.start_span('tps_bench_span', p_tenant => c_tenant);
        PLTelemetry.end_span('OK');
    END;

    -- =========================================================================
    -- PHASE 1: SEQUENTIAL ENQUEUE TPS (per signal)
    -- =========================================================================
    PROCEDURE run_seq_signal(
        p_label   VARCHAR2,
        p_signal  VARCHAR2,
        p_batches PLS_INTEGER,
        p_ops     PLS_INTEGER
    ) IS
        l_samples t_num_tab := t_num_tab();
        l_t0      TIMESTAMP;
        l_t1      TIMESTAMP;
        l_secs    NUMBER;
        l_total_s NUMBER := 0;
    BEGIN
        PLTelemetry.reset_context;
        FOR b IN 1..p_batches LOOP
            l_t0 := SYSTIMESTAMP;
            FOR i IN 1..p_ops LOOP
                CASE p_signal
                    WHEN 'LOG'    THEN emit_log(i);
                    WHEN 'METRIC' THEN emit_metric(i);
                    WHEN 'TRACE'  THEN emit_trace;
                END CASE;
            END LOOP;
            COMMIT;
            l_t1   := SYSTIMESTAMP;
            l_secs := GREATEST(elapsed_s(l_t0, l_t1), 0.001);
            l_total_s := l_total_s + l_secs;
            l_samples.EXTEND;
            l_samples(l_samples.COUNT) := p_ops / l_secs;
        END LOOP;
        report_stats(p_label, l_samples, p_batches * p_ops, l_total_s);
    END;

    PROCEDURE phase_1_sequential IS
    BEGIN
        section('PHASE 1: Sequential Enqueue TPS (' || c_seq_batches || ' batches per signal)');
        run_seq_signal('LOGS   (enqueue)', 'LOG',    c_seq_batches, c_seq_ops_log);
        run_seq_signal('METRICS(enqueue)', 'METRIC', c_seq_batches, c_seq_ops_metric);
        run_seq_signal('TRACES (enqueue)', 'TRACE',  c_seq_batches, c_seq_ops_trace);
    END;

    -- =========================================================================
    -- PHASE 2: EXPORT TPS (process_queue -> collector)
    -- =========================================================================
    PROCEDURE phase_2_export IS
        l_samples   t_num_tab := t_num_tab();
        l_t0        TIMESTAMP;
        l_t1        TIMESTAMP;
        l_secs      NUMBER;
        l_total_s   NUMBER := 0;
        l_new       NUMBER;
        l_before    NUMBER;
        l_processed NUMBER;
        l_failed    NUMBER;
        l_rounds    PLS_INTEGER := 0;
        l_total_out NUMBER := 0;
    BEGIN
        section('PHASE 2: Export TPS via process_queue (batch=' || c_exp_batch_size || ')');

        -- Controlled dataset: equal parts logs / metrics / traces
        truncate_queues;
        PLTelemetry.reset_context;
        FOR i IN 1..c_exp_items_per_sig LOOP
            emit_log(i);
            emit_metric(i);
            emit_trace;
        END LOOP;
        COMMIT;

        SELECT COUNT(*) INTO l_new FROM plt_queue_reader WHERE status = 'NEW';
        DBMS_OUTPUT.PUT_LINE('  Items to export: ' || l_new);

        PLT_OTLP_BRIDGE.set_debug(FALSE);

        WHILE l_new > 0 AND l_rounds < c_exp_max_rounds LOOP
            l_rounds := l_rounds + 1;
            l_before := l_new;

            l_t0 := SYSTIMESTAMP;
            PLTelemetry.process_queue(p_batch_size => c_exp_batch_size);
            l_t1 := SYSTIMESTAMP;

            SELECT COUNT(*) INTO l_new FROM plt_queue_reader WHERE status = 'NEW';
            l_secs := GREATEST(elapsed_s(l_t0, l_t1), 0.001);

            IF l_before - l_new > 0 THEN
                l_total_s   := l_total_s + l_secs;
                l_total_out := l_total_out + (l_before - l_new);
                l_samples.EXTEND;
                l_samples(l_samples.COUNT) := (l_before - l_new) / l_secs;
            ELSE
                EXIT; -- nothing moved: avoid spinning on stuck items
            END IF;
        END LOOP;

        SELECT COUNT(*) INTO l_processed FROM plt_queue_reader WHERE status = 'PROCESSED';
        SELECT COUNT(*) INTO l_failed    FROM plt_queue_reader WHERE status = 'FAILED';
        DBMS_OUTPUT.PUT_LINE('  Rounds=' || l_rounds || ' Processed=' || l_processed
                             || ' Failed=' || l_failed || ' Remaining NEW=' || l_new);

        IF l_samples.COUNT > 0 THEN
            report_stats('EXPORT (OTLP/HTTP)', l_samples, l_total_out, l_total_s);
        ELSE
            DBMS_OUTPUT.PUT_LINE('  WARNING: no items exported, check collector/bridge.');
        END IF;
    END;

    -- =========================================================================
    -- PHASE 3: CONCURRENT ENQUEUE TPS (scheduler jobs)
    -- =========================================================================
    PROCEDURE job_worker(p_job_id NUMBER, p_batches PLS_INTEGER, p_iters_per_batch PLS_INTEGER) IS
        l_t0   TIMESTAMP;
        l_t1   TIMESTAMP;
        l_secs NUMBER;
    BEGIN
        PLTelemetry.reset_context;
        FOR b IN 1..p_batches LOOP
            l_t0 := SYSTIMESTAMP;
            FOR i IN 1..p_iters_per_batch LOOP
                emit_log(i);
                emit_metric(i);
                emit_trace;
            END LOOP;
            COMMIT;
            l_t1   := SYSTIMESTAMP;
            l_secs := GREATEST(elapsed_s(l_t0, l_t1), 0.001);

            INSERT INTO plt_tps_results (job_id, batch_no, ops, elapsed_s, tps, started_at, ended_at)
            VALUES (p_job_id, b, p_iters_per_batch * 3, l_secs,
                    (p_iters_per_batch * 3) / l_secs, l_t0, l_t1);
            COMMIT;
        END LOOP;
    END;

    PROCEDURE phase_3_concurrent IS
        l_samples   t_num_tab := t_num_tab();
        l_pending   NUMBER;
        l_waited    PLS_INTEGER := 0;
        l_jobs_done NUMBER;
        l_total_ops NUMBER;
        l_wall_s    NUMBER;
        l_min_tps   NUMBER;
        l_max_tps   NUMBER;
        l_avg_tps   NUMBER;
    BEGIN
        section('PHASE 3: Concurrent Enqueue TPS (' || c_conc_jobs || ' jobs x '
                || c_conc_batches || ' batches x ' || c_conc_iters || ' iters x 3 signals)');

        DELETE FROM plt_tps_results;
        COMMIT;

        FOR j IN (SELECT job_name FROM user_scheduler_jobs WHERE job_name LIKE 'PLT_TPS_JOB_%') LOOP
            BEGIN DBMS_SCHEDULER.DROP_JOB(j.job_name, force => TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        END LOOP;

        FOR i IN 1..c_conc_jobs LOOP
            DBMS_SCHEDULER.CREATE_JOB(
                job_name   => 'PLT_TPS_JOB_' || i,
                job_type   => 'PLSQL_BLOCK',
                job_action => 'BEGIN PLT_TPS_TEST.job_worker(' || i || ', '
                              || c_conc_batches || ', ' || c_conc_iters || '); END;',
                enabled    => TRUE,
                auto_drop  => TRUE,
                comments   => 'TPS benchmark worker ' || i);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('  Launched ' || c_conc_jobs || ' workers, waiting...');

        LOOP
            SELECT COUNT(*) INTO l_pending
              FROM user_scheduler_jobs WHERE job_name LIKE 'PLT_TPS_JOB_%';
            EXIT WHEN l_pending = 0 OR l_waited >= c_conc_timeout_s;
            DBMS_SESSION.SLEEP(1);
            l_waited := l_waited + 1;
        END LOOP;

        SELECT COUNT(DISTINCT job_id) INTO l_jobs_done FROM plt_tps_results;
        DBMS_OUTPUT.PUT_LINE('  Workers finished: ' || l_jobs_done || '/' || c_conc_jobs
                             || ' (waited ' || l_waited || 's)');

        IF l_jobs_done = 0 THEN
            DBMS_OUTPUT.PUT_LINE('  WARNING: no worker results, skipping stats.');
            RETURN;
        END IF;

        -- Per-batch TPS stats across all workers (per-session speed)
        SELECT MIN(tps), MAX(tps), AVG(tps), SUM(ops)
          INTO l_min_tps, l_max_tps, l_avg_tps, l_total_ops
          FROM plt_tps_results;

        -- Aggregate throughput: total ops over the wall-clock window
        DECLARE
            l_first TIMESTAMP;
            l_last  TIMESTAMP;
        BEGIN
            SELECT MIN(started_at), MAX(ended_at) INTO l_first, l_last FROM plt_tps_results;
            l_wall_s := GREATEST(elapsed_s(l_first, l_last), 0.001);
        END;

        DBMS_OUTPUT.PUT_LINE(
            '  ' || RPAD('CONCURRENT (per-job)', 22)
            || ' | ops='     || LPAD(l_total_ops, 7)
            || ' | wall='    || LPAD(fmt(l_wall_s), 8) || 's'
            || ' | TPS min=' || LPAD(fmt(l_min_tps), 9)
            || ' | avg='     || LPAD(fmt(l_avg_tps), 9)
            || ' | max='     || LPAD(fmt(l_max_tps), 9));
        DBMS_OUTPUT.PUT_LINE(
            '  ' || RPAD('CONCURRENT (combined)', 22)
            || ' | aggregate TPS=' || fmt(l_total_ops / l_wall_s)
            || ' (' || c_conc_jobs || ' sessions)');

        g_summary_text.EXTEND;
        g_summary_text(g_summary_text.COUNT) :=
            RPAD('CONCURRENT x' || c_conc_jobs, 22)
            || ' | TPS min=' || LPAD(fmt(l_min_tps), 9)
            || ' | avg='     || LPAD(fmt(l_avg_tps), 9)
            || ' | max='     || LPAD(fmt(l_max_tps), 9)
            || ' | aggregate=' || fmt(l_total_ops / l_wall_s);
    END;

    -- =========================================================================
    -- MAIN
    -- =========================================================================
    PROCEDURE run_all IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('Starting TPS benchmark (3 phases)...');

        truncate_queues;
        phase_1_sequential;
        phase_2_export;
        phase_3_concurrent;

        -- Leave a clean queue: concurrent-phase items are never exported
        truncate_queues;

        DBMS_OUTPUT.PUT_LINE(CHR(10) || '=========================================================================');
        DBMS_OUTPUT.PUT_LINE('TPS BENCHMARK SUMMARY');
        DBMS_OUTPUT.PUT_LINE('=========================================================================');
        FOR i IN 1..g_summary_text.COUNT LOOP
            DBMS_OUTPUT.PUT_LINE('  ' || g_summary_text(i));
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('=========================================================================');
        DBMS_OUTPUT.PUT_LINE('Note: queues truncated at the end (benchmark data is not kept).');
    END;

END PLT_TPS_TEST;
/

BEGIN
    PLT_TPS_TEST.run_all;
END;
/

DROP PACKAGE PLT_TPS_TEST;
DROP TABLE plt_tps_results PURGE;

EXIT;
