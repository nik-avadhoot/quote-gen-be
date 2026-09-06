-- S5-1: Family D, part one - the group-wide commercial masters.
--
-- Sectors, the versioned system fallbacks, and the approved Payment Terms map.
-- All three are group-wide (CDM-04), so their read predicate is a group
-- capability; but propose/approve authority is PLANT-scoped by the capability
-- model, so a holder at ANY plant may act (§7.5 "P(any, ...)").
--
-- Every master family shares one shape (§4.4): a set row (identity), an
-- immutable version row (the approvable unit), and where needed entry rows under
-- the version. Approved versions are immutable and a correction is a new version
-- (CDM-31/PM-3).
--
-- The transition matrix lives in a trigger, not in the policies, for the reason
-- §7.5 gives: a policy checks USING against the old row and WITH CHECK against
-- the new one independently, so their conjunction is the cartesian product of
-- allowed old-states and allowed new-states and can never express a transition.
-- A BEFORE trigger sees OLD and NEW together and fires for every role, including
-- the BYPASSRLS ones a policy does not reach.

-- ---------------------------------------------------------------- helper
-- §7.5 needs "holds this plant capability at ANY plant" for the group-wide
-- masters. Narrow by construction: one capability key in, one boolean out,
-- no row or attribute exposed.
create or replace function app_private.has_any_plant_cap(p_cap text)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1
      from public.plant_capability_grants g
      join public.capabilities c on c.id = g.capability_id
     where g.app_user_id = (select app_private.current_app_user())
       and c.capability_key = p_cap
       and g.status = 'active');
$fn$;

revoke all on function app_private.has_any_plant_cap(text) from public;
revoke all on function app_private.has_any_plant_cap(text) from anon;
grant execute on function app_private.has_any_plant_cap(text) to authenticated;

-- ---------------------------------------------------------------- sectors
create table public.sectors (
  id          bigint generated always as identity primary key,
  sector_code text        not null,
  name        text        not null,
  status      text        not null default 'active',
  created_at  timestamptz not null default now(),
  created_by  bigint      not null,
  constraint fk_sector_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_sector_code unique (sector_code),
  constraint ck_sector_status check (status in ('active','inactive')),
  constraint ck_sector_code_present check (btrim(sector_code) <> ''),
  constraint ck_sector_name_present check (btrim(name) <> '')
);
create index ix_sector_created_by on public.sectors (created_by);

-- The tier CDM-19's resolution chains consult. margin_pct is NOT NULL by the
-- Sector Margin ruling: a default target margin is a property every Sector
-- maintains, so there is no "sector without a margin" state to represent. Waste
-- and conversion stay nullable because null there means inherit (CDM-19).
create table public.sector_versions (
  id             bigint generated always as identity primary key,
  sector_id      bigint        not null,
  version_no     integer       not null,
  waste_cbb_pct  numeric(7,3)  null,
  waste_pp_pct   numeric(7,3)  null,
  conv_box_rate  numeric(12,4) null,
  conv_pp_rate   numeric(12,4) null,
  margin_pct     numeric(7,3)  not null,
  spec_lang      text          null,
  status         text          not null default 'draft',
  approved_by    bigint        null,
  approved_at    timestamptz   null,
  created_at     timestamptz   not null default now(),
  created_by     bigint        not null,
  constraint fk_sectorv_sector      foreign key (sector_id)   references public.sectors(id)   on delete restrict,
  constraint fk_sectorv_approved_by foreign key (approved_by) references public.app_users(id) on delete restrict,
  constraint fk_sectorv_created_by  foreign key (created_by)  references public.app_users(id) on delete restrict,
  constraint uk_sectorv_version unique (sector_id, version_no),
  constraint uk_sectorv_id_sector unique (id, sector_id),
  constraint ck_sectorv_status  check (status in ('draft','approved','superseded')),
  constraint ck_sectorv_version_no check (version_no >= 1),
  constraint ck_sectorv_margin_range check (margin_pct >= 0 and margin_pct < 100),
  -- ₹/kg rates and percentages are never negative
  constraint ck_sectorv_waste_cbb check (waste_cbb_pct is null or (waste_cbb_pct >= 0 and waste_cbb_pct < 100)),
  constraint ck_sectorv_waste_pp  check (waste_pp_pct  is null or (waste_pp_pct  >= 0 and waste_pp_pct  < 100)),
  constraint ck_sectorv_conv_box  check (conv_box_rate is null or conv_box_rate >= 0),
  constraint ck_sectorv_conv_pp   check (conv_pp_rate  is null or conv_pp_rate  >= 0),
  constraint ck_sectorv_approval_pair check ((approved_by is null) = (approved_at is null))
);
create index ix_sectorv_sector      on public.sector_versions (sector_id);
create index ix_sectorv_approved_by on public.sector_versions (approved_by);
create index ix_sectorv_created_by  on public.sector_versions (created_by);

