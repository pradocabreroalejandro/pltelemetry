CREATE OR REPLACE PACKAGE PLT_OTLP_BRIDGE AS
    /**
     * PLT_OTLP_BRIDGE V2 (Lite & Smart)
     * Transforma JSON nativo de PLTelemetry a OTLP y lo envía vía HTTP directo.
     */

    -- Configuración
    PROCEDURE init(
        p_otlp_endpoint VARCHAR2, 
        p_service_name  VARCHAR2 DEFAULT 'oracle-db',
        p_environment   VARCHAR2 DEFAULT 'production'
    );

    -- Debug
    PROCEDURE set_debug(p_enabled BOOLEAN);

    -- El cerebro: Recibe el JSON crudo de la cola y lo manda a donde toca
    PROCEDURE process_payload(p_item_type VARCHAR2, p_json CLOB);

END PLT_OTLP_BRIDGE;
/