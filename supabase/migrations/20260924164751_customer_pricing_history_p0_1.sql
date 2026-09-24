-- Customer Pricing History, P0.1: foundation and one thin vertical path.
--
-- Authority: quote-gen-fe/docs/customer-pricing-history-phase-0-implementation-plan-2026-09-23.md
-- (Product Owner approved 2026-09-23). This is a DIRECT-EDIT business record,
-- not a Checker-authorised master: there is no draft/approve state here.
--
-- WHAT THIS SLICE CREATES
--   customer_pricing_mechanisms          one per Customer (parties.id): cadence + basis
--   customer_pricing_cycles              one applicable review period
--   customer_pricing_lines               one Cycle's applicable scope
--   customer_pricing_negotiation_events  every offer / counter / agreement, never overwritten
--   customer_pricing_change_events       append-only actor/time/before/after evidence
-- Stable-Term versions, BF delta sets and component breakups are P0.2 and
-- arrive in their own migration.
--
-- AUTHORISATION. Reading AND direct editing require the caller's
-- read_party_master group capability (plan §8.4): being authenticated is not
-- access. manage_customer_master is deliberately NOT required - the Product
-- Owner chose collaborative direct editing.
--
-- WRITE PATH. authenticated holds SELECT only on these tables; there is no
-- INSERT/UPDATE/DELETE privilege, so a caller cannot bypass CAS or audit by
-- writing through the Data API. Every write is one app_private SECURITY
-- DEFINER function (fixed empty search_path, identity + capability checked in
-- the body) reached through a public SECURITY INVOKER wrapper. Both carry an
-- EXECUTE grant for authenticated: the invoker wrapper calls its definer as
-- the caller (the 20260916165004 / 20260922150221 trap).
--
-- AUDIT. AFTER INSERT/UPDATE triggers write customer_pricing_change_events in
-- the same transaction as the business row, so neither can commit without the
-- other. The actor is current_app_user(); a write without an active app user
-- is refused, so there is no anonymous or service-role edit path.
--
-- CONCURRENCY. Mechanisms, Cycles, Lines and Events carry content_version.
-- Every update names the version it read; a mismatch raises PT409 (mapped to
-- STALE_VERSION) and changes nothing. A BEFORE UPDATE trigger bumps the
-- version on every update path.
--
-- MONEY. Every INR value is numeric(12,2). Percentages are numeric(5,2).
-- NULL means "not recorded"; 0.00 is a deliberate value and never a blank.
--
-- NO HARD DELETE. No DELETE privilege or policy exists on any of these tables.

-- ───────────────────────────────────────────────────────────── mechanisms
create table public.customer_pricing_mechanisms (
  id                 bigint generated always as identity primary key,
  party_id           bigint      not null,
  review_frequency   text        not null default 'ad_hoc',
  period_label_style text        not null default 'financial_year',
  rate_basis         text        null,
  weight_basis       text        null,
  tax_treatment      text        not null default 'excluding_gst',
  notes              text        null,
  content_version    integer     not null default 1,
  created_at         timestamptz not null default now(),
  created_by         bigint      not null,
  updated_at         timestamptz not null default now(),
  updated_by         bigint      not null,
  constraint fk_cpm_party      foreign key (party_id)   references public.parties(id)   on delete restrict,
  constraint fk_cpm_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_cpm_updated_by foreign key (updated_by) references public.app_users(id) on delete restrict,
  -- One current mechanism per Customer identity (plan §3).
  constraint uk_cpm_party unique (party_id),
  constraint uk_cpm_id_party unique (id, party_id),
  constraint ck_cpm_frequency check (review_frequency in
    ('monthly','bimonthly','quarterly','half_yearly','annual','ad_hoc')),
  constraint ck_cpm_label_style check (period_label_style in
    ('calendar_year','financial_year','custom')),
  -- NULL = not yet captured. A kg basis without a Weight Basis stays savable;
  -- comparison/conversion is disabled until both are present (plan §8.2).
  constraint ck_cpm_rate_basis check (rate_basis is null or rate_basis in
    ('box_per_piece','box_per_kg','kraft_paper_per_kg','box_per_sqm')),
  constraint ck_cpm_weight_basis check (weight_basis is null or weight_basis in
    ('paper_consumed','sheet_weight','box_weight')),
  constraint ck_cpm_tax check (tax_treatment in ('excluding_gst','including_gst')),
  constraint ck_cpm_notes check (notes is null or char_length(notes) <= 2000),
  constraint ck_cpm_version check (content_version >= 1)
);
create index ix_cpm_created_by on public.customer_pricing_mechanisms (created_by);
create index ix_cpm_updated_by on public.customer_pricing_mechanisms (updated_by);

