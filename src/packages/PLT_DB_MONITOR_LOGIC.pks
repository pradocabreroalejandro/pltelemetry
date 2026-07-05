CREATE OR REPLACE PACKAGE PLTELEMETRY.PLT_DB_MONITOR_LOGIC AS
    /*
     * ORCHESTRATION PACKAGE
     * ---------------------
     * - Manages the execution loop.
     * - Converts PIPELINED rows into PLTelemetry calls.
     */
     
    -- Main procedure called by the Scheduler Job
    PROCEDURE run_collection_cycle;
    
    -- Forces execution of a specific collector (useful for debug)
    PROCEDURE run_collector_dynamic(p_code VARCHAR2, p_package VARCHAR2, p_func VARCHAR2, p_tenant_id VARCHAR2 DEFAULT 'default');

END PLT_DB_MONITOR_LOGIC;

/
