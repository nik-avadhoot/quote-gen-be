-- S5-3: Family E - the Pricing Basis Release.
--
-- CDM-26: an internal, immutable, plant-specific approved bundle of Rates,
-- Freight, Sector defaults and Calculation Defaults. Not customer confirmation.
-- One automatic default applies per plant/date; approved ALTERNATIVES may
-- coexist. Releases may be retrospective or future-effective. Corrections create
-- replacements; withdrawal never rewrites history.
--
-- AMENDMENT 3 APPLIED. Revision 1's polymorphic
-- pricing_basis_components(component_type, component_version_id) had no foreign
-- key, so a Release could carry a missing component or one pointing at the wrong
-- table. It is replaced by four typed NOT NULL foreign keys on the Release
-- itself, which also enforces the arity CDM-26 requires: all four components,
-- always, or no row at all.
--
-- STRENGTHENED beyond §4.5, by the technique §5 already mandates. Two of the
-- four components are plant-owned, so a NAG Release must not be able to
-- reference a PUN rate or freight version. Those two FKs are therefore
-- COMPOSITE against the [scope] keys S5-2 created:
--
--   (rate_set_version_id,    plant_id) -> rate_set_versions(id, plant_id)
--   (freight_set_version_id, plant_id) -> freight_set_versions(id, plant_id)
--
-- Both bind the Release's own plant_id, so cross-plant component leakage is
-- structurally impossible rather than merely checked. Sector and Calculation
-- Defaults are group-wide and take ordinary FKs.
--
-- V-3 RESOLVED, and resolved the stronger way. §17.3 left open whether "all
-- Release components must already be approved" could rest on the approval RPC
-- plus a pgtap pairing, or needed a trigger. It cannot be a CHECK, because a
-- CHECK may not contain a subquery. An RPC-only check is silently bypassed by
-- any later write path that forgets to call it, and by every BYPASSRLS role.
-- This slice adds the TRIGGER, so the rule binds every writer.

create extension if not exists btree_gist with schema extensions;

create table public.pricing_basis_releases (
  id                             bigint      generated always as identity primary key,
  plant_id                       bigint      not null,
  release_name                   text        null,
  effective_from                 date        not null,
  effective_until                date        null,
  is_automatic_default           boolean     not null default false,
  rate_set_version_id            bigint      not null,
  freight_set_version_id         bigint      not null,
  sector_version_id              bigint      not null,
  calculation_default_version_id bigint      not null,
  status                         text        not null default 'draft',
  self_approved                  boolean     not null default false,
  proposed_by                    bigint      not null,
  approved_by                    bigint      null,
  approved_at                    timestamptz null,
  withdrawn_by                   bigint      null,
  withdrawn_at                   timestamptz null,
  created_at                     timestamptz not null default now(),
  constraint fk_pbr_plant  foreign key (plant_id) references public.plants(id) on delete restrict,
  -- the two plant-owned components bind the Release's own plant
  constraint fk_pbr_rate    foreign key (rate_set_version_id, plant_id)
    references public.rate_set_versions(id, plant_id) on delete restrict,
  constraint fk_pbr_freight foreign key (freight_set_version_id, plant_id)
    references public.freight_set_versions(id, plant_id) on delete restrict,
  -- the two group-wide components
  constraint fk_pbr_sector  foreign key (sector_version_id)
    references public.sector_versions(id) on delete restrict,
  constraint fk_pbr_cdv     foreign key (calculation_default_version_id)
    references public.calculation_default_versions(id) on delete restrict,
  constraint fk_pbr_proposed_by  foreign key (proposed_by)  references public.app_users(id) on delete restrict,
  constraint fk_pbr_approved_by  foreign key (approved_by)  references public.app_users(id) on delete restrict,
  constraint fk_pbr_withdrawn_by foreign key (withdrawn_by) references public.app_users(id) on delete restrict,
  constraint ck_pbr_status check (status in ('draft','approved','withdrawn')),
  constraint ck_pbr_dates  check (effective_until is null or effective_until >= effective_from),
  -- CDM-26: only an approved Release may be the automatic default
  constraint ck_pbr_default_requires_approved check (not is_automatic_default or status = 'approved'),
  constraint ck_pbr_approval_pair   check ((approved_by  is null) = (approved_at  is null)),
  constraint ck_pbr_withdrawal_pair check ((withdrawn_by is null) = (withdrawn_at is null)),
  constraint ck_pbr_self_approved_is_approved check (not self_approved or approved_at is not null)
);
create index ix_pbr_plant_effective on public.pricing_basis_releases (plant_id, effective_from);
create index ix_pbr_status          on public.pricing_basis_releases (status);
create index ix_pbr_rate            on public.pricing_basis_releases (rate_set_version_id, plant_id);
create index ix_pbr_freight         on public.pricing_basis_releases (freight_set_version_id, plant_id);
create index ix_pbr_sector          on public.pricing_basis_releases (sector_version_id);
create index ix_pbr_cdv             on public.pricing_basis_releases (calculation_default_version_id);
create index ix_pbr_proposed_by     on public.pricing_basis_releases (proposed_by);
create index ix_pbr_approved_by     on public.pricing_basis_releases (approved_by);
create index ix_pbr_withdrawn_by    on public.pricing_basis_releases (withdrawn_by);