-- ───────────────────────────────────────────────────────────────── cycles
-- Deliberately NOT a Batch: the governed `batches` entity is unrelated.
create table public.customer_pricing_cycles (
  id               bigint generated always as identity primary key,
  party_id         bigint      not null,
  mechanism_id     bigint      not null,
  review_frequency text        not null,
  period_start     date        not null,
  period_end       date        not null,
  custom_label     text        null,
  initiated_on     date        not null,
  status           text        not null default 'open',
  notes            text        null,
  content_version  integer     not null default 1,
  created_at       timestamptz not null default now(),
  created_by       bigint      not null,
  updated_at       timestamptz not null default now(),
  updated_by       bigint      not null,
  constraint fk_cpc_party      foreign key (party_id) references public.parties(id) on delete restrict,
  -- The mechanism must belong to the same Customer.
  constraint fk_cpc_mechanism  foreign key (mechanism_id, party_id)
    references public.customer_pricing_mechanisms(id, party_id) on delete restrict,
  constraint fk_cpc_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_cpc_updated_by foreign key (updated_by) references public.app_users(id) on delete restrict,
  constraint uk_cpc_id_party unique (id, party_id),
  constraint ck_cpc_frequency check (review_frequency in
    ('monthly','bimonthly','quarterly','half_yearly','annual','ad_hoc')),
  constraint ck_cpc_period check (period_end >= period_start),
  constraint ck_cpc_custom_label check (custom_label is null
    or (btrim(custom_label) <> '' and char_length(custom_label) <= 80)),
  constraint ck_cpc_status check (status in ('open','closed')),
  constraint ck_cpc_notes check (notes is null or char_length(notes) <= 2000),
  constraint ck_cpc_version check (content_version >= 1)
);
-- One Cycle per Customer and exact period. The custom label is presentation
-- only, so it is deliberately NOT part of the key: relabelling can never mint
-- a second Cycle for the same period.
alter table public.customer_pricing_cycles
  add constraint uk_cpc_party_period unique (party_id, period_start, period_end);
create index ix_cpc_party_period on public.customer_pricing_cycles (party_id, period_start desc);
create index ix_cpc_mechanism  on public.customer_pricing_cycles (mechanism_id, party_id);
create index ix_cpc_created_by on public.customer_pricing_cycles (created_by);
create index ix_cpc_updated_by on public.customer_pricing_cycles (updated_by);

-- ────────────────────────────────────────────────────────────────── lines
create table public.customer_pricing_lines (
  id                   bigint generated always as identity primary key,
  cycle_id             bigint      not null,
  party_id             bigint      not null,
  customer_location_id bigint      null,
  plant_id             bigint      null,
  sku_id               bigint      null,
  -- Unresolved item/portfolio scope is retained as text; no master identity is invented.
  scope_text           text        null,
  sob_state            text        not null default 'not_captured',
  sob_pct              numeric(5,2) null,
  notes                text        null,
  status               text        not null default 'active',
  content_version      integer     not null default 1,
  created_at           timestamptz not null default now(),
  created_by           bigint      not null,
  updated_at           timestamptz not null default now(),
  updated_by           bigint      not null,
  constraint fk_cpl_cycle    foreign key (cycle_id, party_id)
    references public.customer_pricing_cycles(id, party_id) on delete restrict,
  constraint fk_cpl_party    foreign key (party_id) references public.parties(id) on delete restrict,
  -- A Location must be this Customer's own (uk_loc_id_party).
  constraint fk_cpl_location foreign key (customer_location_id, party_id)
    references public.customer_locations(id, party_id) on delete restrict,
  constraint fk_cpl_plant    foreign key (plant_id) references public.plants(id) on delete restrict,
  -- A SKU must be this Customer's own (uk_sku_id_party)...
  constraint fk_cpl_sku_party foreign key (sku_id, party_id)
    references public.skus(id, party_id) on delete restrict,
  -- ...and, when a Plant is also named, that SKU's Plant (uk_sku_id_plant).
  -- MATCH SIMPLE: with plant_id NULL this check does not apply.
  constraint fk_cpl_sku_plant foreign key (sku_id, plant_id)
    references public.skus(id, plant_id) on delete restrict,
  constraint fk_cpl_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_cpl_updated_by foreign key (updated_by) references public.app_users(id) on delete restrict,
  constraint ck_cpl_scope_text check (scope_text is null
    or (btrim(scope_text) <> '' and char_length(scope_text) <= 200)),
  -- SOB (plan §4.10): defined carries a 0.00-100.00 percentage; 0 is a
  -- deliberate allocation. Every other state carries no percentage.
  constraint ck_cpl_sob_state check (sob_state in ('not_captured','undefined','not_applicable','defined')),
  constraint ck_cpl_sob_pct check (
    (sob_state = 'defined' and sob_pct is not null and sob_pct >= 0 and sob_pct <= 100)
    or (sob_state <> 'defined' and sob_pct is null)),
  constraint ck_cpl_status check (status in ('active','withdrawn')),
  constraint ck_cpl_notes check (notes is null or char_length(notes) <= 2000),
  constraint ck_cpl_version check (content_version >= 1)
);
-- Cycle + scope: one active line per exact scope.
create unique index uk_cpl_scope on public.customer_pricing_lines (
  cycle_id,
  (coalesce(customer_location_id, 0)), (coalesce(plant_id, 0)), (coalesce(sku_id, 0)),
  (lower(coalesce(scope_text, ''))))
  where status = 'active';
