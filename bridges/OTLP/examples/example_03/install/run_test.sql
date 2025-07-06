-- Como PLTELEMETRY
BEGIN
    -- Configurar telemetría
    PLT_DB_MONITOR.configure_telemetry();
    DBMS_OUTPUT.PUT_LINE('✅ Telemetry configured!');
    
    -- Ver qué ambiente detecta
    DBMS_OUTPUT.PUT_LINE('Environment: ' || PLT_DB_MONITOR.detect_environment());
END;
/

-- Ver qué validaciones están activas (debería haber algunas)
SELECT 
    instance_name,
    validation_type_code,
    target_identifier,
    is_enabled,
    last_check_time
FROM db_validation_instances 
WHERE is_enabled = 1;

select * from db_validation_instances where is_enabled = 1;

UPDATE db_validation_instances 
SET is_enabled = 1 
WHERE instance_name IN (
    'SYSTEM_TABLESPACE',
    'USERS_TABLESPACE', 
    'GLOBAL_ACTIVE_SESSIONS',
    'SGA_MEMORY_USAGE'
);

commit;

-- Ver cuáles están activas
SELECT instance_name, validation_type_code, target_identifier
FROM db_validation_instances 
WHERE is_enabled = 1;


BEGIN
    DBMS_OUTPUT.PUT_LINE('🚀 NOW we should see some action...');
    
    PLT_DB_MONITOR.perform_database_validations(p_force_all_checks => TRUE);
    
    DBMS_OUTPUT.PUT_LINE('🎉 Check Grafana now!');
END;
/

select * from db_validation_instances
order by INSTANCE_ID;

update db_validation_instances
set is_enabled = 1;

commit;

-- =============================================================================
-- DIAGNOSTIC QUERIES - Let's see what's wrong! 🔍
-- =============================================================================

PROMPT =============================================================================
PROMPT 1. Check if validation types were actually inserted
PROMPT =============================================================================
SELECT validation_type_code, description, is_active 
FROM db_validation_types 
WHERE validation_type_code IN ('DB_CPU_RATIO', 'CPU_USAGE_PER_TXN', 'BACKGROUND_CPU_USAGE', 'CPU_TIME_PER_CALL');

PROMPT =============================================================================
PROMPT 2. Check all constraints on db_validation_instances table
PROMPT =============================================================================
SELECT 
    constraint_name,
    constraint_type,
    status,
    r_constraint_name,
    delete_rule
FROM user_constraints 
WHERE table_name = 'DB_VALIDATION_INSTANCES'
ORDER BY constraint_type, constraint_name;

PROMPT =============================================================================
PROMPT 3. Check foreign key constraint details
PROMPT =============================================================================
SELECT 
    uc.constraint_name,
    uc.table_name,
    ucc.column_name,
    uc.r_constraint_name,
    r_uc.table_name as referenced_table,
    r_ucc.column_name as referenced_column
FROM user_constraints uc
JOIN user_cons_columns ucc ON uc.constraint_name = ucc.constraint_name
JOIN user_constraints r_uc ON uc.r_constraint_name = r_uc.constraint_name
JOIN user_cons_columns r_ucc ON r_uc.constraint_name = r_ucc.constraint_name
WHERE uc.table_name = 'DB_VALIDATION_INSTANCES'
  AND uc.constraint_type = 'R'
ORDER BY uc.constraint_name, ucc.position;

PROMPT =============================================================================
PROMPT 4. Check what validation_type_codes exist in the parent table
PROMPT =============================================================================
SELECT validation_type_code, is_active, created_at
FROM db_validation_types
ORDER BY validation_type_code;

PROMPT =============================================================================
PROMPT 5. Check if there are any existing instances with these names
PROMPT =============================================================================
SELECT instance_name, validation_type_code, is_enabled
FROM db_validation_instances
WHERE instance_name IN ('DATABASE_CPU_RATIO', 'CPU_USAGE_PER_TRANSACTION', 'BACKGROUND_CPU_USAGE', 'CPU_TIME_PER_USER_CALL')
   OR validation_type_code IN ('DB_CPU_RATIO', 'CPU_USAGE_PER_TXN', 'BACKGROUND_CPU_USAGE', 'CPU_TIME_PER_CALL');

