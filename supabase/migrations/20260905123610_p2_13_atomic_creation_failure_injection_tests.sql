-- P2-13: TX-* injects a failure part-way through a multi-plant creation and
-- proves the database is left with nothing - no partial identity, no partial
-- grants, and therefore nothing for a route to mistake for success.
--
-- The failure is injected the way it would really arrive: a plant that is not
-- assignable sitting SECOND or THIRD in the requested set, so the first plant
-- would already have been written under the old two-step flow.

create or replace function tests.atomic_multi_plant_creation()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_admin_auth uuid; v_admin_email text; v_admin_claims text; v_admin bigint;
  v_target uuid; v_grp bigint; v_inactive bigint; v_id bigint; v_before int;
begin
  -- a synthetic administrator to act as
  v_admin_auth  := tests.__fixture_auth_uid();
  v_admin_email := (select u.email from auth.users u where u.id = v_admin_auth);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_admin_email, '__p2_tx_admin', true);
  v_admin_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_admin_auth, v_admin_email);
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  v_admin := public.bootstrap_app_user();
  reset role;

  -- the account the administrator is creating an identity for
  v_target := tests.__fixture_auth_uid();

  select id into v_grp from public.avadhoot_groups order by id limit 1;
  insert into public.plants (group_id, plant_code, name, timezone, status)
  values (v_grp, 'ZZT', '__p2 tx inactive plant', 'Asia/Kolkata', 'inactive')
  returning id into v_inactive;

  select count(*)::int into v_before from public.app_users;

  -- TX-1: failure on the SECOND plant
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  begin
    set local role authenticated;
    perform public.admin_create_app_user(v_target, 'TX Two', 'maker', array['NAG','ZZT']);
    reset role;
    return next fail('TX-1 a non-assignable SECOND plant must abort the whole creation');
  exception when others then
    reset role;
    return next ok(true, 'TX-1 a non-assignable SECOND plant aborts the creation ('||sqlstate||')');
  end;
  return next is((select count(*)::int from public.app_users), v_before,
    'TX-2 no application identity survives the aborted creation');
  return next is((select count(*)::int from public.app_users where auth_user_id = v_target), 0,
    'TX-3 and specifically none for the target authentication account');

  -- TX-4: failure on the THIRD plant - the first two would already be written
  -- under a step-by-step flow
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  begin
    set local role authenticated;
    perform public.admin_create_app_user(v_target, 'TX Three', 'maker', array['NAG','PUN','ZZT']);
    reset role;
    return next fail('TX-4 a non-assignable THIRD plant must abort the whole creation');
  exception when others then
    reset role;
    return next ok(true, 'TX-4 a non-assignable THIRD plant aborts the creation ('||sqlstate||')');
  end;
  return next is((select count(*)::int from public.app_users where auth_user_id = v_target), 0,
    'TX-5 still no identity - NAG and PUN were not left behind');
  return next is(
    (select count(*)::int from public.plant_capability_grants g
       join public.app_users u on u.id = g.app_user_id
      where u.auth_user_id = v_target), 0,
    'TX-6 and not a single plant grant survives the abort');

  -- TX-7: an unknown plant code behaves identically
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  begin
    set local role authenticated;
    perform public.admin_create_app_user(v_target, 'TX Bogus', 'maker', array['NAG','NOPE']);
    reset role;
    return next fail('TX-7 an unknown plant code must abort the whole creation');
  exception when others then
    reset role;
    return next ok(true, 'TX-7 an unknown plant code aborts the creation ('||sqlstate||')');
  end;
  return next is((select count(*)::int from public.app_users where auth_user_id = v_target), 0,
    'TX-8 no identity from the unknown-plant attempt either');

  -- TX-9..12: the SUCCESS path - all three together, in one call
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  v_id := public.admin_create_app_user(v_target, 'TX Good', 'maker', array['NAG','PUN','KOL']);
  reset role;
  return next ok(v_id is not null, 'TX-9 NAG + PUN + KOL together create ONE identity');
  return next is((select count(*)::int from public.plant_capability_grants
                   where app_user_id = v_id and status='active'), 6,
    'TX-10 with all six grants - three plants x plant_access + make_quote');
  return next is((select count(*)::int from public.group_capability_grants
                   where app_user_id = v_id), 0,
    'TX-11 and no group capability for a Maker');
  return next is((select count(*)::int from public.app_users where auth_user_id = v_target), 1,
    'TX-12 exactly one identity for that authentication account');

  -- TX-13: an administrator may be created with NO plant at all
  begin
    perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
    set local role authenticated;
    perform public.admin_create_app_user(v_target, 'TX Dup', 'admin', array[]::text[]);
    reset role;
    return next fail('TX-13 a second identity for the same auth account must be impossible');
  exception when others then
    reset role;
    return next ok(true, 'TX-13 uk_app_users_auth still forbids a second identity ('||sqlstate||')');
  end;

  delete from public.plant_capability_grants where app_user_id = v_id;
  delete from public.app_users where id = v_id;
  delete from public.plants where id = v_inactive;
  delete from app_private.pending_invitations where invite_email = v_admin_email;
  perform tests.__drop_synthetic_auth(v_target);
  perform tests.__drop_synthetic_auth(v_admin_auth);
  return;

exception when others then
  reset role;
  delete from public.plant_capability_grants
   where app_user_id in (select id from public.app_users where auth_user_id in (v_target, v_admin_auth));
  delete from public.group_capability_grants
   where app_user_id in (select id from public.app_users where auth_user_id in (v_target, v_admin_auth));
  delete from public.app_users where auth_user_id in (v_target, v_admin_auth);
  delete from public.plants where plant_code = 'ZZT';
  delete from app_private.pending_invitations where invite_email = v_admin_email;
  perform tests.__drop_synthetic_auth(v_target);
  perform tests.__drop_synthetic_auth(v_admin_auth);
  raise;
end $fn$;

revoke all on function tests.atomic_multi_plant_creation() from public, anon, authenticated;

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
  return query select * from tests.email_management();
  return query select * from tests.plant_master();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from finish();
end $fn$;

revoke all on function tests.run_all() from public, anon, authenticated;