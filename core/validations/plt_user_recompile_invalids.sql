-- =====================================================
-- PLTelemetry - Recompile Invalid Packages
-- Automatically recompiles all invalid packages
-- Execute as PLTELEMETRY user
-- =====================================================

SET SERVEROUTPUT ON

PROMPT Recompiling invalid PLTelemetry packages...

-- =====================================================
-- STEP 1: Show current invalid objects
-- =====================================================

PROMPT === Current Invalid Objects ===

SELECT 
    object_type,
    object_name,
    status,
    last_ddl_time
FROM user_objects 
WHERE status = 'INVALID'
ORDER BY object_type, object_name;

-- =====================================================
-- STEP 2: Recompile all invalid packages
-- =====================================================

DECLARE
    l_sql VARCHAR2(1000);
    l_count_before NUMBER := 0;
    l_count_after NUMBER := 0;
    l_recompiled NUMBER := 0;
    l_failed NUMBER := 0;
    l_error_msg VARCHAR2(4000);
BEGIN
    -- Count invalid objects before
    SELECT COUNT(*) INTO l_count_before 
    FROM user_objects 
    WHERE status = 'INVALID';
    
    DBMS_OUTPUT.PUT_LINE('=== Starting Recompilation ===');
    DBMS_OUTPUT.PUT_LINE('Invalid objects before: ' || l_count_before);
    DBMS_OUTPUT.PUT_LINE(' ');
    
    -- Recompile package specifications first
    FOR rec IN (
        SELECT object_name 
        FROM user_objects 
        WHERE object_type = 'PACKAGE' 
        AND status = 'INVALID'
        ORDER BY object_name
    ) LOOP
        BEGIN
            l_sql := 'ALTER PACKAGE ' || rec.object_name || ' COMPILE SPECIFICATION';
            EXECUTE IMMEDIATE l_sql;
            DBMS_OUTPUT.PUT_LINE('✓ Recompiled PACKAGE SPEC: ' || rec.object_name);
            l_recompiled := l_recompiled + 1;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(SQLERRM, 1, 200);
                DBMS_OUTPUT.PUT_LINE('✗ Failed PACKAGE SPEC: ' || rec.object_name || ' - ' || l_error_msg);
                l_failed := l_failed + 1;
        END;
    END LOOP;
    
    -- Recompile package bodies second
    FOR rec IN (
        SELECT object_name 
        FROM user_objects 
        WHERE object_type = 'PACKAGE BODY' 
        AND status = 'INVALID'
        ORDER BY object_name
    ) LOOP
        BEGIN
            l_sql := 'ALTER PACKAGE ' || rec.object_name || ' COMPILE BODY';
            EXECUTE IMMEDIATE l_sql;
            DBMS_OUTPUT.PUT_LINE('✓ Recompiled PACKAGE BODY: ' || rec.object_name);
            l_recompiled := l_recompiled + 1;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(SQLERRM, 1, 200);
                DBMS_OUTPUT.PUT_LINE('✗ Failed PACKAGE BODY: ' || rec.object_name || ' - ' || l_error_msg);
                l_failed := l_failed + 1;
        END;
    END LOOP;
    
    -- Recompile functions
    FOR rec IN (
        SELECT object_name 
        FROM user_objects 
        WHERE object_type = 'FUNCTION' 
        AND status = 'INVALID'
        ORDER BY object_name
    ) LOOP
        BEGIN
            l_sql := 'ALTER FUNCTION ' || rec.object_name || ' COMPILE';
            EXECUTE IMMEDIATE l_sql;
            DBMS_OUTPUT.PUT_LINE('✓ Recompiled FUNCTION: ' || rec.object_name);
            l_recompiled := l_recompiled + 1;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(SQLERRM, 1, 200);
                DBMS_OUTPUT.PUT_LINE('✗ Failed FUNCTION: ' || rec.object_name || ' - ' || l_error_msg);
                l_failed := l_failed + 1;
        END;
    END LOOP;
    
    -- Recompile procedures
    FOR rec IN (
        SELECT object_name 
        FROM user_objects 
        WHERE object_type = 'PROCEDURE' 
        AND status = 'INVALID'
        ORDER BY object_name
    ) LOOP
        BEGIN
            l_sql := 'ALTER PROCEDURE ' || rec.object_name || ' COMPILE';
            EXECUTE IMMEDIATE l_sql;
            DBMS_OUTPUT.PUT_LINE('✓ Recompiled PROCEDURE: ' || rec.object_name);
            l_recompiled := l_recompiled + 1;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(SQLERRM, 1, 200);
                DBMS_OUTPUT.PUT_LINE('✗ Failed PROCEDURE: ' || rec.object_name || ' - ' || l_error_msg);
                l_failed := l_failed + 1;
        END;
    END LOOP;
    
    -- Recompile types
    FOR rec IN (
        SELECT object_name 
        FROM user_objects 
        WHERE object_type = 'TYPE' 
        AND status = 'INVALID'
        ORDER BY object_name
    ) LOOP
        BEGIN
            l_sql := 'ALTER TYPE ' || rec.object_name || ' COMPILE';
            EXECUTE IMMEDIATE l_sql;
            DBMS_OUTPUT.PUT_LINE('✓ Recompiled TYPE: ' || rec.object_name);
            l_recompiled := l_recompiled + 1;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(SQLERRM, 1, 200);
                DBMS_OUTPUT.PUT_LINE('✗ Failed TYPE: ' || rec.object_name || ' - ' || l_error_msg);
                l_failed := l_failed + 1;
        END;
    END LOOP;
    
    -- Recompile triggers
    FOR rec IN (
        SELECT object_name 
        FROM user_objects 
        WHERE object_type = 'TRIGGER' 
        AND status = 'INVALID'
        ORDER BY object_name
    ) LOOP
        BEGIN
            l_sql := 'ALTER TRIGGER ' || rec.object_name || ' COMPILE';
            EXECUTE IMMEDIATE l_sql;
            DBMS_OUTPUT.PUT_LINE('✓ Recompiled TRIGGER: ' || rec.object_name);
            l_recompiled := l_recompiled + 1;
        EXCEPTION
            WHEN OTHERS THEN
                l_error_msg := SUBSTR(SQLERRM, 1, 200);
                DBMS_OUTPUT.PUT_LINE('✗ Failed TRIGGER: ' || rec.object_name || ' - ' || l_error_msg);
                l_failed := l_failed + 1;
        END;
    END LOOP;
    
    -- Count invalid objects after
    SELECT COUNT(*) INTO l_count_after 
    FROM user_objects 
    WHERE status = 'INVALID';
    
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('=== Recompilation Summary ===');
    DBMS_OUTPUT.PUT_LINE('Objects recompiled successfully: ' || l_recompiled);
    DBMS_OUTPUT.PUT_LINE('Objects failed to recompile: ' || l_failed);
    DBMS_OUTPUT.PUT_LINE('Invalid objects before: ' || l_count_before);
    DBMS_OUTPUT.PUT_LINE('Invalid objects after: ' || l_count_after);
    DBMS_OUTPUT.PUT_LINE('Objects fixed: ' || (l_count_before - l_count_after));
    
    IF l_count_after = 0 THEN
        DBMS_OUTPUT.PUT_LINE('🎉 All objects are now VALID!');
    ELSIF l_count_after < l_count_before THEN
        DBMS_OUTPUT.PUT_LINE('✓ Progress made, some objects still invalid');
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ No progress made, check compilation errors');
    END IF;
    
