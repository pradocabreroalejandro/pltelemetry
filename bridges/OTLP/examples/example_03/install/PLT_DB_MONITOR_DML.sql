-- =============================================================================
-- PLT_DB_MONITOR - Database Monitoring DML
-- Configuration data for table-driven database validation system
-- =============================================================================

PROMPT Inserting PLT_DB_MONITOR configuration data...

-- =============================================================================
-- 1. Insert Validation Types
-- =============================================================================

-- Tablespace usage validation
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'TABLESPACE_USAGE',
    'Monitor tablespace usage percentage',
    'validate_tablespace_usage',
    5,
    1
);

-- Active sessions validation  
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'ACTIVE_SESSIONS',
    'Monitor active session count',
    'validate_active_sessions',
    2,
    1
);

-- Blocked sessions validation
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'BLOCKED_SESSIONS',
    'Monitor blocked sessions count',
    'validate_blocked_sessions',
    1,
    1
);

-- Invalid objects validation
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'INVALID_OBJECTS',
    'Monitor invalid database objects',
    'validate_invalid_objects',
    10,
    1
);

-- Failed jobs validation
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'FAILED_JOBS',
    'Monitor failed scheduler jobs',
    'validate_failed_jobs',
    5,
    1
);

-- Memory usage validation
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'MEMORY_USAGE',
    'Monitor database memory usage',
    'validate_memory_usage',
    5,
    1
);

-- CPU usage validation
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'CPU_USAGE',
    'Monitor database CPU usage',
    'validate_cpu_usage',
    2,
    1
);

-- Custom certificate expiration validation (your wildcard example!)
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'CERT_EXPIRATION',
    'Monitor certificate expiration dates',
    'validate_certificate_expiration',
    1440, -- Check once per day
    1
);

-- =============================================================================
-- 2. Insert Validation Rules by Environment
-- =============================================================================

-- TABLESPACE_USAGE rules
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'TABLESPACE_USAGE',
    'PROD',
    85.0,  -- 85% warning
    95.0,  -- 95% critical
    'percentage',
    5,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'TABLESPACE_USAGE',
    'TEST',
    90.0,  -- 90% warning
    98.0,  -- 98% critical
    'percentage',
    10,
    1
);

-- ACTIVE_SESSIONS rules
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'ACTIVE_SESSIONS',
    'PROD',
    80,    -- 80 sessions warning
    120,   -- 120 sessions critical
    'count',
    2,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'ACTIVE_SESSIONS',
    'TEST',
    50,    -- 50 sessions warning
    80,    -- 80 sessions critical
    'count',
    5,
    1
);

-- BLOCKED_SESSIONS rules
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'BLOCKED_SESSIONS',
    'PROD',
    3,     -- 3 blocked sessions warning
    10,    -- 10 blocked sessions critical
    'count',
    1,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'BLOCKED_SESSIONS',
    'TEST',
    5,     -- 5 blocked sessions warning
    15,    -- 15 blocked sessions critical
    'count',
    2,
    1
);

-- INVALID_OBJECTS rules
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'INVALID_OBJECTS',
    'PROD',
    5,     -- 5 invalid objects warning
    20,    -- 20 invalid objects critical
    'count',
    10,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'INVALID_OBJECTS',
    'TEST',
    10,    -- 10 invalid objects warning
    50,    -- 50 invalid objects critical
    'count',
    15,
    1
);

-- FAILED_JOBS rules
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'FAILED_JOBS',
    'PROD',
    1,     -- 1 failed job warning
    5,     -- 5 failed jobs critical
    'count',
    5,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'FAILED_JOBS',
    'TEST',
    3,     -- 3 failed jobs warning
    10,    -- 10 failed jobs critical
    'count',
    10,
    1
);

-- MEMORY_USAGE rules
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'MEMORY_USAGE',
    'PROD',
    80.0,  -- 80% memory warning
    90.0,  -- 90% memory critical
    'percentage',
    5,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'MEMORY_USAGE',
    'TEST',
    85.0,  -- 85% memory warning
    95.0,  -- 95% memory critical
    'percentage',
    10,
    1
);

-- CPU_USAGE rules
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'CPU_USAGE',
    'PROD',
    70.0,  -- 70% CPU warning
    85.0,  -- 85% CPU critical
    'percentage',
    2,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'CPU_USAGE',
    'TEST',
    80.0,  -- 80% CPU warning
    90.0,  -- 90% CPU critical
    'percentage',
    5,
    1
);

