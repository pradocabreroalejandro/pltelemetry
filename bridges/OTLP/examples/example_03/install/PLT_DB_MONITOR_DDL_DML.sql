-- =============================================================================
-- PLT_DB_MONITOR - TENANT-AWARE MIGRATION SCRIPT
-- Complete rebuild with tenant_id support and multi-tenant architecture
-- =============================================================================

PROMPT Starting PLT_DB_MONITOR tenant-aware migration...
PROMPT ⚠️  WARNING: This will DROP ALL existing validation data!

-- =============================================================================
-- 1. PURGE EXISTING TABLES (NO MERCY!)
-- =============================================================================

PROMPT Dropping existing tables...

BEGIN
    FOR rec IN (
        SELECT table_name 
        FROM user_tables 
        WHERE table_name LIKE 'DB_VALIDATION_%'
        ORDER BY CASE table_name 
            WHEN 'DB_VALIDATION_INSTANCES' THEN 1
            WHEN 'DB_VALIDATION_RULES' THEN 2  
            WHEN 'DB_VALIDATION_TYPES' THEN 3
        END
    ) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS PURGE';
        DBMS_OUTPUT.PUT_LINE('🗑️  Dropped table: ' || rec.table_name);
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ℹ️  Some tables may not exist, continuing...');
END;
/

-- =============================================================================
-- 2. CREATE NEW TENANT-AWARE TABLES
-- =============================================================================

PROMPT Creating new tenant-aware table structure...

