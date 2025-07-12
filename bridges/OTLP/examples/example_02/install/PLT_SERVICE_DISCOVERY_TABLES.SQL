-- =============================================================================
-- PLTelemetry Service Discovery Tables
-- =============================================================================

-- Drop existing tables if they exist
DROP TABLE plt_service_discovery_config CASCADE CONSTRAINTS;
DROP TABLE plt_service_discovery_crit_levels CASCADE CONSTRAINTS;

-- Criticality levels configuration
CREATE TABLE plt_service_discovery_crit_levels (
    criticality_code         VARCHAR2(10) PRIMARY KEY,
    description              VARCHAR2(100) NOT NULL,
    check_interval_minutes   NUMBER NOT NULL,
    escalation_multiplier    NUMBER DEFAULT 0.5,
    max_escalation_failures  NUMBER DEFAULT 3,
    created_at              TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_at              TIMESTAMP DEFAULT SYSTIMESTAMP
);

COMMENT ON TABLE plt_service_discovery_crit_levels IS 'Service discovery criticality levels and check intervals';
COMMENT ON COLUMN plt_service_discovery_crit_levels.escalation_multiplier IS 'Multiplier to reduce interval on failures (0.5 = half interval)';

-- Service discovery configuration
CREATE TABLE plt_service_discovery_config (
    service_id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_name            VARCHAR2(50) UNIQUE NOT NULL,
    service_description     VARCHAR2(200),
    endpoint_url            VARCHAR2(300) NOT NULL,
    criticality_code        VARCHAR2(10) NOT NULL,
    timeout_seconds         NUMBER DEFAULT 10,
    is_enabled              NUMBER(1) DEFAULT 1,
    tenant_id               VARCHAR2(100),  -- Multi-tenant support
    created_at              TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_at              TIMESTAMP DEFAULT SYSTIMESTAMP,
    last_check_time         TIMESTAMP,
    consecutive_failures    NUMBER DEFAULT 0,
    last_success_time       TIMESTAMP,
    last_failure_reason     VARCHAR2(500),
    
    -- Constraints
    CONSTRAINT fk_svc_disc_criticality FOREIGN KEY (criticality_code) 
        REFERENCES plt_service_discovery_crit_levels(criticality_code),
    CONSTRAINT chk_svc_disc_enabled CHECK (is_enabled IN (0, 1)),
    CONSTRAINT chk_svc_disc_timeout CHECK (timeout_seconds > 0),
    CONSTRAINT chk_svc_disc_failures CHECK (consecutive_failures >= 0)
);

COMMENT ON TABLE plt_service_discovery_config IS 'Service discovery endpoint configuration and health status';
COMMENT ON COLUMN plt_service_discovery_config.tenant_id IS 'Tenant identifier for multi-tenant environments';

-- =============================================================================
-- PERFORMANCE INDEXES
-- =============================================================================

-- Service discovery config indexes
CREATE INDEX idx_plt_svc_disc_enabled ON plt_service_discovery_config(is_enabled, criticality_code);
CREATE INDEX idx_plt_svc_disc_tenant ON plt_service_discovery_config(tenant_id, is_enabled);
CREATE INDEX idx_plt_svc_disc_last_check ON plt_service_discovery_config(last_check_time);
CREATE INDEX idx_plt_svc_disc_failures ON plt_service_discovery_config(consecutive_failures, is_enabled);
CREATE INDEX idx_plt_svc_disc_criticality ON plt_service_discovery_config(criticality_code, is_enabled);
CREATE INDEX idx_plt_svc_disc_next_check ON plt_service_discovery_config(
    CASE WHEN is_enabled = 1 THEN last_check_time END, 
    criticality_code
);

-- Criticality levels indexes  
CREATE INDEX idx_plt_svc_crit_interval ON plt_service_discovery_crit_levels(check_interval_minutes);

