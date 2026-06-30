#!/usr/bin/env python3
"""
PLTelemetry — Unattended Installation Script
============================================
Reads install.yaml and executes all SQL files in the correct order,
replacing placeholders with user-provided values.

Usage:
    python install.py                  # uses install.yaml in same directory
    python install.py --config prod.yaml
    python install.py --dry-run        # validate config + show what would run
"""

import argparse
import getpass
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Try to load YAML (pyyaml), fall back to a minimal parser
# ---------------------------------------------------------------------------
try:
    import yaml as _yaml
    HAS_YAML = True
except ImportError:
    _yaml = None  # type: ignore
    HAS_YAML = False


# ---------------------------------------------------------------------------
# Minimal YAML parser (only what we need, no external deps)
# ---------------------------------------------------------------------------
def _parse_simple_yaml(text: str) -> dict:
    """Parse a flat-ish YAML with only dicts, lists, strings, bools, ints."""
    result: dict = {}
    current_path: list = []
    lines = text.splitlines()

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = len(line) - len(line.lstrip())
        depth = indent // 2

        # Trim path to current depth
        current_path = current_path[:depth]

        if stripped.startswith("- "):
            # List item
            value = stripped[2:].strip().strip('"').strip("'")
            parent = result
            for key in current_path:
                parent = parent.setdefault(key, {})
            list_key = current_path[-1] if current_path else None
            if list_key and list_key in parent:
                if not isinstance(parent[list_key], list):
                    parent[list_key] = []
                parent[list_key].append(value)
            continue

        if ":" in stripped:
            key, _, val = stripped.partition(":")
            key = key.strip()
            val = val.strip()

            if val == "":
                current_path.append(key)
            else:
                val = val.strip('"').strip("'")
                if val.lower() == "true":
                    val = True
                elif val.lower() == "false":
                    val = False
                elif val.isdigit():
                    val = int(val)

                parent = result
                for k in current_path:
                    parent = parent.setdefault(k, {})
                parent[key] = val

    return result


def load_config(path: str) -> dict:
    """Load YAML config, with or without pyyaml."""
    with open(path, "r") as f:
        raw = f.read()

    if HAS_YAML:
        return _yaml.safe_load(raw)  # type: ignore[union-attr]
    else:
        return _parse_simple_yaml(raw)


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
SRC_DIR = BASE_DIR / "src"
DDL_DIR = SRC_DIR / "ddl"
PKG_DIR = SRC_DIR / "packages"
DATA_DIR = SRC_DIR / "data"

# Ordered list of (file, connection_type, description)
# connection_type: "schema" or "sys"
INSTALL_STEPS = [
    # --- Phase 1: Types & Tables (schema) ---
    (DDL_DIR / "00_types.sql", "schema", "Creating object types"),
    (DDL_DIR / "01_tables.sql", "schema", "Creating tables & queue topology"),

    # --- Phase 2: Sys grants (SYS) ---
    (DDL_DIR / "03_permissions_sys.sql", "sys", "Granting system permissions (V$ views, ACLs)"),

    # --- Phase 3: Seed data (schema) ---
    (DDL_DIR / "02_data.sql", "schema", "Seeding default configuration"),

    # --- Phase 4: Package specs ---
    (PKG_DIR / "PLTelemetry.pks", "schema", "PLTelemetry spec"),
    (PKG_DIR / "PLT_CONFIGURATION.pks", "schema", "PLT_CONFIGURATION spec"),
    (PKG_DIR / "PLT_OTLP_BRIDGE.pks", "schema", "PLT_OTLP_BRIDGE spec"),
    (PKG_DIR / "PLT_DB_METRIC_READER.pks", "schema", "PLT_DB_METRIC_READER spec"),
    (PKG_DIR / "PLT_DB_MONITOR_LOGIC.pks", "schema", "PLT_DB_MONITOR_LOGIC spec"),
    (PKG_DIR / "PLT_QUEUE_MANAGER.pks", "schema", "PLT_QUEUE_MANAGER spec"),
    (PKG_DIR / "PLT_ACTIVATION_MANAGER.pks", "schema", "PLT_ACTIVATION_MANAGER spec"),

    # --- Phase 5: Package bodies ---
    (PKG_DIR / "PLTelemetry.pkb", "schema", "PLTelemetry body"),
    (PKG_DIR / "PLT_CONFIGURATION.pkb", "schema", "PLT_CONFIGURATION body"),
    (PKG_DIR / "PLT_OTLP_BRIDGE.pkb", "schema", "PLT_OTLP_BRIDGE body"),
    (PKG_DIR / "PLT_DB_METRIC_READER.pkb", "schema", "PLT_DB_METRIC_READER body"),
    (PKG_DIR / "PLT_DB_MONITOR_LOGIC.pkb", "schema", "PLT_DB_MONITOR_LOGIC body"),
    (PKG_DIR / "PLT_QUEUE_MANAGER.pkb", "schema", "PLT_QUEUE_MANAGER body"),
    (PKG_DIR / "PLT_ACTIVATION_MANAGER.pkb", "schema", "PLT_ACTIVATION_MANAGER body"),

    # --- Phase 6: Standalone procedures ---
    (PKG_DIR / "check_agent_health_proc.sql", "schema", "Agent health check procedure"),

    # --- Phase 7: Jobs ---
    (DDL_DIR / "04_jobs.sql", "schema", "Creating scheduler jobs"),
    (DDL_DIR / "06_queue_config.sql", "schema", "Configuring queue thresholds"),
    (DDL_DIR / "07_queue_maintenace_job.sql", "schema", "Creating queue maintenance job"),

    # --- Phase 8: Default config data ---
    (DATA_DIR / "01_default_config.sql", "schema", "Seeding default pulse config"),
]