END;
/

-- =====================================================
-- STEP 3: Show remaining invalid objects (if any)
-- =====================================================

PROMPT
PROMPT === Remaining Invalid Objects (if any) ===

SELECT 
    object_type,
    object_name,
    status,
    last_ddl_time
FROM user_objects 
WHERE status = 'INVALID'
ORDER BY object_type, object_name;

-- =====================================================
-- STEP 4: Show compilation errors for invalid objects
-- =====================================================

PROMPT
PROMPT === Compilation Errors for Invalid Objects ===

SELECT 
    name,
    type,
    line,
    position,
    text
FROM user_errors 
WHERE name IN (
    SELECT object_name 
    FROM user_objects 
    WHERE status = 'INVALID'
)
ORDER BY name, type, line, position;

-- =====================================================
-- STEP 5: Alternative - Use DBMS_UTILITY (if needed)
-- =====================================================

PROMPT
PROMPT === Alternative: Schema-wide Recompilation ===
PROMPT If objects are still invalid, you can try:
PROMPT EXEC DBMS_UTILITY.COMPILE_SCHEMA(USER);
PROMPT
PROMPT Or for just invalid objects:
PROMPT EXEC DBMS_UTILITY.COMPILE_SCHEMA(USER, FALSE);

-- Quick one-liner for manual execution if needed
-- EXEC DBMS_UTILITY.COMPILE_SCHEMA(USER, FALSE);

PROMPT
PROMPT =====================================================
PROMPT PLTelemetry Package Recompilation Complete
PROMPT =====================================================
PROMPT  
PROMPT Next steps if objects are still invalid:
PROMPT 1. Check compilation errors above
PROMPT 2. Fix source code issues
PROMPT 3. Check dependencies between packages
PROMPT 4. Run: EXEC DBMS_UTILITY.COMPILE_SCHEMA(USER);
PROMPT 
PROMPT Current object status:

SELECT 
    object_type,
    status,
    COUNT(*) as count
FROM user_objects 
WHERE object_type IN ('PACKAGE', 'PACKAGE BODY', 'FUNCTION', 'PROCEDURE', 'TYPE', 'TRIGGER')
GROUP BY object_type, status
ORDER BY object_type, status;