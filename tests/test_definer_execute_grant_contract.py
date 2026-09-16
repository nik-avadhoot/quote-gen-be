"""Static GSM Master / U4 private definer EXECUTE grant contract gate.

The corrective migration was applied live on 2026-09-16. This offline gate
proves the recorded migration keeps the exact boundaries it established:
authenticated gains EXECUTE on exactly the five private definer functions the
public invoker wrappers call, anon and public gain nothing, the
two private-only compatibility overloads stay closed, GSM-6 is repointed rather
than deleted, and the migration verifies the whole defect class before it
commits. It is not a substitute for database-runtime or authenticated-caller
verification.
"""
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "supabase" / "migrations"
SQL = (MIGRATIONS / "20260916165004_fix_gsm_and_u4_definer_execute_grants.sql").read_text(encoding="utf-8")
GSM = (MIGRATIONS / "20260915084131_gsm_master.sql").read_text(encoding="utf-8")
GSM_GATES = (MIGRATIONS / "20260915084252_gsm_master_catalogue_gates.sql").read_text(encoding="utf-8")
U4 = (MIGRATIONS / "20260915100440_u4_customer_family_sectors.sql").read_text(encoding="utf-8")
CONVENTION = (MIGRATIONS / "20260907071937_family_b_mutations_fix_grants_and_drop_obsolete.sql").read_text(encoding="utf-8")

# Executable SQL only. The header explains anon/public and the compatibility
# overloads in prose; authority checks must not match commentary.
CODE = "\n".join(line.split("--", 1)[0] for line in SQL.splitlines()).lower()

CORRECTED = {
    "add_paper_gsm_value": "integer",
    "set_paper_gsm_value_status": "bigint, text, integer",
    "propose_customer_family": "text, bigint",
    "create_minimal_prospect": "text, bigint, bigint",
    "add_customer_family_sector": "bigint, bigint, integer",
}
COMPAT = {
    "propose_customer_family": "text",
    "create_minimal_prospect": "text, bigint",
}

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


# The defect this migration corrects is real in the recorded history.
check(all(f"revoke all on function app_private.{name}({args}) from public, anon, authenticated;" in GSM + U4
          for name, args in CORRECTED.items()),
      "DEG-1 the authoring migrations revoke authenticated EXECUTE on all five private functions")
check(all(re.search(rf"create function public\.{name}\(.*?security invoker.*?app_private\.{name}\(", GSM + U4, re.S)
          or re.search(rf"create or replace function public\.{name}\(.*?security invoker.*?app_private\.{name}\(", GSM + U4, re.S)
          for name in CORRECTED),
      "DEG-2 each public wrapper is SECURITY INVOKER and calls its private counterpart")
check(all(f"grant execute on function public.{name}(" in GSM + U4 for name in CORRECTED),
      "DEG-3 each public wrapper is already executable by authenticated")
check("grant execute on function %i.%i(%s) to authenticated" in CONVENTION.lower()
      and "'propose_customer_family', 'create_minimal_prospect'" in CONVENTION,
      "DEG-4 the working convention grants private governed operations to authenticated")

# The correction grants exactly what the wrappers need and nothing more.
for name, args in CORRECTED.items():
    check(re.search(rf"grant execute on function app_private\.{name}\({re.escape(args)}\)\s+to authenticated;", SQL) is not None,
          f"DEG-5 authenticated gains EXECUTE on app_private.{name}({args})")
    check(re.search(rf"revoke all on function app_private\.{name}\({re.escape(args)}\)\s+from public, anon;", SQL) is not None,
          f"DEG-6 public and anon stay revoked on app_private.{name}({args})")
grant_lines = [line.strip() for line in CODE.splitlines() if line.strip().startswith("grant ")]
check(len(grant_lines) == 6
      and sum(line.endswith("to authenticated;") for line in grant_lines) == 5
      and "grant execute on function tests.gsm_master_catalogue() to service_role;" in grant_lines,
      "DEG-7 exactly five grants to authenticated plus the unchanged gate-suite service_role grant")
check(not re.search(r"\bgrant\b[^;]*\bto\s+(anon|public)\b", CODE)
      and not re.search(r"\bgrant\b[^;]*app_private[^;]*\bto\s+service_role\b", CODE),
      "DEG-8 anon and public gain nothing, and no private function is granted to service_role")
check(not any(re.search(rf"grant[^;]*app_private\.{name}\({re.escape(args)}\)", CODE)
              for name, args in COMPAT.items()),
      "DEG-9 the private-only compatibility overloads are not granted")
