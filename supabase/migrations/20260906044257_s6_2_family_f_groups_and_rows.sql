-- S6-2: Family F, part two - Pricing Groups, Delivery Groups and Batch rows.
--
-- This is where §5's composite-FK technique does most of its work. Five of the
-- ten invariants become structural here, and two deliberately do not.
--
--   5.1 SKU plant == Batch plant   fk_row_batch_plant and fk_row_sku_plant both
--                                  bind batch_rows.plant_id, so the two plants
--                                  must be equal - not compared, equal.
--   5.3 Row and Group same Batch   fk_row_pg (pricing_group_id, batch_id)
--   5.4 Basis in the same Group    fk_dg_pg + fk_pg_freight_basis, the second
--                                  binding (basis_id, id) so the basis must
--                                  belong to THIS group
--   5.8 Version belongs to the SKU fk_row_sku_version (sku_version_id, sku_id)
--   5.10 lineage is a legal target uk_row_lineage, which S9's quote_items needs
--
-- TWO CANNOT BE FOREIGN KEYS, and §5 argues each rather than asserting it.
--
-- §5.2 - the SKU's Customer must belong to the Batch's Family AT ROW ADDITION.
-- A composite FK would enforce it CONTINUOUSLY, so the moment a Party was
-- reassigned to another Family - which CDM-07 permits, effective-dated - every
-- existing row referencing that Party's SKU would violate it, and the
-- reassignment would either fail or cascade. Both destroy work CDM-06 protects.
-- So: a BEFORE INSERT trigger, and sku_id is blocked from changing afterwards,
-- because a row changes SKU by replacement rather than mutation (CDM-11).
-- Reassignment later leaves existing rows untouched, exactly as required.
--
-- §5.7 - a row's proposed Construction must be a PROPOSED one. The FK-only route
-- would cascade a denormalised status and make PUBLICATION fail on every open
-- row still pointing at the Construction - forbidding an operation CDM-12
-- explicitly permits. So: a trigger asserting the status AT THE TIME OF WRITE.
-- Publication afterwards is unaffected, and the row keeps its pinned version,
-- which is what CDM-10's pinning rule wants anyway.

create sequence app_private.batch_row_lineage_seq as bigint;
revoke all on sequence app_private.batch_row_lineage_seq from public, anon, authenticated;

-- ------------------------------------------------------ pricing_groups
create table public.pricing_groups (
  id                               bigint        generated always as identity primary key,
  batch_id                         bigint        not null,
  label                            text          null,
  freight_mode                     text          not null default 'master',
  freight_basis_delivery_group_id  bigint        null,
  freight_manual_value             numeric(12,4) null,
  payment_terms_days               integer       null,
  payment_terms_text               text          null,
  interest_override_pct            numeric(7,3)  null,
  status                           text          not null default 'active',
  content_version                  integer       not null default 1,
  created_at                       timestamptz   not null default now(),
  created_by                       bigint        not null,
  constraint fk_pg_batch      foreign key (batch_id)   references public.batches(id)   on delete restrict,
  constraint fk_pg_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_pg_id_batch unique (id, batch_id),
  constraint ck_pg_freight_mode check (freight_mode in ('master','manual','ex_factory')),
  constraint ck_pg_manual_value check (freight_mode <> 'manual' or freight_manual_value is not null),
  constraint ck_pg_exfactory_no_basis
    check (freight_mode <> 'ex_factory' or freight_basis_delivery_group_id is null),
  constraint ck_pg_interest_non_negative
    check (interest_override_pct is null or interest_override_pct >= 0),
  -- the CDM-18 ruling again, on the consuming side: a non-list credit period is
  -- unstorable as a CALCULATING value and belongs in payment_terms_text, which
  -- never calculates
  constraint ck_pg_payment_terms_closed
    check (payment_terms_days is null or payment_terms_days in (30,45,60,90)),
  constraint ck_pg_status check (status in ('active','removed')),
  constraint ck_pg_content_version check (content_version >= 1)
);
create index ix_pg_batch      on public.pricing_groups (batch_id);
create index ix_pg_created_by on public.pricing_groups (created_by);

