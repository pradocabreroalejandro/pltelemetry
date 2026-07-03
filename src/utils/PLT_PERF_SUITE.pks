CREATE OR REPLACE PACKAGE PLT_PERF_SUITE AUTHID DEFINER AS
    /**
     * PLT_PERF_SUITE
     * -------------------------------------------------------------------------
     * Synthetic load generator for PLTelemetry stress testing.
     */

    -- Runs a sequential test in the current session
    -- p_iterations: How many times to repeat the operation
    -- p_scenario:   'LIGHT', 'STANDARD', 'HEAVY'
    PROCEDURE run_test_session(
        p_iterations NUMBER DEFAULT 1000,
        p_scenario   VARCHAR2 DEFAULT 'STANDARD'
    );

    -- Launches a concurrency test using Jobs
    -- p_concurrent_users: Number of simultaneous sessions
    -- p_iterations_per_user: Iterations per user
    PROCEDURE spawn_load_test(
        p_concurrent_users    NUMBER DEFAULT 5,
        p_iterations_per_user NUMBER DEFAULT 1000,
        p_scenario            VARCHAR2 DEFAULT 'STANDARD'
    );

    -- Clears the queue to start from scratch (DEVELOPMENT ONLY)
    PROCEDURE reset_queue;

END PLT_PERF_SUITE;
/
