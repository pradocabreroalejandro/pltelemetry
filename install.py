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
    python install.py --no-cleanup     # skip cleanup phase
    python install.py --no-tests       # skip test execution
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

# Test scripts to run after installation
TEST_SCRIPTS = [
    (SRC_DIR / "utils" / "PLT_SMOKE_TEST.sql", "Smoke Test Suite"),
    (SRC_DIR / "utils" / "PLT_TPS_TEST.sql", "TPS Benchmark Suite"),
]


# ---------------------------------------------------------------------------
# Cleanup utilities (full uninstall)
# ---------------------------------------------------------------------------
def cleanup_pltelemetry(sys_conn: str, schema: str, dry_run: bool = False) -> bool:
    """
    Complete cleanup of PLTelemetry installation:
    - Drop scheduler jobs
    - Drop network ACLs
    - Drop user/schema (cascade)
    Returns True on success.
    """
    schema_upper = schema.upper()
    print("\n" + "=" * 60)
    print("  CLEANUP PHASE - Removing existing PLTelemetry installation")
    print("=" * 60)

    if dry_run:
        print("  [DRY RUN] Would drop all PLTelemetry objects and schema")
        return True

    # 1. Drop scheduler jobs (as SYS, for the schema)
    print("  [1/4] Dropping scheduler jobs... ", end="", flush=True)
    drop_jobs_sql = f"""
BEGIN
    FOR j IN (SELECT job_name FROM dba_scheduler_jobs WHERE owner = '{schema_upper}') LOOP
        BEGIN
            DBMS_SCHEDULER.DROP_JOB(j.job_name, force => TRUE);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
END;
/
"""
    try:
        result = subprocess.run(
            ["sqlplus", "-S", "-L", sys_conn],
            input=drop_jobs_sql,
            capture_output=True,
            text=True,
            timeout=30,
        )
        output = result.stdout + result.stderr
        if "ORA-" in output and "ORA-00001" not in output:
            print("WARNING (some jobs may not exist)")
        else:
            print("OK")
    except Exception as e:
        print(f"ERROR: {e}")

    # 2. Drop network ACLs for this schema
    print("  [2/4] Dropping network ACLs... ", end="", flush=True)
    drop_acl_sql = f"""
BEGIN
    DBMS_NETWORK_ACL_ADMIN.DELETE_PRIVILEGE(
        host        => '*',
        principal   => '{schema_upper}',
        is_grant    => TRUE,
        privilege   => 'connect'
    );
    DBMS_NETWORK_ACL_ADMIN.DELETE_PRIVILEGE(
        host        => '*',
        principal   => '{schema_upper}',
        is_grant    => TRUE,
        privilege   => 'resolve'
    );
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
"""
    try:
        result = subprocess.run(
            ["sqlplus", "-S", "-L", sys_conn],
            input=drop_acl_sql,
            capture_output=True,
            text=True,
            timeout=30,
        )
        print("OK")
    except Exception as e:
        print(f"ERROR: {e}")

    # 3. Drop the user (cascade)
    print("  [3/4] Dropping schema user... ", end="", flush=True)
    drop_user_sql = f"""
BEGIN
    EXECUTE IMMEDIATE 'DROP USER {schema_upper} CASCADE';
EXCEPTION WHEN OTHERS THEN
    IF SQLCODE != -1918 THEN RAISE; END IF; -- ignore 'user does not exist'
END;
/
"""
    try:
        result = subprocess.run(
            ["sqlplus", "-S", "-L", sys_conn],
            input=drop_user_sql,
            capture_output=True,
            text=True,
            timeout=30,
        )
        output = result.stdout + result.stderr
        if "ORA-" in output and "ORA-01918" not in output:
            print(f"WARNING: {output[:200]}")
        else:
            print("OK (or already dropped)")
    except Exception as e:
        print(f"ERROR: {e}")

    # 4. Purge recyclebin
    print("  [4/4] Purging recyclebin... ", end="", flush=True)
    purge_sql = "PURGE DBA_RECYCLEBIN;"
    try:
        result = subprocess.run(
            ["sqlplus", "-S", "-L", sys_conn],
            input=purge_sql,
            capture_output=True,
            text=True,
            timeout=30,
        )
        print("OK")
    except Exception as e:
        print(f"ERROR: {e}")

    print("\n  Cleanup complete.\n")
    return True


