-- S9-P/4: Path A - temporary freight, narrowly persisted (D-N, D-Q).
--
-- CDM-17: "Pricing Group owns the single freight value entering calculation."
-- Two further reasons this is the right home rather than merely a permitted one:
-- U4 restates legacy_batch into GOVERNED Pricing Group freight, so the value is
-- already where its successor will live and retirement is a transformation in
-- place; and legacy_matrix is consulted only in `master` mode, which is a
-- Pricing Group property.
--
-- ONE PAIR PER GROUP. A group stores EITHER a legacy_batch fallback OR a
-- legacy_matrix fallback, never both. The pair records the temporary value
-- available to the chain, not a catalogue of every tier that might produce one.
--
-- THE RESOLVER SELECTS EXACTLY ONE EFFECTIVE SOURCE, and that settles what a
-- stored value means:
--
--   legacy_batch   sits ABOVE the Pricing Group tier. It wins over manual,
--                  ex_factory and master. Storing it alongside a governed MODE
--                  statement would make that statement ineffective - a real
--                  contradiction, constrained below.
--   legacy_matrix  sits BELOW the approved master. It is a LOWER-PRIORITY
--                  FALLBACK. When an upper tier resolves it is simply not
--                  selected. That is the chain working, not a contradiction,
--                  and it needs no guard.
--
-- WHY ONLY legacy_batch IS CONSTRAINED, AND ONLY IN TWO MODES. `manual` and
-- `ex_factory` are explicit Maker statements of a specific VALUE, so a group
-- holding both would apply the temporary value and silently discard the governed
-- one the Maker just stated. `master` mode is deliberately excluded: there the
-- Maker stated a DELEGATION, not a value, so legacy_batch winning is the
-- ratified S8 chain behaving as designed pending U4.
--
-- NO GUARD TRIGGER IS CREATED, and none should be. A trigger on pricing_groups
-- fires only on writes to pricing_groups, while every input deciding whether the
-- approved master resolves lives elsewhere - delivery_groups.ship_to_location_id,
-- delivery_groups.status, batches.pricing_basis_release_id, freight_entries. A
-- guard here would catch one of five paths and give false assurance on the other
-- four. The invariant lives in the resolver, and S7-R proves it there.
--
-- CLEARING. Both fields are cleared when U4 restates legacy_batch into governed
-- Pricing Group freight - the value has been superseded by a governed one and
-- must not remain as a higher-priority tier that would outrank it. Nothing
-- requires clearing legacy_matrix merely because an upper tier currently
-- resolves; a fallback that is not selected is doing its job.

alter table public.pricing_groups
  add column legacy_freight_value  numeric(12,4) null,
  add column legacy_freight_source text          null;

alter table public.pricing_groups
  -- exactly the two temporary tiers, and no governed source. A governed value
  -- has its own home - freight_manual_value, the ex_factory mode, or the
  -- approved Freight Master via the basis - and admitting one here would create
  -- a second authority over the same number.
  add constraint ck_pg_legacy_freight_source check (
    legacy_freight_source is null
    or legacy_freight_source in ('legacy_batch','legacy_matrix') ),
  -- half a reference is not a reference: value without provenance and provenance
  -- without value are equally unrepresentable
  add constraint ck_pg_legacy_freight_paired check (
    (legacy_freight_value is null) = (legacy_freight_source is null) ),
  add constraint ck_pg_legacy_freight_non_negative check (
    legacy_freight_value is null or legacy_freight_value >= 0 ),
  -- the ONE narrow rule: legacy_batch outranks the Pricing Group tier, so it may
  -- not coexist with a governed MODE statement. legacy_matrix is unrestricted in
  -- every mode - dormant in manual/ex_factory, a fallback in master.
  add constraint ck_pg_legacy_batch_not_with_governed_mode check (
    legacy_freight_source is distinct from 'legacy_batch'
    or freight_mode = 'master' );

comment on column public.pricing_groups.legacy_freight_value is
  'S9-P Path A: the rate a TEMPORARY freight tier produced, Rs/kg. Retired when U3 replaces the legacy matrix and U4 restates the legacy Batch override into governed Pricing Group freight.';
comment on column public.pricing_groups.legacy_freight_source is
  'S9-P Path A: which temporary tier produced the value - legacy_batch (above the Pricing Group tier) or legacy_matrix (below the approved master, a lower-priority fallback). Never a governed source.';