-- CERT_EXPIRATION rules (days until expiration)
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'CERT_EXPIRATION',
    'PROD',
    30,    -- 30 days warning
    7,     -- 7 days critical (note: reversed logic - lower is worse)
    'days',
    1440,  -- Check daily
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'CERT_EXPIRATION',
    'TEST',
    60,    -- 60 days warning
    14,    -- 14 days critical
    'days',
    1440,  -- Check daily
    1
);

-- =============================================================================
-- 3. Insert Example Validation Instances (ALL DISABLED by default)
-- =============================================================================

-- Example tablespace instances (you'll populate these based on your actual tablespaces)
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'TABLESPACE_USAGE',
    'SYSTEM_TABLESPACE',
    'System tablespace usage monitoring',
    'SYSTEM',
    0  -- DISABLED by default
);

INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'TABLESPACE_USAGE',
    'USERS_TABLESPACE',
    'Users tablespace usage monitoring',
    'USERS',
    0  -- DISABLED by default
);

INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'TABLESPACE_USAGE',
    'TEMP_TABLESPACE',
    'Temp tablespace usage monitoring',
    'TEMP',
    0  -- DISABLED by default
);

-- Global active sessions instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'ACTIVE_SESSIONS',
    'GLOBAL_ACTIVE_SESSIONS',
    'Total active sessions in database',
    'ALL',
    0  -- DISABLED by default
);

-- Global blocked sessions instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'BLOCKED_SESSIONS',
    'GLOBAL_BLOCKED_SESSIONS',
    'Total blocked sessions in database',
    'ALL',
    0  -- DISABLED by default
);

-- Global invalid objects instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'INVALID_OBJECTS',
    'GLOBAL_INVALID_OBJECTS',
    'Total invalid objects in database',
    'ALL',
    0  -- DISABLED by default
);

-- Global failed jobs instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'FAILED_JOBS',
    'GLOBAL_FAILED_JOBS',
    'Failed scheduler jobs monitoring',
    'ALL',
    0  -- DISABLED by default
);

-- SGA memory usage instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'MEMORY_USAGE',
    'SGA_MEMORY_USAGE',
    'SGA memory usage monitoring',
    'SGA',
    0  -- DISABLED by default
);

-- PGA memory usage instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'MEMORY_USAGE',
    'PGA_MEMORY_USAGE',
    'PGA memory usage monitoring',
    'PGA',
    0  -- DISABLED by default
);

-- CPU usage instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'CPU_USAGE',
    'DATABASE_CPU_USAGE',
    'Database CPU usage monitoring',
    'DB_CPU',
    0  -- DISABLED by default
);

-- Example certificate expiration instances (your wildcard example!)
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'CERT_EXPIRATION',
    'SSL_CERT_MAIN',
    'Main SSL certificate expiration',
    'MAIN_SSL_CERT',
    0  -- DISABLED by default
);

INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'CERT_EXPIRATION',
    'TDE_WALLET_CERT',
    'TDE wallet certificate expiration',
    'TDE_WALLET',
    0  -- DISABLED by default
);

-- =============================================================================
-- PLT_DB_MONITOR - New Oracle 23ai CPU Metrics DML (FIXED ORDER)
-- Additional CPU monitoring capabilities for Oracle 23ai
-- =============================================================================

PROMPT Inserting Oracle 23ai CPU metrics configuration (CORRECTED ORDER)...

-- =============================================================================
-- 1. FIRST: Insert Validation Types for Oracle 23ai CPU Metrics
-- =============================================================================

-- Database CPU ratio validation (Oracle 23ai)
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'DB_CPU_RATIO',
    'Monitor database CPU time ratio (Oracle 23ai)',
    'validate_database_cpu_ratio',
    2,
    1
);

-- CPU usage per transaction validation (Oracle 23ai)
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'CPU_USAGE_PER_TXN',
    'Monitor CPU usage per transaction (Oracle 23ai)',
    'validate_cpu_usage_per_txn',
    3,
    1
);

-- Background CPU usage validation (Oracle 23ai)
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'BACKGROUND_CPU_USAGE',
    'Monitor background CPU usage (Oracle 23ai)',
    'validate_background_cpu_usage',
    2,
    1
);

