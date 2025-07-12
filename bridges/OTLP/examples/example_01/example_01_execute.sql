
-- 1. First ensure PLTelemetry is properly configured
BEGIN
    PLTelemetry.set_backend_url('OTLP_BRIDGE');
    PLT_OTLP_BRIDGE.set_otlp_collector('http://plt-otel-collector:4318');
    PLT_OTLP_BRIDGE.set_service_info('oracle-forms', '2.1.0', 'test-environment');
    PLTelemetry.set_autocommit(TRUE);
    PLTelemetry.set_async_mode(FALSE);
    PLT_OTLP_BRIDGE.set_debug_mode(TRUE);
    FORM_KEY_COMMIT;
END;
/
BEGIN
    ROLLBACK;
END;

-- 2. Execute the complete invoice workflow
truncate TABLE plt_traces;

truncate TABLE plt_spans;

truncate TABLE plt_events;

truncate TABLE plt_telemetry_errors;

-- 3. Check telemetry data was generated
SELECT * FROM plt_traces WHERE service_name = 'oracle-plsql' order by START_TIME desc;

SELECT * FROM plt_spans WHERE operation_name LIKE '%invoice%';

SELECT * FROM plt_events WHERE span_id IN 
    (SELECT span_id FROM plt_spans WHERE operation_name LIKE '%invoice%');
/*
-- 4. View the trace in Grafana/Tempo using the trace_id from the output

-- Expected timeline in Grafana:
-- ├── forms_invoice_processing (13.8s total)
--     ├── loading_form_configuration (0.3s)
--     ├── pricing_calculation (1.1s) [distributed to API_PRICING]
--     ├── performing_business_validations (1.5s)
--     ├── invoice_creation (2.3s) [distributed to API_INVOICE]
--     ├── generating_pdf_with_oracle_reports (4.3s)
--     └── sending_to_printer (4.3s)

-- All operations will be correlated by the same trace_id and visible as 
-- a complete distributed timeline across Oracle Forms and PL/SQL APIs!
*/

