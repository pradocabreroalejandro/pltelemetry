CREATE OR REPLACE PACKAGE BODY PLTELEMETRY.PLT_DB_METRIC_READER AS

    -- Helper to build JSON tags safely
    FUNCTION tag(k VARCHAR2, v VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '{"' || REPLACE(k, '"', '\"') || '":"' || REPLACE(v, '"', '\"') || '"}';
    END;

    ----------------------------------------------------------------------------
    -- 1. SYSTEM METRICS (Oracle 23ai Enhanced)
    ----------------------------------------------------------------------------
    FUNCTION get_system_metrics RETURN t_plt_metric_tab PIPELINED IS
        l_row t_plt_metric_row;
    BEGIN
        -- ---------------------------------------------------------------------
        -- A. CPU AND HOST METRICS (From V$OSSTAT)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT stat_name, value 
            FROM v$osstat 
            WHERE stat_name IN ('LOAD', 'NUM_CPUS', 'BUSY_TIME', 'IDLE_TIME', 
                                'PHYSICAL_MEMORY_BYTES', 'NUM_CPU_CORES', 
                                'NUM_CPU_SOCKETS')
        ) LOOP
            CASE r.stat_name
                WHEN 'LOAD' THEN
                    PIPE ROW(t_plt_metric_row('oracle_os_load_average', r.value, 'GAUGE', NULL));
                WHEN 'NUM_CPUS' THEN
                    PIPE ROW(t_plt_metric_row('oracle_os_num_cpus', r.value, 'GAUGE', NULL));
                WHEN 'NUM_CPU_CORES' THEN
                    PIPE ROW(t_plt_metric_row('oracle_os_num_cpu_cores', r.value, 'GAUGE', NULL));
                WHEN 'NUM_CPU_SOCKETS' THEN
                    PIPE ROW(t_plt_metric_row('oracle_os_num_cpu_sockets', r.value, 'GAUGE', NULL));
                WHEN 'PHYSICAL_MEMORY_BYTES' THEN
                    PIPE ROW(t_plt_metric_row('oracle_os_physical_memory_bytes', r.value, 'GAUGE', NULL));
                WHEN 'BUSY_TIME' THEN
                    PIPE ROW(t_plt_metric_row('oracle_os_cpu_busy_time_seconds', ROUND(r.value/100, 2), 'COUNTER', NULL));
                WHEN 'IDLE_TIME' THEN
                    PIPE ROW(t_plt_metric_row('oracle_os_cpu_idle_time_seconds', ROUND(r.value/100, 2), 'COUNTER', NULL));
            END CASE;
        END LOOP;

        -- ---------------------------------------------------------------------
        -- B. DATABASE PERFORMANCE COUNTERS (V$SYSSTAT)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT name, value 
            FROM v$sysstat 
            WHERE name IN (
                -- Transactional
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
                'redo log space requests',
                
                -- Cache & Memory
                'session logical reads',
                'db block gets',
                'consistent gets',
                'consistent gets from cache',
                'db block gets from cache',
                'parse count (total)',
                'parse count (hard)',
                'parse count (fail)',
                'execute count',
                'sorts (memory)',
                'sorts (disk)',
                'sorts (rows)',
                
                -- Network
                'bytes sent via SQL*Net to client',
                'bytes received via SQL*Net from client',
                'SQL*Net roundtrips to/from client',
                
                -- Time & Wait
                'DB time',
                'CPU used by this session',
                'DB CPU',
                'background cpu time',
                
                -- 23ai: In-Memory
                'IM scan blocks',
                'IM scan rows',
                'IM scan rows optimized',
                
                -- 23ai: Automatic Indexing
                'auto index actions',
                'auto index actions completed'
            )
        ) LOOP
            -- Map to standardized names (Snake Case)
            PIPE ROW(t_plt_metric_row(
                'oracle_' || REPLACE(REPLACE(REPLACE(LOWER(r.name), ' ', '_'), '*', ''), '(', ''),
                r.value, 
                'COUNTER', 
                NULL
            ));
        END LOOP;
        
        -- ---------------------------------------------------------------------
        -- C. CACHE HIT RATIOS (Calculated Gauges)
        -- ---------------------------------------------------------------------
        DECLARE
            l_logical_reads NUMBER;
            l_physical_reads NUMBER;
            l_hit_ratio NUMBER;
        BEGIN
            SELECT SUM(CASE WHEN name IN ('session logical reads', 'db block gets', 'consistent gets') THEN value ELSE 0 END),
                   SUM(CASE WHEN name = 'physical reads' THEN value ELSE 0 END)
            INTO l_logical_reads, l_physical_reads
            FROM v$sysstat
            WHERE name IN ('session logical reads', 'db block gets', 'consistent gets', 'physical reads');
            
            IF l_logical_reads > 0 THEN
                l_hit_ratio := ROUND((1 - (l_physical_reads / l_logical_reads)) * 100, 2);
                PIPE ROW(t_plt_metric_row('oracle_buffer_cache_hit_ratio', l_hit_ratio, 'GAUGE', NULL));
            END IF;
        END;
        
        -- Library Cache Hit Ratio
        DECLARE
            l_lib_hit_ratio NUMBER;
        BEGIN
            SELECT ROUND(SUM(pinhits) / NULLIF(SUM(pins), 0) * 100, 2)
            INTO l_lib_hit_ratio
            FROM v$librarycache;
            
            IF l_lib_hit_ratio IS NOT NULL THEN
                PIPE ROW(t_plt_metric_row('oracle_library_cache_hit_ratio', l_lib_hit_ratio, 'GAUGE', NULL));
            END IF;
        END;
        
        -- Dictionary Cache Hit Ratio
        DECLARE
            l_dict_hit_ratio NUMBER;
        BEGIN
            SELECT ROUND(SUM(gets - getmisses) / NULLIF(SUM(gets), 0) * 100, 2)
            INTO l_dict_hit_ratio
            FROM v$rowcache
            WHERE gets > 0;
            
            IF l_dict_hit_ratio IS NOT NULL THEN
                PIPE ROW(t_plt_metric_row('oracle_dictionary_cache_hit_ratio', l_dict_hit_ratio, 'GAUGE', NULL));
            END IF;
        END;

        -- ---------------------------------------------------------------------
        -- D. WAIT CLASS METRICS (V$SYSTEM_WAIT_CLASS)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT wait_class, total_waits, time_waited
            FROM v$system_wait_class
            WHERE wait_class != 'Idle'
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_wait_class_' || LOWER(r.wait_class) || '_waits',
                r.total_waits,
                'COUNTER',
                tag('wait_class', r.wait_class)
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_wait_class_' || LOWER(r.wait_class) || '_time_ms',
                r.time_waited,
                'COUNTER',
                tag('wait_class', r.wait_class)
            ));
        END LOOP;

        -- ---------------------------------------------------------------------
        -- E. INSTANCE EFFICIENCY PERCENTAGES
        -- ---------------------------------------------------------------------
        -- Redo Allocation Efficiency
        DECLARE
            l_eff NUMBER;
        BEGIN
            SELECT ROUND(100 - (SUM(CASE WHEN name = 'redo log space requests' THEN value ELSE 0 END) /
                         NULLIF(SUM(CASE WHEN name = 'redo size' THEN value ELSE 0 END), 0) * 100), 2)
            INTO l_eff
            FROM v$sysstat
            WHERE name IN ('redo log space requests', 'redo size');
            
            IF l_eff IS NOT NULL THEN
                PIPE ROW(t_plt_metric_row('oracle_redo_allocation_efficiency', GREATEST(0, l_eff), 'GAUGE', NULL));
            END IF;
        END;

        -- Soft Parse Ratio
        DECLARE
            l_soft_parse_ratio NUMBER;
        BEGIN
            SELECT ROUND((1 - (SUM(CASE WHEN name = 'parse count (hard)' THEN value ELSE 0 END) /
                         NULLIF(SUM(CASE WHEN name = 'parse count (total)' THEN value ELSE 0 END), 0))) * 100, 2)
            INTO l_soft_parse_ratio
            FROM v$sysstat;
            
            IF l_soft_parse_ratio IS NOT NULL THEN
                PIPE ROW(t_plt_metric_row('oracle_soft_parse_ratio', GREATEST(0, l_soft_parse_ratio), 'GAUGE', NULL));
            END IF;
        END;

        RETURN;
    EXCEPTION WHEN OTHERS THEN 
        PLTelemetry.log('ERROR', 'Error in get_system_metrics: ' || SQLERRM);
        RETURN;
    END;

    ----------------------------------------------------------------------------
    -- 2. SESSION METRICS (Oracle 23ai Enhanced)
    ----------------------------------------------------------------------------
    FUNCTION get_session_metrics RETURN t_plt_metric_tab PIPELINED IS
    BEGIN
        -- Active Sessions
        FOR r IN (SELECT count(*) cnt FROM v$session WHERE type='USER' AND status='ACTIVE') LOOP
            PIPE ROW(t_plt_metric_row('oracle_sessions_active', r.cnt, 'GAUGE', NULL));
        END LOOP;

        -- Inactive Sessions
        FOR r IN (SELECT count(*) cnt FROM v$session WHERE type='USER' AND status='INACTIVE') LOOP
            PIPE ROW(t_plt_metric_row('oracle_sessions_inactive', r.cnt, 'GAUGE', NULL));
        END LOOP;

        -- Total User Sessions
        FOR r IN (SELECT count(*) cnt FROM v$session WHERE type='USER') LOOP
            PIPE ROW(t_plt_metric_row('oracle_sessions_total', r.cnt, 'GAUGE', NULL));
        END LOOP;

        -- Blocked Sessions
        FOR r IN (SELECT count(*) cnt FROM v$session WHERE blocking_session IS NOT NULL) LOOP
            PIPE ROW(t_plt_metric_row('oracle_sessions_blocked', r.cnt, 'GAUGE', NULL));
        END LOOP;

        -- Sessions Waiting (non-Idle)
        FOR r IN (SELECT count(*) cnt FROM v$session WHERE state='WAITING' AND wait_class != 'Idle') LOOP
            PIPE ROW(t_plt_metric_row('oracle_sessions_waiting', r.cnt, 'GAUGE', NULL));
        END LOOP;

        -- 23ai: Pluggable Database Sessions
        FOR r IN (
            SELECT con_id, COUNT(*) cnt 
            FROM v$session 
            WHERE type = 'USER'
            GROUP BY con_id
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_pdb_sessions', 
                r.cnt, 
                'GAUGE', 
                tag('con_id', TO_CHAR(r.con_id))
            ));
        END LOOP;

        -- Process Utilization (%)
        FOR r IN (
            SELECT resource_name, current_utilization, limit_value
            FROM v$resource_limit
            WHERE resource_name IN ('processes', 'sessions')
        ) LOOP
            IF r.limit_value != 'UNLIMITED' AND r.limit_value > 0 THEN
                PIPE ROW(t_plt_metric_row(
                    'oracle_resource_utilization_percent', 
                    ROUND((r.current_utilization / TO_NUMBER(r.limit_value)) * 100, 2), 
                    'GAUGE', 
                    tag('resource', r.resource_name)
                ));
            END IF;
        END LOOP;
        
        -- Top SQL by CPU (Top 5)
        FOR r IN (
            SELECT sql_id, cpu_time, executions 
            FROM (
                SELECT sql_id, cpu_time, executions
                FROM v$sql
                WHERE executions > 0
                ORDER BY cpu_time DESC
            )
            WHERE ROWNUM <= 5
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_top_sql_cpu_time',
                r.cpu_time,
                'GAUGE',
                tag('sql_id', r.sql_id)
            ));
        END LOOP;

        RETURN;
    EXCEPTION WHEN OTHERS THEN
        PLTelemetry.log('ERROR', 'Error in get_session_metrics: ' || SQLERRM);
        RETURN;
    END;

    ----------------------------------------------------------------------------
    -- 3. STORAGE METRICS (Oracle 23ai Enhanced)
    ----------------------------------------------------------------------------
    FUNCTION get_storage_metrics RETURN t_plt_metric_tab PIPELINED IS
    BEGIN
        -- Tablespace Usage
        FOR r IN (
            SELECT tablespace_name, 
                   ROUND(used_percent, 2) as used_pct,
                   ROUND(tablespace_size * 8192, 0) as total_bytes,
                   ROUND(used_space * 8192, 0) as used_bytes
            FROM dba_tablespace_usage_metrics
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_tablespace_usage_percent', 
                r.used_pct, 
                'GAUGE', 
                tag('tablespace', r.tablespace_name)
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_tablespace_size_bytes', 
                r.total_bytes, 
                'GAUGE', 
                tag('tablespace', r.tablespace_name)
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_tablespace_used_bytes', 
                r.used_bytes, 
                'GAUGE', 
                tag('tablespace', r.tablespace_name)
            ));
        END LOOP;

        -- 23ai: Datafile I/O Stats
        FOR r IN (
            SELECT file_name, tablespace_name, phywrts, phyblkwrt, readtim, writetim
            FROM dba_data_files df
            JOIN v$filestat fs ON df.file_id = fs.file#
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_datafile_physical_writes',
                r.phywrts,
                'COUNTER',
                tag('tablespace', r.tablespace_name) || ',"file":"' || r.file_name || '"'
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_datafile_write_time_ms',
                r.writetim * 10,
                'COUNTER',
                tag('tablespace', r.tablespace_name) || ',"file":"' || r.file_name || '"'
            ));
        END LOOP;

        -- 23ai: RMAN Backup Status
        FOR r IN (
            SELECT 
                MAX(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END) as last_backup_ok,
                COUNT(*) as total_backups
            FROM v$rman_status
            WHERE session_recid IN (
                SELECT MAX(session_recid) FROM v$rman_status WHERE operation = 'BACKUP'
            )
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_rman_backup_status',
                r.last_backup_ok,
                'GAUGE',
                NULL
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_rman_backup_count',
                r.total_backups,
                'COUNTER',
                NULL
            ));
        END LOOP;

        -- Undo Tablespace Usage (segment bytes vs. datafile capacity)
        FOR r IN (
            SELECT ROUND(SUM(u.bytes)/NULLIF(SUM(d.bytes),0)*100, 2) as undo_used_pct
            FROM dba_segments u
            JOIN dba_tablespaces t ON u.tablespace_name = t.tablespace_name
            JOIN dba_data_files  d ON u.tablespace_name = d.tablespace_name
            WHERE t.contents = 'UNDO'
        ) LOOP
            IF r.undo_used_pct IS NOT NULL THEN
                PIPE ROW(t_plt_metric_row(
                    'oracle_undo_usage_percent',
                    r.undo_used_pct,
                    'GAUGE',
                    NULL
                ));
            END IF;
        END LOOP;

        -- Temp Tablespace Usage
        FOR r IN (
            SELECT tablespace_name, bytes_used, bytes_free
            FROM v$temp_space_header
        ) LOOP
            IF r.bytes_used + r.bytes_free > 0 THEN
                PIPE ROW(t_plt_metric_row(
                    'oracle_temp_usage_percent',
                    ROUND((r.bytes_used / (r.bytes_used + r.bytes_free)) * 100, 2),
                    'GAUGE',
                    tag('tablespace', r.tablespace_name)
                ));
            END IF;
        END LOOP;

        RETURN;
    EXCEPTION WHEN OTHERS THEN
        PLTelemetry.log('ERROR', 'Error in get_storage_metrics: ' || SQLERRM);
        RETURN;
    END;

    ----------------------------------------------------------------------------
    -- 4. NEW: 23ai AUTOMATIC INDEXING METRICS
    ----------------------------------------------------------------------------
    FUNCTION get_indexing_metrics RETURN t_plt_metric_tab PIPELINED IS
        -- dba_auto_index_* views are only present on engineered/EE systems;
        -- use dynamic SQL so the package compiles on 23ai Free and degrades
        -- gracefully when the views are absent.
        l_view_exists NUMBER;
        l_cnt         NUMBER;
        l_tags        VARCHAR2(4000);
        TYPE t_act IS RECORD (action_type VARCHAR2(50), status VARCHAR2(50), cnt NUMBER);
        TYPE t_act_tab IS TABLE OF t_act;
        l_acts t_act_tab;
    BEGIN
        SELECT COUNT(*) INTO l_view_exists FROM all_objects
         WHERE owner='SYS' AND object_type='VIEW' AND object_name='DBA_AUTO_INDEX_ACTIONS';

        IF l_view_exists = 1 THEN
            EXECUTE IMMEDIATE
                'SELECT action_type, status, COUNT(*) cnt FROM dba_auto_index_actions GROUP BY action_type, status'
                BULK COLLECT INTO l_acts;
            FOR i IN 1..l_acts.COUNT LOOP
                PIPE ROW(t_plt_metric_row(
                    'oracle_auto_index_actions',
                    l_acts(i).cnt,
                    'COUNTER',
                    tag('action_type', l_acts(i).action_type) || ',"status":"' || l_acts(i).status || '"'
                ));
            END LOOP;
        END IF;

        SELECT COUNT(*) INTO l_view_exists FROM all_objects
         WHERE owner='SYS' AND object_type='VIEW' AND object_name='DBA_AUTO_INDEX_RECOMMENDATIONS';

        IF l_view_exists = 1 THEN
            EXECUTE IMMEDIATE
                'SELECT COUNT(*) FROM dba_auto_index_recommendations WHERE implemented = ''YES'''
                INTO l_cnt;
            PIPE ROW(t_plt_metric_row(
                'oracle_auto_index_implemented_count',
                l_cnt,
                'GAUGE',
                NULL
            ));
        END IF;

        RETURN;
    EXCEPTION WHEN OTHERS THEN
        PLTelemetry.log('ERROR', 'Error in get_indexing_metrics: ' || SQLERRM);
        RETURN;
    END;

    ----------------------------------------------------------------------------
    -- 5. TNS LISTENER & NETWORK HEALTH METRICS
    ----------------------------------------------------------------------------
    FUNCTION get_listener_metrics RETURN t_plt_metric_tab PIPELINED IS
    BEGIN
        -- ---------------------------------------------------------------------
        -- A. ACTIVE SESSIONS BY SERVICE (TNS Connection Health)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT service_name, COUNT(*) as cnt,
                   SUM(CASE WHEN status = 'ACTIVE' THEN 1 ELSE 0 END) as active,
                   SUM(CASE WHEN status = 'INACTIVE' THEN 1 ELSE 0 END) as inactive
            FROM v$session
            WHERE type = 'USER' AND service_name IS NOT NULL
            GROUP BY service_name
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_tns_service_sessions_total',
                r.cnt,
                'GAUGE',
                tag('service', r.service_name)
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_tns_service_sessions_active',
                r.active,
                'GAUGE',
                tag('service', r.service_name)
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_tns_service_sessions_inactive',
                r.inactive,
                'GAUGE',
                tag('service', r.service_name)
            ));
        END LOOP;

        -- ---------------------------------------------------------------------
        -- B. NETWORK WAIT EVENTS (TNS/Latency Related)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT event, total_waits, time_waited_micro / 1000 as time_waited_ms
            FROM v$system_event
            WHERE event IN (
                'SQL*Net message from client',
                'SQL*Net message from dblink',
                'SQL*Net more data from client',
                'SQL*Net more data to client',
                'SQL*Net roundtrips to/from client',
                'SQL*Net break/reset to client',
                'TNS-00507',
                'TNS-12537',
                'TNS-12560',
                'TNS-12170',
                'TNS-12547',
                'TNS-12583',
                'TNS-12638',
                'TNS-12699',
                'TNS-03510',
                'TNS-12660',
                'TNS-12570',
                'TNS-12535',
                'TNS-12545',
                'TNS-12546',
                'TNS-12541',
                'TNS-12543',
                'TNS-12544',
                'TNS-12557',
                'TNS-12559',
                'TNS-12565',
                'TNS-12566',
                'TNS-12631',
                'TNS-12637',
                'TNS-12640',
                'TNS-12641',
                'TNS-12645',
                'TNS-12647',
                'TNS-12648',
                'TNS-12649',
                'TNS-12650',
                'TNS-12651',
                'TNS-12652',
                'TNS-12653',
                'TNS-12654',
                'TNS-12655',
                'TNS-12656',
                'TNS-12657',
                'TNS-12658',
                'TNS-12659',
                'TNS-12661',
                'TNS-12662',
                'TNS-12663',
                'TNS-12664',
                'TNS-12665',
                'TNS-12666',
                'TNS-12667',
                'TNS-12668',
                'TNS-12669',
                'TNS-12670',
                'TNS-12671',
                'TNS-12672',
                'TNS-12673',
                'TNS-12674',
                'TNS-12675',
                'TNS-12676',
                'TNS-12677',
                'TNS-12678',
                'TNS-12679',
                'TNS-12680',
                'TNS-12681',
                'TNS-12682',
                'TNS-12683',
                'TNS-12684',
                'TNS-12685',
                'TNS-12686',
                'TNS-12687',
                'TNS-12688',
                'TNS-12689',
                'TNS-12690',
                'TNS-12691',
                'TNS-12692',
                'TNS-12693',
                'TNS-12694',
                'TNS-12695',
                'TNS-12696',
                'TNS-12697',
                'TNS-12698',
                'TNS-12700',
                'TNS-12701',
                'TNS-12702',
                'TNS-12703',
                'TNS-12704',
                'TNS-12705',
                'TNS-12706',
                'TNS-12707',
                'TNS-12708',
                'TNS-12709',
                'TNS-12710',
                'TNS-12711',
                'TNS-12712',
                'TNS-12713',
                'TNS-12714',
                'TNS-12715',
                'TNS-12500',
                'TNS-12502',
                'TNS-12504',
                'TNS-12505',
                'TNS-12506',
                'TNS-12507',
                'TNS-12508',
                'TNS-12509',
                'TNS-12510',
                'TNS-12511',
                'TNS-12512',
                'TNS-12513',
                'TNS-12514',
                'TNS-12515',
                'TNS-12516',
                'TNS-12517',
                'TNS-12518',
                'TNS-12519',
                'TNS-12520',
                'TNS-12521',
                'TNS-12523',
                'TNS-12525',
                'TNS-12526',
                'TNS-12527',
                'TNS-12528',
                'TNS-12529',
                'TNS-12530',
                'TNS-12531',
                'TNS-12532',
                'TNS-12533',
                'TNS-12534',
                'TNS-12536',
                'TNS-12538',
                'TNS-12539',
                'TNS-12540',
                'TNS-12542',
                'TNS-12548',
                'TNS-12549',
                'TNS-12550',
                'TNS-12551',
                'TNS-12552',
                'TNS-12553',
                'TNS-12554',
                'TNS-12555',
                'TNS-12556',
                'TNS-12558',
                'TNS-12561',
                'TNS-12562',
                'TNS-12563',
                'TNS-12564',
                'TNS-12567',
                'TNS-12568',
                'TNS-12569',
                'TNS-12571',
                'TNS-12572',
                'TNS-12573',
                'TNS-12574',
                'TNS-12575',
                'TNS-12576',
                'TNS-12577',
                'TNS-12578',
                'TNS-12579',
                'TNS-12580',
                'TNS-12581',
                'TNS-12582',
                'TNS-12584',
                'TNS-12585',
                'TNS-12586',
                'TNS-12587',
                'TNS-12588',
                'TNS-12589',
                'TNS-12590',
                'TNS-12591',
                'TNS-12592',
                'TNS-12593',
                'TNS-12594',
                'TNS-12595',
                'TNS-12596',
                'TNS-12597',
                'TNS-12598',
                'TNS-12599',
                'TNS-12600',
                'TNS-12601',
                'TNS-12602',
                'TNS-12603',
                'TNS-12604',
                'TNS-12605',
                'TNS-12606',
                'TNS-12607',
                'TNS-12608',
                'TNS-12609',
                'TNS-12610',
                'TNS-12611',
                'TNS-12612',
                'TNS-12613',
                'TNS-12614',
                'TNS-12615',
                'TNS-12616',
                'TNS-12617',
                'TNS-12618',
                'TNS-12619',
                'TNS-12620',
                'TNS-12621',
                'TNS-12622',
                'TNS-12623',
                'TNS-12624',
                'TNS-12625',
                'TNS-12626',
                'TNS-12627',
                'TNS-12628',
                'TNS-12629',
                'TNS-12630',
                'TNS-12632',
                'TNS-12633',
                'TNS-12634',
                'TNS-12635',
                'TNS-12636',
                'TNS-12639',
                'TNS-12642',
                'TNS-12643',
                'TNS-12644',
                'listener command timeout',
                'listener get seat wait',
                'enq: TT - contention'
            )
            AND total_waits > 0
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_tns_wait_event_waits',
                r.total_waits,
                'COUNTER',
                tag('event', r.event)
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_tns_wait_event_time_ms',
                r.time_waited_ms,
                'COUNTER',
                tag('event', r.event)
            ));
        END LOOP;

        -- ---------------------------------------------------------------------
        -- C. LOGON PERFORMANCE (TNS Connection Setup)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT name, value FROM v$sysstat
            WHERE name IN ('logons cumulative', 'logons current', 'user calls')
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_tns_' || REPLACE(LOWER(r.name), ' ', '_'),
                r.value,
                CASE WHEN r.name = 'logons current' THEN 'GAUGE' ELSE 'COUNTER' END,
                NULL
            ));
        END LOOP;

        -- ---------------------------------------------------------------------
        -- D. NETWORK TRAFFIC (SQL*Net Bytes)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT name, value FROM v$sysstat
            WHERE name IN (
                'bytes sent via SQL*Net to client',
                'bytes received via SQL*Net from client',
                'SQL*Net roundtrips to/from client'
            )
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_tns_' || REPLACE(REPLACE(LOWER(r.name), ' ', '_'), '*/', ''),
                r.value,
                'COUNTER',
                NULL
            ));
        END LOOP;

        -- ---------------------------------------------------------------------
        -- E. DISPATCHER METRICS (MTS/Shared Server)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT name, network, status, messages, bytes, idle, busy
            FROM v$dispatcher
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_dispatcher_messages',
                r.messages,
                'COUNTER',
                tag('name', r.name) || ',"network":"' || r.network || '","status":"' || r.status || '"'
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_dispatcher_bytes',
                r.bytes,
                'COUNTER',
                tag('name', r.name) || ',"network":"' || r.network || '","status":"' || r.status || '"'
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_dispatcher_idle_time',
                r.idle,
                'COUNTER',
                tag('name', r.name) || ',"network":"' || r.network || '","status":"' || r.status || '"'
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_dispatcher_busy_time',
                r.busy,
                'COUNTER',
                tag('name', r.name) || ',"network":"' || r.network || '","status":"' || r.status || '"'
            ));
        END LOOP;

        -- ---------------------------------------------------------------------
        -- F. CONNECTION RATE (Logons per second - calculated)
        -- ---------------------------------------------------------------------
        DECLARE
            l_logons NUMBER;
        BEGIN
            SELECT value INTO l_logons FROM v$sysstat WHERE name = 'logons cumulative';
            PIPE ROW(t_plt_metric_row(
                'oracle_tns_logons_cumulative',
                l_logons,
                'COUNTER',
                NULL
            ));
        END;

        -- ---------------------------------------------------------------------
        -- G. LISTENER QUEUE (V$QUEUE)
        -- ---------------------------------------------------------------------
        FOR r IN (
            SELECT type, queued, wait, totalq
            FROM v$queue
            WHERE type IS NOT NULL
        ) LOOP
            PIPE ROW(t_plt_metric_row(
                'oracle_listener_queue_items',
                r.queued,
                'GAUGE',
                tag('type', r.type)
            ));
            PIPE ROW(t_plt_metric_row(
                'oracle_listener_queue_wait',
                r.wait,
                'GAUGE',
                tag('type', r.type)
            ));
        END LOOP;

        RETURN;
    EXCEPTION WHEN OTHERS THEN
        PLTelemetry.log('ERROR', 'Error in get_listener_metrics: ' || SQLERRM);
        RETURN;
    END;

    ----------------------------------------------------------------------------
    -- 6. NEW: 23ai IN-METRY (In-Memory) METRICS
    ----------------------------------------------------------------------------
    FUNCTION get_inmemory_metrics RETURN t_plt_metric_tab PIPELINED IS
    BEGIN
        -- In-Memory Population Status
        FOR r IN (
            SELECT segment_name, owner, populate_status, bytes, bytes_not_populated
            FROM v$im_segments
            WHERE bytes > 0
        ) LOOP
            IF r.bytes > 0 THEN
                PIPE ROW(t_plt_metric_row(
                    'oracle_inmemory_population_percent',
                    ROUND((1 - (r.bytes_not_populated / r.bytes)) * 100, 2),
                    'GAUGE',
                    tag('segment', r.segment_name) || ',"owner",' || r.owner || '"'
                ));
            END IF;
        END LOOP;

        -- In-Memory Scan Efficiency
        FOR r IN (
            SELECT SUM(CASE WHEN name = 'IM scan rows' THEN value END) as total_rows,
                   SUM(CASE WHEN name = 'IM scan rows optimized' THEN value END) as optimized_rows
            FROM v$sysstat
            WHERE name IN ('IM scan rows', 'IM scan rows optimized')
        ) LOOP
            IF r.total_rows > 0 THEN
                PIPE ROW(t_plt_metric_row(
                    'oracle_inmemory_scan_efficiency_percent',
                    ROUND((r.optimized_rows / r.total_rows) * 100, 2),
                    'GAUGE',
                    NULL
                ));
            END IF;
        END LOOP;

        RETURN;
    EXCEPTION WHEN OTHERS THEN
        PLTelemetry.log('ERROR', 'Error in get_inmemory_metrics: ' || SQLERRM);
        RETURN;
    END;

END PLT_DB_METRIC_READER;

/
