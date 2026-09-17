-- U2 SKU Master: the SKU pricing portfolio.
--
-- PREPARED, NOT APPLIED. Canonical Amendment 03 (Product Owner, 2026-09-16):
--   CDM-45  Every SKU records a pricing portfolio, exactly 'Transactional' or
--           'Strategic'. Mandatory, with NO default: import must assign one, so
--           no imported SKU is unclassified. An administrator may change it
--           later through a governed operation; no such operation exists yet.
--
-- ON THE SKU, NOT ON THE SPECIFICATION VERSION. CDM-43 puts the SPEC sheet's
-- quotation and costing fields on the immutable specification version because a
-- specification change is a new version. The portfolio is neither a SPEC column
-- nor a specification fact: it classifies the SKU as a commercial object and is
-- reclassified in place (C-03). One value per SKU also removes the question of
-- what "this SKU's portfolio" means when two versions disagree.
--
-- IT CREATES NO PRICING RULE (Amendment 03, C-04; the same boundary Amendment 01
-- A-06 set for colour count). Nothing here reads it, and nothing may infer or
-- apply pricing from it until an approved rate mechanism explicitly consumes it.
-- No rate, discount, margin, floor or approval threshold is derived from it, no
-- trigger fires on it, and no view exposes it to the costing engine.
--
-- Additive only. No existing column, constraint, policy, trigger or function
-- body changes, and no data is written. READ-ONLY for browser callers: `skus`
-- already grants SELECT to authenticated under the plant_access policy, and no
-- INSERT, UPDATE or DELETE grant or policy is added.

-- ─────────────────────────────────────────── the column, deliberately in two steps
-- Added nullable first so the guard below can speak before NOT NULL would fail
-- with a bare constraint violation.
alter table public.skus
  add column pricing_portfolio text null;

-- NO DEFAULT ANYWHERE. A default would let the database classify a SKU by
-- itself, which is precisely what C-04 forbids: the value is always a recorded
-- decision, and a writer that omits it must fail loudly.

-- ─────────────────────────────────────────── existing rows are never guessed
-- If SKUs already exist, this migration REFUSES rather than back-filling.
-- Choosing a value for an existing SKU is a classification decision and belongs
-- to the Product Owner, not to a migration. Classify the rows first, then
-- re-run: the guard passes once nothing is unclassified.
do $$
declare unclassified bigint;
begin
  select count(*) into unclassified from public.skus where pricing_portfolio is null;
  if unclassified > 0 then
    raise exception using
      errcode = 'check_violation',
      message = format('CDM-45: %s existing SKU row(s) have no pricing portfolio.', unclassified),
      detail  = 'This migration does not back-fill a classification, because choosing '
                'Transactional or Strategic for an existing SKU is a Product Owner decision.',
      hint    = 'Set public.skus.pricing_portfolio for every row (Transactional or Strategic), '
                'then run this migration again.';
  end if;
end $$;

-- ─────────────────────────────────────────── mandatory, closed vocabulary
alter table public.skus
  alter column pricing_portfolio set not null,
  add constraint ck_sku_pricing_portfolio
    check (pricing_portfolio in ('Transactional', 'Strategic'));

-- The SKU Master catalogue filters by portfolio; the filter is applied in the
-- database, never by loading a plant's rows and filtering them in memory.
create index ix_sku_pricing_portfolio on public.skus (pricing_portfolio);

comment on column public.skus.pricing_portfolio is
  'CDM-45 pricing portfolio: Transactional or Strategic. Mandatory, no default. '
  'Recorded only - no pricing rule may be inferred or applied from it until an '
  'approved rate mechanism consumes it (Amendment 03 C-04, Amendment 01 A-06).';
