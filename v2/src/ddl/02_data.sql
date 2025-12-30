-- =============================================================================
-- 02_data.sql
-- Datos Semilla (Configuración por Defecto)
-- =============================================================================
PROMPT [02] Seeding Default Data...

-- 1. CONFIGURACIÓN DEL SISTEMA
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('OTLP', 'ENDPOINT_URL', 'http://otel-collector:4318', 'URL base del colector OpenTelemetry');
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('OTLP', 'SERVICE_NAME', 'oracle-db-prod', 'Nombre del servicio reportado');
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('OTLP', 'ENVIRONMENT', 'production', 'Entorno (prod, dev, stg)');
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('OTLP', 'TIMEOUT_MS', '5000', 'Timeout HTTP (ms)');
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('GENERAL', 'TENANT_ID_DEFAULT', 'default', 'Tenant ID por defecto');
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('GENERAL', 'DEBUG_MODE', 'FALSE', 'Activa logs de debug (TRUE/FALSE)');

-- 2. MODOS DE PULSO (Throttling)
INSERT INTO plt_pulse_throttling_config (pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) 
VALUES ('PULSE1', 1.00, 1.00, 1.00, 1.00, 'Full Speed - No Throttling');
INSERT INTO plt_pulse_throttling_config (pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) 
VALUES ('PULSE2', 0.50, 0.50, 2.00, 0.75, 'Moderate Load - 50% Capacity');
INSERT INTO plt_pulse_throttling_config (pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) 
VALUES ('PULSE3', 0.25, 0.25, 4.00, 0.50, 'High Load - 25% Capacity');
INSERT INTO plt_pulse_throttling_config (pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) 
VALUES ('PULSE4', 0.10, 0.10, 10.00, 0.10, 'Critical Load - 10% Capacity');
INSERT INTO plt_pulse_throttling_config (pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, queue_processing, description) 
VALUES ('COMA',   0.00, 0.00, 60.00, 0.00, 'N', 'System Overload - Hibernation');

-- 3. REGLAS DE ACTIVACIÓN (Seguridad por defecto: OFF)
INSERT INTO plt_activation_rules (object_pattern, is_enabled, sample_rate) VALUES ('*', 'N', 0);

-- 4. TENANTS
INSERT INTO plt_tenants (tenant_id, description) VALUES ('default', 'Infraestructura Global');
INSERT INTO plt_tenants (tenant_id, description) VALUES ('CLIENTE_A', 'Empresa ACME Corp');
INSERT INTO plt_tenants (tenant_id, description) VALUES ('CLIENTE_B', 'Wayne Enterprises');

-- 5. COLECTORES DE MÉTRICAS
-- Sistema (15s)
INSERT INTO plt_metric_collectors (collector_code, reader_package, reader_function, interval_seconds, execution_scope)
VALUES ('SYSTEM', 'PLT_DB_METRIC_READER', 'get_system_metrics', 15, 'GLOBAL');
-- Sesiones (15s) - Ejemplo PER_TENANT si aplicara lógica de filtrado, aquí lo dejamos GLOBAL por ahora
INSERT INTO plt_metric_collectors (collector_code, reader_package, reader_function, interval_seconds, execution_scope)
VALUES ('SESSIONS', 'PLT_DB_METRIC_READER', 'get_session_metrics', 15, 'GLOBAL');
-- Storage (60s)
INSERT INTO plt_metric_collectors (collector_code, reader_package, reader_function, interval_seconds, execution_scope)
VALUES ('STORAGE', 'PLT_DB_METRIC_READER', 'get_storage_metrics', 60, 'GLOBAL');

COMMIT;
PROMPT ✅ Datos iniciales cargados.