-- CDM-26 default-coverage exclusivity. Approved ALTERNATIVES may overlap freely -
-- that is the point of an alternative. Only the automatic DEFAULT is exclusive,
-- and only among approved Releases, per plant, over overlapping date ranges.
-- A partial exclusion constraint says exactly that and nothing more.
--
-- Recommended over an RPC-only check because §2 requires enforcement rather than
-- documentation: an RPC check is silently bypassed by any later write path that
-- forgets to call it. btree_gist supplies the `=` operator class that lets
-- plant_id sit in a GiST index beside the range.
alter table public.pricing_basis_releases
  add constraint ex_pbr_default_no_overlap
  exclude using gist (
    plant_id with =,
    daterange(effective_from, effective_until, '[]') with &&
  ) where (is_automatic_default and status = 'approved');

-- ---------------------------------------------------------------- grants
revoke all on public.pricing_basis_releases from anon, authenticated;
grant select on public.pricing_basis_releases to authenticated;
grant insert, update on public.pricing_basis_releases to authenticated;
alter table public.pricing_basis_releases enable row level security;
alter table public.pricing_basis_releases force  row level security;

-- ---------------------------------------------------------------- policies
create policy pricing_basis_releases_select on public.pricing_basis_releases for select to authenticated
  using ( (select app_private.has_plant_cap(plant_id,'plant_access')) );

create policy pricing_basis_releases_insert on public.pricing_basis_releases for insert to authenticated
  with check ( status = 'draft'
               and proposed_by = (select app_private.current_app_user())
               and (select app_private.has_plant_cap(plant_id,'propose_commercial_master')) );

-- ONE policy per §7.5's consolidation. Authorisation and the coarse state
-- envelope only; the transition matrix is the trigger's job, because a policy
-- checks USING against the old row and WITH CHECK against the new one
-- independently and can never express a transition.
create policy pricing_basis_releases_update on public.pricing_basis_releases for update to authenticated
  using      ( status in ('draft','approved')
               and ( (select app_private.has_plant_cap(plant_id,'propose_commercial_master'))
                  or (select app_private.has_plant_cap(plant_id,'approve_commercial_master')) ) )
  with check ( status in ('draft','approved','withdrawn')
               and ( (select app_private.has_plant_cap(plant_id,'propose_commercial_master'))
                  or (select app_private.has_plant_cap(plant_id,'approve_commercial_master')) ) );

-- No DELETE policy (CDM-26/CDM-31): a Release is withdrawn, never deleted.

-- ------------------------------- V-3: components must already be approved
-- Fires for every role on every write to a Release, so the rule cannot be
-- bypassed by a path that forgets the RPC, nor by a BYPASSRLS role.
create or replace function app_private.guard_release_components_approved()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_bad text;
begin
  select string_agg(x.what, ', ') into v_bad from (
    select 'rate_set_version'   as what from public.rate_set_versions
      where id = new.rate_set_version_id and status <> 'approved'
    union all
    select 'freight_set_version' from public.freight_set_versions
      where id = new.freight_set_version_id and status <> 'approved'
    union all
    select 'sector_version' from public.sector_versions
      where id = new.sector_version_id and status <> 'approved'
    union all
    select 'calculation_default_version' from public.calculation_default_versions
      where id = new.calculation_default_version_id and status <> 'approved'
  ) x;

  if v_bad is not null then
    raise exception 'a Pricing Basis Release may only cite APPROVED components - unapproved: % (CDM-27)', v_bad
      using errcode = '23514';
  end if;
  return new;