-- CPU time per user call validation (Oracle 23ai)
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'CPU_TIME_PER_CALL',
    'Monitor CPU time per user call (Oracle 23ai)',
    'validate_cpu_time_per_call',
    3,
    1
);

-- =============================================================================
-- 2. SECOND: Insert Validation Rules (need types to exist first)
-- =============================================================================

-- DB_CPU_RATIO rules (percentage values)
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'DB_CPU_RATIO',
    'PROD',
    75.0,  -- 75% database CPU ratio warning
    90.0,  -- 90% database CPU ratio critical
    'percentage',
    2,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'DB_CPU_RATIO',
    'TEST',
    80.0,  -- 80% warning in test
    95.0,  -- 95% critical in test
    'percentage',
    5,
    1
);

-- CPU_USAGE_PER_TXN rules (centiseconds per transaction)
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'CPU_USAGE_PER_TXN',
    'PROD',
    50.0,   -- 50 centiseconds per txn warning
    100.0,  -- 100 centiseconds per txn critical
    'centiseconds',
    3,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'CPU_USAGE_PER_TXN',
    'TEST',
    75.0,   -- 75 centiseconds warning in test
    150.0,  -- 150 centiseconds critical in test
    'centiseconds',
    5,
    1
);

-- BACKGROUND_CPU_USAGE rules (CPU usage per second)
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'BACKGROUND_CPU_USAGE',
    'PROD',
    20.0,  -- 20 CPU units per second warning
    40.0,  -- 40 CPU units per second critical
    'cpu_per_sec',
    2,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'BACKGROUND_CPU_USAGE',
    'TEST',
    30.0,  -- 30 CPU units warning in test
    60.0,  -- 60 CPU units critical in test
    'cpu_per_sec',
    5,
    1
);

-- CPU_TIME_PER_CALL rules (centiseconds per call)
INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'CPU_TIME_PER_CALL',
    'PROD',
    5.0,   -- 5 centiseconds per call warning
    15.0,  -- 15 centiseconds per call critical
    'centiseconds',
    3,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled
) VALUES (
    'CPU_TIME_PER_CALL',
    'TEST',
    10.0,  -- 10 centiseconds warning in test
    25.0,  -- 25 centiseconds critical in test
    'centiseconds',
    5,
    1
);

-- =============================================================================
-- 3. FINALLY: Insert Validation Instances (need both types and rules to exist)
-- =============================================================================

-- Database CPU ratio instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'DB_CPU_RATIO',
    'DATABASE_CPU_RATIO',
    'Database CPU time ratio monitoring (Oracle 23ai)',
    'DB_CPU_RATIO',
    0  -- DISABLED by default
);

-- CPU usage per transaction instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'CPU_USAGE_PER_TXN',
    'CPU_USAGE_PER_TRANSACTION',
    'CPU usage per transaction monitoring (Oracle 23ai)',
    'CPU_PER_TXN',
    0  -- DISABLED by default
);

-- Background CPU usage instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'BACKGROUND_CPU_USAGE',
    'BACKGROUND_CPU_USAGE',
    'Background CPU usage monitoring (Oracle 23ai)',
    'BG_CPU_USAGE',
    0  -- DISABLED by default
);

-- CPU time per user call instance
INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled
) VALUES (
    'CPU_TIME_PER_CALL',
    'CPU_TIME_PER_USER_CALL',
    'CPU time per user call monitoring (Oracle 23ai)',
    'CPU_PER_CALL',
    0  -- DISABLED by default
);



-- 🔥 INSERTAR NUEVOS TIPOS DE VALIDACIÓN DE MEMORIA
INSERT INTO db_validation_types (
    validation_type_code, 
    description, 
    validation_procedure, 
    default_check_interval_minutes, 
    is_active, 
    created_at
) VALUES 
('PGA_MEMORY_USAGE', 'PGA Memory Usage Monitoring', 'validate_pga_memory_usage', 5, 1, SYSTIMESTAMP),
('UGA_MEMORY_USAGE', 'UGA Memory Usage Monitoring', 'validate_uga_memory_usage', 5, 1, SYSTIMESTAMP),
('MEMORY_SORTS_COUNT', 'Memory Sorts Count Monitoring', 'validate_memory_sorts_count', 10, 1, SYSTIMESTAMP),
('WORKAREA_MEMORY_ALLOCATED', 'Work Area Memory Allocated Monitoring', 'validate_workarea_memory_allocated', 10, 1, SYSTIMESTAMP);


