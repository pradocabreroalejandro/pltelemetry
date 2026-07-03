CREATE OR REPLACE PACKAGE PLT_ACTIVATION_MANAGER AS
    -- Returns TRUE if we should generate telemetry for this object
    FUNCTION should_trace(p_object_name VARCHAR2) RETURN BOOLEAN;
    
    -- Clears the cache (useful if you change rules on the fly)
    PROCEDURE flush_cache;
END PLT_ACTIVATION_MANAGER;
/
