-- =============================================================================
-- PLT_DB_MONITOR - Database Monitoring Tables DDL
-- Table-driven database validation system with configurable thresholds
-- =============================================================================

PROMPT Creating PLT_DB_MONITOR tables...

-- Drop existing tables if they exist (for reinstall)
DECLARE
    l_sql VARCHAR2(1000);
BEGIN
    FOR rec IN (
        SELECT table_name 
        FROM user_tables 
        WHERE table_name IN ('DB_VALIDATION_INSTANCES', 'DB_VALIDATION_RULES', 'DB_VALIDATION_TYPES')
        ORDER BY CASE table_name 
            WHEN 'DB_VALIDATION_INSTANCES' THEN 1
            WHEN 'DB_VALIDATION_RULES' THEN 2  
            WHEN 'DB_VALIDATION_TYPES' THEN 3
        END
    ) LOOP
        l_sql := 'DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS';
        EXECUTE IMMEDIATE l_sql;
        DBMS_OUTPUT.PUT_LINE('Dropped existing table: ' || rec.table_name);
    END LOOP;
END;
/

-- =============================================================================
-- 1. DB_VALIDATION_TYPES - Types of database validations available
-- =============================================================================
CREATE TABLE db_validation_types (
    validation_type_code VARCHAR2(100) PRIMARY KEY,
    description VARCHAR2(200) NOT NULL,
    validation_procedure VARCHAR2(100) NOT NULL, -- PLT_DB_MONITOR procedure name
    default_check_interval_minutes NUMBER DEFAULT 5,
    is_active NUMBER(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT chk_validation_active CHECK (is_active IN (0, 1))
);

COMMENT ON TABLE db_validation_types IS 'Types of database validations (tablespaces, sessions, etc.)';
COMMENT ON COLUMN db_validation_types.validation_type_code IS 'Unique code for validation type';
COMMENT ON COLUMN db_validation_types.validation_procedure IS 'Procedure name in PLT_DB_MONITOR package';
COMMENT ON COLUMN db_validation_types.default_check_interval_minutes IS 'Default check frequency';

-- =============================================================================
-- 2. DB_VALIDATION_RULES - Threshold rules by environment
-- =============================================================================
CREATE TABLE db_validation_rules (
    rule_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    validation_type_code VARCHAR2(100) NOT NULL,
    environment_name VARCHAR2(10) NOT NULL, -- PROD, TEST, DEV
    warning_threshold NUMBER,
    critical_threshold NUMBER,
    threshold_unit VARCHAR2(20) DEFAULT 'percentage', -- percentage, count, seconds, etc.
    check_interval_minutes NUMBER DEFAULT 5,
    is_enabled NUMBER(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT fk_validation_rules_type FOREIGN KEY (validation_type_code) 
        REFERENCES db_validation_types(validation_type_code),
    CONSTRAINT chk_rules_enabled CHECK (is_enabled IN (0, 1)),
    CONSTRAINT chk_thresholds CHECK (warning_threshold < critical_threshold),
    CONSTRAINT uk_validation_rules UNIQUE (validation_type_code, environment_name)
);

COMMENT ON TABLE db_validation_rules IS 'Threshold rules by validation type and environment';
COMMENT ON COLUMN db_validation_rules.environment_name IS 'Target environment (PROD, TEST, DEV)';
COMMENT ON COLUMN db_validation_rules.warning_threshold IS 'Warning level threshold';
COMMENT ON COLUMN db_validation_rules.critical_threshold IS 'Critical level threshold';
COMMENT ON COLUMN db_validation_rules.threshold_unit IS 'Unit of measurement for thresholds';

-- =============================================================================
-- 3. DB_VALIDATION_INSTANCES - Individual validation instances
-- =============================================================================
CREATE TABLE db_validation_instances (
    instance_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    validation_type_code VARCHAR2(100) NOT NULL,
    instance_name VARCHAR2(100) NOT NULL, -- USERS_TS, SYSTEM_TS, specific job name, etc.
    instance_description VARCHAR2(200),
    target_identifier VARCHAR2(200), -- tablespace name, job name, etc.
    is_enabled NUMBER(1) DEFAULT 0, -- DISABLED by default as requested
    last_check_time TIMESTAMP,
    last_check_status VARCHAR2(20), -- OK, WARNING, CRITICAL, ERROR
    last_check_value NUMBER,
    consecutive_failures NUMBER DEFAULT 0,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT fk_validation_instances_type FOREIGN KEY (validation_type_code) 
        REFERENCES db_validation_types(validation_type_code),
    CONSTRAINT chk_instances_enabled CHECK (is_enabled IN (0, 1)),
    CONSTRAINT chk_instance_status CHECK (last_check_status IN ('OK', 'WARNING', 'CRITICAL', 'ERROR', NULL)),
    CONSTRAINT uk_validation_instances UNIQUE (validation_type_code, instance_name)
);

COMMENT ON TABLE db_validation_instances IS 'Individual validation instances (specific tablespaces, jobs, etc.)';
COMMENT ON COLUMN db_validation_instances.instance_name IS 'Unique name for this validation instance';
COMMENT ON COLUMN db_validation_instances.target_identifier IS 'Database object identifier (tablespace name, job name, etc.)';
COMMENT ON COLUMN db_validation_instances.is_enabled IS 'Enable/disable this specific validation (default: disabled)';
COMMENT ON COLUMN db_validation_instances.last_check_status IS 'Result of last validation check';
COMMENT ON COLUMN db_validation_instances.last_check_value IS 'Last measured value (percentage, count, etc.)';

-- =============================================================================
-- Create indexes for performance
-- =============================================================================
CREATE INDEX idx_validation_rules_env ON db_validation_rules(environment_name, is_enabled);
CREATE INDEX idx_validation_instances_enabled ON db_validation_instances(validation_type_code, is_enabled);
CREATE INDEX idx_validation_instances_status ON db_validation_instances(last_check_status, last_check_time);
CREATE INDEX idx_validation_instances_failures ON db_validation_instances(consecutive_failures) WHERE consecutive_failures > 0;

PROMPT PLT_DB_MONITOR tables created successfully.
PROMPT
PROMPT Table Summary:
PROMPT - db_validation_types: Types of validations available
PROMPT - db_validation_rules: Threshold rules by environment  
PROMPT - db_validation_instances: Individual validation instances (disabled by default)
PROMPT
PROMPT Ready for DML data insertion...