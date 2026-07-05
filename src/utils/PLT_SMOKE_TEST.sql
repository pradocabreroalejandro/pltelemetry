-- =============================================================================
-- PLT_SMOKE_TEST.sql — Smoke/Regression Test Runner
-- =============================================================================
-- Run as: sqlplus PLTELEMETRY/plt@//localhost:1521/FREEPDB1 @PLT_SMOKE_TEST.sql
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET LINESIZE 200;
SET PAGESIZE 100;
SET DEFINE OFF;
SET TIMING ON;

PROMPT
PROMPT =========================================================================
PROMPT PLTELEMETRY SMOKE TEST SUITE
PROMPT =========================================================================
PROMPT

CREATE OR REPLACE PACKAGE PLT_SMOKE_TEST AS
    PROCEDURE run_all;
END PLT_SMOKE_TEST;
/

CREATE OR REPLACE PACKAGE BODY PLT_SMOKE_TEST AS

    g_test_count NUMBER := 0;
    g_pass_count NUMBER := 0;
    g_fail_count NUMBER := 0;

    PROCEDURE result(p_name VARCHAR2, p_passed BOOLEAN, p_detail VARCHAR2 DEFAULT NULL) IS
    BEGIN
        g_test_count := g_test_count + 1;
        IF p_passed THEN
            g_pass_count := g_pass_count + 1;
            DBMS_OUTPUT.PUT_LINE('  PASS | ' || RPAD(p_name, 45) || ' | ' || NVL(p_detail, ''));
        ELSE
            g_fail_count := g_fail_count + 1;
            DBMS_OUTPUT.PUT_LINE('  FAIL | ' || RPAD(p_name, 45) || ' | ' || NVL(p_detail, ''));
        END IF;
    END;

    PROCEDURE section(p_title VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(CHR(10) || '--- ' || p_title || ' ---');
    END;

    PROCEDURE test_1_queue_clean IS
        l_cnt NUMBER;
    BEGIN
        section('TEST 1: Queue Clean Slate');
        BEGIN EXECUTE IMMEDIATE 'TRUNCATE TABLE plt_queue_01'; EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN EXECUTE IMMEDIATE 'TRUNCATE TABLE plt_queue_02'; EXCEPTION WHEN OTHERS THEN NULL; END;
        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader;
        result('Queue starts empty', l_cnt = 0, 'rows=' || l_cnt);
    END;

    PROCEDURE test_2_simple_log IS
        l_cnt NUMBER;
        l_severity VARCHAR2(20);
        l_message  VARCHAR2(4000);
        l_tenant   VARCHAR2(100);
        l_ts       VARCHAR2(100);
    BEGIN
        section('TEST 2: Simple Log (INFO)');
        PLTelemetry.reset_context;
        PLTelemetry.log('INFO', 'Smoke test: simple INFO log', p_tenant_id => 'SMOKE_TEST');

        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader WHERE item_type = 'LOG' AND tenant_id = 'SMOKE_TEST';
        result('INFO log enqueued', l_cnt = 1, 'rows=' || l_cnt);

        SELECT JSON_VALUE(payload, '$.severity'), JSON_VALUE(payload, '$.message'),
               JSON_VALUE(payload, '$.tenant_id'), JSON_VALUE(payload, '$.timestamp')
          INTO l_severity, l_message, l_tenant, l_ts
          FROM plt_queue_reader
         WHERE item_type = 'LOG' AND tenant_id = 'SMOKE_TEST' AND ROWNUM = 1;

        result('Log severity=INFO', l_severity = 'INFO', 'severity=' || l_severity);
        result('Log message correct', l_message = 'Smoke test: simple INFO log', 'msg=' || SUBSTR(l_message, 1, 50));
        result('Log tenant=SMOKE_TEST', l_tenant = 'SMOKE_TEST', 'tenant=' || l_tenant);
        result('Log has timestamp', l_ts IS NOT NULL, 'ts=' || SUBSTR(l_ts, 1, 30));
    END;

    PROCEDURE test_3_log_attrs IS
        l_cnt NUMBER;
    BEGIN
        section('TEST 3: Log with attr() overload');
        PLTelemetry.reset_context;
        PLTelemetry.log('WARN', 'Smoke test: log with attrs',
            PLTelemetry.attr('user', 'TESTER'),
            PLTelemetry.attr('module', 'SMOKE_TEST'),
            p_tenant_id => 'SMOKE_TEST');

        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader
         WHERE item_type = 'LOG' AND DBMS_LOB.INSTR(payload, 'TESTER') > 0;
        result('Log with attrs enqueued', l_cnt >= 1, 'rows=' || l_cnt);
    END;

    PROCEDURE test_4_log_json_attrs IS
        l_cnt NUMBER;
    BEGIN
        section('TEST 4: Log with JSON attrs');
        PLTelemetry.reset_context;
        PLTelemetry.log('ERROR', 'Smoke test: JSON attrs log',
            p_attrs_json => '{"error_code":"E001","component":"DB"}',
            p_tenant_id => 'SMOKE_TEST');

        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader
         WHERE item_type = 'LOG' AND DBMS_LOB.INSTR(payload, 'E001') > 0;
        result('Log with JSON attrs enqueued', l_cnt >= 1, 'rows=' || l_cnt);
    END;

    PROCEDURE test_5_all_levels IS
        l_cnt NUMBER;
    BEGIN
        section('TEST 5: All Log Levels');
        PLTelemetry.reset_context;
        PLTelemetry.log('INFO',  'Level test INFO',  p_tenant_id => 'SMOKE_TEST');
        PLTelemetry.log('WARN',  'Level test WARN',  p_tenant_id => 'SMOKE_TEST');
        PLTelemetry.log('ERROR', 'Level test ERROR', p_tenant_id => 'SMOKE_TEST');
        PLTelemetry.log('DEBUG', 'Level test DEBUG', p_tenant_id => 'SMOKE_TEST');

        SELECT COUNT(DISTINCT JSON_VALUE(payload, '$.severity')) INTO l_cnt
          FROM plt_queue_reader
         WHERE item_type = 'LOG' AND tenant_id = 'SMOKE_TEST'
           AND DBMS_LOB.INSTR(payload, 'Level test') > 0;

        result('All 4 log levels present', l_cnt = 4, 'levels=' || l_cnt);
    END;

    PROCEDURE test_6_gauge IS
        l_cnt   NUMBER;
        l_name  VARCHAR2(255);
        l_value NUMBER;
        l_type  VARCHAR2(20);
        l_unit  VARCHAR2(20);
    BEGIN
        section('TEST 6: Gauge Metric');
        PLTelemetry.reset_context;
        PLTelemetry.log_metric('smoke.test.gauge', 42.5,
            p_type => PLTelemetry.c_metric_gauge,
            p_unit => '%',
            p_tenant_id => 'SMOKE_TEST');

        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader
         WHERE item_type = 'METRIC' AND DBMS_LOB.INSTR(payload, 'smoke.test.gauge') > 0;
        result('Gauge metric enqueued', l_cnt >= 1, 'rows=' || l_cnt);

        SELECT JSON_VALUE(payload, '$.name'), JSON_VALUE(payload, '$.value'),
               JSON_VALUE(payload, '$.type'), JSON_VALUE(payload, '$.unit')
          INTO l_name, l_value, l_type, l_unit
          FROM plt_queue_reader
         WHERE item_type = 'METRIC' AND DBMS_LOB.INSTR(payload, 'smoke.test.gauge') > 0 AND ROWNUM = 1;

        result('Metric name correct', l_name = 'smoke.test.gauge', 'name=' || l_name);
        result('Metric value=42.5', l_value = 42.5, 'value=' || l_value);
        result('Metric type=GAUGE', l_type = 'GAUGE', 'type=' || l_type);
        result('Metric unit=%', l_unit = '%', 'unit=' || l_unit);
    END;

    PROCEDURE test_7_counter IS
        l_cnt  NUMBER;
        l_type VARCHAR2(20);
    BEGIN
        section('TEST 7: Counter Metric');
        PLTelemetry.reset_context;
        PLTelemetry.log_metric('smoke.test.counter', 1,
            p_type => PLTelemetry.c_metric_counter,
            p_attrs_json => '{"region":"EU","source":"test"}',
            p_tenant_id => 'SMOKE_TEST');

        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader
         WHERE item_type = 'METRIC' AND DBMS_LOB.INSTR(payload, 'smoke.test.counter') > 0;
        result('Counter metric enqueued', l_cnt >= 1, 'rows=' || l_cnt);

        SELECT JSON_VALUE(payload, '$.type') INTO l_type
          FROM plt_queue_reader
         WHERE item_type = 'METRIC' AND DBMS_LOB.INSTR(payload, 'smoke.test.counter') > 0 AND ROWNUM = 1;

        result('Counter type=COUNTER', l_type = 'COUNTER', 'type=' || l_type);
    END;

    PROCEDURE test_8_simple_trace IS
        l_cnt        NUMBER;
        l_trace_len  NUMBER;
        l_span_len   NUMBER;
        l_op_name    VARCHAR2(200);
        l_status     VARCHAR2(20);
        l_dur        NUMBER;
        l_has_parent NUMBER;
    BEGIN
        section('TEST 8: Simple Trace (single span)');
        PLTelemetry.reset_context;
        PLTelemetry.start_span('smoke_test_single_span', p_tenant => 'SMOKE_TEST');
        DECLARE l_start TIMESTAMP := SYSTIMESTAMP; BEGIN
            WHILE SYSTIMESTAMP < l_start + INTERVAL '0.1' SECOND LOOP NULL; END LOOP;
        END;
        PLTelemetry.end_span('OK');

        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader
         WHERE item_type = 'TRACE' AND DBMS_LOB.INSTR(payload, 'smoke_test_single_span') > 0;
        result('Simple trace enqueued', l_cnt = 1, 'rows=' || l_cnt);

        SELECT length(JSON_VALUE(payload, '$.trace_id')),
               length(JSON_VALUE(payload, '$.span_id')),
               JSON_VALUE(payload, '$.operation_name'),
               JSON_VALUE(payload, '$.status'),
               JSON_VALUE(payload, '$.duration_ms'),
               CASE WHEN DBMS_LOB.INSTR(payload, 'parent_span_id') > 0 THEN 1 ELSE 0 END
          INTO l_trace_len, l_span_len, l_op_name, l_status, l_dur, l_has_parent
          FROM plt_queue_reader
         WHERE item_type = 'TRACE' AND DBMS_LOB.INSTR(payload, 'smoke_test_single_span') > 0 AND ROWNUM = 1;

        result('Span trace_id=32hex', l_trace_len = 32, 'len=' || l_trace_len);
        result('Span span_id=16hex', l_span_len = 16, 'len=' || l_span_len);
        result('Span op_name correct', l_op_name = 'smoke_test_single_span', 'op=' || l_op_name);
        result('Span status=OK', l_status = 'OK', 'status=' || l_status);
        result('Span duration>0', l_dur > 0, 'dur_ms=' || l_dur);
        result('Span is root (no parent)', l_has_parent = 0, 'has_parent=' || l_has_parent);
    END;

    PROCEDURE test_9_nested_trace IS
        l_cnt NUMBER;
        l_parent_trace VARCHAR2(32);
        l_parent_span  VARCHAR2(16);
        l_child_trace  VARCHAR2(32);
        l_child_parent VARCHAR2(16);
    BEGIN
        section('TEST 9: Nested Trace (parent -> child)');
        PLTelemetry.reset_context;
        PLTelemetry.start_span('smoke_parent', p_tenant => 'SMOKE_TEST');
        PLTelemetry.start_span('smoke_child_1');
        PLTelemetry.log('INFO', 'Inside child span', p_tenant_id => 'SMOKE_TEST');
        PLTelemetry.end_span('OK');
        PLTelemetry.start_span('smoke_child_2');
        PLTelemetry.end_span('OK');
        PLTelemetry.end_span('OK');

        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader
         WHERE item_type = 'TRACE' AND tenant_id = 'SMOKE_TEST'
           AND (DBMS_LOB.INSTR(payload, 'smoke_parent') > 0 OR DBMS_LOB.INSTR(payload, 'smoke_child_1') > 0 OR DBMS_LOB.INSTR(payload, 'smoke_child_2') > 0);
        result('Nested trace: 3 spans', l_cnt = 3, 'rows=' || l_cnt);

        SELECT JSON_VALUE(payload, '$.trace_id'), JSON_VALUE(payload, '$.span_id')
          INTO l_parent_trace, l_parent_span
          FROM plt_queue_reader
         WHERE item_type = 'TRACE' AND DBMS_LOB.INSTR(payload, 'smoke_parent') > 0 AND ROWNUM = 1;

        SELECT JSON_VALUE(payload, '$.trace_id'), JSON_VALUE(payload, '$.parent_span_id')
          INTO l_child_trace, l_child_parent
          FROM plt_queue_reader
         WHERE item_type = 'TRACE' AND DBMS_LOB.INSTR(payload, 'smoke_child_1') > 0 AND ROWNUM = 1;

        result('Child inherits trace_id', l_parent_trace = l_child_trace, 'parent=' || l_parent_trace || ' child=' || l_child_trace);
        result('Child parent_span matches', l_parent_span = l_child_parent, 'parent=' || l_parent_span || ' child_parent=' || l_child_parent);

        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader
         WHERE item_type = 'LOG'
           AND DBMS_LOB.INSTR(payload, 'Inside child span') > 0
           AND DBMS_LOB.INSTR(payload, l_child_trace) > 0;
        result('Log inside span has trace correlation', l_cnt >= 1, 'correlated=' || l_cnt);
    END;

    PROCEDURE test_10_error_trace IS
        l_cnt NUMBER;
    BEGIN
        section('TEST 10: Trace with ERROR status');
        PLTelemetry.reset_context;
        PLTelemetry.start_span('smoke_error_span', p_tenant => 'SMOKE_TEST');
        PLTelemetry.log('ERROR', 'Simulated error in span', p_tenant_id => 'SMOKE_TEST');
        PLTelemetry.end_span('ERROR', 'Test error message');

        SELECT COUNT(*) INTO l_cnt FROM plt_queue_reader
         WHERE item_type = 'TRACE'
           AND DBMS_LOB.INSTR(payload, 'smoke_error_span') > 0
           AND DBMS_LOB.INSTR(payload, '"ERROR"') > 0;
        result('Error trace enqueued with ERROR status', l_cnt >= 1, 'rows=' || l_cnt);
    END;

    PROCEDURE test_11_w3c_inject IS
        l_trace_id VARCHAR2(32) := 'abcdef0123456789abcdef0123456789';
        l_parent   VARCHAR2(16) := '1234567890abcdef';
        l_w3c      VARCHAR2(100);
        l_r_trace  VARCHAR2(32);
        l_r_parent VARCHAR2(16);
    BEGIN
        section('TEST 11: W3C Context Injection');
        l_w3c := '00-' || l_trace_id || '-' || l_parent || '-01';
        PLTelemetry.reset_context;
        PLTelemetry.w3c_inject_context(l_w3c);
        PLTelemetry.start_span('smoke_w3c_span', p_tenant => 'SMOKE_TEST');
        PLTelemetry.end_span('OK');

        SELECT JSON_VALUE(payload, '$.trace_id'), JSON_VALUE(payload, '$.parent_span_id')
          INTO l_r_trace, l_r_parent
          FROM plt_queue_reader
         WHERE item_type = 'TRACE' AND DBMS_LOB.INSTR(payload, 'smoke_w3c_span') > 0 AND ROWNUM = 1;

        result('W3C trace_id injected', l_r_trace = l_trace_id, 'expected=' || l_trace_id || ' got=' || l_r_trace);
        result('W3C parent_span_id injected', l_r_parent = l_parent, 'expected=' || l_parent || ' got=' || l_r_parent);
    END;

    PROCEDURE test_12_tenant_iso IS
        l_a NUMBER;
        l_b NUMBER;
    BEGIN
        section('TEST 12: Tenant Isolation');
        PLTelemetry.reset_context;
        PLTelemetry.log('INFO', 'Tenant A log', p_tenant_id => 'TENANT_A');
        PLTelemetry.log('INFO', 'Tenant B log', p_tenant_id => 'TENANT_B');

        SELECT COUNT(*) INTO l_a FROM plt_queue_reader WHERE item_type = 'LOG' AND tenant_id = 'TENANT_A';
        SELECT COUNT(*) INTO l_b FROM plt_queue_reader WHERE item_type = 'LOG' AND tenant_id = 'TENANT_B';

        result('Tenant A isolated', l_a >= 1, 'rows=' || l_a);
        result('Tenant B isolated', l_b >= 1, 'rows=' || l_b);
    END;

    PROCEDURE test_13_queue_summary IS
        l_total   NUMBER;
        l_logs    NUMBER;
        l_metrics NUMBER;
        l_traces  NUMBER;
    BEGIN
        section('TEST 13: Queue Volume Summary');
        SELECT COUNT(*) INTO l_total   FROM plt_queue_reader WHERE tenant_id IN ('SMOKE_TEST','TENANT_A','TENANT_B');
        SELECT COUNT(*) INTO l_logs    FROM plt_queue_reader WHERE item_type = 'LOG'    AND tenant_id IN ('SMOKE_TEST','TENANT_A','TENANT_B');
        SELECT COUNT(*) INTO l_metrics FROM plt_queue_reader WHERE item_type = 'METRIC' AND tenant_id IN ('SMOKE_TEST','TENANT_A','TENANT_B');
        SELECT COUNT(*) INTO l_traces  FROM plt_queue_reader WHERE item_type = 'TRACE'  AND tenant_id IN ('SMOKE_TEST','TENANT_A','TENANT_B');

        DBMS_OUTPUT.PUT_LINE('    Total=' || l_total || ' Logs=' || l_logs || ' Metrics=' || l_metrics || ' Traces=' || l_traces);
        result('All 3 signal types present', l_logs > 0 AND l_metrics > 0 AND l_traces > 0, 'L=' || l_logs || ' M=' || l_metrics || ' T=' || l_traces);
    END;

    PROCEDURE test_14_otlp_export IS
        l_before NUMBER;
        l_after  NUMBER;
        l_failed NUMBER;
    BEGIN
        section('TEST 14: OTLP Export via process_queue');
        SELECT COUNT(*) INTO l_before FROM plt_queue_reader WHERE status = 'NEW';
        DBMS_OUTPUT.PUT_LINE('    Items before: ' || l_before);
        DBMS_OUTPUT.PUT_LINE('    Calling process_queue...');

        PLT_OTLP_BRIDGE.set_debug(TRUE);
        PLTelemetry.process_queue(p_batch_size => 500);

        SELECT COUNT(*) INTO l_after  FROM plt_queue_reader WHERE status = 'PROCESSED';
        SELECT COUNT(*) INTO l_failed FROM plt_queue_reader WHERE status = 'FAILED';

        DBMS_OUTPUT.PUT_LINE('    Processed=' || l_after || ' Failed=' || l_failed);
        result('OTLP export: items processed', l_after > 0, 'processed=' || l_after);
        result('OTLP export: no failures', l_failed = 0, 'failed=' || l_failed);
    END;

    PROCEDURE test_15_collector_reachable IS
        l_req  UTL_HTTP.REQ;
        l_res  UTL_HTTP.RESP;
        l_body VARCHAR2(4000);
        l_url  VARCHAR2(500);
    BEGIN
        section('TEST 15: Collector Reachable from Oracle');
        l_url := PLT_CONFIGURATION.get_param('OTLP', 'ENDPOINT_URL', 'http://localhost:4318');

        BEGIN
            l_req := UTL_HTTP.BEGIN_REQUEST(l_url, 'GET', 'HTTP/1.1');
            l_res := UTL_HTTP.GET_RESPONSE(l_req);
            BEGIN LOOP UTL_HTTP.READ_TEXT(l_res, l_body, 4000); END LOOP;
            EXCEPTION WHEN UTL_HTTP.END_OF_BODY THEN NULL;
            END;
            UTL_HTTP.END_RESPONSE(l_res);
            result('Collector reachable', l_res.status_code IS NOT NULL, 'HTTP ' || l_res.status_code);
        EXCEPTION WHEN OTHERS THEN
            result('Collector reachable', FALSE, 'Error: ' || SUBSTR(SQLERRM, 1, 200));
        END;
    END;

    PROCEDURE run_all IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('Starting 15 tests...' || CHR(10));

        test_1_queue_clean;
        test_2_simple_log;
        test_3_log_attrs;
        test_4_log_json_attrs;
        test_5_all_levels;
        test_6_gauge;
        test_7_counter;
        test_8_simple_trace;
        test_9_nested_trace;
        test_10_error_trace;
        test_11_w3c_inject;
        test_12_tenant_iso;
        test_13_queue_summary;
        test_14_otlp_export;
        test_15_collector_reachable;

        DBMS_OUTPUT.PUT_LINE(CHR(10) || '=========================================================================');
        DBMS_OUTPUT.PUT_LINE('SMOKE TEST SUMMARY');
        DBMS_OUTPUT.PUT_LINE('=========================================================================');
        DBMS_OUTPUT.PUT_LINE('  Total : ' || g_test_count);
        DBMS_OUTPUT.PUT_LINE('  Pass  : ' || g_pass_count);
        DBMS_OUTPUT.PUT_LINE('  Fail  : ' || g_fail_count);
        DBMS_OUTPUT.PUT_LINE('  Result: ' || CASE WHEN g_fail_count = 0 THEN 'ALL TESTS PASSED' ELSE 'SOME TESTS FAILED' END);
        DBMS_OUTPUT.PUT_LINE('=========================================================================');
        DBMS_OUTPUT.PUT_LINE(CHR(10) || 'Verify backends:');
        DBMS_OUTPUT.PUT_LINE('  Prometheus: curl "http://localhost:9090/api/v1/query?query=smoke"');
        DBMS_OUTPUT.PUT_LINE('  Loki:       curl http://localhost:3100/loki/api/v1/labels');
        DBMS_OUTPUT.PUT_LINE('  Tempo:      curl "http://localhost:3200/api/search?q=smoke"');
    END;

END PLT_SMOKE_TEST;
/

BEGIN
    PLT_SMOKE_TEST.run_all;
END;
/

DROP PACKAGE PLT_SMOKE_TEST;

EXIT;
