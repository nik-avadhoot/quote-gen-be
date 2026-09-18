-- U2 SKU Master: governed SKU Set membership (Canonical Amendment 04, slice 2).
-- PREPARED, NOT APPLIED. Membership is supplied only by internal SKU identity;
-- no Plant Item Code parsing or inferred relationship is introduced.

do $$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'sku_master_events') then
    raise exception using errcode = 'object_not_in_prerequisite_state',
      message = 'SKU Set operations need Canonical Amendment 04.';
  end if;
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'sku_sets') then
    raise exception using errcode = 'object_not_in_prerequisite_state',
      message = 'SKU Set operations need Canonical Amendment 02.';
  end if;
  -- This recorded migration follows Amendment 05 and extends the same history
  -- constraints/test registry; fail clearly instead of losing those additions.
  if not exists (select 1 from information_schema.columns where table_schema = 'public'
                  and table_name = 'sku_location_applicabilities' and column_name = 'content_version') then
    raise exception using errcode = 'object_not_in_prerequisite_state',
      message = 'SKU Set operations need the preceding Amendment 05 migration.';
  end if;
end $$;

alter table public.sku_sets
  add column confirmed_at timestamptz null,
  add column confirmed_by bigint null,
  add constraint fk_sku_set_confirmed_by foreign key (confirmed_by)
    references public.app_users(id) on delete restrict;
create index ix_sku_set_confirmed_by on public.sku_sets (confirmed_by);

alter table public.sku_set_members
  add column confirmed_at timestamptz null,
  add column confirmed_by bigint null,
  add constraint fk_ssm_confirmed_by foreign key (confirmed_by)
    references public.app_users(id) on delete restrict;
create index ix_ssm_confirmed_by on public.sku_set_members (confirmed_by);
-- The UI and CDM-44 model one current master Set per independent SKU. A retired
-- Set releases its members because retirement withdraws every membership.
create unique index uk_ssm_one_current_set_per_sku on public.sku_set_members (sku_id)
  where status <> 'withdrawn';

create trigger trg_sku_set_content_version
  before update on public.sku_sets
  for each row execute function app_private.guard_content_version();
create trigger trg_ssm_content_version
  before update on public.sku_set_members
  for each row execute function app_private.guard_content_version();

create or replace function app_private.guard_sku_set_lifecycle()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.plant_id is distinct from old.plant_id
     or new.set_label is distinct from old.set_label
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at then
    raise exception 'SKU Set identity is immutable' using errcode = '23514';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'proposed' and new.status = 'confirmed')
    or (old.status = 'confirmed' and new.status = 'retired')) then
    raise exception 'illegal SKU Set transition % -> %', old.status, new.status using errcode = '23514';
  end if;
  if old.status = 'confirmed' and (new.confirmed_by is distinct from old.confirmed_by
                                or new.confirmed_at is distinct from old.confirmed_at) then
    raise exception 'SKU Set confirmation is immutable' using errcode = '23514';
  end if;
  return new;
end $fn$;
create trigger trg_sku_set_governed_lifecycle
  before update on public.sku_sets
  for each row execute function app_private.guard_sku_set_lifecycle();

create or replace function app_private.guard_sku_set_member_lifecycle()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.set_id is distinct from old.set_id
     or new.sku_id is distinct from old.sku_id
     or new.plant_id is distinct from old.plant_id
     or new.role is distinct from old.role
     or new.qty_per_set is distinct from old.qty_per_set
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at then
    raise exception 'SKU Set member identity, role and quantity are immutable' using errcode = '23514';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'proposed' and new.status = 'confirmed')
    or (old.status = 'confirmed' and new.status = 'withdrawn')) then
    raise exception 'illegal SKU Set member transition % -> %', old.status, new.status using errcode = '23514';
  end if;
  if old.status = 'confirmed' and (new.confirmed_by is distinct from old.confirmed_by
                                or new.confirmed_at is distinct from old.confirmed_at) then
    raise exception 'SKU Set member confirmation is immutable' using errcode = '23514';
  end if;
  return new;
end $fn$;
create trigger trg_ssm_governed_lifecycle
  before update on public.sku_set_members
  for each row execute function app_private.guard_sku_set_member_lifecycle();

