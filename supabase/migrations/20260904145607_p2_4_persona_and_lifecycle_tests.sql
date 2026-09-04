-- P2-4: fixture-based regression tests - the bootstrap SUCCESS path, the granted-user
-- persona matrix, and the Party lifecycle RPCs.
--
-- Self-cleaning by construction: every fixture is created and removed inside the
-- function, and the cleanup runs in an EXCEPTION handler too, so a failed assertion
-- cannot leave residue. No auth.users row is created - the fixture borrows the
-- existing non-human agent identity, so Supabase-managed Auth is never written to.

create or replace function tests.fixtures_matrix()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_auth      uuid;
  v_admin     bigint;
  v_maker     bigint;
  v_fam       bigint;
  v_fam2      bigint;
  v_party     bigint;
  v_loc       bigint;
  v_plant_nag bigint;
  v_plant_pun bigint;
  v_code      text;
  v_code2     text;
  v_seen      int;
  v_ok        boolean;
  v_claims    text;
begin
  select id into v_auth from public.profiles where role = 'maker' limit 1;
  select id into v_plant_nag from public.plants where plant_code = 'NAG';
  select id into v_plant_pun from public.plants where plant_code = 'PUN';
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}',
                     v_auth, 'p2-fixture@example.invalid');

  -- ===================== BOOTSTRAP SUCCESS PATH =========================
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values ('p2-fixture@example.invalid', '__p2_fixture_admin', true);

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_admin := app_private.bootstrap_app_user();
  reset role;

  return next ok(v_admin is not null, 'S-1 bootstrap SUCCESS path creates an app identity');
  return next is((select status from public.app_users where id = v_admin), 'active',
                 'S-2 the bootstrapped identity is active');
  return next ok(exists (select 1 from public.group_capability_grants g
                           join public.capabilities c on c.id = g.capability_id
                          where g.app_user_id = v_admin
                            and c.capability_key = 'administer_users'
                            and g.status = 'active'),
                 'S-3 first administrator receives administer_users');
  return next ok(exists (select 1 from public.operational_settings
                          where setting_key = 'edit_lock_stale_seconds'
                            and created_by = v_admin
                            and setting_value = to_jsonb(900)),
                 'S-4 edit_lock_stale_seconds seeded with real admin attribution');
  return next ok((select consumed_at is not null from app_private.pending_invitations
                   where invite_email = 'p2-fixture@example.invalid'),
                 'S-5 the invitation is consumed after successful bootstrap');

  -- idempotent, and NOT reusable
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  return next is(app_private.bootstrap_app_user(), v_admin,
                 'S-6 re-running bootstrap returns the same identity, never a second one');
  reset role;

  -- a DIFFERENT authenticated user cannot claim the consumed invitation
  perform pg_catalog.set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000901","role":"authenticated",'
    '"email":"p2-fixture@example.invalid"}', true);
  set local role authenticated;
  begin
    perform app_private.bootstrap_app_user();
    reset role;
    return next fail('S-7 a consumed invitation must not be claimable again');
  exception when others then
    reset role;
    return next ok(true, 'S-7 consumed invitation cannot be reused ('||sqlstate||')');
  end;

  -- ===================== GRANTED-USER PERSONA MATRIX ====================
  insert into public.app_users (auth_user_id, display_name, status)
  values (null, '__p2_fixture_maker', 'invited') returning id into v_maker;
  -- borrow the same auth identity for policy evaluation without a second auth row
  update public.app_users set auth_user_id = null where id = v_admin;
  update public.app_users set auth_user_id = v_auth, status = 'active' where id = v_maker;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_plant_nag, c.id, v_maker from public.capabilities c
   where c.capability_key in ('make_quote','plant_access');
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_maker, c.id, v_maker from public.capabilities c
   where c.capability_key = 'read_party_master';

  insert into public.customer_families (name, status, created_by)
  values ('__p2 fixture family', 'active', v_maker) returning id into v_fam;
  insert into public.customer_families (name, status, created_by)
  values ('__p2 fixture family two', 'active', v_maker) returning id into v_fam2;
  update public.customer_families
     set group_customer_code = app_private.allocate_group_customer_code() where id = v_fam;
  insert into public.parties (display_name, lifecycle_state, status, created_by)
  values ('__p2 fixture party', 'prospect', 'proposed', v_maker) returning id into v_party;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
  values (v_party, v_fam, current_date, v_maker);

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  select count(*) into v_seen from public.parties;
  v_ok := app_private.has_plant_cap(v_plant_nag, 'make_quote');
  reset role;
  return next ok(v_seen > 0, 'M-1 granted user WITH read_party_master sees parties');
  return next ok(v_ok, 'M-2 granted user has make_quote on their OWN plant');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_ok := app_private.has_plant_cap(v_plant_pun, 'make_quote');
  reset role;
  return next ok(not v_ok, 'M-3 WRONG-PLANT denial: no make_quote on a plant not granted');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_ok := app_private.has_group_cap('manage_customer_master');
  reset role;
  return next ok(not v_ok, 'M-4 MISSING-CAPABILITY denial: Maker lacks manage_customer_master');

  -- Maker proposal boundary: proposed prospect allowed, active customer refused
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  begin
    insert into public.parties (display_name, lifecycle_state, status, created_by)
    values ('__p2 maker proposal', 'prospect', 'proposed', v_maker);
    return next ok(true, 'M-5 Maker MAY insert a proposed prospect');
  exception when others then
    return next fail('M-5 Maker should be able to insert a proposed prospect ('||sqlstate||')');
  end;
  begin
    insert into public.parties (display_name, lifecycle_state, status, customer_code, created_by)
    values ('__p2 maker overreach', 'customer', 'active', '__p2-X', v_maker);
    return next fail('M-6 Maker must NOT be able to insert an active Customer');
  exception when others then
    return next ok(true, 'M-6 Maker CANNOT insert an active Customer ('||sqlstate||')');
  end;
  reset role;

  -- INACTIVE user: a stale token grants nothing on the very next request
  update public.app_users set status = 'deactivated', deactivated_at = now() where id = v_maker;
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  select count(*) into v_seen from public.parties;
  v_ok := app_private.has_plant_cap(v_plant_nag, 'make_quote');
  reset role;
  return next is(v_seen, 0, 'M-7 DEACTIVATED user sees nothing, holding the same token');
  return next ok(not v_ok, 'M-8 DEACTIVATED user loses every capability immediately');
  update public.app_users set status = 'active', deactivated_at = null where id = v_maker;

  -- ANONYMOUS: no claims at all
  perform pg_catalog.set_config('request.jwt.claims', null, true);
  set local role authenticated;
  select count(*) into v_seen from public.parties;
  reset role;
  return next is(v_seen, 0, 'M-9 ANONYMOUS caller sees nothing');

  -- ===================== PARTY LIFECYCLE RPCs ===========================
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_maker, c.id, v_maker from public.capabilities c
   where c.capability_key = 'manage_customer_master';

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_code := app_private.graduate_party(v_party);
  reset role;
  return next ok(v_code like (select group_customer_code || '-%' from public.customer_families where id = v_fam),
                 'L-1 graduation mints a Customer Code embedding the ORIGINAL Family code');
  return next is((select lifecycle_state from public.parties where id = v_party), 'customer',
                 'L-2 graduation changes lifecycle state of the SAME identity');
  return next is((select count(*)::int from public.parties where id = v_party), 1,
                 'L-3 graduation does not create a second party row');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_code2 := app_private.graduate_party(v_party);
  reset role;
  return next is(v_code2, v_code, 'L-4 graduation is idempotent - never a second code');

  -- reassignment: exactly one current membership, code unchanged (DM-111)
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  perform app_private.reassign_party_family(v_party, v_fam2, current_date);
  reset role;
  return next is((select count(*)::int from public.party_family_memberships
                   where party_id = v_party and is_current), 1,
                 'L-5 reassignment leaves EXACTLY ONE current membership');
  return next is((select count(*)::int from public.party_family_memberships
                   where party_id = v_party), 2,
                 'L-6 the prior membership is retained as history, not overwritten');
  return next is((select customer_code from public.parties where id = v_party), v_code,
                 'L-7 Customer Code is unchanged by reassignment (DM-111)');

  -- the partial unique index is the concurrency backstop
  begin
    insert into public.party_family_memberships (party_id, family_id, effective_from, is_current, created_by)
    values (v_party, v_fam, current_date, true, v_maker);
    return next fail('L-8 a second current membership must be impossible');
  exception when unique_violation then
    return next ok(true, 'L-8 a second CURRENT membership is refused by the unique index');
  end;

  -- location code nests beneath the Customer Code
  insert into public.customer_locations (party_id, bill_to_eligible, status, created_by)
  values (v_party, true, 'active', v_maker) returning id into v_loc;
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_code2 := app_private.assign_location_code(v_loc);
  reset role;
  return next ok(v_code2 like v_code || '-%',
                 'L-9 Location Code is a permanent sequence beneath the Customer Code');

  -- codes are never reused
  return next ok(app_private.allocate_group_customer_code()
                 <> app_private.allocate_group_customer_code(),
                 'L-10 code allocation never returns the same value twice');

  perform tests.__cleanup_fixtures();
  return;