end $fn$;

create trigger trg_pbr_components_approved
  before insert or update on public.pricing_basis_releases
  for each row execute function app_private.guard_release_components_approved();

-- ------------------------------------------------- the transition matrix
-- §7.5's table, made exhaustive. Anything unlisted raises.
--
--   draft     -> draft      propose cap        any content column
--   draft     -> approved   APPROVE cap        status + attribution only
--   approved  -> withdrawn  APPROVE cap        status + attribution only
--   approved  -> approved   rejected - an approved Release is immutable (CDM-26),
--                           is_automatic_default included; a different default is
--                           a new Release
--   approved  -> draft      rejected
--   draft     -> withdrawn  rejected
--   withdrawn -> anything   rejected - terminal; corrections create replacements
--
-- plant_id is immutable in every transition, so the policy's USING and WITH
-- CHECK capability tests cannot be made to disagree by moving the row.
--
-- CDM-27 self-approval: a caller holding ONLY propose cannot approve. A caller
-- holding BOTH may, and it is recorded as self_approved rather than refused -
-- audited emergency self-approval is permitted. The audit_events row §7.5 also
-- describes belongs to Family H and is carried forward to the audit phase; the
-- flag on the row is what S5 can record today.
create or replace function app_private.guard_pricing_basis_transition()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_me bigint := app_private.current_app_user();
begin
  if new.plant_id is distinct from old.plant_id then
    raise exception 'plant_id is immutable on a Pricing Basis Release' using errcode = '23514';
  end if;

  if old.status = 'draft' and new.status = 'draft' then
    if not app_private.has_plant_cap(new.plant_id,'propose_commercial_master') then
      raise exception 'propose_commercial_master is required at that plant' using errcode = '42501';
    end if;
    if new.approved_by is distinct from old.approved_by
       or new.approved_at is distinct from old.approved_at
       or new.self_approved is distinct from old.self_approved then
      raise exception 'approval fields are set by approval, never by an edit (CDM-34)'
        using errcode = '23514';
    end if;
    return new;

  elsif old.status = 'draft' and new.status = 'approved' then
    if not app_private.has_plant_cap(new.plant_id,'approve_commercial_master') then
      raise exception 'approve_commercial_master is required to approve a Release' using errcode = '42501';
    end if;
    -- approval may not smuggle a content edit
    if new.effective_from is distinct from old.effective_from
       or new.effective_until is distinct from old.effective_until
       or new.rate_set_version_id is distinct from old.rate_set_version_id
       or new.freight_set_version_id is distinct from old.freight_set_version_id
       or new.sector_version_id is distinct from old.sector_version_id
       or new.calculation_default_version_id is distinct from old.calculation_default_version_id
       or new.release_name is distinct from old.release_name then
      raise exception 'approval may change status and attribution only, never content (CDM-31)'
        using errcode = '23514';
    end if;
    new.approved_by   := v_me;
    new.approved_at   := now();
    -- CDM-27: permitted, but never silent
    new.self_approved := (v_me is not null and v_me = old.proposed_by);
    return new;

  elsif old.status = 'approved' and new.status = 'withdrawn' then
    if not app_private.has_plant_cap(new.plant_id,'approve_commercial_master') then
      raise exception 'approve_commercial_master is required to withdraw a Release' using errcode = '42501';
    end if;
    new.withdrawn_by := v_me;
    new.withdrawn_at := now();
    -- a withdrawn Release is no longer any plant's automatic default
    new.is_automatic_default := false;
    return new;
  end if;

  raise exception 'illegal Pricing Basis transition % -> % (CDM-26)', old.status, new.status
    using errcode = '23514';
end $fn$;

create trigger trg_pbr_transition
  before update on public.pricing_basis_releases
  for each row execute function app_private.guard_pricing_basis_transition();

revoke all on function app_private.guard_release_components_approved() from public;
revoke all on function app_private.guard_release_components_approved() from anon;
revoke all on function app_private.guard_release_components_approved() from authenticated;
revoke all on function app_private.guard_pricing_basis_transition() from public;
revoke all on function app_private.guard_pricing_basis_transition() from anon;
revoke all on function app_private.guard_pricing_basis_transition() from authenticated;