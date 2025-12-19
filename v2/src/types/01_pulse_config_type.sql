-- src/types/01_pulse_config_type.sql
PROMPT [TYPES] Creating Object Types...

CREATE OR REPLACE TYPE plt_pulse_config_t AS OBJECT (
    pulse_mode          VARCHAR2(10),
    capacity_multiplier NUMBER,
    batch_multiplier    NUMBER,
    interval_multiplier NUMBER,
    sampling_rate       NUMBER,
    metrics_enabled     VARCHAR2(1),
    logs_enabled        VARCHAR2(1),
    queue_processing    VARCHAR2(1),
    description         VARCHAR2(200)
);
/