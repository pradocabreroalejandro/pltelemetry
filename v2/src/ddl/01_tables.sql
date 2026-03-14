-- =============================================================================
-- 01_tables.sql
-- Definición del Esquema de Base de Datos (Topología Rotativa v2)
-- =============================================================================
PROMPT [01] Creating Tables and Indexes...

-- CLEANUP (Ordenado por dependencias)
BEGIN
    -- Borrado de objetos antiguos y nuevos
    FOR t IN (SELECT table_name FROM user_tables WHERE table_name IN (
        'PLT_SYS_CONFIG', 'PLT_METRIC_COLLECTORS', 'PLT_TENANTS', 
        'PLT_QUEUE', 'PLT_QUEUE_01', 'PLT_QUEUE_02', 'PLT_QUEUE_REGISTRY',
        'PLT_PULSE_THROTTLING_CONFIG', 
        'PLT_AGENT_REGISTRY', 'PLT_TELEMETRY_ERRORS', 'PLT_ACTIVATION_RULES'
    )) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS';
    END LOOP;

    -- Borrado de Vistas y Sinónimos de la topología
    FOR v IN (SELECT view_name FROM user_views WHERE view_name = 'PLT_QUEUE_READER') LOOP
        EXECUTE IMMEDIATE 'DROP VIEW ' || v.view_name;
    END LOOP;
    
    FOR s IN (SELECT synonym_name FROM user_synonyms WHERE synonym_name = 'PLT_QUEUE_WRITER') LOOP
        EXECUTE IMMEDIATE 'DROP SYNONYM ' || s.synonym_name;
    END LOOP;
END;
/

-- 1. CONFIGURACIÓN DEL SISTEMA (La fuente de la verdad)
CREATE TABLE plt_sys_config (
    config_group    VARCHAR2(50)  NOT NULL,
    config_key      VARCHAR2(100) NOT NULL,
    config_value    VARCHAR2(4000),
    description     VARCHAR2(255),
    is_encrypted    VARCHAR2(1) DEFAULT 'N' CHECK (is_encrypted IN ('Y', 'N')),
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP,
    updated_by      VARCHAR2(100) DEFAULT USER,
    CONSTRAINT pk_plt_sys_config PRIMARY KEY (config_group, config_key)
);

-- 2. TOPOLOGÍA DE COLAS (Partitioning Lógico)
-- 2.1 Registro de Estado (El cerebro)
CREATE TABLE plt_queue_registry (
    partition_name  VARCHAR2(30) PRIMARY KEY, -- 'PLT_QUEUE_01', 'PLT_QUEUE_02'
    is_active       VARCHAR2(1) DEFAULT 'N',  -- 'Y' = Donde se hacen INSERTS
    state           VARCHAR2(20),             -- 'ACTIVE', 'DRAINING', 'READY'
    last_truncate   TIMESTAMP WITH TIME ZONE,
    row_count_est   NUMBER,
    bytes_est       NUMBER
);

-- 2.2 Tabla Física 01 (Activa por defecto)
CREATE TABLE plt_queue_01 (
    id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_type       VARCHAR2(20) NOT NULL CHECK (item_type IN ('TRACE', 'METRIC', 'LOG')),
    payload         CLOB         NOT NULL,
    status          VARCHAR2(20) DEFAULT 'NEW' NOT NULL CHECK (status IN ('NEW', 'PROCESSING', 'FAILED', 'PROCESSED')),
    retry_count     NUMBER       DEFAULT 0     NOT NULL,
    process_attempts NUMBER      DEFAULT 0     NOT NULL,
    error_message   VARCHAR2(4000),
    created_at      TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at      TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    tenant_id       VARCHAR2(100) DEFAULT 'default'
);
CREATE INDEX idx_plt_queue_main_01 ON plt_queue_01(status, tenant_id, id); 

-- 2.3 Tabla Física 02 (Reserva por defecto)
CREATE TABLE plt_queue_02 (
    id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_type       VARCHAR2(20) NOT NULL CHECK (item_type IN ('TRACE', 'METRIC', 'LOG')),
    payload         CLOB         NOT NULL,
    status          VARCHAR2(20) DEFAULT 'NEW' NOT NULL CHECK (status IN ('NEW', 'PROCESSING', 'FAILED', 'PROCESSED')),
    retry_count     NUMBER       DEFAULT 0     NOT NULL,
    process_attempts NUMBER      DEFAULT 0     NOT NULL,
    error_message   VARCHAR2(4000),
    created_at      TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at      TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    tenant_id       VARCHAR2(100) DEFAULT 'default'
);
CREATE INDEX idx_plt_queue_main_02 ON plt_queue_02(status, tenant_id, id); 

-- 2.4 Inicialización del Registro
INSERT INTO plt_queue_registry (partition_name, is_active, state) VALUES ('PLT_QUEUE_01', 'Y', 'ACTIVE');
INSERT INTO plt_queue_registry (partition_name, is_active, state) VALUES ('PLT_QUEUE_02', 'N', 'READY');

