"""Static contract gate for the Amendment 02 SKU Master migration.

Run:  python tests/test_sku_master_amendment_02_schema_contract.py

The migration is prepared, not applied. This offline gate proves the authored SQL
keeps the boundaries Canonical Amendment 02 sets (CDM-10, CDM-43, CDM-44). It is not
a substitute for database-runtime verification once the migration is activated.
"""
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "supabase" / "migrations" / "20260916100000_u2_sku_master_quote_fields_and_sets.sql").read_text(encoding="utf-8")
# Executable SQL only: the header explains the rules in prose.
CODE = "\n".join(line.split("--", 1)[0] for line in SQL.splitlines())
LOWER = CODE.lower()

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


QUOTE_FIELDS = ("item_name", "item_short_name", "item_family", "item_group", "print_quality",
                "print_technology", "number_of_colours", "colour_detail", "cobb_value", "stated_item_gsm",
                "item_weight_kg", "stated_cs", "stated_bs", "stated_ect", "customer_spec_version")

check(all(re.search(rf"add column {f}\s", CODE) for f in QUOTE_FIELDS),
      "A02-S1 every CDM-43 quote field is added to sku_versions")
check(len(re.findall(r"add column ", CODE)) == len(QUOTE_FIELDS)
      and "alter table public.sku_versions" in CODE and "alter table public.skus" not in CODE,
      "A02-S2 exactly those fields are added, on the version rather than the SKU identity")
check(all(f"add column {f}" not in CODE for f in ("ply", "flute", "layer_", "board_gsm")),
      "A02-S3 ply, flutes and board layers stay on the Construction version (CDM-13)")
check("print_technology in ('Flexo', 'CMYK', 'Offset', 'Unprinted')" in CODE,
      "A02-S4 Print Technology is the exact ruled vocabulary")
check("number_of_colours is null or number_of_colours >= 0" in CODE
      and "item_weight_kg is null or item_weight_kg >= 0" in CODE,
      "A02-S5 colour count and weight allow blank and explicit zero, never negative")
check(not re.search(r"\bnot null default\b", "\n".join(l for l in CODE.splitlines() if "add column" in l)),
      "A02-S6 new version fields are optional, so existing versions stay valid and immutable")
check("'softcomp_code'" in CODE
      and all(f"'{k}'" in CODE for k in ("customer_item_code", "legacy_plant_item_code", "alias", "other")),
      "A02-S7 SoftComp becomes a reference kind without dropping an existing kind")

check("create table public.sku_sets" in CODE and "create table public.sku_set_members" in CODE,
      "A02-S8 master SKU Set and membership tables exist (CDM-44)")
check("foreign key (set_id, plant_id) references public.sku_sets(id, plant_id)" in CODE
      and "foreign key (sku_id, plant_id) references public.skus(id, plant_id)" in CODE,
      "A02-S9 set and member SKU are bound to the same plant")
check("qty_per_set     numeric(10,3) not null" in CODE and "check (qty_per_set > 0)" in CODE,
      "A02-S10 every member carries a strictly positive quantity per set")
check("check (role in ('box', 'plate', 'partition'))" in CODE,
      "A02-S11 member roles are box, plate and partition only; unruled suffixes take no role")
check("uk_ssm_one_active_box" in CODE and "where role = 'box' and status <> 'withdrawn'" in CODE,
      "A02-S12 a set has at most one active box")
check("unique (set_id, sku_id)" in CODE,
      "A02-S13 a SKU appears once per set")
# The pre-existing reference kind 'legacy_plant_item_code' is a value, not a column read.
check(not re.search(r"plant_item_code|substr|left\(|split_part|\blike\b|regexp",
                    LOWER.replace("'legacy_plant_item_code'", "")),
      "A02-S14 nothing infers membership from Plant Item Code text (CDM-03, CDM-20)")

check("grant select on public.%I to authenticated" in CODE
      and not re.search(r"grant\s+(insert|update|delete|all)", LOWER),
      "A02-S15 browser callers receive read authority only on the set tables")
check("enable row level security" in CODE and "force  row level security" in CODE,
      "A02-S16 RLS is enabled and forced on the set tables")
check("has_plant_cap(plant_id, 'plant_access')" in CODE and "for insert" not in LOWER and "for update" not in LOWER,
      "A02-S17 set rows are read per plant_access and have no write policy")
check(not re.search(r"\b(insert into|update public\.|delete from)\b", LOWER),
      "A02-S18 the migration writes no data")
check(not any(t in LOWER for t in ("security definer", "service_role", "create or replace function", "drop policy", "drop trigger")),
      "A02-S19 no function, trigger, policy removal or privileged path is introduced")
check(not any(t in LOWER for t in ("rate_", "price", "coating_cost", "margin", "supplier_credit")),
      "A02-S20 no pricing, coating or colour-count rule is introduced")
check("prepared, not applied" in SQL.lower(),
      "A02-S21 the migration states it is prepared and not applied")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("Amendment 02 SKU Master static contract PASS")
