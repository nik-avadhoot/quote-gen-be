-- P2-5: remove the last CURRENT dependency on public.profiles.
--
-- tests.fixtures_matrix and tests.reference_allocation looked up a usable auth
-- identity via `public.profiles where role='maker'`. That is a live test-time
-- dependency on the legacy object, and it would have blocked S3(c) removal.
--
-- The fixtures never needed the legacy ROLE - only a uuid that satisfies
-- app_users -> auth.users. They now read auth.users directly. No Auth row is
-- created or modified; the oldest existing identity is simply borrowed.

create or replace function tests.__fixture_auth_uid()
returns uuid language sql stable security definer set search_path = '' as $fn$
  select id from auth.users order by created_at limit 1;
$fn$;
revoke execute on function tests.__fixture_auth_uid() from public;

create or replace function tests.reference_allocation()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare a bigint; b bigint; c bigint; n int; v_auth uuid; v_user bigint;
begin
  v_auth := tests.__fixture_auth_uid();
  insert into public.app_users (auth_user_id, display_name, status)
  values (v_auth, '__p2ref probe', 'active') returning id into v_user;
  perform pg_catalog.set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_auth), true);

  a := ref_private.allocate_reference('__p2ref', 0, null);
  b := ref_private.allocate_reference('__p2ref', 0, null);
  c := ref_private.allocate_reference('__p2ref', 0, null);
  select count(*) into n from ref_private.reference_sequences where scope_type = '__p2ref';

  return next ok(a <> b and b <> c and a <> c,
                 'R-1 repeated allocation in one scope never repeats a value');
  return next ok(b = a + 1 and c = b + 1, 'R-2 allocation is strictly sequential');
  return next is(n, 1,
                 'R-3 a NULL fy_label scope keeps exactly ONE counter row (NULLS NOT DISTINCT)');

  delete from ref_private.reference_sequences where scope_type = '__p2ref';
  delete from public.app_users where id = v_user;
exception when others then
  delete from ref_private.reference_sequences where scope_type = '__p2ref';
  delete from public.app_users where display_name = '__p2ref probe';
  raise;
end $fn$;
revoke execute on function tests.reference_allocation() from public;

-- fixtures_matrix: same single change, first statement only.
create or replace function tests.fixtures_matrix()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_auth uuid; v_admin bigint; v_maker bigint; v_fam bigint; v_fam2 bigint;
  v_party bigint; v_loc bigint; v_plant_nag bigint; v_plant_pun bigint;
  v_code text; v_code2 text; v_seen int; v_ok boolean; v_claims text;
