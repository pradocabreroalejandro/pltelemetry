-- =============================================================================
-- PLT_ACTIVATION_MANAGER - DDL Complete
-- Granular telemetry activation control with wildcards and inheritance
-- =============================================================================

PROMPT Creating PLT_ACTIVATION_MANAGER tables and infrastructure...

-- =============================================================================
-- 1. MAIN ACTIVATION TABLE
-- =============================================================================

CREATE TABLE PLT_TELEMETRY_ACTIVATION (
    activation_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    telemetry_type VARCHAR2(20) NOT NULL CHECK (telemetry_type IN ('TRACE', 'LOG', 'METRIC')),
    object_name VARCHAR2(200) NOT NULL, -- PACKAGE.PROCEDURE, FORM.TRIGGER, supports wildcards
    tenant_id VARCHAR2(100) NOT NULL,
    enabled CHAR(1) DEFAULT 'Y' CHECK (enabled IN ('Y','N')),
    enabled_time_from TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    enabled_time_to TIMESTAMP,
    log_level VARCHAR2(10) CHECK (log_level IN ('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')),
    sampling_rate NUMBER DEFAULT 1.0 CHECK (sampling_rate BETWEEN 0.0 AND 1.0),
    created_by VARCHAR2(100),
    created_date TIMESTAMP DEFAULT SYSTIMESTAMP,
    updated_by VARCHAR2(100),
    updated_date TIMESTAMP DEFAULT SYSTIMESTAMP,
    
    CONSTRAINT uk_plt_activation UNIQUE (telemetry_type, object_name, tenant_id)
);

COMMENT ON TABLE PLT_TELEMETRY_ACTIVATION IS 'Granular activation control for PLTelemetry - whitelist approach';
COMMENT ON COLUMN PLT_TELEMETRY_ACTIVATION.object_name IS 'Supports wildcards: PKG.*, FORM.*, PKG.PROC';
COMMENT ON COLUMN PLT_TELEMETRY_ACTIVATION.sampling_rate IS '0.0 to 1.0 - percentage of telemetry to actually send';
COMMENT ON COLUMN PLT_TELEMETRY_ACTIVATION.log_level IS 'Minimum log level for LOG telemetry type';

-- =============================================================================
-- 2. AUDIT TABLE - For tracking changes (always sent to Loki)
-- =============================================================================

CREATE TABLE PLT_ACTIVATION_AUDIT (
    audit_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    activation_id NUMBER,
    operation_type VARCHAR2(10) NOT NULL CHECK (operation_type IN ('INSERT', 'UPDATE', 'DELETE')),
    telemetry_type VARCHAR2(20),
    object_name VARCHAR2(200),
    tenant_id VARCHAR2(100),
    old_enabled CHAR(1),
    new_enabled CHAR(1),
    old_sampling_rate NUMBER,
    new_sampling_rate NUMBER,
    old_enabled_to TIMESTAMP,
    new_enabled_to TIMESTAMP,
    changed_by VARCHAR2(100),
    changed_date TIMESTAMP DEFAULT SYSTIMESTAMP,
    session_info VARCHAR2(500) -- Additional context
);

COMMENT ON TABLE PLT_ACTIVATION_AUDIT IS 'Audit trail for activation changes - always logged to Loki';

-- =============================================================================
-- 3. PERFORMANCE INDICES
-- =============================================================================

-- Primary lookup index - most common query pattern
CREATE INDEX idx_plt_activation_lookup ON PLT_TELEMETRY_ACTIVATION (
    telemetry_type, object_name, tenant_id, enabled
);

-- Time-based queries for cleanup
CREATE INDEX idx_plt_activation_time ON PLT_TELEMETRY_ACTIVATION (
    enabled_time_to, enabled
);

-- Wildcard searches (for inheritance logic)
CREATE INDEX idx_plt_activation_wildcards ON PLT_TELEMETRY_ACTIVATION (
    telemetry_type, tenant_id, enabled, object_name
);

-- Sampling rate queries
CREATE INDEX idx_plt_activation_sampling ON PLT_TELEMETRY_ACTIVATION (
    sampling_rate, enabled
)

-- =============================================================================
-- 4. AUDIT TRIGGER - CRITICAL: Always sends to Loki
-- =============================================================================

CREATE OR REPLACE TRIGGER TRG_PLT_ACTIVATION_AUDIT
    AFTER INSERT OR UPDATE OR DELETE ON PLT_TELEMETRY_ACTIVATION
    FOR EACH ROW
