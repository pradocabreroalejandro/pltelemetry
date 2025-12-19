SET SERVEROUTPUT ON;

DECLARE
    -- Variable para atributos
    l_attrs PLTelemetry.t_attributes;
BEGIN
    DBMS_OUTPUT.PUT_LINE('📡 Iniciando prueba de logs V2 (Multi-Tenant)...');

    -- [NUEVO] 1. Establecemos el contexto del Tenant
    -- Esto es vital ahora. Todo lo que ocurra en esta sesión será de 'CLIENTE_DEMO'.
    PLTelemetry.set_tenant('CLIENTE_DEMO');

    -- 2. Log simple (Hereda el tenant automáticamente)
    PLTelemetry.log(
        p_level   => 'INFO', 
        p_message => 'Sistema V2 arrancado correctamente'
    );

    -- 3. Log con atributos
    l_attrs(1).key := 'usuario';
    l_attrs(1).value := 'ADMIN_TEST';
    l_attrs(2).key := 'origen';
    l_attrs(2).value := 'SQLDeveloper';
    
    PLTelemetry.log(
        p_level   => 'WARN', 
        p_message => 'Prueba de atributos complejos',
        p_attrs   => l_attrs
    );

    -- 4. Cambio de contexto (Simulando otro proceso en la misma sesión)
    PLTelemetry.set_tenant('OTRO_CLIENTE');
    PLTelemetry.log(
        p_level   => 'ERROR', 
        p_message => 'Error simulado en otro contexto'
    );

    DBMS_OUTPUT.PUT_LINE('✅ Logs enviados a la cola.');
    COMMIT; 
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ Error en el bloque de prueba: ' || SQLERRM);
END;
/

SET SERVEROUTPUT ON;

DECLARE
    -- Variable "tonta" para capturar el retorno de la función start_span
    l_waste VARCHAR2(100); 
BEGIN
    DBMS_OUTPUT.PUT_LINE('🏎️ Iniciando prueba de Trazas Anidadas...');

    -- 1. Contexto del Cliente
    PLTelemetry.set_tenant('CLIENTE_AMAZONIAS');

    -- 2. SPAN PADRE (Root)
    -- CORRECCIÓN: Asignamos el resultado a l_waste
    l_waste := PLTelemetry.start_span('procesar_pedido');
    
        PLTelemetry.log('INFO', 'Iniciando validaciones...');

        -- 3. SPAN HIJO 1 (Nested)
        l_waste := PLTelemetry.start_span('validar_stock');
            
            PLTelemetry.log('DEBUG', 'Consultando almacén principal');
            
            -- Cerramos HIJO 1
            PLTelemetry.end_span('OK');

        -- 4. SPAN HIJO 2 (Nested)
        l_waste := PLTelemetry.start_span('procesar_pago');
            
            PLTelemetry.log('INFO', 'Conectando con pasarela de pago');
            
            -- Cerramos HIJO 2
            PLTelemetry.end_span('OK');

    -- 5. Cerramos PADRE (Root)
    PLTelemetry.end_span('OK', 'Pedido procesado correctamente');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('🏁 Prueba de trazas finalizada.');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ Error: ' || SQLERRM);
        ROLLBACK;
END;
/

SET SERVEROUTPUT ON;

BEGIN
    DBMS_OUTPUT.PUT_LINE('📏 Iniciando prueba de Métricas Tipadas...');
    PLTelemetry.set_tenant('CLIENTE_TIPOS');

    -- 1. GAUGE (Valor absoluto)
    -- Ejemplo: Espacio ocupado en un tablespace (puede subir y bajar)
    -- Usamos la constante del paquete para evitar strings mágicos
    PLTelemetry.log_metric(
        p_name  => 'db.tablespace.used_pct', 
        p_value => 85.5, 
        p_type  => PLTelemetry.C_METRIC_GAUGE, -- 'GAUGE'
        p_unit  => '%'
    );

    -- 2. COUNTER (Acumulativo/Delta)
    -- Ejemplo: Hemos procesado 1 pedido nuevo (suma 1 al total)
    PLTelemetry.log_metric(
        p_name  => 'app.orders.processed', 
        p_value => 1, 
        p_type  => PLTelemetry.C_METRIC_COUNTER, -- 'COUNTER'
        p_unit  => '1'
    );

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('✅ Métricas tipadas enviadas.');
END;
/