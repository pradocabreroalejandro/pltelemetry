CREATE OR REPLACE PACKAGE BODY PLT_ACTIVATION_MANAGER
AS
    /**
     * PLT_ACTIVATION_MANAGER - Granular Telemetry Activation Control
     * Version: 1.0.0 - Wildcard Inheritance Edition
     * 
     * Implements sophisticated pattern matching with inheritance rules:
     * - Exact match beats wildcard: PKG.PROC > PKG.*
     * - More specific wildcards beat general: PKG.* > *.*
     * - Sampling decisions are made per call using DBMS_RANDOM
     * - All activation changes are audited and sent directly to Loki
     */

    --------------------------------------------------------------------------
    -- PRIVATE UTILITIES
    --------------------------------------------------------------------------
    
    /**
     * Centralized error logging - never fails the main operation
     */
    PROCEDURE log_error_internal(
        p_operation VARCHAR2,
        p_error_message VARCHAR2,
        p_context VARCHAR2 DEFAULT NULL
    )
    IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_error_msg VARCHAR2(4000);
    BEGIN
        l_error_msg := SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 4000);
        
        INSERT INTO plt_telemetry_errors (
            error_time,
            error_message,
            error_stack,
            module_name
        ) VALUES (
            SYSTIMESTAMP,
            SUBSTR('ACTIVATION_MANAGER [' || p_operation || ']: ' || p_error_message, 1, 4000),
            l_error_msg,
            'PLT_ACTIVATION_MANAGER'
        );
        
        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            NULL; -- Never let error logging break the activation manager
    END log_error_internal;

    /**
     * Normalize and validate input strings
     */
    FUNCTION normalize_string(
        p_input      VARCHAR2,
        p_max_length NUMBER DEFAULT 4000,
        p_allow_null BOOLEAN DEFAULT TRUE
    ) RETURN VARCHAR2
    IS
        l_result VARCHAR2(32767);
    BEGIN
        IF p_input IS NULL THEN
            RETURN CASE WHEN p_allow_null THEN NULL ELSE '' END;
        END IF;
        
        l_result := UPPER(TRIM(p_input)); -- Always uppercase for consistency
        l_result := REPLACE(l_result, CHR(0), ''); -- Remove null terminators
        
        IF LENGTH(l_result) > p_max_length THEN
            l_result := SUBSTR(l_result, 1, p_max_length - 3) || '...';
        END IF;
        
        RETURN l_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN SUBSTR(UPPER(TRIM(NVL(p_input, ''))), 1, p_max_length);
    END normalize_string;

    --------------------------------------------------------------------------
    -- PATTERN MATCHING AND INHERITANCE - THE BEEF 🥩
    --------------------------------------------------------------------------
    
    /**
     * Advanced pattern matching with Oracle LIKE enhancement
     * Supports: *, PKG.*, *.PROC, PKG.PROC
     */
    FUNCTION matches_pattern(
        p_object_name   VARCHAR2,
        p_pattern       VARCHAR2
    ) RETURN BOOLEAN
    IS
        l_object_name VARCHAR2(200);
        l_pattern VARCHAR2(200);
        l_like_pattern VARCHAR2(200);
    BEGIN
        -- Normalize inputs
        l_object_name := normalize_string(p_object_name, 200, FALSE);
        l_pattern := normalize_string(p_pattern, 200, FALSE);
        
        IF l_object_name IS NULL OR l_pattern IS NULL THEN
            RETURN FALSE;
        END IF;
        
        -- Exact match first (fastest)
        IF l_object_name = l_pattern THEN
            RETURN TRUE;
        END IF;
        
        -- Convert wildcard pattern to SQL LIKE pattern
        l_like_pattern := REPLACE(l_pattern, '*', '%');
        
        -- Use Oracle LIKE for pattern matching
        RETURN l_object_name LIKE l_like_pattern;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('matches_pattern', 
                'Pattern matching failed for: ' || p_object_name || ' against ' || p_pattern);
            RETURN FALSE;
    END matches_pattern;

    /**
     * Calculate pattern specificity for inheritance rules
     * More specific patterns get higher scores and win conflicts
     */
    FUNCTION calculate_pattern_specificity(p_pattern VARCHAR2) RETURN NUMBER
    IS
        l_pattern VARCHAR2(200);
        l_specificity NUMBER := 0;
        l_parts NUMBER := 0;
        l_wildcards NUMBER := 0;
    BEGIN
        l_pattern := normalize_string(p_pattern, 200, FALSE);
        
        IF l_pattern IS NULL THEN
            RETURN 0;
        END IF;
        
        -- Count parts (separated by dots) - SAFE way
        l_parts := LENGTH(l_pattern) - LENGTH(REPLACE(l_pattern, '.', ''));
        
        -- Count wildcards - SAFE way
        l_wildcards := LENGTH(l_pattern) - LENGTH(REPLACE(l_pattern, '*', ''));
        
        -- Calculate specificity score
        l_specificity := (NVL(l_parts, 0) * 100) - (NVL(l_wildcards, 0) * 50);
        
        -- Bonus for exact matches (no wildcards)
        IF NVL(l_wildcards, 0) = 0 THEN
            l_specificity := l_specificity + 1000;
        END IF;
        
        -- Bonus for longer patterns
        l_specificity := l_specificity + NVL(LENGTH(l_pattern), 0);
        
        RETURN NVL(l_specificity, 0);
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN 0;
    END calculate_pattern_specificity;

    /**
     * The crown jewel - finds the best matching activation using inheritance
     * Implements: Exact > PKG.PROC > PKG.* > *
     */
    FUNCTION find_best_activation_match(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2
    ) RETURN PLT_TELEMETRY_ACTIVATION%ROWTYPE
    IS
        l_result PLT_TELEMETRY_ACTIVATION%ROWTYPE;
        l_all_fallback PLT_TELEMETRY_ACTIVATION%ROWTYPE;
        l_object_name VARCHAR2(200);
        l_telemetry_type VARCHAR2(20);
        l_tenant_id VARCHAR2(100);
        l_best_specificity NUMBER := -1;
        l_current_specificity NUMBER;
        l_found_match BOOLEAN := FALSE;
        l_found_all_fallback BOOLEAN := FALSE;
        l_cursor_count NUMBER := 0;
        l_all_cursor_count NUMBER := 0;
        
        -- First cursor: Specific tenant matches
        CURSOR c_candidates IS
            SELECT *
            FROM PLT_TELEMETRY_ACTIVATION
            WHERE telemetry_type = l_telemetry_type
            AND tenant_id = l_tenant_id
            AND enabled = 'Y'
            AND (enabled_time_to IS NULL OR enabled_time_to > SYSTIMESTAMP)
            AND SYSTIMESTAMP BETWEEN enabled_time_from AND NVL(enabled_time_to, SYSTIMESTAMP + 1)
            ORDER BY LENGTH(object_name) DESC, object_name;
            
        -- Second cursor: ALL/ALL fallback
        CURSOR c_all_fallback IS
            SELECT *
            FROM PLT_TELEMETRY_ACTIVATION
            WHERE telemetry_type = l_telemetry_type
            AND tenant_id = 'ALL'
            AND enabled = 'Y'
            AND (enabled_time_to IS NULL OR enabled_time_to > SYSTIMESTAMP)
            AND SYSTIMESTAMP BETWEEN enabled_time_from AND NVL(enabled_time_to, SYSTIMESTAMP + 1)
            ORDER BY LENGTH(object_name) DESC, object_name;
            
    BEGIN
        -- Normalize inputs
        l_object_name := normalize_string(p_object_name, 200, FALSE);
        l_telemetry_type := normalize_string(p_telemetry_type, 20, FALSE);
        l_tenant_id := normalize_string(p_tenant_id, 100, FALSE);

        -- Validate inputs
        IF l_object_name IS NULL OR l_telemetry_type IS NULL OR 
        l_tenant_id IS NULL THEN
            RETURN l_result; -- Return empty record
        END IF;
        
        -- STEP 1: Look for specific tenant matches first
        FOR rec IN c_candidates LOOP
            l_cursor_count := l_cursor_count + 1;
                
            IF matches_pattern(l_object_name, rec.object_name) THEN
                l_current_specificity := calculate_pattern_specificity(rec.object_name);
                    
                -- This pattern is more specific than previous matches
                IF l_current_specificity > l_best_specificity THEN
                    l_result := rec;
                    l_best_specificity := l_current_specificity;
                    l_found_match := TRUE;
                END IF;
            END IF;
        END LOOP;
        
        -- STEP 2: If no specific match found, look for ALL/ALL fallback
        IF NOT l_found_match THEN
            FOR rec IN c_all_fallback LOOP
                l_all_cursor_count := l_all_cursor_count + 1;
                    
                IF matches_pattern(l_object_name, rec.object_name) THEN
                    l_current_specificity := calculate_pattern_specificity(rec.object_name);
                        
                    -- This pattern is more specific than previous ALL matches
                    IF l_current_specificity > l_best_specificity THEN
                        l_all_fallback := rec;
                        l_best_specificity := l_current_specificity;
                        l_found_all_fallback := TRUE;
                    END IF;
                END IF;
            END LOOP;
            
            -- Use the ALL/ALL fallback if found
            IF l_found_all_fallback THEN
                l_result := l_all_fallback;
                l_found_match := TRUE;
            END IF;
        END IF;

        RETURN l_result;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- No match found, return empty record
            l_result.activation_id := NULL;
            l_result.object_name := NULL;
            l_result.telemetry_type := l_telemetry_type;
            l_result.tenant_id := l_tenant_id;
            l_result.enabled := 'N';
            l_result.sampling_rate := 0.0;
            l_result.log_level := NULL;
            RETURN l_result;
        WHEN OTHERS THEN
            log_error_internal('find_best_activation_match', 
                SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RETURN l_result; -- Return empty record
            
    END find_best_activation_match;

    --------------------------------------------------------------------------
    -- CORE ACTIVATION QUERIES - Used by PLTelemetry
    --------------------------------------------------------------------------
    
    /**
     * Universal activation checker with sampling decision
     * This is THE function that PLTelemetry core will call
     */
    FUNCTION should_generate_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_log_level         VARCHAR2 DEFAULT NULL
    ) RETURN BOOLEAN
    IS
        l_activation PLT_TELEMETRY_ACTIVATION%ROWTYPE;
        l_sampling_rate NUMBER;
        l_random_value NUMBER;
        l_log_level_ok BOOLEAN := TRUE;
        l_log_level_priority_input NUMBER;
        l_log_level_priority_config NUMBER;
    BEGIN
        -- Find matching activation rule
        l_activation := find_best_activation_match(
            p_object_name, p_telemetry_type, p_tenant_id
        );

        -- No activation found = disabled
        IF l_activation.activation_id IS NULL THEN
            RETURN FALSE;
        END IF;

        -- Check log level if this is a LOG telemetry
        IF p_telemetry_type = 'LOG' AND p_log_level IS NOT NULL THEN
            l_log_level_priority_input := get_log_level_priority(p_log_level);
            l_log_level_priority_config := get_log_level_priority(l_activation.log_level);
        
            l_log_level_ok := l_log_level_priority_input >= l_log_level_priority_config;

            IF NOT l_log_level_ok THEN
                RETURN FALSE;
            END IF;
        END IF;

        -- Apply sampling rate
        l_sampling_rate := NVL(l_activation.sampling_rate, 1.0);
        
        -- Always generate if sampling rate is 1.0 (100%)
        IF l_sampling_rate >= 1.0 THEN
            RETURN TRUE;
        END IF;
        
        -- Never generate if sampling rate is 0.0 (0%)
        IF l_sampling_rate <= 0.0 THEN
            RETURN FALSE;
        END IF;
        
        -- Probabilistic sampling
        l_random_value := DBMS_RANDOM.VALUE(0, 1);

        RETURN l_random_value <= l_sampling_rate;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('should_generate_telemetry', 
                'Activation check failed for: ' || p_object_name || 
                ' - Error: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RETURN FALSE; -- Safe default: disabled on error
    END should_generate_telemetry;

    /**
     * Check if tracing is enabled for specific object
     */
    FUNCTION is_trace_enabled(
        p_object_name   VARCHAR2,
        p_tenant_id     VARCHAR2
    ) RETURN BOOLEAN
    IS
        l_activation PLT_TELEMETRY_ACTIVATION%ROWTYPE;
    BEGIN
        l_activation := find_best_activation_match(
            p_object_name, C_TYPE_TRACE, p_tenant_id
        );
        
        RETURN l_activation.activation_id IS NOT NULL;
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END is_trace_enabled;

    /**
     * Check if logging is enabled for specific object and level
     */
    FUNCTION is_log_enabled(
        p_object_name   VARCHAR2,
        p_tenant_id     VARCHAR2,
        p_log_level     VARCHAR2
    ) RETURN BOOLEAN
    IS
        l_activation PLT_TELEMETRY_ACTIVATION%ROWTYPE;
    BEGIN
        l_activation := find_best_activation_match(
            p_object_name, C_TYPE_LOG, p_tenant_id
        );
        
        IF l_activation.activation_id IS NULL THEN
            RETURN FALSE;
        END IF;
        
        -- Check log level
        RETURN get_log_level_priority(p_log_level) >= 
               get_log_level_priority(l_activation.log_level);
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END is_log_enabled;

    /**
     * Check if metrics are enabled for specific object
     */
    FUNCTION is_metric_enabled(
        p_object_name   VARCHAR2,
        p_tenant_id     VARCHAR2
    ) RETURN BOOLEAN
    IS
        l_activation PLT_TELEMETRY_ACTIVATION%ROWTYPE;
    BEGIN
        l_activation := find_best_activation_match(
            p_object_name, C_TYPE_METRIC, p_tenant_id
        );
        
        RETURN l_activation.activation_id IS NOT NULL;
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END is_metric_enabled;

    /**
     * Get sampling rate for specific object and telemetry type
     */
    FUNCTION get_sampling_rate(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2
    ) RETURN NUMBER
    IS
        l_activation PLT_TELEMETRY_ACTIVATION%ROWTYPE;
    BEGIN
        l_activation := find_best_activation_match(
            p_object_name, p_telemetry_type, p_tenant_id
        );
        
        IF l_activation.activation_id IS NULL THEN
            RETURN 0.0; -- Disabled
        END IF;
        
        RETURN NVL(l_activation.sampling_rate, 1.0);
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN 0.0;
    END get_sampling_rate;

    --------------------------------------------------------------------------
    -- ACTIVATION MANAGEMENT - OVERLOADED PROCEDURES
    --------------------------------------------------------------------------
    
    /**
     * Core enable procedure - all others delegate to this one
     */
    PROCEDURE enable_telemetry_core(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_sampling_rate     NUMBER,
        p_log_level         VARCHAR2,
        p_enabled_from      TIMESTAMP,
        p_enabled_to        TIMESTAMP
    )
    IS
        l_object_name VARCHAR2(200);
        l_telemetry_type VARCHAR2(20);
        l_tenant_id VARCHAR2(100);
        l_log_level VARCHAR2(10);
    BEGIN
        -- Normalize and validate inputs
        l_object_name := normalize_string(p_object_name, 200, FALSE);
        l_telemetry_type := normalize_string(p_telemetry_type, 20, FALSE);
        l_tenant_id := normalize_string(p_tenant_id, 100, FALSE);
        l_log_level := normalize_string(p_log_level, 10, TRUE);
        
        -- Validation
        IF l_object_name IS NULL OR NOT is_valid_object_name(l_object_name) THEN
            RAISE_APPLICATION_ERROR(-20001, 'Invalid object name: ' || p_object_name);
        END IF;
        
        IF NOT is_valid_telemetry_type(l_telemetry_type) THEN
            RAISE_APPLICATION_ERROR(-20002, 'Invalid telemetry type: ' || p_telemetry_type);
        END IF;
        
        IF p_sampling_rate < 0.0 OR p_sampling_rate > 1.0 THEN
            RAISE_APPLICATION_ERROR(-20003, 'Sampling rate must be between 0.0 and 1.0');
        END IF;
        
        IF p_enabled_to IS NOT NULL AND p_enabled_to <= p_enabled_from THEN
            RAISE_APPLICATION_ERROR(-20004, 'End time must be after start time');
        END IF;
        
        -- For LOG telemetry, ensure log level is valid
        IF l_telemetry_type = C_TYPE_LOG THEN
            IF l_log_level IS NULL THEN
                l_log_level := C_LEVEL_INFO; -- Default
            ELSIF get_log_level_priority(l_log_level) = 0 THEN
                RAISE_APPLICATION_ERROR(-20005, 'Invalid log level: ' || p_log_level);
            END IF;
        ELSE
            l_log_level := NULL; -- Clear for non-LOG types
        END IF;
        
        -- Insert or update activation record
        MERGE INTO PLT_TELEMETRY_ACTIVATION ta
        USING (
            SELECT l_telemetry_type as telemetry_type,
                   l_object_name as object_name,
                   l_tenant_id as tenant_id
            FROM dual
        ) src
        ON (ta.telemetry_type = src.telemetry_type 
            AND ta.object_name = src.object_name
            AND ta.tenant_id = src.tenant_id)
        WHEN MATCHED THEN
            UPDATE SET
                enabled = 'Y',
                enabled_time_from = p_enabled_from,
                enabled_time_to = p_enabled_to,
                sampling_rate = p_sampling_rate,
                log_level = l_log_level
        WHEN NOT MATCHED THEN
            INSERT (
                telemetry_type,
                object_name,
                tenant_id,
                enabled,
                enabled_time_from,
                enabled_time_to,
                sampling_rate,
                log_level
            ) VALUES (
                l_telemetry_type,
                l_object_name,
                l_tenant_id,
                'Y',
                p_enabled_from,
                p_enabled_to,
                p_sampling_rate,
                l_log_level
            );
            
        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('enable_telemetry_core', 
                'Failed to enable telemetry: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END enable_telemetry_core;

    /**
     * Overload 1: Indefinite duration
     */
    PROCEDURE enable_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_sampling_rate     NUMBER DEFAULT 1.0,
        p_log_level         VARCHAR2 DEFAULT 'INFO',
        p_enabled_from      TIMESTAMP DEFAULT SYSTIMESTAMP
    )
    IS
    BEGIN
        enable_telemetry_core(
            p_object_name, p_telemetry_type, p_tenant_id, 
            p_sampling_rate, p_log_level, p_enabled_from, NULL
        );
    END enable_telemetry;

    /**
     * Overload 2: Duration in minutes
     */
    PROCEDURE enable_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_sampling_rate     NUMBER DEFAULT 1.0,
        p_log_level         VARCHAR2 DEFAULT 'INFO',
        p_enabled_from      TIMESTAMP DEFAULT SYSTIMESTAMP,
        p_duration_minutes  NUMBER
    )
    IS
        l_enabled_to TIMESTAMP;
    BEGIN
        IF p_duration_minutes IS NULL OR p_duration_minutes <= 0 THEN
            RAISE_APPLICATION_ERROR(-20006, 'Duration must be positive number of minutes');
        END IF;
        
        l_enabled_to := p_enabled_from + (p_duration_minutes / 1440); -- Convert minutes to days
        
        enable_telemetry_core(
            p_object_name, p_telemetry_type, p_tenant_id,
            p_sampling_rate, p_log_level, p_enabled_from, l_enabled_to
        );
    END enable_telemetry;

    /**
     * Overload 3: Explicit end time
     */
    PROCEDURE enable_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_sampling_rate     NUMBER DEFAULT 1.0,
        p_log_level         VARCHAR2 DEFAULT 'INFO',
        p_enabled_from      TIMESTAMP DEFAULT SYSTIMESTAMP,
        p_enabled_to        TIMESTAMP
    )
    IS
    BEGIN
        enable_telemetry_core(
            p_object_name, p_telemetry_type, p_tenant_id, 
            p_sampling_rate, p_log_level, p_enabled_from, p_enabled_to
        );
    END enable_telemetry;

    /**
     * Disable telemetry for specific object pattern
     */
    PROCEDURE disable_telemetry(
        p_object_name       VARCHAR2,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2
    )
    IS
        l_rows_updated NUMBER;
        l_telemetry_type VARCHAR2(20);
        l_object_name VARCHAR2(200);
        l_tenant_id VARCHAR2(100);  
    BEGIN

        l_telemetry_type := normalize_string(p_telemetry_type, 20, FALSE);
        l_object_name := normalize_string(p_object_name, 200, FALSE);
        l_tenant_id := normalize_string(p_tenant_id, 100, FALSE);

        UPDATE PLT_TELEMETRY_ACTIVATION
        SET enabled = 'N'
        WHERE telemetry_type = l_telemetry_type
          AND object_name = l_object_name
          AND tenant_id = l_tenant_id
          AND enabled = 'Y';
          
        l_rows_updated := SQL%ROWCOUNT;
        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('disable_telemetry', 
                'Failed to disable telemetry: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END disable_telemetry;

    --------------------------------------------------------------------------
    -- BULK OPERATIONS
    --------------------------------------------------------------------------
    
    /**
     * Enable telemetry for multiple objects at once
     */
    PROCEDURE enable_telemetry_bulk(
        p_object_patterns   SYS.ODCIVARCHAR2LIST,
        p_telemetry_type    VARCHAR2,
        p_tenant_id         VARCHAR2,
        p_sampling_rate     NUMBER DEFAULT 1.0,
        p_duration_minutes  NUMBER DEFAULT NULL
    )
    IS
        l_enabled_to TIMESTAMP;
        l_success_count NUMBER := 0;
        l_error_count NUMBER := 0;
    BEGIN
        -- Calculate end time if duration provided
        IF p_duration_minutes IS NOT NULL THEN
            l_enabled_to := SYSTIMESTAMP + (p_duration_minutes / 1440);
        END IF;
        
        -- Process each pattern
        FOR i IN 1..p_object_patterns.COUNT LOOP
            BEGIN
                enable_telemetry_core(
                    p_object_patterns(i), p_telemetry_type, p_tenant_id,
                    p_sampling_rate, 'INFO', SYSTIMESTAMP, l_enabled_to
                );
                l_success_count := l_success_count + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    l_error_count := l_error_count + 1;
                    log_error_internal('enable_telemetry_bulk', 
                        'Failed for pattern: ' || p_object_patterns(i) || ' - ' || SQLERRM);
            END;
        END LOOP;
            
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('enable_telemetry_bulk', 
                'Bulk enable failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END enable_telemetry_bulk;

    /**
     * Emergency stop - disable all telemetry for tenant
     */
    PROCEDURE disable_all_telemetry(
        p_tenant_id         VARCHAR2,
        p_telemetry_type    VARCHAR2 DEFAULT NULL
    )
    IS
        l_rows_updated NUMBER;
        l_tenant_id VARCHAR2(100);
        l_telemetry_type VARCHAR2(20);
    BEGIN
        l_tenant_id := normalize_string(p_tenant_id, 100, FALSE);
        l_telemetry_type := normalize_string(p_telemetry_type, 20, FALSE);

        UPDATE PLT_TELEMETRY_ACTIVATION
        SET enabled = 'N'
        WHERE tenant_id = l_tenant_id
          AND (p_telemetry_type IS NULL OR telemetry_type = l_telemetry_type)
          AND enabled = 'Y';
          
        l_rows_updated := SQL%ROWCOUNT;
        COMMIT;
            
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('disable_all_telemetry', 
                'Emergency stop failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END disable_all_telemetry;

    --------------------------------------------------------------------------
    -- MAINTENANCE AND CLEANUP
    --------------------------------------------------------------------------
    
    /**
     * Cleanup expired activation records
     */
    PROCEDURE cleanup_expired_activations
    IS
        l_rows_updated NUMBER;
    BEGIN
        UPDATE PLT_TELEMETRY_ACTIVATION
        SET enabled = 'N'
        WHERE enabled = 'Y'
          AND enabled_time_to IS NOT NULL
          AND enabled_time_to <= SYSTIMESTAMP;
          
        l_rows_updated := SQL%ROWCOUNT;
        
        IF l_rows_updated > 0 THEN
            COMMIT;
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('cleanup_expired_activations', 
                'Cleanup failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
    END cleanup_expired_activations;

    /**
     * Purge old activation records and audit logs
     */
    PROCEDURE purge_old_records(p_keep_days NUMBER DEFAULT 90)
    IS
        l_cutoff_date TIMESTAMP;
        l_activation_purged NUMBER;
        l_audit_purged NUMBER;
    BEGIN
        l_cutoff_date := SYSTIMESTAMP - p_keep_days;
        
        -- Purge old disabled activation records
        DELETE FROM PLT_TELEMETRY_ACTIVATION
        WHERE enabled = 'N'
          AND updated_date < l_cutoff_date;
          
        l_activation_purged := SQL%ROWCOUNT;
        
        -- Purge old audit records
        DELETE FROM PLT_ACTIVATION_AUDIT
        WHERE changed_date < l_cutoff_date;
        
        l_audit_purged := SQL%ROWCOUNT;
        
        COMMIT;
            
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_error_internal('purge_old_records', 
                'Purge failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack || ' - ' || DBMS_UTILITY.format_error_backtrace, 1, 200));
            RAISE;
    END purge_old_records;

    --------------------------------------------------------------------------
    -- REPORTING AND MONITORING
    --------------------------------------------------------------------------
    
    /**
     * Get activation summary for tenant
     */
    FUNCTION get_activation_summary(
        p_tenant_id     VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR
    IS
        l_cursor SYS_REFCURSOR;
    BEGIN
        OPEN l_cursor FOR
            SELECT 
                telemetry_type,
                tenant_id,
                COUNT(*) as total_activations,
                SUM(CASE WHEN enabled = 'Y' THEN 1 ELSE 0 END) as enabled_activations,
                SUM(CASE WHEN enabled_time_to IS NOT NULL AND enabled_time_to > SYSTIMESTAMP THEN 1 ELSE 0 END) as temporary_activations,
                AVG(sampling_rate) as avg_sampling_rate,
                MIN(enabled_time_from) as earliest_activation,
                MAX(enabled_time_to) as latest_expiration
            FROM PLT_TELEMETRY_ACTIVATION
            WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
            GROUP BY telemetry_type, tenant_id
            ORDER BY tenant_id, telemetry_type;

        RETURN l_cursor;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('get_activation_summary', 
                'Summary query failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RETURN NULL;
    END get_activation_summary;

    /**
     * Get currently active telemetry configurations
     */
    FUNCTION get_active_configurations(
        p_tenant_id         VARCHAR2 DEFAULT NULL,
        p_telemetry_type    VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR
    IS
        l_cursor SYS_REFCURSOR;
    BEGIN
        OPEN l_cursor FOR
            SELECT 
                activation_id,
                telemetry_type,
                object_name,
                tenant_id,
                sampling_rate,
                log_level,
                enabled_time_from,
                enabled_time_to,
                CASE 
                    WHEN enabled_time_to IS NULL THEN 'PERMANENT'
                    WHEN enabled_time_to > SYSTIMESTAMP THEN 'TEMPORARY'
                    ELSE 'EXPIRED'
                END as activation_status,
                created_by,
                created_date,
                updated_by,
                updated_date
            FROM PLT_TELEMETRY_ACTIVATION
            WHERE enabled = 'Y'
              AND (enabled_time_to IS NULL OR enabled_time_to > SYSTIMESTAMP)
              AND SYSTIMESTAMP >= enabled_time_from
              AND (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
              AND (p_telemetry_type IS NULL OR telemetry_type = p_telemetry_type)
            ORDER BY 
                tenant_id, 
                telemetry_type, 
                LENGTH(object_name) DESC, -- Most specific first
                object_name;
                
        RETURN l_cursor;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('get_active_configurations', 
                'Active configs query failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RETURN NULL;
    END get_active_configurations;

    /**
     * Get recent activation changes (audit trail)
     */
    FUNCTION get_recent_changes(
        p_hours_back    NUMBER DEFAULT 24,
        p_tenant_id     VARCHAR2 DEFAULT NULL
    ) RETURN SYS_REFCURSOR
    IS
        l_cursor SYS_REFCURSOR;
        l_cutoff_time TIMESTAMP;
    BEGIN
        l_cutoff_time := SYSTIMESTAMP - (p_hours_back / 24);
        
        OPEN l_cursor FOR
            SELECT 
                audit_id,
                operation_type,
                telemetry_type,
                object_name,
                tenant_id,
                old_enabled,
                new_enabled,
                old_sampling_rate,
                new_sampling_rate,
                changed_by,
                changed_date,
                session_info
            FROM PLT_ACTIVATION_AUDIT
            WHERE changed_date >= l_cutoff_time
              AND (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
            ORDER BY changed_date DESC;
            
        RETURN l_cursor;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_error_internal('get_recent_changes', 
                'Recent changes query failed: ' || SUBSTR(DBMS_UTILITY.format_error_stack, 1, 200));
            RETURN NULL;
    END get_recent_changes;

    --------------------------------------------------------------------------
    -- UTILITY FUNCTIONS
    --------------------------------------------------------------------------

    /**
     * Validate object name format
     */
    FUNCTION is_valid_object_name(p_object_name VARCHAR2) RETURN BOOLEAN
    IS
    BEGIN
        IF p_object_name IS NULL OR LENGTH(TRIM(p_object_name)) = 0 THEN
            RETURN FALSE;
        END IF;
        
        -- Allow letters, numbers, dots, underscores, and asterisks
        RETURN REGEXP_LIKE(p_object_name, '^[A-Za-z0-9_.*]+$');
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END is_valid_object_name;

    /**
     * Validate telemetry type
     */
    FUNCTION is_valid_telemetry_type(p_telemetry_type VARCHAR2) RETURN BOOLEAN
    IS
    BEGIN
        RETURN normalize_string(p_telemetry_type, 20, FALSE) IN (C_TYPE_TRACE, C_TYPE_LOG, C_TYPE_METRIC);
    END is_valid_telemetry_type;

    /**
     * Convert log level to numeric priority
     */
    FUNCTION get_log_level_priority(p_log_level VARCHAR2) RETURN NUMBER
    IS
    BEGIN
        RETURN CASE normalize_string(p_log_level, 10, FALSE)
            WHEN C_LEVEL_TRACE THEN 1
            WHEN C_LEVEL_DEBUG THEN 2
            WHEN C_LEVEL_INFO THEN 3
            WHEN C_LEVEL_WARN THEN 4
            WHEN C_LEVEL_ERROR THEN 5
            WHEN C_LEVEL_FATAL THEN 6
            ELSE 0 -- Invalid level
        END;
    END get_log_level_priority;

END PLT_ACTIVATION_MANAGER;
/