DECLARE
    l_operation VARCHAR2(10);
    l_audit_json VARCHAR2(4000);
    l_session_info VARCHAR2(500);
BEGIN
    -- Determine operation
    l_operation := CASE 
        WHEN INSERTING THEN 'INSERT'
        WHEN UPDATING THEN 'UPDATE'
        ELSE 'DELETE'
    END;
    
    -- Gather session context
    l_session_info := 'Host:' || SYS_CONTEXT('USERENV', 'HOST') || 
                     '|IP:' || SYS_CONTEXT('USERENV', 'IP_ADDRESS') ||
                     '|Module:' || SYS_CONTEXT('USERENV', 'MODULE');
    
    -- Insert audit record
    INSERT INTO PLT_ACTIVATION_AUDIT (
        activation_id,
        operation_type,
        telemetry_type,
        object_name,
        tenant_id,
        old_enabled,
        new_enabled,
        old_sampling_rate,
        new_sampling_rate,
        old_enabled_to,
        new_enabled_to,
        changed_by,
        session_info
    ) VALUES (
        COALESCE(:NEW.activation_id, :OLD.activation_id),
        l_operation,
        COALESCE(:NEW.telemetry_type, :OLD.telemetry_type),
        COALESCE(:NEW.object_name, :OLD.object_name),
        COALESCE(:NEW.tenant_id, :OLD.tenant_id),
        :OLD.enabled,
        :NEW.enabled,
        :OLD.sampling_rate,
        :NEW.sampling_rate,
        :OLD.enabled_time_to,
        :NEW.enabled_time_to,
        SYS_CONTEXT('USERENV', 'OS_USER'),
        l_session_info
    );
    
    -- Build JSON for immediate Loki export
    l_audit_json := '{'
        || '"severity":"WARN",'
        || '"message":"PLTelemetry activation changed",'
        || '"timestamp":"' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') || '",'
        || '"attributes":{'
            || '"audit.operation":"' || l_operation || '",'
            || '"audit.object_name":"' || REPLACE(COALESCE(:NEW.object_name, :OLD.object_name), '"', '\"') || '",'
            || '"audit.telemetry_type":"' || COALESCE(:NEW.telemetry_type, :OLD.telemetry_type) || '",'
            || '"audit.tenant_id":"' || COALESCE(:NEW.tenant_id, :OLD.tenant_id) || '",'
            || '"audit.old_enabled":"' || NVL(:OLD.enabled, 'null') || '",'
            || '"audit.new_enabled":"' || NVL(:NEW.enabled, 'null') || '",'
            || '"audit.changed_by":"' || SYS_CONTEXT('USERENV', 'OS_USER') || '",'
            || '"audit.session_user":"' || SYS_CONTEXT('USERENV', 'SESSION_USER') || '",'
            || '"audit.host":"' || SYS_CONTEXT('USERENV', 'HOST') || '",'
            || '"system.bypass_activation":"true"'
        || '}'
    || '}';
    
    -- BYPASS all activation checks - send directly to Loki via OTLP Bridge
    -- This is the ONLY exception to activation rules
    BEGIN
        PLT_OTLP_BRIDGE.send_log_otlp(l_audit_json);
    EXCEPTION
        WHEN OTHERS THEN
            -- Never fail the original transaction due to audit logging
            NULL;
    END;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Never fail the original transaction due to audit trigger
        NULL;
END;
/

-- =============================================================================
-- 5. ROW-LEVEL TRIGGERS FOR METADATA
-- =============================================================================

CREATE OR REPLACE TRIGGER TRG_PLT_ACTIVATION_META
    BEFORE INSERT OR UPDATE ON PLT_TELEMETRY_ACTIVATION
    FOR EACH ROW
BEGIN
    -- Set creation metadata
    IF INSERTING THEN
        :NEW.created_date := SYSTIMESTAMP;
        :NEW.created_by := SYS_CONTEXT('USERENV', 'OS_USER');
    END IF;
    
    -- Always update modification metadata
    :NEW.updated_date := SYSTIMESTAMP;
    :NEW.updated_by := SYS_CONTEXT('USERENV', 'OS_USER');
    
    -- Validate time ranges
    IF :NEW.enabled_time_to IS NOT NULL AND :NEW.enabled_time_to <= :NEW.enabled_time_from THEN
        RAISE_APPLICATION_ERROR(-20001, 'enabled_time_to must be after enabled_time_from');
    END IF;
    
    -- Set default log level for LOG telemetry
    IF :NEW.telemetry_type = 'LOG' AND :NEW.log_level IS NULL THEN
        :NEW.log_level := 'INFO';
    END IF;
    
    -- Clear log_level for non-LOG telemetry
    IF :NEW.telemetry_type != 'LOG' THEN
        :NEW.log_level := NULL;
    END IF;
