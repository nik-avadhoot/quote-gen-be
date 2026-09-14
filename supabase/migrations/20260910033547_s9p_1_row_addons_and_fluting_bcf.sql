-- S9-P/1: the eight add-on charges and the row-level fluting BCF.
--
-- WHY THESE COLUMNS EXIST AT ALL. The engine sums eight named charges into
-- `addOns` and carries the total into `sub = mat + conv + addOns`, on which
-- interest is then charged (engine/costing.js:101-102). They are price-bearing,
-- and until now no column anywhere in `public` held any of them - so a
-- calculation could only carry them inside its own JSONB payload, where a
-- freshness test recomputing a fingerprint would be hashing the payload against
-- itself. The same is true of the fluting BCF, which does not move a price but
-- does move `calc_bs`, the figure checkSpecCompliance quotes as a compliance
-- claim (engine/costing.js:254-255).
--
-- NULL IS NOT ZERO, AND THE DIFFERENCE IS COMMERCIAL (D-M, Product Owner).
-- The engine reads each charge as `(+printing || 0)`, so null and 0 contribute
-- the same nothing to the price. They are NOT the same fact: null means the
-- Maker never entered a charge; 0 means they deliberately entered zero - coating
-- quoted free, handling absorbed, an MOQ charge waived. On an immutable Quote
-- that is the difference between an omission and a concession. Both states are
-- stored distinctly here so that the S7-R fingerprint can hash them distinctly.
--
-- ADD-ONS HAVE NO INHERITANCE CHAIN. Unlike every other nullable commercial
-- column in this model, null here means ABSENT, not INHERIT. There is no Batch
-- tier, no Sector tier and no system fallback for a per-row charge. Stated once
-- so nobody later reads null as "resolve upward".
--
-- fluting_bcf IS THE OPPOSITE: null means INHERIT, and the tier it inherits from
-- is the versioned system default added in S9-P/2. A deliberate 0 is a take-up
-- factor of zero - unusual, but a real technical statement - and it must survive.
--
-- NO NEW GRANT AND NO NEW POLICY. These columns ride the write governance
-- batch_rows already has: authenticated holds INSERT and UPDATE, and
-- batch_rows_update admits the write under can_write_batch(batch_id), which
-- requires the unreleased edit lock, ownership or active collaboration,
-- make_quote at the plant, and a Batch in `working` or `sent`.

alter table public.batch_rows
  add column addon_printing   numeric(14,4) null,
  add column addon_stitching  numeric(14,4) null,
  add column addon_coating    numeric(14,4) null,
  add column addon_handling   numeric(14,4) null,
  add column addon_moq_charge numeric(14,4) null,
  add column addon_packing    numeric(14,4) null,
  add column addon_other      numeric(14,4) null,
  add column addon_unloading  numeric(14,4) null,
  add column fluting_bcf      numeric(8,4)  null;

-- One constraint, not eight, mirroring ck_row_overrides_non_negative exactly.
-- No upper bound: proposal S3.2 computes the realistic maximum of the SUM at
-- ~200 against a type ceiling of 1.8e7, so the type is already the bound and an
-- invented ceiling would be an unapproved commercial limit.
alter table public.batch_rows
  add constraint ck_row_addons_non_negative check (
        (addon_printing   is null or addon_printing   >= 0)
    and (addon_stitching  is null or addon_stitching  >= 0)
    and (addon_coating    is null or addon_coating    >= 0)
    and (addon_handling   is null or addon_handling   >= 0)
    and (addon_moq_charge is null or addon_moq_charge >= 0)
    and (addon_packing    is null or addon_packing    >= 0)
    and (addon_other      is null or addon_other      >= 0)
    and (addon_unloading  is null or addon_unloading  >= 0) ),
  -- 0 .. 0.30 inclusive, matching the bound documented at the engine's own call
  -- site (engine/costing.js:112). Zero is permitted and meaningful.
  add constraint ck_row_fluting_bcf_range check (
    fluting_bcf is null or (fluting_bcf >= 0 and fluting_bcf <= 0.30) );

comment on column public.batch_rows.addon_printing is
  'S9-P: per-row add-on charge, Rs/box. NULL = no charge entered (ABSENT, not inherit); 0 = a deliberate zero charge. Both are price-neutral and commercially distinct (D-M).';
comment on column public.batch_rows.fluting_bcf is
  'S9-P: row-level flute take-up factor. NULL = inherit calculation_default_versions.fluting_bcf_default; a value (including 0) is a deliberate override. Does not move price; moves calc_bs, which is quoted as a compliance claim (CDM-22).';