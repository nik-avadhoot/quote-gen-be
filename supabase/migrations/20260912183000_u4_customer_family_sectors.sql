-- U4: Customer Families are classified by one or more governed Sectors.
--
-- A Family may serve several Sectors. A Batch remains commercially singular:
-- it selects exactly one of its Family's Sectors, preserving the established
-- Batch -> Sector -> Calculation Default inheritance chain.
--
-- Existing rows are not guessed or backfilled. NOT VALID constraints protect
-- every new/changed Batch immediately while allowing existing null/unclassified
-- rows to remain visible for governed remediation.

create table public.customer_family_sectors (
  family_id  bigint      not null,
  sector_id  bigint      not null,
  created_at timestamptz not null default now(),
  created_by bigint      not null,
  constraint pk_customer_family_sectors primary key (family_id, sector_id),
  constraint fk_cfs_family foreign key (family_id)
    references public.customer_families(id) on delete cascade,
  constraint fk_cfs_sector foreign key (sector_id)
    references public.sectors(id) on delete restrict,
  constraint fk_cfs_created_by foreign key (created_by)
    references public.app_users(id) on delete restrict
);

create index ix_cfs_sector on public.customer_family_sectors (sector_id, family_id);
create index ix_cfs_created_by on public.customer_family_sectors (created_by);

revoke all on table public.customer_family_sectors from anon, authenticated;
grant select on table public.customer_family_sectors to authenticated;
alter table public.customer_family_sectors enable row level security;
alter table public.customer_family_sectors force row level security;

create policy customer_family_sectors_select
  on public.customer_family_sectors for select to authenticated
  using ((select app_private.has_group_cap('read_party_master')));

-- No client INSERT/UPDATE/DELETE grant or policy exists. Membership changes are
-- made only by the governed functions below.

-- Preserve existing explicit commercial facts before the composite Batch FK
-- begins checking writes. This is not an inferred classification: each pair
-- was already stored together on an existing Batch. The oldest such Batch
-- supplies the historical timestamp/creator for the association.
insert into public.customer_family_sectors
  (family_id, sector_id, created_at, created_by)
select distinct on (b.family_id, b.sector_id)
       b.family_id, b.sector_id, b.created_at, b.created_by
  from public.batches b
  join public.customer_families f on f.id = b.family_id
  join public.sectors s on s.id = b.sector_id
 where b.sector_id is not null
 order by b.family_id, b.sector_id, b.created_at, b.id;

create or replace function app_private.assert_customer_family_has_sector()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  -- A synthetic or owner-level cleanup may insert and delete a Family inside
  -- one transaction. There is no surviving Family to classify in that case.
  if not exists (select 1 from public.customer_families where id = new.id) then
    return new;
  end if;
  if not exists (
    select 1 from public.customer_family_sectors fs where fs.family_id = new.id
  ) then
    raise exception 'a Customer Family requires at least one Sector'
      using errcode = '23514';
  end if;
  return new;
end $fn$;

create constraint trigger trg_customer_family_requires_sector
  after insert or update of status on public.customer_families
  deferrable initially deferred
  for each row execute function app_private.assert_customer_family_has_sector();

revoke all on function app_private.assert_customer_family_has_sector() from public;
revoke all on function app_private.assert_customer_family_has_sector() from anon;
revoke all on function app_private.assert_customer_family_has_sector() from authenticated;

-- The composite FK makes "this Batch Sector belongs to this Family" structural.
-- Both constraints apply to new/updated rows immediately; validation of legacy
-- rows waits for a separately authorised remediation of any existing gaps.
alter table public.batches
  add constraint ck_batch_sector_required check (sector_id is not null) not valid;
alter table public.batches
  add constraint fk_batch_family_sector
  foreign key (family_id, sector_id)
  references public.customer_family_sectors(family_id, sector_id)
  on delete restrict not valid;
create index ix_batch_family_sector on public.batches (family_id, sector_id);

-- Replace the old proposal signatures. Family creation and its first Sector
-- membership remain one transaction, so the deferred invariant never observes
-- a half-created Family.
drop function public.create_minimal_prospect(text, bigint);
drop function public.propose_customer_family(text);
drop function app_private.create_minimal_prospect(text, bigint);
drop function app_private.propose_customer_family(text);

