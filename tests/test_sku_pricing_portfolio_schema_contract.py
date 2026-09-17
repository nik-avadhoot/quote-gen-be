"""Static contract gate for the Amendment 03 SKU pricing portfolio migration.

Run:  python tests/test_sku_pricing_portfolio_schema_contract.py

The migration was applied live on 2026-09-17 (recorded version in its file name). This offline gate proves the authored SQL
keeps the boundaries Canonical Amendment 03 sets (CDM-45). It is not a substitute
for database-runtime verification once the migration is activated.

WHAT EACH GROUP WOULD CATCH:

  A03-S1..4  the column placed on the specification version instead of the SKU,
             the vocabulary opened past Transactional / Strategic, or the
             mandatory rule quietly relaxed to nullable.
  A03-S5..7  a DEFAULT, a back-fill, or any other way the DATABASE could classify
             a SKU by itself instead of a writer stating the value.
  A03-S8..10 the portfolio reaching a pricing decision - a rate, margin,
             discount, floor or threshold derived from it - which C-04 forbids
             until an approved rate mechanism consumes it.
  A03-S11..13 a client write path, a policy change, or an existing object
             altered by what is meant to be an additive migration.
"""
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "supabase" / "migrations" / "20260917024903_u2_sku_pricing_portfolio.sql").read_text(encoding="utf-8")
# Executable SQL only: the header explains the rules in prose.
CODE = "\n".join(line.split("--", 1)[0] for line in SQL.splitlines())
LOWER = CODE.lower()
# Word bans must read SQL, not the prose INSIDE string literals: the column
# comment and the refusal message both contain the words they are banning.
STATEMENTS = re.sub(r"'[^']*'", "''", LOWER)

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


# ───────────────────────────────────── the column, where CDM-45 puts it
check("alter table public.skus" in LOWER and "add column pricing_portfolio" in LOWER,
      "A03-S1 the portfolio is added to public.skus")
check("sku_versions" not in LOWER,
      "A03-S2 it is NOT on the specification version - it classifies the SKU, not a version (CDM-45)")
check(len(re.findall(r"add column ", LOWER)) == 1,
      "A03-S3 exactly one column is added")
check("check (pricing_portfolio in ('Transactional', 'Strategic'))" in CODE,
      "A03-S4 the vocabulary is exactly Transactional and Strategic, and closed")

# ───────────────────────────────────── mandatory, and never guessed
check("alter column pricing_portfolio set not null" in LOWER,
      "A03-S5 the column ends NOT NULL - no SKU may exist unclassified")
check("default" not in STATEMENTS,
      "A03-S6 there is NO default anywhere: the database can never classify a SKU by itself")
check(not re.search(r"\bupdate\s+public\.skus\b", LOWER) and not re.search(r"\binsert\s+into\b", LOWER),
      "A03-S7 no row is written - an existing SKU is never back-filled with a guessed classification")
check("raise exception" in LOWER and "pricing_portfolio is null" in LOWER,
      "A03-S7a instead, existing unclassified rows make the migration REFUSE, loudly and by count")
check("check_violation" in LOWER and "hint" in LOWER,
      "A03-S7b and the refusal carries a stable errcode and says what to do")

# ───────────────────────────────────── it creates NO pricing rule (C-04)
PRICING = ("rate", "margin", "discount", "floor", "threshold", "price_", "uplift", "surcharge")
check(not [w for w in PRICING if w in STATEMENTS],
      "A03-S8 no rate, margin, discount, floor, threshold or uplift is derived from it")
check("create trigger" not in LOWER and "create or replace function" not in LOWER,
      "A03-S9 no trigger or function fires on it, so nothing can act on a classification")
check("create view" not in LOWER and "create materialized view" not in LOWER,
      "A03-S10 no view exposes it to the costing engine")

# ───────────────────────────────────── read-only, additive, no policy change
check(not re.search(r"grant\s+(insert|update|delete|all)", LOWER),
      "A03-S11 no client INSERT, UPDATE or DELETE grant is added - the SKU Master stays read-only")
check("create policy" not in LOWER and "drop policy" not in LOWER and "alter policy" not in LOWER,
      "A03-S12 no row-level security policy is created, altered or dropped")
check("drop column" not in LOWER and "drop table" not in LOWER
      and not re.search(r"drop constraint(?! if exists)", LOWER),
      "A03-S13 additive only: nothing existing is dropped")
check("service_role" not in LOWER,
      "A03-S14 no service-role path is introduced")

# ───────────────────────────────────── the catalogue filter has an index
check("create index ix_sku_pricing_portfolio on public.skus (pricing_portfolio)" in LOWER,
      "A03-S15 the portfolio is indexed, because the catalogue filters on it in the database")
check("comment on column public.skus.pricing_portfolio" in LOWER
      and "no pricing rule" in LOWER,
      "A03-S16 the column comment carries the C-04 boundary to anyone reading the schema")

# ───────────────────────────────────── the file is prepared, not applied
check("PREPARED, NOT APPLIED" in SQL and "CDM-45" in SQL,
      "A03-S17 the migration states that it is prepared and names the decision it implements")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for failure in FAILURES:
        print(f"  FAILED: {failure}")
    sys.exit(1)
print("Amendment 03 SKU pricing portfolio static contract PASS")
