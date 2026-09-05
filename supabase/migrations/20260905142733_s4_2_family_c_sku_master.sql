-- S4-2: Family C, part two - the SKU master.
--
-- CDM-09: a SKU is a 100% Customer-specific commercial item belonging to exactly
-- one Producing Plant and one Customer. Equivalent supply from another Avadhoot
-- plant is a DIFFERENT SKU. Construction is shareable; SKU is not.
--
-- CDM-13: the published SKU spec version is the SOLE authority for its
-- Construction. That is expressed here as a `not null` foreign key, so a spec
-- version without exactly one Construction authority cannot exist at all.
--
-- Scope columns. §4.3 declares uk_sku_id_plant (id, plant_id) and
-- uk_sku_id_party (id, party_id) on `skus`, both marked [scope], and nothing in
-- Family C consumes them. They exist to be composite-FK targets - the technique
-- §5 mandates - so the three child tables carry a redundant plant_id, and
-- sku_location_applicabilities additionally carries party_id. Three consequences,
-- all structural rather than procedural:
--
--   1. every child RLS predicate is one column read plus one helper call, with no
--      join, which is the performance shape §7.5 argues for on `skus` itself;
--   2. a child row can never be written under a plant its parent does not belong
--      to (PS-18);
--   3. a SKU can only be made applicable at a Customer Location belonging to its
--      OWN Customer, because (location_id, party_id) and (sku_id, party_id) bind
--      the same column (PS-26). Cross-Family reach is closed by construction.

-- ---------------------------------------------------------------------- skus
create table public.skus (
  id                 bigint generated always as identity primary key,
  plant_id           bigint      not null,
  party_id           bigint      not null,
  plant_item_code    text        null,
  status             text        not null default 'proposed',
  replacement_sku_id bigint      null,
  content_version    integer     not null default 1,
  created_at         timestamptz not null default now(),
  created_by         bigint      not null,
  constraint fk_sku_plant       foreign key (plant_id)           references public.plants(id)    on delete restrict,
  constraint fk_sku_party       foreign key (party_id)           references public.parties(id)   on delete restrict,
  constraint fk_sku_replacement foreign key (replacement_sku_id) references public.skus(id)      on delete restrict,
  constraint fk_sku_created_by  foreign key (created_by)         references public.app_users(id) on delete restrict,
  -- CDM-09: Plant Item Code is unique WITHIN its plant, permanent, and optional
  -- until assigned. Multiple nulls are permitted - no pseudo-code is manufactured.
  constraint uk_sku_plant_item unique (plant_id, plant_item_code),
  constraint uk_sku_id_plant   unique (id, plant_id),
  constraint uk_sku_id_party   unique (id, party_id),
  constraint ck_sku_status check (status in ('proposed','active','discontinued')),
  -- CDM-11: a replacement is linked, never silently substituted, and never itself
  constraint ck_sku_not_self_replacement check (replacement_sku_id is distinct from id)
);
create index ix_sku_plant       on public.skus (plant_id);
create index ix_sku_party       on public.skus (party_id);
create index ix_sku_replacement on public.skus (replacement_sku_id);
create index ix_sku_created_by  on public.skus (created_by);

-- ------------------------------------------------------------- sku_versions
-- CDM-10: any dimensional, Construction or strength change is a NEW SKU. A new
-- VERSION carries the non-price-driving changes, and is_price_driving records
-- which kind this is. There is no default: the distinction is a decision, not a
-- fallback.
create table public.sku_versions (
  id                      bigint generated always as identity primary key,
  sku_id                  bigint        not null,
  plant_id                bigint        not null,
  version_no              integer       not null,
  construction_version_id bigint        not null,
  is_price_driving        boolean       not null,
  length_mm               numeric(10,2) null,
  width_mm                numeric(10,2) null,
  height_mm               numeric(10,2) null,
  box_type                text          not null default 'RSC',
  ups                     integer       not null default 1,
  spec_bs                 numeric(10,2) null,
  spec_bct                numeric(10,2) null,
  spec_ect                numeric(10,2) null,
  approved_by             bigint        null,
  approved_at             timestamptz   null,
  created_at              timestamptz   not null default now(),
  created_by              bigint        not null,
  constraint fk_skuv_sku         foreign key (sku_id, plant_id)          references public.skus(id, plant_id)                on delete restrict,
  -- CDM-13 as a not null FK: a spec version always has exactly one Construction
  constraint fk_skuv_construction foreign key (construction_version_id)  references public.construction_versions(id)         on delete restrict,
  constraint fk_skuv_approved_by foreign key (approved_by)               references public.app_users(id)                     on delete restrict,
  constraint fk_skuv_created_by  foreign key (created_by)                references public.app_users(id)                     on delete restrict,
  constraint uk_skuv_version unique (sku_id, version_no),
  -- [scope] §5.8: the target that lets a Batch row bind version-belongs-to-SKU
  constraint uk_skuv_id_sku  unique (id, sku_id),
  constraint ck_skuv_version_no    check (version_no >= 1),
  constraint ck_skuv_ups           check (ups >= 1),
  constraint ck_skuv_box_type      check (btrim(box_type) <> ''),
  constraint ck_skuv_approval_pair check ((approved_by is null) = (approved_at is null))
);
create index ix_skuv_sku                 on public.sku_versions (sku_id, plant_id);
create index ix_skuv_plant               on public.sku_versions (plant_id);
create index ix_skuv_construction_version on public.sku_versions (construction_version_id);
create index ix_skuv_approved_by         on public.sku_versions (approved_by);
create index ix_skuv_created_by          on public.sku_versions (created_by);

