CREATE OR REPLACE PACKAGE BODY PLTELEMETRY.PLT_DB_METRIC_READER AS

    -- Helper para construir JSON simple de tags
    FUNCTION tag(k VARCHAR2, v VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '{"' || k || '":"' || v || '"}';
    END;

    ----------------------------------------------------------------------------
    -- 1. SYSTEM METRICS
    ----------------------------------------------------------------------------
    FUNCTION get_system_metrics RETURN t_plt_metric_tab PIPELINED IS
        l_row t_plt_metric_row;
    BEGIN
        -- ---------------------------------------------------------------------
        -- A. MÉTRICAS DE CPU Y HOST (Desde V$OSSTAT)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT stat_name, value 
            FROM v$osstat 
            WHERE stat_name IN ('LOAD', 'NUM_CPUS', 'BUSY_TIME', 'IDLE_TIME')
        ) LOOP
            IF r.stat_name = 'LOAD' THEN
                 PIPE ROW(t_plt_metric_row('oracle_os_load_average', r.value, 'GAUGE', NULL));
            ELSIF r.stat_name = 'NUM_CPUS' THEN
                 PIPE ROW(t_plt_metric_row('oracle_os_num_cpus', r.value, 'GAUGE', NULL));
            END IF;
        END LOOP;

        -- ---------------------------------------------------------------------
        -- B. CONTADORES REALES (V$SYSSTAT)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT name, value 
            FROM v$sysstat 
            WHERE name IN (
                -- Transaccional
                'user commits',
                'user rollbacks',
                'logons cumulative',
                'user calls',
                
                -- I/O
                'physical reads',
                'physical writes',
                'physical read IO requests',
                'physical write IO requests',
                'redo size',
                
                -- Cache & Memoria
                'session logical reads',
                'db block gets',
                'consistent gets',
                'parse count (total)',
                'parse count (hard)',
                'execute count',
                'sorts (memory)',
                'sorts (disk)',
                
                -- Red
                'bytes sent via SQL*Net to client',
                'bytes received via SQL*Net from client',
                
                -- Time
                'DB time',
                'CPU used by this session'
            )
        ) LOOP
            -- Mapeo a nombres estandarizados (Snake Case) y limpieza de paréntesis
            PIPE ROW(t_plt_metric_row(
                'oracle_' || REPLACE(REPLACE(REPLACE(LOWER(r.name), ' ', '_'), '*', ''), '(', ''),
                r.value, 
                'COUNTER', 
                NULL
            ));
        END LOOP;
        
        -- ---------------------------------------------------------------------
        -- C. MÉTRICAS DE ESTADO (GAUGES Calculados al momento)
        -- ---------------------------------------------------------------------
        -- Sessions Current
        FOR r IN (SELECT COUNT(*) cnt FROM v$session) LOOP
            PIPE ROW(t_plt_metric_row('oracle_session_count_current', r.cnt, 'GAUGE', NULL));
        END LOOP;
        
        -- Procesos Current
        FOR r IN (SELECT COUNT(*) cnt FROM v$process) LOOP
            PIPE ROW(t_plt_metric_row('oracle_process_count_current', r.cnt, 'GAUGE', NULL));
        END LOOP;

        RETURN;
    EXCEPTION WHEN OTHERS THEN RETURN; 
    END;

    ----------------------------------------------------------------------------
    -- 2. SESSION METRICS
    ----------------------------------------------------------------------------
    FUNCTION get_session_metrics RETURN t_plt_metric_tab PIPELINED IS
    BEGIN
        -- Sesiones Activas
        FOR r IN (SELECT count(*) cnt FROM v$session WHERE type='USER' AND status='ACTIVE') LOOP
            PIPE ROW(t_plt_metric_row('oracle_sessions_active', r.cnt, 'GAUGE', NULL));
        END LOOP;

        -- Sesiones Bloqueadas
        FOR r IN (SELECT count(*) cnt FROM v$session WHERE blocking_session IS NOT NULL) LOOP
            PIPE ROW(t_plt_metric_row('oracle_sessions_blocked', r.cnt, 'GAUGE', NULL));
        END LOOP;

        -- Utilización de Procesos (%)
        FOR r IN (SELECT current_utilization, limit_value FROM v$resource_limit WHERE resource_name = 'processes') LOOP
             IF r.limit_value != 'UNLIMITED' THEN
                PIPE ROW(t_plt_metric_row('oracle_process_utilization_percent', 
                         ROUND((r.current_utilization / TO_NUMBER(r.limit_value)) * 100, 2), 
                         'GAUGE', NULL));
             END IF;
        END LOOP;
        
        RETURN;
    END;

    ----------------------------------------------------------------------------
    -- 3. STORAGE METRICS (Iterador)
    ----------------------------------------------------------------------------
    FUNCTION get_storage_metrics RETURN t_plt_metric_tab PIPELINED IS
    BEGIN
        -- Itera sobre TODOS los tablespaces
        FOR r IN (
            SELECT tablespace_name, used_percent 
            FROM dba_tablespace_usage_metrics
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_tablespace_usage_percent', 
                ROUND(r.used_percent, 2), 
                'GAUGE', 
                tag('tablespace', r.tablespace_name)
            ));
        END LOOP;
        
        RETURN;
    END;

END PLT_DB_METRIC_READER;
/