begin
  v_auth := tests.__fixture_auth_uid();
  select id into v_plant_nag from public.plants where plant_code = 'NAG';
  select id into v_plant_pun from public.plants where plant_code = 'PUN';
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}',
                     v_auth, 'p2-fixture@example.invalid');

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
                          where g.app_user_id = v_admin and c.capability_key = 'administer_users'
                            and g.status = 'active'),
                 'S-3 first administrator receives administer_users');
  return next ok(exists (select 1 from public.operational_settings
                          where setting_key = 'edit_lock_stale_seconds'
                            and created_by = v_admin and setting_value = to_jsonb(900)),
                 'S-4 edit_lock_stale_seconds seeded with real admin attribution');
  return next ok((select consumed_at is not null from app_private.pending_invitations
                   where invite_email = 'p2-fixture@example.invalid'),
                 'S-5 the invitation is consumed after successful bootstrap');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  return next is(app_private.bootstrap_app_user(), v_admin,
                 'S-6 re-running bootstrap returns the same identity, never a second one');
  reset role;

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

  insert into public.app_users (auth_user_id, display_name, status)
  values (null, '__p2_fixture_maker', 'invited') returning id into v_maker;
  update public.app_users
     set status = 'deactivated', deactivated_at = now(), auth_user_id = null
   where id = v_admin;
  update public.app_users
     set auth_user_id = v_auth, status = 'active' where id = v_maker;

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);

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

  set local role authenticated;
  select count(*) into v_seen from public.parties;
  v_ok := app_private.has_plant_cap(v_plant_nag, 'make_quote');
  reset role;
  return next ok(v_seen > 0, 'M-1 granted user WITH read_party_master sees parties');
  return next ok(v_ok, 'M-2 granted user has make_quote on their OWN plant');

  set local role authenticated;
  v_ok := app_private.has_plant_cap(v_plant_pun, 'make_quote');
  reset role;
  return next ok(not v_ok, 'M-3 WRONG-PLANT denial: no make_quote on a plant not granted');

  set local role authenticated;
  v_ok := app_private.has_group_cap('manage_customer_master');
  reset role;
  return next ok(not v_ok, 'M-4 MISSING-CAPABILITY denial: Maker lacks manage_customer_master');

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

  update public.app_users set status = 'deactivated', deactivated_at = now() where id = v_maker;
  set local role authenticated;
  select count(*) into v_seen from public.parties;
  v_ok := app_private.has_plant_cap(v_plant_nag, 'make_quote');
  reset role;
  return next is(v_seen, 0, 'M-7 DEACTIVATED user sees nothing, holding the same token');
  return next ok(not v_ok, 'M-8 DEACTIVATED user loses every capability immediately');
  update public.app_users set status = 'active', deactivated_at = null where id = v_maker;

  perform pg_catalog.set_config('request.jwt.claims', null, true);
  set local role authenticated;
  select count(*) into v_seen from public.parties;
  reset role;
  return next is(v_seen, 0, 'M-9 ANONYMOUS caller sees nothing');
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);

  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_maker, c.id, v_maker from public.capabilities c
   where c.capability_key = 'manage_customer_master';

  set local role authenticated;
  v_code := app_private.graduate_party(v_party);
  reset role;
  return next ok(v_code like (select group_customer_code || '-%' from public.customer_families where id = v_fam),
                 'L-1 graduation mints a Customer Code embedding the ORIGINAL Family code');
  return next is((select lifecycle_state from public.parties where id = v_party), 'customer',
                 'L-2 graduation changes lifecycle state of the SAME identity');
  return next is((select count(*)::int from public.parties where id = v_party), 1,
                 'L-3 graduation does not create a second party row');

  set local role authenticated;
  v_code2 := app_private.graduate_party(v_party);
  reset role;
  return next is(v_code2, v_code, 'L-4 graduation is idempotent - never a second code');

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

  begin
    insert into public.party_family_memberships (party_id, family_id, effective_from, is_current, created_by)
    values (v_party, v_fam, current_date, true, v_maker);
    return next fail('L-8 a second current membership must be impossible');
  exception when unique_violation then
    return next ok(true, 'L-8 a second CURRENT membership is refused by the unique index');
  end;

  insert into public.customer_locations (party_id, bill_to_eligible, status, created_by)
  values (v_party, true, 'active', v_maker) returning id into v_loc;
  set local role authenticated;
  v_code2 := app_private.assign_location_code(v_loc);
  reset role;
  return next ok(v_code2 like v_code || '-%',
                 'L-9 Location Code is a permanent sequence beneath the Customer Code');

  return next ok(app_private.allocate_group_customer_code()
                 <> app_private.allocate_group_customer_code(),
                 'L-10 code allocation never returns the same value twice');

  perform tests.__cleanup_fixtures();
  return;

exception when others then
  perform tests.__cleanup_fixtures();
  raise;
end $fn$;
revoke execute on function tests.fixtures_matrix() from public;

-- Guard: no current test may depend on the legacy identity objects again.
create or replace function tests.no_legacy_identity_dependency()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('tests','app_private','ref_private','public')
        and p.prosecdef is not null
        and p.prosrc ilike '%public.profiles%'),
    0, 'D-1 no function in tests/app_private/ref_private/public reads public.profiles');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('tests','app_private','ref_private','public')
        and p.proname <> 'is_admin'
        and p.prosrc ilike '%is_admin%'),
    0, 'D-2 no function calls app_private.is_admin');
  return next is(
    (select count(*)::int from pg_catalog.pg_policy pol
       join pg_catalog.pg_class c on c.oid = pol.polrelid
      where c.relname <> 'profiles'
        and coalesce(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid),'') ilike '%is_admin%'),
    0, 'D-3 no policy outside profiles depends on is_admin');
end $fn$;
revoke execute on function tests.no_legacy_identity_dependency() from public;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.function_grants();
  return query select * from tests.admin_rpcs();
  return query select * from tests.no_legacy_identity_dependency();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from finish();
end $fn$;
revoke execute on function tests.run_all() from public;