create index ix_cpl_cycle      on public.customer_pricing_lines (cycle_id, party_id);
create index ix_cpl_party      on public.customer_pricing_lines (party_id);
create index ix_cpl_location   on public.customer_pricing_lines (customer_location_id, party_id);
create index ix_cpl_plant      on public.customer_pricing_lines (plant_id);
create index ix_cpl_sku_party  on public.customer_pricing_lines (sku_id, party_id);
create index ix_cpl_sku_plant  on public.customer_pricing_lines (sku_id, plant_id);
create index ix_cpl_created_by on public.customer_pricing_lines (created_by);
create index ix_cpl_updated_by on public.customer_pricing_lines (updated_by);

-- ───────────────────────────────────────────────────── negotiation events
create table public.customer_pricing_negotiation_events (
  id                bigint generated always as identity primary key,
  line_id           bigint      not null,
  event_type        text        not null,
  event_date        date        not null,
  -- Stable tie-break for events on the same date; allocated under a line lock.
  sequence_no       integer     not null,
  rate_inr          numeric(12,2) null,
  -- Snapshots of what the rate meant WHEN it was offered.
  rate_basis        text        null,
  weight_basis      text        null,
  tax_treatment     text        not null default 'excluding_gst',
  gst_pct           numeric(5,2) null,
  source_type       text        null,
  source_date       date        null,
  source_ref        text        null,
  notes             text        null,
  -- Client-generated idempotency key: a retried "add" after an unknown
  -- outcome is refused as a duplicate instead of recording a second round.
  -- NOT NULL so the public RPC cannot be called without it.
  client_request_id uuid        not null,
  status            text        not null default 'active',
  content_version   integer     not null default 1,
  created_at        timestamptz not null default now(),
  created_by        bigint      not null,
  updated_at        timestamptz not null default now(),
  updated_by        bigint      not null,
  constraint fk_cpe_line       foreign key (line_id)    references public.customer_pricing_lines(id) on delete restrict,
  constraint fk_cpe_created_by foreign key (created_by) references public.app_users(id) on delete restrict,
  constraint fk_cpe_updated_by foreign key (updated_by) references public.app_users(id) on delete restrict,
  constraint uk_cpe_sequence unique (line_id, sequence_no),
  constraint uk_cpe_client_request unique (line_id, client_request_id),
  constraint ck_cpe_type check (event_type in ('avadhoot_offer','customer_counter','final_agreement')),
  constraint ck_cpe_sequence check (sequence_no >= 1),
  constraint ck_cpe_rate check (rate_inr is null or rate_inr >= 0),
  constraint ck_cpe_rate_basis check (rate_basis is null or rate_basis in
    ('box_per_piece','box_per_kg','kraft_paper_per_kg','box_per_sqm')),
  constraint ck_cpe_weight_basis check (weight_basis is null or weight_basis in
    ('paper_consumed','sheet_weight','box_weight')),
  constraint ck_cpe_tax check (tax_treatment in ('excluding_gst','including_gst')),
  -- GST-inclusive rates keep the GST % that applied then (plan §4.1).
  constraint ck_cpe_gst check (
    (tax_treatment = 'including_gst' and gst_pct is not null and gst_pct > 0 and gst_pct <= 100)
    or (tax_treatment = 'excluding_gst' and gst_pct is null)),
  constraint ck_cpe_source_type check (source_type is null or source_type in
    ('email','whatsapp','call','meeting','excel','other')),
  constraint ck_cpe_source_ref check (source_ref is null or char_length(source_ref) <= 500),
  constraint ck_cpe_notes check (notes is null or char_length(notes) <= 2000),
  constraint ck_cpe_status check (status in ('active','voided')),
  constraint ck_cpe_version check (content_version >= 1)
);
-- Line + chronology.
create index ix_cpe_line_chronology on public.customer_pricing_negotiation_events (line_id, event_date, sequence_no);
create index ix_cpe_created_by on public.customer_pricing_negotiation_events (created_by);
create index ix_cpe_updated_by on public.customer_pricing_negotiation_events (updated_by);

