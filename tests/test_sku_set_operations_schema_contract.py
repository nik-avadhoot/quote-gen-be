"""Static contract for the recorded governed SKU Set operations migration."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "supabase" / "migrations" / "20260917154140_u2_sku_set_governed_operations.sql").read_text(encoding="utf-8")
LOWER = "\n".join(line.split("--", 1)[0] for line in SQL.lower().splitlines())
PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


def body(schema, name):
    match = re.search(rf"create or replace function {schema}\.{name}\(.*?end \$fn\$;", LOWER, re.S)
    return match.group(0) if match else ""


OPS = ("sku_set_propose", "sku_set_confirm", "sku_set_retire")
check("object_not_in_prerequisite_state" in LOWER and "preceding amendment 05" in LOWER,
      "SSOC-1 the recorded migration is dependency-gated")
check("confirmed_by bigint" in LOWER and "confirmed_at timestamptz" in LOWER,
      "SSOC-2 confirmation actor and instant are stored")
check(len(re.findall(r"before update on public\.(sku_sets|sku_set_members).*?guard_content_version", LOWER, re.S)) == 2,
      "SSOC-3 database-maintained CAS tokens cover Sets and members")
check("uk_ssm_one_current_set_per_sku" in LOWER and "where status <> 'withdrawn'" in LOWER,
      "SSOC-4 one SKU belongs to at most one current Set")
check("role and quantity are immutable" in LOWER and "proposed' and new.status = 'confirmed'" in LOWER,
      "SSOC-5 bindings are immutable and lifecycle transitions are closed")
check("revoke insert, update, delete on public.sku_sets, public.sku_set_members from authenticated" in LOWER,
      "SSOC-6 callers have no direct Set write path")
for op in OPS:
    private = body("app_private", op)
    wrapper = re.search(rf"create or replace function public\.{op}\(.*?\$fn\$;", LOWER, re.S)
    check("security definer set search_path = ''" in private and "app_private.__sku_me()" in private
          and "app_private.__sku_require_manage" in private,
          f"SSOC-7 {op} derives actor, pins search_path and checks due authority")
    check(wrapper and "security invoker set search_path = ''" in wrapper.group(0),
          f"SSOC-8 public.{op} is a decision-free invoker wrapper")
check("jsonb_array_elements(p_members)" in body("app_private", "sku_set_propose")
      and "plant_item_code" not in body("app_private", "sku_set_propose"),
      "SSOC-9 membership uses explicit internal identities, never code inference")
check("v_box_count <> 1" in LOWER and "qty_per_set')::numeric > 0" in LOWER,
      "SSOC-10 exactly one box and positive quantity are validated")
check("p.lifecycle_state='customer'" in LOWER and "p.customer_code is not null" in LOWER
      and "v_me = v_set.created_by" in LOWER and "errcode = 'pt425'" in LOWER,
      "SSOC-11 settled Customer Sets require a different confirmer (D-06/D-13)")
check(all("p_expected_content_version" in body("app_private", op) for op in OPS),
      "SSOC-12 every operation carries an optimistic concurrency token")
check(all(f"'{op}'" in LOWER for op in ("propose_sku_set", "confirm_sku_set", "retire_sku_set"))
      and "app_private.__sku_event" in LOWER,
      "SSOC-13 proposal, confirmation and retirement are append-only history events")
check("create or replace function tests.sku_set_operations()" in LOWER
      and "return query select * from tests.sku_set_operations();" in LOWER,
      "SSOC-14 the deploy-time database contract is registered")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for failure in FAILURES:
        print(f"  FAILED: {failure}")
    sys.exit(1)
print("SKU Set operations schema contract PASS")
