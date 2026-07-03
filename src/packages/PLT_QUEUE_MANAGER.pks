CREATE OR REPLACE PACKAGE PLT_QUEUE_MANAGER AS
    /**
     * PLT_QUEUE_MANAGER
     * -------------------------------------------------------------------------
     * Logical partitioning orchestrator for PLT_QUEUE.
     * Manages the lifecycle: ACTIVE -> DRAINING -> TRUNCATE -> READY
     */

    -- Maintains the system: Checks sizes, rotates if necessary and truncates old data.
    -- Ideal to call from a JOB every 5-15 minutes.
    PROCEDURE run_maintenance_cycle;

    -- Forces a manual rotation (useful for deployments or emergencies)
    PROCEDURE force_rotation;

    -- Returns current status information (for monitoring)
    PROCEDURE get_status(
        p_active_table OUT VARCHAR2,
        p_active_mb    OUT NUMBER,
        p_drain_table  OUT VARCHAR2,
        p_drain_rows   OUT NUMBER
    );

    FUNCTION get_table_size_mb(p_table_name VARCHAR2) RETURN NUMBER ;

END PLT_QUEUE_MANAGER;
