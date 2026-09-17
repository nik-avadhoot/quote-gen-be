-- U2 SKU Master: governed master Location applicability (Canonical Amendment 05).
-- PREPARED, NOT APPLIED. Existing batch_only rows remain readable and untouched.

do $$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'sku_master_events') then
    raise exception using errcode = 'object_not_in_prerequisite_state',
      message = 'Location applicability needs Canonical Amendment 04.';
  end if;
end $$;

alter table public.sku_location_applicabilities
  add column content_version integer not null default 1;

create trigger trg_sla_content_version
  before update on public.sku_location_applicabilities
  for each row execute function app_private.guard_content_version();

create or replace function app_private.guard_sku_location_applicability()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.sku_id is distinct from old.sku_id
     or new.plant_id is distinct from old.plant_id
     or new.party_id is distinct from old.party_id
     or new.location_id is distinct from old.location_id
     or new.scope is distinct from old.scope then
    raise exception 'SKU Location applicability binding is immutable' using errcode = '23514';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'proposed' and new.status = 'approved')
    or (old.status = 'approved' and new.status = 'withdrawn')
    or (old.status = 'withdrawn' and new.status = 'approved')) then
    raise exception 'illegal Location applicability transition % -> %', old.status, new.status
      using errcode = '23514';
  end if;
  return new;
end $fn$;
create trigger trg_sla_governed_lifecycle
  before update on public.sku_location_applicabilities
  for each row execute function app_private.guard_sku_location_applicability();
revoke all on function app_private.guard_sku_location_applicability() from public, anon, authenticated;

alter table public.sku_master_events drop constraint ck_sme_entity;
alter table public.sku_master_events add constraint ck_sme_entity
  check (entity in ('sku', 'sku_version', 'sku_external_reference', 'sku_location_applicability'));
alter table public.sku_master_events drop constraint ck_sme_operation;
alter table public.sku_master_events add constraint ck_sme_operation check (operation in (
  'propose', 'create_version', 'update_draft_version', 'approve_version', 'assign_plant_item_code',
  'publish', 'discontinue', 'reactivate', 'withdraw', 'set_pricing_portfolio',
  'add_reference', 'withdraw_reference', 'propose_applicability', 'approve_applicability',
  'withdraw_applicability', 'reactivate_applicability'));

revoke insert, update on public.sku_location_applicabilities from authenticated;
drop policy if exists sku_location_applicabilities_insert on public.sku_location_applicabilities;
drop policy if exists sku_location_applicabilities_update on public.sku_location_applicabilities;

create or replace function app_private.__sku_applicability_lock(p_applicability bigint, p_expected integer)
returns public.sku_location_applicabilities language plpgsql set search_path = '' as $fn$
declare v public.sku_location_applicabilities;
begin
  if p_expected is null then
    raise exception 'the applicability content version you read must be supplied' using errcode = '22023';
  end if;
  select * into v from public.sku_location_applicabilities where id = p_applicability for update;
  if not found then raise exception 'Location applicability not found' using errcode = 'P0002'; end if;
  if v.content_version <> p_expected then
    raise exception 'the Location applicability changed since you read it' using errcode = 'PT409';
  end if;
  if v.scope <> 'master' then
    raise exception 'batch_only applicability is governed by the quotation workflow' using errcode = '22023';
  end if;
  return v;
end $fn$;

create or replace function app_private.__sku_active_location(p_location bigint, p_party bigint)
returns public.customer_locations language plpgsql set search_path = '' as $fn$
declare v public.customer_locations;
begin
  select * into v from public.customer_locations where id = p_location and party_id = p_party;
  if not found then raise exception 'Location does not belong to this SKU Customer' using errcode = '23503'; end if;
  if v.status <> 'active' then raise exception 'Location must currently be active' using errcode = '23514'; end if;
  return v;
end $fn$;

revoke all on function app_private.__sku_applicability_lock(bigint,integer) from public, anon, authenticated;
revoke all on function app_private.__sku_active_location(bigint,bigint) from public, anon, authenticated;

create or replace function app_private.sku_propose_master_applicability(
  p_sku bigint, p_expected_content_version integer, p_location bigint)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus; v_app public.sku_location_applicabilities;