PROMPT =============================================================================
PROMPT 6. Test one INSERT manually to see exact error
PROMPT =============================================================================
-- Let's try just ONE insert to see what happens:
BEGIN
    INSERT INTO db_validation_instances (
        validation_type_code,
        instance_name,
        instance_description,
        target_identifier,
        is_enabled
    ) VALUES (
        'DB_CPU_RATIO',
        'TEST_DATABASE_CPU_RATIO',
        'Test insert for diagnosis',
        'TEST_TARGET',
        0
    );
    
    DBMS_OUTPUT.PUT_LINE('✅ Test insert succeeded!');
    ROLLBACK; -- Don't keep the test record
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('❌ Error: ' || SQLCODE || ' - ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('❌ Stack: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
        ROLLBACK;
END;
/

PROMPT =============================================================================
PROMPT 7. Check table structure
PROMPT =============================================================================
DESCRIBE db_validation_instances;


-- =============================================================================
-- DIAGNOSTIC - Test Oracle 23ai Metric Queries Directly 🔍
-- =============================================================================

PROMPT =============================================================================
PROMPT 1. Check Oracle version
PROMPT =============================================================================
SELECT banner FROM v$version WHERE banner LIKE 'Oracle%';

PROMPT =============================================================================
PROMPT 2. Check what CPU metrics are actually available in v$metric
PROMPT =============================================================================
SELECT DISTINCT metric_name 
FROM v$metric 
WHERE UPPER(metric_name) LIKE '%CPU%'
ORDER BY metric_name;

PROMPT =============================================================================
PROMPT 3. Test each Oracle 23ai query individually
PROMPT =============================================================================

-- Test Database CPU Time Ratio query
PROMPT Testing Database CPU Time Ratio...
BEGIN
    DECLARE
        l_result NUMBER;
    BEGIN
        SELECT NVL(ROUND(AVG(value), 2), 0)
        INTO l_result
        FROM v$metric
        WHERE metric_name = 'Database CPU Time Ratio'
          AND ROWNUM <= 1;
        
        DBMS_OUTPUT.PUT_LINE('✅ Database CPU Time Ratio: ' || l_result);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            DBMS_OUTPUT.PUT_LINE('❌ Database CPU Time Ratio: Metric not found');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('❌ Database CPU Time Ratio Error: ' || SQLERRM);
    END;
END;
/

-- Test CPU Usage Per Txn query
PROMPT Testing CPU Usage Per Txn...
BEGIN
    DECLARE
        l_result NUMBER;
    BEGIN
        SELECT NVL(ROUND(AVG(value), 2), 0)
        INTO l_result
        FROM v$metric
        WHERE metric_name = 'CPU Usage Per Txn'
          AND ROWNUM <= 1;
        
        DBMS_OUTPUT.PUT_LINE('✅ CPU Usage Per Txn: ' || l_result);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            DBMS_OUTPUT.PUT_LINE('❌ CPU Usage Per Txn: Metric not found');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('❌ CPU Usage Per Txn Error: ' || SQLERRM);
    END;
END;
/

-- Test Background CPU Usage query
PROMPT Testing Background CPU Usage...
BEGIN
    DECLARE
        l_result NUMBER;
    BEGIN
        SELECT NVL(ROUND(AVG(value), 2), 0)
        INTO l_result
        FROM v$metric
        WHERE metric_name = 'Background CPU Usage Per Sec'
          AND ROWNUM <= 1;
        
        DBMS_OUTPUT.PUT_LINE('✅ Background CPU Usage Per Sec: ' || l_result);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            DBMS_OUTPUT.PUT_LINE('❌ Background CPU Usage Per Sec: Metric not found');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('❌ Background CPU Usage Per Sec Error: ' || SQLERRM);
    END;
END;
/

-- Test CPU Time Per User Call query
PROMPT Testing CPU Time Per User Call...
BEGIN
    DECLARE
        l_result NUMBER;
    BEGIN
        SELECT NVL(ROUND(AVG(value), 2), 0)
        INTO l_result
        FROM v$metric
        WHERE metric_name = 'CPU Time Per User Call'
          AND ROWNUM <= 1;
        
        DBMS_OUTPUT.PUT_LINE('✅ CPU Time Per User Call: ' || l_result);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            DBMS_OUTPUT.PUT_LINE('❌ CPU Time Per User Call: Metric not found');
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('❌ CPU Time Per User Call Error: ' || SQLERRM);
    END;
END;
/

PROMPT =============================================================================
PROMPT 4. Check all available metric names for reference
PROMPT =============================================================================
SELECT metric_name, metric_unit
FROM v$metric 
WHERE ROWNUM <= 50
ORDER BY metric_name;