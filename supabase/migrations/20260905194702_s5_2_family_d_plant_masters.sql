-- S5-2: Family D, part two - the plant-owned commercial masters.
--
-- Rates and Freight are plant-owned (CDM-04/CDM-26), so every predicate reads
-- the row's OWN plant_id and a wrong-plant caller gets zero rows rather than a
-- filtered view. The same set / version / entry shape and the same transition
-- matrix as the group masters, with the capability resolved per plant instead of
-- at any plant.
--
-- Scope columns, the S4 deviation applied again and for the same reasons. §4.4
-- declares uk_rate_set_id_plant (id, plant_id) and uk_freight_set_id_plant
-- (id, plant_id), both marked [scope], and nothing consumes them. They exist to
-- be composite-FK targets - the technique §5 mandates - so versions carry a
-- redundant plant_id bound to their set, and entries carry one bound to their
-- version. Three consequences, all structural:
--
--   1. every RLS predicate is one column read plus one helper call, no join;
--   2. a version cannot be written under a plant its set does not belong to,
--      and an entry cannot be written under a plant its version does not;
--   3. the transition trigger can resolve the plant from the row itself, so
--      approval authority is checked against the right plant without a lookup.
--
-- CDM-17's silent-zero source is closed by omission: freight_entries.rate is
-- not null with NO default, so a missing origin/destination pair is ABSENT and
-- can never be read as zero.

-- ------------------------------------------------------------- rate sets
create table public.rate_sets (
  id         bigint generated always as identity primary key,
  plant_id   bigint      not null,
  name       text        not null,
  status     text        not null default 'active',
  created_at timestamptz not null default now(),
  created_by bigint      not null,
  constraint fk_rate_set_plant      foreign key (plant_id)   references public.plants(id)    on delete restrict,
  constraint fk_rate_set_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_rate_set_id_plant unique (id, plant_id),
  constraint ck_rate_set_status check (status in ('active','inactive')),
  constraint ck_rate_set_name check (btrim(name) <> '')
);
create index ix_rate_set_plant      on public.rate_sets (plant_id);
create index ix_rate_set_created_by on public.rate_sets (created_by);

create table public.rate_set_versions (
  id          bigint generated always as identity primary key,
  rate_set_id bigint      not null,
  plant_id    bigint      not null,
  version_no  integer     not null,
  status      text        not null default 'draft',
  approved_by bigint      null,
  approved_at timestamptz null,
  created_at  timestamptz not null default now(),
  created_by  bigint      not null,
  constraint fk_rsv_set         foreign key (rate_set_id, plant_id) references public.rate_sets(id, plant_id) on delete restrict,
  constraint fk_rsv_approved_by foreign key (approved_by) references public.app_users(id) on delete restrict,
  constraint fk_rsv_created_by  foreign key (created_by)  references public.app_users(id) on delete restrict,
  constraint uk_rsv_version  unique (rate_set_id, version_no),
  constraint uk_rsv_id_set    unique (id, rate_set_id),
  constraint uk_rsv_id_plant  unique (id, plant_id),
  constraint ck_rsv_status check (status in ('draft','approved','withdrawn')),
  constraint ck_rsv_version_no check (version_no >= 1),
  constraint ck_rsv_approval_pair check ((approved_by is null) = (approved_at is null))
);
create index ix_rsv_set         on public.rate_set_versions (rate_set_id, plant_id);
create index ix_rsv_plant       on public.rate_set_versions (plant_id);
create index ix_rsv_approved_by on public.rate_set_versions (approved_by);
create index ix_rsv_created_by  on public.rate_set_versions (created_by);

create table public.rate_entries (
  id                  bigint        generated always as identity primary key,
  rate_set_version_id bigint        not null,
  plant_id            bigint        not null,
  grade_code          text          not null,
  description         text          null,
  price               numeric(12,4) not null,
  discount            numeric(12,4) not null default 0,
  freight             numeric(12,4) not null default 0,
  interest_pct        numeric(7,3)  null,
  created_at          timestamptz   not null default now(),
  created_by          bigint        not null,
  constraint fk_re_version    foreign key (rate_set_version_id, plant_id)
    references public.rate_set_versions(id, plant_id) on delete cascade,
  constraint fk_re_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_rate_entry unique (rate_set_version_id, grade_code),
  constraint ck_re_grade    check (btrim(grade_code) <> ''),
  constraint ck_re_price    check (price >= 0),
  constraint ck_re_discount check (discount >= 0),
  constraint ck_re_freight  check (freight >= 0),
  constraint ck_re_interest check (interest_pct is null or (interest_pct >= 0 and interest_pct < 100))
);
create index ix_re_version    on public.rate_entries (rate_set_version_id, plant_id);
create index ix_re_plant      on public.rate_entries (plant_id);
create index ix_re_created_by on public.rate_entries (created_by);