# ---------------------------------------------------------------------------
# SQL placeholder replacement
# ---------------------------------------------------------------------------
def prepare_sql(sql_content: str, config: dict) -> str:
    """Replace placeholders in SQL with values from config."""
    conn = config["connection"]
    schema = conn["schema"].upper()

    sql = sql_content

    # Replace hardcoded schema name
    sql = sql.replace("PLTELEMETRY", schema)
    sql = sql.replace("pltelemetry", schema.lower())

    # OTLP config replacements (for 02_data.sql)
    otlp = config.get("otlp", {})
    if otlp.get("endpoint_url"):
        sql = sql.replace(
            "'http://otel-collector:4318'",
            f"'{otlp['endpoint_url']}'"
        )
    if otlp.get("service_name"):
        sql = sql.replace(
            "'oracle-db-prod'",
            f"'{otlp['service_name']}'"
        )
    if otlp.get("environment"):
        sql = sql.replace(
            "'production'",
            f"'{otlp['environment']}'"
        )
    if otlp.get("timeout_ms"):
        sql = sql.replace("'5000'", f"'{otlp['timeout_ms']}'")

    # Debug mode
    features = config.get("features", {})
    debug_val = "TRUE" if features.get("debug_mode") else "FALSE"
    sql = sql.replace("'FALSE'", f"'{debug_val}'", 1)

    # Queue config
    queue = config.get("queue", {})
    if queue.get("max_size_mb"):
        sql = sql.replace("'500'", f"'{queue['max_size_mb']}'", 1)
    if queue.get("force_rotation_hours"):
        sql = sql.replace("'24'", f"'{queue['force_rotation_hours']}'", 1)

    return sql


# ---------------------------------------------------------------------------
# SQL*Plus execution
# ---------------------------------------------------------------------------
def build_connection_string(config: dict, conn_type: str) -> str:
    """Build sqlplus connection string."""
    conn = config["connection"]
    host = conn.get("host", "localhost")
    port = conn.get("port", 1521)
    service = conn.get("service_name", "XEPDB1")

    if conn_type == "sys":
        user = "SYS"
        password = conn.get("sys_password", "")
    else:
        user = conn["schema"]
        password = conn.get("schema_password", "")

    if not password:
        prompt = "SYS" if conn_type == "sys" else conn["schema"]
        password = getpass.getpass(f"Password for {prompt}: ")

    as_sysdba = " AS SYSDBA" if conn_type == "sys" else ""
    return f"{user}/{password}@{host}:{port}/{service}{as_sysdba}"


