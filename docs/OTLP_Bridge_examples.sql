DECLARE
    -- Variable to capture the error and stack trace
    l_err_msg   VARCHAR2(4000);
    
    -- CORRECTED CURSOR:
    -- 1. Removed explicit 'ORDER BY' (we trust the index for FIFO).
    -- 2. Use 'ROWNUM <= 50' instead of 'FETCH FIRST'.
    -- This allows FOR UPDATE SKIP LOCKED to work without internal views.
    CURSOR c_queue IS
        SELECT id, item_type, payload
        FROM plt_queue
        WHERE status = 'NEW'
        AND ROWNUM <= 50 -- <--- THE KEY CHANGE
        FOR UPDATE SKIP LOCKED;
BEGIN
    -- 1. Initialize Bridge (Adjust the URL to your actual Collector)
    PLT_OTLP_BRIDGE.init(
        p_otlp_endpoint => 'http://otel-collector:4318', 
        p_service_name  => 'oracle-db-prod'
    );
    -- Enable debug to see what happens in the console (optional)
    PLT_OTLP_BRIDGE.set_debug(TRUE);

    -- 2. Process batch
    FOR r IN c_queue LOOP
        BEGIN
            -- Try to send
            PLT_OTLP_BRIDGE.process_payload(r.item_type, r.payload);
            
            -- Success: Delete (Fire & Forget)
            DELETE FROM plt_queue WHERE id = r.id;
            
        EXCEPTION 
            WHEN OTHERS THEN
                -- Robust error capture + trace
                l_err_msg := SUBSTR(SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
                
                -- Update status to FAILED
                UPDATE plt_queue 
                SET status = 'FAILED', 
                    error_message = l_err_msg,
                    retry_count = retry_count + 1,
                    updated_at = SYSTIMESTAMP
                WHERE id = r.id;
        END;
    END LOOP;
    
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('✅ Batch processed successfully.');
END;
/



SET SERVEROUTPUT ON;
DECLARE
    l_trace_json CLOB;
    l_metric_json CLOB;
BEGIN
    -- 1. Initialize the bridge (Point to the internal Docker collector)
    -- NOTE: If you run this from your SQL Developer on your PC, use 'http://localhost:4318'
    -- If from inside Docker, it would be the service name. Assuming localhost for now.
    PLT_OTLP_BRIDGE.init(
        p_otlp_endpoint => 'http://otel-collector:4318',
        p_service_name  => 'oracle-db-test', 
        p_environment   => 'dev'
    );
    
    PLT_OTLP_BRIDGE.set_debug(TRUE);

    -- 2. Send a METRIC (A simple counter)
    l_metric_json := '{"name": "test_manual_counter", "value": 1, "type": "COUNTER", "timestamp": "'||TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF6"Z"')||'", "tenant_id": "tenant-1"}';
    PLT_OTLP_BRIDGE.process_payload('METRIC', l_metric_json);
    DBMS_OUTPUT.PUT_LINE('Metric sent.');

    -- 3. Send a TRACE (Simulated)
    -- Note: Not passing TraceId so the package generates a new one and prints it in debug
    l_trace_json := '{"name": "manual_sql_operation", "tenant_id": "tenant-1"}';
    PLT_OTLP_BRIDGE.process_payload('TRACE', l_trace_json);
    
    COMMIT;
END;
/


SET SERVEROUTPUT ON;
DECLARE
    l_metric_json CLOB;
BEGIN
    -- Initialize pointing to the collector
    PLT_OTLP_BRIDGE.init(
        p_otlp_endpoint => 'http://otel-collector:4318', 
        p_service_name  => 'oracle-db-test', 
        p_environment   => 'dev'
    );
    
    PLT_OTLP_BRIDGE.set_debug(TRUE);

    -- ⚠️ TRICK: Don't send timestamp. Let the package calculate the real UTC.
    -- Change the name so it's easy to find.
    l_metric_json := '{
        "name": "test_without_date", 
        "value": 50, 
        "type": "COUNTER", 
        "tenant_id": "tenant-1"
    }';
    
    PLT_OTLP_BRIDGE.process_payload('METRIC', l_metric_json);
    
    DBMS_OUTPUT.PUT_LINE('Metric sent without manual date.');
    COMMIT;
END;
/


SET SERVEROUTPUT ON;
DECLARE
    l_metric_json CLOB;
BEGIN
    PLT_OTLP_BRIDGE.init(
        p_otlp_endpoint => 'http://otel-collector:4318', 
        p_service_name  => 'oracle-db-test', 
        p_environment   => 'dev'
    );
    
    -- GAUGE: The simplest metric type (no history, just current value)
    l_metric_json := '{
        "name": "oracle_gauge_test", 
        "value": 123.45, 
        "type": "GAUGE", 
        "tenant_id": "tenant-1"
    }';
    
    PLT_OTLP_BRIDGE.process_payload('METRIC', l_metric_json);
    
    DBMS_OUTPUT.PUT_LINE('GAUGE metric sent.');
    COMMIT;
END;
/
