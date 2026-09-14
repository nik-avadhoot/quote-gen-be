-- S9-P/3: the Batch's Pricing Date and Pricing Basis Release.
--
-- WHAT WAS MISSING. `pricing_basis_release_id` and `pricing_date` existed only
-- on calculation_snapshots - that is, only on the FROZEN OUTPUT. A working Batch
-- recorded neither, so the database could not say which Release governed it or
-- as at what date, and a freshness test could only read them back out of the
-- payload it was checking. Both now live on the Batch.
--
-- THE ASYMMETRY IS DELIBERATE. pricing_date is NOT NULL because there is always
-- a today. pricing_basis_release_id is NULLABLE because a Release may genuinely
-- not exist for that date - CDM-27's calendar gap - and blocking Batch creation
-- on a master-data gap would stop unrelated work. Null is legal on a working
-- Batch, refused at Calculate, and refused at Send.
--
-- pricing_basis_is_deliberate RECORDS THE MODE OF SELECTION, NOT THE SELECTOR.
-- `true` means an approved alternative was chosen rather than the automatic
-- default. Per CDM-27 that choice is the MAKER's, so this flag does not attest
-- who chose, does not imply Checker involvement, and must never be read as an
-- approval signal. CDM-27 makes reasons optional initially, so no reason column
-- is added.
--
-- THE FOREIGN KEY IS COMPOSITE ON PURPOSE. (release, plant) -> (id, plant_id)
-- makes a Release from ANOTHER PLANT unrepresentable rather than merely refused
-- by a check somewhere - the same scope-binding device used throughout this
-- schema. It needs a matching unique key on the parent, added here.
--
-- pricing_date DEFAULTS TO THE PLANT'S LOCAL DATE, not the server's, and
-- create_batch sets it explicitly in S9-P/5. The column default below exists so
-- that any insert path which does not name it still lands a real date rather
-- than failing; CURRENT_DATE is the server's notion and is deliberately NOT
-- relied upon for the governed path, where S9-P/5 computes
-- (now() at time zone plants.timezone)::date instead (S12.4, CDM-34).

alter table public.pricing_basis_releases
  add constraint uk_pbr_id_plant unique (id, plant_id);

alter table public.batches
  add column pricing_date                date    not null default current_date,
  add column pricing_basis_release_id    bigint  null,
  add column pricing_basis_is_deliberate boolean not null default false;

alter table public.batches
  add constraint fk_batch_pricing_basis
    foreign key (pricing_basis_release_id, plant_id)
    references public.pricing_basis_releases (id, plant_id) on delete restrict,
  -- a deliberate selection of nothing is not a state
  add constraint ck_batch_deliberate_needs_release
    check (not pricing_basis_is_deliberate or pricing_basis_release_id is not null);

create index ix_batch_pricing_basis on public.batches (pricing_basis_release_id);

comment on column public.batches.pricing_date is
  'S9-P: the date the commercial basis is read as at. Set by create_batch to the PRODUCING PLANT''s local date (S12.4/CDM-34), never the server''s. Not DM-5 Reprice - this is only the durable place a Pricing Date can live.';
comment on column public.batches.pricing_basis_release_id is
  'S9-P: the approved Pricing Basis Release governing every row of this Batch. NULL is legal on a working Batch when no automatic default covers pricing_date (CDM-27 calendar gap) and is refused at Send.';
comment on column public.batches.pricing_basis_is_deliberate is
  'S9-P: false = the automatic default was taken; true = an approved alternative was deliberately selected (CDM-27, a MAKER act). Records the MODE of selection only - it attests nothing about who selected and is not an approval signal.';