revoke all on function app_private.guard_sku_set_lifecycle() from public, anon, authenticated;
revoke all on function app_private.guard_sku_set_member_lifecycle() from public, anon, authenticated;

alter table public.sku_master_events drop constraint ck_sme_entity;
alter table public.sku_master_events add constraint ck_sme_entity
  check (entity in ('sku', 'sku_version', 'sku_external_reference', 'sku_location_applicability', 'sku_set'));
alter table public.sku_master_events drop constraint ck_sme_operation;
alter table public.sku_master_events add constraint ck_sme_operation check (operation in (
  'propose', 'create_version', 'update_draft_version', 'approve_version', 'assign_plant_item_code',
  'publish', 'discontinue', 'reactivate', 'withdraw', 'set_pricing_portfolio',
  'add_reference', 'withdraw_reference', 'propose_applicability', 'approve_applicability',
  'withdraw_applicability', 'reactivate_applicability',
  'propose_sku_set', 'confirm_sku_set', 'retire_sku_set'));

-- Amendment 02 already withholds these privileges. Repeat the closure at the write boundary.
revoke insert, update, delete on public.sku_sets, public.sku_set_members from authenticated;

create or replace function app_private.__sku_set_lock(p_set bigint, p_expected integer)
returns public.sku_sets language plpgsql set search_path = '' as $fn$
declare v public.sku_sets;
begin
  if p_expected is null then
    raise exception 'the SKU Set content version you read must be supplied' using errcode = '22023';
  end if;
  select * into v from public.sku_sets where id = p_set for update;
  if not found then raise exception 'SKU Set not found' using errcode = 'P0002'; end if;
  if v.content_version <> p_expected then
    raise exception 'the SKU Set changed since you read it' using errcode = 'PT409';
  end if;
  return v;
end $fn$;
revoke all on function app_private.__sku_set_lock(bigint,integer) from public, anon, authenticated;

create or replace function app_private.sku_set_propose(
  p_box_sku bigint, p_expected_content_version integer, p_set_label text, p_members jsonb)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare
  v_me bigint; v_box public.skus; v_set public.sku_sets; v_member jsonb;
  v_ids bigint[]; v_count integer; v_box_count integer;
begin
  v_me := app_private.__sku_me();
  v_box := app_private.__sku_lock(p_box_sku, p_expected_content_version);
  perform app_private.__sku_require_manage(v_box.plant_id);
  if v_box.status = 'withdrawn' then raise exception 'a withdrawn SKU cannot join a set' using errcode = '23514'; end if;
  if coalesce(pg_catalog.btrim(p_set_label), '') = '' or pg_catalog.length(pg_catalog.btrim(p_set_label)) > 200 then
    raise exception 'a SKU Set label of 1 to 200 characters is required' using errcode = '22023';
  end if;
  if p_members is null or pg_catalog.jsonb_typeof(p_members) <> 'array'
     or pg_catalog.jsonb_array_length(p_members) not between 1 and 100 then
    raise exception 'members must contain 1 to 100 entries' using errcode = '22023';
  end if;

  select pg_catalog.array_agg((m->>'sku_id')::bigint order by (m->>'sku_id')::bigint),
         count(*), count(*) filter (where m->>'role' = 'box')
    into v_ids, v_count, v_box_count
    from pg_catalog.jsonb_array_elements(p_members) m
   where pg_catalog.jsonb_typeof(m) = 'object'
     and (m->>'sku_id') ~ '^[1-9][0-9]*$'
     and m->>'role' in ('box','plate','partition')
     and (m->>'qty_per_set') ~ '^[0-9]+([.][0-9]+)?$'
     and (m->>'qty_per_set')::numeric > 0
     and (m->>'qty_per_set')::numeric <= 9999999.999
     and pg_catalog.scale((m->>'qty_per_set')::numeric) <= 3;
  if v_count <> pg_catalog.jsonb_array_length(p_members)
     or v_box_count <> 1
     or not (p_box_sku = any(v_ids))
     or (select m->>'role' from pg_catalog.jsonb_array_elements(p_members) m
          where (m->>'sku_id')::bigint = p_box_sku limit 1) <> 'box'
     or pg_catalog.array_length(v_ids,1) <> (select count(distinct x) from pg_catalog.unnest(v_ids) x) then
    raise exception 'members need unique internal SKU ids, positive quantities and exactly the selected box' using errcode = '22023';
  end if;

  -- Consistent ascending locks avoid set/SKU deadlocks under concurrent proposals.
  perform 1 from public.skus where id = any(v_ids) order by id for update;
  if (select count(*) from public.skus where id = any(v_ids)) <> v_count
     or exists (select 1 from public.skus where id = any(v_ids)
                 and (plant_id <> v_box.plant_id or status = 'withdrawn')) then
    raise exception 'every member must be a non-withdrawn SKU at the box plant' using errcode = '23514';
  end if;

  insert into public.sku_sets (plant_id, set_label, status, created_by)
  values (v_box.plant_id, pg_catalog.btrim(p_set_label), 'proposed', v_me) returning * into v_set;
  for v_member in select value from pg_catalog.jsonb_array_elements(p_members) order by (value->>'sku_id')::bigint loop
    insert into public.sku_set_members (set_id, sku_id, plant_id, role, qty_per_set, status, created_by)
    values (v_set.id, (v_member->>'sku_id')::bigint, v_box.plant_id, v_member->>'role',
            (v_member->>'qty_per_set')::numeric, 'proposed', v_me);
  end loop;
  perform app_private.__sku_touch(x) from pg_catalog.unnest(v_ids) x;
  perform app_private.__sku_event(v_box.plant_id, p_box_sku, 'sku_set', v_set.id, 'propose_sku_set',
    v_me, null, null, pg_catalog.jsonb_build_object('set', pg_catalog.to_jsonb(v_set), 'members', p_members));
  return v_set.id;