-- ---------------------------------------------------------- freight sets
create table public.freight_sets (
  id         bigint generated always as identity primary key,
  plant_id   bigint      not null,
  name       text        not null,
  status     text        not null default 'active',
  created_at timestamptz not null default now(),
  created_by bigint      not null,
  constraint fk_freight_set_plant      foreign key (plant_id)   references public.plants(id)    on delete restrict,
  constraint fk_freight_set_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_freight_set_id_plant unique (id, plant_id),
  constraint ck_freight_set_status check (status in ('active','inactive')),
  constraint ck_freight_set_name check (btrim(name) <> '')
);
create index ix_freight_set_plant      on public.freight_sets (plant_id);
create index ix_freight_set_created_by on public.freight_sets (created_by);

create table public.freight_set_versions (
  id             bigint      generated always as identity primary key,
  freight_set_id bigint      not null,
  plant_id       bigint      not null,
  version_no     integer     not null,
  effective_from date        null,
  status         text        not null default 'draft',
  approved_by    bigint      null,
  approved_at    timestamptz null,
  created_at     timestamptz not null default now(),
  created_by     bigint      not null,
  constraint fk_fsv_set         foreign key (freight_set_id, plant_id) references public.freight_sets(id, plant_id) on delete restrict,
  constraint fk_fsv_approved_by foreign key (approved_by) references public.app_users(id) on delete restrict,
  constraint fk_fsv_created_by  foreign key (created_by)  references public.app_users(id) on delete restrict,
  constraint uk_fsv_version unique (freight_set_id, version_no),
  constraint uk_fsv_id_set   unique (id, freight_set_id),
  constraint uk_fsv_id_plant unique (id, plant_id),
  constraint ck_fsv_status check (status in ('draft','approved','withdrawn')),
  constraint ck_fsv_version_no check (version_no >= 1),
  constraint ck_fsv_approval_pair check ((approved_by is null) = (approved_at is null))
);
create index ix_fsv_set         on public.freight_set_versions (freight_set_id, plant_id);
create index ix_fsv_plant       on public.freight_set_versions (plant_id);
create index ix_fsv_approved_by on public.freight_set_versions (approved_by);
create index ix_fsv_created_by  on public.freight_set_versions (created_by);

-- A missing (origin, destination) pair is ABSENT, not zero. `rate` is not null
-- with no default, so the database cannot manufacture the silent zero CDM-17
-- exists to close.
create table public.freight_entries (
  id                      bigint        generated always as identity primary key,
  freight_set_version_id  bigint        not null,
  plant_id                bigint        not null,
  origin_plant_id         bigint        not null,
  destination_location_id bigint        not null,
  rate                    numeric(12,4) not null,
  created_at              timestamptz   not null default now(),
  created_by              bigint        not null,
  constraint fk_fe_version     foreign key (freight_set_version_id, plant_id)
    references public.freight_set_versions(id, plant_id) on delete cascade,
  constraint fk_fe_origin      foreign key (origin_plant_id)         references public.plants(id)             on delete restrict,
  constraint fk_fe_destination foreign key (destination_location_id) references public.customer_locations(id) on delete restrict,
  constraint fk_fe_created_by  foreign key (created_by)              references public.app_users(id)          on delete restrict,
  constraint uk_freight_entry unique (freight_set_version_id, origin_plant_id, destination_location_id),
  constraint ck_fe_rate check (rate >= 0)
);
create index ix_fe_version     on public.freight_entries (freight_set_version_id, plant_id);
create index ix_fe_plant       on public.freight_entries (plant_id);
create index ix_fe_origin      on public.freight_entries (origin_plant_id);
create index ix_fe_destination on public.freight_entries (destination_location_id);
create index ix_fe_created_by  on public.freight_entries (created_by);

-- ---------------------------------------------------------------- grants
do $$
declare t text;
begin
  foreach t in array array['rate_sets','rate_set_versions','rate_entries',
                           'freight_sets','freight_set_versions','freight_entries']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant insert, update on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- policies
