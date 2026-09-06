-- S5-6: the inactive-persona baseline must cover every table it asserts.
--
-- REVIEW FINDING, and it is the same class of defect this programme keeps
-- catching. tests.family_de_security() asserted "a DEACTIVATED user sees
-- nothing" across ELEVEN tables, but the fixture populated only seven of them
-- and the ACTIVE baseline covered only TWO - sectors and rate_sets. For
-- payment_interest_map_entries, rate_entries, freight_entries and
-- pricing_basis_releases the fixture inserted no row at all, so the assertion
-- compared zero against a table it had never written to. Four of the twenty DS
-- gates passed because the table was empty, not because access was denied.
--
-- The migration's own stated design was right - "an ACTIVE baseline first so
-- every zero is denial rather than emptiness" - and was implemented for two of
-- eleven. This closes the gap the same way it was described: every one of the
-- eleven tables now carries a fixture row the ACTIVE caller can see, asserted
-- table by table, immediately before deactivation turns each of those same
-- counts to zero. The two loops walk one array, so they cannot drift apart.
--
-- ORDERING MATTERS HERE, and it is the accepted schema doing its job. Entry rows
-- may only be written while their version is draft (guard_*_follows_version), and
-- a Pricing Basis Release may only cite APPROVED components
-- (guard_release_components_approved). So the fixture inserts every entry first,
-- approves the four component versions second, and creates the Release third. A
-- fixture that ignored that order fails - which is two accepted S5 rules working,
-- not an obstacle to work around.
--
-- DS-7 NEEDS A DRAFT VERSION to attempt approving, and version 1 is approved by
-- the time it runs. A second sector version is minted for it. Approving an
-- already-approved version would raise for immutability rather than for
-- deactivation, and the gate would prove the wrong rule - the exact failure mode
-- PB-10 recorded.
--
-- Gate count rises from 20 to 29: DS-1..3 hygiene, DS-4 x11 active baseline,
-- DS-5 x11 deactivated denial, DS-6..9 write, approve, RPC and helper.

