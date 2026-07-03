-- src/data/01_default_config.sql
PROMPT [DATA] Seeding default configuration...

-- Clean up first to avoid duplicates if run multiple times
DELETE FROM plt_pulse_throttling_config;

INSERT INTO plt_pulse_throttling_config 
(pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) 
VALUES ('PULSE1', 1.00, 1.00, 1.00, 1.00, 'Full Speed - No Throttling');

INSERT INTO plt_pulse_throttling_config 
(pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) 
VALUES ('PULSE2', 0.50, 0.50, 2.00, 0.75, 'Moderate Load - 50% Capacity');

INSERT INTO plt_pulse_throttling_config 
(pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) 
VALUES ('PULSE3', 0.25, 0.25, 4.00, 0.50, 'High Load - 25% Capacity');

INSERT INTO plt_pulse_throttling_config 
(pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, description) 
VALUES ('PULSE4', 0.10, 0.10, 10.00, 0.10, 'Critical Load - 10% Capacity');

INSERT INTO plt_pulse_throttling_config 
(pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, sampling_rate, queue_processing, description) 
VALUES ('COMA',   0.00, 0.00, 60.00, 0.00, 'N', 'System Overload - Hibernation');

COMMIT;
PROMPT Default configuration loaded.

-- INITIAL DATA (Examples)
-- 1. By default, EVERYTHING off (Security by design)
-- Use MERGE to avoid ORA-00001 if already exists (idempotent)
MERGE INTO plt_activation_rules t
USING (SELECT '*' AS pattern, 'N' AS enabled, 0 AS rate FROM DUAL) s
ON (t.object_pattern = s.pattern)
WHEN MATCHED THEN UPDATE SET t.is_enabled = s.enabled, t.sample_rate = s.rate
WHEN NOT MATCHED THEN INSERT (object_pattern, is_enabled, sample_rate) VALUES (s.pattern, s.enabled, s.rate);

COMMIT;
