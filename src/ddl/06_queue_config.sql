-- =============================================================================
-- 06_queue_config.sql
-- Queue Configuration (Pulse Modes & Throttling)
-- =============================================================================
PROMPT [06] Configuring Queue and Pulse Modes...

-- 1. QUEUE CONFIGURATION
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('QUEUE', 'MAX_SIZE_MB', '500', 'Maximum size in MB before forcing rotation');
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('QUEUE', 'ROTATION_CHECK_INTERVAL', '300', 'Seconds between rotation checks');
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('QUEUE', 'MAX_RETRY_ATTEMPTS', '3', 'Maximum retries for failed items');
INSERT INTO plt_sys_config (config_group, config_key, config_value, description) VALUES 
('QUEUE', 'BATCH_SIZE', '100', 'Items processed per batch');

-- 2. PULSE MODES (Throttling)
-- These define how the Go Agent behaves under different load conditions
INSERT INTO plt_pulse_throttling_config (
    pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, 
    interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, 
    queue_processing, description, is_active
) VALUES 
('PULSE1', 'GLOBAL', 1.00, 1.00, 1.00, 1.00, 'Y', 'Y', 'Y', 
 'Full Speed - No Throttling', 'Y');

INSERT INTO plt_pulse_throttling_config (
    pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, 
    interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, 
    queue_processing, description, is_active
) VALUES 
('PULSE2', 'GLOBAL', 0.50, 0.50, 2.00, 0.75, 'Y', 'Y', 'Y', 
 'Moderate Load - 50% Capacity', 'Y');

INSERT INTO plt_pulse_throttling_config (
    pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, 
    interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, 
    queue_processing, description, is_active
) VALUES 
('PULSE3', 'GLOBAL', 0.25, 0.25, 4.00, 0.50, 'Y', 'Y', 'Y', 
 'High Load - 25% Capacity', 'Y');

INSERT INTO plt_pulse_throttling_config (
    pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, 
    interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, 
    queue_processing, description, is_active
) VALUES 
('PULSE4', 'GLOBAL', 0.10, 0.10, 10.00, 0.10, 'Y', 'Y', 'Y', 
 'Critical Load - 10% Capacity', 'Y');

INSERT INTO plt_pulse_throttling_config (
    pulse_mode, tenant_id, capacity_multiplier, batch_multiplier, 
    interval_multiplier, sampling_rate, metrics_enabled, logs_enabled, 
    queue_processing, description, is_active
) VALUES 
('COMA', 'GLOBAL', 0.00, 0.00, 60.00, 0.00, 'N', 'N', 'N', 
 'System Overload - Hibernation', 'Y');

COMMIT;
/

PROMPT ✅ Queue and Pulse configuration completed.

