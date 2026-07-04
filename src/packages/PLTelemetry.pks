set define off;

create or replace package pltelemetry authid definer as
    /**
     * PLTelemetry V3 (Stateless-per-request Edition)
     * -------------------------------------------------------------------------
     * High-performance OpenTelemetry SDK for Oracle PL/SQL (12.2+).
     * Architecture: Fire-and-forget to PLT_QUEUE.
     * Dependencies: None (self-contained).
     *
     * V3 CONTRACT CHANGES (BREAKING):
     *   - set_tenant() is REMOVED. Tenant is no longer session-global.
     *   - Tenant is scoped to the active span (set once at the trace root,
     *     inherited by children and by logs inside the span).
     *   - Precedence for every signal: explicit p_tenant_id
     *                                 > active span's tenant
     *                                 > 'default'.
     *   - reset_context() is MANDATORY at the start of each pooled request
     *     (ORDS / connection pool). Without it, a dangling span from a prior
     *     request leaks its tenant into the next one.
     *
     * WHY: in a pooled session, ANY surviving package state crosses the
     * request boundary. The old g_tenant_id global was a cross-tenant data
     * leak by construction. V3 keeps the only irreducible state (the span
     * stack) and makes it resettable in one call.
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

    -- Metric Types (to avoid magic strings)
   c_metric_gauge   constant varchar2(10) := 'GAUGE';   -- Absolute values (temp, CPU %)
   c_metric_counter constant varchar2(10) := 'COUNTER'; -- Cumulative sums (orders, errors)

   c_default_tenant constant varchar2(100) := 'default';

    --------------------------------------------------------------------------
    -- SESSION LIFECYCLE  (CRITICAL FOR POOLED CONNECTIONS)
    --------------------------------------------------------------------------

    /**
     * Clears ALL session-scoped state: span stack + injected W3C context.
     * Call this at the entry point of every pooled request (ORDS handler,
     * scheduler job body, etc.) so a dangling span from a previous request
     * on the same physical session cannot leak its trace or its tenant.
     *
     * Cheap and idempotent. When in doubt, call it.
     */
   procedure reset_context;

    --------------------------------------------------------------------------
    -- SPAN MANAGEMENT
    --------------------------------------------------------------------------

    /**
     * Starts a new span and pushes it onto the internal stack.
     * Does NOT write to the queue yet (end_span does).
     *
     * The tenant given here becomes the tenant of this span and is inherited
     * by all child spans and all logs emitted while it is active. Set it once,
     * at the trace root.
     *
     * @param p_operation   Operation name (e.g. 'process_order'). NULL = auto-detect.
     * @param p_tenant      Tenant for this span's scope. NULL = inherit from
     *                      parent span, or 'default' at the root.
     * @param p_force_trace If TRUE, bypasses the activation manager / sampling.
     * @return Span ID. Safe to ignore; nesting is handled by the stack.
     */
   function start_span (
      p_operation   in varchar2,
      p_tenant      in varchar2 default null,
      p_force_trace in boolean  default false
   ) return varchar2;

    /**
     * Procedure form of start_span for callers who do not want the return
     * value. Nesting is handled internally by the stack, so the id is
     * genuinely optional. Removes the "l_waste := ..." antipattern.
     */
   procedure start_span (
      p_operation   in varchar2,
      p_tenant      in varchar2 default null,
      p_force_trace in boolean  default false
   );

    /**
     * Ends the current active span: computes duration, builds JSON,
     * enqueues, and pops the stack. Emits with the span's own tenant.
     */
   procedure end_span (
      p_status_code in varchar2 default 'OK',
      p_status_msg  in varchar2 default null
   );

    --------------------------------------------------------------------------
    -- TELEMETRY SIGNALS
    --------------------------------------------------------------------------
    -- One-line, compile-time-safe attribute overloads via attr().
    -- Prefer these over p_attrs_json: no string building, no escaping,
    -- no silent parse loss.
    --
    --   PLTelemetry.log('WARN', 'msg', attr('user','ADMIN'));
    --   PLTelemetry.log('WARN', 'msg', attr('user','ADMIN'), attr('src','SQLDev'));
    --------------------------------------------------------------------------

    /**
     * Log message. Correlates with the active span if present, otherwise
     * emitted standalone (subject to the activation manager).
     *
     * @param p_attrs      Structured attributes (associative array).
     * @param p_attrs_json Attributes as a JSON object string. On parse failure
     *                     the log is STILL emitted, the raw string preserved
     *                     under '_attrs_raw' and flagged '_attrs_parse_error'.
     *                     Prefer the attr() overloads for hand-written attrs.
     * @param p_tenant_id  Per-call tenant override (wins over span tenant).
     */
   procedure log (
      p_level      in varchar2, -- INFO, WARN, ERROR, DEBUG
      p_message    in varchar2,
      p_attrs      in t_attributes default cast ( null as t_attributes ),
      p_attrs_json in clob         default null,
      p_tenant_id  in varchar2     default null
   );

   -- Safe one-liner overloads (compile-time checked, no parsing).
   procedure log (
      p_level     in varchar2,
      p_message   in varchar2,
      p_a1        in t_attribute,
      p_tenant_id in varchar2 default null
   );

   procedure log (
      p_level     in varchar2,
      p_message   in varchar2,
      p_a1        in t_attribute,
      p_a2        in t_attribute,
      p_tenant_id in varchar2 default null
   );

   procedure log (
      p_level     in varchar2,
      p_message   in varchar2,
      p_a1        in t_attribute,
      p_a2        in t_attribute,
      p_a3        in t_attribute,
      p_tenant_id in varchar2 default null
   );

    /**
     * Record a metric. Writes immediately to PLT_QUEUE.
     * Same attribute/tenant rules as log().
     */
   procedure log_metric (
      p_name       in varchar2,
      p_value      in number,
      p_type       in varchar2     default c_metric_gauge,
      p_unit       in varchar2     default '1',
      p_attrs      in t_attributes default cast ( null as t_attributes ),
      p_attrs_json in clob         default null,
      p_tenant_id  in varchar2     default null
   );

   procedure log_metric (
      p_name      in varchar2,
      p_value     in number,
      p_a1        in t_attribute,
      p_type      in varchar2 default c_metric_gauge,
      p_unit      in varchar2 default '1',
      p_tenant_id in varchar2 default null
   );

    --------------------------------------------------------------------------
    -- CONTEXT & HELPERS
    --------------------------------------------------------------------------

    /**
     * Quickly build an attribute record. Designed to be passed inline to the
     * log()/log_metric() overloads above.
     */
   function attr (
      k varchar2,
      v varchar2
   ) return t_attribute;

    /**
     * Auto-detects the calling context (package.procedure) via UTL_CALL_STACK.
     */
   function auto_detect_context return varchar2;

    /**
     * Injects an upstream W3C traceparent so this session continues an
     * externally-started trace. Cleared by reset_context().
     */
   procedure w3c_inject_context (
      p_traceparent varchar2
   );

    --------------------------------------------------------------------------
    -- QUEUE & HEALTH
    --------------------------------------------------------------------------

    /**
     * Processes pending items in PLT_QUEUE. Call from a scheduled job.
     */
   procedure process_queue (
      p_batch_size number default 50
   );

   function is_agent_healthy return boolean;

end pltelemetry;
/