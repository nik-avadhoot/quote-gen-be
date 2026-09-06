-- S7-3: supplier paper-credit cost becomes a versioned, approved, plant-owned
-- value.
--
-- Canonical Amendment 01, A-05 and CDM-41 (Product Owner, 2026-09-06). The word
-- "interest" was doing two jobs on opposite sides of the same transaction:
--
--   CUSTOMER credit-period interest   what Avadhoot CHARGES a customer for a
--                                     credit period. CDM-18. Enters the cost
--                                     build-up as sub * interest/100
--
--   SUPPLIER paper-credit cost        what Avadhoot PAYS a paper mill for taking
--                                     credit. CDM-41. Enters the Effective Paper
--                                     Rate as an INPUT COST:
--                                     price + price*credit - discount + freight
--
-- They are not the same number and neither is derived from the other. Deriving
-- supplier credit cost from customer Payment Terms would be an invented
-- commercial rule, and A-05 forbids it.
--
-- WHERE 1.500 COMES FROM, AND WHY IT IS ONE VALUE. CFB_Quotation_Master_v7.xlsx,
-- sheet RATE MASTER, holds "Credit Cost %" in a single cell B4 at 0.015, and
-- every grade's credit cost is the formula C{row}*$B$4. It is one sheet-level
-- constant applied to all grades, not a per-grade figure - so the approved shape
-- is one versioned value on the Rate Set version, with the per-grade column
-- retained only as an explicit exception. That is what A-05 rules and what this
-- migration builds.
--
-- BLANK, ZERO AND EXCEPTION. rate_entries.interest_pct stays nullable and keeps
-- its name, which the Product Owner named directly in the ruling; the comments
-- below carry the meaning the name does not. Null there means INHERIT the Rate
-- Set version value. Explicit zero means zero - a grade genuinely bought on cash
-- terms - and must survive, which is why the application test is null-aware
-- rather than truthy. This is the same blank-versus-zero rule CDM-19 applies to
-- waste and conversion, on a different tier.
--
-- IMMUTABILITY IS ALREADY ENFORCED. app_private.guard_plant_master_version_transition
-- refuses any edit to an approved rate_set_version regardless of column, so the
-- credit cost inherits second-person approval, plant ownership and
-- post-approval immutability from the structure S5-2 already built.
--
-- ADDITIVE. The column carries a default, so every existing row and every
-- fixture insert that does not name it keeps working, and the default reproduces
-- today's reachable literal exactly (A-21). No number moves.

alter table public.rate_set_versions
  add column credit_cost_pct numeric(7,3) not null default 1.500;

alter table public.rate_set_versions
  add constraint ck_rsv_credit_cost_range
    check (credit_cost_pct >= 0 and credit_cost_pct < 100);

comment on column public.rate_set_versions.credit_cost_pct is
  'CDM-41 / Amendment 01 A-05: SUPPLIER paper-credit cost - what Avadhoot pays a mill for taking credit. An input cost to the Effective Paper Rate. Initial approved value 1.500. NOT customer Payment-Terms Interest (CDM-18) and never derived from it. Inherited by every rate entry that does not carry an explicit exception.';

comment on column public.rate_entries.interest_pct is
  'CDM-41 / Amendment 01 A-05: the per-grade EXCEPTION to rate_set_versions.credit_cost_pct. Despite the column name this is SUPPLIER paper-credit cost, not customer Payment-Terms Interest. Null means INHERIT the Rate Set version value; explicit zero means zero and must survive - never resolve it with truthiness.';

comment on column public.rate_sets.name is
  'Paper Rate Master set identity, plant-owned (CDM-04). Its versions carry the supplier paper-credit cost (CDM-41).';
