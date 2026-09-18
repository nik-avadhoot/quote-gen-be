-- Beta: add make_quote at NAG to Snehal (app user 3536, marketing@avadhootpacks.in).
--
-- Product Owner ruling, 2026-09-18: Snehal prepares quotes as well as checking
-- quotes prepared by others. Maker/Checker separation is per Quote and checked
-- daily (beta operating sheet); the database permits dual holders to self-approve.
--
-- The Product Owner cannot operate Users/Access tooling and asked SR DEV to
-- conclude this. As with Wave B, the governed operation runs under the Product
-- Owner's own authenticated identity (app user 44, administer_users), through
-- the same set_user_capabilities RPC the Users/Access route calls, with its
-- compare-and-swap version. The complete resulting set is stated explicitly.

do $grant$
declare
  v_admin_auth uuid;
  v_nag bigint;
  v_caps text;
begin
  select u.auth_user_id into strict v_admin_auth
    from public.app_users u
    join auth.users a on a.id = u.auth_user_id
   where u.id = 44 and lower(a.email) = 'nikunj@avadhootpacks.in' and u.status = 'active';

  select id into strict v_nag from public.plants where plant_code = 'NAG' and status = 'active';

  -- Exactly the state verified before this change, or nothing happens.
  if not exists (
    select 1 from public.app_users u join auth.users a on a.id = u.auth_user_id
     where u.id = 3536 and lower(a.email) = 'marketing@avadhootpacks.in'
       and u.status = 'active' and u.content_version = 1
  ) then
    raise exception 'app user 3536 is not the verified Snehal account at content version 1';
  end if;

  select string_agg(p.plant_code || ':' || c.capability_key, ',' order by p.plant_code, c.capability_key)
    into v_caps
    from public.plant_capability_grants g
    join public.plants p on p.id = g.plant_id
    join public.capabilities c on c.id = g.capability_id
   where g.app_user_id = 3536 and g.status = 'active';
  if v_caps is distinct from 'NAG:check_quote,NAG:plant_access'
     or exists (select 1 from public.group_capability_grants
                 where app_user_id = 3536 and status = 'active') then
    raise exception 'Snehal''s capabilities changed since verification: %', v_caps;
  end if;

  perform pg_catalog.set_config('request.jwt.claims',
    jsonb_build_object('sub', v_admin_auth::text, 'role', 'authenticated',
                       'email', 'nikunj@avadhootpacks.in')::text, true);
  set local role authenticated;

  perform public.set_user_capabilities(
    3536, 1, '{}'::text[],
    jsonb_build_object(v_nag::text, jsonb_build_array('plant_access', 'check_quote', 'make_quote')));

  reset role;

  select string_agg(p.plant_code || ':' || c.capability_key, ',' order by p.plant_code, c.capability_key)
    into v_caps
    from public.plant_capability_grants g
    join public.plants p on p.id = g.plant_id
    join public.capabilities c on c.id = g.capability_id
   where g.app_user_id = 3536 and g.status = 'active';
  if v_caps is distinct from 'NAG:check_quote,NAG:make_quote,NAG:plant_access' then
    raise exception 'unexpected capability set after grant: %', v_caps;
  end if;
end $grant$;