-- ------------------------------------------ calculation_default_versions
-- The versioned bundle of system fallbacks (CDM-18, CDM-22). The defaults below
-- reproduce today's reachable literals exactly, so establishing this table
-- changes no number that the engine already computes (A-21).
create table public.calculation_default_versions (
  id                     bigint generated always as identity primary key,
  version_no             integer       not null,
  interest_fallback_pct  numeric(7,3)  not null default 0.500,
  waste_cbb_fallback_pct numeric(7,3)  not null default 5.000,
  waste_pp_fallback_pct  numeric(7,3)  not null default 5.000,
  conv_box_fallback_rate numeric(12,4) not null default 7.0000,
  conv_pp_fallback_rate  numeric(12,4) not null default 12.5000,
  margin_fallback_pct    numeric(7,3)  not null default 8.000,
  rounding_step          numeric(8,4)  not null default 0.0500,
  engine_version         text          not null,
  rounding_rule_version  text          not null,
  status                 text          not null default 'draft',
  approved_by            bigint        null,
  approved_at            timestamptz   null,
  created_at             timestamptz   not null default now(),
  created_by             bigint        not null,
  constraint fk_cdv_approved_by foreign key (approved_by) references public.app_users(id) on delete restrict,
  constraint fk_cdv_created_by  foreign key (created_by)  references public.app_users(id) on delete restrict,
  constraint uk_cdv_version unique (version_no),
  constraint ck_cdv_status check (status in ('draft','approved','superseded')),
  constraint ck_cdv_version_no check (version_no >= 1),
  constraint ck_cdv_interest_range check (interest_fallback_pct >= 0 and interest_fallback_pct < 100),
  constraint ck_cdv_margin_range   check (margin_fallback_pct   >= 0 and margin_fallback_pct   < 100),
  constraint ck_cdv_waste_cbb      check (waste_cbb_fallback_pct >= 0 and waste_cbb_fallback_pct < 100),
  constraint ck_cdv_waste_pp       check (waste_pp_fallback_pct  >= 0 and waste_pp_fallback_pct  < 100),
  constraint ck_cdv_conv_box       check (conv_box_fallback_rate >= 0),
  constraint ck_cdv_conv_pp        check (conv_pp_fallback_rate  >= 0),
  constraint ck_cdv_rounding_step  check (rounding_step > 0),
  constraint ck_cdv_engine_version check (btrim(engine_version) <> ''),
  constraint ck_cdv_rounding_rule  check (btrim(rounding_rule_version) <> ''),
  constraint ck_cdv_approval_pair  check ((approved_by is null) = (approved_at is null))
);
create index ix_cdv_approved_by on public.calculation_default_versions (approved_by);
create index ix_cdv_created_by  on public.calculation_default_versions (created_by);

-- --------------------------------------- payment_interest_map_entries
-- CDM-18's approved map, a CLOSED LIST by ruling. ck_pime_closed_list makes the
-- ruling structural: a credit-days value outside 30/45/60/90 cannot be stored at
-- all, so "other wording is descriptive only and does not calculate" is enforced
-- by the database rather than by convention. There is deliberately no
-- is_open_ended column and no band semantics - lookup is exact match, and a miss
-- falls to calculation_default_versions.interest_fallback_pct, which is 0.500 and
-- never 1.500. Opening the list later is a migration plus a new map version, not
-- a configuration change; that friction is the point.
create table public.payment_interest_map_entries (
  id                             bigint generated always as identity primary key,
  calculation_default_version_id bigint       not null,
  credit_days                    integer      not null,
  interest_pct                   numeric(7,3) not null,
  created_at                     timestamptz  not null default now(),
  created_by                     bigint       not null,
  constraint fk_pime_cdv        foreign key (calculation_default_version_id)
    references public.calculation_default_versions(id) on delete cascade,
  constraint fk_pime_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_pime unique (calculation_default_version_id, credit_days),
  constraint ck_pime_days_positive check (credit_days > 0),
  constraint ck_pime_closed_list   check (credit_days in (30,45,60,90)),
  constraint ck_pime_interest_range check (interest_pct >= 0 and interest_pct < 100)
);
create index ix_pime_cdv        on public.payment_interest_map_entries (calculation_default_version_id);
create index ix_pime_created_by on public.payment_interest_map_entries (created_by);

-- ---------------------------------------------------------------- grants
do $$
declare t text;
begin
  foreach t in array array['sectors','sector_versions','calculation_default_versions',
                           'payment_interest_map_entries']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant insert, update on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- policies
