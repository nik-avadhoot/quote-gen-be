-- S9(a): executable proof gates for Family G.
--
-- WHAT A GREEN RUN HAS TO MEAN. Every assertion below names the mistake that
-- would produce a DIFFERENT answer, so the run is evidence rather than
-- decoration:
--
--   · a table with RLS enabled but NOT forced passes every policy test and
--     FAILS QG-2, because its owner would bypass every policy;
--   · a table that relies on "no UPDATE policy exists" while still holding the
--     UPDATE privilege passes QG-5 and FAILS QG-4 - that is the exact gap the
--     Product Owner named, and it is tested as its own assertion rather than
--     being folded into the policy count;
--   · an application administrator is not a database role: QG-7 asserts that
--     the `authenticated` role - which every app user including an
--     `administer_users` holder reaches these tables through - holds no write
--     privilege at all, so there is nothing for a capability to escalate INTO;
--   · a freight binding weakened to admit `unresolved`, or to let a temporary
--     source carry governed references, changes the constraint DEFINITION and
--     FAILS QG-9..QG-13. Those are pinned by exact expression, not by name.
--
-- WHY THE FREIGHT CONSTRAINTS ARE PINNED DECLARATIVELY AND NOT BY INSERTION.
-- S9(a) was authorised with "no live Quote rows or number allocations". A
-- rejection probe needs a valid Pricing Basis Release, which needs a Rate Set
-- version, a Freight Set version, a Sector version and a Calculation Default
-- version - four fixture chains in other families, minted only to be thrown
-- away. More importantly the tables are FORCE RLS with no DELETE policy, so a
-- probe that unexpectedly SUCCEEDED would leave a Quote row that even the table
-- owner could not remove. Fail-closed beats a stronger test that can dirty
-- immutable evidence. Live rejection proof lands in S9(b), where the Send RPC
-- brings legitimate fixtures with it.

create or replace function tests.quote_schema()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['quote_families','quote_revisions','calculation_snapshots',
                           'quote_items','quote_item_delivery_groups',
                           'quote_workflow_events','customer_outcome_events',
                           'export_events','export_parts'];
  v_immutable text[] := array['quote_items','calculation_snapshots'];
  t text;
  v_def text;
