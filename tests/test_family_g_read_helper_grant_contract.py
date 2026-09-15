"""Static S9(a) Family G read-helper grant contract gate.

The corrective migration is prepared but not applied. This offline gate proves
the authored migration keeps the exact boundaries that must hold when it is
activated: authenticated gains EXECUTE on the three Family G read helpers,
anon and public gain nothing, QG-38 is inverted rather than deleted, and the
migration verifies the whole defect class before it commits. It is not a
substitute for database-runtime or authenticated-browser verification.
"""
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "supabase" / "migrations"
SQL = (MIGRATIONS / "20260915180000_s9_1_fix_family_g_read_helper_execute.sql").read_text(encoding="utf-8")
ORIGINAL = (MIGRATIONS / "20260909105454_s9_1_family_g_quote_schema.sql").read_text(encoding="utf-8")
BATCH_CORE = (MIGRATIONS / "20260906044153_s6_1_family_f_batch_core.sql").read_text(encoding="utf-8")

HELPERS = ("can_read_quote_family", "can_read_quote_revision", "can_read_quote_item")
LOWER = SQL.lower()
# Executable SQL only. The migration's header deliberately explains SECURITY
# DEFINER and anon/public in prose; authority checks must not match commentary.
CODE = "\n".join(line.split("--", 1)[0] for line in SQL.splitlines()).lower()

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


# The defect this migration corrects is real in the applied history.
check(all(f"revoke all on function app_private.{name}(bigint)" in ORIGINAL for name in HELPERS)
      and all(f"app_private.{name}(" in ORIGINAL.split("-- ═════════════════════════════════════════════════════════════════ policies")[1]
              for name in ("can_read_quote_family", "can_read_quote_revision", "can_read_quote_item")),
      "FG-GRANT-1 the applied schema both calls the helpers in policies and revokes them from authenticated")
check("grant execute on function app_private.can_read_batch(bigint) to authenticated;" in BATCH_CORE,
      "FG-GRANT-2 the can_read_batch precedent grants EXECUTE to authenticated")

# The correction grants exactly what RLS needs and nothing more.
for name in HELPERS:
    check(re.search(rf"grant execute on function app_private\.{name}\(bigint\)\s+to authenticated;", SQL) is not None,
          f"FG-GRANT-3 authenticated gains EXECUTE on app_private.{name}")
grant_lines = [line.strip() for line in CODE.splitlines()
               if line.strip().startswith("grant ")]
check(len(grant_lines) == 3 and all(line.endswith("to authenticated;") for line in grant_lines),
      "FG-GRANT-4 the migration issues exactly three grants, all to authenticated")
check(not re.search(r"\bgrant\b[^;]*\bto\s+(anon|public|service_role)\b", CODE),
      "FG-GRANT-5 anon, public and service_role gain nothing")
check("security definer" not in CODE and "create or replace function app_private" not in CODE
      and "create policy" not in CODE and "drop policy" not in CODE and "alter policy" not in CODE,
      "FG-GRANT-6 no helper body or policy is rewritten")
check(not re.search(r"\b(insert into|update public\.|delete from)\b", CODE),
      "FG-GRANT-7 the correction writes no data")

# QG-38 is inverted, not deleted, and the splice is guarded.
check("tests.quote_schema()'::regprocedure" in SQL and "pg_get_functiondef" in SQL,
      "FG-GRANT-8 the splice targets the live tests.quote_schema() definition")
check(SQL.count("raise exception 'expected exactly 1 QG-38") == 2,
      "FG-GRANT-9 both splice fragments must occur exactly once or the migration aborts")
check("'QG-38 app_private.%s is callable by authenticated" in SQL.replace("''", "'")
      and "still not by anon" in SQL,
      "FG-GRANT-10 the inverted QG-38 still refuses anon EXECUTE")
check("revoke all on function tests.quote_schema() from public, anon, authenticated;" in SQL,
      "FG-GRANT-11 the replaced suite stays unexecutable by browser roles")

# The migration proves the defect class before it commits.
check("pg_catalog.pg_policies" in SQL and "regexp_matches" in SQL
      and "has_function_privilege('authenticated', pr.oid, 'EXECUTE')" in SQL
      and "raise exception 'Family G SELECT policies call helpers authenticated cannot execute" in SQL,
      "FG-GRANT-12 every helper named in a Family G SELECT policy must be executable by authenticated")
check(all(table in SQL for table in (
          "quote_families", "quote_revisions", "calculation_snapshots", "quote_items",
          "quote_item_delivery_groups", "quote_workflow_events", "customer_outcome_events",
          "export_events", "export_parts")),
      "FG-GRANT-13 the structural proof covers all nine Family G tables")
check("raise exception 'anon must not be able to execute the Family G read helpers'" in SQL,
      "FG-GRANT-14 the structural proof also refuses anon EXECUTE")
check("prepared, not applied" in LOWER,
      "FG-GRANT-15 the migration states it is prepared and not applied")

# The splice, simulated against the QG-38 body as recorded in the applied
# history, must yield a truthful contract: authenticated POSITIVE, anon still
# NEGATIVE. A splice that deleted the probe, or also negated anon away, fails.
QG38_SOURCE = (MIGRATIONS / "20260909111611_s9_1_snapshot_freight_reference_integrity_tests.sql").read_text(encoding="utf-8")
FRAGMENTS = {
    name: re.search(rf"{name} text := '((?:[^']|'')*)';", SQL).group(1).replace("''", "'")
    for name in ("v_old1", "v_new1", "v_old2", "v_new2")
}
check(all(QG38_SOURCE.count(FRAGMENTS[old]) == 1 for old in ("v_old1", "v_old2")),
      "FG-GRANT-16 each splice fragment occurs exactly once in the recorded QG-38 body")
SPLICED = QG38_SOURCE.replace(FRAGMENTS["v_old1"], FRAGMENTS["v_new1"]).replace(FRAGMENTS["v_old2"], FRAGMENTS["v_new2"])
QG38_PROBE = re.search(r"return next ok\((.*?)format\('QG-38", SPLICED, re.S).group(1)
check("not pg_catalog.has_function_privilege('authenticated'" not in QG38_PROBE
      and "pg_catalog.has_function_privilege('authenticated', 'app_private.'||t||'(bigint)', 'EXECUTE')" in QG38_PROBE
      and "not pg_catalog.has_function_privilege('anon', 'app_private.'||t||'(bigint)', 'EXECUTE')" in QG38_PROBE,
      "FG-GRANT-17 the inverted QG-38 asserts authenticated CAN and anon CANNOT execute each helper")
check("service_role" not in CODE and "set role" not in CODE and "security definer" not in CODE
      and not re.search(r"\b(alter|create)\s+schema\b|pgrst\.db_schemas|grant usage on schema", CODE),
      "FG-GRANT-18 no service-role path, role switch, or API exposure of app_private is introduced")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("S9(a) Family G read-helper grant static contract PASS")
