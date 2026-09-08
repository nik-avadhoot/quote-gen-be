-- UA-5 - register the status-governance suite. tests.suite_registration()
-- enforces that every tests.* suite is reachable from run_all(), so an
-- unregistered suite is itself a failure.

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
  return query select * from tests.user_capability_governance();
  return query select * from tests.capability_write_bypass_closed();
  return query select * from tests.user_status_governance();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from tests.suite_registration();
  return query select * from finish();
end $function$;
