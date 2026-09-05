-- P2-8: prove the login bootstrap path, and stop the fixtures from ever
-- mutating a real identity.
--
-- Part 1 - tests.__fixture_auth_uid() is now collision-proof.
--
-- It returned `select id from auth.users order by created_at limit 1` - the
-- OLDEST auth account, which is the real administrator. That was harmless only
-- while app_users held no persistent rows. The moment P2-8 lets that
-- administrator actually bootstrap, it becomes a live hazard:
-- fixtures_matrix calls bootstrap_app_user() with that uid, gets the REAL
-- identity id back instead of creating a fixture one, and then executes
--   update public.app_users set status='deactivated', auth_user_id=null ...
-- against it. __cleanup_fixtures only deletes rows whose display_name is like
-- '__p2%', so the real row is left deactivated with its auth link nulled -
-- permanently locked out, with the invitation already consumed and no second
-- administrator able to issue another. Running the test suite would strand the
-- administrator. Nothing detected this because the collision cannot happen
-- while app_users is empty, which is exactly the state every prior run saw.
--
-- The fixture now takes an auth account that owns NO app_users row, and raises
-- a directive error rather than proceeding if none is free. A loudly failing
-- gate is the correct outcome there; silently mutating a real identity is not.
-- When both accounts become real identities this will fail, and the remedy is a
-- dedicated fixture auth account - a Product Owner provisioning decision, not
-- something to infer here.

create or replace function tests.__fixture_auth_uid()
returns uuid language plpgsql security definer set search_path = '' as $fn$
declare v uuid;
begin
  select u.id into v
    from auth.users u
   where not exists (select 1 from public.app_users a where a.auth_user_id = u.id)
   order by u.created_at
   limit 1;
  if v is null then
    raise exception 'no free auth account for fixtures - every auth.users row already owns an app_users identity; provision a dedicated fixture auth account rather than letting the destructive fixtures run against a real one'
      using errcode = '55000';
  end if;
  return v;
end $fn$;

revoke all on function tests.__fixture_auth_uid() from public;
revoke all on function tests.__fixture_auth_uid() from anon;
revoke all on function tests.__fixture_auth_uid() from authenticated;

-- Part 2 - BR-*: the first-sign-in path as the application actually reaches it,
-- through public.bootstrap_app_user(), not the private implementation. Every
-- prior bootstrap test called app_private directly, which is precisely why a
-- missing public route passed every gate.

create or replace function tests.bootstrap_routing()
returns setof text language plpgsql set search_path = 'extensions, pg_catalog' as $fn$
declare
  v_auth uuid; v_claims text; v_id bigint; v_id2 bigint; v_id3 bigint;
  v_email text := 'p2-shim@example.invalid';
