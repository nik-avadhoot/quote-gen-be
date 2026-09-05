-- S4-5: permanent coverage for the S4-1 defect, creator anti-spoofing and
-- child-table plant isolation.
--
-- Every denial here asserts the SQLSTATE, not merely that something failed.
-- That is the point. A test that only records "rejected" cannot tell an
-- authority check from a neighbouring restriction, so a broken policy can hide
-- behind a not-null, a foreign key or a check constraint and still look green.
-- These gates require 42501 - the row-level security refusal - so a 23502,
-- 23503 or 23514 fails the gate even though the write was still refused.
--
-- Lives in its own suite rather than being folded into construction_library()
-- or sku_master(): the accepted suites are left exactly as they were, and this
-- one states precisely what the review found missing.

create or replace function tests.family_c_authority()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_auth uuid;  v_claims text;  v_maker bigint;
  v_nauth uuid; v_nclaims text; v_npd bigint;
  v_owner bigint; v_nag bigint; v_pun bigint; v_party bigint; v_loc bigint;
  v_kprop bigint; v_kpub bigint; v_kmerged bigint; v_vpub bigint;
  v_sku_nag bigint; v_sku_pun bigint;
  v_state text; v_seen int; v_before int;
  v_memail text := 'p2-s4a-m@example.invalid';
  v_nemail text := 'p2-s4a-n@example.invalid';
