CREATE OR REPLACE PACKAGE PLTELEMETRY.PLT_DB_METRIC_READER AUTHID DEFINER AS
    /*
     * DATA ACCESS PACKAGE (READER)
     * ----------------------------
     * - Only reads from system views.
     * - Transforms raw data into t_plt_metric_row.
     * - Knows nothing about PLTelemetry or HTTP sends.
     */

    -- System Metrics (CPU, AAS, Transactions)
    FUNCTION get_system_metrics RETURN t_plt_metric_tab PIPELINED;

    -- Session Metrics (Active, Blocked, Total)
    FUNCTION get_session_metrics RETURN t_plt_metric_tab PIPELINED;

    -- Storage Metrics (Tablespaces, TEMP) - Returns one row per tablespace
    FUNCTION get_storage_metrics RETURN t_plt_metric_tab PIPELINED;

END PLT_DB_METRIC_READER;
