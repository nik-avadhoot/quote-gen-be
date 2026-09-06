-- S7-5: a suite went missing from tests.run_all(), and nothing would have said so.
--
-- WHAT HAPPENED. S7-4 rewrote run_all() by hand to insert tests.interest_authority().
-- The list it was retyped from came out of s6_16_register_the_correction_suites,
-- which is NOT the newest register: s6_18_the_content_version_boundary_is_declared
-- had since appended tests.content_version_boundary() after family_f_security().
-- Retyping the older list silently dropped it, and its four CV assertions with it.
--
-- HOW IT WAS CAUGHT. Arithmetic, not luck. The new suite emits 35 assertions and
-- the total moved 755 -> 786, which is 31. Four assertions had to be somewhere,
-- and no suite showed a gap in its own numbering because the loss was a whole
-- suite rather than an assertion inside one. Reconciling the count instead of
-- accepting a green run is the only reason this is a paragraph rather than a
-- silent hole in the gate.
--
-- IT IS THE SAME FAILURE THE PROGRAMME ALREADY NAMED. session-start.md: "never
-- anchor a replacement range on what FOLLOWS the target... in prose it is
-- silent". Here the anchor was an older copy of the list, and the loss was
-- silent in exactly the way a document deletion is - which is why S6-18 itself
-- registered its suite by TEXTUAL SPLICE with a verification that raises, rather
-- than by retyping. That precaution was correct and this commit is the proof.
--
-- TWO CORRECTIONS.
--
--   1. run_all() is restored with BOTH suites in their proper places:
--      interest_authority beside the Family D suites it extends, and
--      content_version_boundary back after family_f_security where S6-18 put it.
--
--   2. tests.suite_registration() makes the whole class of error loud. It asserts
--      that every suite function in the tests schema is actually named in
--      run_all's definition, and that run_all names nothing that does not exist.
--      A suite that is written but never called proves nothing, and until now
--      the only thing standing between that and a green run was somebody
--      noticing a number. This is a new gate that was not in the S7 proposal;
--      it is added because this slice demonstrated the need for it.

create or replace function tests.suite_registration()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_def text; v_missing text; v_dangling text;
begin
  v_def := pg_catalog.pg_get_functiondef(
             (select p.oid from pg_catalog.pg_proc p
                join pg_catalog.pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'tests' and p.proname = 'run_all'));

  select string_agg(p.proname, ', ' order by p.proname) into v_missing
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'tests'
     and p.proname not like '\_\_%'
     and p.proname <> 'run_all'
     and position('tests.' || p.proname || '()' in v_def) = 0;

  return next is(coalesce(v_missing, 'none'), 'none',
    'SR-1 every suite in the tests schema is registered in run_all - a suite nobody calls proves nothing');

  select string_agg(m[1], ', ' order by m[1]) into v_dangling
    from regexp_matches(v_def, 'tests\.([a-z_0-9]+)\(\)', 'g') m
   where m[1] <> 'run_all'
     and m[1] not like '\_\_%'
     and not exists (select 1 from pg_catalog.pg_proc p
                       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'tests' and p.proname = m[1]);

  return next is(coalesce(v_dangling, 'none'), 'none',
    'SR-2 and run_all names no suite that does not exist');
end $fn$;

revoke all on function tests.suite_registration() from public, anon, authenticated;

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
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from tests.suite_registration();
  return query select * from finish();
end $fn$;

-- Fail the MIGRATION, not just the suite, if the register is incomplete at the
-- moment it is written. Same intent as the S6-18 splice guard.
do $$
declare v_def text; v_missing text;
begin
  v_def := pg_catalog.pg_get_functiondef(
             (select p.oid from pg_catalog.pg_proc p
                join pg_catalog.pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'tests' and p.proname = 'run_all'));
  select string_agg(p.proname, ', ' order by p.proname) into v_missing
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'tests' and p.proname not like '\_\_%' and p.proname <> 'run_all'
     and position('tests.' || p.proname || '()' in v_def) = 0;
  if v_missing is not null then
    raise exception 'run_all does not register: %', v_missing;
  end if;
end $$;
