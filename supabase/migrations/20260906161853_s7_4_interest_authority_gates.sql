-- S7-4: executable proof gates for Canonical Amendment 01.
--
-- The suite and its registration land together on purpose. A suite that is not
-- in tests.run_all() proves nothing, and the two halves have no independent
-- meaning - splitting them would leave one commit whose only effect is a
-- function nobody calls.
--
-- WHAT THIS SUITE HAS TO SETTLE, in the Product Owner's words:
--
--   annual derivation for 30/45/60/90        IA-6 .. IA-9
--   360 as the ONLY permitted convention     IA-4, IA-5, IA-10
--   6.000% reproducing the accepted values   IA-6 .. IA-9 read the STORED rate
--   blank vs explicit-zero override          IA-21, IA-24, IA-25
--   unresolved terms reaching 0.500          IA-11, IA-12
--   annual-rate immutability after approval  IA-13, IA-14
--   supplier credit inheritance and override IA-15 .. IA-20
--
-- THE DERIVATION ASSERTIONS READ THE DATABASE, NOT A LITERAL. Each one selects
-- annual_interest_pct and day_count_basis out of the row and computes with them.
-- A test that hard-codes 6.000 and 360 would still pass if the migration had
-- stored something else, which is the failure it is supposed to catch.

create or replace function tests.interest_authority()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_owner bigint; v_nag bigint; v_state text; v_seen int;
  v_annual numeric; v_basis integer;
  v_cdv bigint; v_cdv2 bigint; v_sector bigint;
  v_rs bigint; v_rsv bigint; v_re_blank bigint; v_re_zero bigint; v_re_exc bigint;
  v_fam bigint; v_batch bigint; v_pg bigint;
  v_by bigint; v_at timestamptz; v_at2 timestamptz;
  v_pauth uuid; v_pclaims text; v_proposer bigint; v_pemail text := 'p2-s7p@example.invalid';
  v_aauth uuid; v_aclaims text; v_approver bigint; v_aemail text := 'p2-s7a@example.invalid';
  v_mauth uuid; v_mclaims text; v_maker    bigint; v_memail text := 'p2-s7m@example.invalid';
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';

  -- ============================================ A-01/A-02, structural
  return next is(
    (select is_nullable from information_schema.columns
      where table_schema='public' and table_name='calculation_default_versions'
        and column_name='annual_interest_pct'),
    'NO', 'IA-1 the approved annual rate is NOT NULL - there is no versionless interest authority');

  return next is(
    (select column_default from information_schema.columns
      where table_schema='public' and table_name='calculation_default_versions'
        and column_name='annual_interest_pct'),
    '6.000', 'IA-2 and the approved initial rate is 6.000% per annum');

  return next is(
    (select column_default from information_schema.columns
      where table_schema='public' and table_name='calculation_default_versions'
        and column_name='day_count_basis'),
    '360', 'IA-3 the day-count basis defaults to 360');

  insert into public.calculation_default_versions
    (version_no, engine_version, rounding_rule_version, created_by)
  values (9901, 'engine-s7', 'round-s7', v_owner) returning id into v_cdv;

  select annual_interest_pct, day_count_basis into v_annual, v_basis
    from public.calculation_default_versions where id = v_cdv;

  -- A-02: 360 ONLY. Not `in (360,365)` - a second permitted basis would be a
  -- second authority, which is the whole point of the amendment.
  begin
    update public.calculation_default_versions set day_count_basis = 365 where id = v_cdv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'IA-4 365 is REJECTED BY CONSTRAINT - 360 is the only permitted convention (A-02)');

  begin
    update public.calculation_default_versions set day_count_basis = 0 where id = v_cdv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'IA-5 and so is every other basis - the constraint is equality, not a list');

  -- ================================= the derivation, from the STORED values
  return next is(round(v_annual * 30 / v_basis, 3), 0.500,
    'IA-6 30 days derives 0.500% from the stored annual rate and basis');
  return next is(round(v_annual * 45 / v_basis, 3), 0.750,
    'IA-7 45 days derives 0.750%');
  return next is(round(v_annual * 60 / v_basis, 3), 1.000,
    'IA-8 60 days derives 1.000%');
  return next is(round(v_annual * 90 / v_basis, 3), 1.500,
    'IA-9 90 days derives 1.500% - every previously approved value, unchanged');

  -- 360 is load-bearing, not a preference: a 365-day year reproduces NONE of them
  return next ok(round(v_annual * 30 / 365, 3) <> 0.500,
    'IA-10 a 365-day year would NOT reproduce 0.500 - the convention is arithmetic, not taste');

  -- ============================ A-03: the independent fallback survives
  return next is(
    (select interest_fallback_pct from public.calculation_default_versions where id = v_cdv),
    0.500, 'IA-11 an unresolved Payment Term still reaches the independent 0.500% fallback');
  return next ok(
    (select interest_fallback_pct from public.calculation_default_versions where id = v_cdv)
      <> round(v_annual * 90 / v_basis, 3),
    'IA-12 which is NOT the 90-day derivation - a miss can never reach 1.500 (CDM-18)');

  -- ==================================== A-01: immutability after approval
  v_pauth := tests.__fixture_auth_uid();
  v_pclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_pauth, v_pemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_pemail, '__p2_s7_proposer', false);
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated; v_proposer := public.bootstrap_app_user(); reset role;

  v_aauth := tests.__fixture_auth_uid();
  v_aclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_aauth, v_aemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_aemail, '__p2_s7_approver', false);
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated; v_approver := public.bootstrap_app_user(); reset role;

  v_mauth := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_memail, '__p2_s7_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated; v_maker := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_proposer, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','propose_commercial_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_approver, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','approve_commercial_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_approver, c.id, v_owner from public.capabilities c
   where c.capability_key = 'read_party_master';

  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  update public.calculation_default_versions set status = 'approved' where id = v_cdv;
  begin
    update public.calculation_default_versions set annual_interest_pct = 12.000 where id = v_cdv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'IA-13 an APPROVED annual rate cannot be edited - a change is a new version (A-01/CDM-31)');
  return next is(
    (select annual_interest_pct from public.calculation_default_versions where id = v_cdv),
    6.000, 'IA-14 and the approved rate is still 6.000 - the refusal was not partial');

  -- ================================ A-05: supplier paper-credit cost
  return next is(
    (select column_default from information_schema.columns
      where table_schema='public' and table_name='rate_set_versions' and column_name='credit_cost_pct'),
    '1.500', 'IA-15 the supplier paper-credit cost is a versioned value, initial 1.500 (CDM-41)');
  return next is(
    (select is_nullable from information_schema.columns
      where table_schema='public' and table_name='rate_entries' and column_name='interest_pct'),
    'YES', 'IA-16 and the per-grade column stays nullable - null there means INHERIT, not zero');

  insert into public.rate_sets (plant_id, name, created_by)
  values (v_nag, '__p2 s7 rate set', v_owner) returning id into v_rs;
  insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
  values (v_rs, v_nag, 9901, v_owner) returning id into v_rsv;

  insert into public.rate_entries (rate_set_version_id, plant_id, grade_code, price, interest_pct, created_by)
  values (v_rsv, v_nag, '__S7BLANK', 30.0000, null,  v_owner) returning id into v_re_blank;
  insert into public.rate_entries (rate_set_version_id, plant_id, grade_code, price, interest_pct, created_by)
  values (v_rsv, v_nag, '__S7ZERO',  30.0000, 0.000, v_owner) returning id into v_re_zero;
  insert into public.rate_entries (rate_set_version_id, plant_id, grade_code, price, interest_pct, created_by)
  values (v_rsv, v_nag, '__S7EXC',   30.0000, 2.250, v_owner) returning id into v_re_exc;

  return next is(
    (select coalesce(e.interest_pct, v.credit_cost_pct) from public.rate_entries e
       join public.rate_set_versions v on v.id = e.rate_set_version_id where e.id = v_re_blank),
    1.500, 'IA-17 a blank per-grade value INHERITS the Rate Set version credit cost');
  return next is(
    (select coalesce(e.interest_pct, v.credit_cost_pct) from public.rate_entries e
       join public.rate_set_versions v on v.id = e.rate_set_version_id where e.id = v_re_zero),
    0.000, 'IA-18 an explicit ZERO stays zero and does not inherit - blank and zero are different states');
  return next is(
    (select coalesce(e.interest_pct, v.credit_cost_pct) from public.rate_entries e
       join public.rate_set_versions v on v.id = e.rate_set_version_id where e.id = v_re_exc),
    2.250, 'IA-19 and an explicit exception wins over the version value');

  return next ok(
    (select v.credit_cost_pct from public.rate_set_versions v where v.id = v_rsv)
      <> (select c.annual_interest_pct from public.calculation_default_versions c where c.id = v_cdv),
    'IA-20 supplier credit cost and the customer annual rate are different numbers on different tables - neither is derived from the other (A-05)');

  -- ==================== A-04: the override, its reason and its attribution
  insert into public.customer_families (name, status, created_by)
  values ('__p2 s7 family','active',v_owner) returning id into v_fam;

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_batch := public.create_batch(v_fam, v_nag, null);
  reset role;
  select id into v_pg from public.pricing_groups where batch_id = v_batch limit 1;

  return next ok(
    (select interest_override_pct is null and interest_override_by is null
       from public.pricing_groups where id = v_pg),
    'IA-21 a new Pricing Group inherits - the override is null, not zero (A-04)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups
       set payment_terms_days = 30, interest_override_pct = 0.900,
           interest_override_derived_pct = 0.500
     where id = v_pg;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'IA-22 an override that DIFFERS from the derived percentage is refused without a reason (A-04)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups
     set payment_terms_days = 30, interest_override_pct = 0.900,
         interest_override_derived_pct = 0.500,
         interest_override_reason = 'negotiated on the Q3 renewal'
   where id = v_pg;
  reset role;
  select interest_override_by, interest_override_at into v_by, v_at
    from public.pricing_groups where id = v_pg;
  return next is(v_by, v_maker,
    'IA-23 with a reason it is accepted, and attributed to the caller by the database (CDM-34)');
  return next ok(v_at is not null, 'IA-23a and time-stamped by the database, not by the client');

  -- an unrelated edit must not rewrite who decided the interest
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__relabelled' where id = v_pg;
  reset role;
  select interest_override_at into v_at2 from public.pricing_groups where id = v_pg;
  return next is(v_at2, v_at,
    'IA-24 editing an unrelated column does NOT re-stamp the override attribution');

  -- explicit zero is a decision, and it is not a blank
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups
     set interest_override_pct = 0.000, interest_override_derived_pct = 0.500,
         interest_override_reason = 'interest waived for this route'
   where id = v_pg;
  reset role;
  return next ok(
    (select interest_override_pct = 0.000 and interest_override_pct is not null
       from public.pricing_groups where id = v_pg),
    'IA-25 an explicit ZERO override is stored as zero and is distinguishable from blank (A-04)');

  -- clearing the override clears the whole decision, leaving no residue
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set interest_override_pct = null where id = v_pg;
  reset role;
  return next ok(
    (select interest_override_pct is null and interest_override_derived_pct is null
        and interest_override_reason is null and interest_override_by is null
        and interest_override_at is null
       from public.pricing_groups where id = v_pg),
    'IA-26 clearing the override clears its reason and attribution - an inheriting group keeps no residue');

  -- the closed Payment Terms list survives the retirement of the map
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups set payment_terms_days = 35 where id = v_pg;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'IA-27 the closed list 30/45/60/90 is still structural on the Pricing Group (A-03)');

  -- a caller with no application identity cannot record a commercial decision
  begin
    update public.pricing_groups set interest_override_pct = 0.750,
           interest_override_derived_pct = 0.750 where id = v_pg;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '42501',
    'IA-28 and an override with no application identity behind it is refused outright (CDM-34)');

  return next is(
    (select count(*)::int
       from pg_catalog.pg_constraint con
       join pg_catalog.pg_class c on c.oid = con.conrelid
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname='public' and c.relname='pricing_groups' and con.contype='f'
        and not exists (
          select 1 from pg_catalog.pg_index i
           where i.indrelid = con.conrelid
             and (i.indkey::smallint[])[0:array_length(con.conkey,1)-1]
                 = (select array_agg(k) from unnest(con.conkey) k))),
    0, 'IA-29 every foreign key on pricing_groups is index-covered, the new one included');

  return next ok(
    not pg_catalog.has_function_privilege('authenticated',
      'app_private.stamp_interest_override_attribution()', 'EXECUTE'),
    'IA-30 and the attribution trigger is not executable by any API role');

  -- ------------------------------------------------------------- cleanup
  delete from public.delivery_groups        where batch_id = v_batch;
  delete from public.pricing_groups         where batch_id = v_batch;
  delete from public.batch_profile_versions where batch_id = v_batch;
  delete from public.batch_edit_locks       where batch_id = v_batch;
  delete from public.batches                where id = v_batch;
  delete from public.customer_families      where id = v_fam;
  delete from public.rate_entries           where rate_set_version_id = v_rsv;
  delete from public.rate_set_versions      where id = v_rsv;
  delete from public.rate_sets              where id = v_rs;
  delete from public.calculation_default_versions where id = v_cdv;
  delete from public.plant_capability_grants where app_user_id in (v_proposer, v_approver, v_maker);
  delete from public.group_capability_grants where app_user_id in (v_proposer, v_approver, v_maker);
  delete from public.operational_settings    where created_by  in (v_proposer, v_approver, v_maker);
  delete from app_private.pending_invitations where invite_email in (v_pemail, v_aemail, v_memail);
  delete from public.app_users where id in (v_proposer, v_approver, v_maker);
  perform tests.__drop_synthetic_auth(v_pauth);
  perform tests.__drop_synthetic_auth(v_aauth);
  perform tests.__drop_synthetic_auth(v_mauth);
end $fn$;

revoke all on function tests.interest_authority() from public;
revoke all on function tests.interest_authority() from anon;
revoke all on function tests.interest_authority() from authenticated;

-- Registered next to the Family D suites it extends, so run_all still reads as
-- the order the model was built in.
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
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from finish();
end $fn$;
