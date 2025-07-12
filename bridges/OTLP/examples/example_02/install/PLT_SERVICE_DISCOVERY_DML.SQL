-- =============================================================================
-- PLTelemetry Service Discovery - DML Configuration
-- =============================================================================

-- =============================================================================
-- Insert Criticality Levels (Updated naming and logic)
-- =============================================================================

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

-- =============================================================================
-- Insert Service Definitions (Real Production Services)
-- =============================================================================

-- Oracle Reports Service (Critical for business reports)
INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'oracle-reports',
    'Oracle Reports Server - Critical reporting infrastructure',
    'http://localhost:8001',
    'CRITICAL',  -- Upgraded from HIGH to CRITICAL
    10,
    1,
    'CORE_PROD'
);

-- WebLogic ERP Service (Core business system)
INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'weblogic-erp',
    'WebLogic ERP System - Core business operations',
    'http://localhost:8002',
    'CRITICAL',  -- Upgraded from HIGH to CRITICAL
    15,
    1,
    'CORE_PROD'
);

-- Email Service (Important for notifications)
INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'email-service',
    'Email Notification Service - Business communications',
    'http://192.168.100.116:8003',
    'HIGH',  -- Was MEDIUM, upgraded
    8,
    1,
    'CORE_PROD'
);

-- Batch Processor (Can wait, but important for daily operations)
INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'batch-processor',
    'Batch Processing Service - Daily background operations',
    'http://localhost:8004',
    'MEDIUM',  -- Was LOW, upgraded
    12,
    1,
    'CORE_PROD'
);

-- Document Generator (Non-critical, can be down for hours)
INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'document-service',
    'Document Generation Service - Non-critical document processing',
    'http://localhost:8005',
    'LOW',  -- Was VERY_LOW, consolidated
    20,
    1,
    'CORE_PROD'
);

-- PLTelemetry OTLP Collector (New - for observability stack)
INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'plt-otel-collector',
    'PLTelemetry OTLP Collector - Observability infrastructure',
    'http://plt-otel-collector:4318/v1/traces',
    'HIGH',
    5,
    1,
    'CORE_PROD'
);

-- Grafana (New - for monitoring dashboards)
INSERT INTO plt_service_discovery_config (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled,
    tenant_id
) VALUES (
    'grafana-dashboard',
    'Grafana Monitoring Dashboards',
    'http://grafana:3000/api/health',
    'MEDIUM',
    8,
    1,
    'CORE_PROD'
);

-- =============================================================================
-- Verification Queries (Updated table names)
-- =============================================================================

-- Check criticality levels
SELECT 
    criticality_code,
    description,
    check_interval_minutes,
    escalation_multiplier,
    max_escalation_failures,
    created_at
FROM plt_service_discovery_crit_levels
ORDER BY check_interval_minutes;

-- Check service configuration
SELECT 
    s.service_name,
    s.service_description,
    s.endpoint_url,
    s.criticality_code,
    c.check_interval_minutes,
    s.timeout_seconds,
    s.tenant_id,
    CASE WHEN s.is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END as status,
    s.consecutive_failures,
    s.last_check_time
FROM plt_service_discovery_config s
JOIN plt_service_discovery_crit_levels c ON s.criticality_code = c.criticality_code
ORDER BY c.check_interval_minutes, s.service_name;

-- Summary by criticality and tenant
SELECT 
    c.criticality_code,
    c.description,
    c.check_interval_minutes,
    s.tenant_id,
    COUNT(s.service_id) as service_count,
    SUM(CASE WHEN s.is_enabled = 1 THEN 1 ELSE 0 END) as enabled_services,
    AVG(s.timeout_seconds) as avg_timeout
FROM plt_service_discovery_crit_levels c
LEFT JOIN plt_service_discovery_config s ON c.criticality_code = s.criticality_code
GROUP BY c.criticality_code, c.description, c.check_interval_minutes, s.tenant_id
ORDER BY c.check_interval_minutes, s.tenant_id;

-- Health check readiness query
SELECT 
    service_name,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    consecutive_failures,
    CASE 
        WHEN last_check_time IS NULL THEN 'NEVER_CHECKED'
        WHEN consecutive_failures = 0 THEN 'HEALTHY'
        WHEN consecutive_failures < (SELECT max_escalation_failures FROM plt_service_discovery_crit_levels cl WHERE cl.criticality_code = s.criticality_code) THEN 'DEGRADED'
        ELSE 'CRITICAL_FAILURE'
    END as health_status
FROM plt_service_discovery_config s
WHERE is_enabled = 1
ORDER BY criticality_code, consecutive_failures DESC;

COMMIT;