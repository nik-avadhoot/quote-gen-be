"""Static contract for Canonical Amendment 05's recorded migration."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "supabase" / "migrations" / "20260917154004_u2_sku_master_location_applicability.sql").read_text("utf-8")
LOWER = SQL.lower()
passes, failures = 0, []

def check(ok, label):
    global passes
    if ok:
        passes += 1
        print(f"ok   - {label}")
    else:
        failures.append(label)
        print(f"FAIL - {label}")

check("add column content_version integer not null default 1" in LOWER
      and "trg_sla_content_version" in LOWER, "SLA-1 applicability has a database-maintained CAS token")
check("guard_sku_location_applicability" in LOWER
      and all(x in LOWER for x in ("new.sku_id is distinct", "new.plant_id is distinct", "new.party_id is distinct",
                                   "new.location_id is distinct", "new.scope is distinct")),
      "SLA-2 the permanent binding is immutable")
check("revoke insert, update on public.sku_location_applicabilities from authenticated" in LOWER
      and "drop policy if exists sku_location_applicabilities_insert" in LOWER
      and "drop policy if exists sku_location_applicabilities_update" in LOWER,
      "SLA-3 callers have no direct write path")
ops = ("sku_propose_master_applicability", "sku_approve_master_applicability",
       "sku_withdraw_master_applicability", "sku_reactivate_master_applicability")
check(all(f"create or replace function app_private.{op}" in LOWER for op in ops)
      and all(f"create or replace function public.{op}" in LOWER for op in ops),
      "SLA-4 all four lifecycle changes have private definers and public invoker wrappers")
check(LOWER.count("security definer set search_path = ''") >= 4
      and LOWER.count("security invoker set search_path = ''") >= 4,
      "SLA-5 governed functions pin resolution and wrappers decide nothing")
check(all(op in LOWER for op in ("propose_applicability", "approve_applicability",
                                 "withdraw_applicability", "reactivate_applicability"))
      and "sku_location_applicability" in LOWER,
      "SLA-6 every transition extends append-only SKU history")
check("scope <> 'master'" in LOWER and "batch_only applicability is governed by the quotation workflow" in LOWER,
      "SLA-7 batch_only remains outside SKU Master mutations")
check(LOWER.count("__sku_active_location") >= 4 and "v.status <> 'active'" in LOWER,
      "SLA-8 proposal, approval and reactivation require an active same-Customer Location")
check(LOWER.count("p_expected_content_version") >= 12 and "errcode = 'pt409'" in LOWER,
      "SLA-9 existing-row operations use CAS and stale writes use PT409")
check("coalesce(v_reason,'') = ''" in LOWER and LOWER.count("a withdrawal reason") == 1
      and LOWER.count("a reactivation reason") == 1,
      "SLA-10 withdrawal and reactivation require bounded reasons")
check("create or replace function tests.sku_location_applicability()" in LOWER
      and "return query select * from tests.sku_location_applicability();" in LOWER,
      "SLA-11 a deploy-time pgTAP suite is registered in tests.run_all")
check("create or replace function app_private.sku_master_location_options" in LOWER
      and "perform app_private.__sku_require_manage(v_sku.plant_id)" in LOWER
      and "l.party_id = v_sku.party_id and l.status = 'active'" in LOWER,
      "SLA-12 SKU managers get only active same-Customer Location options without broad Customer Master access")

print(f"{passes} passed, {len(failures)} failed")
if failures:
    sys.exit(1)
print("SKU Location applicability schema contract PASS")