def run_sql_file(
    sql_path: Path,
    conn_string: str,
    description: str,
    dry_run: bool = False,
) -> bool:
    """Execute a SQL file via SQL*Plus. Returns True on success."""
    print(f"  [{description}] ", end="", flush=True)

    if dry_run:
        print(f"SKIPPED (dry-run) — would run: {sql_path.name}")
        return True

    if not sql_path.exists():
        print(f"SKIPPED — file not found: {sql_path}")
        return True

    try:
        # Read SQL content, prepend SET DEFINE OFF (avoid & substitution),
        # and append EXIT so sqlplus terminates
        sql_content = "SET DEFINE OFF;\n" + sql_path.read_text(encoding="utf-8") + "\nEXIT;\n"
        result = subprocess.run(
            ["sqlplus", "-S", "-L", conn_string],
            input=sql_content,
            capture_output=True,
            text=True,
            timeout=120,
        )

        output = result.stdout + result.stderr

        # Ignore benign "already exists" errors (idempotent re-runs)
        benign_errors = {"ORA-27477", "ORA-01920", "ORA-06512"}
        import re
        ora_codes = set(re.findall(r'ORA-\d{5}', output))
        sp_errors = [l for l in output.splitlines() if "SP2-" in l]
        pls_errors = [l for l in output.splitlines() if "PLS-" in l]
        real_errors = (ora_codes - benign_errors) or sp_errors or pls_errors

        if real_errors:
            print("FAILED")
            print("    --- sqlplus output ---")
            for line in output.strip().splitlines():
                print(f"    | {line}")
            print("    --- end output ---")
            return False
        else:
            print("OK")
            return True


    except subprocess.TimeoutExpired:
        print("TIMEOUT (120s)")
        return False
    except FileNotFoundError:
        print("ERROR — sqlplus not found in PATH")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="PLTelemetry unattended installer"
    )
    parser.add_argument(
        "--config", "-c",
        default="install.yaml",
        help="Path to YAML config file (default: install.yaml)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate config and show what would be installed",
    )
    args = parser.parse_args()

    # --- Load config ---
    config_path = BASE_DIR / args.config
    if not config_path.exists():
        print(f"ERROR: Config file not found: {config_path}")
        print("Copy install_template.yaml to install.yaml, edit it, and try again.")
        sys.exit(1)

    print(f"Loading config: {config_path}")
    config = load_config(str(config_path))

    # --- Validate ---
    conn = config.get("connection", {})
    schema = conn.get("schema", "")
    if not schema:
        print("ERROR: connection.schema is required in config")
        sys.exit(1)

    print(f"Schema       : {schema}")
    print(f"Host         : {conn.get('host', 'localhost')}:{conn.get('port', 1521)}/{conn.get('service_name', 'XEPDB1')}")
    print(f"OTLP endpoint: {config.get('otlp', {}).get('endpoint_url', 'N/A')}")
    print(f"Dry run      : {args.dry_run}")
    print()

    if args.dry_run:
        print("--- DRY RUN: no changes will be made ---\n")

    # --- Build connection strings ---
    schema_conn = build_connection_string(config, "schema")
    sys_conn = build_connection_string(config, "sys")

    # --- Phase 0: Create schema user (SYS) ---
    failed = 0
    schema_upper = schema.upper()
    schema_pwd = conn.get("schema_password", "oracle")

    create_user_sql = f"""
CREATE USER {schema_upper} IDENTIFIED BY "{schema_pwd}";
GRANT CONNECT, RESOURCE, UNLIMITED TABLESPACE TO {schema_upper};
GRANT CREATE TABLE, CREATE PROCEDURE, CREATE TYPE, CREATE JOB, CREATE SYNONYM, CREATE VIEW TO {schema_upper};
GRANT EXECUTE ON DBMS_SCHEDULER TO {schema_upper};
GRANT EXECUTE ON DBMS_NETWORK_ACL_ADMIN TO {schema_upper};
GRANT EXECUTE ON UTL_HTTP TO {schema_upper};
"""
    print("[00/23]   [Creating schema user] ", end="", flush=True)
    if args.dry_run:
        print("SKIPPED (dry-run)")
    else:
        try:
            result = subprocess.run(
                ["sqlplus", "-S", "-L", sys_conn],
                input=create_user_sql,
                capture_output=True,
                text=True,
                timeout=30,
            )
            output = result.stdout + result.stderr
            if "ORA-" in output:
                # ORA-01920 user already exists is OK
                if "ORA-01920" in output:
                    print("OK (already exists)")
                else:
                    print("FAILED")
                    for line in output.strip().splitlines():
                        print(f"    | {line}")
                    failed += 1
            else:
                print("OK")
        except subprocess.TimeoutExpired:
            print("TIMEOUT")
            failed += 1
        except FileNotFoundError:
            print("ERROR — sqlplus not found in PATH")
            sys.exit(1)

    if failed:
        print("\n  ⚠ Schema creation failed. Cannot continue.")
        sys.exit(1)

    # --- Execute file-based steps ---
    total = len(INSTALL_STEPS)

    for i, (sql_file, conn_type, desc) in enumerate(INSTALL_STEPS, 1):
        print(f"[{i:02d}/{total:02d}]", end=" ")

        if sql_file.exists():
            raw_sql = sql_file.read_text(encoding="utf-8")
            prepared_sql = prepare_sql(raw_sql, config)

            # Write prepared SQL to temp file
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".sql", delete=False, encoding="utf-8"
            ) as tmp:
                tmp.write(prepared_sql)
                tmp_path = tmp.name

            conn_str = sys_conn if conn_type == "sys" else schema_conn
            ok = run_sql_file(Path(tmp_path), conn_str, desc, args.dry_run)

            # Cleanup temp file
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

            if not ok:
                failed += 1
                print("\n  ⚠ Installation step failed. You may re-run the script to retry.")
        else:
            print(f"  [{desc}] SKIPPED — file not found: {sql_file}")

    # --- Summary ---
    print()
    if failed == 0:
        print("=" * 60)
        print("  ✅ PLTelemetry installation complete!")
        print("=" * 60)
        print()
        print("Next steps:")
        print("  1. Verify: SELECT object_name, object_type FROM user_objects")
        print("     WHERE object_name LIKE 'PLT%' ORDER BY object_type;")
        print("  2. Check jobs: SELECT job_name, state FROM user_scheduler_jobs")
        print("     WHERE job_name LIKE 'PLT%';")
        print("  3. Enable tracing for your objects:")
        print("     UPDATE plt_activation_rules SET is_enabled='Y', sample_rate=1")
        print("     WHERE object_pattern='*';")
        print("     COMMIT;")
    else:
        print(f"  ⚠ {failed} step(s) failed. Review output above.")
        print("  The script is idempotent — you can fix issues and re-run.")

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
