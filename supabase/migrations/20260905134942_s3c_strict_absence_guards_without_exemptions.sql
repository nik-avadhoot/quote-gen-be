-- S3(c) follow-up: D-4 fired on the two guard functions themselves, because a
-- guard that polices a name necessarily contains that name. The tempting fix is
-- an exemption list; that is what the pre-removal D-1 needed and it always cost
-- reach. Now that the objects are gone there is a better option: assemble the
-- literals at runtime, so NO function anywhere contains them and the guard can
-- stay strict at zero with no exemptions at all.
--
-- Also replaces CN-7, which I wrote as `count = count` - a tautology that
-- asserts nothing. It now states a real post-S3(c) property: app_users is the
-- single link between authentication and the application.

create or replace function tests.no_legacy_identity_dependency()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tbl  text := 'pro' || 'files';                 -- the removed table
  v_qtbl text := 'public.' || v_tbl;               -- qualified, as code would write it
  v_helper text := 'is' || '_admin';               -- the removed admin helper
  v_touch  text := 'set' || '_updated_at';         -- the removed trigger function
begin
  return next is(
    (select count(*)::int from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = v_tbl),
    0, 'D-1 the legacy identity table no longer exists');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app_private' and p.proname = v_helper),
    0, 'D-2 the legacy admin helper no longer exists');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = v_touch),
    0, 'D-3 the legacy updated_at function no longer exists');

  -- Strict, and with NO exemption list: nothing anywhere may name either object.
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('tests','app_private','ref_private','public')
        and (p.prosrc ilike '%'||v_qtbl||'%' or p.prosrc ilike '%'||v_helper||'%')),
    0, 'D-4 no function in any of our schemas references the removed objects');

  return next is(
    (select count(*)::int from pg_catalog.pg_policy pol
      where coalesce(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid),'') ilike '%'||v_helper||'%'
         or coalesce(pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid),'') ilike '%'||v_helper||'%'),
    0, 'D-5 no policy anywhere depends on the removed admin helper');

  return next is(
    (select count(*)::int from pg_catalog.pg_trigger t
      where not t.tgisinternal and t.tgname = v_tbl || '_' || v_touch),
    0, 'D-6 the legacy updated_at trigger is gone');

  return next is(
    (select count(*)::int from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
    0, 'D-7 every remaining table in public still has RLS enabled');
end $fn$;

create or replace function tests.continuity_without_profiles()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_auth uuid; v_claims text; v_id bigint; v_email text;
  v_tbl text := 'pro' || 'files';
begin
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
        and p.prosrc ilike '%'||v_tbl||'%'),
    0, 'CN-1 no function on the sign-in or administration path names the legacy table');

  return next ok(
    not exists (select 1 from pg_catalog.pg_class c
                  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'public' and c.relname = v_tbl),
    'CN-2 the legacy identity table is ABSENT - removed by S3(c), not simulated');

  v_auth  := tests.__fixture_auth_uid();
  v_email := (select u.email from auth.users u where u.id = v_auth);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_cn_maker', false);

  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_id := public.bootstrap_app_user();
  reset role;

  return next ok(v_id is not null,
    'CN-3 an invited identity completes first sign-in with the legacy table REMOVED');
  return next is((select status from public.app_users where id = v_id), 'active',
    'CN-4 the resulting identity is active');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  return next is(app_private.current_app_user(), v_id,
    'CN-5 the caller resolves to that identity');
  return next ok(not app_private.has_group_cap('administer_users'),
    'CN-6 and holds no capability it was not granted');
  reset role;

  -- The real post-S3(c) property: exactly one table links authentication to the
  -- application, and it is app_users.
  return next is(
    (select count(*)::int from pg_catalog.pg_constraint con
       join pg_catalog.pg_class c  on c.oid  = con.conrelid
       join pg_catalog.pg_class rf on rf.oid = con.confrelid
       join pg_catalog.pg_namespace rn on rn.oid = rf.relnamespace
      where con.contype = 'f' and rn.nspname = 'auth' and rf.relname = 'users'
        and c.relname <> 'app_users'),
    0, 'CN-7 app_users is the SOLE link between authentication and the application');

  delete from app_private.pending_invitations where invite_email = v_email;
  perform tests.__drop_synthetic_auth(v_auth);
  return;

exception when others then
  reset role;
  delete from app_private.pending_invitations where invite_email = v_email;
  perform tests.__drop_synthetic_auth(v_auth);
  raise;
end $fn$;

revoke all on function tests.no_legacy_identity_dependency() from public, anon, authenticated;
revoke all on function tests.continuity_without_profiles() from public, anon, authenticated;