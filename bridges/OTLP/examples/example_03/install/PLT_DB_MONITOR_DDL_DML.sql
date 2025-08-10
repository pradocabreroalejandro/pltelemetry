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
    FOR rec
        IN (  SELECT table_name
                FROM user_tables
               WHERE table_name LIKE 'DB_VALIDATION_%'
            ORDER BY CASE table_name WHEN 'DB_VALIDATION_INSTANCES' THEN 1 WHEN 'DB_VALIDATION_RULES' THEN 2 WHEN 'DB_VALIDATION_TYPES' THEN 3 END)
    LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS PURGE';

        DBMS_OUTPUT.PUT_LINE ('🗑️  Dropped table: ' || rec.table_name);
    END LOOP;
EXCEPTION
    WHEN OTHERS
    THEN
        DBMS_OUTPUT.PUT_LINE ('ℹ️  Some tables may not exist, continuing...');
END;
/

-- =============================================================================
-- 2. CREATE NEW TENANT-AWARE TABLES
-- =============================================================================

PROMPT Creating new tenant-aware table structure...

-- -----------------------------------------------------------------------------
-- DB_VALIDATION_TYPES - Global validation types (NO tenant_id needed)
-- -----------------------------------------------------------------------------

CREATE TABLE db_validation_types
(
    validation_type_code             VARCHAR2 (100) PRIMARY KEY,
    description                      VARCHAR2 (200) NOT NULL,
    validation_procedure             VARCHAR2 (100) NOT NULL,
    default_check_interval_minutes   NUMBER DEFAULT 5,
    is_active                        NUMBER (1) DEFAULT 1,
    created_at                       TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT chk_validation_types_active CHECK (is_active IN (0, 1))
);

COMMENT ON TABLE db_validation_types IS 'Global validation types - shared across all tenants';
COMMENT ON COLUMN db_validation_types.validation_type_code IS 'Unique validation type identifier';
COMMENT ON COLUMN db_validation_types.validation_procedure IS 'PLT_DB_MONITOR procedure name';

-- -----------------------------------------------------------------------------
-- DB_VALIDATION_RULES - Tenant specific rules
-- -----------------------------------------------------------------------------

CREATE TABLE db_validation_rules
(
    rule_id                  NUMBER GENERATED ALWAYS AS IDENTITY,
    validation_type_code     VARCHAR2 (100) NOT NULL,
    tenant_id                VARCHAR2 (100) NOT NULL,
    warning_threshold        NUMBER,
    critical_threshold       NUMBER,
    threshold_unit           VARCHAR2 (20) DEFAULT 'percentage',
    check_interval_minutes   NUMBER DEFAULT 5,
    is_enabled               NUMBER (1) DEFAULT 1,
    created_at               TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_at               TIMESTAMP DEFAULT SYSTIMESTAMP,
    -- Composite PRIMARY KEY with tenant context
    CONSTRAINT pk_validation_rules PRIMARY KEY (validation_type_code, tenant_id),
    -- Foreign key to validation types
    CONSTRAINT fk_validation_rules_type FOREIGN KEY (validation_type_code) REFERENCES db_validation_types (validation_type_code) ON DELETE CASCADE,
    -- Business rules
    CONSTRAINT chk_rules_enabled CHECK (is_enabled IN (0, 1)),
    CONSTRAINT chk_rules_thresholds CHECK (warning_threshold < critical_threshold)
);

COMMENT ON TABLE db_validation_rules IS 'Validation rules by tenant';
COMMENT ON COLUMN db_validation_rules.tenant_id IS 'Tenant identifier (e.g., ACME_CORP, WIDGET_INC)';

-- -----------------------------------------------------------------------------
-- DB_VALIDATION_INSTANCES - Tenant specific instances
-- -----------------------------------------------------------------------------

CREATE TABLE db_validation_instances
(
    instance_id            NUMBER GENERATED ALWAYS AS IDENTITY,
    validation_type_code   VARCHAR2 (100) NOT NULL,
    tenant_id              VARCHAR2 (100) NOT NULL,
    instance_name          VARCHAR2 (100) NOT NULL,
    instance_description   VARCHAR2 (200),
    target_identifier      VARCHAR2 (200) NOT NULL,
    is_enabled             NUMBER (1) DEFAULT 0,
    last_check_time        TIMESTAMP,
    last_check_status      VARCHAR2 (20),
    last_check_value       NUMBER,
    consecutive_failures   NUMBER DEFAULT 0,
    created_at             TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_at             TIMESTAMP DEFAULT SYSTIMESTAMP,
    -- Composite PRIMARY KEY with full context
    CONSTRAINT pk_validation_instances PRIMARY KEY (validation_type_code, tenant_id, instance_name),
    -- Foreign key to validation rules (ensures rule exists for this tenant)
    CONSTRAINT fk_validation_instances_rule FOREIGN KEY (validation_type_code, tenant_id)
    REFERENCES db_validation_rules (validation_type_code, tenant_id) ON DELETE CASCADE,
    -- Business rules
    CONSTRAINT chk_instances_enabled CHECK (is_enabled IN (0, 1)),
    CONSTRAINT chk_instances_status CHECK
        (last_check_status IN ('OK',
                               'WARNING',
                               'CRITICAL',
                               'ERROR',
                               NULL))
);

