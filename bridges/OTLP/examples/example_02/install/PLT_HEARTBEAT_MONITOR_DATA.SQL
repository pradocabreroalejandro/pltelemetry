-- ============================================================================
-- Heartbeat Monitoring - DML for Configuration Tables
-- ============================================================================

-- ============================================================================
-- Insert Criticality Levels
-- ============================================================================

INSERT INTO heartbeat_criticality_levels (
    criticality_code, 
    description, 
    check_interval_minutes, 
    escalation_multiplier, 
    max_escalation_failures
) VALUES (
    'HIGH', 
    'Critical services - business operations will stop if down',
    1,      -- Check every minute
    0.5,    -- On failure, check every 30 seconds
    3       -- Escalate after 3 consecutive failures
);

INSERT INTO heartbeat_criticality_levels (
    criticality_code, 
    description, 
    check_interval_minutes, 
    escalation_multiplier, 
    max_escalation_failures
) VALUES (
    'MEDIUM', 
    'Important services - business operations degraded if down',
    2,      -- Check every 2 minutes
    0.5,    -- On failure, check every minute
    4       -- Escalate after 4 consecutive failures
);

INSERT INTO heartbeat_criticality_levels (
    criticality_code, 
    description, 
    check_interval_minutes, 
    escalation_multiplier, 
    max_escalation_failures
) VALUES (
    'LOW', 
    'Supporting services - minimal business impact if down',
    5,      -- Check every 5 minutes
    0.6,    -- On failure, check every 3 minutes
    5       -- Escalate after 5 consecutive failures
);

INSERT INTO heartbeat_criticality_levels (
    criticality_code, 
    description, 
    check_interval_minutes, 
    escalation_multiplier, 
    max_escalation_failures
) VALUES (
    'VERY_LOW', 
    'Non-critical services - no immediate business impact',
    10,     -- Check every 10 minutes
    0.5,    -- On failure, check every 5 minutes
    8       -- Escalate after 8 consecutive failures
);

-- ============================================================================
-- Insert Service Definitions
-- ============================================================================

-- Oracle Reports Service (Critical for business reports)
INSERT INTO heartbeat_services (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled
) VALUES (
    'oracle-reports',
    'Oracle Reports Server - Critical reporting infrastructure',
    'http://192.168.100.116:8001',
    'HIGH',
    10,
    1
);

-- WebLogic ERP Service (Core business system)
INSERT INTO heartbeat_services (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled
) VALUES (
    'weblogic-erp',
    'WebLogic ERP System - Core business operations',
    'http://192.168.100.116:8002',
    'HIGH',
    15,
    1
);

-- Email Service (Important for notifications)
INSERT INTO heartbeat_services (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled
) VALUES (
    'email-service',
    'Email Notification Service - Business communications',
    'http://192.168.100.116:8003',
    'MEDIUM',
    8,
    1
);

-- Batch Processor (Can wait, but important for daily operations)
INSERT INTO heartbeat_services (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled
) VALUES (
    'batch-processor',
    'Batch Processing Service - Daily background operations',
    'http://192.168.100.116:8004',
    'LOW',
    12,
    1
);

-- Document Generator (Non-critical, can be down for hours)
INSERT INTO heartbeat_services (
    service_name,
    service_description,
    endpoint_url,
    criticality_code,
    timeout_seconds,
    is_enabled
) VALUES (
    'document-service',
    'Document Generation Service - Non-critical document processing',
    'http://192.168.100.116:8005',
    'VERY_LOW',
    20,
    1
);

-- ============================================================================
-- Verification Queries
-- ============================================================================

-- Check criticality levels
SELECT 
    criticality_code,
    description,
    check_interval_minutes,
    escalation_multiplier,
    max_escalation_failures
FROM heartbeat_criticality_levels
ORDER BY check_interval_minutes;

-- Check service configuration
SELECT 
    s.service_name,
    s.service_description,
    s.endpoint_url,
    s.criticality_code,
    c.check_interval_minutes,
    s.timeout_seconds,
    CASE WHEN s.is_enabled = 1 THEN 'ENABLED' ELSE 'DISABLED' END as status
FROM heartbeat_services s
JOIN heartbeat_criticality_levels c ON s.criticality_code = c.criticality_code
ORDER BY c.check_interval_minutes, s.service_name;

-- Summary by criticality
SELECT 
    c.criticality_code,
    c.description,
    c.check_interval_minutes,
    COUNT(s.service_id) as service_count,
    SUM(CASE WHEN s.is_enabled = 1 THEN 1 ELSE 0 END) as enabled_services
FROM heartbeat_criticality_levels c
LEFT JOIN heartbeat_services s ON c.criticality_code = s.criticality_code
GROUP BY c.criticality_code, c.description, c.check_interval_minutes
ORDER BY c.check_interval_minutes;

COMMIT;