create function app_private.propose_customer_family(p_name text, p_sector bigint)
returns bigint
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_code text; v_id bigint;
begin
  if not (app_private.has_group_cap('manage_customer_master')
          or app_private.has_any_plant_cap('make_quote')) then
    raise exception 'manage_customer_master or make_quote at an active plant required'
      using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'a Family name is required' using errcode = '22023';
  end if;
  if p_sector is null or not exists (
    select 1 from public.sectors where id = p_sector and status = 'active'
  ) then
    raise exception 'an active Sector is required' using errcode = '22023';
  end if;

  v_code := app_private.allocate_group_customer_code();
  insert into public.customer_families (name, status, group_customer_code, created_by)
  values (btrim(p_name), 'proposed', v_code, v_me)
  returning id into v_id;

  insert into public.customer_family_sectors (family_id, sector_id, created_by)
  values (v_id, p_sector, v_me);
  return v_id;
end $fn$;

create function app_private.create_minimal_prospect(
  p_display_name text, p_family_id bigint, p_sector bigint)
returns table(party_id bigint, family_id bigint)
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_party bigint; v_family bigint; v_status text;
begin
  if not (app_private.has_group_cap('manage_customer_master')
          or app_private.has_any_plant_cap('make_quote')) then
    raise exception 'manage_customer_master or make_quote at an active plant required'
      using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_display_name is null or btrim(p_display_name) = '' then
    raise exception 'a display name is required' using errcode = '22023';
  end if;

  if p_family_id is null then
    v_family := app_private.propose_customer_family(p_display_name, p_sector);
  else
    select status into v_status from public.customer_families
     where id = p_family_id for update;
    if not found then
      raise exception 'Family not found' using errcode = 'P0002';
    end if;
    if v_status = 'retired' then
      raise exception 'that Family is retired - use its surviving Family instead'
        using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.customer_family_sectors fs where fs.family_id = p_family_id
    ) then
      raise exception 'the selected Family requires at least one Sector'
        using errcode = '23514';
    end if;
    if p_sector is not null and not exists (
      select 1 from public.customer_family_sectors fs
       where fs.family_id = p_family_id and fs.sector_id = p_sector
    ) then
      raise exception 'the selected Sector is not attached to that Family'
        using errcode = '23503';
    end if;
    v_family := p_family_id;
  end if;

  insert into public.parties (display_name, lifecycle_state, status, created_by)
  values (btrim(p_display_name), 'prospect', 'proposed', v_me)
  returning id into v_party;

  insert into public.party_family_memberships
    (party_id, family_id, effective_from, is_current, created_by)
  values (v_party, v_family, current_date, true, v_me);

  return query select v_party, v_family;
end $fn$;

create or replace function app_private.add_customer_family_sector(
  p_family bigint, p_sector bigint, p_expected_content_version integer)
returns void
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_family public.customer_families%rowtype;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_expected_content_version is null then
    raise exception 'the Family content version you read must be supplied'
      using errcode = '22023';
  end if;
  v_me := app_private.current_app_user();

  select * into v_family from public.customer_families
   where id = p_family for update;
  if not found then
    raise exception 'Family not found' using errcode = 'P0002';
  end if;
  if v_family.status = 'retired' then
    raise exception 'a retired Family cannot receive another Sector'
      using errcode = '22023';
  end if;
  if v_family.content_version <> p_expected_content_version then
    raise exception 'the Family changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = 'PT409';
  end if;
  if not exists (select 1 from public.sectors where id = p_sector and status = 'active') then
    raise exception 'an active Sector is required' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.customer_family_sectors fs
     where fs.family_id = p_family and fs.sector_id = p_sector
  ) then
    return;
  end if;

  insert into public.customer_family_sectors (family_id, sector_id, created_by)
  values (p_family, p_sector, v_me);
  update public.customer_families
     set content_version = content_version + 1
   where id = p_family;
end $fn$;

create or replace function app_private.approve_customer_family(
  p_family bigint, p_expected_content_version integer)
returns void
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_n int; v_status text;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if p_expected_content_version is null then
    raise exception 'the Family content version you read must be supplied' using errcode = '22023';
  end if;

  select status into v_status from public.customer_families where id = p_family for update;
  if not found then
    raise exception 'Family not found' using errcode = 'P0002';
  end if;
  if v_status <> 'proposed' then
    raise exception 'only a proposed Family may be approved (currently %)', v_status
      using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.customer_family_sectors fs where fs.family_id = p_family
  ) then
    raise exception 'a Customer Family requires at least one Sector'
      using errcode = '23514';
  end if;

  update public.customer_families
     set status = 'active', approved_by = v_me, approved_at = now(),
         content_version = content_version + 1
   where id = p_family and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'the Family changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = 'PT409';
  end if;
end $fn$;

create function public.propose_customer_family(p_name text, p_sector bigint)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.propose_customer_family(p_name, p_sector);
$fn$;

create function public.create_minimal_prospect(
  p_display_name text, p_family_id bigint default null, p_sector bigint default null)
