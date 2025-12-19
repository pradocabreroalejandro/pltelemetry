-- install.sql
SET DEFINE OFF;
SET ECHO OFF;
SET VERIFY OFF;
SET SERVEROUTPUT ON SIZE 1000000;

PROMPT
PROMPT =====================================================================
PROMPT  PLTelemetry V2 (Lean Edition) - Installation
PROMPT =====================================================================
PROMPT

-- 1. Database Objects (DDL)
PROMPT [1/4] Creating Database Objects...
@src/ddl/01_tables.sql

-- 2. Object Types
PROMPT [2/4] Creating Object Types...
@src/types/01_pulse_config_type.sql

-- 3. PLTelemetry Core Package
PROMPT [3/4] Installing PLTelemetry Core...
--@src/packages/PLTelemetry.pks
--@src/packages/PLTelemetry.pkb

-- Nota: Bridge comentado hasta que lo refactoricemos
-- @src/packages/PLT_OTLP_BRIDGE.pks
-- @src/packages/PLT_OTLP_BRIDGE.pkb

-- 4. Data Seeding
PROMPT [4/4] Configuring Defaults...
@src/data/01_default_config.sql

PROMPT
PROMPT =====================================================================
PROMPT  Installation Complete! 🚀
PROMPT  Time to trace something...
PROMPT =====================================================================
PROMPT