COMMENT ON TABLE db_validation_instances IS 'Validation instances by tenant';
COMMENT ON COLUMN db_validation_instances.tenant_id IS 'Tenant identifier';
COMMENT ON COLUMN db_validation_instances.instance_name IS 'Unique instance name within tenant/type';
COMMENT ON COLUMN db_validation_instances.target_identifier IS 'Database object to monitor (tablespace, job name, etc.)';

-- =============================================================================
-- 3. CREATE OPTIMIZED INDEXES
-- =============================================================================

PROMPT Creating tenant-aware indexes...

-- Indexes for efficient tenant-based queries

CREATE INDEX idx_validation_rules_tenant
    ON db_validation_rules (tenant_id, is_enabled);

CREATE INDEX idx_validation_rules_enabled
    ON db_validation_rules (is_enabled, validation_type_code);

CREATE INDEX idx_validation_instances_tenant
    ON db_validation_instances (tenant_id, is_enabled);

CREATE INDEX idx_validation_instances_status
    ON db_validation_instances (last_check_status, last_check_time);

CREATE INDEX idx_validation_instances_failures
    ON db_validation_instances (consecutive_failures);

CREATE INDEX idx_validation_instances_enabled
    ON db_validation_instances (is_enabled, validation_type_code, tenant_id);

-- =============================================================================
-- 4. INSERT VALIDATION TYPES (GLOBAL - NO TENANT)
-- =============================================================================

PROMPT Inserting global validation types...

-- Core infrastructure monitoring

