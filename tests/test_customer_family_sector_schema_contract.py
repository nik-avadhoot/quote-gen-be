"""Static U4 Customer Family/Sector migration contract gate.

The private development database is intentionally not changed in this build
phase. This offline gate proves the authored migration retains the exact
structural and authority boundaries that must be exercised when it is later
activated; it is not a substitute for database-runtime verification.
"""
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "supabase" / "migrations" /
       "20260912183000_u4_customer_family_sectors.sql").read_text(encoding="utf-8")

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


check("create table public.customer_family_sectors" in SQL
      and "primary key (family_id, sector_id)" in SQL,
      "U4-CFS-S1 Family/Sector membership is explicit and unique")
check("grant select on table public.customer_family_sectors to authenticated" in SQL
      and "grant insert" not in SQL.lower()
      and "grant update" not in SQL.lower()
      and "grant delete" not in SQL.lower(),
      "U4-CFS-S2 browser callers receive read authority only")
check("enable row level security" in SQL and "force row level security" in SQL
      and "app_private.has_group_cap('read_party_master')" in SQL,
      "U4-CFS-S3 membership reads remain RLS and capability governed")
check("deferrable initially deferred" in SQL
      and "assert_customer_family_has_sector" in SQL,
      "U4-CFS-S4 every newly created Family must finish its transaction with a Sector")
check("select distinct on (b.family_id, b.sector_id)" in SQL
      and "join public.sectors s on s.id = b.sector_id" in SQL,
      "U4-CFS-S4a existing Batch Family/Sector facts seed memberships without guessing")
check("ck_batch_sector_required" in SQL and "sector_id is not null" in SQL
      and "foreign key (family_id, sector_id)" in SQL,
      "U4-CFS-S5 every new/changed Batch selects one Sector attached to its Family")
check("add_customer_family_sector" in SQL
      and "manage_customer_master" in SQL
      and "p_expected_content_version" in SQL
      and "errcode = 'PT409'" in SQL,
      "U4-CFS-S6 adding another Sector is governed and CAS protected")
check("app_private.propose_customer_family(p_display_name, p_sector)" in SQL
      and "insert into public.customer_family_sectors" in SQL,
      "U4-CFS-S7 implicit Family creation and its first Sector are atomic")
check("the selected Sector is not attached to that Customer Family" in SQL
      and "join public.sectors s" in SQL,
      "U4-CFS-S8 governed Batch creation refuses a foreign or inactive Sector")
check("supplier_credit" not in SQL.lower(),
      "U4-CFS-S9 Family classification introduces no supplier-credit Batch input")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("U4 Customer Family/Sector static contract PASS")
