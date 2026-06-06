CREATE OR REPLACE PACKAGE PLT_CONFIGURATION AS
    /**
     * PLT_CONFIGURATION
     * -------------------------------------------------------------------------
     * Gestor centralizado de configuración.
     * Lee de PLT_SYS_CONFIG y usa RESULT_CACHE para máximo rendimiento.
     */

    -- Obtiene un valor de configuración (String)
    -- Usa RESULT_CACHE: Si la tabla no cambia, no hacemos SELECT.
    FUNCTION get_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_default IN VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2 
    RESULT_CACHE;

    -- Helper para obtener valores booleanos (TRUE/FALSE)
    FUNCTION get_bool_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_default IN BOOLEAN DEFAULT FALSE
    ) RETURN BOOLEAN;

    -- Helper para obtener valores numéricos
    FUNCTION get_num_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_default IN NUMBER DEFAULT 0
    ) RETURN NUMBER;

    -- Actualiza o Inserta un valor de configuración
    -- Al hacer commit, la caché de resultados se invalida automáticamente.
    PROCEDURE set_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_value IN VARCHAR2,
        p_desc  IN VARCHAR2 DEFAULT NULL
    );

END PLT_CONFIGURATION;
/