begin
  v_me := app_private.__sku_me();
  v_sku := app_private.__sku_lock(p_sku, p_expected_content_version);
  perform app_private.__sku_require_manage(v_sku.plant_id);
  perform app_private.__sku_active_location(p_location, v_sku.party_id);
  insert into public.sku_location_applicabilities
    (sku_id, plant_id, party_id, location_id, scope, status, created_by)
  values (p_sku, v_sku.plant_id, v_sku.party_id, p_location, 'master', 'proposed', v_me)
  returning * into v_app;
  perform app_private.__sku_touch(p_sku);
  perform app_private.__sku_event(v_sku.plant_id, p_sku, 'sku_location_applicability', v_app.id,
    'propose_applicability', v_me, null, null, pg_catalog.to_jsonb(v_app));
  return v_app.id;
end $fn$;

create or replace function app_private.sku_master_location_options(p_sku bigint)
returns table(id bigint, location_code text, status text, bill_to_eligible boolean, ship_to_eligible boolean)
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku public.skus;
begin
  v_me := app_private.__sku_me();
  select * into v_sku from public.skus where public.skus.id = p_sku;
  if not found then raise exception 'SKU not found' using errcode = 'P0002'; end if;
  perform app_private.__sku_require_manage(v_sku.plant_id);
  return query select l.id, l.location_code, l.status, l.bill_to_eligible, l.ship_to_eligible
    from public.customer_locations l
   where l.party_id = v_sku.party_id and l.status = 'active'
   order by l.location_code, l.id;
end $fn$;