-- 2.5 Sinónimo de Escritura (Apunta a la activa)
CREATE OR REPLACE SYNONYM plt_queue_writer FOR plt_queue_01;

-- 2.6 Vista de Lectura (Unifica ambas para el Agente)
CREATE OR REPLACE VIEW plt_queue_reader AS
SELECT id, item_type, payload, status, retry_count, process_attempts, error_message, created_at, updated_at, tenant_id, 'PLT_QUEUE_01' as origin_table 
FROM plt_queue_01
UNION ALL
SELECT id, item_type, payload, status, retry_count, process_attempts, error_message, created_at, updated_at, tenant_id, 'PLT_QUEUE_02' as origin_table 
FROM plt_queue_02;


-- 3. REGISTRO DE AGENTES (Heartbeats)
CREATE TABLE plt_agent_registry (
    agent_id          VARCHAR2(100) DEFAULT 'PRIMARY' PRIMARY KEY,
    pulse_mode        VARCHAR2(20)  DEFAULT 'PULSE1',
    system_heat       NUMBER        DEFAULT 0,
    last_heartbeat    TIMESTAMP WITH TIME ZONE,
    last_process_time TIMESTAMP WITH TIME ZONE,
    items_processed   NUMBER DEFAULT 0,
    status_message    VARCHAR2(4000),
    version           VARCHAR2(50),
    created_at        TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP,
    updated_at        TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP
);

-- 4. CONFIGURACIÓN DE THROTTLING (Modos de Pulso)
CREATE TABLE plt_pulse_throttling_config (
    pulse_mode          VARCHAR2(10),
    tenant_id           VARCHAR2(100) DEFAULT 'GLOBAL',
    capacity_multiplier NUMBER(5,4) NOT NULL,
    batch_multiplier    NUMBER(5,4) NOT NULL, 
    interval_multiplier NUMBER(5,2) NOT NULL,
    sampling_rate       NUMBER(5,4) NOT NULL,
    metrics_enabled     VARCHAR2(1) DEFAULT 'Y',
    logs_enabled        VARCHAR2(1) DEFAULT 'Y',
    queue_processing    VARCHAR2(1) DEFAULT 'Y',
    description         VARCHAR2(200),
    is_active           VARCHAR2(1) DEFAULT 'Y',
    CONSTRAINT pk_plt_pulse_config PRIMARY KEY (pulse_mode, tenant_id)
);

-- 5. REGLAS DE ACTIVACIÓN (Sampling por objeto)
CREATE TABLE plt_activation_rules (
    rule_id         NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    object_pattern  VARCHAR2(100) NOT NULL, -- Ej: 'PAQUETE_VENTAS.%' o '*'
    is_enabled      VARCHAR2(1) DEFAULT 'Y' CHECK (is_enabled IN ('Y', 'N')),
    sample_rate     NUMBER DEFAULT 1.0 CHECK (sample_rate BETWEEN 0 AND 1),
    created_at      TIMESTAMP DEFAULT SYSTIMESTAMP
);
CREATE UNIQUE INDEX idx_plt_rules_pattern ON plt_activation_rules(object_pattern);

-- 6. ERRORES INTERNOS (Self-Monitoring)
CREATE TABLE plt_telemetry_errors (
    error_id      NUMBER GENERATED BY DEFAULT ON NULL AS IDENTITY PRIMARY KEY,
    error_time    TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
    error_message VARCHAR2(4000),
    error_stack   VARCHAR2(4000),
    module_name   VARCHAR2(100),
    trace_id      VARCHAR2(32),
    span_id       VARCHAR2(16),
    tenant_id     VARCHAR2(100)
);

-- 7. TENANTS (Multitenancy)
CREATE TABLE plt_tenants (
    tenant_id       VARCHAR2(50) PRIMARY KEY,
    description     VARCHAR2(100),
    is_enabled      NUMBER DEFAULT 1,
    created_at      TIMESTAMP DEFAULT SYSTIMESTAMP
);

-- 8. COLECTORES DE MÉTRICAS
CREATE TABLE plt_metric_collectors (
    collector_code      VARCHAR2(50) PRIMARY KEY,
    reader_package      VARCHAR2(128) DEFAULT 'PLT_DB_METRIC_READER' NOT NULL,
    reader_function     VARCHAR2(128) NOT NULL,
    execution_scope     VARCHAR2(20)  DEFAULT 'GLOBAL' CHECK (execution_scope IN ('GLOBAL', 'PER_TENANT')),
    interval_seconds    NUMBER DEFAULT 60,
    is_enabled          NUMBER DEFAULT 1,
    last_run            TIMESTAMP WITH TIME ZONE
);

COMMIT;

PROMPT ✅ Tablas y Topología Rotativa (v2) creadas correctamente.