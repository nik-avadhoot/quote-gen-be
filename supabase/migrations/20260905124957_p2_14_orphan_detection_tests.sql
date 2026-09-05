create or replace function tests.orphan_detection()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_admin_auth uuid; v_admin_email text; v_admin_claims text; v_admin bigint;
  v_auth uuid; v_email text; v_claims text; v_id bigint; v_out text[];
begin
  return next ok(
    (select not p.prosecdef from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='admin_emails_with_open_invitation'),
    'OD-1 the orphan-support shim is SECURITY INVOKER, not definer');
  return next ok(
    not (select pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
           from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname='admin_emails_with_open_invitation'),
    'OD-2 anon cannot execute it');

  v_admin_auth  := tests.__fixture_auth_uid();
  v_admin_email := (select u.email from auth.users u where u.id = v_admin_auth);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_admin_email, '__p2_od_admin', true);
  v_admin_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_admin_auth, v_admin_email);
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  v_admin := public.bootstrap_app_user();
  reset role;

  v_auth  := tests.__fixture_auth_uid();
  v_email := (select u.email from auth.users u where u.id = v_auth);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_od_user', false);
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_id := public.bootstrap_app_user();
  reset role;

  -- OD-3: an ordinary caller cannot use it at all
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  begin
    set local role authenticated;
    perform public.admin_emails_with_open_invitation(array['anything@example.invalid']);
    reset role;
    return next fail('OD-3 an ordinary caller must not query invitation status');
  exception when others then
    reset role;
    return next ok(true, 'OD-3 an ordinary caller is refused ('||sqlstate||')');
  end;

  -- OD-4/5: it answers ONLY about addresses the caller already supplied
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values ('od-outstanding@example.invalid', '__p2_od_pending', false);

  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  v_out := public.admin_emails_with_open_invitation(
             array['od-outstanding@example.invalid','od-unknown@example.invalid']);
  reset role;
  return next ok(v_out @> array['od-outstanding@example.invalid'],
    'OD-4 an address WITH an open invitation is reported back');
  return next ok(not (v_out @> array['od-unknown@example.invalid']),
    'OD-5 an address without one is not');

  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  v_out := public.admin_emails_with_open_invitation(array[]::text[]);
  reset role;
  return next is(coalesce(array_length(v_out,1),0), 0,
    'OD-6 an empty request returns nothing - it cannot ENUMERATE invitations');

  -- OD-7: a consumed invitation is not outstanding
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  v_out := public.admin_emails_with_open_invitation(array[v_email]);
  reset role;
  return next ok(not (v_out @> array[v_email]),
    'OD-7 a CONSUMED invitation is not reported as outstanding');

  delete from app_private.pending_invitations
   where invite_email in ('od-outstanding@example.invalid', v_email, v_admin_email);
  perform tests.__drop_synthetic_auth(v_auth);
  perform tests.__drop_synthetic_auth(v_admin_auth);
  return;

exception when others then
  reset role;
  delete from app_private.pending_invitations
   where invite_email in ('od-outstanding@example.invalid', v_email, v_admin_email);
  perform tests.__drop_synthetic_auth(v_auth);
  perform tests.__drop_synthetic_auth(v_admin_auth);
  raise;
end $fn$;

revoke all on function tests.orphan_detection() from public, anon, authenticated;

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
  return query select * from tests.email_management();
  return query select * from tests.plant_master();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from finish();
end $fn$;

revoke all on function tests.run_all() from public, anon, authenticated;