-- Read: any user holding a granted read capability. These are group-wide
-- reference tiers with no plant or customer content, so they are visible to a
-- granted user of either master area - but never to an ungranted one, and never
-- to anon.
do $$
declare t text;
begin
  foreach t in array array['sectors','sector_versions','calculation_default_versions',
                           'payment_interest_map_entries']
  loop
    execute format($p$
      create policy %1$s_select on public.%1$I for select to authenticated
        using ( (select app_private.has_group_cap('read_party_master'))
             or (select app_private.has_group_cap('read_construction_library')) )$p$, t);
    execute format($p$
      create policy %1$s_insert on public.%1$I for insert to authenticated
        with check ( created_by = (select app_private.current_app_user())
                     and (select app_private.has_any_plant_cap('propose_commercial_master')) )$p$, t);
    -- Authorisation and coarse state envelope only. Which OLD -> NEW transition
    -- is legal, and which columns may move with it, is the trigger's job.
    execute format($p$
      create policy %1$s_update on public.%1$I for update to authenticated
        using      ( (select app_private.has_any_plant_cap('propose_commercial_master'))
                  or (select app_private.has_any_plant_cap('approve_commercial_master')) )
        with check ( (select app_private.has_any_plant_cap('propose_commercial_master'))
                  or (select app_private.has_any_plant_cap('approve_commercial_master')) )$p$, t);
  end loop;
end $$;

-- No DELETE policy on any Family D table (CDM-31).

-- ------------------------------------------------- the transition matrix
-- One function, reused by every group-scoped master version table. TG_ARGV[0]
-- names the terminal state this table uses ('superseded' here, 'withdrawn' for
-- the plant-scoped sets in S5-2), so the shape is stated once.
--
-- Exhaustive: anything not listed raises. Attribution is written by the trigger
-- from current_app_user() and now() and is never accepted from the client
-- (CDM-34), so an approval cannot smuggle in a content edit either.
create or replace function app_private.guard_master_version_transition()
returns trigger language plpgsql set search_path = '' as $fn$
declare
  v_terminal text := tg_argv[0];
  v_me bigint := app_private.current_app_user();
begin
  -- an approved version is immutable except for the one legal exit
  if old.status = 'approved' and new.status = old.status then
    raise exception 'an approved % is immutable - a correction is a new version (CDM-31)', tg_table_name
      using errcode = '23514';
  end if;

  if new.status = old.status then
    -- draft -> draft: ordinary content editing
    if old.status <> 'draft' then
      raise exception 'a % version in state % cannot be edited', tg_table_name, old.status
        using errcode = '23514';
    end if;
    if not app_private.has_any_plant_cap('propose_commercial_master') then
      raise exception 'propose_commercial_master is required to edit a draft' using errcode = '42501';
    end if;
    -- approval fields may not be set by an edit
    if new.approved_by is distinct from old.approved_by
       or new.approved_at is distinct from old.approved_at then
      raise exception 'approval fields are set by approval, never by an edit (CDM-34)'
        using errcode = '23514';
    end if;
    return new;
  end if;

  if old.status = 'draft' and new.status = 'approved' then
    if not app_private.has_any_plant_cap('approve_commercial_master') then
      raise exception 'approve_commercial_master is required to approve' using errcode = '42501';
    end if;
    -- approval carries nothing but its own attribution
    new.approved_by := v_me;
    new.approved_at := now();
    return new;
  end if;

  if old.status = 'approved' and new.status = v_terminal then
    if not app_private.has_any_plant_cap('approve_commercial_master') then
      raise exception 'approve_commercial_master is required to % a version', v_terminal
        using errcode = '42501';
    end if;
    return new;
  end if;

  raise exception 'illegal % transition % -> % (CDM-31)', tg_table_name, old.status, new.status
    using errcode = '23514';
end $fn$;

create trigger trg_sectorv_transition
  before update on public.sector_versions
  for each row execute function app_private.guard_master_version_transition('superseded');

create trigger trg_cdv_transition
  before update on public.calculation_default_versions
  for each row execute function app_private.guard_master_version_transition('superseded');

-- Map entries belong to their draft version as one editing unit (§4.9), so they
-- are not independently versioned - but they must not change once the version
-- they belong to is approved.
create or replace function app_private.guard_map_entry_follows_version()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_status text; v_id bigint;
begin
  v_id := coalesce(new.calculation_default_version_id, old.calculation_default_version_id);
  select status into v_status from public.calculation_default_versions where id = v_id;
  if v_status is distinct from 'draft' then
    raise exception 'the Payment Terms map may only be edited while its version is draft (found %)',
      coalesce(v_status,'unknown') using errcode = '23514';
  end if;
  return coalesce(new, old);
end $fn$;

create trigger trg_pime_follows_version
  before insert or update or delete on public.payment_interest_map_entries
  for each row execute function app_private.guard_map_entry_follows_version();

revoke all on function app_private.guard_master_version_transition() from public;
revoke all on function app_private.guard_master_version_transition() from anon;
revoke all on function app_private.guard_master_version_transition() from authenticated;
revoke all on function app_private.guard_map_entry_follows_version() from public;
revoke all on function app_private.guard_map_entry_follows_version() from anon;
revoke all on function app_private.guard_map_entry_follows_version() from authenticated;