do $$
declare t text;
begin
  foreach t in array array['rate_sets','rate_set_versions','rate_entries',
                           'freight_sets','freight_set_versions','freight_entries']
  loop
    execute format($p$
      create policy %1$s_select on public.%1$I for select to authenticated
        using ( (select app_private.has_plant_cap(plant_id,'plant_access')) )$p$, t);
    execute format($p$
      create policy %1$s_insert on public.%1$I for insert to authenticated
        with check ( created_by = (select app_private.current_app_user())
                     and (select app_private.has_plant_cap(plant_id,'propose_commercial_master')) )$p$, t);
    execute format($p$
      create policy %1$s_update on public.%1$I for update to authenticated
        using      ( (select app_private.has_plant_cap(plant_id,'propose_commercial_master'))
                  or (select app_private.has_plant_cap(plant_id,'approve_commercial_master')) )
        with check ( (select app_private.has_plant_cap(plant_id,'propose_commercial_master'))
                  or (select app_private.has_plant_cap(plant_id,'approve_commercial_master')) )$p$, t);
  end loop;
end $$;

-- No DELETE policy on any of them (CDM-31).

-- ------------------------------------------------- the transition matrix
-- Same shape as the group masters, with the capability resolved against the
-- row's own plant. plant_id is immutable in every transition, so the USING and
-- WITH CHECK capability tests cannot be made to disagree by moving a row
-- between plants.
create or replace function app_private.guard_plant_master_version_transition()
returns trigger language plpgsql set search_path = '' as $fn$
declare
  v_terminal text := tg_argv[0];
  v_me bigint := app_private.current_app_user();
begin
  if new.plant_id is distinct from old.plant_id then
    raise exception 'plant_id is immutable on %', tg_table_name using errcode = '23514';
  end if;

  if old.status = 'approved' and new.status = old.status then
    raise exception 'an approved % is immutable - a correction is a new version (CDM-31)', tg_table_name
      using errcode = '23514';
  end if;

  if new.status = old.status then
    if old.status <> 'draft' then
      raise exception 'a % in state % cannot be edited', tg_table_name, old.status
        using errcode = '23514';
    end if;
    if not app_private.has_plant_cap(new.plant_id, 'propose_commercial_master') then
      raise exception 'propose_commercial_master is required at that plant' using errcode = '42501';
    end if;
    if new.approved_by is distinct from old.approved_by
       or new.approved_at is distinct from old.approved_at then
      raise exception 'approval fields are set by approval, never by an edit (CDM-34)'
        using errcode = '23514';
    end if;
    return new;
  end if;

  if old.status = 'draft' and new.status = 'approved' then
    if not app_private.has_plant_cap(new.plant_id, 'approve_commercial_master') then
      raise exception 'approve_commercial_master is required at that plant' using errcode = '42501';
    end if;
    new.approved_by := v_me;
    new.approved_at := now();
    return new;
  end if;

  if old.status = 'approved' and new.status = v_terminal then
    if not app_private.has_plant_cap(new.plant_id, 'approve_commercial_master') then
      raise exception 'approve_commercial_master is required at that plant' using errcode = '42501';
    end if;
    return new;
  end if;

  raise exception 'illegal % transition % -> % (CDM-31)', tg_table_name, old.status, new.status
    using errcode = '23514';
end $fn$;

create trigger trg_rsv_transition
  before update on public.rate_set_versions
  for each row execute function app_private.guard_plant_master_version_transition('withdrawn');

create trigger trg_fsv_transition
  before update on public.freight_set_versions
  for each row execute function app_private.guard_plant_master_version_transition('withdrawn');

-- Entries are one editing unit with their draft version (§4.9): writable while
-- the version is draft, frozen the moment it is approved. INSERT and UPDATE
-- only - DELETE stays governed by grant and policy absence, so the §4.9 cascade
-- from a version still works.
create or replace function app_private.guard_entry_follows_version()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_status text; v_parent text := tg_argv[0]; v_col text := tg_argv[1]; v_id bigint;
begin
  execute format('select ($1).%I', v_col) into v_id using new;
  execute format('select status from public.%I where id = $1', v_parent) into v_status using v_id;
  if v_status is distinct from 'draft' then
    raise exception 'a % entry may only be written while its version is draft (found %)',
      tg_table_name, coalesce(v_status,'unknown') using errcode = '23514';
  end if;
  return new;
end $fn$;

create trigger trg_re_follows_version
  before insert or update on public.rate_entries
  for each row execute function app_private.guard_entry_follows_version('rate_set_versions','rate_set_version_id');

create trigger trg_fe_follows_version
  before insert or update on public.freight_entries
  for each row execute function app_private.guard_entry_follows_version('freight_set_versions','freight_set_version_id');

revoke all on function app_private.guard_plant_master_version_transition() from public;
revoke all on function app_private.guard_plant_master_version_transition() from anon;
revoke all on function app_private.guard_plant_master_version_transition() from authenticated;
revoke all on function app_private.guard_entry_follows_version() from public;
revoke all on function app_private.guard_entry_follows_version() from anon;
revoke all on function app_private.guard_entry_follows_version() from authenticated;