INSERT INTO db_validation_types
     VALUES ('TABLESPACE_USAGE',
             'Monitor tablespace usage percentage',
             'validate_tablespace_usage',
             5,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('ACTIVE_SESSIONS',
             'Monitor active session count',
             'validate_active_sessions',
             2,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('BLOCKED_SESSIONS',
             'Monitor blocked sessions count',
             'validate_blocked_sessions',
             1,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('INVALID_OBJECTS',
             'Monitor invalid database objects',
             'validate_invalid_objects',
             10,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('FAILED_JOBS',
             'Monitor failed scheduler jobs',
             'validate_failed_jobs',
             5,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('MEMORY_USAGE',
             'Monitor database memory usage',
             'validate_memory_usage',
             5,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('CPU_USAGE',
             'Monitor database CPU usage',
             'validate_cpu_usage',
             2,
             1,
             SYSTIMESTAMP);

-- Advanced Oracle metrics

INSERT INTO db_validation_types
     VALUES ('DB_CPU_RATIO',
             'Monitor database CPU time ratio',
             'validate_database_cpu_ratio',
             2,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('CPU_USAGE_PER_TXN',
             'Monitor CPU usage per transaction',
             'validate_cpu_usage_per_txn',
             3,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('BACKGROUND_CPU_USAGE',
             'Monitor background CPU usage',
             'validate_background_cpu_usage',
             2,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('CPU_TIME_PER_CALL',
             'Monitor CPU time per user call',
             'validate_cpu_time_per_call',
             3,
             1,
             SYSTIMESTAMP);

-- Memory monitoring

INSERT INTO db_validation_types
     VALUES ('PGA_MEMORY_USAGE',
             'PGA Memory Usage Monitoring',
             'validate_pga_memory_usage',
             5,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('UGA_MEMORY_USAGE',
             'UGA Memory Usage Monitoring',
             'validate_uga_memory_usage',
             5,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('MEMORY_SORTS_COUNT',
             'Memory Sorts Count Monitoring',
             'validate_memory_sorts_count',
             10,
             1,
             SYSTIMESTAMP);

INSERT INTO db_validation_types
     VALUES ('WORKAREA_MEMORY_ALLOCATED',
             'Work Area Memory Allocated Monitoring',
             'validate_workarea_memory_allocated',
             10,
             1,
             SYSTIMESTAMP);

-- Business-specific validations

INSERT INTO db_validation_types
     VALUES ('CERT_EXPIRATION',
             'Monitor certificate expiration dates',
             'validate_certificate_expiration',
             1440,
             1,
             SYSTIMESTAMP);

-- =============================================================================
-- 5. INSERT TENANT-SPECIFIC RULES
-- =============================================================================

PROMPT Inserting tenant-specific validation rules...

-- -----------------------------------------------------------------------------
-- ACME_CORP tenant rules
-- -----------------------------------------------------------------------------

-- ACME_CORP PROD rules (strict thresholds)

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('TABLESPACE_USAGE',
             'ACME_CORP',
             80.0,
             90.0,
             'percentage',
             3,
             1);


    -- Session monitoring

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('ACTIVE_SESSIONS',
             'ACME_CORP',
             100,
             150,
             'count',
             1,
             1);


INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('BLOCKED_SESSIONS',
             'ACME_CORP',
             2,
             5,
             'count',
             1,
             1);

    -- Resource monitoring

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('MEMORY_USAGE',
             'ACME_CORP',
             75.0,
             85.0,
             'percentage',
             3,
             1);

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('CPU_USAGE',
             'ACME_CORP',
             70.0,
             85.0,
             'percentage',
             2,
             1);

    -- Job monitoring

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('FAILED_JOBS',
             'ACME_CORP',
             1,
             3,
             'count',
             5,
             1);

    -- Object health

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('INVALID_OBJECTS',
             'ACME_CORP',
             3,
             10,
             'count',
             10,
             1);

-- -----------------------------------------------------------------------------
-- WIDGET_INC tenant rules
-- -----------------------------------------------------------------------------

-- WIDGET_INC PROD rules (different thresholds than ACME)

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('TABLESPACE_USAGE',
             'WIDGET_INC',
             75.0,
             88.0,
             'percentage',
             3,
             1);

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('ACTIVE_SESSIONS',
             'WIDGET_INC',
             80,
             120,
             'count',
             2,
             1);

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('MEMORY_USAGE',
             'WIDGET_INC',
             70.0,
             82.0,
             'percentage',
             3,
             1);

INSERT INTO db_validation_rules (validation_type_code,
                                 tenant_id,
                                 warning_threshold,
                                 critical_threshold,
                                 threshold_unit,
                                 check_interval_minutes,
                                 is_enabled)
     VALUES ('CPU_USAGE',
             'WIDGET_INC',
             65.0,
             80.0,
             'percentage',
             2,
             1);



-- =============================================================================
-- 6. INSERT TENANT-SPECIFIC INSTANCES
-- =============================================================================

PROMPT Inserting tenant-specific validation instances...

-- -----------------------------------------------------------------------------
-- ACME_CORP instances
-- -----------------------------------------------------------------------------

-- ACME_CORP PROD tablespaces

INSERT INTO db_validation_instances (validation_type_code,
                                     tenant_id,
                                     instance_name,
                                     instance_description,
                                     target_identifier,
                                     is_enabled)
     VALUES ('TABLESPACE_USAGE',
             'ACME_CORP',
             'ACME_PROD_DATA_TS',
             'ACME PROD main data tablespace',
             'ACME_PROD_DATA',
             1);

INSERT INTO db_validation_instances (validation_type_code,
                                     tenant_id,
                                     instance_name,
                                     instance_description,
                                     target_identifier,
                                     is_enabled)
     VALUES ('TABLESPACE_USAGE',
             'ACME_CORP',
             'ACME_PROD_INDEX_TS',
             'ACME PROD index tablespace',
             'ACME_PROD_INDEX',
             1);

INSERT INTO db_validation_instances (validation_type_code,
                                     tenant_id,
                                     instance_name,
                                     instance_description,
                                     target_identifier,
                                     is_enabled)
     VALUES ('TABLESPACE_USAGE',
             'ACME_CORP',
             'ACME_PROD_TEMP_TS',
             'ACME PROD temp tablespace',
             'ACME_PROD_TEMP',
             1);



-- -----------------------------------------------------------------------------
-- WIDGET_INC instances
-- -----------------------------------------------------------------------------

-- WIDGET_INC PROD tablespaces (different naming convention)

INSERT INTO db_validation_instances (validation_type_code,
                                     tenant_id,
                                     instance_name,
                                     instance_description,
                                     target_identifier,
                                     is_enabled)
     VALUES ('TABLESPACE_USAGE',
             'WIDGET_INC',
             'WIDGET_PROD_APP_DATA',
             'Widget Inc PROD application data',
             'WIDGET_APP_DATA_PROD',
             1);

INSERT INTO db_validation_instances (validation_type_code,
                                     tenant_id,
                                     instance_name,
                                     instance_description,
                                     target_identifier,
                                     is_enabled)
     VALUES ('TABLESPACE_USAGE',
             'WIDGET_INC',
             'WIDGET_PROD_APP_IDX',
             'Widget Inc PROD application indexes',
             'WIDGET_APP_IDX_PROD',
             1);

INSERT INTO db_validation_instances (validation_type_code,
                                     tenant_id,
                                     instance_name,
                                     instance_description,
                                     target_identifier,
                                     is_enabled)
     VALUES ('TABLESPACE_USAGE',
             'WIDGET_INC',
             'WIDGET_PROD_REPORTS_DATA',
             'Widget Inc PROD reports data',
             'WIDGET_REPORTS_PROD',
             1);



-- WIDGET_INC PROD monitoring

INSERT INTO db_validation_instances (validation_type_code,
                                     tenant_id,
                                     instance_name,
                                     instance_description,
                                     target_identifier,
                                     is_enabled)
     VALUES ('ACTIVE_SESSIONS',
             'WIDGET_INC',
             'WIDGET_PROD_SESSIONS',
             'Widget Inc PROD session monitoring',
             'ALL',
             1);

INSERT INTO db_validation_instances (validation_type_code,
                                     tenant_id,
                                     instance_name,
                                     instance_description,
                                     target_identifier,
                                     is_enabled)
     VALUES ('MEMORY_USAGE',
             'WIDGET_INC',
             'WIDGET_PROD_MEMORY',
             'Widget Inc PROD memory monitoring',
             'SGA',
             1);


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
PROMPT Validation Rules by Tenant:
PROMPT =============================================================================

  SELECT tenant_id,
         validation_type_code,
         warning_threshold || ' ' || threshold_unit                AS warning_level,
         critical_threshold || ' ' || threshold_unit               AS critical_level,
         check_interval_minutes,
         CASE WHEN is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END AS status
    FROM db_validation_rules
ORDER BY tenant_id, validation_type_code;

PROMPT
PROMPT =============================================================================
PROMPT Validation Instances by Tenant:
PROMPT =============================================================================

  SELECT tenant_id,
         validation_type_code,
         instance_name,
         target_identifier,
         CASE WHEN is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END AS status
    FROM db_validation_instances
ORDER BY tenant_id, validation_type_code, instance_name;

PROMPT
PROMPT =============================================================================
PROMPT Summary by Tenant:
PROMPT =============================================================================

  SELECT r.tenant_id,
         COUNT (DISTINCT r.validation_type_code)          AS configured_rule_types,
         COUNT (DISTINCT i.validation_type_code)          AS configured_instance_types,
         SUM (CASE WHEN i.is_enabled = 1 THEN 1 ELSE 0 END) AS enabled_instances,
         COUNT (i.instance_id)                            AS total_instances
    FROM db_validation_rules r LEFT JOIN db_validation_instances i ON (r.validation_type_code = i.validation_type_code AND r.tenant_id = i.tenant_id)
GROUP BY r.tenant_id
ORDER BY r.tenant_id;

COMMIT;

PROMPT
PROMPT ✅ PLT_DB_MONITOR tenant-aware migration completed successfully!
PROMPT
PROMPT Next steps:
PROMPT 1. Update PLT_DB_MONITOR package to use tenant context
PROMPT 3. Update all validation procedures to filter by tenant
PROMPT 4. Test with: PLT_DB_MONITOR.perform_database_validations_for_tenant('ACME_CORP', 'PROD')
PROMPT
PROMPT 🎯 Ready for multi-tenant database monitoring!
PROMPT =============================================================================

drop table plt_db_monitor_config;

CREATE TABLE plt_db_monitor_config
(
    config_id             NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id             VARCHAR2 (100) NOT NULL,
    instance_identifier   VARCHAR2 (100),
    description           VARCHAR2 (200),
    is_active             NUMBER (1) DEFAULT 1,
    created_at            TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_at            TIMESTAMP DEFAULT SYSTIMESTAMP,
    -- Business constraints
    CONSTRAINT chk_monitor_config_active CHECK (is_active IN (0, 1)),
    CONSTRAINT uk_monitor_config_tenant UNIQUE (tenant_id)
);

COMMENT ON TABLE plt_db_monitor_config IS 'PLT_DB_MONITOR tenant configuration';
COMMENT ON COLUMN plt_db_monitor_config.tenant_id IS 'Tenant identifier for this database instance';
COMMENT ON COLUMN plt_db_monitor_config.instance_identifier IS 'Unique identifier for this database instance';

-- Create index for fast lookups

CREATE INDEX idx_monitor_config_active
    ON plt_db_monitor_config (is_active, tenant_id);

-- Insert example configuration (you'll need to customize this)

INSERT INTO plt_db_monitor_config (tenant_id,
                                   instance_identifier,
                                   description,
                                   is_active)
     VALUES ('ACME_CORP',
             SYS_CONTEXT ('USERENV', 'DB_NAME') || '_' || SYS_CONTEXT ('USERENV', 'INSTANCE_NAME'),
             'Auto-configured for ' || SYS_CONTEXT ('USERENV', 'DB_NAME'),
             1);

COMMIT;