begin
  select id into v_owner from public.app_users order by id limit 1;
  select id into v_nag   from public.plants where plant_code = 'NAG';
  select id into v_pun   from public.plants where plant_code = 'PUN';

  -- ------------------------------------------------------ helper hygiene
  return next ok(
    (select p.prosecdef from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app_private' and p.proname = 'construction_is_proposed'),
    'FA-1 the parent-status helper is SECURITY DEFINER in app_private, off every exposed schema');

  return next ok(
    (select p.proconfig @> array['search_path='] from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app_private' and p.proname = 'construction_is_proposed'),
    'FA-2 and pins an empty search_path');

  return next ok(
    not (select pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
           from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'app_private' and p.proname = 'construction_is_proposed'),
    'FA-3 anon cannot execute it');

  -- ---------------------------------------------------------- fixtures
  v_auth   := tests.__fixture_auth_uid();
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_memail, '__p2_s4a_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated; v_maker := public.bootstrap_app_user(); reset role;

  v_nauth   := tests.__fixture_auth_uid();
  v_nclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_nauth, v_nemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_nemail, '__p2_s4a_npd', false);
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated; v_npd := public.bootstrap_app_user(); reset role;

  -- Maker: make_quote + plant_access at NAG. NO group capability of any kind.
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  -- NPD: the library capability, to prove the master branch still works
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_npd, c.id, v_owner from public.capabilities c
   where c.capability_key = 'manage_construction_library';

  insert into public.parties (display_name, created_by) values ('__p2 fa party', v_owner)
    returning id into v_party;
  insert into public.customer_locations (party_id, bill_to_eligible, ship_to_eligible, created_by)
    values (v_party, true, true, v_owner) returning id into v_loc;

  -- a PROPOSED Construction owned by the Maker, a PUBLISHED one, and a MERGED one
  insert into public.constructions (name, status, created_by)
  values ('__p2 fa proposed', 'proposed', v_maker) returning id into v_kprop;
  insert into public.constructions (name, created_by) values ('__p2 fa published', v_owner)
    returning id into v_kpub;
  insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kpub, 1, 3, v_owner) returning id into v_vpub;
  update public.constructions set construction_code = 'CON-996001', status = 'published'
   where id = v_kpub;
  insert into public.constructions (name, created_by) values ('__p2 fa merged', v_owner)
    returning id into v_kmerged;
  update public.constructions set status = 'merged', surviving_construction_id = v_kpub
   where id = v_kmerged;

  -- SKUs at both plants, with children only at PUN
  insert into public.skus (plant_id, party_id, created_by) values (v_nag, v_party, v_owner)
    returning id into v_sku_nag;
  insert into public.skus (plant_id, party_id, created_by) values (v_pun, v_party, v_owner)
    returning id into v_sku_pun;
  insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id,
                                   is_price_driving, created_by)
  values (v_sku_pun, v_pun, 1, v_vpub, true, v_owner);
  insert into public.sku_external_references (sku_id, plant_id, reference_kind, reference_value, created_by)
  values (v_sku_pun, v_pun, 'alias', '__p2 fa pun alias', v_owner);
  insert into public.sku_location_applicabilities
    (sku_id, plant_id, party_id, location_id, scope, created_by)
  values (v_sku_pun, v_pun, v_party, v_loc, 'master', v_owner);
  insert into public.plant_construction_adoptions (plant_id, construction_version_id, adopted_by)
  values (v_pun, v_vpub, v_owner);

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);

  -- ============================================ the repaired route, positive
  v_before := (select count(*)::int from public.construction_versions where construction_id = v_kprop);
  set local role authenticated;
  begin
    insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kprop, 1, 3, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR',
    'FA-4 a Maker MAY write version 1 of the Construction they proposed (CDM-12/DM-144)');
  return next is((select count(*)::int from public.construction_versions where construction_id = v_kprop),
                 v_before + 1,
                 'FA-4a and the row is actually there - the route works, it does not merely not raise');

  -- ===================================== and read authority is NOT broadened
  set local role authenticated;
  select count(*) into v_seen from public.constructions;
  reset role;
  return next is(v_seen, 0,
    'FA-5 the Maker STILL cannot read any Construction - the helper granted write, not read');

  set local role authenticated;
  select count(*) into v_seen from public.construction_versions;
  reset role;
  return next is(v_seen, 0,
    'FA-6 nor read back the version they just wrote - read_construction_library is still required');

  -- ================================ denials, each attributed to 42501 exactly
  set local role authenticated;
  begin
    insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kpub, 2, 3, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FA-7 a version under a PUBLISHED parent is refused BY THE POLICY, not by a constraint');

  set local role authenticated;
  begin
    insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kmerged, 1, 3, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FA-8 and under a MERGED parent - the helper answers false for every non-proposed status');

  set local role authenticated;
  begin
    insert into public.construction_versions (construction_id, version_no, ply, approved_by, approved_at, created_by)
    values (v_kprop, 2, 3, v_maker, now(), v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FA-9 a PRE-APPROVED version is refused by the policy - approval is never self-served');

  set local role authenticated;
  begin
    insert into public.construction_versions (construction_id, version_no, ply, approved_by, created_by)
    values (v_kprop, 2, 3, v_owner, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FA-9a and approved_by alone is refused by the POLICY, before ck_cv_approval_pair is reached');

  set local role authenticated;
  begin
    insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kprop, 2, 3, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FA-10 a version attributed to somebody else is refused (CDM-34)');

  -- a caller holding NO make_quote and no library capability
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  delete from public.group_capability_grants where app_user_id = v_npd;
  set local role authenticated;
  begin
    insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kprop, 2, 3, v_npd);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FA-11 a caller with neither make_quote nor the library capability is refused');

  -- the master branch must still work, unchanged
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_npd, c.id, v_owner from public.capabilities c
   where c.capability_key = 'manage_construction_library';
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kpub, 2, 5, v_npd);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR',
    'FA-12 the master route is untouched - a library manager may still version a PUBLISHED Construction');

  -- ================================ creator anti-spoofing on every Maker branch
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);

  set local role authenticated;
  begin
    insert into public.constructions (name, status, created_by)
    values ('__p2 fa spoof', 'proposed', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FA-13 constructions: a proposal cannot be attributed to another user');

  set local role authenticated;
  begin
    insert into public.skus (plant_id, party_id, status, created_by)
    values (v_nag, v_party, 'proposed', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FA-14 skus: same, on the row own plant');

  set local role authenticated;
  begin
    insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id,
                                     is_price_driving, created_by)
    values (v_sku_nag, v_nag, 1, v_vpub, true, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FA-15 sku_versions: same');

  set local role authenticated;
  begin
    insert into public.sku_location_applicabilities
      (sku_id, plant_id, party_id, location_id, scope, status, created_by)
    values (v_sku_nag, v_nag, v_party, v_loc, 'batch_only', 'proposed', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FA-16 sku_location_applicabilities: same');

  -- ============================ plant isolation on every Family C child table
  -- Rows exist at PUN; the Maker is granted only at NAG. Each of these tables
  -- carries its own SELECT policy on its own plant_id, and until now only
  -- `skus` had that policy exercised from a wrong-plant session.
  set local role authenticated; select count(*) into v_seen from public.sku_versions; reset role;
  return next is(v_seen, 0, 'FA-17 wrong-plant sku_versions are invisible');

  set local role authenticated; select count(*) into v_seen from public.sku_external_references; reset role;
  return next is(v_seen, 0, 'FA-18 wrong-plant sku_external_references are invisible');

  set local role authenticated; select count(*) into v_seen from public.sku_location_applicabilities; reset role;
  return next is(v_seen, 0, 'FA-19 wrong-plant sku_location_applicabilities are invisible');

  set local role authenticated; select count(*) into v_seen from public.plant_construction_adoptions; reset role;
  return next is(v_seen, 0, 'FA-20 wrong-plant plant_construction_adoptions are invisible');

  -- and the positive control, so FA-17..20 cannot pass by the tables being empty
  insert into public.sku_external_references (sku_id, plant_id, reference_kind, reference_value, created_by)
  values (v_sku_nag, v_nag, 'alias', '__p2 fa nag alias', v_owner);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated; select count(*) into v_seen from public.sku_external_references; reset role;
  return next is(v_seen, 1,
    'FA-21 but the Maker own plant IS visible - the zeroes above are isolation, not emptiness');

  -- ------------------------------------------------------------- cleanup
  delete from public.plant_construction_adoptions
   where construction_version_id in (
     select cv.id from public.construction_versions cv
      join public.constructions k on k.id = cv.construction_id
     where k.name like '\_\_p2 fa%');
  delete from public.sku_location_applicabilities
   where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.sku_external_references
   where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.sku_versions
   where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.skus where party_id = v_party;
  delete from public.construction_versions
   where construction_id in (select id from public.constructions where name like '\_\_p2 fa%');
  update public.constructions set surviving_construction_id = null
   where name like '\_\_p2 fa%' and status <> 'merged';
  delete from public.constructions
   where name like '\_\_p2 fa%' and surviving_construction_id is not null;
  delete from public.constructions where name like '\_\_p2 fa%';
  delete from public.customer_locations where party_id = v_party;
  delete from public.parties where id = v_party;
  delete from public.plant_capability_grants where app_user_id in (v_maker, v_npd);
  delete from public.group_capability_grants where app_user_id in (v_maker, v_npd);
  delete from public.operational_settings     where created_by  in (v_maker, v_npd);
  delete from app_private.pending_invitations where invite_email in (v_memail, v_nemail);
  delete from public.app_users where id in (v_maker, v_npd);
  perform tests.__drop_synthetic_auth(v_auth);
  perform tests.__drop_synthetic_auth(v_nauth);
end $fn$;

revoke all on function tests.family_c_authority() from public;
revoke all on function tests.family_c_authority() from anon;
revoke all on function tests.family_c_authority() from authenticated;