create or replace function tests.family_de_security()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['sectors','sector_versions','calculation_default_versions',
                           'payment_interest_map_entries','rate_sets','rate_set_versions',
                           'rate_entries','freight_sets','freight_set_versions',
                           'freight_entries','pricing_basis_releases'];
  t text; v_owner bigint; v_nag bigint; v_n int; v_state text; v_before text;
  v_auth uuid; v_claims text; v_uid bigint; v_email text := 'p2-s5sec@example.invalid';
  v_sec bigint; v_sv bigint; v_sv2 bigint; v_cdv bigint; v_rs bigint; v_rsv bigint;
  v_fs bigint; v_fsv bigint; v_rel bigint;
  v_fam bigint; v_party bigint; v_loc bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';

  -- ------------------------------------------------- helper hygiene
  return next ok(
    (select p.prosecdef from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='app_private' and p.proname='has_any_plant_cap'),
    'DS-1 has_any_plant_cap is SECURITY DEFINER in app_private, off every exposed schema');
  return next is(
    (select p.proconfig from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app_private' and p.proname='has_any_plant_cap'),
    (select p.proconfig from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app_private' and p.proname='has_plant_cap'),
    'DS-2 and is configured exactly like has_plant_cap, an accepted Phase 2 definer');
  return next ok(
    not (select pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
           from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
          where n.nspname='app_private' and p.proname='has_any_plant_cap'),
    'DS-3 anon cannot execute it');

  -- ------------------------------------------------------- the caller
  v_auth := tests.__fixture_auth_uid();
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_s5_sec', false);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated; v_uid := public.bootstrap_app_user(); reset role;

  -- fully capable at NAG, so every denial below can only come from deactivation
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_uid, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','propose_commercial_master','approve_commercial_master');
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_uid, c.id, v_owner from public.capabilities c where c.capability_key = 'read_party_master';

  -- --------------------------------------- a row in every asserted table
  -- Family B support, needed only as the freight entry's destination
  insert into public.customer_families (name, status, created_by)
    values ('__p2 s5sec family','active',v_owner) returning id into v_fam;
  insert into public.parties (display_name, created_by)
    values ('__p2 s5sec party', v_owner) returning id into v_party;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    values (v_party, v_fam, current_date, v_owner);
  insert into public.customer_locations (party_id, ship_to_eligible, created_by)
    values (v_party, true, v_owner) returning id into v_loc;

  insert into public.sectors (sector_code, name, created_by)
    values ('__P2SEC','__p2 sec sector', v_owner) returning id into v_sec;
  insert into public.sector_versions (sector_id, version_no, margin_pct, created_by)
    values (v_sec, 1, 8.000, v_owner) returning id into v_sv;
  insert into public.calculation_default_versions (version_no, engine_version, rounding_rule_version, created_by)
    values (957, 'engine-sec', 'round-sec', v_owner) returning id into v_cdv;
  insert into public.rate_sets (plant_id, name, created_by)
    values (v_nag, '__p2 sec rs', v_owner) returning id into v_rs;
  insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
    values (v_rs, v_nag, 1, v_owner) returning id into v_rsv;
  insert into public.freight_sets (plant_id, name, created_by)
    values (v_nag, '__p2 sec fs', v_owner) returning id into v_fs;
  insert into public.freight_set_versions (freight_set_id, plant_id, version_no, created_by)
    values (v_fs, v_nag, 1, v_owner) returning id into v_fsv;

  -- entries first: each may only be written while its version is still draft
  insert into public.payment_interest_map_entries
    (calculation_default_version_id, credit_days, interest_pct, created_by)
    values (v_cdv, 30, 0.500, v_owner);
  insert into public.rate_entries (rate_set_version_id, plant_id, grade_code, price, created_by)
    values (v_rsv, v_nag, '__P2SECG', 10.0000, v_owner);
  insert into public.freight_entries
    (freight_set_version_id, plant_id, origin_plant_id, destination_location_id, rate, created_by)
    values (v_fsv, v_nag, v_nag, v_loc, 1.0000, v_owner);

  -- approve the four components, as the still-ACTIVE caller who holds
  -- approve_commercial_master; the transition trigger reads the session, so the
  -- claims must be in place even though RLS is not in the way here
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  update public.sector_versions              set status = 'approved' where id = v_sv;
  update public.calculation_default_versions set status = 'approved' where id = v_cdv;
  update public.rate_set_versions            set status = 'approved' where id = v_rsv;
  update public.freight_set_versions         set status = 'approved' where id = v_fsv;

  -- and only now can a Release exist at all (guard_release_components_approved)
  insert into public.pricing_basis_releases
    (plant_id, effective_from, rate_set_version_id, freight_set_version_id,
     sector_version_id, calculation_default_version_id, proposed_by)
  values (v_nag, date '2026-02-01', v_rsv, v_fsv, v_sv, v_cdv, v_owner)
  returning id into v_rel;

  -- a DRAFT version for DS-7, because version 1 is approved and therefore
  -- immutable - approving it would raise for the wrong rule
  insert into public.sector_versions (sector_id, version_no, margin_pct, created_by)
    values (v_sec, 2, 9.000, v_owner) returning id into v_sv2;

  -- ============================================ the ACTIVE baseline
  -- Every zero below this line has to mean denial. That is only true if the
  -- same caller could see a row in the same table a moment earlier.
  foreach t in array v_tables loop
    perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
    set local role authenticated;
    execute format('select count(*) from public.%I', t) into v_n;
    reset role;
    return next ok(v_n > 0,
      format('DS-4 while ACTIVE the caller can see rows in %s - the baseline this suite needs', t));
  end loop;

  -- ------------------------------------ deactivate, same still-valid token
  update public.app_users set status = 'deactivated', deactivated_at = now() where id = v_uid;

  foreach t in array v_tables loop
    perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
    set local role authenticated;
    execute format('select count(*) from public.%I', t) into v_n;
    reset role;
    return next is(v_n, 0,
      format('DS-5 a DEACTIVATED user sees nothing in %s, holding the same token (CDM-05)', t));
  end loop;

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  begin
    insert into public.sectors (sector_code, name, created_by) values ('__P2SEC2','__p2 sec two', v_uid);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'DS-6 and cannot create a master');

  -- an RLS-filtered UPDATE is not an error, so read the row back
  v_before := (select status from public.sector_versions where id = v_sv2);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  update public.sector_versions set status = 'approved' where id = v_sv2;
  reset role;
  return next is((select status from public.sector_versions where id = v_sv2), v_before,
    'DS-7 nor approve a DRAFT one - the row is untouched, because the UPDATE matched nothing rather than raising');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  begin
    perform public.propose_pricing_basis_release(v_nag, current_date, v_rsv, v_fsv, v_sv, v_cdv);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'DS-8 nor reach the Pricing Basis operations through their RPC');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  return next ok(not app_private.has_any_plant_cap('approve_commercial_master'),
                 'DS-9 every capability the helper reports collapses on deactivation');
  reset role;

  -- ------------------------------------------------------------- cleanup
  update public.app_users set status = 'active', deactivated_at = null where id = v_uid;
  delete from public.pricing_basis_releases where id = v_rel;
  delete from public.freight_entries where freight_set_version_id = v_fsv;
  delete from public.freight_set_versions where freight_set_id = v_fs;
  delete from public.freight_sets where id = v_fs;
  delete from public.rate_entries where rate_set_version_id = v_rsv;
  delete from public.rate_set_versions where rate_set_id = v_rs;
  delete from public.rate_sets where id = v_rs;
  delete from public.payment_interest_map_entries where calculation_default_version_id = v_cdv;
  delete from public.calculation_default_versions where id = v_cdv;
  delete from public.sector_versions where sector_id = v_sec;
  delete from public.sectors where id = v_sec;
  delete from public.customer_locations where id = v_loc;
  delete from public.party_family_memberships where party_id = v_party;
  delete from public.parties where id = v_party;
  delete from public.customer_families where id = v_fam;
  delete from public.plant_capability_grants where app_user_id = v_uid;
  delete from public.group_capability_grants where app_user_id = v_uid;
  delete from public.operational_settings     where created_by  = v_uid;
  delete from app_private.pending_invitations where invite_email = v_email;
  delete from public.app_users where id = v_uid;
  perform tests.__drop_synthetic_auth(v_auth);
  perform pg_catalog.set_config('request.jwt.claims', null, true);
end $fn$;

revoke all on function tests.family_de_security() from public;
revoke all on function tests.family_de_security() from anon;
revoke all on function tests.family_de_security() from authenticated;
