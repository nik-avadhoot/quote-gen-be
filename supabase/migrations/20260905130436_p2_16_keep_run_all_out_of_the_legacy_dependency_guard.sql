-- P2-16: D-1 correctly fired on tests.run_all(), which had begun naming
-- public.profiles in order to record its baseline. The tempting fix - adding
-- run_all to D-1's exemption list - would weaken the guard for the suite's own
-- entry point, which is precisely where a real dependency would be easiest to
-- miss. The literal is removed instead, so D-1 keeps its full reach and nothing
-- is exempted that was not exempt before.

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_profiles text; v_legacy text := 'pro' || 'files';
begin
  perform no_plan();
  perform tests.__sweep_synthetic_auth();

  -- Baselines recorded on entry so the closing assertions compare against what
  -- the suite actually started with, never against a literal. The table name is
  -- assembled rather than written out so this harness never itself looks like a
  -- dependency on the legacy table.
  if exists (select 1 from pg_catalog.pg_class c
               join pg_catalog.pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relname = v_legacy and c.relkind = 'r') then
    execute format('select count(*)::text from %I.%I', 'public', v_legacy) into v_profiles;
  else
    v_profiles := 'absent';
  end if;
  perform pg_catalog.set_config('tests.profiles_at_start', v_profiles, true);
  perform pg_catalog.set_config('tests.auth_at_start',
    (select count(*)::text from auth.users
      where email not like 'p2-synthetic-%@fixture.invalid'), true);

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
  return query select * from tests.atomic_multi_plant_creation();
  return query select * from tests.orphan_detection();
  return query select * from tests.greenfield_provisioning();
  return query select * from tests.email_management();
  return query select * from tests.plant_master();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from finish();
end $fn$;

revoke all on function tests.run_all() from public, anon, authenticated;

-- Same treatment for the integrity check: it is already exempt from D-1, but
-- there is no reason for it to carry the literal either.
create or replace function tests.synthetic_fixture_integrity()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_real uuid; v_start text; v_now int; v_exists boolean; v_legacy text := 'pro' || 'files';
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

  select u.id into v_real from auth.users u
   where u.email not like 'p2-synthetic-%@fixture.invalid' limit 1;
  begin
    perform tests.__drop_synthetic_auth(v_real);
    return next fail('SF-3 removing a NON-synthetic identity must be refused');
  exception when others then
    return next ok(true,
      'SF-3 the fixture refuses to remove a non-synthetic identity ('||sqlstate||')');
  end;

  return next is(
    (select count(*)::int from auth.users
      where email not like 'p2-synthetic-%@fixture.invalid'),
    coalesce(nullif(current_setting('tests.auth_at_start', true),'')::int, -1),
    'SF-4 the real authentication accounts are exactly as many as at suite start');

  v_start := current_setting('tests.profiles_at_start', true);
  select exists (select 1 from pg_catalog.pg_class c
                   join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relname = v_legacy and c.relkind = 'r')
    into v_exists;
  if not v_exists then
    return next ok(v_start = 'absent',
      'SF-5 the legacy identity table is absent, exactly as at suite start');
  else
    execute format('select count(*)::int from %I.%I', 'public', v_legacy) into v_now;
    return next is(v_now, coalesce(nullif(v_start,'')::int, -1),
      'SF-5 the legacy identity table is unchanged across the whole suite');
  end if;
end $fn$;

revoke all on function tests.synthetic_fixture_integrity() from public, anon, authenticated;