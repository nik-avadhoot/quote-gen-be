"""Static contract gate for the SKU Master governed-operations migration (Amendment 04).

Run:  python tests/test_sku_governed_operations_schema_contract.py

The migration is PREPARED, NOT APPLIED. This offline gate proves the authored SQL keeps
the Product Owner's rulings of 2026-09-16 (design packet D1-D12). It cannot prove the
SQL runs: that is database-runtime verification, owed when the migration is activated
(its own pgTAP suite, tests.sku_governed_operations, is registered in run_all for that).

WHAT EACH GROUP WOULD CATCH:

  SGC-1..4    applied without Amendments 02/03, or the direct write path (D10) left open,
              or the deferred Location applicability quietly changed (D7).
  SGC-5..8    a history a caller could write or rewrite (D9); a token a caller could set,
              or a table left without one (D8).
  SGC-9..14   an operation that trusts a client-supplied actor, skips the plant
              capability, writes no history, or lives in an exposed schema as a definer.
  SGC-15..22  a field class drifting from D2; approval forbidden to the proposer (D1);
              code assignment publishing again (D3); discontinuation without a reason,
              a cross-Customer replacement, or a sticky replacement on reactivation (D4);
              a withdrawal that orphans a Batch row; references edited in place (D5).
  SGC-23..25  a pricing rule inferred from the portfolio; any Family G (Quote) table
              touched (S9 stays narrow); existing suites deleted instead of repointed.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "supabase" / "migrations" / "20260916200000_u2_sku_master_governed_operations.sql").read_text(encoding="utf-8")
CODE = "\n".join(line.split("--", 1)[0] for line in SQL.splitlines())
LOWER = CODE.lower()
NO_LITERALS = re.sub(r"'[^']*'", "''", LOWER)

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
    m = re.search(rf"create or replace function {schema}\.{name}\((.*?)end \$fn\$;", CODE, re.S | re.I)
    return m.group(0) if m else ""


OPS = ("sku_propose", "sku_create_version", "sku_update_draft_version", "sku_approve_version",
       "sku_assign_plant_item_code", "sku_publish", "sku_discontinue", "sku_reactivate", "sku_withdraw",
       "sku_set_pricing_portfolio", "sku_add_reference", "sku_withdraw_reference")

# ───────────────────────────────────────────── prerequisites and the write path
check("prepared, not applied" in SQL.lower() and "object_not_in_prerequisite_state" in LOWER
      and "column_name = 'item_name'" in LOWER and "column_name = 'pricing_portfolio'" in LOWER,
      "SGC-1 prepared-not-applied, and it refuses to run without Amendments 02 and 03")
check("revoke insert, update on public.skus, public.sku_versions, public.sku_external_references from authenticated" in LOWER,
      "SGC-2 authenticated loses INSERT and UPDATE on the three SKU tables (D10)")
check(all(f"drop policy if exists {p}" in LOWER for p in (
        "skus_insert", "skus_update", "sku_versions_insert", "sku_versions_update",
        "sku_external_references_insert", "sku_external_references_update")),
      "SGC-3 and every write policy on them is dropped (D10)")
check(not re.search(r"(revoke|grant|drop policy|create policy|alter table)[^;]*sku_location_applicabilities", LOWER),
      "SGC-4 Location applicability is deliberately untouched (D7 deferred)")

# ───────────────────────────────────────────── history and tokens
check("create table public.sku_master_events" in LOWER
      and "revoke all on public.sku_master_events from anon, authenticated, service_role" in LOWER
      and "grant select on public.sku_master_events to authenticated" in LOWER
      and not re.search(r"grant (insert|update|delete|all)[^;]*sku_master_events", LOWER),
      "SGC-5 the history is readable, and no application role may write it (D9)")
check("force  row level security" in LOWER and "has_plant_cap(plant_id, 'plant_access')" in LOWER
      and "foreign key (sku_id, plant_id) references public.skus(id, plant_id)" in LOWER,
      "SGC-6 history is RLS-forced, plant-scoped, and bound to the SKU's own plant")
check("alter table public.sku_versions add column content_version integer not null default 1" in LOWER,
      "SGC-7 sku_versions gains its own compare-and-swap token (D8)")
check(len(re.findall(r"before update on public\.(skus|sku_versions)\s+for each row execute function app_private\.guard_content_version\(\)", LOWER)) == 2,
      "SGC-8 the database maintains both tokens - a caller can never set one (D8)")

# ───────────────────────────────────────────── every operation, the same discipline
for op in OPS:
    b = body("app_private", op)
    check(b and "security definer set search_path = ''" in b.lower(),
          f"SGC-9 app_private.{op} is a definer with an empty search_path")
    check("app_private.__sku_me()" in b and "p_actor" not in b and "p_created_by" not in b,
          f"SGC-10 {op} takes the actor from the session, never from a parameter (CDM-34)")
    check("app_private.__sku_event(" in b, f"SGC-11 {op} writes one history event (D9)")
    check("has_plant_cap(" in b or "__sku_require_manage(" in b,
          f"SGC-12 {op} checks capability at the SKU's own plant")
    wrapper = re.search(rf"create or replace function public\.{op}\((.*?)\$fn\$;", CODE, re.S | re.I)
    check(wrapper and "security invoker" in wrapper.group(0).lower() and "security definer" not in wrapper.group(0).lower(),
          f"SGC-13 public.{op} is an invoker wrapper that decides nothing")
check(all(("p_expected_content_version" in body("app_private", op)) for op in OPS if op != "sku_propose"),
      "SGC-14 every operation on an existing record takes expected_content_version and raises PT409 (D8)")
check(all(f"'{op}'" in LOWER for op in OPS) and "grant execute on function %i.%i(%s) to authenticated" in LOWER,
      "SGC-14a the private definers and their wrappers are executable by authenticated - an invoker wrapper "
      "runs with the caller's privileges, so revoking the private one breaks it")
check(all(re.search(rf"revoke execute on function (public|app_private)\.{f}\(", LOWER)
          for f in ("propose_sku", "approve_sku_version", "assign_plant_item_code", "set_sku_status")),
      "SGC-14b the S4-3 functions (no token, no reason, no history) are no longer reachable by callers")

# ───────────────────────────────────────────── the rulings
cls = body("app_private", "sku_field_class") or re.search(r"function app_private\.sku_field_class.*?\$fn\$;", CODE, re.S).group(0)
new_sku = re.search(r"in \(([^)]*)\)\s*then 'new_sku'", cls, re.S).group(1)
price = re.search(r"in \(([^)]*)\)\s*then 'price_driving_version'", cls, re.S).group(1)
version = re.search(r"in \(([^)]*)\)\s*then 'version'", cls, re.S).group(1)
names = lambda chunk: sorted(re.findall(r"'([a-z_0-9]+)'", chunk))
check(names(new_sku) == sorted(["length_mm", "width_mm", "height_mm", "construction_version_id", "spec_bs", "spec_bct",
                                "spec_ect", "box_type", "stated_item_gsm", "stated_cs", "stated_bs", "stated_ect"]),
      "SGC-15 dimensions, Construction, BS/BCT/ECT, box type and stated strength force a NEW SKU (CDM-10, D2)")
check(names(price) == ["cobb_value", "item_weight_kg", "ups"],
      "SGC-16 Cobb value, item weight and ups make a price-driving version (D2)")
check(names(version) == sorted(["item_name", "item_short_name", "print_quality", "print_technology", "number_of_colours",
                                "colour_detail", "customer_spec_version", "item_family", "item_group"]),
      "SGC-17 names, printing, spec version, Item Family and Item Group make a version (D2)")
check("'plant_id'" not in cls and "'party_id'" not in cls and "errcode = 'pt423'" in LOWER,
      "SGC-17a plant and Customer are no field at all, and a new-SKU change raises PT423")
approve = body("app_private", "sku_approve_version").lower()
check("approved_by = v_me" in approve and "created_by" not in approve,
      "SGC-18 the proposer may approve their own version - no proposer/approver separation (D1, initially)")
propose = body("app_private", "sku_propose").lower()
check("'make_quote'" in propose and "pricing portfolio" in propose,
      "SGC-18a a Maker may propose, and a proposal must state its portfolio (D1, CDM-45)")
assign = body("app_private", "sku_assign_plant_item_code").lower()
publish = body("app_private", "sku_publish").lower()
check("status = 'active'" not in assign and "legacy_plant_item_code" in assign,
      "SGC-19 assigning the code does not publish, and a retired code is never reissued (D3)")
check("plant_item_code is null" in publish and "approved_at is not null" in publish
      and "pricing_portfolio is null" in publish and "set status = 'active'" in publish,
      "SGC-20 publishing needs a code, an approved version and a portfolio (D3)")
disc = body("app_private", "sku_discontinue").lower()
react = body("app_private", "sku_reactivate").lower()
check("a reason is required" in disc and "v_rep.plant_id <> v_sku.plant_id" in disc
      and "v_rep.party_id <> v_sku.party_id" in disc and "replacement_sku_id = null" in react,
      "SGC-21 discontinuing needs a reason; a replacement is at the same plant and Customer; reactivation clears it (D4)")
withdraw = body("app_private", "sku_withdraw").lower()
check("from public.batch_rows where sku_id = p_sku" in withdraw
      and "(old.status = 'proposed'     and new.status = 'withdrawn')" in LOWER
      and "before insert or update of sku_id on public.batch_rows" in LOWER,
      "SGC-22 a proposal already on a Batch row is not withdrawn, withdrawn is terminal, "
      "and a withdrawn SKU can never be put on a Batch row (D4)")
check("update public.sku_external_references set status = 'withdrawn'" in LOWER
      and not re.search(r"update public\.sku_external_references set reference_value", LOWER),
      "SGC-22a references are withdrawn, never edited in place (D5)")

# ───────────────────────────────────────────── boundaries that must not move
ops_code = "\n".join(body("app_private", op) for op in OPS).lower()
ops_no_literals = re.sub(r"'[^']*'", "''", ops_code)
check(not [w for w in ("rate", "margin", "discount", "floor", "threshold", "uplift") if re.search(rf"\b{w}\b", ops_no_literals)],
      "SGC-23 no operation derives a rate, margin, discount or floor from the portfolio (CDM-45 C-04)")
check(not re.search(r"\bpublic\.quote_|\bquote_revisions\b|\bquote_items\b|\bquote_families\b", LOWER),
      "SGC-24 no Family G (Quote) table is read or written - S9 stays narrow")
check("return next ok(not v_ok, 'ps-8 a maker may not write a sku row directly" in LOWER
      and "create or replace function tests.product_workflow()" in LOWER
      and "public.propose_sku(" not in LOWER.split("create or replace function tests.product_workflow()")[1].split("end $fn$;")[0]
      and "return query select * from tests.sku_governed_operations();" in LOWER,
      "SGC-25 existing suites are repointed, not deleted, and the new suite is registered in run_all")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("SKU governed operations schema contract PASS")
