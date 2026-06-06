PROMPT [06] Configuring Queue Thresholds...

-- Umbral de tamaño para rotar la tabla (en MB). 
-- 1024 MB = 1GB. Ponemos 500MB por defecto para ser conservadores.
BEGIN
    PLT_CONFIGURATION.set_param('QUEUE', 'MAX_SIZE_MB', '500', 'Tamaño máximo de tabla antes de rotar');
    PLT_CONFIGURATION.set_param('QUEUE', 'FORCE_ROTATION_HOURS', '24', 'Rotar forzosamente cada X horas (opcional)');
    COMMIT;
END;
/
PROMPT ✅ Configuración de umbrales cargada.