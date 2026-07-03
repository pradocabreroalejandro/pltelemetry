CREATE OR REPLACE PACKAGE BODY PLT_ACTIVATION_MANAGER AS

    -- In-memory cache (Session Level)
    TYPE t_decision_cache IS TABLE OF BOOLEAN INDEX BY VARCHAR2(200);
    g_cache t_decision_cache;

    FUNCTION check_db_rules(p_obj VARCHAR2) RETURN BOOLEAN IS
        l_enabled VARCHAR2(1);
        l_rate    NUMBER;
    BEGIN
        -- Look for specific rule first, then wildcard '*'
        BEGIN
            SELECT is_enabled, sample_rate
            INTO l_enabled, l_rate
            FROM (
                SELECT is_enabled, sample_rate, 1 as priority
                FROM plt_activation_rules
                WHERE p_obj LIKE REPLACE(object_pattern, '*', '%')
                UNION ALL
                SELECT is_enabled, sample_rate, 2 as priority
                FROM plt_activation_rules
                WHERE object_pattern = '*'
                ORDER BY priority ASC
            )
            WHERE ROWNUM = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RETURN FALSE; -- If no rules, don't trace
        END;

        IF l_enabled = 'N' THEN RETURN FALSE; END IF;

        -- Sampling: Flip a coin
        -- If rate is 0.1 (10%), and random gives 0.05 -> TRUE
        IF DBMS_RANDOM.VALUE(0, 1) <= l_rate THEN
            RETURN TRUE;
        ELSE
            RETURN FALSE;
        END IF;
    END check_db_rules;

    FUNCTION should_trace(p_object_name VARCHAR2) RETURN BOOLEAN IS
        l_norm_name VARCHAR2(200) := UPPER(TRIM(p_object_name));
        l_result    BOOLEAN;
    BEGIN
        -- 1. Check Cache
        IF g_cache.EXISTS(l_norm_name) THEN
            RETURN g_cache(l_norm_name);
        END IF;

        -- 2. If not found, ask the DB
        l_result := check_db_rules(l_norm_name);

        -- 3. Save decision in Cache
        g_cache(l_norm_name) := l_result;
        
        RETURN l_result;
    EXCEPTION
        WHEN OTHERS THEN RETURN FALSE; -- Fail safe (Fail-close)
    END should_trace;

    PROCEDURE flush_cache IS
    BEGIN
        g_cache.DELETE;
    END flush_cache;

END PLT_ACTIVATION_MANAGER;
/
