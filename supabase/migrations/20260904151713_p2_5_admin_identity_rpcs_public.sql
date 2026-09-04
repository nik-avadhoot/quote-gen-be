-- P2-5: the two administrative identity operations the backend cannot perform as a
-- plain caller-context table write, exposed in `public` so PostgREST can route to them.
--
-- Why here and not app_private: app_private is deliberately NOT an exposed schema, so
-- nothing in it is reachable over /rest/v1/rpc. These two must be callable by the
-- backend on behalf of an administrator, so they live in public and carry their own
-- capability check. Exposure is safe precisely because the check is inside the
-- function - an authenticated non-admin calling them is refused.
--
-- Everything else the backend needs is an ordinary caller-context table operation:
--   read app_users / grants / capabilities / plants  -> existing SELECT policies
--   insert or revoke a capability grant              -> existing INSERT/UPDATE policies
--                                                       (both require administer_users)
--   self-edit display_name                           -> existing column grant + policy
-- so no further RPC surface is added.

-- app_users has NO insert policy for any role, by design: identity creation is not an
-- ordinary table write. This is the only route to a new application identity.
create or replace function public.admin_create_app_user(
  p_auth_user_id uuid,
  p_display_name text,
  p_role         text default 'maker',
  p_plant_code   text default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_id bigint; v_plant bigint; v_cap bigint; v_me bigint;
begin
  if not app_private.has_group_cap('administer_users') then
    raise exception 'administer_users required' using errcode = '42501';
  end if;
  if p_role not in ('maker','checker','admin') then
    raise exception 'invalid role' using errcode = '22023';
  end if;
  if coalesce(btrim(p_display_name),'') = '' then
    raise exception 'display_name is required' using errcode = '22023';
  end if;
  v_me := app_private.current_app_user();

  insert into public.app_users (auth_user_id, display_name, status)
  values (p_auth_user_id, btrim(p_display_name), 'active')
  returning id into v_id;

  -- role is expressed as capabilities, never as a column (CDM-05)
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

-- status changes carry a side effect (session revocation is the caller's job) and
-- app_users.status is deliberately outside the authenticated column grant.
create or replace function public.admin_set_app_user_status(p_app_user bigint, p_status text)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint;
begin
  if not app_private.has_group_cap('administer_users') then
    raise exception 'administer_users required' using errcode = '42501';
  end if;
  if p_status not in ('invited','active','deactivated') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  v_me := app_private.current_app_user();
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

do $$
declare f text;
begin
  foreach f in array array['public.admin_create_app_user(uuid,text,text,text)',
                           'public.admin_set_app_user_status(bigint,text)']
  loop
    execute format('revoke execute on function %s from public', f);
    execute format('revoke execute on function %s from anon', f);
    execute format('grant  execute on function %s to authenticated', f);
  end loop;
end $$;

-- Regression tests: exposure is safe only because the capability check is inside.
create or replace function tests.admin_rpcs()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform pg_catalog.set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000902","role":"authenticated"}', true);
  set local role authenticated;
  begin
    perform public.admin_create_app_user(
      '00000000-0000-0000-0000-000000000903'::uuid, 'probe', 'admin', null);
    reset role;
    return next fail('A-1 admin_create_app_user must require administer_users');
  exception when others then
    reset role;
    return next ok(true, 'A-1 admin_create_app_user refused without administer_users ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(1, 'deactivated');
    reset role;
    return next fail('A-2 admin_set_app_user_status must require administer_users');
  exception when others then
    reset role;
    return next ok(true, 'A-2 admin_set_app_user_status refused without administer_users ('||sqlstate||')');
  end;

  return next ok(not pg_catalog.has_function_privilege(
      'anon','public.admin_create_app_user(uuid,text,text,text)','EXECUTE'),
    'A-3 anon cannot execute admin_create_app_user');
  return next ok(not pg_catalog.has_function_privilege(
      'anon','public.admin_set_app_user_status(bigint,text)','EXECUTE'),
    'A-4 anon cannot execute admin_set_app_user_status');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prosecdef
        and coalesce(array_to_string(p.proconfig,','),'') <> 'search_path=""'
        and p.proname <> 'rls_auto_enable'),
    0, 'A-5 every SECURITY DEFINER function exposed in public pins search_path');
end $fn$;

revoke execute on function tests.admin_rpcs() from public;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.function_grants();
  return query select * from tests.admin_rpcs();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from finish();
end $fn$;

revoke execute on function tests.run_all() from public;