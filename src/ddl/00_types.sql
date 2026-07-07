-- =============================================================================
-- 00_types.sql
-- Object Type Definitions (UDTs)
-- =============================================================================
PROMPT [00] Creating Object Types...

-- Preventive cleanup
BEGIN
    EXECUTE IMMEDIATE 'DROP TYPE t_plt_metric_tab FORCE';
    EXECUTE IMMEDIATE 'DROP TYPE t_plt_metric_row FORCE';
    EXECUTE IMMEDIATE 'DROP TYPE plt_pulse_config_t FORCE';
EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- 1. PULSE CONFIGURATION (Used to communicate config to the Go Agent)
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

-- 2. METRIC ROW (Used in Pipelined Functions)
-- NOTE: SQL object types do NOT support DEFAULT on attributes; the '1' (dimensionless)
-- default is applied at the PL/SQL layer (PIPE ROW construction) instead.
CREATE OR REPLACE TYPE t_plt_metric_row AS OBJECT (
    metric_name   VARCHAR2(255),
    metric_value  NUMBER,
    metric_type   VARCHAR2(20),  -- 'GAUGE' or 'COUNTER'
    tags_json     VARCHAR2(4000), -- Additional tags: '{"tablespace":"USERS"}'
    metric_unit   VARCHAR2(50)   -- OTLP unit: '1'=count, 'By'=bytes, 's'=seconds, 'ms'=ms, '%'=percent, 'cs'=centiseconds, 'us'=microseconds
);
/

-- 3. METRIC COLLECTION
CREATE OR REPLACE TYPE t_plt_metric_tab AS TABLE OF t_plt_metric_row;
/

PROMPT ✅ Types created successfully.