-- -----------------------------------------------------------------------------
-- DB_VALIDATION_TYPES - Global validation types (NO tenant_id needed)
-- -----------------------------------------------------------------------------
CREATE TABLE db_validation_types (
    validation_type_code VARCHAR2(100) PRIMARY KEY,
    description VARCHAR2(200) NOT NULL,
    validation_procedure VARCHAR2(100) NOT NULL,
    default_check_interval_minutes NUMBER DEFAULT 5,
    is_active NUMBER(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT chk_validation_types_active CHECK (is_active IN (0, 1))
);

COMMENT ON TABLE db_validation_types IS 'Global validation types - shared across all tenants';
COMMENT ON COLUMN db_validation_types.validation_type_code IS 'Unique validation type identifier';
COMMENT ON COLUMN db_validation_types.validation_procedure IS 'PLT_DB_MONITOR procedure name';

-- -----------------------------------------------------------------------------
-- DB_VALIDATION_RULES - Tenant + Environment specific rules
-- -----------------------------------------------------------------------------
CREATE TABLE db_validation_rules (
    rule_id NUMBER GENERATED ALWAYS AS IDENTITY,
    validation_type_code VARCHAR2(100) NOT NULL,
    tenant_id VARCHAR2(100) NOT NULL,
    environment_name VARCHAR2(10) NOT NULL,
    warning_threshold NUMBER,
    critical_threshold NUMBER,
    threshold_unit VARCHAR2(20) DEFAULT 'percentage',
    check_interval_minutes NUMBER DEFAULT 5,
    is_enabled NUMBER(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    
    -- Composite PRIMARY KEY with tenant context
    CONSTRAINT pk_validation_rules PRIMARY KEY (validation_type_code, tenant_id, environment_name),
    
    -- Foreign key to validation types
    CONSTRAINT fk_validation_rules_type FOREIGN KEY (validation_type_code) 
        REFERENCES db_validation_types(validation_type_code) ON DELETE CASCADE,
    
    -- Business rules
    CONSTRAINT chk_rules_enabled CHECK (is_enabled IN (0, 1)),
    CONSTRAINT chk_rules_thresholds CHECK (warning_threshold < critical_threshold),
    CONSTRAINT chk_rules_environment CHECK (environment_name IN ('PROD', 'UAT', 'DEV', 'TEST'))
);

COMMENT ON TABLE db_validation_rules IS 'Validation rules by tenant and environment';
COMMENT ON COLUMN db_validation_rules.tenant_id IS 'Tenant identifier (e.g., ACME_CORP, WIDGET_INC)';
COMMENT ON COLUMN db_validation_rules.environment_name IS 'Environment (PROD, UAT, DEV, TEST)';

-- -----------------------------------------------------------------------------
-- DB_VALIDATION_INSTANCES - Tenant + Environment specific instances
-- -----------------------------------------------------------------------------
CREATE TABLE db_validation_instances (
    instance_id NUMBER GENERATED ALWAYS AS IDENTITY,
    validation_type_code VARCHAR2(100) NOT NULL,
    tenant_id VARCHAR2(100) NOT NULL,
    environment_name VARCHAR2(10) NOT NULL,
    instance_name VARCHAR2(100) NOT NULL,
    instance_description VARCHAR2(200),
    target_identifier VARCHAR2(200) NOT NULL,
    is_enabled NUMBER(1) DEFAULT 0,
    last_check_time TIMESTAMP,
    last_check_status VARCHAR2(20),
    last_check_value NUMBER,
    consecutive_failures NUMBER DEFAULT 0,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    
    -- Composite PRIMARY KEY with full context
    CONSTRAINT pk_validation_instances PRIMARY KEY (validation_type_code, tenant_id, environment_name, instance_name),
    
    -- Foreign key to validation rules (ensures rule exists for this tenant/env)
    CONSTRAINT fk_validation_instances_rule FOREIGN KEY (validation_type_code, tenant_id, environment_name) 
        REFERENCES db_validation_rules(validation_type_code, tenant_id, environment_name) ON DELETE CASCADE,
    
    -- Business rules
    CONSTRAINT chk_instances_enabled CHECK (is_enabled IN (0, 1)),
    CONSTRAINT chk_instances_status CHECK (last_check_status IN ('OK', 'WARNING', 'CRITICAL', 'ERROR', NULL)),
    CONSTRAINT chk_instances_environment CHECK (environment_name IN ('PROD', 'UAT', 'DEV', 'TEST'))
);

COMMENT ON TABLE db_validation_instances IS 'Validation instances by tenant and environment';
COMMENT ON COLUMN db_validation_instances.tenant_id IS 'Tenant identifier';
COMMENT ON COLUMN db_validation_instances.environment_name IS 'Environment identifier';
COMMENT ON COLUMN db_validation_instances.instance_name IS 'Unique instance name within tenant/env/type';
COMMENT ON COLUMN db_validation_instances.target_identifier IS 'Database object to monitor (tablespace, job name, etc.)';

-- =============================================================================
-- 3. CREATE OPTIMIZED INDEXES
-- =============================================================================

PROMPT Creating tenant-aware indexes...

-- Indexes for efficient tenant-based queries
CREATE INDEX idx_validation_rules_tenant_env ON db_validation_rules(tenant_id, environment_name, is_enabled);
CREATE INDEX idx_validation_rules_enabled ON db_validation_rules(is_enabled, validation_type_code);

CREATE INDEX idx_validation_instances_tenant_env ON db_validation_instances(tenant_id, environment_name, is_enabled);
CREATE INDEX idx_validation_instances_status ON db_validation_instances(last_check_status, last_check_time);
CREATE INDEX idx_validation_instances_failures ON db_validation_instances(consecutive_failures) WHERE consecutive_failures > 0;
CREATE INDEX idx_validation_instances_enabled ON db_validation_instances(is_enabled, validation_type_code, tenant_id);

-- =============================================================================
-- 4. INSERT VALIDATION TYPES (GLOBAL - NO TENANT)
-- =============================================================================

PROMPT Inserting global validation types...

-- Core infrastructure monitoring
INSERT INTO db_validation_types VALUES ('TABLESPACE_USAGE', 'Monitor tablespace usage percentage', 'validate_tablespace_usage', 5, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('ACTIVE_SESSIONS', 'Monitor active session count', 'validate_active_sessions', 2, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('BLOCKED_SESSIONS', 'Monitor blocked sessions count', 'validate_blocked_sessions', 1, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('INVALID_OBJECTS', 'Monitor invalid database objects', 'validate_invalid_objects', 10, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('FAILED_JOBS', 'Monitor failed scheduler jobs', 'validate_failed_jobs', 5, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('MEMORY_USAGE', 'Monitor database memory usage', 'validate_memory_usage', 5, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('CPU_USAGE', 'Monitor database CPU usage', 'validate_cpu_usage', 2, 1, SYSTIMESTAMP);

-- Advanced Oracle metrics
INSERT INTO db_validation_types VALUES ('DB_CPU_RATIO', 'Monitor database CPU time ratio', 'validate_database_cpu_ratio', 2, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('CPU_USAGE_PER_TXN', 'Monitor CPU usage per transaction', 'validate_cpu_usage_per_txn', 3, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('BACKGROUND_CPU_USAGE', 'Monitor background CPU usage', 'validate_background_cpu_usage', 2, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('CPU_TIME_PER_CALL', 'Monitor CPU time per user call', 'validate_cpu_time_per_call', 3, 1, SYSTIMESTAMP);

-- Memory monitoring
INSERT INTO db_validation_types VALUES ('PGA_MEMORY_USAGE', 'PGA Memory Usage Monitoring', 'validate_pga_memory_usage', 5, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('UGA_MEMORY_USAGE', 'UGA Memory Usage Monitoring', 'validate_uga_memory_usage', 5, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('MEMORY_SORTS_COUNT', 'Memory Sorts Count Monitoring', 'validate_memory_sorts_count', 10, 1, SYSTIMESTAMP);
INSERT INTO db_validation_types VALUES ('WORKAREA_MEMORY_ALLOCATED', 'Work Area Memory Allocated Monitoring', 'validate_workarea_memory_allocated', 10, 1, SYSTIMESTAMP);

-- Business-specific validations
INSERT INTO db_validation_types VALUES ('CERT_EXPIRATION', 'Monitor certificate expiration dates', 'validate_certificate_expiration', 1440, 1, SYSTIMESTAMP);

-- =============================================================================
-- 5. INSERT TENANT-SPECIFIC RULES
-- =============================================================================

PROMPT Inserting tenant-specific validation rules...

-- -----------------------------------------------------------------------------
-- ACME_CORP tenant rules
-- -----------------------------------------------------------------------------

-- ACME_CORP PROD rules (strict thresholds)
INSERT ALL
    -- Tablespace monitoring
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled) 
    VALUES ('TABLESPACE_USAGE', 'ACME_CORP', 'PROD', 80.0, 90.0, 'percentage', 3, 1)
    
    -- Session monitoring  
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('ACTIVE_SESSIONS', 'ACME_CORP', 'PROD', 100, 150, 'count', 1, 1)
    
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('BLOCKED_SESSIONS', 'ACME_CORP', 'PROD', 2, 5, 'count', 1, 1)
    
    -- Resource monitoring
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('MEMORY_USAGE', 'ACME_CORP', 'PROD', 75.0, 85.0, 'percentage', 3, 1)
    
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('CPU_USAGE', 'ACME_CORP', 'PROD', 70.0, 85.0, 'percentage', 2, 1)
    
    -- Job monitoring
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('FAILED_JOBS', 'ACME_CORP', 'PROD', 1, 3, 'count', 5, 1)
    
    -- Object health
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('INVALID_OBJECTS', 'ACME_CORP', 'PROD', 3, 10, 'count', 10, 1)

SELECT * FROM dual;

-- ACME_CORP UAT rules (more relaxed)
INSERT ALL
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'ACME_CORP', 'UAT', 85.0, 95.0, 'percentage', 5, 1)
    
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('ACTIVE_SESSIONS', 'ACME_CORP', 'UAT', 50, 80, 'count', 3, 1)
    
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('MEMORY_USAGE', 'ACME_CORP', 'UAT', 80.0, 90.0, 'percentage', 5, 1)
    
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('CPU_USAGE', 'ACME_CORP', 'UAT', 75.0, 90.0, 'percentage', 5, 1)

SELECT * FROM dual;

-- -----------------------------------------------------------------------------
-- WIDGET_INC tenant rules
-- -----------------------------------------------------------------------------

-- WIDGET_INC PROD rules (different thresholds than ACME)
INSERT ALL
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'WIDGET_INC', 'PROD', 75.0, 88.0, 'percentage', 3, 1)
    
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('ACTIVE_SESSIONS', 'WIDGET_INC', 'PROD', 80, 120, 'count', 2, 1)
    
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('MEMORY_USAGE', 'WIDGET_INC', 'PROD', 70.0, 82.0, 'percentage', 3, 1)
    
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('CPU_USAGE', 'WIDGET_INC', 'PROD', 65.0, 80.0, 'percentage', 2, 1)

SELECT * FROM dual;

-- WIDGET_INC UAT rules
INSERT ALL
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'WIDGET_INC', 'UAT', 90.0, 98.0, 'percentage', 10, 1)
    
    INTO db_validation_rules (validation_type_code, tenant_id, environment_name, warning_threshold, critical_threshold, threshold_unit, check_interval_minutes, is_enabled)
    VALUES ('ACTIVE_SESSIONS', 'WIDGET_INC', 'UAT', 40, 60, 'count', 5, 1)

SELECT * FROM dual;

-- =============================================================================
-- 6. INSERT TENANT-SPECIFIC INSTANCES
-- =============================================================================

PROMPT Inserting tenant-specific validation instances...

-- -----------------------------------------------------------------------------
-- ACME_CORP instances
-- -----------------------------------------------------------------------------

-- ACME_CORP PROD tablespaces
INSERT ALL
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'ACME_CORP', 'PROD', 'ACME_PROD_DATA_TS', 'ACME PROD main data tablespace', 'ACME_PROD_DATA', 1)
    
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'ACME_CORP', 'PROD', 'ACME_PROD_INDEX_TS', 'ACME PROD index tablespace', 'ACME_PROD_INDEX', 1)
    
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'ACME_CORP', 'PROD', 'ACME_PROD_TEMP_TS', 'ACME PROD temp tablespace', 'ACME_PROD_TEMP', 1)

SELECT * FROM dual;

-- ACME_CORP PROD global monitoring
INSERT ALL
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('ACTIVE_SESSIONS', 'ACME_CORP', 'PROD', 'ACME_PROD_SESSIONS', 'ACME PROD active sessions monitor', 'ALL', 1)
    
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('MEMORY_USAGE', 'ACME_CORP', 'PROD', 'ACME_PROD_SGA_MEMORY', 'ACME PROD SGA memory usage', 'SGA', 1)
    
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('CPU_USAGE', 'ACME_CORP', 'PROD', 'ACME_PROD_DATABASE_CPU', 'ACME PROD database CPU usage', 'DB_CPU', 1)

SELECT * FROM dual;

-- ACME_CORP UAT tablespaces
INSERT ALL
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'ACME_CORP', 'UAT', 'ACME_UAT_DATA_TS', 'ACME UAT main data tablespace', 'ACME_UAT_DATA', 1)
    
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'ACME_CORP', 'UAT', 'ACME_UAT_INDEX_TS', 'ACME UAT index tablespace', 'ACME_UAT_INDEX', 1)

SELECT * FROM dual;

-- -----------------------------------------------------------------------------
-- WIDGET_INC instances
-- -----------------------------------------------------------------------------

-- WIDGET_INC PROD tablespaces (different naming convention)
INSERT ALL
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'WIDGET_INC', 'PROD', 'WIDGET_PROD_APP_DATA', 'Widget Inc PROD application data', 'WIDGET_APP_DATA_PROD', 1)
    
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'WIDGET_INC', 'PROD', 'WIDGET_PROD_APP_IDX', 'Widget Inc PROD application indexes', 'WIDGET_APP_IDX_PROD', 1)
    
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'WIDGET_INC', 'PROD', 'WIDGET_PROD_REPORTS_DATA', 'Widget Inc PROD reports data', 'WIDGET_REPORTS_PROD', 1)

SELECT * FROM dual;

-- WIDGET_INC PROD monitoring
INSERT ALL
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('ACTIVE_SESSIONS', 'WIDGET_INC', 'PROD', 'WIDGET_PROD_SESSIONS', 'Widget Inc PROD session monitoring', 'ALL', 1)
    
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('MEMORY_USAGE', 'WIDGET_INC', 'PROD', 'WIDGET_PROD_MEMORY', 'Widget Inc PROD memory monitoring', 'SGA', 1)

SELECT * FROM dual;

-- WIDGET_INC UAT tablespaces
INSERT ALL
    INTO db_validation_instances (validation_type_code, tenant_id, environment_name, instance_name, instance_description, target_identifier, is_enabled)
    VALUES ('TABLESPACE_USAGE', 'WIDGET_INC', 'UAT', 'WIDGET_UAT_APP_DATA', 'Widget Inc UAT application data', 'WIDGET_APP_DATA_UAT', 1)

SELECT * FROM dual;

-- =============================================================================
-- 7. VERIFICATION QUERIES
-- =============================================================================

PROMPT
PROMPT =============================================================================
PROMPT Migration completed! Verification results:
PROMPT =============================================================================

PROMPT
PROMPT Validation Types (Global):
SELECT validation_type_code, description, is_active 
FROM db_validation_types 
ORDER BY validation_type_code;

PROMPT
PROMPT =============================================================================
PROMPT Validation Rules by Tenant/Environment:
PROMPT =============================================================================
SELECT 
    tenant_id,
    environment_name,
    validation_type_code,
    warning_threshold || ' ' || threshold_unit as warning_level,
    critical_threshold || ' ' || threshold_unit as critical_level,
    check_interval_minutes,
    CASE WHEN is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END as status
FROM db_validation_rules
ORDER BY tenant_id, environment_name, validation_type_code;

PROMPT
PROMPT =============================================================================
PROMPT Validation Instances by Tenant/Environment:
PROMPT =============================================================================
SELECT 
    tenant_id,
    environment_name,
    validation_type_code,
    instance_name,
    target_identifier,
    CASE WHEN is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END as status
FROM db_validation_instances
ORDER BY tenant_id, environment_name, validation_type_code, instance_name;

PROMPT
PROMPT =============================================================================
PROMPT Summary by Tenant:
PROMPT =============================================================================
SELECT 
    r.tenant_id,
    r.environment_name,
    COUNT(DISTINCT r.validation_type_code) as configured_rule_types,
    COUNT(DISTINCT i.validation_type_code) as configured_instance_types,
    SUM(CASE WHEN i.is_enabled = 1 THEN 1 ELSE 0 END) as enabled_instances,
    COUNT(i.instance_id) as total_instances
FROM db_validation_rules r
LEFT JOIN db_validation_instances i ON (
    r.validation_type_code = i.validation_type_code 
    AND r.tenant_id = i.tenant_id 
    AND r.environment_name = i.environment_name
)
GROUP BY r.tenant_id, r.environment_name
ORDER BY r.tenant_id, r.environment_name

COMMIT;

PROMPT
PROMPT ✅ PLT_DB_MONITOR tenant-aware migration completed successfully!
PROMPT
PROMPT Next steps:
PROMPT 1. Update PLT_DB_MONITOR package to use tenant context
PROMPT 2. Modify detect_environment() to also detect tenant
PROMPT 3. Update all validation procedures to filter by tenant+environment
PROMPT 4. Test with: PLT_DB_MONITOR.perform_database_validations_for_tenant('ACME_CORP', 'PROD')
PROMPT
PROMPT 🎯 Ready for multi-tenant database monitoring!
PROMPT =============================================================================

CREATE TABLE plt_db_monitor_config (
    config_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id VARCHAR2(100) NOT NULL,
    environment_name VARCHAR2(10) NOT NULL,
    instance_identifier VARCHAR2(100),
    description VARCHAR2(200),
    is_active NUMBER(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    
    -- Business constraints
    CONSTRAINT chk_monitor_config_active CHECK (is_active IN (0, 1)),
    CONSTRAINT chk_monitor_config_env CHECK (environment_name IN ('PROD', 'UAT', 'DEV', 'TEST')),
    CONSTRAINT uk_monitor_config_tenant_env UNIQUE (tenant_id, environment_name)
);

COMMENT ON TABLE plt_db_monitor_config IS 'PLT_DB_MONITOR tenant and environment configuration';
COMMENT ON COLUMN plt_db_monitor_config.tenant_id IS 'Tenant identifier for this database instance';
COMMENT ON COLUMN plt_db_monitor_config.environment_name IS 'Environment identifier (PROD, UAT, DEV, TEST)';
COMMENT ON COLUMN plt_db_monitor_config.instance_identifier IS 'Unique identifier for this database instance';

-- Create index for fast lookups
CREATE INDEX idx_monitor_config_active ON plt_db_monitor_config(is_active, tenant_id, environment_name);

-- Insert example configuration (you'll need to customize this)
INSERT INTO plt_db_monitor_config (
    tenant_id, 
    environment_name, 
    instance_identifier, 
    description,
    is_active
) VALUES (
    'ACME_CORP',
    'PROD', 
    SYS_CONTEXT('USERENV', 'DB_NAME') || '_' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME'),
    'Auto-configured for ' || SYS_CONTEXT('USERENV', 'DB_NAME'),
    1
);

COMMIT;