--drop table heartbeat_services;

CREATE TABLE heartbeat_criticality_levels (
    criticality_code VARCHAR2(10) PRIMARY KEY,
    description VARCHAR2(100),
    check_interval_minutes NUMBER NOT NULL,
    escalation_multiplier NUMBER DEFAULT 0.5, -- Para reducir interval en fallos
    max_escalation_failures NUMBER DEFAULT 3
);

CREATE TABLE heartbeat_services (
    service_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_name VARCHAR2(50) UNIQUE NOT NULL,
    service_description VARCHAR2(200),
    endpoint_url VARCHAR2(300) NOT NULL,
    criticality_code VARCHAR2(10) REFERENCES heartbeat_criticality_levels(criticality_code),
    timeout_seconds NUMBER DEFAULT 10,
    is_enabled NUMBER(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP,
    last_check_time TIMESTAMP,
    consecutive_failures NUMBER DEFAULT 0
);