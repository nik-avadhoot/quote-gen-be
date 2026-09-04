-- P2-6: restore the canonical private-definer design (option 1).
--
-- P2-5 put owner-privileged implementation code in `public` because PostgREST
-- cannot route to app_private. That was implementation pressure changing the
-- security architecture, and it produced two valid 0029 advisor warnings.
--
-- The compliant shape separates ROUTING from PRIVILEGE:
--   public.<name>()        SECURITY INVOKER - a thin, unprivileged shim that exists
--                          only so PostgREST has something to route to. It holds no
--                          owner privilege, reads nothing, and decides nothing.
--   app_private.<name>()   SECURITY DEFINER - the implementation, outside every
--                          exposed schema, search_path='', with its own auth.uid(),
--                          active-user and capability checks.
--
-- An invoker wrapper runs as the caller, so calling the private implementation
-- requires the caller to hold USAGE on app_private and EXECUTE on the function -
-- which `authenticated` does, exactly as it does for has_group_cap. No new
-- privilege is created, and no definer function remains in an exposed schema.

drop function if exists app_private.admin_set_user_status(bigint,text);

create or replace function app_private.admin_create_app_user(
  p_auth_user_id uuid,
  p_display_name text,
  p_role         text default 'maker',
  p_plant_code   text default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_id bigint; v_plant bigint; v_cap bigint; v_me bigint;
begin
  if (select auth.uid()) is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_group_cap('administer_users') then
    raise exception 'administer_users required' using errcode = '42501';
  end if;

  if p_role not in ('maker','checker','admin') then
    raise exception 'invalid role' using errcode = '22023';
  end if;
  if coalesce(btrim(p_display_name),'') = '' then
    raise exception 'display_name is required' using errcode = '22023';
  end if;
  if p_auth_user_id is null
     or not exists (select 1 from auth.users u where u.id = p_auth_user_id) then
    raise exception 'unknown authentication account' using errcode = '22023';
  end if;

  insert into public.app_users (auth_user_id, display_name, status)
  values (p_auth_user_id, btrim(p_display_name), 'active')
  returning id into v_id;

  if p_role = 'admin' then
    select id into v_cap from public.capabilities where capability_key = 'administer_users';
    insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
    values (v_id, v_cap, v_me);
  end if;

  if p_plant_code is not null then
    select id into v_plant from public.plants where plant_code = p_plant_code;
    if v_plant is null then
      raise exception 'unknown plant' using errcode = '22023';
    end if;
    insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
    select v_id, v_plant, c.id, v_me from public.capabilities c
     where c.capability_key in ('plant_access',
                                case when p_role = 'checker' then 'check_quote' else 'make_quote' end);
  end if;

  return v_id;
end $fn$;

create or replace function app_private.admin_set_user_status(p_app_user bigint, p_status text)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint;
begin
  if (select auth.uid()) is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_group_cap('administer_users') then
    raise exception 'administer_users required' using errcode = '42501';
  end if;
  if p_status not in ('invited','active','deactivated') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  if p_app_user = v_me and p_status <> 'active' then
    raise exception 'you cannot deactivate your own account' using errcode = '42501';
  end if;

  update public.app_users
     set status          = p_status,
         deactivated_at  = case when p_status = 'deactivated' then now() else null end,
         content_version = content_version + 1
   where id = p_app_user;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;
end $fn$;

drop function if exists public.admin_create_app_user(uuid,text,text,text);
drop function if exists public.admin_set_app_user_status(bigint,text);

create function public.admin_create_app_user(
  p_auth_user_id uuid, p_display_name text,
  p_role text default 'maker', p_plant_code text default null)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.admin_create_app_user(p_auth_user_id, p_display_name, p_role, p_plant_code);
$fn$;

create function public.admin_set_app_user_status(p_app_user bigint, p_status text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.admin_set_user_status(p_app_user, p_status);
$fn$;

do $$
declare f text;
begin
  foreach f in array array['public.admin_create_app_user(uuid,text,text,text)',
                           'public.admin_set_app_user_status(bigint,text)',
                           'app_private.admin_create_app_user(uuid,text,text,text)',
                           'app_private.admin_set_user_status(bigint,text)']
  loop
    execute format('revoke execute on function %s from public', f);
    execute format('revoke execute on function %s from anon', f);
    execute format('grant  execute on function %s to authenticated', f);
  end loop;
end $$;

create or replace function tests.definer_placement()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public','graphql_public') and p.prosecdef
        and p.proname <> 'rls_auto_enable'),
    0, 'P-1 no SECURITY DEFINER function of ours lives in an exposed schema');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('app_private','ref_private') and p.prosecdef
        and coalesce(array_to_string(p.proconfig,','),'') <> 'search_path=""'),
    0, 'P-2 every private definer pins search_path to empty');

  return next ok(
    (select not p.prosecdef from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public' and p.proname='admin_create_app_user'),
    'P-3 the public create shim is SECURITY INVOKER, not definer');
  return next ok(
    (select not p.prosecdef from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public' and p.proname='admin_set_app_user_status'),
    'P-4 the public status shim is SECURITY INVOKER, not definer');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public','app_private','ref_private','tests')
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
        and p.proname <> 'rls_auto_enable'),
    0, 'P-5 anon can execute none of our functions in any schema');
end $fn$;
revoke execute on function tests.definer_placement() from public;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.function_grants();
  return query select * from tests.definer_placement();
  return query select * from tests.admin_rpcs();
  return query select * from tests.no_legacy_identity_dependency();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from finish();
end $fn$;
revoke execute on function tests.run_all() from public;