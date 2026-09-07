-- Family B governed mutations - pgTAP suite, and the one existing-fixture fix
-- reassign_party_family's changed signature requires.
--
-- Fixture identities are MINTED, never borrowed (S4-6 rule) - every persona
-- below is a fresh synthetic auth uid via tests.__fixture_auth_uid(), never
-- one of the two governed identities.

-- ── the one existing call site reassign_party_family's new signature breaks ──
create or replace function tests.fixtures_matrix()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_auth uuid; v_admin bigint; v_maker bigint; v_fam bigint; v_fam2 bigint;
  v_party bigint; v_loc bigint; v_plant_nag bigint; v_plant_pun bigint;
  v_code text; v_code2 text; v_seen int; v_ok boolean; v_claims text;
  v_party_cv int;
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
  return next ok(exists (select 1 from public.operational_settings os
                           join public.app_users au2 on au2.id = os.created_by
                           join public.group_capability_grants gg on gg.app_user_id = au2.id
                           join public.capabilities cc on cc.id = gg.capability_id
                          where os.setting_key = 'edit_lock_stale_seconds'
                            and os.setting_value = to_jsonb(900)
                            and cc.capability_key = 'administer_users'
                            and gg.status = 'active'),
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

  select content_version into v_party_cv from public.parties where id = v_party;
  set local role authenticated;
  perform app_private.reassign_party_family(v_party, v_fam2, v_party_cv, current_date);
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
end $function$;

-- ═══════════════════════ the new suite ══════════════════════════════════════
create or replace function tests.customer_family_mutations()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_admin bigint; v_maker bigint; v_nocap bigint; v_inactive bigint;
  v_plant_nag bigint;
  v_claims_admin text; v_claims_maker text; v_claims_nocap text; v_claims_inactive text;
  v_fam bigint; v_fam2 bigint; v_fam3 bigint; v_party bigint; v_party2 bigint;
  v_cv int; v_cv2 int; v_alias_id bigint; v_alias_cv int;
  v_seen int; v_code text;
begin
  -- ── mint four fresh, never-borrowed identities (S4-6) ─────────────────────
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cf admin', 'active') returning id into v_admin;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cf maker', 'active') returning id into v_maker;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cf nocap', 'active') returning id into v_nocap;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cf inactive', 'deactivated') returning id into v_inactive;

  select id into v_plant_nag from public.plants where plant_code = 'NAG';

  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_admin, c.id, v_admin from public.capabilities c where c.capability_key = 'manage_customer_master';
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_plant_nag, c.id, v_admin from public.capabilities c where c.capability_key = 'make_quote';
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_inactive, c.id, v_admin from public.capabilities c where c.capability_key = 'manage_customer_master';

  v_claims_admin    := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_admin));
  v_claims_maker    := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_maker));
  v_claims_nocap    := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_nocap));
  v_claims_inactive := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_inactive));

  -- ── CFM-1 unauthenticated caller ───────────────────────────────────────────
  perform pg_catalog.set_config('request.jwt.claims', null, true);
  set local role authenticated;
  begin
    perform app_private.propose_customer_family('__u1cf should not exist');
    reset role;
    return next fail('CFM-1 an anonymous caller must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CFM-1 anonymous caller refused 42501 ('||sqlstate||')');
  end;

  -- ── CFM-2 authenticated, no capability at all ──────────────────────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_nocap, true);
  set local role authenticated;
  begin
    perform app_private.propose_customer_family('__u1cf should not exist');
    reset role;
    return next fail('CFM-2 a caller with no grant at all must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CFM-2 no-capability caller refused 42501 ('||sqlstate||')');
  end;

  -- ── CFM-3 inactive assignment: a deactivated manage_customer_master holder ──
  perform pg_catalog.set_config('request.jwt.claims', v_claims_inactive, true);
  set local role authenticated;
  begin
    perform app_private.propose_customer_family('__u1cf should not exist');
    reset role;
    return next fail('CFM-3 a deactivated caller must be refused despite holding the grant');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CFM-3 deactivated caller refused 42501 ('||sqlstate||')');
  end;

  -- ── CFM-4 valid Maker proposes a Family (the make_quote path, not admin) ───
  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  v_fam := app_private.propose_customer_family('__u1cf proposed family');
  reset role;
  return next ok(v_fam is not null, 'CFM-4 a Maker (make_quote, no manage_customer_master) MAY propose a Family');
  return next is((select status from public.customer_families where id = v_fam), 'proposed',
                 'CFM-4a it is created Proposed');
  return next ok((select group_customer_code from public.customer_families where id = v_fam) is not null,
                 'CFM-5 the Family Code is allocated AT CREATION (sr-dev-proposal S12.4), not deferred to approval');

  -- ── CFM-6 wrong-group: Maker cannot approve (manage_customer_master only) ──
  select content_version into v_cv from public.customer_families where id = v_fam;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  begin
    perform app_private.approve_customer_family(v_fam, v_cv);
    reset role;
    return next fail('CFM-6 a Maker must not be able to approve a Family');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CFM-6 WRONG-GROUP denial: Maker lacks manage_customer_master ('||sqlstate||')');
  end;

  -- ── CFM-7 valid authorized caller: admin approves ──────────────────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  perform app_private.approve_customer_family(v_fam, v_cv);
  reset role;
  return next is((select status from public.customer_families where id = v_fam), 'active',
                 'CFM-7 admin approves the proposed Family');
  return next is((select approved_by from public.customer_families where id = v_fam), v_admin,
                 'CFM-7a approval attribution recorded');

  -- ── CFM-8 forbidden transition: approving twice ────────────────────────────
  select content_version into v_cv from public.customer_families where id = v_fam;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.approve_customer_family(v_fam, v_cv);
    reset role;
    return next fail('CFM-8 approving an already-active Family must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-8 forbidden state transition refused 22023 ('||sqlstate||')');
  end;

  -- ── CFM-9 stale content_version on a plain edit ────────────────────────────
  select content_version into v_cv from public.customer_families where id = v_fam;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.update_customer_family(v_fam, v_cv - 1, '__u1cf renamed wrong');
    reset role;
    return next fail('CFM-9 a stale expected version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-9 stale content_version refused 40001 ('||sqlstate||')');
  end;
  set local role authenticated;
  perform app_private.update_customer_family(v_fam, v_cv, '__u1cf renamed right');
  reset role;
  return next is((select name from public.customer_families where id = v_fam), '__u1cf renamed right',
                 'CFM-9a the correct expected version succeeds');

  -- ── CFM-10/11 aliases: add, edit, duplicate, retire, stale ─────────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  v_alias_id := app_private.add_family_alias(v_fam, '__u1cf alias one');
  reset role;
  return next ok(v_alias_id is not null, 'CFM-10 alias added');

  set local role authenticated;
  begin
    perform app_private.add_family_alias(v_fam, '__u1cf alias one');
    reset role;
    return next fail('CFM-11 a duplicate alias on the same Family must be refused');
  exception when unique_violation then
    reset role;
    return next ok(true, 'CFM-11 duplicate alias refused by uk_alias (23505)');
  end;

  select content_version into v_alias_cv from public.customer_family_aliases where id = v_alias_id;
  set local role authenticated;
  begin
    perform app_private.update_family_alias(v_alias_id, v_alias_cv - 1, '__u1cf alias renamed wrong');
    reset role;
    return next fail('CFM-12 a stale alias version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-12 stale alias content_version refused 40001 ('||sqlstate||')');
  end;
  set local role authenticated;
  perform app_private.update_family_alias(v_alias_id, v_alias_cv, '__u1cf alias renamed');
  select content_version into v_alias_cv from public.customer_family_aliases where id = v_alias_id;
  perform app_private.retire_family_alias(v_alias_id, v_alias_cv);
  reset role;
  return next is((select status from public.customer_family_aliases where id = v_alias_id), 'retired',
                 'CFM-13 alias retired');

  -- ── CFM-14/15/16 merge: self-merge, dual-sided CAS (both sides), cycle ─────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.merge_customer_families(v_fam, v_fam, 1, 1);
    reset role;
    return next fail('CFM-14 self-merge must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-14 self-merge refused 22023 ('||sqlstate||')');
  end;

  set local role authenticated;
  v_fam2 := app_private.propose_customer_family('__u1cf merge survivor');
  v_fam3 := app_private.propose_customer_family('__u1cf merge retiree');
  reset role;
  select content_version into v_cv  from public.customer_families where id = v_fam2;
  select content_version into v_cv2 from public.customer_families where id = v_fam3;

  -- stale SURVIVOR side alone must be caught, not just the retired side
  set local role authenticated;
  begin
    perform app_private.merge_customer_families(v_fam2, v_fam3, v_cv - 1, v_cv2);
    reset role;
    return next fail('CFM-15 a stale SURVIVOR version must be refused - the survivor side must be validated too');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-15 stale SURVIVOR side alone refused 40001 - both sides validated ('||sqlstate||')');
  end;
  -- stale RETIRED side alone must also be caught
  set local role authenticated;
  begin
    perform app_private.merge_customer_families(v_fam2, v_fam3, v_cv, v_cv2 - 1);
    reset role;
    return next fail('CFM-16 a stale RETIRED version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-16 stale RETIRED side alone refused 40001 ('||sqlstate||')');
  end;

  -- the real merge, both correct
  select content_version into v_cv  from public.customer_families where id = v_fam2;
  select content_version into v_cv2 from public.customer_families where id = v_fam3;
  set local role authenticated;
  perform app_private.merge_customer_families(v_fam2, v_fam3, v_cv, v_cv2);
  reset role;
  return next is((select status from public.customer_families where id = v_fam3), 'retired',
                 'CFM-17 the retired Family keeps its row - lineage preserved, not deleted');
  return next is((select surviving_family_id from public.customer_families where id = v_fam3), v_fam2,
                 'CFM-17a surviving_family_id points at the survivor');
  return next ok(exists (select 1 from public.customer_family_aliases
                           where family_id = v_fam2 and alias = '__u1cf merge retiree'),
                 'CFM-17b the retired name survives as an alias on the survivor');

  -- merge-cycle prevention: the now-retired v_fam3 can never be a survivor again
  select content_version into v_cv from public.customer_families where id = v_fam3;
  set local role authenticated;
  begin
    perform app_private.merge_customer_families(v_fam3, v_fam2, v_cv, v_cv);
    reset role;
    return next fail('CFM-18 a retired Family must never become a survivor');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-18 merge-cycle prevented: retired Family cannot survive a merge ('||sqlstate||')');
  end;
  -- and it cannot be retired a second time either
  select content_version into v_cv2 from public.customer_families where id = v_fam2;
  select content_version into v_cv  from public.customer_families where id = v_fam3;
  set local role authenticated;
  begin
    perform app_private.merge_customer_families(v_fam2, v_fam3, v_cv2, v_cv);
    reset role;
    return next fail('CFM-19 an already-retired Family must not be retired again');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-19 double-retirement prevented ('||sqlstate||')');
  end;

  -- ── CFM-20 atomic Prospect + silently-created Family (CDM-06) ──────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  select p.party_id, p.family_id into v_party, v_fam
    from app_private.create_minimal_prospect('__u1cf minimal prospect') p;
  reset role;
  return next ok(v_party is not null and v_fam is not null,
                 'CFM-20 create_minimal_prospect returns both the new Party and its Family');
  return next is((select lifecycle_state from public.parties where id = v_party), 'prospect',
                 'CFM-20a the Party is a Prospect');
  return next is((select name from public.customer_families where id = v_fam), '__u1cf minimal prospect',
                 'CFM-20b a Family was silently created, named after the Prospect (CDM-06)');
  return next ok((select group_customer_code from public.customer_families where id = v_fam) is not null,
                 'CFM-20c that silently-created Family also has its permanent code already');
  return next ok(exists (select 1 from public.party_family_memberships
                           where party_id = v_party and family_id = v_fam and is_current),
                 'CFM-20d and a current membership links them');

  -- reuse path: a second minimal Prospect explicitly joining the FIRST one's Family
  set local role authenticated;
  select p.party_id, p.family_id into v_party2, v_fam2
    from app_private.create_minimal_prospect('__u1cf second prospect', v_fam) p;
  reset role;
  return next is(v_fam2, v_fam, 'CFM-21 an explicit family_id is reused, not re-created');

  -- ── CFM-22 atomic rollback: a bad family_id creates NOTHING ────────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  begin
    perform app_private.create_minimal_prospect('__u1cf orphan attempt', -999999);
    reset role;
    return next fail('CFM-22 a nonexistent family_id must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = 'P0002', 'CFM-22 refused before any row is written ('||sqlstate||')');
  end;
  return next is((select count(*)::int from public.parties where display_name = '__u1cf orphan attempt'), 0,
                 'CFM-22a and no orphan Party was left behind - the whole operation rolled back');

  -- ── CFM-23 reassignment: CAS on the Party, concurrent-membership safety ────
  select content_version into v_cv from public.parties where id = v_party;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.reassign_customer_family(v_party, v_fam3, v_cv - 1, current_date);
    reset role;
    return next fail('CFM-23 a stale Party version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-23 stale Party content_version refused during reassignment 40001 ('||sqlstate||')');
  end;
  -- v_fam3 is retired - even with the RIGHT version this must be refused too
  set local role authenticated;
  begin
    perform app_private.reassign_customer_family(v_party, v_fam3, v_cv, current_date);
    reset role;
    return next fail('CFM-24 reassigning into a RETIRED Family must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-24 cannot reassign into a retired Family ('||sqlstate||')');
  end;
  -- the real reassignment, into the active survivor
  set local role authenticated;
  perform app_private.reassign_customer_family(v_party, v_fam2, v_cv, current_date);
  reset role;
  return next is((select count(*)::int from public.party_family_memberships
                   where party_id = v_party and is_current), 1,
                 'CFM-25 exactly one current membership after reassignment');
  return next is((select count(*)::int from public.party_family_memberships where party_id = v_party), 2,
                 'CFM-25a the prior membership is retained as history');

  -- ── CFM-26 grant/revoke posture on every new public wrapper ────────────────
  return next is(
    (select count(*)::int from unnest(array[
       'propose_customer_family','create_minimal_prospect','update_customer_family',
       'approve_customer_family','add_family_alias','update_family_alias',
       'retire_family_alias','merge_customer_families','reassign_customer_family',
       'graduate_customer_party']) fn
      where pg_catalog.has_function_privilege('anon',
        (select oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
          where n2.nspname='public' and p2.proname=fn limit 1), 'EXECUTE')
         or pg_catalog.has_function_privilege('service_role',
        (select oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
          where n2.nspname='public' and p2.proname=fn limit 1), 'EXECUTE')),
    0, 'CFM-26 none of the ten new public wrappers is executable by anon or service_role');
  return next is(
    (select count(*)::int from unnest(array[
       'propose_customer_family','create_minimal_prospect','update_customer_family',
       'approve_customer_family','add_family_alias','update_family_alias',
       'retire_family_alias','merge_customer_families','reassign_customer_family',
       'graduate_customer_party']) fn
      where pg_catalog.has_function_privilege('authenticated',
        (select oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
          where n2.nspname='public' and p2.proname=fn limit 1), 'EXECUTE')),
    10, 'CFM-26a all ten are executable by authenticated');

  -- ── cleanup ─────────────────────────────────────────────────────────────
  delete from public.customer_locations where party_id in
    (select id from public.parties where display_name like '\_\_u1cf%');
  delete from public.party_family_memberships where party_id in
    (select id from public.parties where display_name like '\_\_u1cf%');
  delete from public.parties where display_name like '\_\_u1cf%';
  delete from public.customer_family_aliases where family_id in
    (select id from public.customer_families where name like '\_\_u1cf%');
  delete from public.customer_families where name like '\_\_u1cf%';
  delete from public.group_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cf%');
  delete from public.plant_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cf%');
  delete from public.app_users where display_name like '\_\_u1cf%';
  return;

exception when others then
  delete from public.customer_locations where party_id in
    (select id from public.parties where display_name like '\_\_u1cf%');
  delete from public.party_family_memberships where party_id in
    (select id from public.parties where display_name like '\_\_u1cf%');
  delete from public.parties where display_name like '\_\_u1cf%';
  delete from public.customer_family_aliases where family_id in
    (select id from public.customer_families where name like '\_\_u1cf%');
  delete from public.customer_families where name like '\_\_u1cf%';
  delete from public.group_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cf%');
  delete from public.plant_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cf%');
  delete from public.app_users where display_name like '\_\_u1cf%';
  raise;
end $function$;

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
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from tests.suite_registration();
  return query select * from finish();
end $function$;
