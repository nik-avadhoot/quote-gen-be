-- S7-1: the annual customer-interest basis.
--
-- Canonical Amendment 01, A-01 and A-02 (Product Owner, 2026-09-06). CDM-18 no
-- longer holds four fixed effective-interest percentages; it holds ONE approved
-- annual rate, and the effective percentage is derived from it:
--
--     effective_interest_pct = annual_interest_pct * payment_terms_days / day_count_basis
--
-- THIS MIGRATION CHANGES NO NUMBER. The initial approved rate is 6.000% per
-- annum, and the four withdrawn values were already an exact straight-line
-- derivation at that rate on a 360-day year: 0.5/30, 0.75/45, 1.0/60 and 1.5/90
-- each come to 6.00% per annum. A 365-day year reproduces none of them, which is
-- why 360 is the approved convention rather than a preference. Same discipline
-- as A-21: establishing the structure moves no result.
--
-- ADDITIVE BY CONSTRUCTION. Both columns carry a default, so every existing row
-- and every fixture insert that does not name them keeps working. The obsolete
-- payment_interest_map_entries table is NOT touched here - A-03 makes the removal
-- ORDER canonical, and the map is dropped only after the resolver and the
-- application transition have proved that no runtime path reads it.
--
-- WHY day_count_basis EXISTS AT ALL WHEN IT CAN ONLY BE 360. It is provenance,
-- not configuration. CDM-22 requires Send to freeze the basis a percentage was
-- derived under, so that a snapshot stays verifiable if the convention is ever
-- amended. The check makes the Product Owner's "360 only" ruling structural: 365
-- is not a stored alternative, and changing the convention is a canonical
-- amendment plus a migration, never a configuration change.
--
-- IMMUTABILITY IS ALREADY ENFORCED. app_private.guard_master_version_transition
-- refuses any edit to an approved version regardless of column, so the annual
-- rate inherits second-person approval and post-approval immutability from the
-- structure S5-1 already built. A rate change is a new version.

alter table public.calculation_default_versions
  add column annual_interest_pct numeric(7,3) not null default 6.000,
  add column day_count_basis     integer      not null default 360;

alter table public.calculation_default_versions
  add constraint ck_cdv_annual_interest_range
    check (annual_interest_pct >= 0 and annual_interest_pct < 100),
  -- A-02: 360 and 360 only. Not `in (360,365)` - permitting a second basis is
  -- exactly the second authority this amendment exists to remove.
  add constraint ck_cdv_day_count_basis_360_only
    check (day_count_basis = 360);

comment on column public.calculation_default_versions.annual_interest_pct is
  'CDM-18 / Amendment 01 A-01: the single approved annual authority for customer Payment-Terms Interest. Initial approved value 6.000. Calculation-driving, so a change is a new approved version.';

comment on column public.calculation_default_versions.day_count_basis is
  'CDM-18 / Amendment 01 A-02: the day-count convention the effective percentage is derived under. 360 only; stored so a Send snapshot stays verifiable if the convention is ever amended.';

comment on column public.calculation_default_versions.interest_fallback_pct is
  'CDM-18: the INDEPENDENT fallback for an unresolved structured Payment Term, including a null. 0.500, and never 1.500. It survives the retirement of the fixed Payment Terms map and is not derived from the annual rate.';