-- --------------------------------------------------- sku_external_references
-- CDM-10: Customer Item Code and aliases - optional, searchable, and explicitly
-- NON-authoritative. Deliberately not unique: two customers may use one string,
-- and one customer may use several for the same item.
create table public.sku_external_references (
  id              bigint generated always as identity primary key,
  sku_id          bigint      not null,
  plant_id        bigint      not null,
  reference_kind  text        not null,
  reference_value text        not null,
  status          text        not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      bigint      not null,
  constraint fk_sxr_sku        foreign key (sku_id, plant_id) references public.skus(id, plant_id) on delete restrict,
  constraint fk_sxr_created_by foreign key (created_by)       references public.app_users(id)      on delete restrict,
  constraint ck_sxr_kind   check (reference_kind in ('customer_item_code','legacy_plant_item_code','alias','other')),
  constraint ck_sxr_status check (status in ('active','withdrawn')),
  constraint ck_sxr_value_present check (btrim(reference_value) <> '')
);
create index ix_sxr_sku        on public.sku_external_references (sku_id, plant_id);
create index ix_sxr_plant      on public.sku_external_references (plant_id);
create index ix_sxr_created_by on public.sku_external_references (created_by);

-- ----------------------------------------------- sku_location_applicabilities
-- CDM-11: where a SKU may be quoted. A `batch_only` row authorises the Quote
-- without updating the master; a `master` row is the published permission.
create table public.sku_location_applicabilities (
  id          bigint      generated always as identity primary key,
  sku_id      bigint      not null,
  plant_id    bigint      not null,
  party_id    bigint      not null,
  location_id bigint      not null,
  scope       text        not null,
  status      text        not null default 'proposed',
  approved_by bigint      null,
  approved_at timestamptz null,
  created_at  timestamptz not null default now(),
  created_by  bigint      not null,
  constraint fk_sla_sku_plant   foreign key (sku_id, plant_id)      references public.skus(id, plant_id)              on delete restrict,
  -- these two bind the same party_id column, so the Location must belong to the
  -- SKU's own Customer. Fully DB-enforced (CDM-09/CDM-35).
  constraint fk_sla_sku_party   foreign key (sku_id, party_id)      references public.skus(id, party_id)              on delete restrict,
  constraint fk_sla_location    foreign key (location_id, party_id) references public.customer_locations(id, party_id) on delete restrict,
  constraint fk_sla_approved_by foreign key (approved_by)           references public.app_users(id)                   on delete restrict,
  constraint fk_sla_created_by  foreign key (created_by)            references public.app_users(id)                   on delete restrict,
  constraint uk_sla_sku_location_scope unique (sku_id, location_id, scope),
  constraint ck_sla_scope  check (scope  in ('master','batch_only')),
  constraint ck_sla_status check (status in ('proposed','approved','withdrawn')),
  constraint ck_sla_approval_pair check ((approved_by is null) = (approved_at is null))
);
create index ix_sla_sku         on public.sku_location_applicabilities (sku_id, plant_id);
create index ix_sla_plant       on public.sku_location_applicabilities (plant_id);
create index ix_sla_location    on public.sku_location_applicabilities (location_id, party_id);
create index ix_sla_party       on public.sku_location_applicabilities (party_id);
create index ix_sla_approved_by on public.sku_location_applicabilities (approved_by);
create index ix_sla_created_by  on public.sku_location_applicabilities (created_by);

-- ---------------------------------------------------------------- grants
do $$
declare t text;
begin
  foreach t in array array['skus','sku_versions','sku_external_references',
                           'sku_location_applicabilities']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant insert, update on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- policies
-- CDM-04/CDM-35: SKUs are plant-owned, so every predicate reads the row's OWN
-- plant_id. A wrong-plant Maker gets zero rows, and guessing an id changes
-- nothing - the predicate is on the row, not on obscurity (§7.7).
do $$
declare t text;
begin
  foreach t in array array['skus','sku_versions','sku_external_references',
                           'sku_location_applicabilities']
  loop
    execute format($p$
      create policy %1$s_select on public.%1$I for select to authenticated
        using ( (select app_private.has_plant_cap(plant_id,'plant_access')) )$p$, t);
    execute format($p$
      create policy %1$s_update on public.%1$I for update to authenticated
        using      ( (select app_private.has_plant_cap(plant_id,'manage_sku_master')) )
        with check ( (select app_private.has_plant_cap(plant_id,'manage_sku_master')) )$p$, t);
  end loop;