-- ----------------------------------------------------- delivery_groups
create table public.delivery_groups (
  id                  bigint      generated always as identity primary key,
  pricing_group_id    bigint      not null,
  batch_id            bigint      not null,
  label               text        null,
  bill_to_location_id bigint      null,
  ship_to_location_id bigint      null,
  route_notes         text        null,
  status              text        not null default 'active',
  created_at          timestamptz not null default now(),
  created_by          bigint      not null,
  constraint fk_dg_pg      foreign key (pricing_group_id, batch_id)
    references public.pricing_groups(id, batch_id) on delete restrict,
  constraint fk_dg_bill_to foreign key (bill_to_location_id) references public.customer_locations(id) on delete restrict,
  constraint fk_dg_ship_to foreign key (ship_to_location_id) references public.customer_locations(id) on delete restrict,
  constraint fk_dg_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_dg_id_pg unique (id, pricing_group_id),
  constraint ck_dg_status check (status in ('active','removed'))
);
create index ix_dg_pg         on public.delivery_groups (pricing_group_id, batch_id);
create index ix_dg_bill_to    on public.delivery_groups (bill_to_location_id);
create index ix_dg_ship_to    on public.delivery_groups (ship_to_location_id);
create index ix_dg_created_by on public.delivery_groups (created_by);

-- The circular half, added once its target exists. on delete restrict is A-11:
-- the Delivery Group serving as the freight basis cannot be removed out from
-- under the calculation.
alter table public.pricing_groups
  add constraint fk_pg_freight_basis
  foreign key (freight_basis_delivery_group_id, id)
  references public.delivery_groups(id, pricing_group_id) on delete restrict;
create index ix_pg_freight_basis on public.pricing_groups (freight_basis_delivery_group_id, id);

-- ---------------------------------------------------------- batch_rows
create table public.batch_rows (
  id                               bigint        generated always as identity primary key,
  lineage_id                       bigint        not null default nextval('app_private.batch_row_lineage_seq'),
  batch_id                         bigint        not null,
  plant_id                         bigint        not null,
  pricing_group_id                 bigint        not null,
  sku_id                           bigint        not null,
  sku_version_id                   bigint        not null,
  proposed_construction_version_id bigint        null,
  material_code                    text          null,
  row_type                         text          not null default 'box',
  waste_override_pct               numeric(7,3)  null,
  margin_override_pct              numeric(7,3)  null,
  conv_override_rate               numeric(12,4) null,
  freight_override                 numeric(12,4) null,
  sales_moq                        bigint        null,
  volume                           bigint        null,
  status                           text          not null default 'active',
  content_version                  integer       not null default 1,
  created_at                       timestamptz   not null default now(),
  created_by                       bigint        not null,
  constraint fk_row_batch       foreign key (batch_id) references public.batches(id) on delete restrict,
  constraint fk_row_pg          foreign key (pricing_group_id, batch_id)
    references public.pricing_groups(id, batch_id) on delete restrict,
  constraint fk_row_batch_plant foreign key (batch_id, plant_id)
    references public.batches(id, plant_id) on delete restrict,
  constraint fk_row_sku_plant   foreign key (sku_id, plant_id)
    references public.skus(id, plant_id) on delete restrict,
  constraint fk_row_sku_version foreign key (sku_version_id, sku_id)
    references public.sku_versions(id, sku_id) on delete restrict,
  constraint fk_row_proposed_cv foreign key (proposed_construction_version_id)
    references public.construction_versions(id) on delete restrict,
  constraint fk_row_created_by  foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_row_lineage  unique (lineage_id),
  constraint uk_row_id_batch unique (id, batch_id),
  constraint uk_row_id_type  unique (id, row_type),
  constraint ck_row_type   check (row_type in ('box','plate','part_l','part_w','other')),
  constraint ck_row_status check (status in ('active','removed')),
  constraint ck_row_overrides_non_negative check (
        (waste_override_pct  is null or waste_override_pct  >= 0)
    and (margin_override_pct is null or margin_override_pct >= 0)
    and (conv_override_rate  is null or conv_override_rate  >= 0)
    and (freight_override    is null or freight_override    >= 0)),
  constraint ck_row_moq    check (sales_moq is null or sales_moq >= 0),
  constraint ck_row_volume check (volume    is null or volume    >= 0),
  constraint ck_row_content_version check (content_version >= 1)
);
create index ix_row_batch      on public.batch_rows (batch_id);
create index ix_row_pg         on public.batch_rows (pricing_group_id, batch_id);
create index ix_row_sku        on public.batch_rows (sku_id, plant_id);
create index ix_row_lineage    on public.batch_rows (lineage_id);
create index ix_row_batch_plant on public.batch_rows (batch_id, plant_id);
create index ix_row_sku_version on public.batch_rows (sku_version_id, sku_id);
create index ix_row_proposed_cv on public.batch_rows (proposed_construction_version_id);
create index ix_row_created_by  on public.batch_rows (created_by);

