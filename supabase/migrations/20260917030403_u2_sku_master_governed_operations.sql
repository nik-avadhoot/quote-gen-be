-- U2 SKU Master: governed editing by due authority, slice 1.
--
-- PREPARED, NOT APPLIED. Product Owner rulings 2026-09-16 on the design packet
-- quote-gen-fe/docs/u2-sku-master-governed-edit-design-packet.md, recorded as
-- Canonical Amendment 04:
--
--   D1   due authority is manage_sku_master at the SKU's plant. The SAME person may
--        propose and approve (initially). A Maker (make_quote) may propose a SKU and
--        its versions, because approval must not hold a new SKU back from quotation.
--   D2   field classes: plant and Customer are never editable; dimensions, the
--        Construction version, BS / BCT / ECT, box type and the customer-stated GSM /
--        CS / BS / ECT force a NEW SKU (refused here with PT423); item names,
--        printing fields, customer spec version, Item Family and Item Group make a
--        new version; Cobb value, item weight and ups make a PRICE-DRIVING version.
--        A draft version is editable in place until approved.
--   D3   assigning the Plant Item Code is separate from publishing; publishing needs
--        a code, an approved version and a portfolio. A code is never reissued.
--   D4   discontinuing needs a reason; a replacement is at the same plant and
--        Customer and is never substituted; reactivation clears the link (history
--        keeps it); a Proposed SKU may be WITHDRAWN (terminal).
--   D5   references are added and withdrawn, never edited in place.
--   D8   every operation takes expected_content_version and raises PT409 when stale;
--        the database maintains the token on skus and sku_versions.
--   D9   an append-only sku_master_events history, written inside each operation.
--   D10  the direct INSERT / UPDATE path on skus, sku_versions and
--        sku_external_references is closed; the S4-3 functions are no longer
--        reachable by callers.
--   D7   Location applicability is deferred, so sku_location_applicabilities and
--        its Maker batch_only proposal path are deliberately untouched here.
--   D6   SKU Sets are slice 2 and are not touched here.
--
-- DEPENDS ON Amendment 02 (20260917024849) and Amendment 03 (20260917024903); it
-- refuses to run without them. No row of existing data is changed.
--
-- S9: every table written here is Family C. Nothing reads or writes a Family G
-- (Quote) table, so this neither enables nor relies on production Quote mutations.
-- The one Family F touch is an additive trigger that refuses a WITHDRAWN SKU on a
-- Batch row; no existing Family F function or trigger body changes.

-- ─────────────────────────────────────────────────────────────── dependencies
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'sku_versions' and column_name = 'item_name') then
    raise exception using errcode = 'object_not_in_prerequisite_state',
      message = 'SKU governed operations need Canonical Amendment 02 storage.',
      hint = 'Apply 20260917024849_u2_sku_master_quote_fields_and_sets first.';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'skus' and column_name = 'pricing_portfolio') then
    raise exception using errcode = 'object_not_in_prerequisite_state',
      message = 'SKU governed operations need Canonical Amendment 03 storage.',
      hint = 'Apply 20260917024903_u2_sku_pricing_portfolio first.';
  end if;
end $$;

-- ─────────────────────────────────────────────────────── lifecycle: withdrawn
alter table public.skus drop constraint ck_sku_status;
alter table public.skus add constraint ck_sku_status
  check (status in ('proposed', 'active', 'discontinued', 'withdrawn'));

-- The S4-2 rules are kept verbatim; D4 adds exactly one transition, and it is terminal.
create or replace function app_private.guard_sku_permanence()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if old.plant_item_code is not null
     and new.plant_item_code is distinct from old.plant_item_code then
    raise exception 'plant_item_code % is permanent and can never be changed or released (CDM-09)', old.plant_item_code
      using errcode = '23514';
  end if;

  if new.status is distinct from old.status then
    if not ( (old.status = 'proposed'     and new.status = 'active')
          or (old.status = 'active'       and new.status = 'discontinued')
          or (old.status = 'discontinued' and new.status = 'active')
          -- Amendment 04 D4: a proposal that should never go live is withdrawn, not deleted (CDM-31)
          or (old.status = 'proposed'     and new.status = 'withdrawn') ) then
      raise exception 'illegal SKU transition % -> % (CDM-11)', old.status, new.status
        using errcode = '23514';
    end if;
  end if;

  return new;
end $fn$;

-- A withdrawn SKU can never be put on a Batch row. Additive: the existing row
-- triggers (trg_row_sku_family, trg_row_sku_immutable) are not changed.
create or replace function app_private.guard_row_sku_not_withdrawn()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if exists (select 1 from public.skus s where s.id = new.sku_id and s.status = 'withdrawn') then
    raise exception 'SKU % is withdrawn and cannot be used on a Batch row', new.sku_id using errcode = '23514';
  end if;
  return new;
end $fn$;
create trigger trg_row_sku_not_withdrawn
  before insert or update of sku_id on public.batch_rows
  for each row execute function app_private.guard_row_sku_not_withdrawn();
revoke all on function app_private.guard_row_sku_not_withdrawn() from public, anon, authenticated;

-- ──────────────────────────────────────────────── D8 compare-and-swap tokens
-- The token is the database's to maintain (guard_content_version, S6-4): a caller
-- can never set it, and every UPDATE advances it.
alter table public.sku_versions add column content_version integer not null default 1;
create trigger trg_sku_content_version
  before update on public.skus
  for each row execute function app_private.guard_content_version();
create trigger trg_skuv_content_version
  before update on public.sku_versions
  for each row execute function app_private.guard_content_version();

-- ────────────────────────────────────────────────────── D9 append-only history
create table public.sku_master_events (
  id           bigint      generated always as identity primary key,
  plant_id     bigint      not null,
  sku_id       bigint      not null,
  entity       text        not null,
  entity_id    bigint      not null,
  operation    text        not null,
  actor        bigint      not null,
  occurred_at  timestamptz not null default now(),
  reason       text        null,
  before_state jsonb       null,
  after_state  jsonb       null,
  constraint fk_sme_sku   foreign key (sku_id, plant_id) references public.skus(id, plant_id) on delete restrict,
  constraint fk_sme_actor foreign key (actor)            references public.app_users(id)      on delete restrict,
  constraint ck_sme_entity check (entity in ('sku', 'sku_version', 'sku_external_reference')),
  constraint ck_sme_operation check (operation in (
    'propose', 'create_version', 'update_draft_version', 'approve_version', 'assign_plant_item_code',
    'publish', 'discontinue', 'reactivate', 'withdraw', 'set_pricing_portfolio',
    'add_reference', 'withdraw_reference'))
);
create index ix_sme_sku   on public.sku_master_events (sku_id, plant_id, occurred_at);
create index ix_sme_actor on public.sku_master_events (actor);

revoke all on public.sku_master_events from anon, authenticated, service_role;
grant select on public.sku_master_events to authenticated;
alter table public.sku_master_events enable row level security;
alter table public.sku_master_events force  row level security;
create policy sku_master_events_select on public.sku_master_events for select to authenticated
  using ( (select app_private.has_plant_cap(plant_id, 'plant_access')) );
-- No INSERT, UPDATE or DELETE grant or policy for any application role: only the
-- governed operations below write here, and nothing rewrites history.

-- ─────────────────────────────────────────────── D10 close the direct write path
revoke insert, update on public.skus, public.sku_versions, public.sku_external_references from authenticated;
drop policy if exists skus_insert                     on public.skus;
drop policy if exists skus_update                     on public.skus;
drop policy if exists sku_versions_insert             on public.sku_versions;
drop policy if exists sku_versions_update             on public.sku_versions;
drop policy if exists sku_external_references_insert  on public.sku_external_references;
drop policy if exists sku_external_references_update  on public.sku_external_references;

-- The S4-3 SKU functions carry no compare-and-swap, no reason and no history, and
-- assign_plant_item_code also activates (contrary to D3). They stay defined for the
-- database's own fixtures but no caller may reach them.
revoke execute on function public.propose_sku(bigint,bigint,bigint,boolean,numeric,numeric,numeric,text,integer,numeric,numeric,numeric) from authenticated;
revoke execute on function public.approve_sku_version(bigint)         from authenticated;
revoke execute on function public.assign_plant_item_code(bigint,text) from authenticated;
revoke execute on function public.set_sku_status(bigint,text)         from authenticated;
revoke execute on function app_private.propose_sku(bigint,bigint,bigint,boolean,numeric,numeric,numeric,text,integer,numeric,numeric,numeric) from authenticated;
revoke execute on function app_private.approve_sku_version(bigint)         from authenticated;
revoke execute on function app_private.assign_plant_item_code(bigint,text) from authenticated;
revoke execute on function app_private.set_sku_status(bigint,text)         from authenticated;

-- ─────────────────────────────────────────────────────────── field classes (D2)
create or replace function app_private.sku_field_class(p_field text)
returns text language sql immutable set search_path = '' as $fn$
  select case
    when p_field in ('length_mm', 'width_mm', 'height_mm', 'construction_version_id', 'spec_bs', 'spec_bct',
                     'spec_ect', 'box_type', 'stated_item_gsm', 'stated_cs', 'stated_bs', 'stated_ect')
      then 'new_sku'
    when p_field in ('cobb_value', 'item_weight_kg', 'ups')
      then 'price_driving_version'
    when p_field in ('item_name', 'item_short_name', 'print_quality', 'print_technology', 'number_of_colours',
                     'colour_detail', 'customer_spec_version', 'item_family', 'item_group')
      then 'version'
    else null
  end;
