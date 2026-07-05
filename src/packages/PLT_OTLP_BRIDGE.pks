SET DEFINE OFF;

CREATE OR REPLACE PACKAGE PLT_OTLP_BRIDGE AS
    /**
     * PLT_OTLP_BRIDGE V2 (Lite & Smart)
     * Transforms native PLTelemetry JSON to OTLP and sends it via direct HTTP.
     */

    -- Configuration
    PROCEDURE init(
        p_otlp_endpoint VARCHAR2, 
        p_service_name  VARCHAR2 DEFAULT 'oracle-db',
        p_environment   VARCHAR2 DEFAULT 'production'
    );

    -- Debug
    PROCEDURE set_debug(p_enabled BOOLEAN);

    -- The brain: Receives raw JSON from the queue and sends it where it belongs
    PROCEDURE process_payload(p_item_type VARCHAR2, p_json CLOB);

    -- Batch sender: drains many metric payloads in a SINGLE OTLP HTTP POST.
    -- p_metrics is a JSON array of metric payload objects (same shape process_payload
    -- parses for METRIC). Used by the failover path to avoid 1-POST-per-metric.
    PROCEDURE send_metrics_batch(p_metrics SYS.JSON_ARRAY_T);

    PROCEDURE run_failover_processing;

    g_debug         BOOLEAN := FALSE;


END PLT_OTLP_BRIDGE;
/
