CREATE OR REPLACE PACKAGE PLT_QUEUE_MANAGER AS
    /**
     * PLT_QUEUE_MANAGER
     * -------------------------------------------------------------------------
     * Orquestador de particionado lógico para PLT_QUEUE.
     * Gestiona el ciclo de vida: ACTIVE -> DRAINING -> TRUNCATE -> READY
     */

    -- Mantiene el sistema: Verifica tamaños, rota si es necesario y trunca lo viejo.
    -- Ideal para llamar desde un JOB cada 5-15 minutos.
    PROCEDURE run_maintenance_cycle;

    -- Fuerza una rotación manual (útil para despliegues o emergencias)
    PROCEDURE force_rotation;

    -- Devuelve información del estado actual (para monitoreo)
    PROCEDURE get_status(
        p_active_table OUT VARCHAR2,
        p_active_mb    OUT NUMBER,
        p_drain_table  OUT VARCHAR2,
        p_drain_rows   OUT NUMBER
    );

    FUNCTION get_table_size_mb(p_table_name VARCHAR2) RETURN NUMBER ;

END PLT_QUEUE_MANAGER;
/