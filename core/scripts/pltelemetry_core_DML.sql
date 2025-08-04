-- =====================================================
-- PLTelemetry - Unified DML (Configuration Data)
-- All DML operations for PLTelemetry
-- Execute as PLTELEMETRY user after DDL
-- =====================================================

SET SERVEROUTPUT ON

PROMPT Inserting PLTelemetry configuration data...

-- =====================================================
-- FAILOVER CONFIGURATION DATA
-- =====================================================

-- Default configurations for failover mechanism
INSERT INTO plt_failover_config (config_key, config_value, description) VALUES 
    ('ENABLED', 'Y', 'Enable/disable fallback mechanism');

INSERT INTO plt_failover_config (config_key, config_value, description) VALUES 
    ('MAX_MISSED_RUNS', '3', 'Number of missed runs before activating fallback');

INSERT INTO plt_failover_config (config_key, config_value, description) VALUES 
    ('CHECK_INTERVAL', '60', 'Seconds between health checks');

INSERT INTO plt_failover_config (config_key, config_value, description) VALUES 
    ('QUEUE_THRESHOLD', '1000', 'Max queue items before considering agent overloaded');

INSERT INTO plt_failover_config (config_key, config_value, description) VALUES
    ('FALLBACK_BACKEND', 'OTLP_BRIDGE', 'Backend to use when in fallback mode');

-- OTLP Bridge configuration
INSERT INTO plt_failover_config (config_key, config_value, description) VALUES 
    ('OTLP_COLLECTOR_URL', 'http://otel-collector:4318', 'OTLP Collector endpoint for fallback');

INSERT INTO plt_failover_config (config_key, config_value, description) VALUES 
    ('OTLP_SERVICE_NAME', 'oracle-plsql', 'Service name for OTLP telemetry');

INSERT INTO plt_failover_config (config_key, config_value, description) VALUES 
    ('OTLP_SERVICE_VERSION', '1.0.0', 'Service version for OTLP telemetry');

INSERT INTO plt_failover_config (config_key, config_value, description) VALUES 
    ('OTLP_ENVIRONMENT', 'production', 'Deployment environment');

-- Agent pulse mode configuration
INSERT INTO plt_failover_config (
    config_key, 
    config_value, 
    description, 
    updated_at
) VALUES (
    'AGENT_PULSE_MODE', 
    'PULSE1', 
    'Current agent throttling pulse mode (PULSE1, PULSE2, PULSE3, PULSE4, COMA)', 
    SYSTIMESTAMP
);

-- =====================================================
-- RATE LIMITING CONFIGURATION DATA
-- =====================================================

-- Default rate limiting configuration (adjustable per environment)
INSERT INTO plt_rate_limit_config (priority, latency_threshold_ms, optimal_batch_size, description) VALUES
    (1, 0,    500, 'Ultra fast - aggressive processing');

INSERT INTO plt_rate_limit_config (priority, latency_threshold_ms, optimal_batch_size, description) VALUES
    (2, 100,  300, 'Fast - normal processing');

INSERT INTO plt_rate_limit_config (priority, latency_threshold_ms, optimal_batch_size, description) VALUES
    (3, 500,  150, 'Moderate - some latency detected');

INSERT INTO plt_rate_limit_config (priority, latency_threshold_ms, optimal_batch_size, description) VALUES
    (4, 1000, 75,  'Slow - significant latency');

INSERT INTO plt_rate_limit_config (priority, latency_threshold_ms, optimal_batch_size, description) VALUES
    (5, 2000, 25,  'Very slow - system struggling');

INSERT INTO plt_rate_limit_config (priority, latency_threshold_ms, optimal_batch_size, description) VALUES
    (6, 9999999, 10, 'Fallback - minimum processing');

-- =====================================================
-- PULSE THROTTLING CONFIGURATION DATA
-- =====================================================

-- Insert default throttling configurations (fully configurable per environment)
INSERT INTO plt_pulse_throttling_config (
    pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, 
    sampling_rate, metrics_enabled, logs_enabled, queue_processing, description
) VALUES 
    ('PULSE1', 1.0000, 1.0000, 1.00, 1.0000, 'Y', 'Y', 'Y', 'Full capacity - no throttling');

