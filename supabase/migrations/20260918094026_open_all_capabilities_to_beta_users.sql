-- Beta verification: give Sonali (3535) and Snehal (3536) every capability.
--
-- Product Owner ruling, 2026-09-18: during this verification phase every user
-- must see every screen and be able to exercise every intended workflow, so
-- access is not restricted by role. Each of the two beta users receives the
-- same complete set app user 44 holds: every group capability, and every
-- plant capability at every active Producing Plant. This supersedes the
-- earlier NAG-only minimal fence for these two users; it is reversible by the
-- same operation (the beta kill switch).
--
-- Runs, as before, through the governed set_user_capabilities operation under
-- the Product Owner's own identity (app user 44), with each user's
-- compare-and-swap version, and refuses unless each user is exactly as last
-- verified.

do $open$
declare
  v_admin_auth uuid;
  v_group text[];
  v_plant jsonb;
  r record;
  v_pc int;
  v_gc int;
begin
  select u.auth_user_id into strict v_admin_auth
    from public.app_users u
    join auth.users a on a.id = u.auth_user_id
   where u.id = 44 and lower(a.email) = 'nikunj@avadhootpacks.in' and u.status = 'active';

  select array_agg(capability_key order by capability_key) into v_group
    from public.capabilities where scope_kind = 'group';

  select jsonb_object_agg(p.id::text, caps.keys) into v_plant
    from public.plants p
    cross join (select jsonb_agg(capability_key order by capability_key) as keys
                  from public.capabilities where scope_kind = 'plant') caps
   where p.status = 'active';

  for r in select * from (values
      (3535::bigint, 'sales.01@avadhootpacks.in', 1),
      (3536::bigint, 'marketing@avadhootpacks.in', 2)) as t(id, email, ver)
  loop
    if not exists (
      select 1 from public.app_users u join auth.users a on a.id = u.auth_user_id
       where u.id = r.id and lower(a.email) = r.email
         and u.status = 'active' and u.content_version = r.ver
    ) then
      raise exception 'app user % is not as last verified (expected version %)', r.id, r.ver;
    end if;
  end loop;

  perform pg_catalog.set_config('request.jwt.claims',
    jsonb_build_object('sub', v_admin_auth::text, 'role', 'authenticated',
                       'email', 'nikunj@avadhootpacks.in')::text, true);
  set local role authenticated;

  perform public.set_user_capabilities(3535, 1, v_group, v_plant);
  perform public.set_user_capabilities(3536, 2, v_group, v_plant);

  reset role;

  -- Each now holds exactly what app user 44 holds.
  for r in select unnest(array[3535, 3536]::bigint[]) as id loop
    select count(*) into v_pc from (
      select plant_id, capability_id from public.plant_capability_grants where app_user_id = r.id and status = 'active'
      except
      select plant_id, capability_id from public.plant_capability_grants where app_user_id = 44 and status = 'active') d;
    select count(*) + v_pc into v_pc from (
      select plant_id, capability_id from public.plant_capability_grants where app_user_id = 44 and status = 'active'
      except
      select plant_id, capability_id from public.plant_capability_grants where app_user_id = r.id and status = 'active') d;
    select count(*) into v_gc from (
      (select capability_id from public.group_capability_grants where app_user_id = r.id and status = 'active'
       except
       select capability_id from public.group_capability_grants where app_user_id = 44 and status = 'active')
      union all
      (select capability_id from public.group_capability_grants where app_user_id = 44 and status = 'active'
       except
       select capability_id from public.group_capability_grants where app_user_id = r.id and status = 'active')) d;
    if v_pc <> 0 or v_gc <> 0 then
      raise exception 'app user % does not match app user 44 after the grant', r.id;
    end if;
  end loop;
end $open$;
