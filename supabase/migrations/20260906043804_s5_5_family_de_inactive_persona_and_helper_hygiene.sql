-- S5-5: the security personas Family D and E were never asked about.
--
-- The S5 authorisation requires evidence for anonymous, INACTIVE,
-- missing-capability and wrong-plant denial. Reviewing the S5 gate inventory
-- found:
--
--   * anonymous        - 12 catalogue-level gates (has_table_privilege), plus a
--                        52-check HTTP probe added alongside this migration
--   * missing capability - MD-11, PB-12, MR-10 and friends
--   * wrong plant      - MR-8 x6, PB-22/23
--   * INACTIVE         - NOTHING. Zero gates.
--
-- PS-28 proves it for Family C; Family D and E had no equivalent. Behaviour was
-- probed before writing these gates and was already correct, so this closes an
-- EVIDENCE gap rather than a defect - but an untested persona is an untested
-- persona, and deactivation is the one that protects against a still-valid token
-- in the wrong hands (CDM-05).
--
-- DS-6 records a property worth stating once: a deactivated caller's UPDATE is
-- not refused with an error, it silently matches no row, because RLS filters it
-- out. The gate therefore reads the row back rather than trusting the absence of
-- an exception - the same lesson PB-20 records.
--
-- HELPER DISCLOSURE, qualified rather than overstated. app_private.has_any_plant_cap
-- answers "does the caller hold this capability at ANY plant" for a supplied
-- capability key. It returns one boolean about the CALLER only - it names no
-- plant, exposes no grant row and reveals nothing about any other user, and it
-- is unreachable through the exposed API (PGRST202 from public, PGRST106 from
-- app_private, both re-probed). What it does disclose, to any authenticated
-- caller, is that caller's own capability shape one bit at a time. That is
-- strictly less than public.capabilities already exposes as vocabulary, and less
-- than the caller's own grants, which group_/plant_capability_grants already let
-- them read. Recorded so the boundary is stated accurately.

create or replace function tests.family_de_security()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['sectors','sector_versions','calculation_default_versions',
                           'payment_interest_map_entries','rate_sets','rate_set_versions',
                           'rate_entries','freight_sets','freight_set_versions',
                           'freight_entries','pricing_basis_releases'];
  t text; v_owner bigint; v_nag bigint; v_n int; v_state text; v_before text;
  v_auth uuid; v_claims text; v_uid bigint; v_email text := 'p2-s5sec@example.invalid';
  v_sec bigint; v_sv bigint; v_cdv bigint; v_rs bigint; v_rsv bigint;
  v_fs bigint; v_fsv bigint;
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

  -- ------------------------------------------------------- fixtures
  v_auth := tests.__fixture_auth_uid();
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_s5_sec', false);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated; v_uid := public.bootstrap_app_user(); reset role;

  -- fully capable at NAG, so the denial below can only come from deactivation
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_uid, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','propose_commercial_master','approve_commercial_master');
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_uid, c.id, v_owner from public.capabilities c where c.capability_key = 'read_party_master';

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

  -- the ACTIVE baseline, so every zero below is denial rather than emptiness
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated; select count(*) into v_n from public.sectors; reset role;
  return next ok(v_n > 0, 'DS-4 while ACTIVE the caller sees the group masters');
  set local role authenticated; select count(*) into v_n from public.rate_sets where plant_id = v_nag; reset role;
  return next ok(v_n > 0, 'DS-4a and their own plant rate sets');

  -- ------------------------------------ deactivate, same still-valid token
  update public.app_users set status = 'deactivated', deactivated_at = now() where id = v_uid;
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);

  foreach t in array v_tables loop
    set local role authenticated;
    execute format('select count(*) from public.%I', t) into v_n;
    reset role;
    return next is(v_n, 0,
      format('DS-5 a DEACTIVATED user sees nothing in %s, holding the same token (CDM-05)', t));
  end loop;

  set local role authenticated;
  begin
    insert into public.sectors (sector_code, name, created_by) values ('__P2SEC2','__p2 sec two', v_uid);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'DS-6 and cannot create a master');

  -- an RLS-filtered UPDATE is not an error, so read the row back
  v_before := (select status from public.sector_versions where id = v_sv);
  set local role authenticated;
  update public.sector_versions set status = 'approved' where id = v_sv;
  reset role;
  return next is((select status from public.sector_versions where id = v_sv), v_before,
    'DS-7 nor approve one - the row is untouched, because the UPDATE matched nothing rather than raising');

  set local role authenticated;
  begin
    perform public.propose_pricing_basis_release(v_nag, current_date, v_rsv, v_fsv, v_sv, v_cdv);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'DS-8 nor reach the Pricing Basis operations through their RPC');

  -- and every capability answer collapses at once
  set local role authenticated;
  return next ok(not app_private.has_any_plant_cap('approve_commercial_master'),
                 'DS-9 every capability the helper reports collapses on deactivation');
  reset role;

  -- ------------------------------------------------------------- cleanup
  update public.app_users set status = 'active', deactivated_at = null where id = v_uid;
  delete from public.freight_set_versions where freight_set_id = v_fs;
  delete from public.freight_sets where id = v_fs;
  delete from public.rate_set_versions where rate_set_id = v_rs;
  delete from public.rate_sets where id = v_rs;
  delete from public.payment_interest_map_entries where calculation_default_version_id = v_cdv;
  delete from public.calculation_default_versions where id = v_cdv;
  delete from public.sector_versions where sector_id = v_sec;
  delete from public.sectors where id = v_sec;
  delete from public.plant_capability_grants where app_user_id = v_uid;
  delete from public.group_capability_grants where app_user_id = v_uid;
  delete from public.operational_settings     where created_by  = v_uid;
  delete from app_private.pending_invitations where invite_email = v_email;
  delete from public.app_users where id = v_uid;
  perform tests.__drop_synthetic_auth(v_auth);
end $fn$;

revoke all on function tests.family_de_security() from public;
revoke all on function tests.family_de_security() from anon;
revoke all on function tests.family_de_security() from authenticated;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
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
  return query select * from tests.pricing_basis();
  return query select * from tests.family_de_security();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from finish();
end $fn$;