INSERT INTO plt_pulse_throttling_config (
    pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, 
    sampling_rate, metrics_enabled, logs_enabled, queue_processing, description
) VALUES 
    ('PULSE2', 0.5000, 0.5000, 2.00, 0.7500, 'Y', 'Y', 'Y', 'Half capacity - moderate load');

INSERT INTO plt_pulse_throttling_config (
    pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, 
    sampling_rate, metrics_enabled, logs_enabled, queue_processing, description
) VALUES 
    ('PULSE3', 0.2500, 0.2500, 4.00, 0.5000, 'Y', 'Y', 'Y', 'Quarter capacity - high load');

INSERT INTO plt_pulse_throttling_config (
    pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, 
    sampling_rate, metrics_enabled, logs_enabled, queue_processing, description
) VALUES 
    ('PULSE4', 0.1000, 0.1000, 10.0, 0.2500, 'Y', 'Y', 'Y', 'Minimal capacity - critical load');

INSERT INTO plt_pulse_throttling_config (
    pulse_mode, capacity_multiplier, batch_multiplier, interval_multiplier, 
    sampling_rate, metrics_enabled, logs_enabled, queue_processing, description
) VALUES 
    ('COMA',   0.0000, 0.0100, 60.0, 0.0500, 'N', 'N', 'N', 'Hibernation mode - system overload');

-- =====================================================
-- DATABASE MONITORING CONFIGURATION DATA
-- =====================================================

-- Database validation types
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'TABLESPACE_USAGE',
    'Monitor tablespace usage percentage',
    'validate_tablespace_usage',
    5,
    1
);

INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'ACTIVE_SESSIONS',
    'Monitor active session count',
    'validate_active_sessions',
    2,
    1
);

INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'BLOCKED_SESSIONS',
    'Monitor blocked sessions count',
    'validate_blocked_sessions',
    1,
    1
);

INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'INVALID_OBJECTS',
    'Monitor invalid database objects',
    'validate_invalid_objects',
    10,
    1
);

INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'FAILED_JOBS',
    'Monitor failed scheduler jobs',
    'validate_failed_jobs',
    5,
    1
);

INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'MEMORY_USAGE',
    'Monitor database memory usage',
    'validate_memory_usage',
    5,
    1
);

INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'CPU_USAGE',
    'Monitor database CPU usage',
    'validate_cpu_usage',
    2,
    1
);

-- Custom certificate expiration validation
INSERT INTO db_validation_types (
    validation_type_code,
    description,
    validation_procedure,
    default_check_interval_minutes,
    is_active
) VALUES (
    'CERT_EXPIRATION',
    'Monitor SSL certificate expiration dates',
    'validate_cert_expiration',
    1440, -- Daily check
    1
);

-- Sample database validation rules
INSERT INTO db_validation_rules (
    validation_type_code,
    rule_name,
    target_name,
    warning_threshold,
    critical_threshold,
    check_interval_minutes,
    is_active
) VALUES (
    'TABLESPACE_USAGE',
    'PLTELEMETRY_DATA Usage',
    'PLTELEMETRY_DATA',
    80, -- Warning at 80%
    95, -- Critical at 95%
    10,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    rule_name,
    target_name,
    warning_threshold,
    critical_threshold,
    check_interval_minutes,
    is_active
) VALUES (
    'ACTIVE_SESSIONS',
    'High Session Count',
    NULL,
    50,  -- Warning at 50 sessions
    100, -- Critical at 100 sessions
    5,
    1
);

INSERT INTO db_validation_rules (
    validation_type_code,
    rule_name,
    target_name,
    warning_threshold,
    critical_threshold,
    check_interval_minutes,
    is_active
) VALUES (
    'BLOCKED_SESSIONS',
    'Blocked Sessions Check',
    NULL,
    1,   -- Warning at 1 blocked session
    5,   -- Critical at 5 blocked sessions
    2,
    1
);

-- =====================================================
-- SERVICE DISCOVERY CONFIGURATION DATA
-- =====================================================

-- Criticality levels configuration
INSERT INTO plt_service_discovery_crit_levels (
    criticality_code, 
    description, 
    check_interval_minutes, 
    escalation_multiplier, 
    max_escalation_failures
) VALUES (
    'CRITICAL', 
    'Critical services - business operations will stop if down',
    1,      -- Check every minute
    0.5,    -- On failure, check every 30 seconds
    5       -- Escalate after 5 consecutive failures
);