returns table(party_id bigint, family_id bigint)
language sql security invoker set search_path = '' as $fn$
  select * from app_private.create_minimal_prospect(p_display_name, p_family_id, p_sector);
$fn$;

create function public.add_customer_family_sector(
  p_family bigint, p_sector bigint, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.add_customer_family_sector(
    p_family, p_sector, p_expected_content_version);
$fn$;

-- Stored historical database suites call the former private signatures. Keep
-- private-only compatibility overloads so tests.run_all() is not stranded by
-- this migration. They choose a Sector only for synthetic suite fixtures;
-- no public wrapper or authenticated EXECUTE grant exposes this path to the
-- application. Production callers must always supply the commercial choice.
create function app_private.propose_customer_family(p_name text)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_sector bigint;
begin
  select id into v_sector from public.sectors
   where status = 'active' order by id limit 1;
  if v_sector is null then
    raise exception 'an active Sector is required for the synthetic test fixture'
      using errcode = '22023';
  end if;
  return app_private.propose_customer_family(p_name, v_sector);
end $fn$;

create function app_private.create_minimal_prospect(
  p_display_name text, p_family_id bigint default null)
returns table(party_id bigint, family_id bigint)
language plpgsql security definer set search_path = '' as $fn$
declare v_sector bigint;
begin
  if p_family_id is null then
    select id into v_sector from public.sectors
     where status = 'active' order by id limit 1;
    if v_sector is null then
      raise exception 'an active Sector is required for the synthetic test fixture'
        using errcode = '22023';
    end if;
  end if;
  return query
    select * from app_private.create_minimal_prospect(
      p_display_name, p_family_id, v_sector);
end $fn$;

-- Keep create_batch's established signature while making Sector required and
-- Family-scoped. The remaining body is the activated S9-P implementation.
create or replace function app_private.create_batch(
  p_family bigint, p_plant bigint, p_sector bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_batch bigint; v_pg bigint;
        v_pricing_date date; v_release bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_plant_cap(p_plant, 'make_quote') then
    raise exception 'make_quote is required at that plant' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.customer_families
     where id = p_family and status <> 'retired'
  ) then
    raise exception 'unknown or retired Customer Family' using errcode = '23503';
  end if;
  if p_sector is null then
    raise exception 'a Batch requires one Customer Family Sector' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.customer_family_sectors fs
    join public.sectors s on s.id = fs.sector_id and s.status = 'active'
    where fs.family_id = p_family and fs.sector_id = p_sector
  ) then
    raise exception 'the selected Sector is not attached to that Customer Family'
      using errcode = '23503';
  end if;

  select (now() at time zone p.timezone)::date into v_pricing_date
    from public.plants p where p.id = p_plant;

  select r.id into v_release
    from public.pricing_basis_releases r
   where r.plant_id = p_plant
     and r.status = 'approved'
     and r.is_automatic_default
     and daterange(r.effective_from, r.effective_until, '[]') @> v_pricing_date;

  insert into public.batches (batch_reference, family_id, plant_id, owner_user_id,
                              sector_id, status, created_by,
                              pricing_date, pricing_basis_release_id)
  values ('pending', p_family, p_plant, v_me, p_sector, 'working', v_me,
          v_pricing_date, v_release)
  returning id into v_batch;

  insert into public.batch_edit_locks (batch_id, holder_user_id)
  values (v_batch, v_me);
  insert into public.pricing_groups (batch_id, label, created_by)
  values (v_batch, 'Default', v_me) returning id into v_pg;
  insert into public.delivery_groups (pricing_group_id, batch_id, label, created_by)
  values (v_pg, v_batch, 'Default', v_me);
  insert into public.batch_profile_versions (batch_id, version_no, created_by)
  values (v_batch, 1, v_me);
  return v_batch;
end $fn$;

revoke all on function app_private.propose_customer_family(text, bigint) from public, anon, authenticated;
revoke all on function app_private.create_minimal_prospect(text, bigint, bigint) from public, anon, authenticated;
revoke all on function app_private.add_customer_family_sector(bigint, bigint, integer) from public, anon, authenticated;
revoke all on function app_private.propose_customer_family(text) from public, anon, authenticated;
revoke all on function app_private.create_minimal_prospect(text, bigint) from public, anon, authenticated;

revoke all on function public.propose_customer_family(text, bigint) from public, anon;
grant execute on function public.propose_customer_family(text, bigint) to authenticated;
revoke all on function public.create_minimal_prospect(text, bigint, bigint) from public, anon;
grant execute on function public.create_minimal_prospect(text, bigint, bigint) to authenticated;
revoke all on function public.add_customer_family_sector(bigint, bigint, integer) from public, anon;
grant execute on function public.add_customer_family_sector(bigint, bigint, integer) to authenticated;