exception when unique_violation then
  raise exception 'a current SKU Set already uses that label or member' using errcode = '22023';
when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'a SKU Set member has an invalid id or quantity' using errcode = '22023';
end $fn$;

create or replace function app_private.sku_set_confirm(p_set bigint, p_expected_content_version integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  v_me bigint; v_set public.sku_sets; v_box bigint; v_ids bigint[]; v_before jsonb;
begin
  v_me := app_private.__sku_me();
  v_set := app_private.__sku_set_lock(p_set, p_expected_content_version);
  perform app_private.__sku_require_manage(v_set.plant_id);
  if v_set.status <> 'proposed' then raise exception 'only a Proposed SKU Set may be confirmed' using errcode = '23514'; end if;
  select pg_catalog.array_agg(sku_id order by sku_id), min(sku_id) filter (where role='box'),
         pg_catalog.jsonb_agg(pg_catalog.to_jsonb(m) order by m.id)
    into v_ids, v_box, v_before from public.sku_set_members m where set_id = p_set and status = 'proposed';
  if v_ids is null or v_box is null then raise exception 'the SKU Set has no proposed box membership' using errcode = '23514'; end if;
  perform 1 from public.skus where id = any(v_ids) order by id for update;
  if exists (select 1 from public.skus where id = any(v_ids) and status = 'withdrawn') then
    raise exception 'a withdrawn SKU cannot be confirmed in a set' using errcode = '23514';
  end if;
  -- D-06/D-13: a settled Customer requires a different confirmer.
  if v_me = v_set.created_by and exists (
      select 1 from public.skus s join public.parties p on p.id=s.party_id
       where s.id = any(v_ids) and p.lifecycle_state='customer' and p.customer_code is not null) then
    raise exception 'a settled Customer SKU Set requires a second approver' using errcode = 'PT425';
  end if;
  update public.sku_set_members set status='confirmed', confirmed_by=v_me, confirmed_at=pg_catalog.now()
   where set_id=p_set and status='proposed';
  update public.sku_sets set status='confirmed', confirmed_by=v_me, confirmed_at=pg_catalog.now() where id=p_set;
  perform app_private.__sku_touch(x) from pg_catalog.unnest(v_ids) x;
  perform app_private.__sku_event(v_set.plant_id, v_box, 'sku_set', p_set, 'confirm_sku_set', v_me, null,
    pg_catalog.jsonb_build_object('set', pg_catalog.to_jsonb(v_set), 'members', v_before),
    pg_catalog.jsonb_build_object('status','confirmed','confirmed_by',v_me,'member_count',pg_catalog.array_length(v_ids,1)));
end $fn$;

create or replace function app_private.sku_set_retire(
  p_set bigint, p_expected_content_version integer, p_reason text)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  v_me bigint; v_set public.sku_sets; v_box bigint; v_ids bigint[]; v_reason text := pg_catalog.btrim(p_reason);
begin
  v_me := app_private.__sku_me();
  v_set := app_private.__sku_set_lock(p_set, p_expected_content_version);
  perform app_private.__sku_require_manage(v_set.plant_id);
  if coalesce(v_reason,'')='' or pg_catalog.length(v_reason)>500 then
    raise exception 'a retirement reason of 1 to 500 characters is required' using errcode = '22023';
  end if;
  if v_set.status <> 'confirmed' then raise exception 'only a Confirmed SKU Set may be retired' using errcode = '23514'; end if;
  select pg_catalog.array_agg(sku_id order by sku_id), min(sku_id) filter (where role='box')
    into v_ids, v_box from public.sku_set_members where set_id=p_set and status='confirmed';
  perform 1 from public.skus where id = any(v_ids) order by id for update;
  update public.sku_set_members set status='withdrawn' where set_id=p_set and status='confirmed';
  update public.sku_sets set status='retired' where id=p_set;
  perform app_private.__sku_touch(x) from pg_catalog.unnest(v_ids) x;
  perform app_private.__sku_event(v_set.plant_id, v_box, 'sku_set', p_set, 'retire_sku_set', v_me, v_reason,
    pg_catalog.to_jsonb(v_set), pg_catalog.jsonb_build_object('status','retired','member_count',pg_catalog.array_length(v_ids,1)));
end $fn$;

create or replace function public.sku_set_propose(
  p_box_sku bigint, p_expected_content_version integer, p_set_label text, p_members jsonb)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.sku_set_propose(p_box_sku,p_expected_content_version,p_set_label,p_members); $fn$;
create or replace function public.sku_set_confirm(p_set bigint, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_set_confirm(p_set,p_expected_content_version); $fn$;
create or replace function public.sku_set_retire(p_set bigint, p_expected_content_version integer, p_reason text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.sku_set_retire(p_set,p_expected_content_version,p_reason); $fn$;

do $$
declare r record;
begin
  for r in select n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid) args
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('app_private','public')
     and p.proname in ('sku_set_propose','sku_set_confirm','sku_set_retire')
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon',r.nspname,r.proname,r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated',r.nspname,r.proname,r.args);
  end loop;
end $$;

comment on column public.sku_sets.content_version is
  'Database-maintained CAS token for governed SKU Set operations.';
comment on column public.sku_set_members.content_version is
  'Database-maintained CAS token for governed SKU Set member transitions.';

create or replace function tests.sku_set_operations()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  return next ok(not pg_catalog.has_table_privilege('authenticated','public.sku_sets','INSERT')
    and not pg_catalog.has_table_privilege('authenticated','public.sku_set_members','UPDATE'),
    'SSO-DB-1 no caller has a direct SKU Set write path');
  return next ok(pg_catalog.has_function_privilege('authenticated','public.sku_set_propose(bigint,integer,text,jsonb)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.sku_set_confirm(bigint,integer)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.sku_set_retire(bigint,integer,text)','EXECUTE'),
    'SSO-DB-2 governed SKU Set operations are executable');
  return next ok(exists (select 1 from information_schema.columns where table_schema='public'
    and table_name='sku_sets' and column_name='confirmed_by'),
    'SSO-DB-3 confirmation actor is recorded');
end $fn$;
revoke all on function tests.sku_set_operations() from public, anon, authenticated;

do $rw$
declare v_def text; v_oid oid;
  v_old text := $q$return query select * from tests.sku_location_applicability();$q$;
  v_new text := $q$return query select * from tests.sku_location_applicability();
  return query select * from tests.sku_set_operations();$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='tests' and p.proname='run_all';
  v_def := pg_get_functiondef(v_oid);
  if position('sku_set_operations' in v_def)=0 then
    if position(v_old in v_def)=0 then raise exception 'tests.run_all SKU applicability anchor not found' using errcode='55000'; end if;
    execute replace(v_def,v_old,v_new);
  end if;
end $rw$;