-- ──────────────────────────────────────────────────────────── change events
create table public.customer_pricing_change_events (
  id                bigint generated always as identity primary key,
  party_id          bigint      not null,
  entity_type       text        not null,
  entity_id         bigint      not null,
  operation         text        not null,
  content_version   integer     null,
  before_state      jsonb       null,
  after_state       jsonb       not null,
  actor_app_user_id bigint      not null,
  occurred_at       timestamptz not null default now(),
  constraint fk_cpx_party foreign key (party_id) references public.parties(id) on delete restrict,
  constraint fk_cpx_actor foreign key (actor_app_user_id) references public.app_users(id) on delete restrict,
  constraint ck_cpx_entity check (entity_type in ('mechanism','cycle','line','negotiation_event')),
  constraint ck_cpx_operation check (operation in ('create','update')),
  constraint ck_cpx_before check ((operation = 'create') = (before_state is null))
);
create index ix_cpx_party_time on public.customer_pricing_change_events (party_id, occurred_at desc);
create index ix_cpx_entity     on public.customer_pricing_change_events (entity_type, entity_id);
create index ix_cpx_actor      on public.customer_pricing_change_events (actor_app_user_id);

-- ────────────────────────────────────────────────── privileges and RLS
-- Explicit grants: Supabase is moving new-table exposure to opt-in, and this
-- file must not depend on either default.
do $$
declare t text;
begin
  foreach t in array array['customer_pricing_mechanisms','customer_pricing_cycles',
                           'customer_pricing_lines','customer_pricing_negotiation_events',
                           'customer_pricing_change_events']
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
-- No INSERT/UPDATE/DELETE grant or policy: writes exist only as the governed
-- functions below, and there is no hard-delete path at all.

-- ───────────────────────────────────────────────────── shared helpers
create or replace function app_private.cph_require_editor()
returns bigint
language plpgsql stable security definer set search_path = '' as $fn$
declare v_me bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null or not app_private.has_group_cap('read_party_master') then
    raise exception 'read_party_master is required to record Customer pricing history'
      using errcode = '42501';
  end if;
  return v_me;
end $fn$;

-- Pricing history belongs to a live Customer/Prospect identity. A merged
-- identity's history lives on its survivor.
create or replace function app_private.cph_require_party(p_party bigint)
returns void
language plpgsql stable security definer set search_path = '' as $fn$
declare v_status text;
begin
  select p.status into v_status from public.parties p where p.id = p_party;
  if not found then
    raise exception 'Customer not found' using errcode = 'P0002';
  end if;
  if v_status = 'merged' then
    raise exception 'that Customer was merged - record pricing on the surviving Customer'
      using errcode = '22023';
  end if;
end $fn$;

-- ───────────────────────────────────────────────── version + audit triggers
create or replace function app_private.cph_before_update()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if new.id <> old.id then
    raise exception 'identity columns are immutable' using errcode = '22023';
  end if;
  new.content_version := old.content_version + 1;
  new.updated_at := now();
  new.updated_by := coalesce(app_private.current_app_user(), old.updated_by);
  new.created_at := old.created_at;
  new.created_by := old.created_by;
  return new;
end $fn$;

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
  if v_entity = 'negotiation_event' then
    select l.party_id into v_party from public.customer_pricing_lines l where l.id = new.line_id;
  else
    v_party := new.party_id;
  end if;
  insert into public.customer_pricing_change_events (
    party_id, entity_type, entity_id, operation, content_version,
    before_state, after_state, actor_app_user_id)
  values (
    v_party, v_entity, new.id,
    case tg_op when 'INSERT' then 'create' else 'update' end,
    new.content_version,
    case tg_op when 'INSERT' then null else to_jsonb(old) end,
    to_jsonb(new), v_actor);
  return null;
end $fn$;

-- Parent-key columns never move: a line cannot hop Cycles, nor an event Lines.
create or replace function app_private.cph_freeze_parent()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if (to_jsonb(new) -> tg_argv[0]) is distinct from (to_jsonb(old) -> tg_argv[0])
     or (tg_nargs > 1 and (to_jsonb(new) -> tg_argv[1]) is distinct from (to_jsonb(old) -> tg_argv[1])) then
    raise exception 'the owning record of a pricing-history row cannot change'
      using errcode = '22023';
  end if;
  return new;
end $fn$;

create trigger trg_cpm_version before update on public.customer_pricing_mechanisms
  for each row execute function app_private.cph_before_update();
create trigger trg_cpm_freeze before update on public.customer_pricing_mechanisms
  for each row execute function app_private.cph_freeze_parent('party_id');
create trigger trg_cpm_audit after insert or update on public.customer_pricing_mechanisms
  for each row execute function app_private.cph_audit('mechanism');

create trigger trg_cpc_version before update on public.customer_pricing_cycles
  for each row execute function app_private.cph_before_update();
create trigger trg_cpc_freeze before update on public.customer_pricing_cycles
  for each row execute function app_private.cph_freeze_parent('party_id', 'mechanism_id');
create trigger trg_cpc_audit after insert or update on public.customer_pricing_cycles
  for each row execute function app_private.cph_audit('cycle');

create trigger trg_cpl_version before update on public.customer_pricing_lines
  for each row execute function app_private.cph_before_update();
