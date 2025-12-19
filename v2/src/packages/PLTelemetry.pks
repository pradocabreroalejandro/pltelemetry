CREATE OR REPLACE PACKAGE PLTelemetry AUTHID DEFINER AS
    /**
     * PLTelemetry V2 (Lean Edition)
     * -------------------------------------------------------------------------
     * High-performance OpenTelemetry SDK for Oracle PL/SQL.
     * Architecture: Fire-and-forget to PLT_QUEUE.
     * Dependencies: None (Self-contained).
     */

    --------------------------------------------------------------------------
    -- PUBLIC TYPES & CONSTANTS
    --------------------------------------------------------------------------
    TYPE t_attribute IS RECORD (key VARCHAR2(100), value VARCHAR2(4000));
    TYPE t_attributes IS TABLE OF t_attribute INDEX BY BINARY_INTEGER;

    -- Tipos de Métricas (Para no equivocarse)
    C_METRIC_GAUGE   CONSTANT VARCHAR2(10) := 'GAUGE';   -- Valores absolutos (Temp, CPU)
    C_METRIC_COUNTER CONSTANT VARCHAR2(10) := 'COUNTER'; -- Sumatorios (Ventas, Errores)

    --------------------------------------------------------------------------
    -- SPAN MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * Starts a new span. Pushes it to the internal memory stack.
     * Does NOT write to database yet.
     *
     * @param p_operation   Name of the operation (e.g., 'calculate_tax')
     * @param p_force_trace If TRUE, ignores sampling configuration
     * @return Span ID (optional usage, usually handled internally)
     */
    FUNCTION start_span(
        p_operation   IN VARCHAR2,
        p_force_trace IN BOOLEAN  DEFAULT FALSE
    ) RETURN VARCHAR2;

    /**
     * Ends the current active span.
     * Calculates duration, generates JSON, and writes to PLT_QUEUE.
     *
     * @param p_status_code 'OK' or 'ERROR'
     * @param p_status_msg  Error message or description
     */
    PROCEDURE end_span(
        p_status_code IN VARCHAR2 DEFAULT 'OK',
        p_status_msg  IN VARCHAR2 DEFAULT NULL
    );

    --------------------------------------------------------------------------
    -- TELEMETRY SIGNALS
    --------------------------------------------------------------------------

    /**
     * Record a metric. Writes immediately to PLT_QUEUE.
     */
    PROCEDURE log_metric(
        p_name  IN VARCHAR2,
        p_value IN NUMBER,
        p_type  IN VARCHAR2 DEFAULT C_METRIC_GAUGE,
        p_unit  IN VARCHAR2 DEFAULT '1',
        p_attrs IN t_attributes DEFAULT CAST(NULL AS t_attributes)
    );

    /**
     * Record a log message. Writes immediately to PLT_QUEUE.
     * Automatically correlates with current active span if any.
     */
    PROCEDURE log(
        p_level   IN VARCHAR2, -- INFO, WARN, ERROR, DEBUG
        p_message IN VARCHAR2,
        p_attrs   IN t_attributes DEFAULT CAST(NULL AS t_attributes)
    );

    --------------------------------------------------------------------------
    -- CONTEXT & CONFIG
    --------------------------------------------------------------------------

    /**
     * Sets the Tenant ID for the current session context.
     * All subsequent traces/logs will carry this tenant_id.
     */
    PROCEDURE set_tenant(p_tenant_id VARCHAR2);

    /**
     * Helper to quickly create an attribute record
     */
    FUNCTION attr(k VARCHAR2, v VARCHAR2) RETURN t_attribute;

END PLTelemetry;
/