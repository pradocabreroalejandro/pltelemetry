CREATE OR REPLACE PACKAGE PLTELEMETRY.PLT_DB_METRIC_READER AUTHID DEFINER AS
    /*
     * PAQUETE DE ACCESO A DATOS (READER)
     * ----------------------------------
     * - Solo lee de vistas de sistema.
     * - Transforma el dato crudo en t_plt_metric_row.
     * - No sabe nada de PLTelemetry ni de envíos HTTP.
     */

    -- Métricas de Sistema (CPU, AAS, Transacciones)
    FUNCTION get_system_metrics RETURN t_plt_metric_tab PIPELINED;

    -- Métricas de Sesiones (Activas, Bloqueadas, Totales)
    FUNCTION get_session_metrics RETURN t_plt_metric_tab PIPELINED;

    -- Métricas de Espacio (Tablespaces, TEMP) - Devuelve una fila por tablespace
    FUNCTION get_storage_metrics RETURN t_plt_metric_tab PIPELINED;

END PLT_DB_METRIC_READER;
/