END;
/

-- =============================================================================
-- 6. CLEANUP JOB SCHEDULER
-- =============================================================================

-- Drop existing job if it exists
BEGIN
    DBMS_SCHEDULER.DROP_JOB('PLT_ACTIVATION_CLEANUP', TRUE);
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

-- Create cleanup job
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PLT_ACTIVATION_CLEANUP',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN PLT_ACTIVATION_MANAGER.cleanup_expired_activations(); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=5', -- Every 5 minutes
        enabled         => TRUE,
        comments        => 'Cleanup expired PLTelemetry activations'
    );
    
    DBMS_OUTPUT.PUT_LINE('✅ PLT_ACTIVATION_CLEANUP job created successfully');
END;
/

-- =============================================================================
-- 7. INITIAL DATA - Example configurations
-- =============================================================================

-- Universal activation records for PLTelemetry
-- This enables ALL telemetry for ALL tenants by default

-- Enable all TRACE telemetry
INSERT INTO PLT_TELEMETRY_ACTIVATION (
    TELEMETRY_TYPE,
    OBJECT_NAME,
    TENANT_ID,
    ENABLED,
    ENABLED_TIME_FROM,
    ENABLED_TIME_TO,
    LOG_LEVEL,
    SAMPLING_RATE,
    CREATED_BY,
    CREATED_DATE,
    UPDATED_BY,
    UPDATED_DATE
) VALUES (
    'TRACE',
    '*',              -- All objects
    'ALL',            -- All tenants
    'Y',
    SYSTIMESTAMP,
    NULL,             -- Never expires
    NULL,             -- Not applicable for TRACE
    1.0,              -- 100% sampling
    'system',
    SYSTIMESTAMP,
    'system',
    SYSTIMESTAMP
);

-- Enable all LOG telemetry (DEBUG level and above)
INSERT INTO PLT_TELEMETRY_ACTIVATION (
    TELEMETRY_TYPE,
    OBJECT_NAME,
    TENANT_ID,
    ENABLED,
    ENABLED_TIME_FROM,
    ENABLED_TIME_TO,
    LOG_LEVEL,
    SAMPLING_RATE,
    CREATED_BY,
    CREATED_DATE,
    UPDATED_BY,
    UPDATED_DATE
) VALUES (
    'LOG',
    '*',              -- All objects
    'ALL',            -- All tenants
    'Y',
    SYSTIMESTAMP,
    NULL,             -- Never expires
    'DEBUG',          -- Capture everything from DEBUG level up
    1.0,              -- 100% sampling
    'system',
    SYSTIMESTAMP,
    'system',
    SYSTIMESTAMP
);

-- Enable all METRIC telemetry
INSERT INTO PLT_TELEMETRY_ACTIVATION (
    TELEMETRY_TYPE,
    OBJECT_NAME,
    TENANT_ID,
    ENABLED,
    ENABLED_TIME_FROM,
    ENABLED_TIME_TO,
    LOG_LEVEL,
    SAMPLING_RATE,
    CREATED_BY,
    CREATED_DATE,
    UPDATED_BY,
    UPDATED_DATE
) VALUES (
    'METRIC',
    '*',              -- All objects
    'ALL',            -- All tenants
    'Y',
    SYSTIMESTAMP,
    NULL,             -- Never expires
    NULL,             -- Not applicable for METRIC
    1.0,              -- 100% sampling
    'system',
    SYSTIMESTAMP,
    'system',
    SYSTIMESTAMP
);

COMMIT;

-- Verify the records were created
SELECT 
    TELEMETRY_TYPE,
    OBJECT_NAME,
    TENANT_ID,
    ENABLED,
    LOG_LEVEL,
    SAMPLING_RATE,
    CREATED_BY
FROM PLT_TELEMETRY_ACTIVATION
WHERE TENANT_ID = 'ALL'
  AND OBJECT_NAME = '*'
ORDER BY TELEMETRY_TYPE;