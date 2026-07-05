-- =============================================================================
-- 06_queue_config.sql
-- Queue Configuration (Pulse Modes & Throttling)
-- =============================================================================
PROMPT [06] Configuring Queue and Pulse Modes...

-- 1. QUEUE CONFIGURATION (Idempotent)
MERGE INTO plt_sys_config t USING (SELECT 'QUEUE' AS cg, 'MAX_SIZE_MB' AS ck, '500' AS cv, 'Maximum size in MB before forcing rotation' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

MERGE INTO plt_sys_config t USING (SELECT 'QUEUE' AS cg, 'ROTATION_CHECK_INTERVAL' AS ck, '300' AS cv, 'Seconds between rotation checks' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

MERGE INTO plt_sys_config t USING (SELECT 'QUEUE' AS cg, 'MAX_RETRY_ATTEMPTS' AS ck, '3' AS cv, 'Maximum retries for failed items' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

MERGE INTO plt_sys_config t USING (SELECT 'QUEUE' AS cg, 'BATCH_SIZE' AS ck, '100' AS cv, 'Items processed per batch' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

-- 2. PULSE MODES (Throttling) — Idempotent with UPDATE on match
MERGE INTO plt_pulse_throttling_config t USING (SELECT 'PULSE1' AS pm, 'GLOBAL' AS tid, 1.00 AS cm, 1.00 AS bm, 1.00 AS im, 1.00 AS sr, 'Y' AS me, 'Y' AS le, 'Y' AS qp, 'Full Speed - No Throttling' AS dsc, 'Y' AS ia FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN MATCHED THEN UPDATE SET capacity_multiplier = s.cm, batch_multiplier = s.bm, interval_multiplier = s.im, sampling_rate = s.sr, metrics_enabled = s.me, logs_enabled = s.le, queue_processing = s.qp, description = s.dsc, is_active = s.ia
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, queue_processing, description, is_active) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.me, s.le, s.qp, s.dsc, s.ia);

MERGE INTO plt_pulse_throttling_config t USING (SELECT 'PULSE2' AS pm, 'GLOBAL' AS tid, 0.50 AS cm, 0.50 AS bm, 2.00 AS im, 0.75 AS sr, 'Y' AS me, 'Y' AS le, 'Y' AS qp, 'Moderate Load - 50% Capacity' AS dsc, 'Y' AS ia FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN MATCHED THEN UPDATE SET capacity_multiplier = s.cm, batch_multiplier = s.bm, interval_multiplier = s.im, sampling_rate = s.sr, metrics_enabled = s.me, logs_enabled = s.le, queue_processing = s.qp, description = s.dsc, is_active = s.ia
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, queue_processing, description, is_active) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.me, s.le, s.qp, s.dsc, s.ia);

MERGE INTO plt_pulse_throttling_config t USING (SELECT 'PULSE3' AS pm, 'GLOBAL' AS tid, 0.25 AS cm, 0.25 AS bm, 4.00 AS im, 0.50 AS sr, 'Y' AS me, 'Y' AS le, 'Y' AS qp, 'High Load - 25% Capacity' AS dsc, 'Y' AS ia FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN MATCHED THEN UPDATE SET capacity_multiplier = s.cm, batch_multiplier = s.bm, interval_multiplier = s.im, sampling_rate = s.sr, metrics_enabled = s.me, logs_enabled = s.le, queue_processing = s.qp, description = s.dsc, is_active = s.ia
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, queue_processing, description, is_active) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.me, s.le, s.qp, s.dsc, s.ia);

MERGE INTO plt_pulse_throttling_config t USING (SELECT 'PULSE4' AS pm, 'GLOBAL' AS tid, 0.10 AS cm, 0.10 AS bm, 10.00 AS im, 0.10 AS sr, 'Y' AS me, 'Y' AS le, 'Y' AS qp, 'Critical Load - 10% Capacity' AS dsc, 'Y' AS ia FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN MATCHED THEN UPDATE SET capacity_multiplier = s.cm, batch_multiplier = s.bm, interval_multiplier = s.im, sampling_rate = s.sr, metrics_enabled = s.me, logs_enabled = s.le, queue_processing = s.qp, description = s.dsc, is_active = s.ia
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, queue_processing, description, is_active) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.me, s.le, s.qp, s.dsc, s.ia);

MERGE INTO plt_pulse_throttling_config t USING (SELECT 'COMA' AS pm, 'GLOBAL' AS tid, 0.00 AS cm, 0.00 AS bm, 60.00 AS im, 0.00 AS sr, 'N' AS me, 'N' AS le, 'N' AS qp, 'System Overload - Hibernation' AS dsc, 'Y' AS ia FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN MATCHED THEN UPDATE SET capacity_multiplier = s.cm, batch_multiplier = s.bm, interval_multiplier = s.im, sampling_rate = s.sr, metrics_enabled = s.me, logs_enabled = s.le, queue_processing = s.qp, description = s.dsc, is_active = s.ia
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, queue_processing, description, is_active) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.me, s.le, s.qp, s.dsc, s.ia);

COMMIT;

PROMPT ✅ Queue and Pulse configuration completed.

