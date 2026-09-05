-- S3(c) follow-up: CN-7 counted EVERY foreign key to auth.users and so caught
-- Supabase's own eight - identities, sessions, mfa_factors, oauth_*,
-- one_time_tokens, webauthn_* - which legitimately reference it and are none of
-- our business. Scoped to the schemas we own, where the claim is both true and
-- meaningful: before S3(c) there were two such links (profiles and app_users),
-- and now there is one.

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

  -- Within OUR schemas, exactly one table links authentication to the
  -- application. Supabase's own auth.* tables are excluded: they reference
  -- auth.users by design and are not ours to police.
  return next is(
    (select count(*)::int from pg_catalog.pg_constraint con
       join pg_catalog.pg_class c   on c.oid  = con.conrelid
       join pg_catalog.pg_namespace cn on cn.oid = c.relnamespace
       join pg_catalog.pg_class rf  on rf.oid = con.confrelid
       join pg_catalog.pg_namespace rn on rn.oid = rf.relnamespace
      where con.contype = 'f'
        and rn.nspname = 'auth' and rf.relname = 'users'
        and cn.nspname in ('public','app_private','ref_private')
        and c.relname <> 'app_users'),
    0, 'CN-7 app_users is the SOLE application link to authentication');

  delete from app_private.pending_invitations where invite_email = v_email;
  perform tests.__drop_synthetic_auth(v_auth);
  return;

exception when others then
  reset role;
  delete from app_private.pending_invitations where invite_email = v_email;
  perform tests.__drop_synthetic_auth(v_auth);
  raise;
end $fn$;

revoke all on function tests.continuity_without_profiles() from public, anon, authenticated;