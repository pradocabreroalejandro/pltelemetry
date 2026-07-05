-- =============================================================================
-- 02_data.sql
-- Seed Data (Default Configuration) — Idempotent (MERGE)
-- =============================================================================
PROMPT [02] Seeding Default Data...

-- 1. SYSTEM CONFIGURATION
MERGE INTO plt_sys_config t USING (SELECT 'OTLP' AS cg, 'ENDPOINT_URL' AS ck, 'http://otel-collector:4318' AS cv, 'Base URL of the OpenTelemetry collector' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

MERGE INTO plt_sys_config t USING (SELECT 'OTLP' AS cg, 'SERVICE_NAME' AS ck, 'oracle-db-prod' AS cv, 'Reported service name' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

MERGE INTO plt_sys_config t USING (SELECT 'OTLP' AS cg, 'ENVIRONMENT' AS ck, 'production' AS cv, 'Environment (prod, dev, stg)' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

MERGE INTO plt_sys_config t USING (SELECT 'OTLP' AS cg, 'TIMEOUT_MS' AS ck, '5000' AS cv, 'HTTP Timeout (ms)' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

MERGE INTO plt_sys_config t USING (SELECT 'GENERAL' AS cg, 'TENANT_ID_DEFAULT' AS ck, 'default' AS cv, 'Default Tenant ID' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

MERGE INTO plt_sys_config t USING (SELECT 'GENERAL' AS cg, 'DEBUG_MODE' AS ck, 'FALSE' AS cv, 'Enable debug logs (TRUE/FALSE)' AS dsc FROM dual) s
ON (t.config_group = s.cg AND t.config_key = s.ck)
WHEN NOT MATCHED THEN INSERT (config_group, config_key, config_value, description) VALUES (s.cg, s.ck, s.cv, s.dsc);

-- 2. PULSE MODES (Throttling) — Base seed (full config in 06_queue_config.sql)
MERGE INTO plt_pulse_throttling_config t USING (SELECT 'PULSE1' AS pm, 'GLOBAL' AS tid, 1.00 AS cm, 1.00 AS bm, 1.00 AS im, 1.00 AS sr, 'Full Speed - No Throttling' AS dsc FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.dsc);

MERGE INTO plt_pulse_throttling_config t USING (SELECT 'PULSE2' AS pm, 'GLOBAL' AS tid, 0.50 AS cm, 0.50 AS bm, 2.00 AS im, 0.75 AS sr, 'Moderate Load - 50% Capacity' AS dsc FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.dsc);

MERGE INTO plt_pulse_throttling_config t USING (SELECT 'PULSE3' AS pm, 'GLOBAL' AS tid, 0.25 AS cm, 0.25 AS bm, 4.00 AS im, 0.50 AS sr, 'High Load - 25% Capacity' AS dsc FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.dsc);

MERGE INTO plt_pulse_throttling_config t USING (SELECT 'PULSE4' AS pm, 'GLOBAL' AS tid, 0.10 AS cm, 0.10 AS bm, 10.00 AS im, 0.10 AS sr, 'Critical Load - 10% Capacity' AS dsc FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.dsc);

MERGE INTO plt_pulse_throttling_config t USING (SELECT 'COMA' AS pm, 'GLOBAL' AS tid, 0.00 AS cm, 0.00 AS bm, 60.00 AS im, 0.00 AS sr, 'N' AS qp, 'System Overload - Hibernation' AS dsc FROM dual) s
ON (t.pulse_mode = s.pm AND t.tenant_id = s.tid)
WHEN NOT MATCHED THEN INSERT (pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, queue_processing, description) VALUES (s.pm, s.tid, s.cm, s.bm, s.im, s.sr, s.qp, s.dsc);

-- 3. ACTIVATION RULES (Security by default: OFF)
MERGE INTO plt_activation_rules t USING (SELECT '*' AS op, 'N' AS ie, 0 AS sr FROM dual) s
ON (t.object_pattern = s.op)
WHEN NOT MATCHED THEN INSERT (object_pattern, is_enabled, sample_rate) VALUES (s.op, s.ie, s.sr);

-- 4. TENANTS
MERGE INTO plt_tenants t USING (SELECT 'default' AS tid, 'Global Infrastructure' AS dsc FROM dual) s
ON (t.tenant_id = s.tid)
WHEN NOT MATCHED THEN INSERT (tenant_id, description) VALUES (s.tid, s.dsc);

MERGE INTO plt_tenants t USING (SELECT 'CLIENT_A' AS tid, 'ACME Corp' AS dsc FROM dual) s
ON (t.tenant_id = s.tid)
WHEN NOT MATCHED THEN INSERT (tenant_id, description) VALUES (s.tid, s.dsc);

MERGE INTO plt_tenants t USING (SELECT 'CLIENT_B' AS tid, 'Wayne Enterprises' AS dsc FROM dual) s
ON (t.tenant_id = s.tid)
WHEN NOT MATCHED THEN INSERT (tenant_id, description) VALUES (s.tid, s.dsc);

-- 5. METRIC COLLECTORS
MERGE INTO plt_metric_collectors t USING (SELECT 'SYSTEM' AS cc, 'PLT_DB_METRIC_READER' AS rp, 'get_system_metrics' AS rf, 15 AS iv, 'GLOBAL' AS es FROM dual) s
ON (t.collector_code = s.cc)
WHEN NOT MATCHED THEN INSERT (collector_code, reader_package, reader_function, interval_seconds, execution_scope) VALUES (s.cc, s.rp, s.rf, s.iv, s.es);

MERGE INTO plt_metric_collectors t USING (SELECT 'SESSIONS' AS cc, 'PLT_DB_METRIC_READER' AS rp, 'get_session_metrics' AS rf, 15 AS iv, 'GLOBAL' AS es FROM dual) s
ON (t.collector_code = s.cc)
WHEN NOT MATCHED THEN INSERT (collector_code, reader_package, reader_function, interval_seconds, execution_scope) VALUES (s.cc, s.rp, s.rf, s.iv, s.es);

MERGE INTO plt_metric_collectors t USING (SELECT 'STORAGE' AS cc, 'PLT_DB_METRIC_READER' AS rp, 'get_storage_metrics' AS rf, 60 AS iv, 'GLOBAL' AS es FROM dual) s
ON (t.collector_code = s.cc)
WHEN NOT MATCHED THEN INSERT (collector_code, reader_package, reader_function, interval_seconds, execution_scope) VALUES (s.cc, s.rp, s.rf, s.iv, s.es);

COMMIT;

PROMPT ✅ Initial data loaded.