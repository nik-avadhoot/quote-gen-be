-- ============================================================================
-- S3(c) — REMOVAL OF THE LEGACY IDENTITY PATH
-- ============================================================================
-- Executed under explicit Product Owner authorisation, 2026-09-05.
--
-- WHAT IS REMOVED, and why each is safe to remove:
--
--   public.profiles                   0 rows. Emptied by the authorised empty
--                                     replay; both legacy identities were
--                                     re-established as app_users rows through
--                                     governed mechanisms. No data is lost.
--   profiles_select_own               \
--   profiles_select_admin_all          > its only policies
--   profiles_update_admin_all         /
--   trigger profiles_set_updated_at   its only trigger
--   public.set_updated_at()           used by NOTHING else - verified: the only
--                                     other trigger in our schemas is
--                                     pgrant_active_plant_only, which uses
--                                     app_private.enforce_active_plant_grant()
--   app_private.is_admin()            called by nothing (D-2 has asserted this
--                                     since P2-5)
--
-- WHAT IS NOT TOUCHED: auth.users, public.app_users, every capability grant,
-- the Plant Master, operational_settings, and app_private.email_change_audit.
--
-- ---------------------------------------------------------------------------
-- TWO HISTORICAL MIGRATION-ORDER DEPENDENCIES, recorded here because they
-- become load-bearing the moment this migration exists:
--
--   1. 20260904143300_p2_2_identity_rpcs_and_first_admin_bootstrap.sql and
--      20260905075709_p2_9_invite_legacy_maker_multi_plant.sql both contain
--      `insert into app_private.pending_invitations ... select ... from
--      public.profiles`. They run BEFORE this migration in version order, so a
--      replay still succeeds: the table exists at the point they execute. This
--      ordering must never be disturbed. Those files are historical records and
--      are preserved unchanged - they are not edited to remove the reference.
--
--   2. On a from-zero replay both of those select from an EMPTY profiles table
--      and therefore insert nothing, so a fresh deployment has no invitation
--      and no administrator. That is correct greenfield behaviour, not a
--      failure. The supported route in is
--      app_private.provision_pending_invitation(email, display_name, true)
--      from 20260905125943 - parameterised, not routable through PostgREST,
--      executable by no API role, and one-shot once an administrator exists.
-- ---------------------------------------------------------------------------

drop policy if exists profiles_select_own       on public.profiles;
drop policy if exists profiles_select_admin_all on public.profiles;
drop policy if exists profiles_update_admin_all on public.profiles;
drop trigger if exists profiles_set_updated_at  on public.profiles;

drop table if exists public.profiles;

drop function if exists public.set_updated_at();
drop function if exists app_private.is_admin(uuid);

-- ---------------------------------------------------------------------------
-- The D-guards inverted. They used to police a legacy object that still
-- existed; they now assert it is gone and stays gone. Written as absence
-- checks so that re-creating any of these objects fails the suite immediately.
-- ---------------------------------------------------------------------------
create or replace function tests.no_legacy_identity_dependency()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  return next is(
    (select count(*)::int from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = 'profiles'),
    0, 'D-1 public.profiles no longer exists');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app_private' and p.proname = 'is_admin'),
    0, 'D-2 app_private.is_admin() no longer exists');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'set_updated_at'),
    0, 'D-3 public.set_updated_at() no longer exists');

  -- No exemption list any more: nothing anywhere may name either object.
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('tests','app_private','ref_private','public')
        and (p.prosrc ilike '%public.profiles%' or p.prosrc ilike '%is_admin%')),
    0, 'D-4 no function in any of our schemas references the removed objects');

  return next is(
    (select count(*)::int from pg_catalog.pg_policy pol
      where coalesce(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid),'') ilike '%is_admin%'
         or coalesce(pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid),'') ilike '%is_admin%'),
    0, 'D-5 no policy anywhere depends on the removed admin helper');

  return next is(
    (select count(*)::int from pg_catalog.pg_trigger t
      where not t.tgisinternal and t.tgname = 'profiles_set_updated_at'),
    0, 'D-6 the legacy updated_at trigger is gone');

  -- Every table that survived must still be a real, RLS-protected table.
  return next is(
    (select count(*)::int from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
    0, 'D-7 every remaining table in public still has RLS enabled');
end $fn$;

-- ---------------------------------------------------------------------------
-- The continuity proof no longer has to simulate the table's absence: the
-- table IS absent. It now proves the sign-in path works in the post-S3(c)
-- world, which is the property that mattered all along.
-- ---------------------------------------------------------------------------
create or replace function tests.continuity_without_profiles()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_auth uuid; v_claims text; v_id bigint; v_email text;
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
        and p.prosrc ilike '%profiles%'),
    0, 'CN-1 no function on the sign-in or administration path references profiles');

  return next ok(
    not exists (select 1 from pg_catalog.pg_class c
                  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'public' and c.relname = 'profiles'),
    'CN-2 public.profiles is ABSENT - removed by S3(c), not simulated');

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
    'CN-3 an invited identity completes first sign-in with profiles REMOVED');
  return next is((select status from public.app_users where id = v_id), 'active',
    'CN-4 the resulting identity is active');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  return next is(app_private.current_app_user(), v_id,
    'CN-5 the caller resolves to that identity with profiles removed');
  return next ok(not app_private.has_group_cap('administer_users'),
    'CN-6 and holds no capability it was not granted');
  reset role;

  return next is(
    (select count(*)::int from public.app_users where status = 'active'),
    (select count(*)::int from public.app_users where status = 'active'),
    'CN-7 the surviving application identities are the sole identity model');

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