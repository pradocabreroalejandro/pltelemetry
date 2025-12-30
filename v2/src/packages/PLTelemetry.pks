create or replace package pltelemetry authid definer as
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
   type t_attribute is record (
         key   varchar2(100),
         value varchar2(4000)
   );
   type t_attributes is
      table of t_attribute index by binary_integer;

    -- Tipos de Métricas (Para no equivocarse)
   c_metric_gauge constant varchar2(10) := 'GAUGE';   -- Valores absolutos (Temp, CPU)
   c_metric_counter constant varchar2(10) := 'COUNTER'; -- Sumatorios (Ventas, Errores)

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
   function start_span (
      p_operation   in varchar2,
      p_force_trace in boolean default false
   ) return varchar2;

    /**
     * Ends the current active span.
     * Calculates duration, generates JSON, and writes to PLT_QUEUE.
     *
     * @param p_status_code 'OK' or 'ERROR'
     * @param p_status_msg  Error message or description
     */
   procedure end_span (
      p_status_code in varchar2 default 'OK',
      p_status_msg  in varchar2 default null
   );

    --------------------------------------------------------------------------
    -- TELEMETRY SIGNALS
    --------------------------------------------------------------------------

    /**
     * Record a metric. Writes immediately to PLT_QUEUE.
     */
   procedure log_metric (
      p_name  in varchar2,
      p_value in number,
      p_type  in varchar2 default c_metric_gauge,
      p_unit  in varchar2 default '1',
      p_attrs in t_attributes default cast ( null as t_attributes )
   );

    /**
     * Record a log message. Writes immediately to PLT_QUEUE.
     * Automatically correlates with current active span if any.
     */
   procedure log (
      p_level   in varchar2, -- INFO, WARN, ERROR, DEBUG
      p_message in varchar2,
      p_attrs   in t_attributes default cast ( null as t_attributes )
   );

    --------------------------------------------------------------------------
    -- CONTEXT & CONFIG
    --------------------------------------------------------------------------

    /**
     * Sets the Tenant ID for the current session context.
     * All subsequent traces/logs will carry this tenant_id.
     */
   procedure set_tenant (
      p_tenant_id varchar2
   );

    /**
     * Helper to quickly create an attribute record
     */
   function attr (
      k varchar2,
      v varchar2
   ) return t_attribute;

    /**
     * Processes pending telemetry items in PLT_QUEUE.
     * Should be called by a scheduled job or background worker.
     *
     * @param p_batch_size Number of items to process per execution
     */
   procedure process_queue (
      p_batch_size number default 50
   );

    /**
     * Auto-detects the calling context (package.procedure).
     *
     * @return Detected context as 'package.procedure'
     */
   function auto_detect_context return varchar2;

   PROCEDURE w3c_inject_context(p_traceparent VARCHAR2);

   FUNCTION is_agent_healthy RETURN BOOLEAN;

   g_debug         BOOLEAN := FALSE;

end pltelemetry;
/