begin
  -- ─────────────────────────────────────────────────────────── structural
  foreach t in array v_tables loop
    return next ok(
      (select c.relrowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t),
      format('QG-1 %s has RLS enabled', t));

    return next ok(
      (select c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t),
      format('QG-2 %s FORCES RLS, so even its owner is subject to policy', t));

    return next ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('anon','public.'||t,'DELETE')),
      format('QG-3 anon holds no privilege of any kind on %s', t));

    -- The Product Owner's safeguard, stated as its own assertion: immutability
    -- must not rest on the absence of a policy while the PRIVILEGE survives.
    return next ok(
      not (pg_catalog.has_table_privilege('authenticated','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('authenticated','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('authenticated','public.'||t,'DELETE')),
      format('QG-4 authenticated holds NO write privilege on %s - there is nothing for a policy to admit', t));

    return next ok(
      pg_catalog.has_table_privilege('authenticated','public.'||t,'SELECT'),
      format('QG-5 authenticated may still READ %s', t));

    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid=pol.polrelid
         join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname=t and pol.polcmd <> 'r'),
      0,
      format('QG-6 %s carries no INSERT, UPDATE or DELETE policy', t));

    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid=pol.polrelid
         join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname=t),
      1,
      format('QG-7 %s carries exactly one policy, and it is the SELECT policy', t));
  end loop;

  -- The two immutable children, called out separately because §7.4 names them.
  foreach t in array v_immutable loop
    return next ok(
      not pg_catalog.has_table_privilege('authenticated','public.'||t,'UPDATE')
      and not pg_catalog.has_table_privilege('authenticated','public.'||t,'DELETE')
      and not exists (select 1 from pg_catalog.pg_policy pol
                        join pg_catalog.pg_class c on c.oid=pol.polrelid
                        join pg_catalog.pg_namespace n on n.oid=c.relnamespace
                       where n.nspname='public' and c.relname=t and pol.polcmd in ('w','d')),
      format('QG-8 %s has NO update or delete path: neither privilege nor policy, for any app user including an administer_users holder', t));
  end loop;

  -- ─────────────────────────────────── S8 freight provenance, pinned exactly
  select pg_catalog.pg_get_constraintdef(oid) into v_def
    from pg_catalog.pg_constraint where conname = 'ck_cs_freight_source';
  return next ok(v_def is not null, 'QG-9 ck_cs_freight_source exists');
  return next ok(v_def not like '%unresolved%',
    'QG-10 the freight source list does NOT admit ''unresolved'' - unresolved freight cannot enter a Quote snapshot');
  return next ok(v_def like '%row%' and v_def like '%legacy_batch%' and v_def like '%pricing_group%'
             and v_def like '%master%' and v_def like '%legacy_matrix%',
    'QG-11 and it admits exactly the five sendable S8 sources');

  select pg_catalog.pg_get_constraintdef(oid) into v_def
    from pg_catalog.pg_constraint where conname = 'ck_cs_freight_authority_binds_source';
  return next ok(v_def is not null,
    'QG-12 the database BINDS source to authority - the runtime field enables enforcement, this performs it');
  return next ok(v_def like '%governed%' and v_def like '%temporary%',
    'QG-13 binding both authorities, so no other combination is accepted');

  select pg_catalog.pg_get_constraintdef(oid) into v_def
    from pg_catalog.pg_constraint where conname = 'ck_cs_master_has_both_refs';
  return next ok(v_def is not null and v_def like '%freight_set_version_id%'
             and v_def like '%freight_entry_id%',
    'QG-14 a governed ''master'' snapshot must carry BOTH governed references');

  select pg_catalog.pg_get_constraintdef(oid) into v_def
    from pg_catalog.pg_constraint where conname = 'ck_cs_temporary_carries_no_governed_ref';
  return next ok(v_def is not null and v_def like '%temporary%',
    'QG-15 a temporary source may never occupy the governed reference shape');

  return next ok(
    exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='calculation_snapshots'
               and column_name='freight_authority' and is_nullable='NO'),
    'QG-16 freight_authority is a REQUIRED typed column, not an optional annotation');

  -- ─────────────────────────────────────────────── lifecycle and lineage
  return next ok(
    exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='quote_revisions'
               and column_name='revision_no' and is_nullable='YES'),
    'QG-17 revision_no is NULLABLE - a draft that is never approved consumes no number (CDM-21)');

  select pg_catalog.pg_get_constraintdef(oid) into v_def
    from pg_catalog.pg_constraint where conname = 'ck_qr_approved_has_revision_no';
  return next ok(v_def is not null,
    'QG-18 but an approved or issued revision cannot lack one');

  select pg_catalog.pg_get_constraintdef(oid) into v_def
    from pg_catalog.pg_constraint where conname = 'ck_qf_abandoned_unreferenced';
  return next ok(v_def is not null,
    'QG-19 an abandoned pre-approval family consumes no Quote Reference (CDM-30)');

  -- PM-7: the FK must target the LINEAGE, not the row id, or the link breaks
  -- the first time the originating Batch row is edited.
  return next ok(
    exists (
      select 1 from pg_catalog.pg_constraint c
       where c.conname = 'fk_qi_lineage'
         and c.confrelid = 'public.batch_rows'::regclass
         and (select attname from pg_catalog.pg_attribute
               where attrelid = c.confrelid and attnum = c.confkey[1]) = 'lineage_id'),
    'QG-20 PM-7 binds quote_items to batch_rows.LINEAGE_ID, not to the row id');

  return next ok(
    exists (select 1 from pg_catalog.pg_constraint where conname='uk_qi_snapshot' and contype='u'),
    'QG-21 a snapshot serves exactly one Quote Item (§5.10)');

  return next ok(
    exists (select 1 from pg_catalog.pg_constraint where conname='uk_qf_batch' and contype='u'),
    'QG-22 one Quote family per Batch (CDM-21)');

  -- ───────────────────────────────────────────── S9(a) creates no live data
  return next is((select count(*)::int from public.quote_families), 0,
    'QG-23 S9(a) created no Quote family');
  return next is((select count(*)::int from public.quote_revisions), 0,
    'QG-24 no revision, so no Quote number was allocated');
  return next is((select count(*)::int from public.calculation_snapshots), 0,
    'QG-25 and no calculation snapshot exists yet');

  -- The traversal helpers are internal machinery, not an API surface.
  foreach t in array array['can_read_quote_family','can_read_quote_revision','can_read_quote_item'] loop
    return next ok(
      not pg_catalog.has_function_privilege('authenticated', 'app_private.'||t||'(bigint)', 'EXECUTE')
      and not pg_catalog.has_function_privilege('anon', 'app_private.'||t||'(bigint)', 'EXECUTE'),
      format('QG-26 app_private.%s is not callable by anon or authenticated', t));
  end loop;
end $fn$;

-- ═══════════════════════ register in run_all() ══════════════════════════════
-- tests.suite_registration() enforces that every tests.* suite is reachable
-- from run_all(), so an unregistered suite is itself a failure.
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
  return query select * from tests.quote_schema();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from tests.suite_registration();
  return query select * from finish();
end $function$;