INSERT INTO db_validation_instances (
    validation_type_code,
    instance_name,
    instance_description,
    target_identifier,
    is_enabled,
    last_check_time,
    last_check_status,
    last_check_value,
    consecutive_failures,
    created_at
) VALUES 
('PGA_MEMORY_USAGE', 'PGA_MEMORY_USAGE', 'PGA Memory Usage Monitor', 'PGA_MEM', 1, NULL, NULL, NULL, 0, SYSTIMESTAMP),
('UGA_MEMORY_USAGE', 'UGA_MEMORY_USAGE', 'UGA Memory Usage Monitor', 'UGA_MEM', 1, NULL, NULL, NULL, 0, SYSTIMESTAMP),
('MEMORY_SORTS_COUNT', 'MEMORY_SORTS_COUNT', 'Memory Sorts Count Monitor', 'MEM_SORTS', 1, NULL, NULL, NULL, 0, SYSTIMESTAMP),
('WORKAREA_MEMORY_ALLOCATED', 'WORKAREA_MEMORY_ALLOCATED', 'Work Area Memory Monitor', 'WORKAREA', 1, NULL, NULL, NULL, 0, SYSTIMESTAMP);


INSERT INTO db_validation_rules (
    validation_type_code,
    environment_name,
    warning_threshold,
    critical_threshold,
    threshold_unit,
    check_interval_minutes,
    is_enabled,
    created_at
) VALUES 
-- PGA Memory Usage Rules
('PGA_MEMORY_USAGE', 'TEST', 75, 90, 'percentage', 5, 1, SYSTIMESTAMP),
('PGA_MEMORY_USAGE', 'DEV', 80, 95, 'percentage', 10, 1, SYSTIMESTAMP),
('PGA_MEMORY_USAGE', 'PROD', 70, 85, 'percentage', 3, 1, SYSTIMESTAMP),

-- UGA Memory Usage Rules  
('UGA_MEMORY_USAGE', 'TEST', 75, 90, 'percentage', 5, 1, SYSTIMESTAMP),
('UGA_MEMORY_USAGE', 'DEV', 80, 95, 'percentage', 10, 1, SYSTIMESTAMP),
('UGA_MEMORY_USAGE', 'PROD', 70, 85, 'percentage', 3, 1, SYSTIMESTAMP),

-- Memory Sorts Count Rules
('MEMORY_SORTS_COUNT', 'TEST', 10000, 50000, 'count', 10, 1, SYSTIMESTAMP),
('MEMORY_SORTS_COUNT', 'DEV', 15000, 75000, 'count', 15, 1, SYSTIMESTAMP),
('MEMORY_SORTS_COUNT', 'PROD', 5000, 25000, 'count', 5, 1, SYSTIMESTAMP),

-- Work Area Memory Rules
('WORKAREA_MEMORY_ALLOCATED', 'TEST', 100000000, 500000000, 'bytes', 10, 1, SYSTIMESTAMP),
('WORKAREA_MEMORY_ALLOCATED', 'DEV', 200000000, 1000000000, 'bytes', 15, 1, SYSTIMESTAMP),
('WORKAREA_MEMORY_ALLOCATED', 'PROD', 50000000, 250000000, 'bytes', 5, 1, SYSTIMESTAMP);

COMMIT;


-- =============================================================================
-- Verification Queries for New Oracle 23ai Metrics
-- =============================================================================

PROMPT
PROMPT =============================================================================
PROMPT Verification - New Oracle 23ai CPU Validation Types
PROMPT =============================================================================
SELECT 
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    CASE WHEN is_active = 1 THEN 'ACTIVE' ELSE 'INACTIVE' END as status
FROM db_validation_types
WHERE validation_type_code IN ('DB_CPU_RATIO', 'CPU_USAGE_PER_TXN', 'BACKGROUND_CPU_USAGE', 'CPU_TIME_PER_CALL')
ORDER BY validation_type_code;

PROMPT
PROMPT =============================================================================
PROMPT Verification - Oracle 23ai CPU Validation Rules by Environment
PROMPT =============================================================================
SELECT 
    r.validation_type_code,
    r.environment_name,
    r.warning_threshold || ' ' || r.threshold_unit as warning_level,
    r.critical_threshold || ' ' || r.threshold_unit as critical_level,
    r.check_interval_minutes,
    CASE WHEN r.is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END as status
