SET DEFINE OFF;

CREATE OR REPLACE PACKAGE PLT_CONFIGURATION AS
    /**
     * PLT_CONFIGURATION
     * -------------------------------------------------------------------------
     * Centralized configuration manager.
     * Reads from PLT_SYS_CONFIG and uses RESULT_CACHE for maximum performance.
     */

    -- Gets a configuration value (String)
    -- Uses RESULT_CACHE: If the table doesn't change, we don't SELECT.
    FUNCTION get_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_default IN VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2 
    RESULT_CACHE;

    -- Helper to get boolean values (TRUE/FALSE)
    FUNCTION get_bool_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_default IN BOOLEAN DEFAULT FALSE
    ) RETURN BOOLEAN;

    -- Helper to get numeric values
    FUNCTION get_num_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_default IN NUMBER DEFAULT 0
    ) RETURN NUMBER;

    -- Updates or Inserts a configuration value
    -- On commit, the result cache is automatically invalidated.
    PROCEDURE set_param(
        p_group IN VARCHAR2, 
        p_key   IN VARCHAR2, 
        p_value IN VARCHAR2,
        p_desc  IN VARCHAR2 DEFAULT NULL
    );

END PLT_CONFIGURATION;
/