-- ---------------------------------- §5.2 Family membership, at ROW ADDITION
create or replace function app_private.guard_row_sku_family()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_party bigint; v_family bigint; v_batch_family bigint;
begin
  select party_id into v_party from public.skus where id = new.sku_id;
  select family_id into v_batch_family from public.batches where id = new.batch_id;
  select m.family_id into v_family
    from public.party_family_memberships m
   where m.party_id = v_party and m.is_current;

  if v_family is null then
    raise exception 'the SKU Customer has no current Family membership (CDM-07)'
      using errcode = '23514';
  end if;
  if v_family is distinct from v_batch_family then
    raise exception 'the SKU Customer belongs to another Customer Family (CDM-06/DM-187)'
      using errcode = '23514';
  end if;
  return new;
end $fn$;

create trigger trg_row_sku_family
  before insert on public.batch_rows
  for each row execute function app_private.guard_row_sku_family();

-- A row changes SKU by replacement, not mutation (CDM-11). Blocking the column
-- is what lets §5.2 be an insert-time rule without leaving a mutation hole.
create or replace function app_private.guard_row_sku_immutable()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.sku_id is distinct from old.sku_id then
    raise exception 'a Batch row changes SKU by replacement, never by mutation (CDM-11)'
      using errcode = '23514';
  end if;
  if new.batch_id is distinct from old.batch_id or new.plant_id is distinct from old.plant_id then
    raise exception 'a Batch row cannot be moved between Batches or plants' using errcode = '23514';
  end if;
  if new.lineage_id is distinct from old.lineage_id then
    raise exception 'lineage is stable across revisions and never changes (CDM-22)'
      using errcode = '23514';
  end if;
  return new;
end $fn$;

create trigger trg_row_sku_immutable
  before update on public.batch_rows
  for each row execute function app_private.guard_row_sku_immutable();

-- --------------------------- §5.7 proposed Construction mutual exclusivity
-- Asserted AT THE TIME OF WRITE, so publishing the Construction later cannot
-- retroactively invalidate open rows - which is precisely what an ON UPDATE
-- CASCADE of a denormalised status would have done.
create or replace function app_private.guard_row_proposed_construction()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_status text;
begin
  if new.proposed_construction_version_id is null then
    return new;
  end if;
  select k.status into v_status
    from public.construction_versions cv
    join public.constructions k on k.id = cv.construction_id
   where cv.id = new.proposed_construction_version_id;

  if v_status is distinct from 'proposed' then
    raise exception 'a row Construction reference exists only for a Quote-specific PROPOSED Construction; the published SKU spec version is otherwise sole authority (CDM-13)'
      using errcode = '23514';
  end if;
  return new;
end $fn$;

create trigger trg_row_proposed_construction
  before insert or update on public.batch_rows
  for each row execute function app_private.guard_row_proposed_construction();

-- ---------------------------------------------------------------- grants
do $$
declare t text;
begin
  foreach t in array array['pricing_groups','delivery_groups','batch_rows']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant insert, update on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- policies
-- Every one delegates to the Batch predicates, so the access model has one home.
do $$
declare t text;
begin
  foreach t in array array['pricing_groups','delivery_groups','batch_rows']
  loop
    execute format($p$
      create policy %1$s_select on public.%1$I for select to authenticated
        using ( (select app_private.can_read_batch(batch_id)) )$p$, t);
    execute format($p$
      create policy %1$s_insert on public.%1$I for insert to authenticated
        with check ( created_by = (select app_private.current_app_user())
                     and (select app_private.can_write_batch(batch_id)) )$p$, t);
    execute format($p$
      create policy %1$s_update on public.%1$I for update to authenticated
        using      ( (select app_private.can_write_batch(batch_id)) )
        with check ( (select app_private.can_write_batch(batch_id)) )$p$, t);
  end loop;
end $$;

revoke all on function app_private.guard_row_sku_family() from public, anon, authenticated;
revoke all on function app_private.guard_row_sku_immutable() from public, anon, authenticated;
revoke all on function app_private.guard_row_proposed_construction() from public, anon, authenticated;