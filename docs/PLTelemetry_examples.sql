SET SERVEROUTPUT ON;

DECLARE
    -- Variable for attributes (LEGACY API)
    l_attrs PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('📡 Starting V2 log test (Multi-Tenant)...');

    -- =========================================================================
    -- 1. ONE-LINE API (NEW)
    -- =========================================================================
    -- Everything in a single call: no set_tenant, no attribute records.

    PLTelemetry.log('INFO', 'System started successfully',
                    p_tenant_id => 'CLIENTE_DEMO');

    PLTelemetry.log('WARN', 'Complex attributes test',
                    p_attrs_json => '{"user":"ADMIN_TEST","source":"SQLDeveloper"}',
                    p_tenant_id  => 'CLIENTE_DEMO');

    -- What was previously 2 lines (set_tenant + log) is now 1 line:
    PLTelemetry.log('ERROR', 'Simulated error in another context',
                    p_tenant_id => 'OTHER_CLIENT');

    -- =========================================================================
    -- 2. LEGACY API (still fully supported)
    -- =========================================================================
    PLTelemetry.set_tenant('CLIENTE_DEMO');

    l_attrs(1).key := 'user';   l_attrs(1).value := 'ADMIN_TEST';
    l_attrs(2).key := 'source'; l_attrs(2).value := 'SQLDeveloper';

    PLTelemetry.log(
        p_level   => 'WARN',
        p_message => 'Complex attributes test (legacy)',
        p_attrs   => l_attrs
    );

    DBMS_OUTPUT.PUT_LINE('✅ Logs sent to queue.');
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ Error in test block: ' || SQLERRM);
END;
/

SET SERVEROUTPUT ON;

DECLARE
    l_waste VARCHAR2(100);
BEGIN
    DBMS_OUTPUT.PUT_LINE('🏎️ Starting Nested Traces test...');

    PLTelemetry.set_tenant('CLIENT_AMAZON');

    l_waste := PLTelemetry.start_span('process_order');

        PLTelemetry.log('INFO', 'Starting validations...');

        l_waste := PLTelemetry.start_span('validate_stock');
            PLTelemetry.log('DEBUG', 'Querying main warehouse',
                            p_attrs_json => '{"warehouse":"MAIN","region":"EU"}');
            PLTelemetry.end_span('OK');

        l_waste := PLTelemetry.start_span('process_payment');
            PLTelemetry.log('INFO', 'Connecting to payment gateway',
                            p_attrs_json => '{"gateway":"STRIPE","amount":"99.99"}');
            PLTelemetry.end_span('OK');

    PLTelemetry.end_span('OK', 'Order processed successfully');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('🏁 Trace test completed.');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ Error: ' || SQLERRM);
        ROLLBACK;
END;
/

SET SERVEROUTPUT ON;

BEGIN
    DBMS_OUTPUT.PUT_LINE('📏 Starting Typed Metrics test...');

    -- 1. GAUGE with one-line tenant override
    PLTelemetry.log_metric(
        p_name      => 'db.tablespace.used_pct',
        p_value     => 85.5,
        p_type      => PLTelemetry.C_METRIC_GAUGE,
        p_unit      => '%',
        p_tenant_id => 'CLIENT_TYPES'
    );

    -- 2. COUNTER with inline JSON attributes
    PLTelemetry.log_metric(
        p_name       => 'app.orders.processed',
        p_value      => 1,
        p_type       => PLTelemetry.C_METRIC_COUNTER,
        p_attrs_json => '{"region":"EU-WEST","channel":"WEB"}',
        p_tenant_id  => 'CLIENT_TYPES'
    );

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('✅ Typed metrics sent.');
END;
/