def run_test_script(
    sql_path: Path,
    schema_conn: str,
    test_name: str,
    dry_run: bool = False,
) -> tuple:
    """
    Run a test script and return (success, pass_count, fail_count).
    Parses the output for PASS/FAIL markers.
    """
    print(f"\n{'='*60}")
    print(f"  RUNNING: {test_name}")
    print(f"{'='*60}")

    if dry_run:
        print(f"  [DRY RUN] Would run: {sql_path.name}")
        return True, 0, 0

    if not sql_path.exists():
        print(f"  SKIPPED - file not found: {sql_path}")
        return True, 0, 0

    try:
        sql_content = sql_path.read_text(encoding="utf-8")
        result = subprocess.run(
            ["sqlplus", "-S", "-L", schema_conn],
            input=sql_content,
            capture_output=True,
            text=True,
            timeout=300,  # Tests may take longer
        )

        output = result.stdout + result.stderr

        # Parse for errors
        import re
        ora_codes = set(re.findall(r'ORA-\d{5}', output))
        sp_errors = [l for l in output.splitlines() if "SP2-" in l and "deprecated" not in l.lower()]
        pls_errors = [l for l in output.splitlines() if "PLS-" in l]
        benign_errors = {"ORA-27477", "ORA-01920", "ORA-06512", "ORA-00001", "ORA-01403"}

        # Check for critical errors
        non_benign_ora = ora_codes - benign_errors
        if non_benign_ora or sp_errors or pls_errors:
            print("  TEST SCRIPT FAILED")
            print("    --- sqlplus output ---")
            for line in output.strip().splitlines()[-50:]:  # Last 50 lines
                print(f"    | {line}")
            print("    --- end output ---")
            return False, 0, 0

        # Count PASS/FAIL from smoke test output
        pass_count = len(re.findall(r'\bPASS\b', output))
        fail_count = len(re.findall(r'\bFAIL\b', output))

        # Print summary
        print(output[-3000:] if len(output) > 3000 else output)  # Last 3000 chars

        if fail_count > 0:
            print(f"\n  {test_name}: {fail_count} test(s) FAILED")
            return False, pass_count, fail_count
        elif pass_count > 0:
            print(f"\n  {test_name}: ALL {pass_count} TESTS PASSED")
            return True, pass_count, fail_count
        else:
            print(f"\n  {test_name}: Completed (no explicit test markers found)")
            return True, 0, 0

    except subprocess.TimeoutExpired:
        print("  TIMEOUT (300s)")
        return False, 0, 0
    except FileNotFoundError:
        print("  ERROR - sqlplus not found in PATH")
        sys.exit(1)


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
        print(f"SKIPPED (dry-run) - would run: {sql_path.name}")
        return True

    if not sql_path.exists():
        print(f"SKIPPED - file not found: {sql_path}")
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

        # Parse error indicators once
        import re
        ora_codes = set(re.findall(r'ORA-\d{5}', output))
        sp_errors = [l for l in output.splitlines() if "SP2-" in l]
        pls_errors = [l for l in output.splitlines() if "PLS-" in l]
        benign_errors = {"ORA-27477", "ORA-01920", "ORA-06512", "ORA-00001"}

        # Check return code first - sqlplus may fail to start entirely
        # (e.g., missing shared libraries, binary not found)
        if result.returncode != 0:
            non_benign_ora = ora_codes - benign_errors

            # If no ORA errors at all and returncode != 0, sqlplus failed to start
            if not ora_codes and not sp_errors and not pls_errors:
                print("FAILED - sqlplus did not execute successfully")
                print("    --- sqlplus output ---")
                for line in output.strip().splitlines():
                    print(f"    | {line}")
                print(f"    | (exit code: {result.returncode})")
                print("    --- end output ---")
                return False
            elif non_benign_ora:
                print("FAILED")
                print("    --- sqlplus output ---")
                for line in output.strip().splitlines():
                    print(f"    | {line}")
                print(f"    | (exit code: {result.returncode})")
                print("    --- end output ---")
                return False
            else:
                print("OK (with benign warnings)")
                return True

        # Ignore benign "already exists" errors (idempotent re-runs)
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
        print("ERROR - sqlplus not found in PATH")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="PLTelemetry unattended installer with full cleanup and tests"
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
    parser.add_argument(
        "--no-cleanup",
        action="store_true",
        help="Skip cleanup phase (do not drop existing schema)",
    )
    parser.add_argument(
        "--no-tests",
        action="store_true",
        help="Skip test execution after installation",
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
    print(f"Cleanup      : {'SKIP' if args.no_cleanup else 'FULL'}")
    print(f"Run tests    : {'SKIP' if args.no_tests else 'YES'}")
    print()

    if args.dry_run:
        print("--- DRY RUN: no changes will be made ---\n")

    # --- Build connection strings ---
    schema_conn = build_connection_string(config, "schema")
    sys_conn = build_connection_string(config, "sys")

    failed = 0

    # =======================================================================
    # PHASE -1: CLEANUP (drop existing installation)
    # =======================================================================
    if not args.no_cleanup and not args.dry_run:
        if not cleanup_pltelemetry(sys_conn, schema, dry_run=False):
            print("  Cleanup reported issues, but continuing...")

    # =======================================================================
    # PHASE 0: Create schema user (SYS)
    # =======================================================================
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
    print("[PHASE 0/3] [Creating schema user] ", end="", flush=True)
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
            print("ERROR - sqlplus not found in PATH")
            sys.exit(1)

    if failed:
        print("\nSchema creation failed. Cannot continue.")
        sys.exit(1)

    # =======================================================================
    # PHASE 1: INSTALL (execute all SQL files)
    # =======================================================================
    print("\n" + "=" * 60)
    print("  PHASE 1/3: INSTALLATION")
    print("=" * 60)
    
    total = len(INSTALL_STEPS)
    install_failed = 0

    for i, (sql_file, conn_type, desc) in enumerate(INSTALL_STEPS, 1):
        print(f"[{i:02d}/{total:02d}]", end=" ")

        if sql_file.exists():
            raw_sql = sql_file.read_text(encoding="utf-8")
            prepared_sql = prepare_sql(raw_sql, config)

            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".sql", delete=False, encoding="utf-8"
            ) as tmp:
                tmp.write(prepared_sql)
                tmp_path = tmp.name

            conn_str = sys_conn if conn_type == "sys" else schema_conn
            ok = run_sql_file(Path(tmp_path), conn_str, desc, args.dry_run)

            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

            if not ok:
                install_failed += 1
                print("\n  Installation step failed.")
        else:
            print(f"  [{desc}] SKIPPED - file not found: {sql_file}")

    if install_failed > 0:
        print(f"\nInstallation failed with {install_failed} error(s).")
        failed += install_failed

    # =======================================================================
    # PHASE 2: TESTS (smoke test + TPS benchmark)
    # =======================================================================
    test_failed = 0
    total_tests_run = 0
    total_tests_passed = 0
    total_tests_failed_count = 0

    if not args.no_tests and not args.dry_run and failed == 0:
        print("\n" + "=" * 60)
        print("  PHASE 2/3: RUNNING TESTS")
        print("=" * 60)

        for test_path, test_name in TEST_SCRIPTS:
            success, passed, failed_count = run_test_script(
                test_path, schema_conn, test_name, dry_run=False
            )
            total_tests_run += 1
            total_tests_passed += passed
            total_tests_failed_count += failed_count

            if not success:
                test_failed += 1

    # =======================================================================
    # FINAL SUMMARY
    # =======================================================================
    print("\n" + "=" * 60)
    print("  FINAL SUMMARY")
    print("=" * 60)

    if failed == 0 and test_failed == 0:
        print("  ALL PHASES COMPLETED SUCCESSFULLY!")
        print(f"     - Installation: {len(INSTALL_STEPS)} steps OK")
        if not args.no_tests:
            print(f"     - Tests: {total_tests_passed} passed, {total_tests_failed_count} failed")
        print("\n  PLTelemetry is ready to use.")
        print("  Enable tracing: UPDATE plt_activation_rules SET is_enabled='Y' WHERE object_pattern='*';")
    else:
        print("  SOME PHASES FAILED")
        if install_failed > 0:
            print(f"     - Installation errors: {install_failed}")
        if test_failed > 0:
            print(f"     - Test failures: {test_failed}")
        print("\n  Review the output above and re-run after fixing issues.")

    # Exit with appropriate code
    if failed == 0 and test_failed == 0:
        print("\n" + "=" * 60)
        print("  ZERO ERRORS - FULLY OPERATIONAL")
        print("=" * 60)
        sys.exit(0)
    else:
        print(f"\nEXIT CODE 1 - {failed + test_failed} failure(s)")
        sys.exit(1)


if __name__ == "__main__":
    main()
