CREATE OR REPLACE PACKAGE PLT_ACTIVATION_MANAGER AS
    -- Devuelve TRUE si debemos generar telemetría para este objeto
    FUNCTION should_trace(p_object_name VARCHAR2) RETURN BOOLEAN;
    
    -- Limpia la caché (útil si cambias las reglas en caliente)
    PROCEDURE flush_cache;
END PLT_ACTIVATION_MANAGER;
/