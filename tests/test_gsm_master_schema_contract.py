"""Static GSM Master migration contract gate.

The development database is not changed by this build phase. This offline
gate proves the authored migration keeps its structural and authority
boundaries; it is not a substitute for database-runtime verification once the
migration is activated (tests.gsm_master_catalogue()).
"""
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "supabase" / "migrations"
SQL = (MIGRATIONS / "20260915084131_gsm_master.sql").read_text(encoding="utf-8")
GATES = (MIGRATIONS / "20260915084252_gsm_master_catalogue_gates.sql").read_text(encoding="utf-8")
CORRECTION = (MIGRATIONS / "20260916165004_fix_gsm_and_u4_definer_execute_grants.sql").read_text(
    encoding="utf-8")
CORRECTION_NORMALIZED = " ".join(CORRECTION.lower().split())

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


check("create table public.paper_gsm_values" in SQL
      and "constraint uk_paper_gsm_value unique (gsm)" in SQL
      and "check (gsm between 1 and 2000)" in SQL,
      "GSM-S1 one integer row per GSM value, bounded")
check("check (status in ('active', 'retired'))" in SQL
      and "content_version integer     not null default 1" in SQL,
      "GSM-S2 lifecycle is active/retired with a CAS version")
check("grant select on table public.paper_gsm_values to authenticated" in SQL
      and "grant insert" not in SQL.lower()
      and "grant update" not in SQL.lower()
      and "grant delete" not in SQL.lower(),
      "GSM-S3 browser callers receive read authority only")
check("enable row level security" in SQL and "force row level security" in SQL,
      "GSM-S4 RLS is enabled and forced")
check("array[80, 100, 110, 120, 140, 150, 170, 180, 200, 220, 230, 250]" in SQL,
      "GSM-S5 the Product Owner seed list is exact")
check(SQL.count("has_group_cap('manage_construction_library')") == 2,
      "GSM-S6 both governed writes require manage_construction_library")
check("errcode = 'PT409'" in SQL and "p_expected_content_version" in SQL,
      "GSM-S7 retire/restore is CAS protected with the application's stale-version code")
check("set gsm" not in SQL.lower() and "update public.paper_gsm_values\n     set status" in SQL,
      "GSM-S8 no governed operation renumbers a GSM value")
check("security invoker" in SQL
      and "security definer" in SQL
      and "grant execute on function app_private.add_paper_gsm_value(integer) to authenticated" in CORRECTION_NORMALIZED
      and "grant execute on function app_private.set_paper_gsm_value_status(bigint, text, integer) to authenticated" in CORRECTION_NORMALIZED
      and "revoke all on function app_private.add_paper_gsm_value(integer) from public, anon" in CORRECTION_NORMALIZED
      and "revoke all on function app_private.set_paper_gsm_value_status(bigint, text, integer) from public, anon" in CORRECTION_NORMALIZED,
      "GSM-S9 authenticated invoker wrappers can reach private definers; anon cannot")
check("tests.gsm_master_catalogue()" in GATES
      and "grant execute on function tests.gsm_master_catalogue() to service_role" in GATES,
      "GSM-S10 a runtime catalogue gate exists for activation")
check("supplier_credit" not in SQL.lower()
      and not any(token in SQL.lower() for token in ("rate_", "_rate", "rate_set", "price")),
      "GSM-S11 the GSM Master introduces no rate or supplier-credit input")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("GSM Master static contract PASS")