check(not re.search(r"\bauthenticated\b[^;]*\bwith grant option\b", CODE)
      and "create or replace function app_private" not in CODE
      and "create function" not in CODE
      and "security definer" not in CODE
      and not re.search(r"\b(create|alter|drop)\s+policy\b", CODE),
      "DEG-10 no function body, policy, or grant option is introduced")
check(not re.search(r"\b(insert into|update public\.|delete from)\b", CODE),
      "DEG-11 the correction writes no data")
check("set role" not in CODE
      and not re.search(r"\b(alter|create)\s+schema\b|pgrst\.db_schemas|grant usage on schema", CODE),
      "DEG-12 no role switch or API exposure of app_private is introduced")

# GSM-6 is repointed, not deleted, and the splice is guarded.
check("tests.gsm_master_catalogue()'::regprocedure" in SQL and "pg_get_functiondef" in SQL,
      "DEG-13 the splice targets the live tests.gsm_master_catalogue() definition")
check("raise exception 'expected exactly 1 GSM-6 splice fragment %, found %'" in SQL,
      "DEG-14 every splice fragment must occur exactly once or the migration aborts")
check("revoke all on function tests.gsm_master_catalogue() from public, anon, authenticated;" in SQL,
      "DEG-15 the replaced suite stays unexecutable by browser roles")


def sql_array(var):
    body = re.search(rf"{var}\s+text\[\] := array\[(.*?)\];", SQL, re.S).group(1)
    return [m.replace("''", "'") for m in re.findall(r"'((?:[^']|'')*)'", body)]


OLD, NEW = sql_array("v_old"), sql_array("v_new")
check(len(OLD) == len(NEW) == 4 and all(GSM_GATES.count(fragment) == 1 for fragment in OLD),
      "DEG-16 each splice fragment occurs exactly once in the recorded GSM gate body")
SPLICED = GSM_GATES
for old, new in zip(OLD, NEW):
    SPLICED = SPLICED.replace(old, new)
GSM6 = re.search(r"(ok := [^;]*;)\s*name := 'GSM-6[^']*';", SPLICED, re.S)
PROBE = GSM6.group(1) if GSM6 else ""
check(GSM6 is not None
      and "not pg_catalog.has_function_privilege('authenticated'" not in PROBE
      and PROBE.count("pg_catalog.has_function_privilege('authenticated',") == 2
      and PROBE.count("not pg_catalog.has_function_privilege('anon'") == 2
      and "'app_private.add_paper_gsm_value(integer)'" in PROBE
      and "'app_private.set_paper_gsm_value_status(bigint,text,integer)'" in PROBE,
      "DEG-17 the repointed GSM-6 asserts authenticated CAN and anon CANNOT execute both GSM functions")
check(SPLICED.count("name := 'GSM-") == GSM_GATES.count("name := 'GSM-") == 6
      and SPLICED.count("return next;") == GSM_GATES.count("return next;") == 6,
      "DEG-18 the splice keeps all six GSM gates")
check(SPLICED.split("ok := pg_catalog.has_function_privilege('authenticated',\n      'app_private.")[0]
      == GSM_GATES.split("ok := not pg_catalog.has_function_privilege('authenticated',\n      'app_private.")[0],
      "DEG-19 gates GSM-1..GSM-5 are unchanged by the splice")

# The migration proves the defect class before it commits.
check("regexp_matches(w.prosrc, 'app_private\\.([a-z_0-9]+)\\s*\\(', 'g')" in SQL
      and "not w.prosecdef" in SQL
      and "has_function_privilege('authenticated', pr.oid, 'EXECUTE')" in SQL
      and "raise exception 'public invoker wrappers call private functions authenticated cannot execute" in SQL,
      "DEG-20 every public invoker wrapper's private callee must be executable by authenticated")
check(all(f"has_function_privilege('anon', 'app_private.{name}({args.replace(', ', ',')})', 'EXECUTE')" in SQL
          for name, args in CORRECTED.items())
      and "raise exception 'anon must not be able to execute the corrected private definer functions'" in SQL,
      "DEG-21 the structural proof refuses anon EXECUTE on all five")
check(all(f"has_function_privilege('authenticated', 'app_private.{name}({args.replace(', ', ',')})', 'EXECUTE')" in SQL
          for name, args in COMPAT.items())
      and "raise exception 'the private-only compatibility overloads must stay unexecutable by authenticated'" in SQL,
      "DEG-22 the structural proof keeps the compatibility overloads closed")
check("applied to the live project 2026-09-16" in SQL.lower()
      and not (MIGRATIONS / "20260916180000_fix_gsm_and_u4_definer_execute_grants.sql").exists(),
      "DEG-23 the file carries the live-recorded version and states it was applied")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("GSM/U4 private definer EXECUTE grant static contract PASS")
