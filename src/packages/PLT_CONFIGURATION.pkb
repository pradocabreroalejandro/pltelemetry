CREATE OR REPLACE PACKAGE BODY PLT_CONFIGURATION AS

    -- =========================================================================
    -- CORE: GET PARAM (RESULT CACHED)
    -- =========================================================================
    FUNCTION get_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_default IN VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2 
    RESULT_CACHE RELIES_ON (plt_sys_config) -- ¡La magia! Si la tabla cambia, la cache se limpia.
    IS
        l_val plt_sys_config.config_value%TYPE;
    BEGIN
        SELECT config_value
        INTO l_val
        FROM plt_sys_config
        WHERE config_group = p_group
          AND config_key   = p_key;
          
        RETURN l_val;
    EXCEPTION 
        WHEN NO_DATA_FOUND THEN
            RETURN p_default;
        WHEN OTHERS THEN
            -- Fail-safe: Si falla la BD, devolvemos default sin explotar
            RETURN p_default;
    END get_param;

    -- =========================================================================
    -- HELPERS DE TIPO
    -- =========================================================================
    
    FUNCTION get_bool_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_default IN BOOLEAN DEFAULT FALSE
    ) RETURN BOOLEAN IS
        l_val VARCHAR2(100);
    BEGIN
        l_val := get_param(p_group, p_key, NULL);
        
        IF l_val IS NULL THEN RETURN p_default; END IF;
        
        IF UPPER(l_val) IN ('TRUE', 'Y', 'YES', '1', 'ON') THEN
            RETURN TRUE;
        ELSE
            RETURN FALSE;
        END IF;
    END;

    FUNCTION get_num_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_default IN NUMBER DEFAULT 0
    ) RETURN NUMBER IS
        l_val VARCHAR2(4000);
    BEGIN
        l_val := get_param(p_group, p_key, NULL);
        IF l_val IS NULL THEN RETURN p_default; END IF;
        
        RETURN TO_NUMBER(l_val);
    EXCEPTION WHEN OTHERS THEN
        RETURN p_default; -- Si no es número, devolvemos default
    END;

    -- =========================================================================
    -- SETTER (ADMIN)
    -- =========================================================================
    
    PROCEDURE set_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_value IN VARCHAR2,
        p_desc  IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION; -- Para no afectar la txn principal
    BEGIN
        MERGE INTO plt_sys_config t
        USING (SELECT p_group as g, p_key as k FROM dual) s
        ON (t.config_group = s.g AND t.config_key = s.k)
        WHEN MATCHED THEN
            UPDATE SET 
                config_value = p_value,
                updated_at   = SYSTIMESTAMP,
                updated_by   = USER,
                description  = NVL(p_desc, description) -- Actualiza desc solo si se pasa
        WHEN NOT MATCHED THEN
            INSERT (config_group, config_key, config_value, description)
            VALUES (p_group, p_key, p_value, NVL(p_desc, 'Auto-generated param'));
            
        COMMIT;
    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20005, 'Error actualizando config: ' || 
            DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    END set_param;

END PLT_CONFIGURATION;
/