create trigger trg_cpl_freeze before update on public.customer_pricing_lines
  for each row execute function app_private.cph_freeze_parent('cycle_id', 'party_id');
create trigger trg_cpl_audit after insert or update on public.customer_pricing_lines
  for each row execute function app_private.cph_audit('line');

create trigger trg_cpe_version before update on public.customer_pricing_negotiation_events
  for each row execute function app_private.cph_before_update();
create trigger trg_cpe_freeze before update on public.customer_pricing_negotiation_events
  for each row execute function app_private.cph_freeze_parent('line_id', 'sequence_no');
create trigger trg_cpe_audit after insert or update on public.customer_pricing_negotiation_events
  for each row execute function app_private.cph_audit('negotiation_event');

-- The change log is append-only even for the table owner's own code paths.
create or replace function app_private.cph_change_log_immutable()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  raise exception 'pricing-history change events are append-only' using errcode = '42501';
end $fn$;
create trigger trg_cpx_immutable before update or delete on public.customer_pricing_change_events
  for each row execute function app_private.cph_change_log_immutable();

-- ───────────────────────────────────────────────────────── mechanism
-- p_expected_version NULL = "I saw no mechanism": creates one, or refuses
-- PT409 if another user created it first. Otherwise CAS update.
create or replace function app_private.cph_save_mechanism(
  p_party bigint, p_expected_version integer,
  p_review_frequency text, p_period_label_style text,
  p_rate_basis text, p_weight_basis text, p_tax_treatment text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint; v_current integer; v_version integer;
begin
  v_me := app_private.cph_require_editor();
  perform app_private.cph_require_party(p_party);

  select m.id, m.content_version into v_id, v_current
    from public.customer_pricing_mechanisms m where m.party_id = p_party for update;

  if p_expected_version is null then
    if v_id is not null then
      raise exception 'a pricing mechanism already exists for this Customer - reload and edit it'
        using errcode = 'PT409';
    end if;
    insert into public.customer_pricing_mechanisms (
      party_id, review_frequency, period_label_style, rate_basis, weight_basis,
      tax_treatment, notes, created_by, updated_by)
    values (p_party, coalesce(p_review_frequency, 'ad_hoc'),
            coalesce(p_period_label_style, 'financial_year'),
            p_rate_basis, p_weight_basis, coalesce(p_tax_treatment, 'excluding_gst'),
            nullif(btrim(coalesce(p_notes, '')), ''), v_me, v_me)
    returning id, content_version into v_id, v_version;
  else
    if v_id is null then
      raise exception 'pricing mechanism not found' using errcode = 'P0002';
    end if;
    if v_current <> p_expected_version then
      raise exception 'the mechanism changed since you read it (expected %, found %)',
        p_expected_version, v_current using errcode = 'PT409';
    end if;
    update public.customer_pricing_mechanisms set
      review_frequency   = coalesce(p_review_frequency, review_frequency),
      period_label_style = coalesce(p_period_label_style, period_label_style),
      rate_basis         = p_rate_basis,
      weight_basis       = p_weight_basis,
      tax_treatment      = coalesce(p_tax_treatment, tax_treatment),
      notes              = nullif(btrim(coalesce(p_notes, '')), '')
    where id = v_id
    returning content_version into v_version;
  end if;
  return jsonb_build_object('id', v_id, 'content_version', v_version);
end $fn$;

-- ─────────────────────────────────────────────────────────────── cycles
create or replace function app_private.cph_create_cycle(
  p_party bigint, p_period_start date, p_period_end date,
  p_initiated_on date, p_review_frequency text, p_custom_label text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_mech bigint; v_freq text; v_id bigint;
begin
  v_me := app_private.cph_require_editor();
  perform app_private.cph_require_party(p_party);
  select m.id, m.review_frequency into v_mech, v_freq
    from public.customer_pricing_mechanisms m where m.party_id = p_party;
  if v_mech is null then
    raise exception 'record the Customer''s pricing mechanism before its first Cycle'
      using errcode = '22023';
  end if;
  insert into public.customer_pricing_cycles (
    party_id, mechanism_id, review_frequency, period_start, period_end,
    custom_label, initiated_on, notes, created_by, updated_by)
  values (p_party, v_mech, coalesce(p_review_frequency, v_freq), p_period_start, p_period_end,
          nullif(btrim(coalesce(p_custom_label, '')), ''), p_initiated_on,
          nullif(btrim(coalesce(p_notes, '')), ''), v_me, v_me)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'content_version', 1);
end $fn$;

create or replace function app_private.cph_update_cycle(
  p_cycle bigint, p_expected_version integer,
  p_period_start date, p_period_end date, p_initiated_on date,
  p_review_frequency text, p_custom_label text, p_status text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_current integer; v_version integer;
begin
  perform app_private.cph_require_editor();
  select c.content_version into v_current
    from public.customer_pricing_cycles c where c.id = p_cycle for update;
  if not found then
    raise exception 'pricing Cycle not found' using errcode = 'P0002';
  end if;
  if p_expected_version is null or v_current <> p_expected_version then
    raise exception 'the Cycle changed since you read it (expected %, found %)',
      p_expected_version, v_current using errcode = 'PT409';
  end if;
  update public.customer_pricing_cycles set
    period_start     = p_period_start,
    period_end       = p_period_end,
    initiated_on     = p_initiated_on,
    review_frequency = coalesce(p_review_frequency, review_frequency),
    custom_label     = nullif(btrim(coalesce(p_custom_label, '')), ''),
    status           = coalesce(p_status, status),
    notes            = nullif(btrim(coalesce(p_notes, '')), '')
  where id = p_cycle
  returning content_version into v_version;
  return jsonb_build_object('id', p_cycle, 'content_version', v_version);
end $fn$;

-- ──────────────────────────────────────────────────────────────── lines
create or replace function app_private.cph_create_line(
  p_cycle bigint, p_customer_location bigint, p_plant bigint, p_sku bigint,
  p_scope_text text, p_sob_state text, p_sob_pct numeric, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_party bigint; v_id bigint;
begin
  v_me := app_private.cph_require_editor();
  select c.party_id into v_party from public.customer_pricing_cycles c where c.id = p_cycle;
  if v_party is null then
    raise exception 'pricing Cycle not found' using errcode = 'P0002';
  end if;
  insert into public.customer_pricing_lines (
    cycle_id, party_id, customer_location_id, plant_id, sku_id, scope_text,
    sob_state, sob_pct, notes, created_by, updated_by)
  values (p_cycle, v_party, p_customer_location, p_plant, p_sku,
          nullif(btrim(coalesce(p_scope_text, '')), ''),
          coalesce(p_sob_state, 'not_captured'), p_sob_pct,
          nullif(btrim(coalesce(p_notes, '')), ''), v_me, v_me)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'content_version', 1);
end $fn$;

create or replace function app_private.cph_update_line(
  p_line bigint, p_expected_version integer,
  p_customer_location bigint, p_plant bigint, p_sku bigint,
  p_scope_text text, p_sob_state text, p_sob_pct numeric, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_current integer; v_version integer;
begin
  perform app_private.cph_require_editor();
  select l.content_version into v_current
    from public.customer_pricing_lines l where l.id = p_line for update;
  if not found then
    raise exception 'pricing Line not found' using errcode = 'P0002';
  end if;
  if p_expected_version is null or v_current <> p_expected_version then
    raise exception 'the Line changed since you read it (expected %, found %)',
      p_expected_version, v_current using errcode = 'PT409';
  end if;
  update public.customer_pricing_lines set
    customer_location_id = p_customer_location,
    plant_id             = p_plant,
    sku_id               = p_sku,
    scope_text           = nullif(btrim(coalesce(p_scope_text, '')), ''),
    sob_state            = coalesce(p_sob_state, 'not_captured'),
    sob_pct              = p_sob_pct,
    notes                = nullif(btrim(coalesce(p_notes, '')), '')
  where id = p_line
  returning content_version into v_version;
  return jsonb_build_object('id', p_line, 'content_version', v_version);
end $fn$;

-- ─────────────────────────────────────────────────── negotiation events
-- Adding a round never needs the Line's version: two people recording two
-- rounds are both right. The Line row lock serialises sequence allocation.
create or replace function app_private.cph_add_event(
  p_line bigint, p_event_type text, p_event_date date, p_rate_inr numeric,
  p_tax_treatment text, p_gst_pct numeric,
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
  -- Snapshot what the rate meant at the time, so a later mechanism change
  -- never reinterprets an old offer.
  select m.rate_basis, m.weight_basis, m.tax_treatment into v_rate_basis, v_weight_basis, v_tax
    from public.customer_pricing_mechanisms m where m.party_id = v_party;
  select coalesce(max(e.sequence_no), 0) + 1 into v_seq
    from public.customer_pricing_negotiation_events e where e.line_id = p_line;
  insert into public.customer_pricing_negotiation_events (
    line_id, event_type, event_date, sequence_no, rate_inr, rate_basis, weight_basis,
    tax_treatment, gst_pct, source_type, source_date, source_ref, notes,
    client_request_id, created_by, updated_by)
  values (p_line, p_event_type, p_event_date, v_seq, p_rate_inr, v_rate_basis, v_weight_basis,
          coalesce(p_tax_treatment, v_tax, 'excluding_gst'), p_gst_pct,
          p_source_type, p_source_date, nullif(btrim(coalesce(p_source_ref, '')), ''),
          nullif(btrim(coalesce(p_notes, '')), ''), p_client_request_id, v_me, v_me)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'sequence_no', v_seq, 'content_version', 1);
end $fn$;

-- Correcting a round is an audited CAS update of THAT round; it never
-- replaces or reorders any other round.
create or replace function app_private.cph_correct_event(
  p_event bigint, p_expected_version integer,
  p_event_type text, p_event_date date, p_rate_inr numeric,
  p_tax_treatment text, p_gst_pct numeric,
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
  update public.customer_pricing_negotiation_events set
    event_type    = p_event_type,
    event_date    = p_event_date,
    rate_inr      = p_rate_inr,
    tax_treatment = coalesce(p_tax_treatment, tax_treatment),
    gst_pct       = p_gst_pct,
    source_type   = p_source_type,
    source_date   = p_source_date,
    source_ref    = nullif(btrim(coalesce(p_source_ref, '')), ''),
    notes         = nullif(btrim(coalesce(p_notes, '')), '')
  where id = p_event
  returning content_version into v_version;
  return jsonb_build_object('id', p_event, 'content_version', v_version);
end $fn$;

-- ───────────────────────────────────────────────── public invoker wrappers
create or replace function public.cph_save_mechanism(
  p_party bigint, p_expected_version integer,
  p_review_frequency text, p_period_label_style text,
  p_rate_basis text, p_weight_basis text, p_tax_treatment text, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_save_mechanism(p_party, p_expected_version, p_review_frequency,
    p_period_label_style, p_rate_basis, p_weight_basis, p_tax_treatment, p_notes);
$fn$;

create or replace function public.cph_create_cycle(
  p_party bigint, p_period_start date, p_period_end date,
  p_initiated_on date, p_review_frequency text, p_custom_label text, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_create_cycle(p_party, p_period_start, p_period_end,
    p_initiated_on, p_review_frequency, p_custom_label, p_notes);
$fn$;

create or replace function public.cph_update_cycle(
  p_cycle bigint, p_expected_version integer,
  p_period_start date, p_period_end date, p_initiated_on date,
  p_review_frequency text, p_custom_label text, p_status text, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_update_cycle(p_cycle, p_expected_version, p_period_start,
    p_period_end, p_initiated_on, p_review_frequency, p_custom_label, p_status, p_notes);
$fn$;

create or replace function public.cph_create_line(
  p_cycle bigint, p_customer_location bigint, p_plant bigint, p_sku bigint,
  p_scope_text text, p_sob_state text, p_sob_pct numeric, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_create_line(p_cycle, p_customer_location, p_plant, p_sku,
    p_scope_text, p_sob_state, p_sob_pct, p_notes);
$fn$;

create or replace function public.cph_update_line(
  p_line bigint, p_expected_version integer,
  p_customer_location bigint, p_plant bigint, p_sku bigint,
  p_scope_text text, p_sob_state text, p_sob_pct numeric, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_update_line(p_line, p_expected_version, p_customer_location,
    p_plant, p_sku, p_scope_text, p_sob_state, p_sob_pct, p_notes);
$fn$;

create or replace function public.cph_add_event(
  p_line bigint, p_event_type text, p_event_date date, p_rate_inr numeric,
  p_tax_treatment text, p_gst_pct numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text,
  p_client_request_id uuid)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_add_event(p_line, p_event_type, p_event_date, p_rate_inr,
    p_tax_treatment, p_gst_pct, p_source_type, p_source_date, p_source_ref, p_notes,
    p_client_request_id);
$fn$;

create or replace function public.cph_correct_event(
  p_event bigint, p_expected_version integer,
  p_event_type text, p_event_date date, p_rate_inr numeric,
  p_tax_treatment text, p_gst_pct numeric,
  p_source_type text, p_source_date date, p_source_ref text, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_correct_event(p_event, p_expected_version, p_event_type,
    p_event_date, p_rate_inr, p_tax_treatment, p_gst_pct, p_source_type, p_source_date,
    p_source_ref, p_notes);
$fn$;

-- ─────────────────────────────────────────────────────────────── grants
do $$
declare f text;
begin
  -- Callable operations: private definer + public invoker wrapper, both
  -- executable by authenticated (the wrapper calls the definer AS the caller).
  foreach f in array array[
    'cph_save_mechanism(bigint,integer,text,text,text,text,text,text)',
    'cph_create_cycle(bigint,date,date,date,text,text,text)',
    'cph_update_cycle(bigint,integer,date,date,date,text,text,text,text)',
    'cph_create_line(bigint,bigint,bigint,bigint,text,text,numeric,text)',
    'cph_update_line(bigint,integer,bigint,bigint,bigint,text,text,numeric,text)',
    'cph_add_event(bigint,text,date,numeric,text,numeric,text,date,text,text,uuid)',
    'cph_correct_event(bigint,integer,text,date,numeric,text,numeric,text,date,text,text)']
  loop
    execute format('revoke all on function app_private.%s from public, anon', f);
    execute format('grant execute on function app_private.%s to authenticated', f);
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  -- Internal helpers and trigger functions: nobody calls these directly.
  foreach f in array array['cph_require_editor()', 'cph_require_party(bigint)',
                           'cph_before_update()', 'cph_audit()', 'cph_freeze_parent()',
                           'cph_change_log_immutable()']
  loop
    execute format('revoke all on function app_private.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- ────────────────────────────────────────────────────── structural gates
-- Run: select * from tests.cph_p0_1_catalogue();  (every row must be ok)
-- Deliberately NOT registered in tests.run_all(): run_all currently stops at a
-- pre-existing family_d_group_masters fixture collision (recorded debt).
create or replace function tests.cph_p0_1_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
declare
  v_tables text[] := array['customer_pricing_mechanisms','customer_pricing_cycles',
    'customer_pricing_lines','customer_pricing_negotiation_events','customer_pricing_change_events'];
  v_ops text[] := array[
    'cph_save_mechanism(bigint,integer,text,text,text,text,text,text)',
    'cph_create_cycle(bigint,date,date,date,text,text,text)',
    'cph_update_cycle(bigint,integer,date,date,date,text,text,text,text)',
    'cph_create_line(bigint,bigint,bigint,bigint,text,text,numeric,text)',
    'cph_update_line(bigint,integer,bigint,bigint,bigint,text,text,numeric,text)',
    'cph_add_event(bigint,text,date,numeric,text,numeric,text,date,text,text,uuid)',
    'cph_correct_event(bigint,integer,text,date,numeric,text,numeric,text,date,text,text)'];
  t text; f text; v_bad text[];
begin
  v_bad := '{}';
  foreach t in array v_tables loop
    if not exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relname = t and c.relrowsecurity and c.relforcerowsecurity) then
      v_bad := v_bad || t;
    end if;
  end loop;
  ok := cardinality(v_bad) = 0; name := 'CPH-1 RLS enabled and forced on every pricing-history table ' || v_bad::text;
  return next;

  v_bad := '{}';
  foreach t in array v_tables loop
    if pg_catalog.has_table_privilege('anon', 'public.' || t, 'SELECT,INSERT,UPDATE,DELETE') then
      v_bad := v_bad || t;
    end if;
  end loop;
  ok := cardinality(v_bad) = 0; name := 'CPH-2 anon holds no table privilege ' || v_bad::text;
  return next;

  v_bad := '{}';
  foreach t in array v_tables loop
    if not pg_catalog.has_table_privilege('authenticated', 'public.' || t, 'SELECT')
       or pg_catalog.has_table_privilege('authenticated', 'public.' || t, 'INSERT,UPDATE,DELETE,TRUNCATE') then
      v_bad := v_bad || t;
    end if;
  end loop;
  ok := cardinality(v_bad) = 0;
  name := 'CPH-3 authenticated may SELECT but never write directly (CAS/audit cannot be bypassed) ' || v_bad::text;
  return next;

  -- Every SELECT policy carries the real predicate, not bare TO authenticated.
  select coalesce(array_agg(p.tablename::text), '{}') into v_bad
    from pg_catalog.pg_policies p
   where p.schemaname = 'public' and p.tablename = any (v_tables)
     and (p.cmd <> 'SELECT' or p.qual not like '%read_party_master%' or 'anon' = any (p.roles)
          or 'public' = any (p.roles));
  ok := cardinality(v_bad) = 0
    and (select count(*) from pg_catalog.pg_policies p
          where p.schemaname = 'public' and p.tablename = any (v_tables)) = cardinality(v_tables);
  name := 'CPH-4 exactly one SELECT policy per table, gated by read_party_master ' || v_bad::text;
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
  name := 'CPH-5 wrappers and their definers are executable by authenticated and never by anon ' || v_bad::text;
  return next;

  -- Every foreign-key column is covered by an index whose leading column matches.
  select coalesce(array_agg(format('%s.%s', c.conrelid::regclass, c.conname)), '{}') into v_bad
    from pg_catalog.pg_constraint c
   where c.contype = 'f' and c.conrelid::regclass::text = any (
           select 'customer_pricing_' || x from unnest(array['mechanisms','cycles','lines',
             'negotiation_events','change_events']) x
           union select 'public.customer_pricing_' || x from unnest(array['mechanisms','cycles','lines',
             'negotiation_events','change_events']) x)
     and not exists (select 1 from pg_catalog.pg_index i
                      where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]);
  ok := cardinality(v_bad) = 0; name := 'CPH-6 every foreign key has a covering index ' || v_bad::text;
  return next;

  select coalesce(array_agg(p.proname::text), '{}') into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app_private' and p.proname like 'cph\_%'
     and (not p.prosecdef or p.proconfig is null
          or not ('search_path=""' = any (p.proconfig) or 'search_path=' = any (p.proconfig)));
  ok := cardinality(v_bad) = 0; name := 'CPH-7 every private definer pins an empty search_path ' || v_bad::text;
  return next;
end $fn$;
revoke all on function tests.cph_p0_1_catalogue() from public, anon, authenticated;