INSERT INTO plt_service_discovery_crit_levels (
    criticality_code, 
    description, 
    check_interval_minutes, 
    escalation_multiplier, 
    max_escalation_failures
) VALUES (
    'HIGH', 
    'Important services - business operations degraded if down',
    2,      -- Check every 2 minutes
    0.5,    -- On failure, check every minute
    4       -- Escalate after 4 consecutive failures
);

INSERT INTO plt_service_discovery_crit_levels (
    criticality_code, 
    description, 
    check_interval_minutes, 
    escalation_multiplier, 
    max_escalation_failures
) VALUES (
    'MEDIUM', 
    'Supporting services - moderate business impact if down',
    5,      -- Check every 5 minutes
    0.6,    -- On failure, check every 3 minutes
    5       -- Escalate after 5 consecutive failures
);

INSERT INTO plt_service_discovery_crit_levels (
    criticality_code, 
    description, 
    check_interval_minutes, 
    escalation_multiplier, 
    max_escalation_failures
) VALUES (
    'LOW', 
    'Non-critical services - minimal business impact if down',
    10,     -- Check every 10 minutes
    0.5,    -- On failure, check every 5 minutes
    8       -- Escalate after 8 consecutive failures
);

-- Observability infrastructure services
INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'otel-collector',
    'OpenTelemetry Collector - Telemetry ingestion',
    'http://otel-collector:4318/v1/traces',
    'HIGH',
    5,
    1,
    'observability'
);

INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'grafana',
    'Grafana - Monitoring dashboards and visualization',
    'http://grafana:3000/api/health',
    'HIGH',
    8,
    1,
    'observability'
);

INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'tempo',
    'Grafana Tempo - Distributed tracing backend',
    'http://tempo:3200/api/echo',
    'MEDIUM',
    10,
    1,
    'observability'
);

INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'prometheus',
    'Prometheus - Metrics collection and storage',
    'http://prometheus:9090/-/healthy',
    'MEDIUM',
    8,
    1,
    'observability'
);

INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'loki',
    'Grafana Loki - Log aggregation system',
    'http://loki:3100/ready',
    'LOW',
    10,
    1,
    'observability'
);

-- =====================================================
-- COMMIT ALL CONFIGURATION DATA
-- =====================================================

COMMIT;

PROMPT
PROMPT =====================================================
PROMPT PLTelemetry DML Installation Complete
PROMPT =====================================================
PROMPT 
PROMPT Configuration data inserted:
PROMPT - Failover configuration: 10 entries
PROMPT - Rate limiting: 6 priority levels
PROMPT - Pulse throttling: 5 pulse modes (PULSE1-4, COMA)
PROMPT - Service discovery criticality levels: 4 levels
PROMPT - Observability services: 5 services (collector, grafana, tempo, prometheus, loki)
PROMPT - Database monitoring: 8 validation types
PROMPT - Sample validation rules: 3 rules
PROMPT 
PROMPT Key endpoints configured:
PROMPT - OTLP Collector: http://otel-collector:4318
PROMPT - Service name: oracle-plsql
PROMPT - Environment: production
PROMPT 
PROMPT System ready for PLTelemetry core package installation
PROMPT =====================================================

-- Quick verification queries
PROMPT
PROMPT === Configuration Verification ===

SELECT 'Failover Config' as component, COUNT(*) as entries FROM plt_failover_config
UNION ALL
SELECT 'Rate Limiting', COUNT(*) FROM plt_rate_limit_config  
UNION ALL
SELECT 'Pulse Throttling', COUNT(*) FROM plt_pulse_throttling_config
UNION ALL
SELECT 'Service Criticality Levels', COUNT(*) FROM plt_service_discovery_crit_levels
UNION ALL
SELECT 'Observability Services', COUNT(*) FROM plt_service_discovery_config
UNION ALL
SELECT 'DB Validation Types', COUNT(*) FROM db_validation_types
UNION ALL
SELECT 'DB Validation Rules', COUNT(*) FROM db_validation_rules;

PROMPT
PROMPT Current configuration values:
SELECT config_key, config_value, description 
FROM plt_failover_config 
WHERE config_key IN ('OTLP_COLLECTOR_URL', 'OTLP_SERVICE_NAME', 'AGENT_PULSE_MODE')
ORDER BY config_key;