CREATE OR REPLACE PACKAGE PLTELEMETRY.PLT_DB_MONITOR_LOGIC AS
    /*
     * PAQUETE DE ORQUESTACIÓN
     * -----------------------
     * - Gestiona el bucle de ejecución.
     * - Convierte filas PIPELINED en llamadas a PLTelemetry.
     */
     
    -- Procedimiento principal llamado por el Job del Scheduler
    PROCEDURE run_collection_cycle;
    
    -- Fuerza la ejecución de un colector específico (útil para debug)
    PROCEDURE run_collector_dynamic(p_code VARCHAR2, p_package VARCHAR2, p_func VARCHAR2);

END PLT_DB_MONITOR_LOGIC;
/