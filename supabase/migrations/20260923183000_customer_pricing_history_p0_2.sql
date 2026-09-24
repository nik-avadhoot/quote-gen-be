-- Customer Pricing History, P0.2: commercial mechanisms.
--
-- Successor to 20260923150000_customer_pricing_history_p0_1.sql (must follow it).
-- Authority: quote-gen-fe/docs/customer-pricing-history-phase-0-implementation-plan-2026-09-23.md
-- §4.4-4.8 and §10 P0.2.
--
-- WHAT THIS SLICE ADDS
--   customer_pricing_term_versions   effective-dated Stable Terms per Customer / Location / Plant scope
--   customer_pricing_bf_delta_sets   effective-dated base BF + signed deltas (entries immutable)
--   customer_pricing_bf_deltas
--   customer_pricing_line_measures   Paper Consumed / Sheet / Box weight and m2 area, ONE ROW PER SOURCE
--   customer_pricing_event_bf_rates  the BF schedule snapshotted onto each negotiation round (+ overrides)
--   lines   -> term / BF-set references, prior_line_id (Start next cycle)
--   events  -> component breakup + frozen snapshot of the applicable term and BF set
--
-- UNITS follow the settled Costing engine (quote-gen-fe/src/engine/costing.js), which this migration
-- does NOT change: Conversion is INR per kg of Paper Consumed (Paper Consumed includes wastage);
-- Freight is INR per kg of Sheet Weight (Sheet Weight excludes wastage); weights are kg per box and
-- area is m2 per box, both carried to 4 decimals as Costing does. BF is identified by the paper grade
-- code Costing uses ('16', '18', '20GY', ...), never by an inferred number.
--
-- HISTORY IS SNAPSHOTTED, NEVER RE-JOINED. A negotiation round copies the applicable term values and
-- the whole BF delta schedule when it is recorded; a BEFORE UPDATE trigger freezes those copies. A
-- later term or BF version therefore cannot reinterpret an earlier offer, counter or agreement.
-- Derived BF rates are base-BF round rate + snapshotted signed delta, exact to 2 decimals, computed on
-- read; an explicit override is stored beside the snapshot, never instead of it.
--
-- Every P0.1 boundary is preserved: SELECT-only for authenticated, RLS forced with a read_party_master
-- policy, writes only through app_private.cph_* definers (empty search_path) behind public invoker
-- wrappers, CAS on every mutable row, trigger-written before/after audit, no hard delete.

-- ─────────────────────────────────────────────── audit vocabulary + helpers
alter table public.customer_pricing_change_events drop constraint ck_cpx_entity;
alter table public.customer_pricing_change_events add constraint ck_cpx_entity check (entity_type in
  ('mechanism','cycle','line','negotiation_event',
   'term_version','bf_delta_set','bf_delta','line_measure','event_bf_rate'));

-- Same function, wider party resolution for the new child tables.
create or replace function app_private.cph_audit()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_actor bigint; v_party bigint; v_entity text;
begin
  v_actor := app_private.current_app_user();
  if v_actor is null then
    raise exception 'pricing history is edited only by an identified app user'
      using errcode = '42501';
  end if;
  v_entity := tg_argv[0];
  if v_entity in ('negotiation_event', 'line_measure') then
    select l.party_id into v_party from public.customer_pricing_lines l where l.id = new.line_id;
  elsif v_entity = 'event_bf_rate' then
    select l.party_id into v_party
      from public.customer_pricing_negotiation_events e
      join public.customer_pricing_lines l on l.id = e.line_id where e.id = new.event_id;
  elsif v_entity = 'bf_delta' then
    select s.party_id into v_party from public.customer_pricing_bf_delta_sets s where s.id = new.set_id;
  else
    v_party := new.party_id;
  end if;
  insert into public.customer_pricing_change_events (
    party_id, entity_type, entity_id, operation, content_version,
    before_state, after_state, actor_app_user_id)
  values (
    v_party, v_entity, new.id,
    case tg_op when 'INSERT' then 'create' else 'update' end,
    case when to_jsonb(new) ? 'content_version' then (to_jsonb(new) ->> 'content_version')::integer end,
    case tg_op when 'INSERT' then null else to_jsonb(old) end,
    to_jsonb(new), v_actor);
  return null;
end $fn$;

