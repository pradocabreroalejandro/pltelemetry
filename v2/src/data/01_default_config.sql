-- src/data/01_default_config.sql
PROMPT [DATA] Seeding default configuration...

-- Limpiamos primero para evitar duplicados si se corre varias veces
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