create or replace function app_private.sku_approve_master_applicability(
  p_applicability bigint, p_expected_content_version integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_app public.sku_location_applicabilities;
begin
  v_me := app_private.__sku_me();
  v_app := app_private.__sku_applicability_lock(p_applicability, p_expected_content_version);
  perform app_private.__sku_require_manage(v_app.plant_id);
  perform app_private.__sku_active_location(v_app.location_id, v_app.party_id);
  if v_app.status <> 'proposed' then raise exception 'only Proposed applicability may be approved' using errcode = '23514'; end if;
  update public.sku_location_applicabilities set status = 'approved', approved_by = v_me, approved_at = now()
   where id = p_applicability;
  perform app_private.__sku_touch(v_app.sku_id);
  perform app_private.__sku_event(v_app.plant_id, v_app.sku_id, 'sku_location_applicability', v_app.id,
    'approve_applicability', v_me, null, pg_catalog.to_jsonb(v_app),
    pg_catalog.to_jsonb(v_app) || pg_catalog.jsonb_build_object('status','approved','approved_by',v_me));
end $fn$;

create or replace function app_private.sku_withdraw_master_applicability(
  p_applicability bigint, p_expected_content_version integer, p_reason text)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_app public.sku_location_applicabilities; v_reason text := pg_catalog.btrim(p_reason);
begin
  v_me := app_private.__sku_me();
  v_app := app_private.__sku_applicability_lock(p_applicability, p_expected_content_version);
  perform app_private.__sku_require_manage(v_app.plant_id);
  if coalesce(v_reason,'') = '' or pg_catalog.length(v_reason) > 500 then
    raise exception 'a withdrawal reason of 1 to 500 characters is required' using errcode = '22023';
  end if;
  if v_app.status <> 'approved' then raise exception 'only Approved applicability may be withdrawn' using errcode = '23514'; end if;
  update public.sku_location_applicabilities set status = 'withdrawn' where id = p_applicability;
  perform app_private.__sku_touch(v_app.sku_id);
  perform app_private.__sku_event(v_app.plant_id, v_app.sku_id, 'sku_location_applicability', v_app.id,
    'withdraw_applicability', v_me, v_reason, pg_catalog.to_jsonb(v_app),
    pg_catalog.to_jsonb(v_app) || pg_catalog.jsonb_build_object('status','withdrawn'));
end $fn$;

create or replace function app_private.sku_reactivate_master_applicability(
  p_applicability bigint, p_expected_content_version integer, p_reason text)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_app public.sku_location_applicabilities; v_reason text := pg_catalog.btrim(p_reason);
begin
  v_me := app_private.__sku_me();
  v_app := app_private.__sku_applicability_lock(p_applicability, p_expected_content_version);
  perform app_private.__sku_require_manage(v_app.plant_id);
  if coalesce(v_reason,'') = '' or pg_catalog.length(v_reason) > 500 then
    raise exception 'a reactivation reason of 1 to 500 characters is required' using errcode = '22023';
  end if;
  perform app_private.__sku_active_location(v_app.location_id, v_app.party_id);
  if v_app.status <> 'withdrawn' then raise exception 'only Withdrawn applicability may be reactivated' using errcode = '23514'; end if;
  update public.sku_location_applicabilities set status = 'approved', approved_by = v_me, approved_at = now()
   where id = p_applicability;
  perform app_private.__sku_touch(v_app.sku_id);
  perform app_private.__sku_event(v_app.plant_id, v_app.sku_id, 'sku_location_applicability', v_app.id,
    'reactivate_applicability', v_me, v_reason, pg_catalog.to_jsonb(v_app),
    pg_catalog.to_jsonb(v_app) || pg_catalog.jsonb_build_object('status','approved','approved_by',v_me));
end $fn$;

create or replace function public.sku_propose_master_applicability(p_sku bigint, p_expected_content_version integer, p_location bigint)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.sku_propose_master_applicability(p_sku,p_expected_content_version,p_location); $fn$;
create or replace function public.sku_master_location_options(p_sku bigint)
returns table(id bigint, location_code text, status text, bill_to_eligible boolean, ship_to_eligible boolean)
language sql security invoker set search_path = '' as $fn$
  select * from app_private.sku_master_location_options(p_sku); $fn$;
create or replace function public.sku_approve_master_applicability(p_applicability bigint, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_approve_master_applicability(p_applicability,p_expected_content_version); $fn$;
create or replace function public.sku_withdraw_master_applicability(p_applicability bigint, p_expected_content_version integer, p_reason text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_withdraw_master_applicability(p_applicability,p_expected_content_version,p_reason); $fn$;
create or replace function public.sku_reactivate_master_applicability(p_applicability bigint, p_expected_content_version integer, p_reason text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_reactivate_master_applicability(p_applicability,p_expected_content_version,p_reason); $fn$;

do $$
declare r record;
begin
  for r in select n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid) args
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('app_private','public') and p.proname in (
    'sku_master_location_options','sku_propose_master_applicability','sku_approve_master_applicability',
    'sku_withdraw_master_applicability','sku_reactivate_master_applicability')
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon',r.nspname,r.proname,r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated',r.nspname,r.proname,r.args);
  end loop;
end $$;

comment on column public.sku_location_applicabilities.content_version is
  'Database-maintained CAS token for governed master applicability operations.';

-- Deploy-time pgTAP contract. Behavioural route/UI gates live in the repositories;
-- this suite verifies the activated database boundary itself.
create or replace function tests.sku_location_applicability()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_count integer;
begin
  return next ok(exists (select 1 from information_schema.columns where table_schema='public'
    and table_name='sku_location_applicabilities' and column_name='content_version'),
    'SLA-DB-1 content_version is activated');
  return next ok(not pg_catalog.has_table_privilege('authenticated','public.sku_location_applicabilities','INSERT')
    and not pg_catalog.has_table_privilege('authenticated','public.sku_location_applicabilities','UPDATE'),
    'SLA-DB-2 authenticated has no direct write privilege');
  select count(*) into v_count from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in ('sku_propose_master_applicability','sku_approve_master_applicability',
    'sku_withdraw_master_applicability','sku_reactivate_master_applicability');
  return next is(v_count, 4, 'SLA-DB-3 four public governed operations exist');
  select count(*) into v_count from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid
   join pg_catalog.pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname='sku_location_applicabilities'
     and t.tgname in ('trg_sla_content_version','trg_sla_governed_lifecycle') and not t.tgisinternal;
  return next is(v_count, 2, 'SLA-DB-4 CAS and immutable-lifecycle triggers exist');
end $fn$;
revoke all on function tests.sku_location_applicability() from public, anon, authenticated;

do $rw$
declare v_def text; v_oid oid;
  v_old text := $q$  return query select * from tests.sku_governed_operations();$q$;
  v_new text := $q$  return query select * from tests.sku_governed_operations();
  return query select * from tests.sku_location_applicability();$q$;
begin
  select p.oid into v_oid from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
   where n.nspname='tests' and p.proname='run_all';
  v_def := pg_catalog.pg_get_functiondef(v_oid);
  if position(v_old in v_def)=0 then raise exception 'the run_all anchor was not found' using errcode='55000'; end if;
  if position('sku_location_applicability' in v_def)=0 then execute replace(v_def,v_old,v_new); end if;
end $rw$;
