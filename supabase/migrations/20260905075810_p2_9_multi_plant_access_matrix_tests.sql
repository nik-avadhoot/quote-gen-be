-- P2-9: prove the multi-plant Maker access matrix, and prove its one limitation.
--
-- CDM-05-A represents the legacy `Group` scope as EXPLICIT grants at every
-- current plant. That only means anything if two things are true: the grants
-- actually confer Maker authority at each plant and nothing more, and a plant
-- created afterwards is NOT silently included. MP-8 asserts the second one
-- deliberately - the deferral is a tested property, not a footnote, so if a
-- later change ever makes new plants automatic, this test fails and says so.

create or replace function tests.multi_plant_access()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_auth uuid; v_claims text; v_id bigint; v_grp bigint; v_new bigint;
  v_email text := 'p2-mp@example.invalid';
  v_codes text[] := array['NAG','PUN','KOL'];
  c text; v_ok boolean; v_n int;
begin
  v_auth := tests.__fixture_auth_uid();
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);

  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_mp_maker', false);

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_id := public.bootstrap_app_user();
  reset role;

  return next ok(v_id is not null, 'MP-1 the invited Maker bootstraps into an active identity');
  return next is((select count(*)::int from public.group_capability_grants
                   where app_user_id = v_id), 0,
                 'MP-2 a non-admin invitation grants NO group capability at all');
  return next is((select count(*)::int from public.plant_capability_grants
                   where app_user_id = v_id), 0,
                 'MP-3 and no plant capability - every grant is an administrator act');

  -- what PATCH /admin/users/<id> with plants=[NAG,PUN,KOL] produces
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_id, p.id, c2.id, v_id
    from public.plants p
    cross join public.capabilities c2
   where p.plant_code = any(v_codes)
     and c2.capability_key in ('plant_access','make_quote');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);

  foreach c in array v_codes loop
    set local role authenticated;
    select app_private.has_plant_cap(p.id, 'make_quote') into v_ok
      from public.plants p where p.plant_code = c;
    reset role;
    return next ok(v_ok, format('MP-4 Maker authority holds at %s', c));

    set local role authenticated;
    select app_private.is_plant_member(p.id) into v_ok
      from public.plants p where p.plant_code = c;
    reset role;
    return next ok(v_ok, format('MP-5 plant membership holds at %s', c));

    set local role authenticated;
    select app_private.has_plant_cap(p.id, 'check_quote') into v_ok
      from public.plants p where p.plant_code = c;
    reset role;
    return next ok(not v_ok, format('MP-6 NO Checker authority at %s', c));
  end loop;

  set local role authenticated;
  v_ok := app_private.has_group_cap('administer_users');
  reset role;
  return next ok(not v_ok, 'MP-7 the multi-plant Maker holds NO administer_users');

  set local role authenticated;
  v_ok := app_private.has_group_cap('manage_customer_master');
  reset role;
  return next ok(not v_ok, 'MP-7a and no group master-write capability');

  set local role authenticated;
  v_ok := app_private.has_group_cap('read_party_master');
  reset role;
  return next ok(not v_ok,
    'MP-7b and no group read capability - group visibility is a separate explicit grant');

  -- the accepted Phase 2 limitation, proved rather than described
  select id into v_grp from public.avadhoot_groups order by id limit 1;
  insert into public.plants (group_id, plant_code, name, timezone, status)
  values (v_grp, 'ZZT', '__p2 mp future plant', 'Asia/Kolkata', 'active')
  returning id into v_new;

  set local role authenticated;
  v_ok := app_private.has_plant_cap(v_new, 'make_quote');
  reset role;
  return next ok(not v_ok,
    'MP-8 a plant created LATER is NOT automatically included - explicit grant required (deferred)');

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_id, v_new, c2.id from public.capabilities c2
   where c2.capability_key in ('plant_access','make_quote');

  set local role authenticated;
  v_ok := app_private.has_plant_cap(v_new, 'make_quote');
  reset role;
  return next ok(v_ok, 'MP-9 an explicit administrator grant is what admits the new plant');

  select count(*)::int into v_n from public.plant_capability_grants
   where app_user_id = v_id and status = 'active';
  return next is(v_n, 8, 'MP-10 four plants x two capabilities - grants are per-plant, never collapsed');

  delete from public.plant_capability_grants where app_user_id = v_id;
  delete from public.group_capability_grants where app_user_id = v_id;
  delete from public.operational_settings where created_by = v_id;
  delete from public.plants where plant_code = 'ZZT';
  delete from app_private.pending_invitations where invite_email = v_email;
  delete from public.app_users where id = v_id;
  return;

exception when others then
  reset role;
  delete from public.plant_capability_grants
   where app_user_id in (select id from public.app_users where display_name like '\_\_p2\_mp%');
  delete from public.group_capability_grants
   where app_user_id in (select id from public.app_users where display_name like '\_\_p2\_mp%');
  delete from public.operational_settings
   where created_by in (select id from public.app_users where display_name like '\_\_p2\_mp%');
  delete from public.plants where plant_code = 'ZZT';
  delete from app_private.pending_invitations where invite_email = v_email;
  delete from public.app_users where display_name like '\_\_p2\_mp%';
  raise;
end $fn$;

revoke all on function tests.multi_plant_access() from public;
revoke all on function tests.multi_plant_access() from anon;
revoke all on function tests.multi_plant_access() from authenticated;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
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
  return query select * from tests.multi_plant_access();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from finish();
end $fn$;

revoke all on function tests.run_all() from public;
revoke all on function tests.run_all() from anon;
revoke all on function tests.run_all() from authenticated;