-- Freeze any number of identity/scope columns (P0.1's cph_freeze_parent takes two).
create or replace function app_private.cph_freeze_columns()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare i integer;
begin
  for i in 0 .. tg_nargs - 1 loop
    if (to_jsonb(new) -> tg_argv[i]) is distinct from (to_jsonb(old) -> tg_argv[i]) then
      raise exception 'column % of a pricing-history row cannot change', tg_argv[i]
        using errcode = '22023';
    end if;
  end loop;
  return new;
end $fn$;

create or replace function app_private.cph_immutable_row()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  raise exception 'this pricing-history row is immutable - record a new version instead'
    using errcode = '42501';
end $fn$;

-- ───────────────────────────────────────────────────────── Stable Terms
create table public.customer_pricing_term_versions (
  id                    bigint generated always as identity primary key,
  party_id              bigint      not null,
  customer_location_id  bigint      null,
  plant_id              bigint      null,
  version_no            integer     not null,
  status                text        not null default 'active',
  effective_from        date        not null,
  effective_to          date        null,
  rate_basis            text        null,
  weight_basis          text        null,
  wastage_treatment     text        not null default 'not_captured',
  wastage_pct           numeric(5,2) null,
  freight_treatment     text        not null default 'not_captured',
  -- INR per kg of Paper Consumed (Costing: conversion applies on Paper Consumed).
  conversion_inr_per_kg numeric(12,2) null,
  -- INR per kg of Sheet Weight (Costing: freight applies on Sheet Weight).
  freight_inr_per_kg    numeric(12,2) null,
  source_type           text        null,
  source_date           date        null,
  source_ref            text        null,
  notes                 text        null,
  content_version       integer     not null default 1,
  created_at            timestamptz not null default now(),
  created_by            bigint      not null,
  updated_at            timestamptz not null default now(),
  updated_by            bigint      not null,
  constraint fk_cpt_party      foreign key (party_id) references public.parties(id) on delete restrict,
  constraint fk_cpt_location   foreign key (customer_location_id, party_id)
    references public.customer_locations(id, party_id) on delete restrict,
  constraint fk_cpt_plant      foreign key (plant_id) references public.plants(id) on delete restrict,
  constraint fk_cpt_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_cpt_updated_by foreign key (updated_by) references public.app_users(id) on delete restrict,
  constraint uk_cpt_id_party unique (id, party_id),
  constraint ck_cpt_status check (status in ('active','withdrawn')),
  constraint ck_cpt_version check (version_no >= 1 and content_version >= 1),
  constraint ck_cpt_period check (effective_to is null or effective_to >= effective_from),
  constraint ck_cpt_rate_basis check (rate_basis is null or rate_basis in
    ('box_per_piece','box_per_kg','kraft_paper_per_kg','box_per_sqm')),
  constraint ck_cpt_weight_basis check (weight_basis is null or weight_basis in
    ('paper_consumed','sheet_weight','box_weight')),
  -- Wastage: a % exists only when it is added over the weight. Zero is a
  -- deliberate % there; "not captured" and "not applicable" carry none.
  constraint ck_cpt_wastage check (
    (wastage_treatment = 'added_pct' and wastage_pct is not null and wastage_pct >= 0 and wastage_pct <= 100)
    or (wastage_treatment in ('included_in_weight','not_applicable','not_captured') and wastage_pct is null)),
  constraint ck_cpt_freight_treatment check (freight_treatment in
    ('delivered_included','ex_factory_separate','not_captured')),
  constraint ck_cpt_amounts check ((conversion_inr_per_kg is null or conversion_inr_per_kg >= 0)
    and (freight_inr_per_kg is null or freight_inr_per_kg >= 0)),
  constraint ck_cpt_source_type check (source_type is null or source_type in
    ('email','whatsapp','call','meeting','excel','other')),
  constraint ck_cpt_source_ref check (source_ref is null or char_length(source_ref) <= 500),
  constraint ck_cpt_notes check (notes is null or char_length(notes) <= 2000)
);
create unique index uk_cpt_scope_version on public.customer_pricing_term_versions
  (party_id, (coalesce(customer_location_id, 0)), (coalesce(plant_id, 0)), version_no);
create index ix_cpt_party_effective on public.customer_pricing_term_versions (party_id, effective_from desc);
create index ix_cpt_location   on public.customer_pricing_term_versions (customer_location_id, party_id);
create index ix_cpt_plant      on public.customer_pricing_term_versions (plant_id);
create index ix_cpt_created_by on public.customer_pricing_term_versions (created_by);
create index ix_cpt_updated_by on public.customer_pricing_term_versions (updated_by);

-- ──────────────────────────────────────────────────────── BF delta sets
create table public.customer_pricing_bf_delta_sets (
  id                   bigint generated always as identity primary key,
  party_id             bigint      not null,
  customer_location_id bigint      null,
  plant_id             bigint      null,
  version_no           integer     not null,
  status               text        not null default 'active',
  effective_from       date        not null,
  effective_to         date        null,
  base_bf_code         text        not null,
  source_type          text        null,
  source_date          date        null,
  source_ref           text        null,
  notes                text        null,
  content_version      integer     not null default 1,
  created_at           timestamptz not null default now(),
  created_by           bigint      not null,
  updated_at           timestamptz not null default now(),
  updated_by           bigint      not null,
  constraint fk_cpb_party      foreign key (party_id) references public.parties(id) on delete restrict,
  constraint fk_cpb_location   foreign key (customer_location_id, party_id)
    references public.customer_locations(id, party_id) on delete restrict,
  constraint fk_cpb_plant      foreign key (plant_id) references public.plants(id) on delete restrict,
  constraint fk_cpb_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_cpb_updated_by foreign key (updated_by) references public.app_users(id) on delete restrict,
  constraint uk_cpb_id_party unique (id, party_id),
  constraint ck_cpb_status check (status in ('active','withdrawn')),
  constraint ck_cpb_version check (version_no >= 1 and content_version >= 1),
  constraint ck_cpb_period check (effective_to is null or effective_to >= effective_from),
  constraint ck_cpb_base_bf check (base_bf_code ~ '^[0-9]{1,3}[A-Z]{0,4}$'),
  constraint ck_cpb_source_type check (source_type is null or source_type in
    ('email','whatsapp','call','meeting','excel','other')),
  constraint ck_cpb_source_ref check (source_ref is null or char_length(source_ref) <= 500),
  constraint ck_cpb_notes check (notes is null or char_length(notes) <= 2000)
);
create unique index uk_cpb_scope_version on public.customer_pricing_bf_delta_sets
  (party_id, (coalesce(customer_location_id, 0)), (coalesce(plant_id, 0)), version_no);
create index ix_cpb_party_effective on public.customer_pricing_bf_delta_sets (party_id, effective_from desc);
create index ix_cpb_location   on public.customer_pricing_bf_delta_sets (customer_location_id, party_id);
create index ix_cpb_plant      on public.customer_pricing_bf_delta_sets (plant_id);
create index ix_cpb_created_by on public.customer_pricing_bf_delta_sets (created_by);
create index ix_cpb_updated_by on public.customer_pricing_bf_delta_sets (updated_by);

-- Entries are immutable: a changed delta is a new set version, so no old
-- round's schedule can be rewritten through them.
create table public.customer_pricing_bf_deltas (
  id         bigint generated always as identity primary key,
  set_id     bigint        not null,
  bf_code    text          not null,
  delta_inr  numeric(12,2) not null,
  created_at timestamptz   not null default now(),
  created_by bigint        not null,
  constraint fk_cpd_set        foreign key (set_id)     references public.customer_pricing_bf_delta_sets(id) on delete restrict,
  constraint fk_cpd_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint uk_cpd_set_bf unique (set_id, bf_code),
  constraint ck_cpd_bf check (bf_code ~ '^[0-9]{1,3}[A-Z]{0,4}$')
);
create index ix_cpd_created_by on public.customer_pricing_bf_deltas (created_by);

-- ───────────────────────────────────────── line references + measures
alter table public.customer_pricing_lines
  add column term_version_id bigint null,
  add column bf_delta_set_id bigint null,
  add column prior_line_id   bigint null,
  add constraint uk_cpl_id_party unique (id, party_id),
  add constraint fk_cpl_term  foreign key (term_version_id, party_id)
    references public.customer_pricing_term_versions(id, party_id) on delete restrict,
  add constraint fk_cpl_bf_set foreign key (bf_delta_set_id, party_id)
    references public.customer_pricing_bf_delta_sets(id, party_id) on delete restrict,
  add constraint fk_cpl_prior foreign key (prior_line_id, party_id)
    references public.customer_pricing_lines(id, party_id) on delete restrict;
create index ix_cpl_term   on public.customer_pricing_lines (term_version_id, party_id);
create index ix_cpl_bf_set on public.customer_pricing_lines (bf_delta_set_id, party_id);
create index ix_cpl_prior  on public.customer_pricing_lines (prior_line_id, party_id);

-- One row per (line, measure, SOURCE): a Customer-confirmed or manual value
-- sits BESIDE a Costing-snapshot value, it never overwrites it.
create table public.customer_pricing_line_measures (
  id              bigint generated always as identity primary key,
  line_id         bigint        not null,
  measure         text          not null,
  source          text          not null,
  value           numeric(12,4) not null,
  status          text          not null default 'active',
  notes           text          null,
  content_version integer       not null default 1,
  created_at      timestamptz   not null default now(),
  created_by      bigint        not null,
  updated_at      timestamptz   not null default now(),
  updated_by      bigint        not null,
  constraint fk_cpw_line       foreign key (line_id)    references public.customer_pricing_lines(id) on delete restrict,
  constraint fk_cpw_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_cpw_updated_by foreign key (updated_by) references public.app_users(id) on delete restrict,
  constraint uk_cpw_line_measure_source unique (line_id, measure, source),
  constraint ck_cpw_measure check (measure in ('paper_consumed_kg','sheet_weight_kg','box_weight_kg','area_sqm')),
  constraint ck_cpw_source check (source in ('costing_snapshot','customer_confirmed','imported','manual')),
  constraint ck_cpw_value check (value > 0),
  constraint ck_cpw_status check (status in ('active','withdrawn')),
  constraint ck_cpw_notes check (notes is null or char_length(notes) <= 500),
  constraint ck_cpw_version check (content_version >= 1)
);
create index ix_cpw_created_by on public.customer_pricing_line_measures (created_by);
create index ix_cpw_updated_by on public.customer_pricing_line_measures (updated_by);

-- ─────────────────────────────────────────── round components + snapshot
alter table public.customer_pricing_negotiation_events
  -- Component breakup, in the unit of the round's own rate. The recorded
  -- total stays rate_inr; the component sum and difference are shown, and
  -- neither ever replaces the recorded total.
  add column component_kraft_inr      numeric(12,2) null,
  add column component_conversion_inr numeric(12,2) null,
  add column component_freight_inr    numeric(12,2) null,
  -- Snapshot of the Stable Term that applied when the round was recorded.
  add column term_version_id            bigint        null,
  add column snap_wastage_treatment     text          null,
  add column snap_wastage_pct           numeric(5,2)  null,
  add column snap_freight_treatment     text          null,
  add column snap_conversion_inr_per_kg numeric(12,2) null,
  add column snap_freight_inr_per_kg    numeric(12,2) null,
  -- Snapshot of the BF set; its schedule is copied to event_bf_rates.
  add column bf_delta_set_id bigint null,
  add column base_bf_code    text   null,
  add constraint fk_cpe_term   foreign key (term_version_id) references public.customer_pricing_term_versions(id) on delete restrict,
  add constraint fk_cpe_bf_set foreign key (bf_delta_set_id) references public.customer_pricing_bf_delta_sets(id) on delete restrict,
  add constraint ck_cpe_components check (
    (component_kraft_inr is null or component_kraft_inr >= 0)
    and (component_conversion_inr is null or component_conversion_inr >= 0)
    and (component_freight_inr is null or component_freight_inr >= 0));
create index ix_cpe_term   on public.customer_pricing_negotiation_events (term_version_id);
create index ix_cpe_bf_set on public.customer_pricing_negotiation_events (bf_delta_set_id);

create table public.customer_pricing_event_bf_rates (
  id                bigint generated always as identity primary key,
  event_id          bigint        not null,
  bf_code           text          not null,
  -- Snapshotted from the BF set when the round was recorded; frozen.
  delta_inr         numeric(12,2) not null,
  -- An explicit BF-specific exception. NULL = the derived rate applies.
  override_rate_inr numeric(12,2) null,
  content_version   integer       not null default 1,
  created_at        timestamptz   not null default now(),
  created_by        bigint        not null,
  updated_at        timestamptz   not null default now(),
  updated_by        bigint        not null,
  constraint fk_cpr_event      foreign key (event_id)   references public.customer_pricing_negotiation_events(id) on delete restrict,
  constraint fk_cpr_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_cpr_updated_by foreign key (updated_by) references public.app_users(id) on delete restrict,
  constraint uk_cpr_event_bf unique (event_id, bf_code),
  constraint ck_cpr_override check (override_rate_inr is null or override_rate_inr >= 0),
  constraint ck_cpr_version check (content_version >= 1)
);
create index ix_cpr_created_by on public.customer_pricing_event_bf_rates (created_by);
create index ix_cpr_updated_by on public.customer_pricing_event_bf_rates (updated_by);

-- ─────────────────────────────────────────────────── privileges and RLS
do $$
declare t text;
begin
  foreach t in array array['customer_pricing_term_versions','customer_pricing_bf_delta_sets',
                           'customer_pricing_bf_deltas','customer_pricing_line_measures',
                           'customer_pricing_event_bf_rates']
  loop
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
    execute format($p$
      create policy %1$s_select on public.%1$I for select to authenticated
        using ( (select app_private.has_group_cap('read_party_master')) )$p$, t);
  end loop;
end $$;

-- ────────────────────────────────────────────── snapshot triggers on rounds
-- BEFORE INSERT: copy the line's applicable term and BF set onto the round.
create or replace function app_private.cph_event_snapshot()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_term public.customer_pricing_term_versions%rowtype; v_bf_set bigint; v_base text;
begin
  select t.* into v_term
    from public.customer_pricing_lines l
    join public.customer_pricing_term_versions t on t.id = l.term_version_id
   where l.id = new.line_id;
  if found then
    new.term_version_id            := v_term.id;
    new.rate_basis                 := coalesce(v_term.rate_basis, new.rate_basis);
    new.weight_basis               := coalesce(v_term.weight_basis, new.weight_basis);
    new.snap_wastage_treatment     := v_term.wastage_treatment;
    new.snap_wastage_pct           := v_term.wastage_pct;
    new.snap_freight_treatment     := v_term.freight_treatment;
    new.snap_conversion_inr_per_kg := v_term.conversion_inr_per_kg;
    new.snap_freight_inr_per_kg    := v_term.freight_inr_per_kg;
  end if;
  select s.id, s.base_bf_code into v_bf_set, v_base
    from public.customer_pricing_lines l
    join public.customer_pricing_bf_delta_sets s on s.id = l.bf_delta_set_id
   where l.id = new.line_id;
  if v_bf_set is not null then
    new.bf_delta_set_id := v_bf_set;
    new.base_bf_code    := v_base;
  end if;
  return new;
end $fn$;

-- AFTER INSERT: copy the complete delta schedule onto the round. A signed
-- delta is valid, but no derived BF rate (base rate + delta) may fall below
-- 0.00: the whole insert - round, snapshot and audit - is refused, on every
-- path that records a round (cph_add_round and P0.1's cph_add_event alike).
create or replace function app_private.cph_event_bf_snapshot()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint;
begin
  if new.bf_delta_set_id is null then
    return null;
  end if;
  if new.rate_inr is not null and exists (
       select 1 from public.customer_pricing_bf_deltas d
        where d.set_id = new.bf_delta_set_id and new.rate_inr + d.delta_inr < 0) then
    raise exception 'a BF in this round''s schedule would have a negative derived rate'
      using errcode = '23514';
  end if;
  v_me := app_private.current_app_user();
  insert into public.customer_pricing_event_bf_rates (event_id, bf_code, delta_inr, created_by, updated_by)
  select new.id, d.bf_code, d.delta_inr, v_me, v_me
    from public.customer_pricing_bf_deltas d where d.set_id = new.bf_delta_set_id;
  return null;
end $fn$;

create trigger trg_cpe_snapshot before insert on public.customer_pricing_negotiation_events
  for each row execute function app_private.cph_event_snapshot();
create trigger trg_cpe_snapshot_freeze before update on public.customer_pricing_negotiation_events
  for each row execute function app_private.cph_freeze_columns(
    'term_version_id', 'snap_wastage_treatment', 'snap_wastage_pct', 'snap_freight_treatment',
    'snap_conversion_inr_per_kg', 'snap_freight_inr_per_kg', 'bf_delta_set_id', 'base_bf_code',
    'rate_basis', 'weight_basis');
create trigger trg_cpe_z_bf_snapshot after insert on public.customer_pricing_negotiation_events
  for each row execute function app_private.cph_event_bf_snapshot();

-- BEFORE UPDATE: correcting a round's base rate may not push any of its OWN
-- snapshotted BF rates below 0.00. An override does not excuse it: the derived
-- rate is kept beside the override and must itself stay valid.
create or replace function app_private.cph_event_bf_floor()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if new.rate_inr is not null and new.rate_inr is distinct from old.rate_inr and exists (
       select 1 from public.customer_pricing_event_bf_rates r
        where r.event_id = new.id and new.rate_inr + r.delta_inr < 0) then
    raise exception 'that base rate would give a BF in this round''s schedule a negative derived rate'
      using errcode = '23514';
  end if;
  return new;
end $fn$;
create trigger trg_cpe_bf_floor before update on public.customer_pricing_negotiation_events
  for each row execute function app_private.cph_event_bf_floor();

-- ────────────────────────────── version, freeze and audit triggers (new tables)
create trigger trg_cpt_version before update on public.customer_pricing_term_versions
  for each row execute function app_private.cph_before_update();
create trigger trg_cpt_freeze before update on public.customer_pricing_term_versions
  for each row execute function app_private.cph_freeze_columns('party_id', 'customer_location_id', 'plant_id', 'version_no');
create trigger trg_cpt_audit after insert or update on public.customer_pricing_term_versions
  for each row execute function app_private.cph_audit('term_version');

create trigger trg_cpb_version before update on public.customer_pricing_bf_delta_sets
  for each row execute function app_private.cph_before_update();
create trigger trg_cpb_freeze before update on public.customer_pricing_bf_delta_sets
  for each row execute function app_private.cph_freeze_columns('party_id', 'customer_location_id', 'plant_id',
    'version_no', 'base_bf_code');
create trigger trg_cpb_audit after insert or update on public.customer_pricing_bf_delta_sets
  for each row execute function app_private.cph_audit('bf_delta_set');

create trigger trg_cpd_immutable before update or delete on public.customer_pricing_bf_deltas
  for each row execute function app_private.cph_immutable_row();
create trigger trg_cpd_audit after insert on public.customer_pricing_bf_deltas
  for each row execute function app_private.cph_audit('bf_delta');

create trigger trg_cpw_version before update on public.customer_pricing_line_measures
  for each row execute function app_private.cph_before_update();
create trigger trg_cpw_freeze before update on public.customer_pricing_line_measures
  for each row execute function app_private.cph_freeze_columns('line_id', 'measure', 'source');
create trigger trg_cpw_audit after insert or update on public.customer_pricing_line_measures
  for each row execute function app_private.cph_audit('line_measure');

create trigger trg_cpr_version before update on public.customer_pricing_event_bf_rates
  for each row execute function app_private.cph_before_update();
create trigger trg_cpr_freeze before update on public.customer_pricing_event_bf_rates
  for each row execute function app_private.cph_freeze_columns('event_id', 'bf_code', 'delta_inr');
create trigger trg_cpr_audit after insert or update on public.customer_pricing_event_bf_rates
  for each row execute function app_private.cph_audit('event_bf_rate');

create trigger trg_cpl_refs_freeze before update on public.customer_pricing_lines
  for each row execute function app_private.cph_freeze_columns('prior_line_id');

-- ──────────────────────────────────────────────────────── shared checks
-- Term and BF writes serialise per Customer on the mechanism row, so the
-- overlap check below cannot race another writer for the same Customer.
create or replace function app_private.cph_lock_customer(p_party bigint)
returns void
language plpgsql security definer set search_path = '' as $fn$
begin
  perform 1 from public.customer_pricing_mechanisms m where m.party_id = p_party for update;
  if not found then
    raise exception 'record the Customer''s pricing mechanism first' using errcode = '22023';
  end if;
end $fn$;

create or replace function app_private.cph_check_money(p_value numeric, p_label text)
returns void
language plpgsql immutable security definer set search_path = '' as $fn$
begin
  if p_value is not null and p_value <> round(p_value, 2) then
    raise exception '% has more than two decimal places', p_label using errcode = '22023';
  end if;
end $fn$;

-- ─────────────────────────────────────────────────────── Stable Terms RPCs
create or replace function app_private.cph_create_term_version(
  p_party bigint, p_location bigint, p_plant bigint,
  p_effective_from date, p_effective_to date, p_close_prior boolean,
  p_rate_basis text, p_weight_basis text,
  p_wastage_treatment text, p_wastage_pct numeric, p_freight_treatment text,
  p_conversion_inr_per_kg numeric, p_freight_inr_per_kg numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_prior bigint; v_next integer; v_id bigint;
begin
  v_me := app_private.cph_require_editor();
  perform app_private.cph_require_party(p_party);
  perform app_private.cph_lock_customer(p_party);
  perform app_private.cph_check_money(p_conversion_inr_per_kg, 'conversion');
  perform app_private.cph_check_money(p_freight_inr_per_kg, 'freight');
  perform app_private.cph_check_money(p_wastage_pct, 'wastage %');

  -- A new effective version may explicitly close the open-ended one it
  -- follows; that closure is an audited update, never a silent rewrite.
  if coalesce(p_close_prior, false) then
    select t.id into v_prior from public.customer_pricing_term_versions t
     where t.party_id = p_party
       and coalesce(t.customer_location_id, 0) = coalesce(p_location, 0)
       and coalesce(t.plant_id, 0) = coalesce(p_plant, 0)
       and t.status = 'active' and t.effective_to is null and t.effective_from < p_effective_from
     order by t.effective_from desc limit 1;
    if v_prior is not null then
      update public.customer_pricing_term_versions
         set effective_to = p_effective_from - 1 where id = v_prior;
    end if;
  end if;

  if exists (select 1 from public.customer_pricing_term_versions t
              where t.party_id = p_party
                and coalesce(t.customer_location_id, 0) = coalesce(p_location, 0)
                and coalesce(t.plant_id, 0) = coalesce(p_plant, 0)
                and t.status = 'active'
                and daterange(t.effective_from, t.effective_to, '[]')
                    && daterange(p_effective_from, p_effective_to, '[]')) then
    raise exception 'another active Stable Term version already applies to this scope in that period'
      using errcode = '23P01';
  end if;

  select coalesce(max(t.version_no), 0) + 1 into v_next
    from public.customer_pricing_term_versions t
   where t.party_id = p_party
     and coalesce(t.customer_location_id, 0) = coalesce(p_location, 0)
     and coalesce(t.plant_id, 0) = coalesce(p_plant, 0);

  insert into public.customer_pricing_term_versions (
    party_id, customer_location_id, plant_id, version_no, effective_from, effective_to,
    rate_basis, weight_basis, wastage_treatment, wastage_pct, freight_treatment,
    conversion_inr_per_kg, freight_inr_per_kg, source_type, source_date, source_ref, notes,
    created_by, updated_by)
  values (p_party, p_location, p_plant, v_next, p_effective_from, p_effective_to,
    p_rate_basis, p_weight_basis, coalesce(p_wastage_treatment, 'not_captured'), p_wastage_pct,
    coalesce(p_freight_treatment, 'not_captured'), p_conversion_inr_per_kg, p_freight_inr_per_kg,
    p_source_type, p_source_date, nullif(btrim(coalesce(p_source_ref, '')), ''),
    nullif(btrim(coalesce(p_notes, '')), ''), v_me, v_me)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'version_no', v_next, 'content_version', 1,
                            'closed_prior_id', v_prior);
end $fn$;

-- An explicitly audited CAS correction of one version (a typo, a withdrawn
-- version). Rounds already recorded keep their own snapshot.
create or replace function app_private.cph_correct_term_version(
  p_term bigint, p_expected_version integer, p_status text,
  p_effective_from date, p_effective_to date,
  p_rate_basis text, p_weight_basis text,
  p_wastage_treatment text, p_wastage_pct numeric, p_freight_treatment text,
  p_conversion_inr_per_kg numeric, p_freight_inr_per_kg numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_row public.customer_pricing_term_versions%rowtype; v_version integer; v_status text;
begin
  perform app_private.cph_require_editor();
  select t.* into v_row from public.customer_pricing_term_versions t where t.id = p_term;
  if not found then
    raise exception 'Stable Term version not found' using errcode = 'P0002';
  end if;
  perform app_private.cph_lock_customer(v_row.party_id);
  select t.* into v_row from public.customer_pricing_term_versions t where t.id = p_term for update;
  if p_expected_version is null or v_row.content_version <> p_expected_version then
    raise exception 'the Stable Term changed since you read it (expected %, found %)',
      p_expected_version, v_row.content_version using errcode = 'PT409';
  end if;
  perform app_private.cph_check_money(p_conversion_inr_per_kg, 'conversion');
  perform app_private.cph_check_money(p_freight_inr_per_kg, 'freight');
  perform app_private.cph_check_money(p_wastage_pct, 'wastage %');
  v_status := coalesce(p_status, v_row.status);
  if v_status = 'active' and exists (
       select 1 from public.customer_pricing_term_versions t
        where t.id <> p_term and t.party_id = v_row.party_id
          and coalesce(t.customer_location_id, 0) = coalesce(v_row.customer_location_id, 0)
          and coalesce(t.plant_id, 0) = coalesce(v_row.plant_id, 0)
          and t.status = 'active'
          and daterange(t.effective_from, t.effective_to, '[]')
              && daterange(p_effective_from, p_effective_to, '[]')) then
    raise exception 'another active Stable Term version already applies to this scope in that period'
      using errcode = '23P01';
  end if;
  update public.customer_pricing_term_versions set
    status = v_status, effective_from = p_effective_from, effective_to = p_effective_to,
    rate_basis = p_rate_basis, weight_basis = p_weight_basis,
    wastage_treatment = coalesce(p_wastage_treatment, 'not_captured'), wastage_pct = p_wastage_pct,
    freight_treatment = coalesce(p_freight_treatment, 'not_captured'),
    conversion_inr_per_kg = p_conversion_inr_per_kg, freight_inr_per_kg = p_freight_inr_per_kg,
    source_type = p_source_type, source_date = p_source_date,
    source_ref = nullif(btrim(coalesce(p_source_ref, '')), ''),
    notes = nullif(btrim(coalesce(p_notes, '')), '')
  where id = p_term
  returning content_version into v_version;
  return jsonb_build_object('id', p_term, 'content_version', v_version);
end $fn$;

-- ────────────────────────────────────────────────────────── BF set RPCs
-- p_deltas: [{"bf_code": "20", "delta_inr": "1.50"}, ...] - signed, exact 2dp.
create or replace function app_private.cph_create_bf_delta_set(
  p_party bigint, p_location bigint, p_plant bigint,
  p_effective_from date, p_effective_to date, p_close_prior boolean,
  p_base_bf_code text, p_deltas jsonb,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_prior bigint; v_next integer; v_id bigint; v_entry jsonb; v_delta numeric;
begin
  v_me := app_private.cph_require_editor();
  perform app_private.cph_require_party(p_party);
  perform app_private.cph_lock_customer(p_party);
  if p_deltas is null or jsonb_typeof(p_deltas) <> 'array' then
    raise exception 'the BF delta schedule must be a list' using errcode = '22023';
  end if;

  if coalesce(p_close_prior, false) then
    select s.id into v_prior from public.customer_pricing_bf_delta_sets s
     where s.party_id = p_party
       and coalesce(s.customer_location_id, 0) = coalesce(p_location, 0)
       and coalesce(s.plant_id, 0) = coalesce(p_plant, 0)
       and s.status = 'active' and s.effective_to is null and s.effective_from < p_effective_from
     order by s.effective_from desc limit 1;
    if v_prior is not null then
      update public.customer_pricing_bf_delta_sets set effective_to = p_effective_from - 1 where id = v_prior;
    end if;
  end if;

  if exists (select 1 from public.customer_pricing_bf_delta_sets s
              where s.party_id = p_party
                and coalesce(s.customer_location_id, 0) = coalesce(p_location, 0)
                and coalesce(s.plant_id, 0) = coalesce(p_plant, 0)
                and s.status = 'active'
                and daterange(s.effective_from, s.effective_to, '[]')
                    && daterange(p_effective_from, p_effective_to, '[]')) then
    raise exception 'another active BF delta set already applies to this scope in that period'
      using errcode = '23P01';
  end if;

  select coalesce(max(s.version_no), 0) + 1 into v_next
    from public.customer_pricing_bf_delta_sets s
   where s.party_id = p_party
     and coalesce(s.customer_location_id, 0) = coalesce(p_location, 0)
     and coalesce(s.plant_id, 0) = coalesce(p_plant, 0);

  insert into public.customer_pricing_bf_delta_sets (
    party_id, customer_location_id, plant_id, version_no, effective_from, effective_to,
    base_bf_code, source_type, source_date, source_ref, notes, created_by, updated_by)
  values (p_party, p_location, p_plant, v_next, p_effective_from, p_effective_to,
    upper(btrim(p_base_bf_code)), p_source_type, p_source_date,
    nullif(btrim(coalesce(p_source_ref, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''), v_me, v_me)
  returning id into v_id;

  for v_entry in select * from jsonb_array_elements(p_deltas) loop
    if upper(btrim(v_entry ->> 'bf_code')) = upper(btrim(p_base_bf_code)) then
      raise exception 'the base BF carries no delta' using errcode = '22023';
    end if;
    v_delta := (v_entry ->> 'delta_inr')::numeric;
    if v_delta is null then
      raise exception 'every BF in the schedule needs a delta (use 0.00 for none)' using errcode = '22023';
    end if;
    perform app_private.cph_check_money(v_delta, 'BF delta');
    insert into public.customer_pricing_bf_deltas (set_id, bf_code, delta_inr, created_by)
    values (v_id, upper(btrim(v_entry ->> 'bf_code')), v_delta, v_me);
  end loop;
  return jsonb_build_object('id', v_id, 'version_no', v_next, 'content_version', 1,
                            'closed_prior_id', v_prior);
end $fn$;

-- Header-only CAS correction (dates, status, notes, source). The schedule
-- itself never changes: a different delta is a new set version.
create or replace function app_private.cph_correct_bf_delta_set(
  p_set bigint, p_expected_version integer, p_status text,
  p_effective_from date, p_effective_to date,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_row public.customer_pricing_bf_delta_sets%rowtype; v_version integer; v_status text;
begin
  perform app_private.cph_require_editor();
  select s.* into v_row from public.customer_pricing_bf_delta_sets s where s.id = p_set;
  if not found then
    raise exception 'BF delta set not found' using errcode = 'P0002';
  end if;
  perform app_private.cph_lock_customer(v_row.party_id);
  select s.* into v_row from public.customer_pricing_bf_delta_sets s where s.id = p_set for update;
  if p_expected_version is null or v_row.content_version <> p_expected_version then
    raise exception 'the BF delta set changed since you read it (expected %, found %)',
      p_expected_version, v_row.content_version using errcode = 'PT409';
  end if;
  v_status := coalesce(p_status, v_row.status);
  if v_status = 'active' and exists (
       select 1 from public.customer_pricing_bf_delta_sets s
        where s.id <> p_set and s.party_id = v_row.party_id
          and coalesce(s.customer_location_id, 0) = coalesce(v_row.customer_location_id, 0)
          and coalesce(s.plant_id, 0) = coalesce(v_row.plant_id, 0)
          and s.status = 'active'
          and daterange(s.effective_from, s.effective_to, '[]')
              && daterange(p_effective_from, p_effective_to, '[]')) then
    raise exception 'another active BF delta set already applies to this scope in that period'
      using errcode = '23P01';
  end if;
  update public.customer_pricing_bf_delta_sets set
    status = v_status, effective_from = p_effective_from, effective_to = p_effective_to,
    source_type = p_source_type, source_date = p_source_date,
    source_ref = nullif(btrim(coalesce(p_source_ref, '')), ''),
    notes = nullif(btrim(coalesce(p_notes, '')), '')
  where id = p_set
  returning content_version into v_version;
  return jsonb_build_object('id', p_set, 'content_version', v_version);
end $fn$;

-- ──────────────────────────────────────────────── line references / measures
-- A line may reference a term / BF set only if it applies to the line's scope
-- (same or wider Location/Plant) at the start of the line's Cycle.
create or replace function app_private.cph_set_line_references(
  p_line bigint, p_expected_version integer, p_term bigint, p_bf_set bigint)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_line public.customer_pricing_lines%rowtype; v_start date; v_version integer;
begin
  perform app_private.cph_require_editor();
  select l.* into v_line from public.customer_pricing_lines l where l.id = p_line for update;
  if not found then
    raise exception 'pricing Line not found' using errcode = 'P0002';
  end if;
  if p_expected_version is null or v_line.content_version <> p_expected_version then
    raise exception 'the Line changed since you read it (expected %, found %)',
      p_expected_version, v_line.content_version using errcode = 'PT409';
  end if;
  select c.period_start into v_start from public.customer_pricing_cycles c where c.id = v_line.cycle_id;
  if p_term is not null and not exists (
       select 1 from public.customer_pricing_term_versions t
        where t.id = p_term and t.party_id = v_line.party_id and t.status = 'active'
          and (t.customer_location_id is null or t.customer_location_id = v_line.customer_location_id)
          and (t.plant_id is null or t.plant_id = v_line.plant_id)
          and t.effective_from <= v_start and (t.effective_to is null or t.effective_to >= v_start)) then
    raise exception 'that Stable Term does not apply to this line''s scope and period' using errcode = '22023';
  end if;
  if p_bf_set is not null and not exists (
       select 1 from public.customer_pricing_bf_delta_sets s
        where s.id = p_bf_set and s.party_id = v_line.party_id and s.status = 'active'
          and (s.customer_location_id is null or s.customer_location_id = v_line.customer_location_id)
          and (s.plant_id is null or s.plant_id = v_line.plant_id)
          and s.effective_from <= v_start and (s.effective_to is null or s.effective_to >= v_start)) then
    raise exception 'that BF delta set does not apply to this line''s scope and period' using errcode = '22023';
  end if;
  update public.customer_pricing_lines set term_version_id = p_term, bf_delta_set_id = p_bf_set
   where id = p_line returning content_version into v_version;
  return jsonb_build_object('id', p_line, 'content_version', v_version);
end $fn$;

-- Record, change or withdraw ONE (measure, source) value. p_expected_version
-- NULL means "I saw no value from this source"; p_value NULL withdraws.
create or replace function app_private.cph_set_line_measure(
  p_line bigint, p_measure text, p_source text, p_value numeric,
  p_expected_version integer, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_row public.customer_pricing_line_measures%rowtype; v_id bigint; v_version integer;
begin
  v_me := app_private.cph_require_editor();
  perform 1 from public.customer_pricing_lines l where l.id = p_line for update;
  if not found then
    raise exception 'pricing Line not found' using errcode = 'P0002';
  end if;
  if p_value is not null and p_value <> round(p_value, 4) then
    raise exception 'weights and area carry at most four decimals' using errcode = '22023';
  end if;
  select w.* into v_row from public.customer_pricing_line_measures w
   where w.line_id = p_line and w.measure = p_measure and w.source = p_source for update;
  if not found then
    if p_expected_version is not null then
      raise exception 'that value no longer exists - reload' using errcode = 'PT409';
    end if;
    if p_value is null then
      raise exception 'nothing recorded from that source to withdraw' using errcode = '22023';
    end if;
    insert into public.customer_pricing_line_measures (line_id, measure, source, value, notes, created_by, updated_by)
    values (p_line, p_measure, p_source, p_value, nullif(btrim(coalesce(p_notes, '')), ''), v_me, v_me)
    returning id, content_version into v_id, v_version;
  else
    if p_expected_version is null or v_row.content_version <> p_expected_version then
      raise exception 'that value changed since you read it (expected %, found %)',
        p_expected_version, v_row.content_version using errcode = 'PT409';
    end if;
    update public.customer_pricing_line_measures set
      value  = coalesce(p_value, value),
      status = case when p_value is null then 'withdrawn' else 'active' end,
      notes  = nullif(btrim(coalesce(p_notes, '')), '')
    where id = v_row.id
    returning id, content_version into v_id, v_version;
  end if;
  return jsonb_build_object('id', v_id, 'content_version', v_version);
end $fn$;

-- ─────────────────────────────────────────────── rounds with components
-- Supersets of P0.1's cph_add_event / cph_correct_event that also carry the
-- component breakup. The snapshot triggers apply to both paths alike.
create or replace function app_private.cph_add_round(
  p_line bigint, p_event_type text, p_event_date date, p_rate_inr numeric,
  p_tax_treatment text, p_gst_pct numeric,
  p_kraft_inr numeric, p_conversion_inr numeric, p_freight_inr numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text,
  p_client_request_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_party bigint; v_rate_basis text; v_weight_basis text;
        v_tax text; v_seq integer; v_id bigint;
begin
  v_me := app_private.cph_require_editor();
  select l.party_id into v_party
    from public.customer_pricing_lines l where l.id = p_line and l.status = 'active' for update;
  if v_party is null then
    raise exception 'active pricing Line not found' using errcode = 'P0002';
  end if;
  perform app_private.cph_check_money(p_rate_inr, 'rate');
  perform app_private.cph_check_money(p_kraft_inr, 'Kraft paper component');
  perform app_private.cph_check_money(p_conversion_inr, 'conversion component');
  perform app_private.cph_check_money(p_freight_inr, 'freight component');
  select m.rate_basis, m.weight_basis, m.tax_treatment into v_rate_basis, v_weight_basis, v_tax
    from public.customer_pricing_mechanisms m where m.party_id = v_party;
  select coalesce(max(e.sequence_no), 0) + 1 into v_seq
    from public.customer_pricing_negotiation_events e where e.line_id = p_line;
  insert into public.customer_pricing_negotiation_events (
    line_id, event_type, event_date, sequence_no, rate_inr, rate_basis, weight_basis,
    tax_treatment, gst_pct, component_kraft_inr, component_conversion_inr, component_freight_inr,
    source_type, source_date, source_ref, notes, client_request_id, created_by, updated_by)
  values (p_line, p_event_type, p_event_date, v_seq, p_rate_inr, v_rate_basis, v_weight_basis,
          coalesce(p_tax_treatment, v_tax, 'excluding_gst'), p_gst_pct,
          p_kraft_inr, p_conversion_inr, p_freight_inr,
          p_source_type, p_source_date, nullif(btrim(coalesce(p_source_ref, '')), ''),
          nullif(btrim(coalesce(p_notes, '')), ''), p_client_request_id, v_me, v_me)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'sequence_no', v_seq, 'content_version', 1);
end $fn$;

create or replace function app_private.cph_correct_round(
  p_event bigint, p_expected_version integer,
  p_event_type text, p_event_date date, p_rate_inr numeric,
  p_tax_treatment text, p_gst_pct numeric,
  p_kraft_inr numeric, p_conversion_inr numeric, p_freight_inr numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_current integer; v_version integer;
begin
  perform app_private.cph_require_editor();
  select e.content_version into v_current
    from public.customer_pricing_negotiation_events e where e.id = p_event for update;
  if not found then
    raise exception 'negotiation event not found' using errcode = 'P0002';
  end if;
  if p_expected_version is null or v_current <> p_expected_version then
    raise exception 'the negotiation event changed since you read it (expected %, found %)',
      p_expected_version, v_current using errcode = 'PT409';
  end if;
  perform app_private.cph_check_money(p_rate_inr, 'rate');
  perform app_private.cph_check_money(p_kraft_inr, 'Kraft paper component');
  perform app_private.cph_check_money(p_conversion_inr, 'conversion component');
  perform app_private.cph_check_money(p_freight_inr, 'freight component');
  update public.customer_pricing_negotiation_events set
    event_type = p_event_type, event_date = p_event_date, rate_inr = p_rate_inr,
    tax_treatment = coalesce(p_tax_treatment, tax_treatment), gst_pct = p_gst_pct,
    component_kraft_inr = p_kraft_inr, component_conversion_inr = p_conversion_inr,
    component_freight_inr = p_freight_inr,
    source_type = p_source_type, source_date = p_source_date,
    source_ref = nullif(btrim(coalesce(p_source_ref, '')), ''),
    notes = nullif(btrim(coalesce(p_notes, '')), '')
  where id = p_event
  returning content_version into v_version;
  return jsonb_build_object('id', p_event, 'content_version', v_version);
end $fn$;

-- Set or clear ONE BF-specific override on a round, under the round's CAS.
-- The snapshotted delta is untouched, so derived and overridden stay visible.
create or replace function app_private.cph_set_bf_override(
  p_event bigint, p_expected_version integer, p_bf_code text, p_override_rate_inr numeric)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_current integer; v_version integer;
begin
  perform app_private.cph_require_editor();
  select e.content_version into v_current
    from public.customer_pricing_negotiation_events e where e.id = p_event for update;
  if not found then
    raise exception 'negotiation event not found' using errcode = 'P0002';
  end if;
  if p_expected_version is null or v_current <> p_expected_version then
    raise exception 'the negotiation event changed since you read it (expected %, found %)',
      p_expected_version, v_current using errcode = 'PT409';
  end if;
  perform app_private.cph_check_money(p_override_rate_inr, 'BF override');
  update public.customer_pricing_event_bf_rates set override_rate_inr = p_override_rate_inr
   where event_id = p_event and bf_code = upper(btrim(p_bf_code));
  if not found then
    raise exception 'that BF is not in this round''s snapshotted schedule' using errcode = 'P0002';
  end if;
  -- Touch the round so its version moves: a concurrent editor of the round
  -- is refused rather than silently reading a schedule that changed.
  update public.customer_pricing_negotiation_events set updated_at = now()
   where id = p_event returning content_version into v_version;
  return jsonb_build_object('id', p_event, 'content_version', v_version);
end $fn$;

-- ───────────────────────────────────────────────────── Start next cycle
-- Copies structure only: scopes, the term / BF set that applies at the new
-- period start, and weight/area context. SOB, rounds and rates start blank;
-- the prior line is linked so its agreed values show as locked comparison.
create or replace function app_private.cph_start_next_cycle(
  p_prior_cycle bigint, p_period_start date, p_period_end date,
  p_initiated_on date, p_custom_label text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_prior public.customer_pricing_cycles%rowtype; v_freq text; v_cycle bigint;
        r public.customer_pricing_lines%rowtype; v_term bigint; v_bf bigint; v_line bigint; v_lines integer := 0;
begin
  v_me := app_private.cph_require_editor();
  select c.* into v_prior from public.customer_pricing_cycles c where c.id = p_prior_cycle;
  if not found then
    raise exception 'pricing Cycle not found' using errcode = 'P0002';
  end if;
  perform app_private.cph_require_party(v_prior.party_id);
  select m.review_frequency into v_freq
    from public.customer_pricing_mechanisms m where m.party_id = v_prior.party_id;
  if p_period_start <= v_prior.period_start then
    raise exception 'the next Cycle must start after the one it follows' using errcode = '22023';
  end if;

  insert into public.customer_pricing_cycles (
    party_id, mechanism_id, review_frequency, period_start, period_end,
    custom_label, initiated_on, created_by, updated_by)
  values (v_prior.party_id, v_prior.mechanism_id, coalesce(v_freq, v_prior.review_frequency),
          p_period_start, p_period_end, nullif(btrim(coalesce(p_custom_label, '')), ''),
          p_initiated_on, v_me, v_me)
  returning id into v_cycle;

  for r in select l.* from public.customer_pricing_lines l
            where l.cycle_id = p_prior_cycle and l.status = 'active' order by l.id loop
    -- The version that applies NOW for the same scope as the prior reference.
    v_term := null; v_bf := null;
    if r.term_version_id is not null then
      select t2.id into v_term
        from public.customer_pricing_term_versions t1
        join public.customer_pricing_term_versions t2
          on t2.party_id = t1.party_id
         and coalesce(t2.customer_location_id, 0) = coalesce(t1.customer_location_id, 0)
         and coalesce(t2.plant_id, 0) = coalesce(t1.plant_id, 0)
       where t1.id = r.term_version_id and t2.status = 'active'
         and t2.effective_from <= p_period_start
         and (t2.effective_to is null or t2.effective_to >= p_period_start)
       order by t2.version_no desc limit 1;
    end if;
    if r.bf_delta_set_id is not null then
      select s2.id into v_bf
        from public.customer_pricing_bf_delta_sets s1
        join public.customer_pricing_bf_delta_sets s2
          on s2.party_id = s1.party_id
         and coalesce(s2.customer_location_id, 0) = coalesce(s1.customer_location_id, 0)
         and coalesce(s2.plant_id, 0) = coalesce(s1.plant_id, 0)
       where s1.id = r.bf_delta_set_id and s2.status = 'active'
         and s2.effective_from <= p_period_start
         and (s2.effective_to is null or s2.effective_to >= p_period_start)
       order by s2.version_no desc limit 1;
    end if;
    insert into public.customer_pricing_lines (
      cycle_id, party_id, customer_location_id, plant_id, sku_id, scope_text,
      term_version_id, bf_delta_set_id, prior_line_id, created_by, updated_by)
    values (v_cycle, r.party_id, r.customer_location_id, r.plant_id, r.sku_id, r.scope_text,
            v_term, v_bf, r.id, v_me, v_me)
    returning id into v_line;
    insert into public.customer_pricing_line_measures (line_id, measure, source, value, notes, created_by, updated_by)
    select v_line, w.measure, w.source, w.value,
           left(concat_ws(' · ', w.notes, 'carried from line ' || r.id), 500), v_me, v_me
      from public.customer_pricing_line_measures w
     where w.line_id = r.id and w.status = 'active';
    v_lines := v_lines + 1;
  end loop;
  return jsonb_build_object('id', v_cycle, 'content_version', 1, 'lines', v_lines);
end $fn$;

-- ───────────────────────────────────────────────── public invoker wrappers
create or replace function public.cph_create_term_version(
  p_party bigint, p_location bigint, p_plant bigint,
  p_effective_from date, p_effective_to date, p_close_prior boolean,
  p_rate_basis text, p_weight_basis text,
  p_wastage_treatment text, p_wastage_pct numeric, p_freight_treatment text,
  p_conversion_inr_per_kg numeric, p_freight_inr_per_kg numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_create_term_version(p_party, p_location, p_plant, p_effective_from,
    p_effective_to, p_close_prior, p_rate_basis, p_weight_basis, p_wastage_treatment, p_wastage_pct,
    p_freight_treatment, p_conversion_inr_per_kg, p_freight_inr_per_kg, p_source_type, p_source_date,
    p_source_ref, p_notes);
$fn$;

create or replace function public.cph_correct_term_version(
  p_term bigint, p_expected_version integer, p_status text,
  p_effective_from date, p_effective_to date,
  p_rate_basis text, p_weight_basis text,
  p_wastage_treatment text, p_wastage_pct numeric, p_freight_treatment text,
  p_conversion_inr_per_kg numeric, p_freight_inr_per_kg numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_correct_term_version(p_term, p_expected_version, p_status, p_effective_from,
    p_effective_to, p_rate_basis, p_weight_basis, p_wastage_treatment, p_wastage_pct, p_freight_treatment,
    p_conversion_inr_per_kg, p_freight_inr_per_kg, p_source_type, p_source_date, p_source_ref, p_notes);
$fn$;

create or replace function public.cph_create_bf_delta_set(
  p_party bigint, p_location bigint, p_plant bigint,
  p_effective_from date, p_effective_to date, p_close_prior boolean,
  p_base_bf_code text, p_deltas jsonb,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_create_bf_delta_set(p_party, p_location, p_plant, p_effective_from,
    p_effective_to, p_close_prior, p_base_bf_code, p_deltas, p_source_type, p_source_date,
    p_source_ref, p_notes);
$fn$;

create or replace function public.cph_correct_bf_delta_set(
  p_set bigint, p_expected_version integer, p_status text,
  p_effective_from date, p_effective_to date,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_correct_bf_delta_set(p_set, p_expected_version, p_status, p_effective_from,
    p_effective_to, p_source_type, p_source_date, p_source_ref, p_notes);
$fn$;

create or replace function public.cph_set_line_references(
  p_line bigint, p_expected_version integer, p_term bigint, p_bf_set bigint)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_set_line_references(p_line, p_expected_version, p_term, p_bf_set);
$fn$;

create or replace function public.cph_set_line_measure(
  p_line bigint, p_measure text, p_source text, p_value numeric,
  p_expected_version integer, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_set_line_measure(p_line, p_measure, p_source, p_value, p_expected_version, p_notes);
$fn$;

create or replace function public.cph_add_round(
  p_line bigint, p_event_type text, p_event_date date, p_rate_inr numeric,
  p_tax_treatment text, p_gst_pct numeric,
  p_kraft_inr numeric, p_conversion_inr numeric, p_freight_inr numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text,
  p_client_request_id uuid)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_add_round(p_line, p_event_type, p_event_date, p_rate_inr, p_tax_treatment,
    p_gst_pct, p_kraft_inr, p_conversion_inr, p_freight_inr, p_source_type, p_source_date,
    p_source_ref, p_notes, p_client_request_id);
$fn$;

create or replace function public.cph_correct_round(
  p_event bigint, p_expected_version integer,
  p_event_type text, p_event_date date, p_rate_inr numeric,
  p_tax_treatment text, p_gst_pct numeric,
  p_kraft_inr numeric, p_conversion_inr numeric, p_freight_inr numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_correct_round(p_event, p_expected_version, p_event_type, p_event_date,
    p_rate_inr, p_tax_treatment, p_gst_pct, p_kraft_inr, p_conversion_inr, p_freight_inr,
    p_source_type, p_source_date, p_source_ref, p_notes);
$fn$;

create or replace function public.cph_set_bf_override(
  p_event bigint, p_expected_version integer, p_bf_code text, p_override_rate_inr numeric)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_set_bf_override(p_event, p_expected_version, p_bf_code, p_override_rate_inr);
$fn$;

create or replace function public.cph_start_next_cycle(
  p_prior_cycle bigint, p_period_start date, p_period_end date,
  p_initiated_on date, p_custom_label text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_start_next_cycle(p_prior_cycle, p_period_start, p_period_end,
    p_initiated_on, p_custom_label);
$fn$;

-- ─────────────────────────────────────────────────────────────── grants
do $$
declare f text;
begin
  foreach f in array array[
    'cph_create_term_version(bigint,bigint,bigint,date,date,boolean,text,text,text,numeric,text,numeric,numeric,text,date,text,text)',
    'cph_correct_term_version(bigint,integer,text,date,date,text,text,text,numeric,text,numeric,numeric,text,date,text,text)',
    'cph_create_bf_delta_set(bigint,bigint,bigint,date,date,boolean,text,jsonb,text,date,text,text)',
    'cph_correct_bf_delta_set(bigint,integer,text,date,date,text,date,text,text)',
    'cph_set_line_references(bigint,integer,bigint,bigint)',
    'cph_set_line_measure(bigint,text,text,numeric,integer,text)',
    'cph_add_round(bigint,text,date,numeric,text,numeric,numeric,numeric,numeric,text,date,text,text,uuid)',
    'cph_correct_round(bigint,integer,text,date,numeric,text,numeric,numeric,numeric,numeric,text,date,text,text)',
    'cph_set_bf_override(bigint,integer,text,numeric)',
    'cph_start_next_cycle(bigint,date,date,date,text)']
  loop
    execute format('revoke all on function app_private.%s from public, anon', f);
    execute format('grant execute on function app_private.%s to authenticated', f);
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['cph_freeze_columns()', 'cph_immutable_row()', 'cph_event_snapshot()',
                           'cph_event_bf_snapshot()', 'cph_event_bf_floor()', 'cph_lock_customer(bigint)',
                           'cph_check_money(numeric,text)', 'cph_audit()']
  loop
    execute format('revoke all on function app_private.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- ────────────────────────────────────────────────────── structural gates
-- Run: select * from tests.cph_p0_2_catalogue();  (every row must be ok)
create or replace function tests.cph_p0_2_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
declare
  v_tables text[] := array['customer_pricing_term_versions','customer_pricing_bf_delta_sets',
    'customer_pricing_bf_deltas','customer_pricing_line_measures','customer_pricing_event_bf_rates'];
  v_ops text[] := array[
    'cph_create_term_version(bigint,bigint,bigint,date,date,boolean,text,text,text,numeric,text,numeric,numeric,text,date,text,text)',
    'cph_correct_term_version(bigint,integer,text,date,date,text,text,text,numeric,text,numeric,numeric,text,date,text,text)',
    'cph_create_bf_delta_set(bigint,bigint,bigint,date,date,boolean,text,jsonb,text,date,text,text)',
    'cph_correct_bf_delta_set(bigint,integer,text,date,date,text,date,text,text)',
    'cph_set_line_references(bigint,integer,bigint,bigint)',
    'cph_set_line_measure(bigint,text,text,numeric,integer,text)',
    'cph_add_round(bigint,text,date,numeric,text,numeric,numeric,numeric,numeric,text,date,text,text,uuid)',
    'cph_correct_round(bigint,integer,text,date,numeric,text,numeric,numeric,numeric,numeric,text,date,text,text)',
    'cph_set_bf_override(bigint,integer,text,numeric)',
    'cph_start_next_cycle(bigint,date,date,date,text)'];
  t text; f text; v_bad text[];
begin
  v_bad := '{}';
  foreach t in array v_tables loop
    if not exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relname = t and c.relrowsecurity and c.relforcerowsecurity)
       or pg_catalog.has_table_privilege('anon', 'public.' || t, 'SELECT,INSERT,UPDATE,DELETE')
       or not pg_catalog.has_table_privilege('authenticated', 'public.' || t, 'SELECT')
       or pg_catalog.has_table_privilege('authenticated', 'public.' || t, 'INSERT,UPDATE,DELETE,TRUNCATE') then
      v_bad := v_bad || t;
    end if;
  end loop;
  ok := cardinality(v_bad) = 0;
  name := 'CPH2-1 new tables: RLS forced, anon nothing, authenticated SELECT only ' || v_bad::text;
  return next;

  select coalesce(array_agg(p.tablename::text), '{}') into v_bad
    from pg_catalog.pg_policies p
   where p.schemaname = 'public' and p.tablename = any (v_tables)
     and (p.cmd <> 'SELECT' or p.qual not like '%read_party_master%' or 'anon' = any (p.roles)
          or 'public' = any (p.roles));
  ok := cardinality(v_bad) = 0
    and (select count(*) from pg_catalog.pg_policies p
          where p.schemaname = 'public' and p.tablename = any (v_tables)) = cardinality(v_tables);
  name := 'CPH2-2 exactly one read_party_master SELECT policy per new table ' || v_bad::text;
  return next;

  v_bad := '{}';
  foreach f in array v_ops loop
    if not pg_catalog.has_function_privilege('authenticated', 'public.' || f, 'EXECUTE')
       or not pg_catalog.has_function_privilege('authenticated', 'app_private.' || f, 'EXECUTE')
       or pg_catalog.has_function_privilege('anon', 'public.' || f, 'EXECUTE')
       or pg_catalog.has_function_privilege('anon', 'app_private.' || f, 'EXECUTE') then
      v_bad := v_bad || f;
    end if;
  end loop;
  ok := cardinality(v_bad) = 0;
  name := 'CPH2-3 new wrappers and definers: authenticated EXECUTE, never anon ' || v_bad::text;
  return next;

  -- Across ALL pricing-history tables, old and new.
  select coalesce(array_agg(format('%s.%s', c.conrelid::regclass, c.conname)), '{}') into v_bad
    from pg_catalog.pg_constraint c
    join pg_catalog.pg_class k on k.oid = c.conrelid
    join pg_catalog.pg_namespace n on n.oid = k.relnamespace
   where c.contype = 'f' and n.nspname = 'public' and k.relname like 'customer\_pricing\_%'
     and not exists (select 1 from pg_catalog.pg_index i
                      where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]);
  ok := cardinality(v_bad) = 0; name := 'CPH2-4 every pricing-history foreign key has a covering index ' || v_bad::text;
  return next;

  select coalesce(array_agg(p.proname::text), '{}') into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app_private' and p.proname like 'cph\_%'
     and (not p.prosecdef or p.proconfig is null
          or not ('search_path=""' = any (p.proconfig) or 'search_path=' = any (p.proconfig)));
  ok := cardinality(v_bad) = 0; name := 'CPH2-5 every private definer pins an empty search_path ' || v_bad::text;
  return next;

  select coalesce(array_agg(format('%s', k.relname)), '{}') into v_bad
    from pg_catalog.pg_class k join pg_catalog.pg_namespace n on n.oid = k.relnamespace
   where n.nspname = 'public' and k.relname like 'customer\_pricing\_%' and k.relkind = 'r'
     and (not k.relrowsecurity or not k.relforcerowsecurity);
  ok := cardinality(v_bad) = 0; name := 'CPH2-6 RLS still forced on every pricing-history table ' || v_bad::text;
  return next;
end $fn$;
revoke all on function tests.cph_p0_2_catalogue() from public, anon, authenticated;
