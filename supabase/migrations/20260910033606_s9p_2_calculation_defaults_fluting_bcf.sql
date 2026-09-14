-- S9-P/2: the versioned system tier for the flute take-up factor.
--
-- The engine currently hard-codes the fallback:
--     flBCF = (flutingBCF is usable) ? +flutingBCF : 0.10      (costing.js:112)
-- A bare literal governing a frozen result is precisely what S7 spent itself
-- removing - A-17 put the Payment-Terms map and the 0.5% interest fallback onto
-- calculation_default_versions for this reason. This finishes that job for the
-- one engine constant S7 did not reach.
--
-- THIS MIGRATION CHANGES NO NUMBER. The seeded value is 0.1000, which is exactly
-- the literal the engine already applies, so establishing the structure moves no
-- calc_bs and no compliance verdict. Same discipline as A-21 and S7-1.
--
-- THE COLUMN CARRIES A DEFAULT, DELIBERATELY, following S7-1's precedent in this
-- table verbatim: "Both columns carry a default, so every existing row and every
-- fixture insert that does not name them keeps working." tests.pricing_basis()
-- inserts a calculation_default_versions row without naming this column, and
-- dropping the default would break it. A new approved version that wants a
-- different factor states one; a version that does not is asserting the approved
-- 0.1000, which is a statement rather than an accident.
--
-- IMMUTABILITY IS ALREADY ENFORCED. app_private.guard_master_version_transition
-- refuses any edit to an approved version regardless of column, so this value
-- inherits second-person approval and post-approval immutability from the
-- structure S5-1 already built. A factor change is a NEW version, which is what
-- keeps an old snapshot reproducible: the version it names still holds the
-- number it used (CDM-31).

alter table public.calculation_default_versions
  add column fluting_bcf_default numeric(8,4) not null default 0.1000;

alter table public.calculation_default_versions
  add constraint ck_cdv_fluting_bcf_range
    check (fluting_bcf_default >= 0 and fluting_bcf_default <= 0.30);

comment on column public.calculation_default_versions.fluting_bcf_default is
  'S9-P: the governed system fallback for the flute take-up factor, seeded at the engine literal 0.1000 so establishing it moves no number. Calculation-relevant through calc_bs and its compliance claim, so a change is a new approved version (CDM-31).';