-- P2-10: S-4 asserted the wrong actor.
--
-- bootstrap_app_user() seeds the edit_lock_stale_seconds baseline with
-- `on conflict do nothing`, because the baseline is a group-scope singleton
-- that must be created once and never overwritten. S-4 asserted the row was
-- attributed to the FIXTURE's administrator - true only while no real
-- administrator had ever bootstrapped. Now that one has, the real row wins the
-- conflict, the fixture's insert is correctly skipped, and S-4 failed.
--
-- The property S-4 is named for is "real admin attribution": that the baseline
-- is attributed to an actual administrator rather than to a system actor or a
-- null. That is now what it asserts, for whichever administrator seeded it.
--
-- Patched in place with an explicit match guard rather than retyping the whole
-- 180-line fixture, so the change is exactly one assertion and cannot silently
-- no-op if the source ever moves.

do $patch$
declare
  v_src text;
  v_old text := E'  return next ok(exists (select 1 from public.operational_settings\n'
                 '                          where setting_key = ''edit_lock_stale_seconds''\n'
                 '                            and created_by = v_admin and setting_value = to_jsonb(900)),\n'
                 '                 ''S-4 edit_lock_stale_seconds seeded with real admin attribution'');';
  v_new text := E'  return next ok(exists (select 1 from public.operational_settings os\n'
                 '                           join public.app_users au2 on au2.id = os.created_by\n'
                 '                           join public.group_capability_grants gg on gg.app_user_id = au2.id\n'
                 '                           join public.capabilities cc on cc.id = gg.capability_id\n'
                 '                          where os.setting_key = ''edit_lock_stale_seconds''\n'
                 '                            and os.setting_value = to_jsonb(900)\n'
                 '                            and cc.capability_key = ''administer_users''\n'
                 '                            and gg.status = ''active''),\n'
                 '                 ''S-4 edit_lock_stale_seconds seeded with real admin attribution'');';
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'tests' and p.proname = 'fixtures_matrix';

  if v_src is null then
    raise exception 'tests.fixtures_matrix() not found';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'S-4 assertion not found verbatim in tests.fixtures_matrix() - refusing to patch blind';
  end if;

  v_src := replace(v_src, v_old, v_new);

  execute format(
    'create or replace function tests.fixtures_matrix() returns setof text '
    'language plpgsql set search_path = extensions, pg_catalog as %L', v_src);
end
$patch$;

revoke all on function tests.fixtures_matrix() from public;
revoke all on function tests.fixtures_matrix() from anon;
revoke all on function tests.fixtures_matrix() from authenticated;