end $$;

-- CDM-11/DM-132: a Maker may create a stable Proposed SKU in Batch Entry and quote
-- it before Plant Item Code assignment. The branch is plant-scoped as well as
-- narrow: P(plant_id,'make_quote') reads the row's own plant_id, so a Maker cannot
-- propose a SKU onto a plant they hold no grant for (test PS-7).
create policy skus_insert on public.skus for insert to authenticated
  with check (
        (select app_private.has_plant_cap(plant_id,'manage_sku_master'))
     or ( status = 'proposed'
          and plant_item_code is null           -- no fabricated placeholder code
          and created_by = (select app_private.current_app_user())
          and (select app_private.has_plant_cap(plant_id,'make_quote')) ) );

create policy sku_versions_insert on public.sku_versions for insert to authenticated
  with check (
        (select app_private.has_plant_cap(plant_id,'manage_sku_master'))
     or ( approved_at is null
          and created_by = (select app_private.current_app_user())
          and (select app_private.has_plant_cap(plant_id,'make_quote')) ) );

-- Aliases are master data with no proposal route (CDM-10: non-authoritative, but
-- still published reference data).
create policy sku_external_references_insert on public.sku_external_references for insert to authenticated
  with check ( (select app_private.has_plant_cap(plant_id,'manage_sku_master')) );

-- CDM-11: a `batch_only` applicability authorises the Quote without updating the
-- master, so a Maker may create exactly that and nothing else. `master` scope
-- remains an NPD/Admin act.
create policy sku_location_applicabilities_insert on public.sku_location_applicabilities for insert to authenticated
  with check (
        (select app_private.has_plant_cap(plant_id,'manage_sku_master'))
     or ( scope = 'batch_only'
          and status = 'proposed'
          and approved_at is null
          and created_by = (select app_private.current_app_user())
          and (select app_private.has_plant_cap(plant_id,'make_quote')) ) );

-- No DELETE policy on any SKU table (CDM-31).

-- ------------------------------------------------------------ guard triggers
create or replace function app_private.guard_sku_version_immutable()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  -- CDM-10/CDM-22: an approved spec version is frozen; a change is a new version
  if old.approved_at is not null then
    raise exception 'SKU version % is approved and immutable - a change is a new version (CDM-10)', old.id
      using errcode = '23514';
  end if;
  if new.sku_id is distinct from old.sku_id then
    raise exception 'sku_id is immutable on sku_versions' using errcode = '23514';
  end if;
  if new.version_no is distinct from old.version_no then
    raise exception 'version_no is immutable on sku_versions' using errcode = '23514';
  end if;
  if new.plant_id is distinct from old.plant_id then
    raise exception 'plant_id is immutable on sku_versions' using errcode = '23514';
  end if;
  return new;
end $fn$;

create trigger trg_skuv_immutable
  before update on public.sku_versions
  for each row execute function app_private.guard_sku_version_immutable();

-- CDM-09: Plant Item Code is permanent once assigned, and CDM-11 fixes the SKU
-- lifecycle. Both live in a trigger for the §7.5 reason - a policy sees OLD and
-- NEW independently and can never express a transition matrix.
--
-- NOT enforced here, and deliberately: CDM-09's rule that plant_id and party_id
-- become immutable once the SKU has appeared on an ISSUED QUOTE. That predicate
-- needs Family G, which does not exist until S9. What IS already true is that the
-- composite foreign keys pin plant_id the moment any child row exists, because
-- ON UPDATE NO ACTION refuses to leave the child orphaned (PS-19).
create or replace function app_private.guard_sku_permanence()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if old.plant_item_code is not null
     and new.plant_item_code is distinct from old.plant_item_code then
    raise exception 'plant_item_code % is permanent and can never be changed or released (CDM-09)', old.plant_item_code
      using errcode = '23514';
  end if;

  if new.status is distinct from old.status then
    -- exhaustive; anything unlisted raises. Lifecycle per §4.3 / CDM-11.
    if not ( (old.status = 'proposed'     and new.status = 'active')
          or (old.status = 'active'       and new.status = 'discontinued')
          -- CDM-11: reactivation preserves identity, so it returns to the SAME row
          or (old.status = 'discontinued' and new.status = 'active') ) then
      raise exception 'illegal SKU transition % -> % (CDM-11)', old.status, new.status
        using errcode = '23514';
    end if;
  end if;

  return new;
end $fn$;

create trigger trg_sku_permanence
  before update on public.skus
  for each row execute function app_private.guard_sku_permanence();

revoke all on function app_private.guard_sku_version_immutable() from public;
revoke all on function app_private.guard_sku_version_immutable() from anon;
revoke all on function app_private.guard_sku_version_immutable() from authenticated;
revoke all on function app_private.guard_sku_permanence() from public;
revoke all on function app_private.guard_sku_permanence() from anon;
revoke all on function app_private.guard_sku_permanence() from authenticated;