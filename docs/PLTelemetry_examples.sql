SET SERVEROUTPUT ON;

DECLARE
    -- Variable for attributes
    l_attrs PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('📡 Starting V2 log test (Multi-Tenant)...');

    -- [NEW] 1. Set the Tenant context
    -- This is vital now. Everything that happens in this session will belong to 'CLIENTE_DEMO'.
    PLTelemetry.set_tenant('CLIENTE_DEMO');

    -- 2. Simple log (Inherits the tenant automatically)
    PLTelemetry.log(
        p_level   => 'INFO', 
        p_message => 'V2 System started successfully'
    );

    -- 3. Log with attributes
    l_attrs(1).key := 'user';
    l_attrs(1).value := 'ADMIN_TEST';
    l_attrs(2).key := 'source';
    l_attrs(2).value := 'SQLDeveloper';
    
    PLTelemetry.log(
        p_level   => 'WARN', 
        p_message => 'Complex attributes test',
        p_attrs   => l_attrs
    );

    -- 4. Context switch (Simulating another process in the same session)
    PLTelemetry.set_tenant('OTHER_CLIENT');
    PLTelemetry.log(
        p_level   => 'ERROR', 
        p_message => 'Simulated error in another context'
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
    -- Dummy variable to capture the return of the start_span function
    l_waste VARCHAR2(100); 
BEGIN
    DBMS_OUTPUT.PUT_LINE('🏎️ Starting Nested Traces test...');

    -- 1. Client Context
    PLTelemetry.set_tenant('CLIENT_AMAZON');

    -- 2. PARENT SPAN (Root)
    -- FIX: Assign the result to l_waste
    l_waste := PLTelemetry.start_span('process_order');
    
        PLTelemetry.log('INFO', 'Starting validations...');

        -- 3. CHILD SPAN 1 (Nested)
        l_waste := PLTelemetry.start_span('validate_stock');
            
            PLTelemetry.log('DEBUG', 'Querying main warehouse');
            
            -- Close CHILD 1
            PLTelemetry.end_span('OK');

        -- 4. CHILD SPAN 2 (Nested)
        l_waste := PLTelemetry.start_span('process_payment');
            
            PLTelemetry.log('INFO', 'Connecting to payment gateway');
            
            -- Close CHILD 2
            PLTelemetry.end_span('OK');

    -- 5. Close PARENT (Root)
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
    PLTelemetry.set_tenant('CLIENT_TYPES');

    -- 1. GAUGE (Absolute value)
    -- Example: Space used in a tablespace (can go up and down)
    -- Use the package constant to avoid magic strings
    PLTelemetry.log_metric(
        p_name  => 'db.tablespace.used_pct', 
        p_value => 85.5, 
        p_type  => PLTelemetry.C_METRIC_GAUGE, -- 'GAUGE'
        p_unit  => '%'
    );

    -- 2. COUNTER (Cumulative/Delta)
    -- Example: We processed 1 new order (adds 1 to the total)
    PLTelemetry.log_metric(
        p_name  => 'app.orders.processed', 
        p_value => 1, 
        p_type  => PLTelemetry.C_METRIC_COUNTER, -- 'COUNTER'
        p_unit  => '1'
    );

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('✅ Typed metrics sent.');
END;
/
