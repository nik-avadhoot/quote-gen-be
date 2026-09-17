"""Offline contract gate for the Wave A catalogue-suite registration.

This proves the authored migration is a guarded splice and keeps both missing
suites reachable from tests.run_all(). Database-runtime SR-1 remains the
activation evidence and is deliberately reported separately.
"""
from pathlib import Path


MIGRATION = (
    Path(__file__).resolve().parent.parent
    / "supabase"
    / "migrations"
    / "20260917182138_register_gsm_and_customer_family_sector_suites.sql"
)
SQL = MIGRATION.read_text(encoding="utf-8")

FAILURES = []
PASSES = 0


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


check("pg_get_functiondef('tests.run_all()'::regprocedure)" in SQL,
      "WA-SR-1 registration starts from the stored run_all definition")
check("create or replace function tests.run_all" not in SQL.lower(),
      "WA-SR-2 registration does not retype run_all")
check(SQL.count("tests.gsm_master_catalogue()") >= 3,
      "WA-SR-3 GSM catalogue is guarded, inserted and verified")
check(SQL.count("tests.u4_customer_family_sector_catalogue()") >= 3,
      "WA-SR-4 Customer Family Sector catalogue is guarded, inserted and verified")
check("expected exactly 1 plant_master anchor" in SQL
      and "expected exactly 1 customer_family_mutations anchor" in SQL,
      "WA-SR-5 both splice anchors have exact-count guards")
check("revoke all on function tests.run_all() from public, anon, authenticated" in SQL,
      "WA-SR-6 run_all remains unavailable to application callers")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for failure in FAILURES:
        print(f"  FAILED: {failure}")
    raise SystemExit(1)
print("Wave A suite-registration contract gate PASS")
