-- S9(a) correction: the governed Freight Master reference on a calculation
-- snapshot was individually valid but not MUTUALLY consistent, and it was not
-- confined to the one source entitled to carry it. Both gaps are closed here,
-- additively. No applied migration is rewritten or removed.
--
-- GAP 1 - two independent references could disagree. freight_set_version_id and
-- freight_entry_id each had their own single-column FK, so a snapshot could name
-- Freight Set Version 11 and Freight Entry 42 while entry 42 belonged to a
-- DIFFERENT version. Each reference was valid; the pair was a fiction. On an
-- immutable, issued snapshot that fiction is uncorrectable. The composite FK
-- below makes the pair itself the thing the database checks, which is the same
-- device used throughout this schema for scope-binding (uk_*_id_* + composite
-- FK) - it is not a new pattern, it is the one that was missed here.
--
-- GAP 2 - the reference shape was open on one side. ck_cs_master_has_both_refs
-- required both references FOR 'master', and
-- ck_cs_temporary_carries_no_governed_ref forbade them FOR 'temporary'. Nothing
-- spoke for the governed non-master sources: a 'row' or 'pricing_group'
-- snapshot could carry one or both Freight Master references and claim a
-- provenance it does not have. The two one-sided checks are replaced by a single
-- BICONDITIONAL, so the shape is exact in both directions and there is one
-- authoritative rule rather than two partial ones.
--
-- The source-to-authority rule is deliberately UNTOUCHED: row, pricing_group and
-- master remain governed; legacy_batch and legacy_matrix remain temporary
-- (ck_cs_freight_authority_binds_source, and ck_cs_freight_source still omits
-- 'unresolved').

-- The candidate key the composite FK needs. Additive; freight_entries.id is
-- already unique as the primary key, so this adds an index, never a restriction.
alter table public.freight_entries
  add constraint uk_fe_id_version unique (id, freight_set_version_id);

-- The pair must belong together. MATCH SIMPLE is what we want: with both columns
-- null the constraint does not apply, which is exactly the non-master case the
-- shape rule below permits.
alter table public.calculation_snapshots
  drop constraint fk_cs_freight_entry;

alter table public.calculation_snapshots
  add constraint fk_cs_freight_entry_in_version
  foreign key (freight_entry_id, freight_set_version_id)
  references public.freight_entries (id, freight_set_version_id) on delete restrict;

-- fk_cs_freight_set_version is retained as redundant defence: it constrains the
-- version alone, and costs nothing.

-- Exact shape, both directions: master carries both references, and every other
-- source carries neither.
alter table public.calculation_snapshots
  drop constraint ck_cs_master_has_both_refs;
alter table public.calculation_snapshots
  drop constraint ck_cs_temporary_carries_no_governed_ref;

alter table public.calculation_snapshots
  add constraint ck_cs_freight_refs_master_only check (
        (freight_entry_id       is not null) = (freight_source = 'master')
    and (freight_set_version_id is not null) = (freight_source = 'master'));

create index ix_cs_freight_pair
  on public.calculation_snapshots (freight_entry_id, freight_set_version_id);