exception when others then
  perform tests.__cleanup_fixtures();
  raise;
end $fn$;

-- Cleanup is a separate function so the happy path and the exception path use
-- exactly the same teardown. Deletes run child-first because every FK is RESTRICT.
create or replace function tests.__cleanup_fixtures()
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  delete from public.customer_locations
   where party_id in (select id from public.parties where display_name like '\_\_p2%');
  delete from public.party_family_memberships
   where party_id in (select id from public.parties where display_name like '\_\_p2%');
  delete from public.party_external_references
   where party_id in (select id from public.parties where display_name like '\_\_p2%');
  delete from public.parties where display_name like '\_\_p2%';
  delete from public.customer_family_aliases
   where family_id in (select id from public.customer_families where name like '\_\_p2%');
  delete from public.customer_families where name like '\_\_p2%';
  delete from public.operational_settings
   where created_by in (select id from public.app_users where display_name like '\_\_p2%');
  delete from public.group_capability_grants
   where app_user_id in (select id from public.app_users where display_name like '\_\_p2%');
  delete from public.plant_capability_grants
   where app_user_id in (select id from public.app_users where display_name like '\_\_p2%');
  update app_private.pending_invitations set consumed_at = null, consumed_by = null
   where invite_email = 'p2-fixture@example.invalid';
  delete from app_private.pending_invitations where invite_email = 'p2-fixture@example.invalid';
  delete from public.app_users where display_name like '\_\_p2%';
end $fn$;

revoke execute on function tests.__cleanup_fixtures() from public;
revoke execute on function tests.fixtures_matrix() from public;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.party_masters();
  return query select * from tests.fixtures_matrix();
  return query select * from finish();
end $fn$;