$fn$;
revoke all on function app_private.sku_field_class(text) from public, anon;
grant execute on function app_private.sku_field_class(text) to authenticated;

-- Every key of a field set must be a known specification field.
create or replace function app_private.__sku_assert_fields(p_fields jsonb, p_extra text[] default '{}')
returns void language plpgsql immutable set search_path = '' as $fn$
declare k text;
begin
  if p_fields is null or pg_catalog.jsonb_typeof(p_fields) <> 'object' then
    raise exception 'fields must be a JSON object' using errcode = '22023';
  end if;
  for k in select pg_catalog.jsonb_object_keys(p_fields) loop
    if app_private.sku_field_class(k) is null and not (k = any(p_extra)) then
      raise exception 'unknown SKU specification field %', k using errcode = '22023';
    end if;
  end loop;
end $fn$;

-- Apply a field set onto a version row. A present key sets the value (JSON null
-- clears it); an absent key keeps the previous value. Blank stays distinct from 0.
create or replace function app_private.__sku_apply_fields(p_base public.sku_versions, p_fields jsonb)
returns public.sku_versions language plpgsql stable set search_path = '' as $fn$
declare v public.sku_versions := p_base;
begin
  if p_fields ? 'construction_version_id' then v.construction_version_id := (p_fields->>'construction_version_id')::bigint; end if;
  if p_fields ? 'length_mm'   then v.length_mm   := (p_fields->>'length_mm')::numeric;   end if;
  if p_fields ? 'width_mm'    then v.width_mm    := (p_fields->>'width_mm')::numeric;    end if;
  if p_fields ? 'height_mm'   then v.height_mm   := (p_fields->>'height_mm')::numeric;   end if;
  if p_fields ? 'box_type'    then v.box_type    := p_fields->>'box_type';               end if;
  if p_fields ? 'ups'         then v.ups         := (p_fields->>'ups')::integer;         end if;
  if p_fields ? 'spec_bs'     then v.spec_bs     := (p_fields->>'spec_bs')::numeric;     end if;
  if p_fields ? 'spec_bct'    then v.spec_bct    := (p_fields->>'spec_bct')::numeric;    end if;
  if p_fields ? 'spec_ect'    then v.spec_ect    := (p_fields->>'spec_ect')::numeric;    end if;
  if p_fields ? 'item_name'             then v.item_name             := p_fields->>'item_name';             end if;
  if p_fields ? 'item_short_name'       then v.item_short_name       := p_fields->>'item_short_name';       end if;
  if p_fields ? 'item_family'           then v.item_family           := p_fields->>'item_family';           end if;
  if p_fields ? 'item_group'            then v.item_group            := p_fields->>'item_group';            end if;
  if p_fields ? 'print_quality'         then v.print_quality         := p_fields->>'print_quality';         end if;
  if p_fields ? 'print_technology'      then v.print_technology      := p_fields->>'print_technology';      end if;
  if p_fields ? 'number_of_colours'     then v.number_of_colours     := (p_fields->>'number_of_colours')::integer; end if;
  if p_fields ? 'colour_detail'         then v.colour_detail         := p_fields->>'colour_detail';         end if;
  if p_fields ? 'cobb_value'            then v.cobb_value            := p_fields->>'cobb_value';            end if;
  if p_fields ? 'stated_item_gsm'       then v.stated_item_gsm       := p_fields->>'stated_item_gsm';       end if;
  if p_fields ? 'item_weight_kg'        then v.item_weight_kg        := (p_fields->>'item_weight_kg')::numeric; end if;
  if p_fields ? 'stated_cs'             then v.stated_cs             := p_fields->>'stated_cs';             end if;
  if p_fields ? 'stated_bs'             then v.stated_bs             := p_fields->>'stated_bs';             end if;
  if p_fields ? 'stated_ect'            then v.stated_ect            := p_fields->>'stated_ect';            end if;
  if p_fields ? 'customer_spec_version' then v.customer_spec_version := p_fields->>'customer_spec_version'; end if;
  return v;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'a SKU specification value has the wrong type' using errcode = '22023';
end $fn$;

-- The classes of fields whose value differs between two versions.
create or replace function app_private.__sku_changed_classes(p_old public.sku_versions, p_new public.sku_versions)
returns text[] language sql immutable set search_path = '' as $fn$
  select coalesce(pg_catalog.array_agg(distinct app_private.sku_field_class(o.key)), '{}')
    from pg_catalog.jsonb_each(pg_catalog.to_jsonb(p_old)) o
    join pg_catalog.jsonb_each(pg_catalog.to_jsonb(p_new)) n on n.key = o.key
   where app_private.sku_field_class(o.key) is not null
     and o.value is distinct from n.value;
$fn$;

-- ────────────────────────────────────────────────────────── shared machinery
create or replace function app_private.__sku_me()
returns bigint language plpgsql stable set search_path = '' as $fn$
declare v_me bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  return v_me;
end $fn$;

-- Lock the SKU, then check the caller's token against it.
create or replace function app_private.__sku_lock(p_sku bigint, p_expected integer)
returns public.skus language plpgsql set search_path = '' as $fn$
declare v public.skus;
begin
  if p_expected is null then
    raise exception 'the SKU content version you read must be supplied' using errcode = '22023';
  end if;
  select * into v from public.skus where id = p_sku for update;
  if not found then
    raise exception 'SKU not found' using errcode = 'P0002';
  end if;
  if v.content_version <> p_expected then
    raise exception 'the SKU changed since you read it (expected content version %)', p_expected using errcode = 'PT409';
  end if;
  return v;
end $fn$;

create or replace function app_private.__sku_require_manage(p_plant bigint)
returns void language plpgsql stable set search_path = '' as $fn$
begin
  if not app_private.has_plant_cap(p_plant, 'manage_sku_master') then
    raise exception 'manage_sku_master is required at that plant' using errcode = '42501';
  end if;
end $fn$;

-- Advance the SKU's token: every change anywhere in the aggregate is a change to the SKU.
create or replace function app_private.__sku_touch(p_sku bigint)
returns void language sql set search_path = '' as $fn$
  update public.skus set plant_id = plant_id where id = p_sku;
$fn$;

create or replace function app_private.__sku_event(
  p_plant bigint, p_sku bigint, p_entity text, p_entity_id bigint, p_operation text, p_actor bigint,
  p_reason text, p_before jsonb, p_after jsonb)
returns void language sql set search_path = '' as $fn$
  insert into public.sku_master_events (plant_id, sku_id, entity, entity_id, operation, actor, reason, before_state, after_state)
  values (p_plant, p_sku, p_entity, p_entity_id, p_operation, p_actor,
          nullif(pg_catalog.btrim(p_reason), ''), p_before, p_after);
$fn$;

