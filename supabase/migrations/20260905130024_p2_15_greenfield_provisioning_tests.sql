create or replace function tests.greenfield_provisioning()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_auth uuid; v_email text; v_claims text; v_admin bigint; v_out text;
begin
  -- GP-1/2: it is not reachable from the API at all, by anybody
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'provision_pending_invitation'), 0,
    'GP-1 there is NO public shim - the procedure is not routable through PostgREST');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       cross join unnest(array['anon','authenticated','service_role']) as r(role)
      where n.nspname = 'app_private' and p.proname = 'provision_pending_invitation'
        and pg_catalog.has_function_privilege(r.role, p.oid, 'EXECUTE')), 0,
    'GP-2 no API role - not even service_role - may execute it');

  -- GP-3: it embeds no address; the caller supplies one
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app_private' and p.proname = 'provision_pending_invitation'
        and p.prosrc ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'), 0,
    'GP-3 no email address is embedded in the procedure body');

  -- GP-4: input validation
  begin
    perform app_private.provision_pending_invitation('not-an-email', 'X', true);
    return next fail('GP-4 a malformed address must be refused');
  exception when others then
    return next ok(true, 'GP-4 a malformed address is refused ('||sqlstate||')');
  end;

  -- With an administrator PRESENT, the first-admin path must be closed and the
  -- ordinary path open. A synthetic administrator provides that state.
  v_auth  := tests.__fixture_auth_uid();
  v_email := (select u.email from auth.users u where u.id = v_auth);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_gp_admin', true);
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_admin := public.bootstrap_app_user();
  reset role;

  begin
    perform app_private.provision_pending_invitation('gp-second@example.invalid', 'Second Admin', true);
    return next fail('GP-5 a SECOND first-administrator must be impossible');
  exception when others then
    return next ok(true,
      'GP-5 the first-administrator path is one-shot - refused once one exists ('||sqlstate||')');
  end;

  v_out := app_private.provision_pending_invitation('gp-ordinary@example.invalid', 'Ordinary', false);
  return next ok(v_out like '%created%',
    'GP-6 an ordinary invitation IS allowed once an administrator exists');
  return next is(
    (select count(*)::int from app_private.pending_invitations
      where invite_email = 'gp-ordinary@example.invalid' and consumed_at is null), 1,
    'GP-7 and exactly one open invitation results');

  v_out := app_private.provision_pending_invitation('gp-ordinary@example.invalid', 'Ordinary', false);
  return next ok(v_out like 'unchanged%',
    'GP-8 re-running is idempotent - it does not stack duplicate invitations');
  return next is(
    (select count(*)::int from app_private.pending_invitations
      where invite_email = 'gp-ordinary@example.invalid' and consumed_at is null), 1,
    'GP-9 still exactly one');

  begin
    perform app_private.provision_pending_invitation(v_email, 'Already In', false);
    return next fail('GP-10 an address that already has an identity must be refused');
  exception when others then
    return next ok(true,
      'GP-10 an address with an existing application identity is refused ('||sqlstate||')');
  end;

  delete from app_private.pending_invitations
   where invite_email in ('gp-ordinary@example.invalid', v_email);
  perform tests.__drop_synthetic_auth(v_auth);
  return;

exception when others then
  reset role;
  delete from app_private.pending_invitations
   where invite_email in ('gp-ordinary@example.invalid', 'gp-second@example.invalid', v_email);
  perform tests.__drop_synthetic_auth(v_auth);
  raise;
end $fn$;

revoke all on function tests.greenfield_provisioning() from public, anon, authenticated;

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