CREATE OR REPLACE PACKAGE PLTELEMETRY.PLT_DB_METRIC_READER AUTHID DEFINER AS
    /*
     * DATA ACCESS PACKAGE (READER)
     * ----------------------------
     * - Only reads from system views.
     * - Transforms raw data into t_plt_metric_row.
     * - Knows nothing about PLTelemetry or HTTP sends.
     * 
     * Oracle 23ai Enhanced: Includes TNS Listener, In-Memory, and Auto Indexing metrics.
     */
    
    -- System Metrics (CPU, AAS, Transactions, Wait Classes, Hit Ratios)
    FUNCTION get_system_metrics RETURN t_plt_metric_tab PIPELINED;
    
    -- Session Metrics (Active, Blocked, Total, PDB sessions)
    FUNCTION get_session_metrics RETURN t_plt_metric_tab PIPELINED;
    
    -- Storage Metrics (Tablespaces, TEMP, Undo, RMAN status, Datafile I/O)
    FUNCTION get_storage_metrics RETURN t_plt_metric_tab PIPELINED;
    
    -- TNS Listener & Network Health (Services, SQL*Net waits, Dispatcher stats)
    FUNCTION get_listener_metrics RETURN t_plt_metric_tab PIPELINED;
    
    -- Automatic Indexing Metrics (23ai)
    FUNCTION get_indexing_metrics RETURN t_plt_metric_tab PIPELINED;
    
    -- In-Memory Column Store Metrics (23ai)
    FUNCTION get_inmemory_metrics RETURN t_plt_metric_tab PIPELINED;
    
END PLT_DB_METRIC_READER;

/
