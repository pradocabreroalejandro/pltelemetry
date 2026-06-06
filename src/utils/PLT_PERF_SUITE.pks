CREATE OR REPLACE PACKAGE PLT_PERF_SUITE AUTHID DEFINER AS
    /**
     * PLT_PERF_SUITE
     * -------------------------------------------------------------------------
     * Generador de carga sintética para pruebas de estrés de PLTelemetry.
     */

    -- Ejecuta una prueba secuencial en la sesión actual
    -- p_iterations: Cuántas veces repetir la operación
    -- p_scenario:   'LIGHT', 'STANDARD', 'HEAVY'
    PROCEDURE run_test_session(
        p_iterations NUMBER DEFAULT 1000,
        p_scenario   VARCHAR2 DEFAULT 'STANDARD'
    );

    -- Lanza una prueba de concurrencia usando Jobs
    -- p_concurrent_users: Número de sesiones simultáneas
    -- p_iterations_per_user: Iteraciones por usuario
    PROCEDURE spawn_load_test(
        p_concurrent_users    NUMBER DEFAULT 5,
        p_iterations_per_user NUMBER DEFAULT 1000,
        p_scenario            VARCHAR2 DEFAULT 'STANDARD'
    );

    -- Limpia la cola para empezar de cero (SOLO EN DESARROLLO)
    PROCEDURE reset_queue;

END PLT_PERF_SUITE;
/