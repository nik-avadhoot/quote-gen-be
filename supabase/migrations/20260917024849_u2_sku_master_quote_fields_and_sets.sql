-- U2 SKU Master: quote and costing fields and master SKU Sets.
--
-- PREPARED, NOT APPLIED. Canonical Amendment 02 (Product Owner, 2026-09-16):
--   CDM-43  SKU Master stores the quotation- and costing-relevant SPEC fields on the
--           immutable SKU specification version; every other SPEC column is a listed
--           production-data backlog and has no storage here.
--   CDM-44  Boxes, plates and partitions stay independent SKUs, linked into a
--           plant-owned master SKU Set; each member carries its quantity per set.
--   CDM-10  Printing Technology is Flexo, CMYK, Offset or Unprinted, held with Number
--           of Colours, the descriptive colour detail and the print quality statement.
--
-- Additive only. No existing column, constraint (other than the widened reference
-- kind), policy, trigger or function body changes, and no data is written. Ply,
-- flutes and board layers stay on the Construction version (CDM-13). No pricing,
-- coating or colour-count rule is introduced (Amendment 01, A-06; Amendment 02, B-07).
-- Set membership is created only by a later governed operation; nothing here infers
-- it from Plant Item Code text (CDM-03, CDM-20).

-- ─────────────────────────────────────────────── SKU version quote fields
-- Customer-stated specification values (Item GSM, CS, BS, ECT, Cobb) are kept as the
-- text the customer states. The existing numeric spec_bs / spec_bct / spec_ect stay the
-- calculation check values. item_weight_kg is numeric because costing compares a weight.
alter table public.sku_versions
  add column item_name             text          null,
  add column item_short_name       text          null,
  add column item_family           text          null,
  add column item_group            text          null,
  add column print_quality         text          null,
  add column print_technology      text          null,
  add column number_of_colours     integer       null,
  add column colour_detail         text          null,
  add column cobb_value            text          null,
  add column stated_item_gsm       text          null,
  add column item_weight_kg        numeric(12,4) null,
  add column stated_cs             text          null,
  add column stated_bs             text          null,
  add column stated_ect            text          null,
  add column customer_spec_version text          null,
  add constraint ck_skuv_print_technology
    check (print_technology is null or print_technology in ('Flexo', 'CMYK', 'Offset', 'Unprinted')),
  add constraint ck_skuv_number_of_colours
    check (number_of_colours is null or number_of_colours >= 0),
  add constraint ck_skuv_item_weight
    check (item_weight_kg is null or item_weight_kg >= 0);

-- ─────────────────────────────────────────────── SoftComp reference kind
-- SPEC DZ SoftComp Code is an external reference, like the Customer Item Code.
alter table public.sku_external_references drop constraint ck_sxr_kind;
alter table public.sku_external_references add constraint ck_sxr_kind
  check (reference_kind in ('customer_item_code', 'legacy_plant_item_code', 'alias', 'softcomp_code', 'other'));

-- ─────────────────────────────────────────────────────────────── SKU Sets
create table public.sku_sets (
  id              bigint      generated always as identity primary key,
  plant_id        bigint      not null,
  set_label       text        not null,
  status          text        not null default 'proposed',
  content_version integer     not null default 1,
  created_at      timestamptz not null default now(),
  created_by      bigint      not null,
  constraint fk_sku_set_plant      foreign key (plant_id)   references public.plants(id)    on delete restrict,
  constraint fk_sku_set_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  -- The APSPL Item Code base labels a set; the label is not a relationship key.
  constraint uk_sku_set_label     unique (plant_id, set_label),
  constraint uk_sku_set_id_plant  unique (id, plant_id),
  constraint ck_sku_set_label     check (btrim(set_label) <> ''),
  constraint ck_sku_set_status    check (status in ('proposed', 'confirmed', 'retired'))
);
create index ix_sku_set_created_by on public.sku_sets (created_by);

create table public.sku_set_members (
  id              bigint        generated always as identity primary key,
  set_id          bigint        not null,
  sku_id          bigint        not null,
  plant_id        bigint        not null,
  role            text          not null,
  qty_per_set     numeric(10,3) not null,
  status          text          not null default 'proposed',
  content_version integer       not null default 1,
  created_at      timestamptz   not null default now(),
  created_by      bigint        not null,
  -- Both composite keys bind the same plant_id, so a member can never belong to a
  -- set at another plant.
  constraint fk_ssm_set        foreign key (set_id, plant_id) references public.sku_sets(id, plant_id) on delete restrict,
  constraint fk_ssm_sku        foreign key (sku_id, plant_id) references public.skus(id, plant_id)     on delete restrict,
  constraint fk_ssm_created_by foreign key (created_by)       references public.app_users(id)          on delete restrict,
  constraint uk_ssm_set_sku    unique (set_id, sku_id),
  constraint ck_ssm_role       check (role in ('box', 'plate', 'partition')),
  constraint ck_ssm_qty        check (qty_per_set > 0),
  constraint ck_ssm_status     check (status in ('proposed', 'confirmed', 'withdrawn'))
);
-- At most one active box per set.
create unique index uk_ssm_one_active_box on public.sku_set_members (set_id)
  where role = 'box' and status <> 'withdrawn';
create index ix_ssm_sku        on public.sku_set_members (sku_id, plant_id);
create index ix_ssm_set_plant  on public.sku_set_members (set_id, plant_id);
create index ix_ssm_created_by on public.sku_set_members (created_by);

-- ─────────────────────────────────────────────────────────── authority
-- Read-only for browser callers, scoped like every SKU table: the row's own plant.
-- No client INSERT, UPDATE or DELETE grant or policy exists.
do $$
declare t text;
begin
  foreach t in array array['sku_sets', 'sku_set_members']
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
    execute format($p$
      create policy %1$s_select on public.%1$I for select to authenticated
        using ( (select app_private.has_plant_cap(plant_id, 'plant_access')) )$p$, t);
  end loop;
end $$;