begin
  return next ok(
    (select not p.prosecdef from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public' and p.proname='bootstrap_app_user'),
    'BR-1 the public bootstrap shim is SECURITY INVOKER, not definer');

  return next ok(
    not (select pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
           from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
          where n.nspname='public' and p.proname='bootstrap_app_user'),
    'BR-2 anon cannot execute the public bootstrap shim');

  return next ok(
    (select pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')
       from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public' and p.proname='bootstrap_app_user'),
    'BR-3 authenticated CAN execute it - the route the login flow needs exists');

  v_auth := tests.__fixture_auth_uid();
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);

  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_shim_admin', true);

  -- refusals first, while no identity exists for this uid
  begin
    perform pg_catalog.set_config('request.jwt.claims', null, true);
    set local role authenticated;
    perform public.bootstrap_app_user();
    reset role;
    return next fail('BR-4 unauthenticated bootstrap through the shim must be refused');
  exception when others then
    reset role;
    return next ok(true, 'BR-4 unauthenticated bootstrap through the shim refused ('||sqlstate||')');
  end;

  begin
    perform pg_catalog.set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth,
             'wrong-address@example.invalid'), true);
    set local role authenticated;
    perform public.bootstrap_app_user();
    reset role;
    return next fail('BR-5 a caller whose verified email does not match the invitation must be refused');
  exception when others then
    reset role;
    return next ok(true, 'BR-5 WRONG-EMAIL caller refused - the invitation binds to the verified email ('||sqlstate||')');
  end;

  begin
    perform pg_catalog.set_config('request.jwt.claims',
      '{"sub":"00000000-0000-0000-0000-000000000801","role":"authenticated",'
      '"email":"uninvited@example.invalid"}', true);
    set local role authenticated;
    perform public.bootstrap_app_user();
    reset role;
    return next fail('BR-6 an uninvited authenticated caller must be refused');
  exception when others then
    reset role;
    return next ok(true, 'BR-6 UNINVITED authenticated caller refused - no public registration ('||sqlstate||')');
  end;

  return next is((select count(*)::int from public.app_users where auth_user_id = v_auth), 0,
                 'BR-7 no identity was created by any refused attempt');

  -- success, through the public route
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_id := public.bootstrap_app_user();
  reset role;

  return next ok(v_id is not null, 'BR-8 invited caller completes bootstrap THROUGH THE PUBLIC SHIM');
  return next is((select status from public.app_users where id = v_id), 'active',
                 'BR-9 the resulting identity persists and is active');
  return next is((select count(*)::int from public.app_users where auth_user_id = v_auth), 1,
                 'BR-10 exactly one identity exists for that authentication account');
  return next is((select count(*)::int from public.group_capability_grants g
                    join public.capabilities c on c.id = g.capability_id
                   where g.app_user_id = v_id and c.capability_key = 'administer_users'), 1,
                 'BR-11 exactly one administer_users grant, and only that capability');
  return next is((select count(*)::int from public.group_capability_grants
                   where app_user_id = v_id), 1,
                 'BR-12 no capability beyond the approved bootstrap grant');
  return next ok((select consumed_at is not null from app_private.pending_invitations
                   where invite_email = v_email),
                 'BR-13 the invitation is consumed exactly once');

  -- idempotence: repeated login must not duplicate identity or grants
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_id2 := public.bootstrap_app_user();
  reset role;
  return next is(v_id2, v_id, 'BR-14 repeated login is idempotent - the same identity, never a second');
  return next is((select count(*)::int from public.app_users where auth_user_id = v_auth), 1,
                 'BR-15 repeated login creates no second identity');
  return next is((select count(*)::int from public.group_capability_grants
                   where app_user_id = v_id), 1,
                 'BR-16 repeated login creates no second grant');

  -- a deactivated identity must not be able to re-bootstrap itself
  update public.app_users set status = 'deactivated', deactivated_at = now() where id = v_id;
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_id3 := public.bootstrap_app_user();
  reset role;
  return next is(v_id3, v_id, 'BR-17 a DEACTIVATED identity cannot re-bootstrap into a new one');
  return next is((select status from public.app_users where id = v_id), 'deactivated',
                 'BR-18 re-bootstrap does not reactivate a deactivated identity');
  return next is((select count(*)::int from public.group_capability_grants
                   where app_user_id = v_id), 1,
                 'BR-19 re-bootstrap grants a deactivated identity nothing further');

  delete from public.operational_settings
   where created_by in (select id from public.app_users where display_name like '\_\_p2\_shim%');
  delete from public.group_capability_grants
   where app_user_id in (select id from public.app_users where display_name like '\_\_p2\_shim%');
  delete from app_private.pending_invitations where invite_email = v_email;
  delete from public.app_users where display_name like '\_\_p2\_shim%';
  return;

exception when others then
  reset role;
  delete from public.operational_settings
   where created_by in (select id from public.app_users where display_name like '\_\_p2\_shim%');
  delete from public.group_capability_grants
   where app_user_id in (select id from public.app_users where display_name like '\_\_p2\_shim%');
  delete from app_private.pending_invitations where invite_email = v_email;
  delete from public.app_users where display_name like '\_\_p2\_shim%';
  raise;
end $fn$;

revoke all on function tests.bootstrap_routing() from public;
revoke all on function tests.bootstrap_routing() from anon;
revoke all on function tests.bootstrap_routing() from authenticated;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = 'extensions, pg_catalog' as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.function_grants();
  return query select * from tests.definer_placement();
  return query select * from tests.admin_rpcs();
  return query select * from tests.no_legacy_identity_dependency();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.bootstrap_routing();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from finish();
end $fn$;

revoke all on function tests.run_all() from public;
revoke all on function tests.run_all() from anon;
revoke all on function tests.run_all() from authenticated;