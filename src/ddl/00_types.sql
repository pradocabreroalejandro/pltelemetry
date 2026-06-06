-- =============================================================================
-- 00_types.sql
-- Definición de Tipos de Objetos SQL (UDTs)
-- =============================================================================
PROMPT [00] Creating Object Types...

-- Limpieza preventiva
BEGIN
    EXECUTE IMMEDIATE 'DROP TYPE t_plt_metric_tab FORCE';
    EXECUTE IMMEDIATE 'DROP TYPE t_plt_metric_row FORCE';
    EXECUTE IMMEDIATE 'DROP TYPE plt_pulse_config_t FORCE';
EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- 1. CONFIGURACIÓN DE PULSO (Usado para comunicar config al Agente Go)
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

-- 2. FILA DE MÉTRICA (Usado en Pipelined Functions)
CREATE OR REPLACE TYPE t_plt_metric_row AS OBJECT (
    metric_name   VARCHAR2(255),
    metric_value  NUMBER,
    metric_type   VARCHAR2(20),  -- 'GAUGE' o 'COUNTER'
    tags_json     VARCHAR2(4000) -- Tags adicionales: '{"tablespace":"USERS"}'
);
/

-- 3. COLECCIÓN DE MÉTRICAS
CREATE OR REPLACE TYPE t_plt_metric_tab AS TABLE OF t_plt_metric_row;
/

PROMPT ✅ Tipos creados correctamente.