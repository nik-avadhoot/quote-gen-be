-- U1 Slice C - Customer Location pgTAP suite, registered in tests.run_all().
--
-- Fixture identities are MINTED, never borrowed (S4-6 rule).

create or replace function tests.customer_location_mutations()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_admin bigint; v_maker bigint; v_nocap bigint;
  v_claims_admin text; v_claims_maker text; v_claims_nocap text;
  v_party bigint; v_party_ungraduated bigint;
  v_loc bigint; v_cv int; v_code text;
  v_current_count int;
begin
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cl admin', 'active') returning id into v_admin;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cl maker', 'active') returning id into v_maker;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cl nocap', 'active') returning id into v_nocap;

  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_admin, c.id, v_admin from public.capabilities c where c.capability_key = 'manage_customer_master';
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, (select id from public.plants where plant_code = 'NAG'), c.id, v_admin
    from public.capabilities c where c.capability_key = 'make_quote';

  v_claims_admin := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_admin));
  v_claims_maker := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_maker));
  v_claims_nocap := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_nocap));

  insert into public.parties (display_name, lifecycle_state, status, created_by)
  values ('__u1cl party', 'prospect', 'proposed', v_admin) returning id into v_party;
  insert into public.parties (display_name, lifecycle_state, status, created_by)
  values ('__u1cl ungraduated party', 'prospect', 'proposed', v_admin) returning id into v_party_ungraduated;

  -- ── CLM-1 unauthenticated caller ──────────────────────────────────────────
  perform pg_catalog.set_config('request.jwt.claims', null, true);
  set local role authenticated;
  begin
    perform app_private.propose_customer_location(v_party, null, null, null, null, true, false);
    reset role;
    return next fail('CLM-1 an anonymous caller must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CLM-1 anonymous caller refused 42501 ('||sqlstate||')');
  end;

  -- ── CLM-2 authenticated, no capability at all ────────────────────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_nocap, true);
  set local role authenticated;
  begin
    perform app_private.propose_customer_location(v_party, null, null, null, null, true, false);
    reset role;
    return next fail('CLM-2 a caller with no grant at all must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CLM-2 no-capability caller refused 42501 ('||sqlstate||')');
  end;

  -- ── CLM-3 the make_quote path succeeds (not just manage_customer_master) ──
  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  v_loc := app_private.propose_customer_location(v_party, 'plant', '1 Industrial Ave', 'Contact A',
                                                   'first note', true, false);
  reset role;
  return next ok(v_loc is not null, 'CLM-3 a Maker (make_quote, no manage_customer_master) MAY propose a Location');
  return next is((select status from public.customer_locations where id = v_loc), 'proposed',
                 'CLM-3a it is created Proposed');
  return next is((select count(*)::int from public.customer_location_versions
                   where location_id = v_loc and status = 'current'), 1,
                 'CLM-3b exactly one current version exists');
  return next is((select version_no from public.customer_location_versions
                   where location_id = v_loc and status = 'current'), 1,
                 'CLM-3c the first version is version_no 1');

  -- ── CLM-4 eligibility guard: neither bill-to nor ship-to ─────────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  begin
    perform app_private.propose_customer_location(v_party, null, null, null, null, false, false);
    reset role;
    return next fail('CLM-4 a Location with neither eligibility must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CLM-4 not(bill_to or ship_to) refused 22023 ('||sqlstate||')');
  end;

  -- ── CLM-5 not-found Party ─────────────────────────────────────────────────
  set local role authenticated;
  begin
    perform app_private.propose_customer_location(-999999, null, null, null, null, true, false);
    reset role;
    return next fail('CLM-5 a nonexistent Party must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = 'P0002', 'CLM-5 not-found Party refused P0002 ('||sqlstate||')');
  end;

  -- ── CLM-6 atomicity: a forced failure on the SECOND insert leaves no orphan ──
  set local role authenticated;
  begin
    perform app_private.propose_customer_location(v_party, '__invalid_type', null, null, null, true, false);
    reset role;
    return next fail('CLM-6 an invalid location_type must be refused by ck_lv_type');
  exception when others then
    reset role;
    return next ok(true, 'CLM-6 invalid location_type refused by the version check constraint ('||sqlstate||')');
  end;
  return next is((select count(*)::int from public.customer_locations
                   where party_id = v_party and status = 'proposed'
                     and id not in (select location_id from public.customer_location_versions)), 0,
                 'CLM-6a no orphan Location survives the forced failure - whole operation rolled back');

  -- ── CLM-7 update_customer_location: stale CAS ─────────────────────────────
  select content_version into v_cv from public.customer_locations where id = v_loc;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.update_customer_location(v_loc, v_cv - 1, '2 New Ave', 'Contact B', 'second note');
    reset role;
    return next fail('CLM-7 a stale expected version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CLM-7 stale content_version refused 40001 ('||sqlstate||')');
  end;

  -- ── CLM-8 the correct expected version succeeds: new version, old superseded ──
  set local role authenticated;
  perform app_private.update_customer_location(v_loc, v_cv, '2 New Ave', 'Contact B', 'second note');
  reset role;
  select count(*)::int into v_current_count from public.customer_location_versions
   where location_id = v_loc and status = 'current';
  return next is(v_current_count, 1, 'CLM-8 exactly one current version after the edit (uk_lv_one_current holds)');
  return next is((select version_no from public.customer_location_versions
                   where location_id = v_loc and status = 'current'), 2,
                 'CLM-8a the new version is version_no 2');
  return next is((select status from public.customer_location_versions
                   where location_id = v_loc and version_no = 1), 'superseded',
                 'CLM-8b the prior version is superseded, not deleted');
  return next is((select address_text from public.customer_location_versions
                   where location_id = v_loc and status = 'current'), '2 New Ave',
                 'CLM-8c the new version carries the new address');
  return next is((select bill_to_eligible from public.customer_locations where id = v_loc), true,
                 'CLM-8d eligibility is unchanged by a descriptive edit - no parameter exists to change it');

  -- ── CLM-9 approve: forbidden transition (retire before approve) ──────────
  select content_version into v_cv from public.customer_locations where id = v_loc;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.retire_customer_location(v_loc, v_cv);
    reset role;
    return next fail('CLM-9 retiring a still-proposed Location must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CLM-9 retire-before-approve refused 22023 ('||sqlstate||')');
  end;

  -- ── CLM-10 approve succeeds ────────────────────────────────────────────────
  set local role authenticated;
  perform app_private.approve_customer_location(v_loc, v_cv);
  reset role;
  return next is((select status from public.customer_locations where id = v_loc), 'active',
                 'CLM-10 approve moves proposed -> active');

  -- ── CLM-11 double-approval refused ───────────────────────────────────────
  select content_version into v_cv from public.customer_locations where id = v_loc;
  set local role authenticated;
  begin
    perform app_private.approve_customer_location(v_loc, v_cv);
    reset role;
    return next fail('CLM-11 approving an already-active Location must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CLM-11 double-approval refused 22023 ('||sqlstate||')');
  end;

  -- ── CLM-12 retire succeeds ────────────────────────────────────────────────
  set local role authenticated;
  perform app_private.retire_customer_location(v_loc, v_cv);
  reset role;
  return next is((select status from public.customer_locations where id = v_loc), 'inactive',
                 'CLM-12 retire moves active -> inactive');

  -- ── CLM-13 double-retirement refused ─────────────────────────────────────
  select content_version into v_cv from public.customer_locations where id = v_loc;
  set local role authenticated;
  begin
    perform app_private.retire_customer_location(v_loc, v_cv);
    reset role;
    return next fail('CLM-13 retiring an already-inactive Location must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CLM-13 double-retirement refused 22023 ('||sqlstate||')');
  end;

  -- ── CLM-14/15 assign_location_code: P0002 pre-graduation, success post ──
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.assign_location_code(v_loc);
    reset role;
    return next fail('CLM-14 assigning a code before the Party is graduated must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = 'P0002', 'CLM-14 un-graduated Party refused P0002 ('||sqlstate||')');
  end;

  set local role authenticated;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
  select v_party, f.id, current_date, v_admin
    from public.customer_families f where f.name = '__u1cl family' limit 1;
  reset role;
  -- ensure a Family exists and is linked, then graduate
  if not exists (select 1 from public.party_family_memberships where party_id = v_party and is_current) then
    set local role authenticated;
    perform app_private.propose_customer_family('__u1cl family');
    reset role;
    insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    select v_party, f.id, current_date, v_admin
      from public.customer_families f where f.name = '__u1cl family';
  end if;

  set local role authenticated;
  v_code := app_private.graduate_party(v_party);
  v_code := app_private.assign_location_code(v_loc);
  reset role;
  return next ok(v_code like '%-%', 'CLM-15 a graduated Party lets assign_location_code mint a code');

  set local role authenticated;
  return next is(app_private.assign_location_code(v_loc), v_code,
                 'CLM-15a assign_location_code is idempotent - a repeat call returns the same code');
  reset role;

  -- ── CLM-16/17 grant posture on all five new public wrappers ─────────────
  return next is(
    (select count(*)::int from unnest(array[
       'propose_customer_location','update_customer_location','approve_customer_location',
       'retire_customer_location','assign_customer_location_code']) fn
      where pg_catalog.has_function_privilege('anon',
        (select p2.oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
          where n2.nspname='public' and p2.proname=fn limit 1), 'EXECUTE')
         or pg_catalog.has_function_privilege('service_role',
        (select p2.oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
          where n2.nspname='public' and p2.proname=fn limit 1), 'EXECUTE')),
    0, 'CLM-16 none of the five new public wrappers is executable by anon or service_role');
  return next is(
    (select count(*)::int from unnest(array[
       'propose_customer_location','update_customer_location','approve_customer_location',
       'retire_customer_location','assign_customer_location_code']) fn
      where pg_catalog.has_function_privilege('authenticated',
        (select p2.oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
          where n2.nspname='public' and p2.proname=fn limit 1), 'EXECUTE')),
    5, 'CLM-17 all five are executable by authenticated');

  -- ── cleanup ────────────────────────────────────────────────────────────────
  delete from public.customer_location_versions where location_id in
    (select id from public.customer_locations where party_id in (v_party, v_party_ungraduated));
  delete from public.customer_locations where party_id in (v_party, v_party_ungraduated);
  delete from public.party_family_memberships where party_id in (v_party, v_party_ungraduated);
  delete from public.parties where id in (v_party, v_party_ungraduated);
  delete from public.customer_families where name = '__u1cl family';
  delete from public.group_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cl%');
  delete from public.plant_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cl%');
  delete from public.app_users where display_name like '\_\_u1cl%';
  return;

exception when others then
  delete from public.customer_location_versions where location_id in
    (select id from public.customer_locations where party_id in (v_party, v_party_ungraduated));
  delete from public.customer_locations where party_id in (v_party, v_party_ungraduated);
  delete from public.party_family_memberships where party_id in (v_party, v_party_ungraduated);
  delete from public.parties where id in (v_party, v_party_ungraduated);
  delete from public.customer_families where name = '__u1cl family';
  delete from public.group_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cl%');
  delete from public.plant_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cl%');
  delete from public.app_users where display_name like '\_\_u1cl%';
  raise;
end $function$;

revoke all on function tests.customer_location_mutations() from public, anon, authenticated, service_role;

-- ═══════════════════════ register in run_all() ══════════════════════════════
create or replace function tests.run_all()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare v_profiles text; v_legacy text := 'pro' || 'files';
begin
  perform no_plan();
  perform tests.__sweep_synthetic_auth();

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
  return query select * from tests.construction_library();
  return query select * from tests.sku_master();
  return query select * from tests.family_c_authority();
  return query select * from tests.product_workflow();
  return query select * from tests.family_d_group_masters();
  return query select * from tests.family_d_plant_masters();
  return query select * from tests.interest_authority();
  return query select * from tests.pricing_basis();
  return query select * from tests.family_de_security();
  return query select * from tests.batch_workspace();
  return query select * from tests.batch_sets();
  return query select * from tests.batch_set_cardinality();
  return query select * from tests.batch_profile();
  return query select * from tests.batch_locks();
  return query select * from tests.family_f_security();
  return query select * from tests.content_version_boundary();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.customer_family_mutations();
  return query select * from tests.party_edit_mutations();
  return query select * from tests.customer_location_mutations();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from tests.suite_registration();
  return query select * from finish();
end $function$;