FROM db_validation_rules r
WHERE r.validation_type_code IN ('DB_CPU_RATIO', 'CPU_USAGE_PER_TXN', 'BACKGROUND_CPU_USAGE', 'CPU_TIME_PER_CALL')
ORDER BY r.validation_type_code, r.environment_name;

PROMPT
PROMPT =============================================================================
PROMPT Verification - Oracle 23ai CPU Validation Instances (ALL DISABLED by default)
PROMPT =============================================================================
SELECT 
    i.validation_type_code,
    i.instance_name,
    i.target_identifier,
    CASE WHEN i.is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END as status,
    TO_CHAR(i.created_at, 'YYYY-MM-DD HH24:MI:SS') as created
FROM db_validation_instances i
WHERE i.validation_type_code IN ('DB_CPU_RATIO', 'CPU_USAGE_PER_TXN', 'BACKGROUND_CPU_USAGE', 'CPU_TIME_PER_CALL')
ORDER BY i.validation_type_code, i.instance_name;

COMMIT;

PROMPT
PROMPT ✅ Oracle 23ai CPU metrics configuration inserted successfully! (ORDER FIXED)
PROMPT
PROMPT Insertion order was:
PROMPT 1. Validation Types (parent table)
PROMPT 2. Validation Rules (references types)
PROMPT 3. Validation Instances (references types)
PROMPT
PROMPT New CPU metrics added:
PROMPT - DB_CPU_RATIO: Database CPU time ratio monitoring
PROMPT - CPU_USAGE_PER_TXN: CPU usage per transaction monitoring  
PROMPT - BACKGROUND_CPU_USAGE: Background CPU usage monitoring
PROMPT - CPU_TIME_PER_CALL: CPU time per user call monitoring

-- =============================================================================
-- Verification Queries
-- =============================================================================

PROMPT
PROMPT =============================================================================
PROMPT Verification - Validation Types
PROMPT =============================================================================
SELECT 
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    CASE WHEN is_active = 1 THEN 'ACTIVE' ELSE 'INACTIVE' END as status
FROM db_validation_types
ORDER BY validation_type_code;

PROMPT
PROMPT =============================================================================
PROMPT Verification - Validation Rules by Environment
PROMPT =============================================================================
SELECT 
    r.validation_type_code,
    r.environment_name,
    r.warning_threshold || ' ' || r.threshold_unit as warning_level,
    r.critical_threshold || ' ' || r.threshold_unit as critical_level,
    r.check_interval_minutes,
    CASE WHEN r.is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END as status
FROM db_validation_rules r
ORDER BY r.validation_type_code, r.environment_name;

PROMPT
PROMPT =============================================================================
PROMPT Verification - Validation Instances (ALL DISABLED by default)
PROMPT =============================================================================
SELECT 
    i.validation_type_code,
    i.instance_name,
    i.target_identifier,
    CASE WHEN i.is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END as status,
    TO_CHAR(i.created_at, 'YYYY-MM-DD HH24:MI:SS') as created
FROM db_validation_instances i
ORDER BY i.validation_type_code, i.instance_name;

PROMPT
PROMPT =============================================================================
PROMPT Summary by Validation Type
PROMPT =============================================================================
SELECT 
    t.validation_type_code,
    t.description,
    COUNT(i.instance_id) as total_instances,
    SUM(CASE WHEN i.is_enabled = 1 THEN 1 ELSE 0 END) as enabled_instances,
    COUNT(DISTINCT r.environment_name) as environments_configured
FROM db_validation_types t
LEFT JOIN db_validation_instances i ON t.validation_type_code = i.validation_type_code
LEFT JOIN db_validation_rules r ON t.validation_type_code = r.validation_type_code
WHERE t.is_active = 1
GROUP BY t.validation_type_code, t.description
ORDER BY t.validation_type_code;

COMMIT;

PROMPT
PROMPT ✅ PLT_DB_MONITOR configuration data inserted successfully!
PROMPT
PROMPT Next steps:
PROMPT 1. Enable specific validation instances you want to monitor
PROMPT 2. Adjust thresholds for your environment
PROMPT 3. Create the PLT_DB_MONITOR package
PROMPT 4. Set up the scheduled job
PROMPT
PROMPT To enable a validation instance:
PROMPT UPDATE db_validation_instances 
PROMPT SET is_enabled = 1 
PROMPT WHERE instance_name = 'SYSTEM_TABLESPACE';
PROMPT