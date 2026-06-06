DECLARE
    -- Variable para capturar el error y el stack trace
    l_err_msg   VARCHAR2(4000);
    
    -- CURSOR CORREGIDO:
    -- 1. Quitamos 'ORDER BY' explícito (confiamos en el índice para FIFO).
    -- 2. Usamos 'ROWNUM <= 50' en lugar de 'FETCH FIRST'.
    -- Esto permite que FOR UPDATE SKIP LOCKED funcione sin vistas internas.
    CURSOR c_queue IS
        SELECT id, item_type, payload
        FROM plt_queue
        WHERE status = 'NEW'
        AND ROWNUM <= 50 -- <--- EL CAMBIO CLAVE
        FOR UPDATE SKIP LOCKED;
BEGIN
    -- 1. Inicializar Bridge (Ajusta la URL a tu Collector real)
    PLT_OTLP_BRIDGE.init(
        p_otlp_endpoint => 'http://otel-collector:4318', 
        p_service_name  => 'oracle-db-prod'
    );
    -- Activar debug para ver qué pasa en la consola (opcional)
    PLT_OTLP_BRIDGE.set_debug(TRUE);

    -- 2. Procesar lote
    FOR r IN c_queue LOOP
        BEGIN
            -- Intentamos enviar
            PLT_OTLP_BRIDGE.process_payload(r.item_type, r.payload);
            
            -- Éxito: Borramos (Fire & Forget)
            DELETE FROM plt_queue WHERE id = r.id;
            
        EXCEPTION 
            WHEN OTHERS THEN
                -- Captura robusta del error + traza
                l_err_msg := SUBSTR(SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
                
                -- Actualizamos estado a FAILED
                UPDATE plt_queue 
                SET status = 'FAILED', 
                    error_message = l_err_msg,
                    retry_count = retry_count + 1,
                    updated_at = SYSTIMESTAMP
                WHERE id = r.id;
        END;
    END LOOP;
    
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('✅ Lote procesado correctamente.');
END;
/



SET SERVEROUTPUT ON;
DECLARE
    l_trace_json CLOB;
    l_metric_json CLOB;
BEGIN
    -- 1. Inicializamos el puente (Apunta al collector interno de Docker)
    -- OJO: Si ejecutas esto desde tu SQL Developer en tu PC, usa 'http://localhost:4318'
    -- Si es desde dentro de Docker, sería el nombre del servicio. Asumo localhost por ahora.
    PLT_OTLP_BRIDGE.init(
        p_otlp_endpoint => 'http://otel-collector:4318',
        p_service_name  => 'oracle-db-test', 
        p_environment   => 'dev'
    );
    
    PLT_OTLP_BRIDGE.set_debug(TRUE);

    -- 2. Enviamos una MÉTRICA (Un contador simple)
    l_metric_json := '{"name": "test_contador_manual", "value": 1, "type": "COUNTER", "timestamp": "'||TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF6"Z"')||'", "tenant_id": "tenant-1"}';
    PLT_OTLP_BRIDGE.process_payload('METRIC', l_metric_json);
    DBMS_OUTPUT.PUT_LINE('Métrica enviada.');

    -- 3. Enviamos una TRAZA (Simulada)
    -- Nota: No paso TraceId para que el paquete genere uno nuevo y me lo pinte en debug
    l_trace_json := '{"name": "operacion_manual_sql", "tenant_id": "tenant-1"}';
    PLT_OTLP_BRIDGE.process_payload('TRACE', l_trace_json);
    
    COMMIT;
END;
/


SET SERVEROUTPUT ON;
DECLARE
    l_metric_json CLOB;
BEGIN
    -- Inicializamos apuntando al collector
    PLT_OTLP_BRIDGE.init(
        p_otlp_endpoint => 'http://otel-collector:4318', 
        p_service_name  => 'oracle-db-test', 
        p_environment   => 'dev'
    );
    
    PLT_OTLP_BRIDGE.set_debug(TRUE);

    -- ⚠️ TRUCO: No enviamos timestamp. Dejamos que el package calcule el UTC real.
    -- Cambiamos el nombre para que sea fácil de buscar.
    l_metric_json := '{
        "name": "test_sin_fecha", 
        "value": 50, 
        "type": "COUNTER", 
        "tenant_id": "tenant-1"
    }';
    
    PLT_OTLP_BRIDGE.process_payload('METRIC', l_metric_json);
    
    DBMS_OUTPUT.PUT_LINE('Métrica enviada sin fecha manual.');
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
    
    -- GAUGE: El tipo de métrica más sencillo (sin histórico, solo valor actual)
    l_metric_json := '{
        "name": "oracle_gauge_prueba", 
        "value": 123.45, 
        "type": "GAUGE", 
        "tenant_id": "tenant-1"
    }';
    
    PLT_OTLP_BRIDGE.process_payload('METRIC', l_metric_json);
    
    DBMS_OUTPUT.PUT_LINE('Métrica GAUGE enviada.');
    COMMIT;
END;
/