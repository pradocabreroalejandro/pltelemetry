set define off;

create or replace package body pltelemetry as

    -- =========================================================================
    -- INTERNAL STATE
    -- The ONLY session state is the span stack + injected W3C context.
    -- Both are cleared by reset_context(). There is NO global tenant:
    -- tenant lives on each span and is resolved per signal.
    --
    -- Observability: this source carries plcrumbs [LOG:debug] breadcrumbs at
    -- key capture points. They are plain SQL comments and the source compiles
    -- and runs as-is. What instrument.py substitutes for each crumb is not this
    -- file's concern.
    -- =========================================================================

    type t_span_context is record (
        trace_id       varchar2(32),
        span_id        varchar2(16),
        parent_span_id varchar2(16),
        operation      varchar2(1000),
        tenant         varchar2(100),
        start_time     timestamp with time zone,
        start_cpu      number
    );

    type t_span_stack is table of t_span_context index by binary_integer;

    g_span_stack t_span_stack;
    g_stack_ptr  binary_integer := 0;

    -- Externally injected W3C context (upstream trace continuation)
    g_current_trace_id   varchar2(32);
    g_external_parent_id varchar2(16);

    c_disabled        constant varchar2(16)   := 'DISABLED';
    c_max_stack_depth constant binary_integer := 100;

    -- =========================================================================
    -- PRIVATE HELPERS
    -- =========================================================================

    /**
     * Hex correlation id. SYS_GUID is self-contained (no grants, no external
     * deps) and collision-safe. It is NOT cryptographically random: the high
     * bytes carry host/timestamp structure. For OTel-grade random ids swap
     * this for DBMS_CRYPTO.RANDOMBYTES (requires EXECUTE grant). For log/trace
     * correlation, uniqueness is what matters, so SYS_GUID is the right call.
     */
    function generate_hex_id(p_length number) return varchar2 is
        l_hex varchar2(64);
    begin
        l_hex := lower(rawtohex(sys_guid()));            -- 32 hex chars
        if p_length > 32 then
            l_hex := l_hex || lower(rawtohex(sys_guid())); -- up to 64
        end if;
        return substr(l_hex, 1, p_length);
    end;

    function iso_date(p_date timestamp with time zone) return varchar2 is
    begin
        return to_char(p_date at time zone 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.FF6"Z"');
    end;

    -- Elapsed milliseconds between two timestamps (interval computed once).
    function elapsed_ms(
        p_from timestamp with time zone,
        p_to   timestamp with time zone
    ) return number is
        l_d interval day to second := p_to - p_from;
    begin
        return extract(day    from l_d) * 86400000
             + extract(hour   from l_d) * 3600000
             + extract(minute from l_d) * 60000
             + extract(second from l_d) * 1000;
    end;

    -- Current tenant = tenant of the active (top) span, else 'default'.
    -- The top frame always carries a resolved tenant, even when disabled,
    -- so inheritance chains correctly.
    function current_tenant return varchar2 is
    begin
        if g_stack_ptr > 0 then
            return nvl(g_span_stack(g_stack_ptr).tenant, c_default_tenant);
        end if;
        return c_default_tenant;
    end;

    -- Per-signal tenant precedence: explicit override > active span > default.
    function resolve_tenant(p_tenant_id varchar2) return varchar2 is
    begin
        if p_tenant_id is not null then
            return nvl(trim(p_tenant_id), c_default_tenant);
        end if;
        return current_tenant();
    end;

    -- Auto-detect caller (package.procedure), skipping our own frames.
    function auto_detect_context return varchar2 is
        l_depth     pls_integer;
        l_unit_name varchar2(4000);
    begin
        l_depth := utl_call_stack.dynamic_depth;
        for i in 2 .. l_depth loop
            l_unit_name := utl_call_stack.concatenate_subprogram(
                               utl_call_stack.subprogram(i));
            if l_unit_name is not null
               and upper(l_unit_name) not like '%PLTELEMETRY%' then
                return l_unit_name;
            end if;
        end loop;
        return 'ANONYMOUS_BLOCK';
    exception
        when others then
            return 'UNKNOWN_CONTEXT';
    end;

    -- Internal error logger (autonomous, captures full stack, never throws).
    procedure log_internal_error(p_msg varchar2) is
        pragma autonomous_transaction;
        l_full_msg varchar2(4000);
        l_tenant   varchar2(100) := current_tenant();
        l_trace_id varchar2(32);
        l_span_id  varchar2(16);
    begin
        if g_stack_ptr > 0 then
            l_trace_id := g_span_stack(g_stack_ptr).trace_id;
            l_span_id  := g_span_stack(g_stack_ptr).span_id;
        end if;

        l_full_msg := substr(
            p_msg || chr(10)
            || 'Stack: '     || dbms_utility.format_error_stack || chr(10)
            || 'Backtrace: ' || dbms_utility.format_error_backtrace,
            1, 4000);

        insert into plt_telemetry_errors (
            error_message, module_name, tenant_id, trace_id, span_id
        ) values (
            l_full_msg, 'PLTelemetry', l_tenant, l_trace_id,
            case when l_span_id = c_disabled then null else l_span_id end
        );
        commit;
    exception
        when others then rollback;
    end;

    -- Fire-and-forget queue writer. Autonomous so telemetry survives a caller
    -- ROLLBACK and never blocks/poisons the business transaction.
    procedure enqueue(p_type varchar2, p_payload clob, p_tenant varchar2) is
        pragma autonomous_transaction;
    begin
        insert into plt_queue_writer (item_type, payload, tenant_id)
        values (p_type, p_payload, nvl(p_tenant, c_default_tenant));
        commit;
    exception
        when others then
            rollback;
            log_internal_error('Enqueue failed');
    end;

    function attrs_to_json(p_attrs t_attributes) return json_object_t is
        l_json json_object_t := json_object_t();
        l_idx  binary_integer;
    begin
        if p_attrs.count > 0 then
            l_idx := p_attrs.first;
            while l_idx is not null loop
                l_json.put(p_attrs(l_idx).key, p_attrs(l_idx).value);
                l_idx := p_attrs.next(l_idx);
            end loop;
        end if;
        return l_json;
    exception
        when others then return json_object_t();
    end;

    /**
     * Attaches attributes to a signal payload.
     * p_attrs_json takes precedence when present. On parse failure the signal
     * is NOT dropped: the raw string is preserved under '_attrs_raw' and the
     * payload is flagged '_attrs_parse_error' so the loss is visible. If a
     * structured p_attrs was also supplied it is used as the fallback.
     */
    procedure apply_attributes(
        io_json      in out nocopy json_object_t,
        p_attrs      in t_attributes,
        p_attrs_json in clob
    ) is
        l_parsed json_object_t;
    begin
        if p_attrs_json is not null and dbms_lob.getlength(p_attrs_json) > 0 then
            begin
                l_parsed := json_object_t.parse(p_attrs_json);  -- [LOG:debug]
                io_json.put('attributes', l_parsed);
            exception
                when others then
                    io_json.put('_attrs_parse_error', true);
                    io_json.put('_attrs_raw',
                                dbms_lob.substr(p_attrs_json, 4000, 1));
                    if p_attrs.count > 0 then
                        io_json.put('attributes', attrs_to_json(p_attrs));
                    end if;
            end;
        elsif p_attrs.count > 0 then
            io_json.put('attributes', attrs_to_json(p_attrs));
        end if;
    end;

    -- Restore DBMS_APPLICATION_INFO action to reflect the new top span.
    procedure sync_action is
    begin
        if g_stack_ptr > 0
           and g_span_stack(g_stack_ptr).span_id != c_disabled then
            dbms_application_info.set_action(
                'SPAN:' || substr(g_span_stack(g_stack_ptr).operation, 1, 30));
        else
            dbms_application_info.set_action(null);
        end if;
    end;

    -- Decides whether a log/metric should be emitted and, if so, resolves the
    -- active-span correlation. Returns FALSE to suppress: inside an unsampled
    -- span, or standalone when the activation manager says no.
    function should_emit(
        p_context  in  varchar2,
        o_trace_id out varchar2,
        o_span_id  out varchar2
    ) return boolean is
    begin
        o_trace_id := null;
        o_span_id  := null;
        if g_stack_ptr > 0 then
            if g_span_stack(g_stack_ptr).span_id = c_disabled then
                return false;
            end if;
            o_trace_id := g_span_stack(g_stack_ptr).trace_id;
            o_span_id  := g_span_stack(g_stack_ptr).span_id;
            return true;
        end if;
        return plt_activation_manager.should_trace(p_context);
    end;

    -- =========================================================================
    -- SESSION LIFECYCLE
    -- =========================================================================

    procedure reset_context is
    begin
        g_span_stack.delete;
        g_stack_ptr          := 0;
        g_current_trace_id   := null;
        g_external_parent_id := null;
        dbms_application_info.set_action(null);
    end;

    -- =========================================================================
    -- SPAN MANAGEMENT
    -- =========================================================================

    function start_span(
        p_operation   in varchar2,
        p_tenant      in varchar2 default null,
        p_force_trace in boolean  default false
    ) return varchar2 is
        l_ctx    t_span_context;
        l_op     varchar2(1000);
        l_should boolean;
        l_found  boolean := false;
    begin
        -- Guard against a runaway stack (missing end_span). Never grow forever.
        if g_stack_ptr >= c_max_stack_depth then
            log_internal_error('start_span: max stack depth reached, '
                             || 'span suppressed (missing end_span?)');
            l_ctx.span_id := c_disabled;
            l_ctx.tenant  := resolve_tenant(p_tenant);
            g_stack_ptr := g_stack_ptr + 1;
            g_span_stack(g_stack_ptr) := l_ctx;
            return null;
        end if;

        l_op            := nvl(p_operation, auto_detect_context());  -- [LOG:debug]
        -- Tenant is resolved once, here, and frozen onto the span.
        l_ctx.operation := substr(l_op, 1, 900);
        l_ctx.tenant    := resolve_tenant(p_tenant);                 -- [LOG:debug]

        -- Activation decision.
        if (g_current_trace_id is not null and g_external_parent_id is not null)
           or p_force_trace then
            l_should := true;
        else
            l_should := plt_activation_manager.should_trace(l_op);
        end if;

        -- Not sampled: push a ghost that still carries the tenant (so an
        -- enabled child can inherit it) but emits nothing.
        if not l_should then
            l_ctx.span_id := c_disabled;
            g_stack_ptr := g_stack_ptr + 1;
            g_span_stack(g_stack_ptr) := l_ctx;
            return null;
        end if;

        -- Enabled span.
        l_ctx.span_id    := generate_hex_id(16);                     -- [LOG:debug]
        l_ctx.start_time := systimestamp;
        l_ctx.start_cpu  := dbms_utility.get_cpu_time;

        -- Parent = nearest ENABLED ancestor on the stack. Disabled frames are
        -- skipped: a sampled span under unsampled ancestors starts a NEW trace
        -- rather than pointing parent_span_id at a span that was never emitted.
        for i in reverse 1 .. g_stack_ptr loop
            if g_span_stack(i).span_id != c_disabled then
                l_ctx.trace_id       := g_span_stack(i).trace_id;
                l_ctx.parent_span_id := g_span_stack(i).span_id;
                l_found := true;
                exit;
            end if;
        end loop;

        if not l_found then
            if g_current_trace_id is not null
               and g_external_parent_id is not null then
                l_ctx.trace_id       := g_current_trace_id;
                l_ctx.parent_span_id := g_external_parent_id;
                -- Consume both once: children inherit trace_id via the stack,
                -- and no stale upstream context survives into the next request.
                g_current_trace_id   := null;
                g_external_parent_id := null;
            else
                l_ctx.trace_id       := generate_hex_id(32);
                l_ctx.parent_span_id := null;
            end if;
        end if;

        g_stack_ptr := g_stack_ptr + 1;
        g_span_stack(g_stack_ptr) := l_ctx;

        sync_action;
        return l_ctx.span_id;
    exception
        when others then
            log_internal_error('start_span critical error');
            return null;
    end;

    procedure start_span(
        p_operation   in varchar2,
        p_tenant      in varchar2 default null,
        p_force_trace in boolean  default false
    ) is
        l_ignore varchar2(16);
    begin
        l_ignore := start_span(p_operation, p_tenant, p_force_trace);
    end;

    procedure end_span(
        p_status_code in varchar2 default 'OK',
        p_status_msg  in varchar2 default null
    ) is
        l_ctx         t_span_context;
        l_json_obj    json_object_t;
        l_end_time    timestamp with time zone := systimestamp;
        l_duration_ms number;
        l_cpu_ms      number;
    begin
        if g_stack_ptr is null or g_stack_ptr = 0 then
            return; -- underflow guard
        end if;

        l_ctx := g_span_stack(g_stack_ptr);
        g_span_stack.delete(g_stack_ptr);
        g_stack_ptr := g_stack_ptr - 1;

        if l_ctx.span_id = c_disabled then
            sync_action;
            return;
        end if;

        l_duration_ms := elapsed_ms(l_ctx.start_time, l_end_time);   -- [LOG:debug]

        -- GET_CPU_TIME is in centiseconds -> *10 for ms.
        l_cpu_ms := (dbms_utility.get_cpu_time - l_ctx.start_cpu) * 10;  -- [LOG:debug]

        l_json_obj := json_object_t();
        l_json_obj.put('trace_id',       l_ctx.trace_id);
        l_json_obj.put('span_id',        l_ctx.span_id);
        l_json_obj.put('operation_name', l_ctx.operation);
        l_json_obj.put('tenant_id',      nvl(l_ctx.tenant, c_default_tenant));
        l_json_obj.put('start_time',     iso_date(l_ctx.start_time));
        l_json_obj.put('end_time',       iso_date(l_end_time));
        l_json_obj.put('duration_ms',    l_duration_ms);
        l_json_obj.put('cpu_ms',         l_cpu_ms);
        l_json_obj.put('status',         p_status_code);

        if l_ctx.parent_span_id is not null then
            l_json_obj.put('parent_span_id', l_ctx.parent_span_id);
        end if;
        if p_status_msg is not null then
            l_json_obj.put('status_message', p_status_msg);
        end if;

        enqueue('TRACE', l_json_obj.to_clob(), l_ctx.tenant);
        sync_action;
    exception
        when others then
            log_internal_error('end_span error');
    end;

    -- =========================================================================
    -- TELEMETRY SIGNALS
    -- =========================================================================

    procedure log(
        p_level      in varchar2,
        p_message    in varchar2,
        p_attrs      in t_attributes default cast(null as t_attributes),
        p_attrs_json in clob         default null,
        p_tenant_id  in varchar2     default null
    ) is
        l_json_obj json_object_t;
        l_trace_id varchar2(32);
        l_span_id  varchar2(16);
        l_context  varchar2(200);
        l_tenant   varchar2(100) := resolve_tenant(p_tenant_id);
    begin
        l_context := auto_detect_context();                          -- [LOG:debug]

        if not should_emit(l_context, l_trace_id, l_span_id) then
            return;
        end if;

        l_json_obj := json_object_t();
        l_json_obj.put('severity',      p_level);
        l_json_obj.put('message',       p_message);
        l_json_obj.put('code_location', l_context);
        l_json_obj.put('tenant_id',     l_tenant);
        l_json_obj.put('timestamp',     iso_date(systimestamp));

        if l_trace_id is not null then
            l_json_obj.put('trace_id', l_trace_id);
            l_json_obj.put('span_id',  l_span_id);
        end if;

        apply_attributes(l_json_obj, p_attrs, p_attrs_json);

        enqueue('LOG', l_json_obj.to_clob(), l_tenant);
    exception
        when others then
            log_internal_error('log error');
    end;

    -- Safe one-liner overloads (compile-time checked, no JSON parsing).
    procedure log(
        p_level     in varchar2,
        p_message   in varchar2,
        p_a1        in t_attribute,
        p_tenant_id in varchar2 default null
    ) is
        l_attrs t_attributes;
    begin
        l_attrs(1) := p_a1;
        log(p_level, p_message, p_attrs => l_attrs, p_tenant_id => p_tenant_id);
    end;

    procedure log(
        p_level     in varchar2,
        p_message   in varchar2,
        p_a1        in t_attribute,
        p_a2        in t_attribute,
        p_tenant_id in varchar2 default null
    ) is
        l_attrs t_attributes;
    begin
        l_attrs(1) := p_a1;
        l_attrs(2) := p_a2;
        log(p_level, p_message, p_attrs => l_attrs, p_tenant_id => p_tenant_id);
    end;

    procedure log(
        p_level     in varchar2,
        p_message   in varchar2,
        p_a1        in t_attribute,
        p_a2        in t_attribute,
        p_a3        in t_attribute,
        p_tenant_id in varchar2 default null
    ) is
        l_attrs t_attributes;
    begin
        l_attrs(1) := p_a1;
        l_attrs(2) := p_a2;
        l_attrs(3) := p_a3;
        log(p_level, p_message, p_attrs => l_attrs, p_tenant_id => p_tenant_id);
    end;

    procedure log_metric(
        p_name       in varchar2,
        p_value      in number,
        p_type       in varchar2     default c_metric_gauge,
        p_unit       in varchar2     default '1',
        p_attrs      in t_attributes default cast(null as t_attributes),
        p_attrs_json in clob         default null,
        p_tenant_id  in varchar2     default null
    ) is
        l_json_obj json_object_t;
        l_trace_id varchar2(32);
        l_span_id  varchar2(16);
        l_context  varchar2(200);
        l_tenant   varchar2(100) := resolve_tenant(p_tenant_id);
    begin
        l_context := auto_detect_context();                          -- [LOG:debug]

        if not should_emit(l_context, l_trace_id, l_span_id) then
            return;
        end if;

        l_json_obj := json_object_t();
        l_json_obj.put('name',          p_name);
        l_json_obj.put('value',         p_value);
        l_json_obj.put('type',          p_type);
        l_json_obj.put('unit',          p_unit);
        l_json_obj.put('tenant_id',     l_tenant);
        l_json_obj.put('timestamp',     iso_date(systimestamp));
        l_json_obj.put('code_location', l_context);

        if l_trace_id is not null then
            l_json_obj.put('trace_id', l_trace_id);
            l_json_obj.put('span_id',  l_span_id);
        end if;

        apply_attributes(l_json_obj, p_attrs, p_attrs_json);

        enqueue('METRIC', l_json_obj.to_clob(), l_tenant);
    exception
        when others then
            log_internal_error('log_metric error');
    end;

    procedure log_metric(
        p_name      in varchar2,
        p_value     in number,
        p_a1        in t_attribute,
        p_type      in varchar2 default c_metric_gauge,
        p_unit      in varchar2 default '1',
        p_tenant_id in varchar2 default null
    ) is
        l_attrs t_attributes;
    begin
        l_attrs(1) := p_a1;
        log_metric(p_name, p_value, p_type => p_type, p_unit => p_unit,
                   p_attrs => l_attrs, p_tenant_id => p_tenant_id);
    end;

    -- =========================================================================
    -- CONTEXT & HELPERS
    -- =========================================================================

    function attr(k varchar2, v varchar2) return t_attribute is
        l_rec t_attribute;
    begin
        l_rec.key   := k;
        l_rec.value := v;
        return l_rec;
    end;

    procedure w3c_inject_context(p_traceparent varchar2) is
    begin
        if p_traceparent is null or length(p_traceparent) < 55 then
            return;
        end if;
        g_current_trace_id   := substr(p_traceparent, 4, 32);        -- [LOG:debug]
        g_external_parent_id := substr(p_traceparent, 37, 16);       -- [LOG:debug]
    exception
        when others then null;
    end;

    -- =========================================================================
    -- QUEUE & HEALTH
    -- =========================================================================

    procedure process_queue(p_batch_size number default 50) is
        cursor c_pending is
            select id, item_type, payload
              from plt_queue_writer
             where status = 'NEW'
             order by id asc
             fetch first p_batch_size rows only;
        l_err_msg varchar2(4000);
    begin
        plt_otlp_bridge.init(null, null, null);
        for r in c_pending loop
            begin
                plt_otlp_bridge.process_payload(r.item_type, r.payload);
                update plt_queue_writer
                   set status = 'PROCESSED', updated_at = systimestamp
                 where id = r.id;
            exception
                when others then
                    l_err_msg := substr(                             -- [LOG:debug]
                        'Stack: '     || dbms_utility.format_error_stack || chr(10)
                        || 'Backtrace: ' || dbms_utility.format_error_backtrace,
                        1, 4000);
                    update plt_queue_writer
                       set status        = 'FAILED',
                           error_message = l_err_msg,
                           retry_count   = retry_count + 1,
                           updated_at    = systimestamp
                     where id = r.id;
            end;
        end loop;
        commit;
    exception
        when others then
            rollback;
            log_internal_error('process_queue fatal error');
    end;

    function is_agent_healthy return boolean is
        l_mode      varchar2(20);
        l_last_beat timestamp with time zone;
        l_threshold constant number := 45;
    begin
        select pulse_mode, last_heartbeat
          into l_mode, l_last_beat                                   -- [LOG:debug]
          from plt_agent_registry
         where agent_id = 'PRIMARY_AGENT'
         fetch first 1 rows only;

        if elapsed_ms(l_last_beat, systimestamp) / 1000 > l_threshold then
            return false;              -- stale heartbeat: it's dead, Jim
        end if;
        if l_mode = 'COMA' then
            return false;
        end if;
        return true;
    exception
        when no_data_found then
            return false;              -- no agent -> let PL/SQL process
        when others then
            return false;
    end;

end pltelemetry;
/