do $$
declare f text;
begin
  foreach f in array array[
    'app_private.__sku_assert_fields(jsonb,text[])',
    'app_private.__sku_apply_fields(public.sku_versions,jsonb)',
    'app_private.__sku_changed_classes(public.sku_versions,public.sku_versions)',
    'app_private.__sku_me()', 'app_private.__sku_lock(bigint,integer)',
    'app_private.__sku_require_manage(bigint)', 'app_private.__sku_touch(bigint)',
    'app_private.__sku_event(bigint,bigint,text,bigint,text,bigint,text,jsonb,jsonb)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- ─────────────────────────────────────────────────────── governed operations
-- Every operation: SECURITY DEFINER in app_private with an empty search_path, the
-- caller identified from the session (never a parameter), capability checked at the
-- SKU's OWN plant, the token checked (PT409), one history event written, and a public
-- SECURITY INVOKER wrapper that decides nothing.

-- D1 / CDM-11: a Maker or a manage_sku_master holder proposes a SKU with version 1.
create or replace function app_private.sku_propose(
  p_plant bigint, p_party bigint, p_pricing_portfolio text, p_is_price_driving boolean, p_fields jsonb)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus; v_ver public.sku_versions;
begin
  v_me := app_private.__sku_me();
  if not ( app_private.has_plant_cap(p_plant, 'manage_sku_master')
        or app_private.has_plant_cap(p_plant, 'make_quote') ) then
    raise exception 'manage_sku_master or make_quote is required at that plant' using errcode = '42501';
  end if;
  if not exists (select 1 from public.parties where id = p_party) then
    raise exception 'unknown Customer' using errcode = 'P0002';
  end if;
  if p_pricing_portfolio is null or p_pricing_portfolio not in ('Transactional', 'Strategic') then
    raise exception 'a pricing portfolio (Transactional or Strategic) is required (CDM-45)' using errcode = '22023';
  end if;
  if p_is_price_driving is null then
    raise exception 'whether the version is price-driving must be stated' using errcode = '22023';
  end if;
  perform app_private.__sku_assert_fields(p_fields);
  if not (p_fields ? 'construction_version_id')
     or not exists (select 1 from public.construction_versions where id = (p_fields->>'construction_version_id')::bigint) then
    raise exception 'a SKU spec version requires a Construction Version (CDM-13)' using errcode = '22023';
  end if;

  insert into public.skus (plant_id, party_id, status, pricing_portfolio, created_by)
  values (p_plant, p_party, 'proposed', p_pricing_portfolio, v_me)
  returning * into v_sku;

  v_ver.box_type := 'RSC';
  v_ver.ups := 1;
  v_ver := app_private.__sku_apply_fields(v_ver, p_fields);
  insert into public.sku_versions (
    sku_id, plant_id, version_no, construction_version_id, is_price_driving, length_mm, width_mm, height_mm,
    box_type, ups, spec_bs, spec_bct, spec_ect, item_name, item_short_name, item_family, item_group, print_quality,
    print_technology, number_of_colours, colour_detail, cobb_value, stated_item_gsm, item_weight_kg, stated_cs,
    stated_bs, stated_ect, customer_spec_version, created_by)
  values (
    v_sku.id, p_plant, 1, v_ver.construction_version_id, p_is_price_driving, v_ver.length_mm, v_ver.width_mm,
    v_ver.height_mm, coalesce(v_ver.box_type, 'RSC'), coalesce(v_ver.ups, 1), v_ver.spec_bs, v_ver.spec_bct,
    v_ver.spec_ect, v_ver.item_name, v_ver.item_short_name, v_ver.item_family, v_ver.item_group, v_ver.print_quality,
    v_ver.print_technology, v_ver.number_of_colours, v_ver.colour_detail, v_ver.cobb_value, v_ver.stated_item_gsm,
    v_ver.item_weight_kg, v_ver.stated_cs, v_ver.stated_bs, v_ver.stated_ect, v_ver.customer_spec_version, v_me)
  returning * into v_ver;

  perform app_private.__sku_event(p_plant, v_sku.id, 'sku', v_sku.id, 'propose', v_me, null, null,
    pg_catalog.jsonb_build_object('sku', pg_catalog.to_jsonb(v_sku), 'version', pg_catalog.to_jsonb(v_ver)));
  return v_sku.id;
end $fn$;

-- D2: a new version. Fields that force a NEW SKU are refused with PT423; a change to a
-- price-driving field must be declared price-driving. One open draft at a time.
create or replace function app_private.sku_create_version(
  p_sku bigint, p_expected_content_version integer, p_is_price_driving boolean, p_fields jsonb)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus; v_prev public.sku_versions; v_new public.sku_versions; v_classes text[];
begin
  v_me := app_private.__sku_me();
  v_sku := app_private.__sku_lock(p_sku, p_expected_content_version);
  if not ( app_private.has_plant_cap(v_sku.plant_id, 'manage_sku_master')
        or app_private.has_plant_cap(v_sku.plant_id, 'make_quote') ) then
    raise exception 'manage_sku_master or make_quote is required at that plant' using errcode = '42501';
  end if;
  if v_sku.status in ('withdrawn', 'discontinued') then
    raise exception 'a % SKU takes no new version', v_sku.status using errcode = '22023';
  end if;
  if p_is_price_driving is null then
    raise exception 'whether the version is price-driving must be stated' using errcode = '22023';
  end if;
  perform app_private.__sku_assert_fields(p_fields);
  if exists (select 1 from public.sku_versions where sku_id = p_sku and approved_at is null) then
    raise exception 'this SKU already has an open draft version - approve or edit it first' using errcode = '22023';
  end if;

  select * into v_prev from public.sku_versions where sku_id = p_sku order by version_no desc limit 1;
  v_new := app_private.__sku_apply_fields(v_prev, p_fields);
  v_classes := app_private.__sku_changed_classes(v_prev, v_new);
  if 'new_sku' = any(v_classes) then
    raise exception 'a dimension, Construction, box type or strength change is a new SKU (CDM-10)' using errcode = 'PT423';
  end if;
  if pg_catalog.cardinality(v_classes) = 0 then
    raise exception 'a new version must change at least one field' using errcode = '22023';
  end if;
  if 'price_driving_version' = any(v_classes) and not p_is_price_driving then
    raise exception 'a Cobb value, item weight or ups change is a price-driving version' using errcode = '22023';
  end if;

  insert into public.sku_versions (
    sku_id, plant_id, version_no, construction_version_id, is_price_driving, length_mm, width_mm, height_mm,
    box_type, ups, spec_bs, spec_bct, spec_ect, item_name, item_short_name, item_family, item_group, print_quality,
    print_technology, number_of_colours, colour_detail, cobb_value, stated_item_gsm, item_weight_kg, stated_cs,
    stated_bs, stated_ect, customer_spec_version, created_by)
  values (
    p_sku, v_sku.plant_id, v_prev.version_no + 1, v_new.construction_version_id, p_is_price_driving, v_new.length_mm,
    v_new.width_mm, v_new.height_mm, v_new.box_type, v_new.ups, v_new.spec_bs, v_new.spec_bct, v_new.spec_ect,
    v_new.item_name, v_new.item_short_name, v_new.item_family, v_new.item_group, v_new.print_quality,
    v_new.print_technology, v_new.number_of_colours, v_new.colour_detail, v_new.cobb_value, v_new.stated_item_gsm,
    v_new.item_weight_kg, v_new.stated_cs, v_new.stated_bs, v_new.stated_ect, v_new.customer_spec_version, v_me)
  returning * into v_new;

  perform app_private.__sku_touch(p_sku);
  perform app_private.__sku_event(v_sku.plant_id, p_sku, 'sku_version', v_new.id, 'create_version', v_me, null,
    pg_catalog.to_jsonb(v_prev), pg_catalog.to_jsonb(v_new));
  return v_new.id;
end $fn$;

-- D2: a draft is edited in place until approved, by its proposer or a manage_sku_master
-- holder. Version 1 of a SKU that has never been approved may change any field; a later
-- draft keeps the new-SKU fields of the version before it.
create or replace function app_private.sku_update_draft_version(
  p_version bigint, p_expected_content_version integer, p_is_price_driving boolean, p_fields jsonb)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_ver public.sku_versions; v_prev public.sku_versions; v_new public.sku_versions;
        v_classes text[]; v_sku public.skus;
begin
  v_me := app_private.__sku_me();
  if p_expected_content_version is null then
    raise exception 'the version content version you read must be supplied' using errcode = '22023';
  end if;
  select * into v_ver from public.sku_versions where id = p_version for update;
  if not found then
    raise exception 'SKU version not found' using errcode = 'P0002';
  end if;
  select * into v_sku from public.skus where id = v_ver.sku_id for update;
  if v_ver.content_version <> p_expected_content_version then
    raise exception 'the version changed since you read it (expected content version %)', p_expected_content_version
      using errcode = 'PT409';
  end if;
  if not ( app_private.has_plant_cap(v_ver.plant_id, 'manage_sku_master')
        or (v_ver.created_by = v_me and app_private.has_plant_cap(v_ver.plant_id, 'make_quote')) ) then
    raise exception 'only the proposer or a manage_sku_master holder may edit this draft' using errcode = '42501';
  end if;
  if v_ver.approved_at is not null then
    raise exception 'an approved version is immutable - a change is a new version (CDM-10)' using errcode = '22023';
  end if;
  if v_sku.status = 'withdrawn' then
    raise exception 'a withdrawn SKU takes no edit' using errcode = '22023';
  end if;
  perform app_private.__sku_assert_fields(p_fields);

  v_new := app_private.__sku_apply_fields(v_ver, p_fields);
  if v_ver.version_no > 1 then
    select * into v_prev from public.sku_versions
     where sku_id = v_ver.sku_id and version_no = v_ver.version_no - 1;
    v_classes := app_private.__sku_changed_classes(v_prev, v_new);
    if 'new_sku' = any(v_classes) then
      raise exception 'a dimension, Construction, box type or strength change is a new SKU (CDM-10)' using errcode = 'PT423';
    end if;
    if 'price_driving_version' = any(v_classes) and not coalesce(p_is_price_driving, v_ver.is_price_driving) then
      raise exception 'a Cobb value, item weight or ups change is a price-driving version' using errcode = '22023';
    end if;
  end if;
  if (p_fields ? 'construction_version_id')
     and not exists (select 1 from public.construction_versions where id = v_new.construction_version_id) then
    raise exception 'a SKU spec version requires a Construction Version (CDM-13)' using errcode = '22023';
  end if;

  update public.sku_versions set
    construction_version_id = v_new.construction_version_id,
    is_price_driving = coalesce(p_is_price_driving, v_ver.is_price_driving),
    length_mm = v_new.length_mm, width_mm = v_new.width_mm, height_mm = v_new.height_mm,
    box_type = v_new.box_type, ups = v_new.ups, spec_bs = v_new.spec_bs, spec_bct = v_new.spec_bct,
    spec_ect = v_new.spec_ect, item_name = v_new.item_name, item_short_name = v_new.item_short_name,
    item_family = v_new.item_family, item_group = v_new.item_group, print_quality = v_new.print_quality,
    print_technology = v_new.print_technology, number_of_colours = v_new.number_of_colours,
    colour_detail = v_new.colour_detail, cobb_value = v_new.cobb_value, stated_item_gsm = v_new.stated_item_gsm,
    item_weight_kg = v_new.item_weight_kg, stated_cs = v_new.stated_cs, stated_bs = v_new.stated_bs,
    stated_ect = v_new.stated_ect, customer_spec_version = v_new.customer_spec_version
  where id = p_version
  returning * into v_new;

  perform app_private.__sku_touch(v_ver.sku_id);
  perform app_private.__sku_event(v_ver.plant_id, v_ver.sku_id, 'sku_version', p_version, 'update_draft_version',
    v_me, null, pg_catalog.to_jsonb(v_ver), pg_catalog.to_jsonb(v_new));
end $fn$;

-- D1: approval by a manage_sku_master holder; the proposer MAY approve their own
-- version (Product Owner, 2026-09-16 - to be revisited once the workflow is observed).
create or replace function app_private.sku_approve_version(p_version bigint, p_expected_content_version integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_ver public.sku_versions; v_new public.sku_versions;
begin
  v_me := app_private.__sku_me();
  if p_expected_content_version is null then
    raise exception 'the version content version you read must be supplied' using errcode = '22023';
  end if;
  select * into v_ver from public.sku_versions where id = p_version for update;
  if not found then
    raise exception 'SKU version not found' using errcode = 'P0002';
  end if;
  perform 1 from public.skus where id = v_ver.sku_id for update;
  if v_ver.content_version <> p_expected_content_version then
    raise exception 'the version changed since you read it (expected content version %)', p_expected_content_version
      using errcode = 'PT409';
  end if;
  perform app_private.__sku_require_manage(v_ver.plant_id);
  if v_ver.approved_at is not null then
    raise exception 'SKU version % is already approved', p_version using errcode = '22023';
  end if;
  if exists (select 1 from public.skus where id = v_ver.sku_id and status = 'withdrawn') then
    raise exception 'a withdrawn SKU takes no approval' using errcode = '22023';
  end if;

  update public.sku_versions set approved_by = v_me, approved_at = pg_catalog.now()
   where id = p_version returning * into v_new;
  perform app_private.__sku_touch(v_ver.sku_id);
  perform app_private.__sku_event(v_ver.plant_id, v_ver.sku_id, 'sku_version', p_version, 'approve_version', v_me,
    null, pg_catalog.to_jsonb(v_ver), pg_catalog.to_jsonb(v_new));
end $fn$;

-- D3 / CDM-09: assign the permanent code. It does NOT publish. A code already held by
-- another SKU at the plant, or recorded there as a retired (legacy) code, is refused.
create or replace function app_private.sku_assign_plant_item_code(
  p_sku bigint, p_expected_content_version integer, p_code text)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus; v_code text := pg_catalog.btrim(p_code);
begin
  v_me := app_private.__sku_me();
  v_sku := app_private.__sku_lock(p_sku, p_expected_content_version);
  perform app_private.__sku_require_manage(v_sku.plant_id);
  if coalesce(v_code, '') = '' or pg_catalog.length(v_code) > 60 then
    raise exception 'a Plant Item Code of 1 to 60 characters is required' using errcode = '22023';
  end if;
  if v_sku.plant_item_code is not null then
    raise exception 'this SKU already carries its permanent Plant Item Code (CDM-09)' using errcode = '22023';
  end if;
  if v_sku.status <> 'proposed' then
    raise exception 'only a proposed SKU is assigned its code' using errcode = '22023';
  end if;
  if exists (select 1 from public.skus where plant_id = v_sku.plant_id and plant_item_code = v_code)
     or exists (select 1 from public.sku_external_references
                 where plant_id = v_sku.plant_id and reference_kind = 'legacy_plant_item_code'
                   and reference_value = v_code) then
    raise exception 'that Plant Item Code is already used at this plant and is never reissued' using errcode = '22023';
  end if;

  update public.skus set plant_item_code = v_code where id = p_sku;
  perform app_private.__sku_event(v_sku.plant_id, p_sku, 'sku', p_sku, 'assign_plant_item_code', v_me, null,
    pg_catalog.jsonb_build_object('plant_item_code', null), pg_catalog.jsonb_build_object('plant_item_code', v_code));
end $fn$;

-- D3: publish = Proposed -> Active, only with a code, an approved version and a portfolio.
create or replace function app_private.sku_publish(p_sku bigint, p_expected_content_version integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus;
begin
  v_me := app_private.__sku_me();
  v_sku := app_private.__sku_lock(p_sku, p_expected_content_version);
  perform app_private.__sku_require_manage(v_sku.plant_id);
  if v_sku.status <> 'proposed' then
    raise exception 'only a proposed SKU is published' using errcode = '22023';
  end if;
  if v_sku.plant_item_code is null then
    raise exception 'assign the Plant Item Code before publishing' using errcode = '22023';
  end if;
  if not exists (select 1 from public.sku_versions where sku_id = p_sku and approved_at is not null) then
    raise exception 'approve a version before publishing' using errcode = '22023';
  end if;
  if v_sku.pricing_portfolio is null then
    raise exception 'record a pricing portfolio before publishing (CDM-45)' using errcode = '22023';
  end if;

  update public.skus set status = 'active' where id = p_sku;
  perform app_private.__sku_event(v_sku.plant_id, p_sku, 'sku', p_sku, 'publish', v_me, null,
    pg_catalog.jsonb_build_object('status', v_sku.status), pg_catalog.jsonb_build_object('status', 'active'));
end $fn$;

-- D4 / CDM-11: discontinue with a reason and an optional replacement at the SAME plant
-- and Customer. The link is recorded; nothing is ever substituted.
create or replace function app_private.sku_discontinue(
  p_sku bigint, p_expected_content_version integer, p_reason text, p_replacement_sku bigint default null)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus; v_rep public.skus;
begin
  v_me := app_private.__sku_me();
  v_sku := app_private.__sku_lock(p_sku, p_expected_content_version);
  perform app_private.__sku_require_manage(v_sku.plant_id);
  if v_sku.status <> 'active' then
    raise exception 'only an active SKU is discontinued' using errcode = '22023';
  end if;
  if coalesce(pg_catalog.btrim(p_reason), '') = '' then
    raise exception 'a reason is required to discontinue a SKU' using errcode = '22023';
  end if;
  if p_replacement_sku is not null then
    select * into v_rep from public.skus where id = p_replacement_sku;
    if not found then
      raise exception 'replacement SKU not found' using errcode = 'P0002';
    end if;
    if v_rep.id = v_sku.id or v_rep.plant_id <> v_sku.plant_id or v_rep.party_id <> v_sku.party_id
       or v_rep.status <> 'active' then
      raise exception 'a replacement is a different, active SKU of the same plant and Customer' using errcode = '22023';
    end if;
  end if;

  update public.skus set status = 'discontinued', replacement_sku_id = p_replacement_sku where id = p_sku;
  perform app_private.__sku_event(v_sku.plant_id, p_sku, 'sku', p_sku, 'discontinue', v_me, p_reason,
    pg_catalog.jsonb_build_object('status', v_sku.status, 'replacement_sku_id', v_sku.replacement_sku_id),
    pg_catalog.jsonb_build_object('status', 'discontinued', 'replacement_sku_id', p_replacement_sku));
end $fn$;

-- D4: reactivation keeps identity and clears the replacement link; the history keeps it.
create or replace function app_private.sku_reactivate(
  p_sku bigint, p_expected_content_version integer, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus;
begin
  v_me := app_private.__sku_me();
  v_sku := app_private.__sku_lock(p_sku, p_expected_content_version);
  perform app_private.__sku_require_manage(v_sku.plant_id);
  if v_sku.status <> 'discontinued' then
    raise exception 'only a discontinued SKU is reactivated' using errcode = '22023';
  end if;

  update public.skus set status = 'active', replacement_sku_id = null where id = p_sku;
  perform app_private.__sku_event(v_sku.plant_id, p_sku, 'sku', p_sku, 'reactivate', v_me, p_reason,
    pg_catalog.jsonb_build_object('status', v_sku.status, 'replacement_sku_id', v_sku.replacement_sku_id),
    pg_catalog.jsonb_build_object('status', 'active', 'replacement_sku_id', null));
end $fn$;

-- D4 / CDM-31: withdraw a proposal, by its proposer or a manage_sku_master holder. A
-- proposal already on a Batch row is refused rather than orphaning that row.
create or replace function app_private.sku_withdraw(
  p_sku bigint, p_expected_content_version integer, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus;
begin
  v_me := app_private.__sku_me();
  v_sku := app_private.__sku_lock(p_sku, p_expected_content_version);
  if not ( app_private.has_plant_cap(v_sku.plant_id, 'manage_sku_master')
        or (v_sku.created_by = v_me and app_private.has_plant_cap(v_sku.plant_id, 'make_quote')) ) then
    raise exception 'only the proposer or a manage_sku_master holder may withdraw this proposal' using errcode = '42501';
  end if;
  if v_sku.status <> 'proposed' then
    raise exception 'only a proposed SKU is withdrawn' using errcode = '22023';
  end if;
  if exists (select 1 from public.batch_rows where sku_id = p_sku) then
    raise exception 'this proposal is already used on a Batch row and cannot be withdrawn' using errcode = '22023';
  end if;

  update public.skus set status = 'withdrawn' where id = p_sku;
  perform app_private.__sku_event(v_sku.plant_id, p_sku, 'sku', p_sku, 'withdraw', v_me, p_reason,
    pg_catalog.jsonb_build_object('status', v_sku.status), pg_catalog.jsonb_build_object('status', 'withdrawn'));
end $fn$;

-- CDM-45 C-03: the portfolio changes in place, by a manage_sku_master holder.
create or replace function app_private.sku_set_pricing_portfolio(
  p_sku bigint, p_expected_content_version integer, p_pricing_portfolio text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus;
begin
  v_me := app_private.__sku_me();
  v_sku := app_private.__sku_lock(p_sku, p_expected_content_version);
  perform app_private.__sku_require_manage(v_sku.plant_id);
  if p_pricing_portfolio is null or p_pricing_portfolio not in ('Transactional', 'Strategic') then
    raise exception 'the pricing portfolio is Transactional or Strategic (CDM-45)' using errcode = '22023';
  end if;
  if v_sku.status = 'withdrawn' then
    raise exception 'a withdrawn SKU is not reclassified' using errcode = '22023';
  end if;
  if v_sku.pricing_portfolio = p_pricing_portfolio then
    raise exception 'the SKU is already %', p_pricing_portfolio using errcode = '22023';
  end if;

  update public.skus set pricing_portfolio = p_pricing_portfolio where id = p_sku;
  perform app_private.__sku_event(v_sku.plant_id, p_sku, 'sku', p_sku, 'set_pricing_portfolio', v_me, p_reason,
    pg_catalog.jsonb_build_object('pricing_portfolio', v_sku.pricing_portfolio),
    pg_catalog.jsonb_build_object('pricing_portfolio', p_pricing_portfolio));
end $fn$;

-- D5: references are added and withdrawn, never edited in place.
create or replace function app_private.sku_add_reference(
  p_sku bigint, p_expected_content_version integer, p_kind text, p_value text)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus; v_value text := pg_catalog.btrim(p_value); v_ref public.sku_external_references;
begin
  v_me := app_private.__sku_me();
  v_sku := app_private.__sku_lock(p_sku, p_expected_content_version);
  perform app_private.__sku_require_manage(v_sku.plant_id);
  if p_kind is null or p_kind not in ('customer_item_code', 'softcomp_code', 'legacy_plant_item_code', 'alias', 'other') then
    raise exception 'unknown reference kind' using errcode = '22023';
  end if;
  if coalesce(v_value, '') = '' or pg_catalog.length(v_value) > 120 then
    raise exception 'a reference value of 1 to 120 characters is required' using errcode = '22023';
  end if;
  if v_sku.status = 'withdrawn' then
    raise exception 'a withdrawn SKU takes no reference' using errcode = '22023';
  end if;
  if exists (select 1 from public.sku_external_references
              where sku_id = p_sku and reference_kind = p_kind and reference_value = v_value and status = 'active') then
    raise exception 'that reference is already recorded on this SKU' using errcode = '22023';
  end if;

  insert into public.sku_external_references (sku_id, plant_id, reference_kind, reference_value, created_by)
  values (p_sku, v_sku.plant_id, p_kind, v_value, v_me)
  returning * into v_ref;
  perform app_private.__sku_touch(p_sku);
  perform app_private.__sku_event(v_sku.plant_id, p_sku, 'sku_external_reference', v_ref.id, 'add_reference', v_me,
    null, null, pg_catalog.to_jsonb(v_ref));
  return v_ref.id;
end $fn$;

create or replace function app_private.sku_withdraw_reference(
  p_reference bigint, p_expected_content_version integer, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_ref public.sku_external_references; v_sku public.skus;
begin
  v_me := app_private.__sku_me();
  select * into v_ref from public.sku_external_references where id = p_reference;
  if not found then
    raise exception 'reference not found' using errcode = 'P0002';
  end if;
  v_sku := app_private.__sku_lock(v_ref.sku_id, p_expected_content_version);
  perform app_private.__sku_require_manage(v_sku.plant_id);
  if v_ref.status <> 'active' then
    raise exception 'that reference is already withdrawn' using errcode = '22023';
  end if;

  update public.sku_external_references set status = 'withdrawn' where id = p_reference;
  perform app_private.__sku_touch(v_ref.sku_id);
  perform app_private.__sku_event(v_sku.plant_id, v_ref.sku_id, 'sku_external_reference', p_reference,
    'withdraw_reference', v_me, p_reason, pg_catalog.to_jsonb(v_ref),
    pg_catalog.to_jsonb(v_ref) || pg_catalog.jsonb_build_object('status', 'withdrawn'));
end $fn$;

-- ──────────────────────────────────────────────────── invoker wrappers + grants
create or replace function public.sku_propose(
  p_plant bigint, p_party bigint, p_pricing_portfolio text, p_is_price_driving boolean, p_fields jsonb)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.sku_propose(p_plant, p_party, p_pricing_portfolio, p_is_price_driving, p_fields);
$fn$;
create or replace function public.sku_create_version(
  p_sku bigint, p_expected_content_version integer, p_is_price_driving boolean, p_fields jsonb)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.sku_create_version(p_sku, p_expected_content_version, p_is_price_driving, p_fields);
$fn$;
create or replace function public.sku_update_draft_version(
  p_version bigint, p_expected_content_version integer, p_is_price_driving boolean, p_fields jsonb)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_update_draft_version(p_version, p_expected_content_version, p_is_price_driving, p_fields);
$fn$;
create or replace function public.sku_approve_version(p_version bigint, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_approve_version(p_version, p_expected_content_version);
$fn$;
create or replace function public.sku_assign_plant_item_code(p_sku bigint, p_expected_content_version integer, p_code text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_assign_plant_item_code(p_sku, p_expected_content_version, p_code);
$fn$;
create or replace function public.sku_publish(p_sku bigint, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_publish(p_sku, p_expected_content_version);
$fn$;
create or replace function public.sku_discontinue(
  p_sku bigint, p_expected_content_version integer, p_reason text, p_replacement_sku bigint default null)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_discontinue(p_sku, p_expected_content_version, p_reason, p_replacement_sku);
$fn$;
create or replace function public.sku_reactivate(p_sku bigint, p_expected_content_version integer, p_reason text default null)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_reactivate(p_sku, p_expected_content_version, p_reason);
$fn$;
create or replace function public.sku_withdraw(p_sku bigint, p_expected_content_version integer, p_reason text default null)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_withdraw(p_sku, p_expected_content_version, p_reason);
$fn$;
create or replace function public.sku_set_pricing_portfolio(
  p_sku bigint, p_expected_content_version integer, p_pricing_portfolio text, p_reason text default null)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_set_pricing_portfolio(p_sku, p_expected_content_version, p_pricing_portfolio, p_reason);
$fn$;
create or replace function public.sku_add_reference(p_sku bigint, p_expected_content_version integer, p_kind text, p_value text)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.sku_add_reference(p_sku, p_expected_content_version, p_kind, p_value);
$fn$;
create or replace function public.sku_withdraw_reference(
  p_reference bigint, p_expected_content_version integer, p_reason text default null)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_withdraw_reference(p_reference, p_expected_content_version, p_reason);
$fn$;

-- The working convention (S4-3, Family B): the private definer AND its invoker wrapper
-- are executable by authenticated, because an invoker wrapper runs with the CALLER's
-- privileges. Revoking the private one makes the wrapper fail for everyone.
do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid) as args
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app_private', 'public')
       and p.proname in ('sku_propose', 'sku_create_version', 'sku_update_draft_version', 'sku_approve_version',
                         'sku_assign_plant_item_code', 'sku_publish', 'sku_discontinue', 'sku_reactivate',
                         'sku_withdraw', 'sku_set_pricing_portfolio', 'sku_add_reference', 'sku_withdraw_reference')
  loop
    execute format('revoke all on function %I.%I(%s) from public', r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon', r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;

-- ─────────────────────────────────────── repoint tests.sku_master PS-8 (S4-2 suite)
-- PS-8 asserted a Maker MAY insert a Proposed SKU row directly. D10 closes that path on
-- purpose; proposal is now the governed operation. The assertion is inverted, not deleted.
do $rw$
declare v_def text; v_oid oid;
  v_old text := $q$return next ok(v_ok, 'PS-8 a Maker MAY propose a SKU at their own plant (CDM-11/DM-132)');$q$;
  v_new text := $q$return next ok(not v_ok, 'PS-8 a Maker may NOT write a SKU row directly - proposal is the governed sku_propose operation (Amendment 04 D10)');$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'tests' and p.proname = 'sku_master';
  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def) = 0 then
    raise exception 'the tests.sku_master PS-8 anchor was not found' using errcode = '55000';
  end if;
  execute replace(v_def, v_old, v_new);
end $rw$;

-- ───────────────────────────────── repoint tests.product_workflow (S4-3 suite)
-- Its SKU section called the S4-3 functions callers can no longer reach, and asserted
-- that code assignment activates. It now drives the governed operations and asserts
-- the ruled behaviour. Every Construction assertion is byte-for-byte unchanged.
create or replace function tests.product_workflow()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  fns text[] := array['propose_construction','approve_construction_version',
                      'publish_construction','merge_construction',
                      'adopt_construction_for_plant','propose_sku',
                      'approve_sku_version','assign_plant_item_code','set_sku_status'];
  f text; v_ok boolean;
  v_mauth uuid; v_mclaims text; v_maker bigint; v_memail text := 'p2-s4w-m@example.invalid';
  v_nauth uuid; v_nclaims text; v_npd   bigint; v_nemail text := 'p2-s4w-n@example.invalid';
  v_owner bigint; v_nag bigint; v_pun bigint; v_party bigint;
  v_k1 bigint; v_k2 bigint; v_kdup bigint;
  v_v1 bigint; v_v2 bigint; v_vdup bigint;
  v_code1 text; v_code2 text; v_adopt bigint;
  v_sku bigint; v_sver bigint;
begin
  select id into v_owner from public.app_users order by id limit 1;
  select id into v_nag   from public.plants where plant_code = 'NAG';
  select id into v_pun   from public.plants where plant_code = 'PUN';

  -- ------------------------------------------------ anon reaches none of them
  foreach f in array fns loop
    return next ok(
      not exists (select 1 from pg_catalog.pg_proc p
                    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = f
                     and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')),
      format('PW-1 anon cannot execute public.%s', f));
    return next ok(
      exists (select 1 from pg_catalog.pg_proc p
                join pg_catalog.pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app_private' and p.proname = f and p.prosecdef),
      format('PW-1a the privilege for %s lives in app_private as SECURITY DEFINER', f));
    return next ok(
      exists (select 1 from pg_catalog.pg_proc p
                join pg_catalog.pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = f and not p.prosecdef),
      format('PW-1b and public.%s is a SECURITY INVOKER shim that decides nothing', f));
  end loop;

  -- ------------------------------------------------------------- identities
  v_mauth   := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_memail, '__p2_s4w_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_maker := public.bootstrap_app_user();
  reset role;

  v_nauth   := tests.__fixture_auth_uid();
  v_nclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_nauth, v_nemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_nemail, '__p2_s4w_npd', false);
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_npd := public.bootstrap_app_user();
  reset role;

  -- Maker: make_quote + plant_access at NAG only. No group capability at all.
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');

  -- NPD: the master capabilities, group-wide library plus NAG plant authority
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_npd, c.id, v_owner from public.capabilities c
   where c.capability_key in ('read_construction_library','manage_construction_library');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_npd, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','manage_sku_master','adopt_construction_for_plant');

  insert into public.parties (display_name, created_by) values ('__p2 pw customer', v_owner)
    returning id into v_party;

  -- ------------------------------------------------- proposal, by the Maker
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_k1 := public.propose_construction('__p2 pw con one', 3, 'B', null,
                                      'K', 'S', 'S', null, 'K',
                                      150, 120, 120, null, 150, 540);
  reset role;
  return next ok(v_k1 is not null, 'PW-2 a Maker may propose a Construction from Batch Entry (CDM-12/DM-144)');
  return next is((select status from public.constructions where id = v_k1), 'proposed',
                 'PW-2a it is born proposed');
  return next ok((select construction_code is null from public.constructions where id = v_k1),
                 'PW-2b and carries NO permanent code - publication allocates that');
  return next is((select created_by from public.constructions where id = v_k1), v_maker,
                 'PW-2c attribution is the caller, taken from current_app_user() (CDM-34)');
  select id into v_v1 from public.construction_versions where construction_id = v_k1;
  return next ok(v_v1 is not null, 'PW-2d version 1 is written in the same operation');

  -- ------------------------------------------- the Maker may do nothing more
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.approve_construction_version(v_v1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-3 a Maker may NOT approve a Construction Version');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.publish_construction(v_k1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-4 nor publish one - publication is a library capability (CDM-12)');

  -- ------------------------------------------- review and publication, by NPD
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.approve_construction_version(v_v1);
  reset role;
  return next is((select approved_by from public.construction_versions where id = v_v1), v_npd,
                 'PW-5 approval records the approver, never a client-supplied value (CDM-34)');
  return next ok((select approved_at is not null from public.construction_versions where id = v_v1),
                 'PW-5a and its timestamp - ck_cv_approval_pair makes them inseparable');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.approve_construction_version(v_v1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-6 an already-approved version cannot be approved again');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_code1 := public.publish_construction(v_k1);
  reset role;
  return next ok(v_code1 ~ '^CON-[0-9]{6}$',
                 'PW-7 publication allocates a neutral permanent sequence code: ' || v_code1);
  return next is((select status from public.constructions where id = v_k1), 'published',
                 'PW-7a and moves the Construction to published');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.publish_construction(v_k1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-8 republishing is refused - published is terminal');
  return next is((select construction_code from public.constructions where id = v_k1), v_code1,
                 'PW-8a and the permanent code is unchanged (CDM-03)');

  -- a second publication must take a DIFFERENT code, never a reused one
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_k2 := public.propose_construction('__p2 pw con two', 5);
  select id into v_v2 from public.construction_versions where construction_id = v_k2;
  perform public.approve_construction_version(v_v2);
  v_code2 := public.publish_construction(v_k2);
  reset role;
  return next ok(v_code2 <> v_code1,
                 'PW-9 a second publication takes a different code - references are never reused (CDM-03)');
  return next ok(v_code2 > v_code1, 'PW-9a allocated from the accepted ref_private sequence, not a max()');

  -- ------------------------------------------------------ adoption, CDM-12
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.adopt_construction_for_plant(v_nag, v_v1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-10 a Maker holds no adopt_construction_for_plant and cannot adopt');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.adopt_construction_for_plant(v_pun, v_v1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-11 and NPD granted only at NAG cannot adopt for PUN - cross-plant isolation');

  -- an unpublished / unapproved Construction is not adoptable: formal use only
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_kdup := public.propose_construction('__p2 pw con dup', 3);
  select id into v_vdup from public.construction_versions where construction_id = v_kdup;
  begin
    perform public.adopt_construction_for_plant(v_nag, v_vdup); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok,
    'PW-12 an unpublished, unapproved Construction cannot be adopted - formal use requires both (CDM-12)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_adopt := public.adopt_construction_for_plant(v_nag, v_v1);
  reset role;
  return next ok(v_adopt is not null, 'PW-13 an approved version of a published Construction IS adoptable at the granted plant');
  return next is((select adopted_by from public.plant_construction_adoptions where id = v_adopt), v_npd,
                 'PW-13a with the adopter recorded from the session, not from a parameter');

  -- ------------------------------------------------------------ merge, CDM-12
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.merge_construction(v_kdup, v_kdup); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-14 a Construction cannot merge into itself');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.merge_construction(v_kdup, v_k1);
  reset role;
  return next is((select status from public.constructions where id = v_kdup), 'merged',
                 'PW-15 a duplicate proposal merges into the existing Construction');
  return next is((select surviving_construction_id from public.constructions where id = v_kdup), v_k1,
                 'PW-15a with lineage retained - the merged row survives and points at its survivor (CDM-12)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.merge_construction(v_k2, v_kdup); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-16 lineage must not chain into an already-merged row');

  -- ------------------------------------------------------------- SKU workflow
  -- Amendment 04 (2026-09-16): repointed from the S4-3 functions, which callers can
  -- no longer reach, to the governed SKU operations. Numbering is kept; PW-21a and
  -- PW-25 state the ruled behaviour instead of the retired one.
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_sku := public.sku_propose(v_nag, v_party, 'Transactional', true,
             pg_catalog.jsonb_build_object('construction_version_id', v_v1, 'length_mm', 300, 'width_mm', 200, 'height_mm', 150));
  reset role;
  return next ok(v_sku is not null, 'PW-17 a Maker may propose a SKU at their own plant (CDM-11)');
  return next is((select status from public.skus where id = v_sku), 'proposed',
                 'PW-17a born proposed');
  return next ok((select plant_item_code is null from public.skus where id = v_sku),
                 'PW-17b with NO Plant Item Code - no pseudo-code is manufactured (DM-132)');
  select id into v_sver from public.sku_versions where sku_id = v_sku;
  return next is((select construction_version_id from public.sku_versions where id = v_sver), v_v1,
                 'PW-17c and its spec version carries exactly one Construction authority (CDM-13)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_propose(v_pun, v_party, 'Transactional', true,
              pg_catalog.jsonb_build_object('construction_version_id', v_v1)); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-18 but not at PUN - a wrong-plant proposal is refused (CDM-35)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_propose(v_nag, v_party, 'Transactional', true, '{}'::jsonb); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-19 and a SKU with no Construction authority is impossible (CDM-13)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_assign_plant_item_code(v_sku, (select content_version from public.skus where id = v_sku), 'NAGPW-0001');
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok,
    'PW-20 code assignment is an Admin/NPD act, not a Maker act (CDM-11)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.sku_assign_plant_item_code(v_sku, (select content_version from public.skus where id = v_sku), 'NAGPW-0001');
  reset role;
  return next is((select plant_item_code from public.skus where id = v_sku), 'NAGPW-0001',
                 'PW-21 NPD assigns the permanent Plant Item Code');
  return next is((select status from public.skus where id = v_sku), 'proposed',
                 'PW-21a and it does NOT publish the SKU - assignment and publication are separate (Amendment 04 D3)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.sku_assign_plant_item_code(v_sku, (select content_version from public.skus where id = v_sku), 'NAGPW-0002');
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-22 a second assignment is refused - the code is permanent (CDM-09)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.sku_approve_version(v_sver, (select content_version from public.sku_versions where id = v_sver));
  perform public.sku_publish(v_sku, (select content_version from public.skus where id = v_sku));
  reset role;
  return next is((select approved_by from public.sku_versions where id = v_sver), v_npd,
                 'PW-23 spec-version approval records the approver from the session');
  return next is((select status from public.skus where id = v_sku), 'active',
                 'PW-23a publication with a code, an approved version and a portfolio makes it active (D3)');

  begin
    update public.sku_versions set spec_bct = 99.9 where id = v_sver;
    return next fail('PW-24 an approved spec version must be immutable');
  exception when others then
    return next ok(true, 'PW-24 and freezes the version against every role thereafter ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.sku_withdraw(v_sku, (select content_version from public.skus where id = v_sku)); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-25 an active SKU cannot be withdrawn back out of its lifecycle (CDM-11, D4)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.sku_discontinue(v_sku, (select content_version from public.skus where id = v_sku), '__p2 pw reason');
  perform public.sku_reactivate(v_sku, (select content_version from public.skus where id = v_sku));
  reset role;
  return next is((select plant_item_code from public.skus where id = v_sku), 'NAGPW-0001',
                 'PW-26 reactivation preserves identity and the permanent code (CDM-11)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_discontinue(v_sku, (select content_version from public.skus where id = v_sku), 'maker'); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-27 a Maker cannot drive the SKU lifecycle');

  -- ------------------------------------------------------------- cleanup
  -- Lineage order, not lineage erasure: a merged Construction may never be left
  -- without its survivor, so the rows that POINT at one are removed first.
  delete from public.plant_construction_adoptions
   where construction_version_id in (
     select cv.id from public.construction_versions cv
      join public.constructions k on k.id = cv.construction_id
     where k.name like '\_\_p2 pw%');
  delete from public.sku_location_applicabilities where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.sku_external_references     where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.sku_master_events           where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.sku_versions                where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.skus where party_id = v_party;
  delete from public.construction_versions
   where construction_id in (select id from public.constructions where name like '\_\_p2 pw%');
  delete from public.constructions
   where name like '\_\_p2 pw%' and surviving_construction_id is not null;
  delete from public.constructions where name like '\_\_p2 pw%';
  delete from public.customer_locations where party_id = v_party;
  delete from public.parties where id = v_party;
  delete from public.plant_capability_grants where app_user_id in (v_maker, v_npd);
  delete from public.group_capability_grants where app_user_id in (v_maker, v_npd);
  delete from public.operational_settings     where created_by  in (v_maker, v_npd);
  delete from app_private.pending_invitations where invite_email in (v_memail, v_nemail);
  delete from public.app_users where id in (v_maker, v_npd);
  perform tests.__drop_synthetic_auth(v_mauth);
  perform tests.__drop_synthetic_auth(v_nauth);
end $fn$;
revoke all on function tests.product_workflow() from public, anon, authenticated;

-- ──────────────────────────────────────────────────────────────── the gates
create or replace function tests.sku_governed_operations()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  t text; f text; v_state text; v_ok boolean;
  v_owner bigint; v_nag bigint; v_party bigint; v_party2 bigint; v_k bigint; v_cv bigint; v_cv2 bigint;
  v_mauth uuid; v_mclaims text; v_maker bigint; v_memail text := 'p2-skug-m@example.invalid';
  v_nauth uuid; v_nclaims text; v_npd   bigint; v_nemail text := 'p2-skug-n@example.invalid';
  v_sku bigint; v_sku2 bigint; v_rep bigint; v_v1 bigint; v_v2 bigint; v_ref bigint; v_cvn integer;
  ops text[] := array['sku_propose','sku_create_version','sku_update_draft_version','sku_approve_version',
                      'sku_assign_plant_item_code','sku_publish','sku_discontinue','sku_reactivate','sku_withdraw',
                      'sku_set_pricing_portfolio','sku_add_reference','sku_withdraw_reference'];
begin
  select id into v_owner from public.app_users order by id limit 1;
  select id into v_nag   from public.plants where plant_code = 'NAG';

  -- ------------------------------------------------------- the boundary (D10)
  foreach t in array array['skus','sku_versions','sku_external_references'] loop
    return next ok(not pg_catalog.has_table_privilege('authenticated', 'public.'||t, 'INSERT')
               and not pg_catalog.has_table_privilege('authenticated', 'public.'||t, 'UPDATE'),
      format('SG-1 authenticated can no longer INSERT or UPDATE %s directly', t));
    return next is((select count(*)::int from pg_catalog.pg_policy pol
                      join pg_catalog.pg_class c on c.oid = pol.polrelid
                     where c.relname = t and pol.polcmd in ('a','w','d')), 0,
      format('SG-1a and %s carries no write policy', t));
  end loop;
  return next ok(pg_catalog.has_table_privilege('authenticated', 'public.sku_master_events', 'SELECT')
             and not pg_catalog.has_table_privilege('authenticated', 'public.sku_master_events', 'INSERT')
             and not pg_catalog.has_table_privilege('authenticated', 'public.sku_master_events', 'UPDATE')
             and not pg_catalog.has_table_privilege('authenticated', 'public.sku_master_events', 'DELETE'),
    'SG-2 the SKU history is readable and append-only for callers (D9)');
  return next ok((select c.relrowsecurity and c.relforcerowsecurity from pg_catalog.pg_class c
                   where c.relname = 'sku_master_events'),
    'SG-2a with RLS enabled and forced');
  foreach f in array ops loop
    return next ok(exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                            where n.nspname = 'app_private' and p.proname = f and p.prosecdef
                              and pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')
                              and not pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')),
      format('SG-3 app_private.%s is a definer callers reach only when signed in', f));
    return next ok(exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                            where n.nspname = 'public' and p.proname = f and not p.prosecdef
                              and pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')),
      format('SG-3a and public.%s is its invoker wrapper', f));
  end loop;
  foreach f in array array['propose_sku','approve_sku_version','assign_plant_item_code','set_sku_status'] loop
    return next ok(not exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                                where n.nspname in ('public','app_private') and p.proname = f
                                  and pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')),
      format('SG-4 the retired S4-3 %s is not reachable by callers', f));
  end loop;
  return next is((select count(*)::int from pg_catalog.pg_trigger tg join pg_catalog.pg_class c on c.oid = tg.tgrelid
                   join pg_catalog.pg_proc p on p.oid = tg.tgfoid
                  where p.proname = 'guard_content_version' and c.relname in ('skus','sku_versions')), 2,
    'SG-5 the database maintains the token on skus and sku_versions (D8)');

  -- ------------------------------------------------------------- fixtures
  v_mauth := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin) values (v_memail, '__p2_skug_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated; v_maker := public.bootstrap_app_user(); reset role;

  v_nauth := tests.__fixture_auth_uid();
  v_nclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_nauth, v_nemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin) values (v_nemail, '__p2_skug_npd', false);
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated; v_npd := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_nag, c.id, v_owner from public.capabilities c where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_npd, v_nag, c.id, v_owner from public.capabilities c where c.capability_key in ('plant_access','manage_sku_master');

  insert into public.parties (display_name, created_by) values ('__p2 skug customer', v_owner) returning id into v_party;
  insert into public.parties (display_name, created_by) values ('__p2 skug other', v_owner) returning id into v_party2;
  insert into public.constructions (name, created_by) values ('__p2 skug con', v_owner) returning id into v_k;
  insert into public.construction_versions (construction_id, version_no, ply, created_by) values (v_k, 1, 3, v_owner) returning id into v_cv;
  insert into public.construction_versions (construction_id, version_no, ply, created_by) values (v_k, 2, 5, v_owner) returning id into v_cv2;

  -- ------------------------------------------------ D1: a Maker proposes, fast
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_sku := public.sku_propose(v_nag, v_party, 'Transactional', true,
             pg_catalog.jsonb_build_object('construction_version_id', v_cv, 'length_mm', 300, 'width_mm', 200,
                                           'height_mm', 0, 'item_name', 'SKUG Carton', 'cobb_value', 'NA'));
  reset role;
  return next ok(v_sku is not null, 'SG-6 a Maker proposes a SKU with its first version (CDM-11, D1)');
  select id into v_v1 from public.sku_versions where sku_id = v_sku;
  return next is((select height_mm from public.sku_versions where id = v_v1), 0::numeric,
    'SG-6a a recorded zero stays zero, never blank');
  return next is((select operation || ':' || actor from public.sku_master_events where sku_id = v_sku),
    'propose:' || v_maker, 'SG-6b the proposal is in the history, attributed to the session caller (D9)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_propose(v_nag, v_party, null, true, pg_catalog.jsonb_build_object('construction_version_id', v_cv));
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '22023', 'SG-7 a proposal without a pricing portfolio is refused (CDM-45)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_propose(v_nag, v_party, 'Strategic', true,
              pg_catalog.jsonb_build_object('construction_version_id', v_cv, 'price', 9));
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '22023', 'SG-8 an unknown field is refused, never silently ignored');

  -- ------------------------------------------------------- D2 drafts in place
  select content_version into v_cvn from public.sku_versions where id = v_v1;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.sku_update_draft_version(v_v1, v_cvn, null, pg_catalog.jsonb_build_object('length_mm', 310));
  reset role;
  return next is((select length_mm from public.sku_versions where id = v_v1), 310::numeric,
    'SG-9 the proposer edits the never-approved first version in place, dimensions included (D2)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_update_draft_version(v_v1, v_cvn, null, pg_catalog.jsonb_build_object('length_mm', 320));
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, 'PT409', 'SG-10 a stale token is refused PT409, never a silent overwrite (D8)');

  -- ------------------------------------------------- D1 same-person approval
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_approve_version(v_v1, (select content_version from public.sku_versions where id = v_v1));
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '42501', 'SG-11 a Maker cannot approve a version');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_sku2 := public.sku_propose(v_nag, v_party, 'Strategic', false,
              pg_catalog.jsonb_build_object('construction_version_id', v_cv, 'length_mm', 400, 'width_mm', 300, 'height_mm', 200));
  select id into v_v2 from public.sku_versions where sku_id = v_sku2;
  perform public.sku_approve_version(v_v2, (select content_version from public.sku_versions where id = v_v2));
  reset role;
  return next is((select approved_by from public.sku_versions where id = v_v2), v_npd,
    'SG-12 the same manage_sku_master holder may propose and approve (D1, initially)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.sku_approve_version(v_v1, (select content_version from public.sku_versions where id = v_v1));
  reset role;

  -- --------------------------------------------------------- D2 new versions
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_create_version(v_sku, (select content_version from public.skus where id = v_sku), false,
              pg_catalog.jsonb_build_object('width_mm', 210));
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, 'PT423', 'SG-13 a dimension change is a NEW SKU, refused as a version (CDM-10)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_create_version(v_sku, (select content_version from public.skus where id = v_sku), false,
              pg_catalog.jsonb_build_object('construction_version_id', v_cv2));
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, 'PT423', 'SG-13a so is a Construction change');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_create_version(v_sku, (select content_version from public.skus where id = v_sku), false,
              pg_catalog.jsonb_build_object('cobb_value', '32'));
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '22023', 'SG-14 a Cobb value change must be declared price-driving (D2)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.sku_create_version(v_sku, (select content_version from public.skus where id = v_sku), false,
            pg_catalog.jsonb_build_object('item_name', 'SKUG Carton Renamed', 'print_technology', 'Flexo'));
  reset role;
  return next is((select item_name || '/' || version_no || '/' || (approved_at is null)::text
                    from public.sku_versions where sku_id = v_sku order by version_no desc limit 1),
    'SKUG Carton Renamed/2/true', 'SG-15 a name or printing change is a new, unapproved version (D2)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_create_version(v_sku, (select content_version from public.skus where id = v_sku), false,
              pg_catalog.jsonb_build_object('item_group', 'X'));
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '22023', 'SG-16 one open draft at a time');

  -- ------------------------------------------------- D3 code, then publication
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.sku_publish(v_sku, (select content_version from public.skus where id = v_sku));
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '22023', 'SG-17 publishing without a Plant Item Code is refused (D3)');

  insert into public.sku_external_references (sku_id, plant_id, reference_kind, reference_value, created_by)
  values (v_sku2, v_nag, 'legacy_plant_item_code', '__P2-SKUG-OLD', v_owner);
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.sku_assign_plant_item_code(v_sku, (select content_version from public.skus where id = v_sku), '__P2-SKUG-OLD');
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  perform public.sku_assign_plant_item_code(v_sku, (select content_version from public.skus where id = v_sku), '__P2-SKUG-0001');
  perform public.sku_publish(v_sku, (select content_version from public.skus where id = v_sku));
  reset role;
  return next is(v_state, '22023', 'SG-18 a retired code recorded at the plant is never reissued (D3)');
  return next is((select status || '/' || plant_item_code from public.skus where id = v_sku), 'active/__P2-SKUG-0001',
    'SG-19 code assigned, version approved, portfolio recorded: published (D3)');

  -- ------------------------------------------------- D4 lifecycle and replacement
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_rep := public.sku_propose(v_nag, v_party2, 'Transactional', true, pg_catalog.jsonb_build_object('construction_version_id', v_cv));
  begin
    perform public.sku_discontinue(v_sku, (select content_version from public.skus where id = v_sku), '  ');
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '22023', 'SG-20 discontinuing needs a reason (D4)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.sku_discontinue(v_sku, (select content_version from public.skus where id = v_sku), 'superseded', v_rep);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '22023', 'SG-21 a replacement at another Customer is refused (D4)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.sku_assign_plant_item_code(v_sku2, (select content_version from public.skus where id = v_sku2), '__P2-SKUG-0002');
  perform public.sku_publish(v_sku2, (select content_version from public.skus where id = v_sku2));
  perform public.sku_discontinue(v_sku, (select content_version from public.skus where id = v_sku), 'superseded', v_sku2);
  reset role;
  return next is((select status || '/' || replacement_sku_id from public.skus where id = v_sku), 'discontinued/' || v_sku2,
    'SG-22 discontinued with a linked replacement of the same plant and Customer (CDM-11)');
  return next is((select reason from public.sku_master_events where sku_id = v_sku and operation = 'discontinue'), 'superseded',
    'SG-22a and the reason is in the history');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.sku_reactivate(v_sku, (select content_version from public.skus where id = v_sku));
  reset role;
  return next ok((select status = 'active' and replacement_sku_id is null from public.skus where id = v_sku),
    'SG-23 reactivation keeps identity and clears the replacement link (D4)');
  return next is((select (before_state->>'replacement_sku_id')::bigint from public.sku_master_events
                   where sku_id = v_sku and operation = 'reactivate'), v_sku2,
    'SG-23a while the history keeps the link it cleared');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.sku_withdraw(v_rep, (select content_version from public.skus where id = v_rep), 'duplicate');
  reset role;
  return next is((select status from public.skus where id = v_rep), 'withdrawn', 'SG-24 a proposal is withdrawn, not deleted (CDM-31, D4)');
  begin
    update public.skus set status = 'proposed' where id = v_rep;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  return next is(v_state, '23514', 'SG-24a and withdrawn is terminal for every role');

  -- ------------------------------------------------ CDM-45 and D5 references
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.sku_set_pricing_portfolio(v_sku, (select content_version from public.skus where id = v_sku), 'Strategic');
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '42501', 'SG-25 a Maker cannot reclassify the pricing portfolio');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.sku_set_pricing_portfolio(v_sku, (select content_version from public.skus where id = v_sku), 'Strategic');
  v_ref := public.sku_add_reference(v_sku, (select content_version from public.skus where id = v_sku), 'customer_item_code', ' CUST-SKUG ');
  begin
    perform public.sku_add_reference(v_sku, (select content_version from public.skus where id = v_sku), 'customer_item_code', 'CUST-SKUG');
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  perform public.sku_withdraw_reference(v_ref, (select content_version from public.skus where id = v_sku));
  reset role;
  return next is((select pricing_portfolio from public.skus where id = v_sku), 'Strategic',
    'SG-26 the portfolio changes in place by due authority (CDM-45 C-03)');
  return next is(v_state, '22023', 'SG-27 an active duplicate reference is refused');
  return next is((select reference_value || '/' || status from public.sku_external_references where id = v_ref),
    'CUST-SKUG/withdrawn', 'SG-28 references are trimmed on entry, withdrawn rather than edited (D5)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    insert into public.sku_master_events (plant_id, sku_id, entity, entity_id, operation, actor)
    values (v_nag, v_sku, 'sku', v_sku, 'publish', v_npd);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate; end;
  reset role;
  return next is(v_state, '42501', 'SG-29 no caller can write history directly (D9)');

  -- ------------------------------------------------------------- cleanup
  delete from public.sku_master_events where sku_id in (select id from public.skus where party_id in (v_party, v_party2));
  delete from public.sku_external_references where sku_id in (select id from public.skus where party_id in (v_party, v_party2));
  delete from public.sku_versions where sku_id in (select id from public.skus where party_id in (v_party, v_party2));
  update public.skus set replacement_sku_id = null where party_id in (v_party, v_party2);
  delete from public.skus where party_id in (v_party, v_party2);
  delete from public.construction_versions where construction_id = v_k;
  delete from public.constructions where id = v_k;
  delete from public.parties where id in (v_party, v_party2);
  delete from public.plant_capability_grants where app_user_id in (v_maker, v_npd);
  delete from public.operational_settings where created_by in (v_maker, v_npd);
  delete from app_private.pending_invitations where invite_email in (v_memail, v_nemail);
  delete from public.app_users where id in (v_maker, v_npd);
  perform tests.__drop_synthetic_auth(v_mauth);
  perform tests.__drop_synthetic_auth(v_nauth);
end $fn$;

revoke all on function tests.sku_governed_operations() from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────── register the suite
do $rw$
declare v_def text; v_oid oid;
  v_old text := $q$  return query select * from tests.product_workflow();$q$;
  v_new text := $q$  return query select * from tests.product_workflow();
  return query select * from tests.sku_governed_operations();$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'tests' and p.proname = 'run_all';
  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def) = 0 then
    raise exception 'the run_all anchor was not found' using errcode = '55000';
  end if;
  if position('sku_governed_operations' in v_def) = 0 then
    execute replace(v_def, v_old, v_new);
  end if;
end $rw$;
