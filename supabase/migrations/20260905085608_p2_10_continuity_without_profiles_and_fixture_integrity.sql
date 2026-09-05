-- P2-10: prove identity continuity survives the REMOVAL of public.profiles,
-- and prove the fixtures leave no synthetic identity behind.
--
-- My earlier packets asserted that both legacy identities had to bootstrap
-- BEFORE profiles could be removed. That was wrong, and the Product Owner was
-- right to challenge it. Continuity does not depend on an app_users row already
-- existing; it depends on the bootstrap path being reachable and on its inputs
-- surviving removal. Its inputs are auth.users and app_private.pending_invitations.
-- Neither is a removal target. An unconsumed invitation IS the approved
-- continuity mechanism, so requiring a sign-in merely to manufacture a row was
-- me demanding evidence the design does not need.
--
-- CN-2 makes this a test rather than an argument: public.profiles is renamed
-- out of existence, the full invited-bootstrap path is executed against a world
-- where the table genuinely is not there, and the table is renamed back. DDL is
-- transactional in Postgres, so an abort at any point restores it, and the
-- exception handler restores it on a caught failure. Nothing reads profiles
-- (D-1), so the window affects no other caller.

create or replace function tests.continuity_without_profiles()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_auth uuid; v_claims text; v_id bigint; v_email text; v_renamed boolean := false;
begin
  -- Static: nothing on the login path so much as names the table.
  return next is(
    (select count(*)::int
       from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where ((n.nspname = 'app_private'
              and p.proname in ('bootstrap_app_user','current_app_user',
                                'has_group_cap','has_plant_cap','is_plant_member'))
          or (n.nspname = 'public'
              and p.proname in ('bootstrap_app_user','admin_create_app_user',
                                'admin_set_app_user_status')))
        and p.prosrc ilike '%profiles%'),
    0, 'CN-1 no function on the sign-in or administration path references profiles');

  v_auth  := tests.__fixture_auth_uid();
  v_email := (select u.email from auth.users u where u.id = v_auth);

  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_cn_maker', false);

  alter table public.profiles rename to profiles__cn_absent;
  v_renamed := true;

  return next ok(
    not exists (select 1 from pg_catalog.pg_class c
                  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'public' and c.relname = 'profiles'),
    'CN-2 public.profiles is genuinely ABSENT for the rest of this test');

  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_id := public.bootstrap_app_user();
  reset role;

  return next ok(v_id is not null,
    'CN-3 an invited identity completes first sign-in with profiles REMOVED');
  return next is((select status from public.app_users where id = v_id), 'active',
    'CN-4 the resulting identity is active - no successor row was needed beforehand');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  return next is(app_private.current_app_user(), v_id,
    'CN-5 the caller resolves to that identity with profiles removed');
  return next ok(not app_private.has_group_cap('administer_users'),
    'CN-6 and holds no capability it was not granted');
  reset role;

  alter table public.profiles__cn_absent rename to profiles;
  v_renamed := false;

  return next ok(
    exists (select 1 from pg_catalog.pg_class c
              join pg_catalog.pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relname = 'profiles'),
    'CN-7 the table is restored - this test leaves live state unchanged');
  return next is(
    (select count(*)::int from pg_catalog.pg_policy pol
      where pol.polrelid = 'public.profiles'::regclass), 3,
    'CN-8 its three policies survived the rename');
  return next is(
    (select count(*)::int from pg_catalog.pg_trigger t
      where t.tgrelid = 'public.profiles'::regclass and not t.tgisinternal), 1,
    'CN-9 and its updated_at trigger survived');

  delete from app_private.pending_invitations where invite_email = v_email;
  perform tests.__drop_synthetic_auth(v_auth);
  return;

exception when others then
  reset role;
  if v_renamed then
    alter table public.profiles__cn_absent rename to profiles;
  end if;
  delete from app_private.pending_invitations where invite_email = v_email;
  perform tests.__drop_synthetic_auth(v_auth);
  raise;
end $fn$;

create or replace function tests.synthetic_fixture_integrity()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_real uuid;
begin
  perform tests.__sweep_synthetic_auth();

  return next is(
    (select count(*)::int from auth.users
      where email like 'p2-synthetic-%@fixture.invalid'), 0,
    'SF-1 no synthetic fixture identity survives the suite');
  return next is(
    (select count(*)::int from public.app_users a
       join auth.users u on u.id = a.auth_user_id
      where u.email like 'p2-synthetic-%@fixture.invalid'), 0,
    'SF-2 and no application identity is left attached to one');

  -- fail closed: removal must refuse anything it cannot prove it owns
  select u.id into v_real from auth.users u
   where u.email not like 'p2-synthetic-%@fixture.invalid' limit 1;
  begin
    perform tests.__drop_synthetic_auth(v_real);
    return next fail('SF-3 removing a NON-synthetic identity must be refused');
  exception when others then
    return next ok(true,
      'SF-3 the fixture refuses to remove a non-synthetic identity ('||sqlstate||')');
  end;

  return next ok(
    (select count(*) from auth.users
      where email not like 'p2-synthetic-%@fixture.invalid') = 2,
    'SF-4 exactly the two real authentication accounts remain, untouched');
  return next ok(
    (select count(*)::int from public.profiles) = 2,
    'SF-5 and the two legacy profiles rows are untouched by the whole suite');
end $fn$;

revoke all on function tests.continuity_without_profiles() from public;
revoke all on function tests.continuity_without_profiles() from anon;
revoke all on function tests.continuity_without_profiles() from authenticated;
revoke all on function tests.synthetic_fixture_integrity() from public;
revoke all on function tests.synthetic_fixture_integrity() from anon;
revoke all on function tests.synthetic_fixture_integrity() from authenticated;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  perform tests.__sweep_synthetic_auth();
  return query select * from tests.access_model();
  return query select * from tests.function_grants();
  return query select * from tests.definer_placement();
  return query select * from tests.admin_rpcs();
  return query select * from tests.no_legacy_identity_dependency();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.bootstrap_routing();
  return query select * from tests.continuity_without_profiles();
  return query select * from tests.multi_plant_access();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from finish();
end $fn$;

revoke all on function tests.run_all() from public;
revoke all on function tests.run_all() from anon;
revoke all on function tests.run_all() from authenticated;