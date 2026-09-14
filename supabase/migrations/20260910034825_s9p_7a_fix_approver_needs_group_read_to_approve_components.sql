-- S9-P/7a: the approver could not approve the two GROUP-scoped components.
--
-- WHAT WENT WRONG, AND WHY IT IS THE SAME LESSON TWICE. The suite approved four
-- components by updating status='approved' as a persona holding
-- approve_commercial_master at two plants. rate_set_versions and
-- freight_set_versions took the update; sector_versions and
-- calculation_default_versions silently did not, and
-- guard_release_components_approved then refused the Release naming them.
--
-- The UPDATE policy on both group-scoped tables is satisfied by
-- has_any_plant_cap('approve_commercial_master'), which the persona held. But an
-- UPDATE ... WHERE also applies the SELECT policy, and the SELECT policy on
-- those two tables requires a GROUP capability - read_party_master or
-- read_construction_library - which the persona did not hold. So the WHERE
-- matched zero rows, no error was raised, and the failure surfaced three
-- statements later as "unapproved components".
--
-- This is exactly the recorded S6 finding: an RLS-filtered UPDATE is not an
-- error, it silently changes nothing, and you cannot approve what you cannot
-- read. The fix is to give the approver the group READ capability its own
-- approval act requires - not to weaken any policy.
--
-- Only the fixture changes. No gate, no assertion and no expected result is
-- altered by this correction.

create or replace function tests.calculation_persistence()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_owner bigint; v_kol bigint; v_nag bigint;
  v_state text; v_con text; v_today date; v_cv int; v_num numeric; v_n int;
  v_mauth uuid; v_mclaims text; v_maker bigint;  v_memail text := 'p2-s9p-m@example.invalid';
  v_oauth uuid; v_oclaims text; v_other bigint;  v_oemail text := 'p2-s9p-o@example.invalid';
  v_pauth uuid; v_pclaims text; v_prop  bigint;  v_pemail text := 'p2-s9p-p@example.invalid';
  v_aauth uuid; v_aclaims text; v_appr  bigint;  v_aemail text := 'p2-s9p-a@example.invalid';
  v_fam bigint; v_party bigint; v_kcon bigint; v_kcv bigint; v_sku bigint; v_skuv bigint;
  v_rs bigint; v_rsv bigint; v_fs bigint; v_fsv bigint; v_sec bigint; v_sv bigint; v_cdv bigint;
  v_rs_n bigint; v_rsv_n bigint; v_fs_n bigint; v_fsv_n bigint;
  v_rel_def bigint; v_rel_alt bigint; v_rel_fut bigint; v_rel_exp bigint;
  v_rel_edge bigint; v_rel_draft bigint; v_rel_wd bigint; v_rel_nag bigint; v_rel_dup bigint;
  v_batch_gap bigint; v_batch bigint; v_pg bigint; v_row bigint;
  c text; v_cols text[] := array['addon_printing','addon_stitching','addon_coating',
                                'addon_handling','addon_moq_charge','addon_packing',
                                'addon_other','addon_unloading'];
begin
  v_owner := tests.__fixture_owner();
  select id into v_kol from public.plants where plant_code = 'KOL';
  select id into v_nag from public.plants where plant_code = 'NAG';
  select (now() at time zone p.timezone)::date into v_today from public.plants p where p.id = v_kol;

  v_mauth := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_memail, '__p2_s9p_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated; v_maker := public.bootstrap_app_user(); reset role;

  v_oauth := tests.__fixture_auth_uid();
  v_oclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_oauth, v_oemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_oemail, '__p2_s9p_other', false);
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated; v_other := public.bootstrap_app_user(); reset role;

  v_pauth := tests.__fixture_auth_uid();
  v_pclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_pauth, v_pemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_pemail, '__p2_s9p_prop', false);
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated; v_prop := public.bootstrap_app_user(); reset role;

  v_aauth := tests.__fixture_auth_uid();
  v_aclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_aauth, v_aemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_aemail, '__p2_s9p_appr', false);
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated; v_appr := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_kol, c2.id, v_owner from public.capabilities c2
   where c2.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_other, v_kol, c2.id, v_owner from public.capabilities c2
   where c2.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_prop, v_kol, c2.id, v_owner from public.capabilities c2
   where c2.capability_key in ('plant_access','propose_commercial_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_prop, v_nag, c2.id, v_owner from public.capabilities c2
   where c2.capability_key in ('plant_access','propose_commercial_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_appr, v_kol, c2.id, v_owner from public.capabilities c2
   where c2.capability_key in ('plant_access','approve_commercial_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_appr, v_nag, c2.id, v_owner from public.capabilities c2
   where c2.capability_key in ('plant_access','approve_commercial_master');

  -- S9-P/7a: the GROUP read capability the approval act itself requires. An
  -- UPDATE ... WHERE applies the SELECT policy, and the group-scoped master
  -- tables gate SELECT on read_party_master / read_construction_library.
  -- Without it the approval matches zero rows and fails silently.
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_appr, c2.id, v_owner from public.capabilities c2
   where c2.capability_key = 'read_party_master';
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_prop, c2.id, v_owner from public.capabilities c2
   where c2.capability_key = 'read_party_master';

  insert into public.customer_families (name, status, created_by)
    values ('__p2 s9p family','active',v_owner) returning id into v_fam;
  insert into public.parties (display_name, created_by) values ('__p2 s9p party', v_owner)
    returning id into v_party;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    values (v_party, v_fam, current_date, v_owner);
  insert into public.constructions (name, created_by) values ('__p2 s9p con', v_owner)
    returning id into v_kcon;
  insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kcon, 1, 3, v_owner) returning id into v_kcv;
  update public.constructions set construction_code='CON-995101', status='published' where id=v_kcon;
  insert into public.skus (plant_id, party_id, created_by) values (v_kol, v_party, v_owner)
    returning id into v_sku;
  insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id,
                                   is_price_driving, created_by)
    values (v_sku, v_kol, 1, v_kcv, true, v_owner) returning id into v_skuv;

  -- ══════════════════════════ CP-37, BEFORE any Release exists at KOL ══
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_batch_gap := public.create_batch(v_fam, v_kol, null);
  reset role;

  return next ok(
    (select pricing_basis_release_id is null from public.batches where id = v_batch_gap),
    'CP-37 a calendar gap does NOT refuse Batch creation - the Release is left null (CDM-27)');
  return next is(
    (select pricing_date from public.batches where id = v_batch_gap), v_today,
    'CP-37a and the Pricing Date is still set, to the PRODUCING PLANT local date (S12.4/CDM-34)');
  return next ok(
    (select not pricing_basis_is_deliberate from public.batches where id = v_batch_gap),
    'CP-37b a gap is not a deliberate selection');

  insert into public.rate_sets (plant_id, name, created_by)
    values (v_kol,'__p2 s9p rs',v_owner) returning id into v_rs;
  insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
    values (v_rs, v_kol, 1, v_owner) returning id into v_rsv;
  insert into public.freight_sets (plant_id, name, created_by)
    values (v_kol,'__p2 s9p fs',v_owner) returning id into v_fs;
  insert into public.freight_set_versions (freight_set_id, plant_id, version_no, created_by)
    values (v_fs, v_kol, 1, v_owner) returning id into v_fsv;
  insert into public.sectors (sector_code, name, created_by)
    values ('__S9P','__p2 s9p sector',v_owner) returning id into v_sec;
  insert into public.sector_versions (sector_id, version_no, margin_pct, created_by)
    values (v_sec, 1, 8.000, v_owner) returning id into v_sv;
  insert into public.calculation_default_versions (version_no, engine_version, rounding_rule_version, created_by)
    values (951, 'engine-s9p', 'round-s9p', v_owner) returning id into v_cdv;
  insert into public.rate_sets (plant_id, name, created_by)
    values (v_nag,'__p2 s9p rs nag',v_owner) returning id into v_rs_n;
  insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
    values (v_rs_n, v_nag, 1, v_owner) returning id into v_rsv_n;
  insert into public.freight_sets (plant_id, name, created_by)
    values (v_nag,'__p2 s9p fs nag',v_owner) returning id into v_fs_n;
  insert into public.freight_set_versions (freight_set_id, plant_id, version_no, created_by)
    values (v_fs_n, v_nag, 1, v_owner) returning id into v_fsv_n;

  return next is(
    (select fluting_bcf_default from public.calculation_default_versions where id = v_cdv), 0.1000,
    'CP-3a a Calculation Defaults version that does not name the factor gets the approved 0.1000 - establishing the tier moved no number (A-21)');
  return next ok(
    (select attnotnull from pg_catalog.pg_attribute
      where attrelid='public.calculation_default_versions'::regclass and attname='fluting_bcf_default'),
    'CP-3b and the versioned tier is NOT NULL - there is no unversioned literal left');
  return next ok(
    exists (select 1 from pg_catalog.pg_constraint
             where conname = 'ck_cdv_fluting_bcf_range'
               and conrelid = 'public.calculation_default_versions'::regclass),
    'CP-4b the governed tier carries the same 0..0.30 range rule as the row tier');

  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  update public.rate_set_versions            set status='approved' where id in (v_rsv, v_rsv_n);
  update public.freight_set_versions         set status='approved' where id in (v_fsv, v_fsv_n);
  update public.sector_versions              set status='approved' where id = v_sv;
  update public.calculation_default_versions set status='approved' where id = v_cdv;
  reset role;

  -- the approval actually landed, on the GROUP-scoped components too
  return next is((select status from public.sector_versions where id = v_sv), 'approved',
    'CP-29 the group-scoped Sector version really is approved - an RLS-filtered UPDATE changes nothing silently, so the row is read back rather than assumed');
  return next is((select status from public.calculation_default_versions where id = v_cdv), 'approved',
    'CP-29a and so is the Calculation Defaults version');

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  v_rel_def   := public.propose_pricing_basis_release(v_kol, v_today - 30, v_rsv, v_fsv, v_sv, v_cdv, null,         '__s9p default');
  v_rel_alt   := public.propose_pricing_basis_release(v_kol, v_today - 10, v_rsv, v_fsv, v_sv, v_cdv, null,         '__s9p alternative');
  v_rel_fut   := public.propose_pricing_basis_release(v_kol, v_today + 30, v_rsv, v_fsv, v_sv, v_cdv, null,         '__s9p future');
  v_rel_exp   := public.propose_pricing_basis_release(v_kol, v_today - 60, v_rsv, v_fsv, v_sv, v_cdv, v_today - 31, '__s9p expired');
  v_rel_edge  := public.propose_pricing_basis_release(v_kol, v_today - 5,  v_rsv, v_fsv, v_sv, v_cdv, v_today,      '__s9p edge');
  v_rel_draft := public.propose_pricing_basis_release(v_kol, v_today - 20, v_rsv, v_fsv, v_sv, v_cdv, null,         '__s9p draft');
  v_rel_wd    := public.propose_pricing_basis_release(v_kol, v_today - 15, v_rsv, v_fsv, v_sv, v_cdv, null,         '__s9p withdrawn');
  v_rel_nag   := public.propose_pricing_basis_release(v_nag, v_today - 10, v_rsv_n, v_fsv_n, v_sv, v_cdv, null,     '__s9p nag alt');
  reset role;

  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  perform public.approve_pricing_basis_release(v_rel_def,  true);
  perform public.approve_pricing_basis_release(v_rel_alt,  false);
  perform public.approve_pricing_basis_release(v_rel_fut,  false);
  perform public.approve_pricing_basis_release(v_rel_exp,  false);
  perform public.approve_pricing_basis_release(v_rel_edge, false);
  perform public.approve_pricing_basis_release(v_rel_wd,   false);
  perform public.approve_pricing_basis_release(v_rel_nag,  false);
  perform public.withdraw_pricing_basis_release(v_rel_wd);
  reset role;

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  v_rel_dup := public.propose_pricing_basis_release(v_kol, v_today - 1, v_rsv, v_fsv, v_sv, v_cdv, null, '__s9p dup default');
  reset role;
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    perform public.approve_pricing_basis_release(v_rel_dup, true);
    v_state := 'NO ERROR'; v_con := null;
  exception when others then
    v_state := sqlstate; get stacked diagnostics v_con = constraint_name;
  end;
  reset role;
  return next is(v_state, '23P01',
    'CP-38 a second approved automatic default overlapping the first at one plant is refused');
  return next is(v_con, 'ex_pbr_default_no_overlap',
    'CP-38a by ex_pbr_default_no_overlap BY NAME - the guarantee create_batch single-row select depends on');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_batch := public.create_batch(v_fam, v_kol, null);
  reset role;
  select id into v_pg from public.pricing_groups where batch_id = v_batch;

  return next is(
    (select pricing_basis_release_id from public.batches where id = v_batch), v_rel_def,
    'CP-30 create_batch selects the approved automatic default Release covering the Pricing Date');
  return next ok(
    (select not pricing_basis_is_deliberate from public.batches where id = v_batch),
    'CP-30a and marks it NOT deliberate - the automatic default was taken');
  return next is(
    (select pricing_date from public.batches where id = v_batch), v_today,
    'CP-30b the Pricing Date is the producing plant local date');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id,
                                 row_type, created_by)
  values (v_batch, v_kol, v_pg, v_sku, v_skuv, 'box', v_maker) returning id into v_row;
  reset role;

  foreach c in array v_cols loop
    execute format('select %I from public.batch_rows where id = $1', c) into v_num using v_row;
    return next ok(v_num is null,
      format('CP-1 %s starts NULL - an add-on nobody entered is ABSENT, not zero', c));

    perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
    set local role authenticated;
    execute format('update public.batch_rows set %I = 0 where id = $1', c) using v_row;
    reset role;
    execute format('select %I from public.batch_rows where id = $1', c) into v_num using v_row;
    return next ok(v_num is not null and v_num = 0,
      format('CP-1a %s stores an explicit 0 and reads it back as 0, not as NULL - a deliberate zero charge survives (D-M)', c));

    perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
    set local role authenticated;
    execute format('update public.batch_rows set %I = null where id = $1', c) using v_row;
    reset role;
    execute format('select %I from public.batch_rows where id = $1', c) into v_num using v_row;
    return next ok(v_num is null,
      format('CP-1b %s returns to NULL - the two states are distinguishable in both directions', c));
  end loop;

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.batch_rows set fluting_bcf = 0 where id = v_row;
  reset role;
  return next ok((select fluting_bcf = 0 from public.batch_rows where id = v_row),
    'CP-3 an explicit fluting_bcf of 0 is stored as 0 - a take-up factor of zero is a real technical statement');
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.batch_rows set fluting_bcf = null where id = v_row;
  reset role;
  return next ok((select fluting_bcf is null from public.batch_rows where id = v_row),
    'CP-3c and NULL is distinguishable from it - here NULL means INHERIT the versioned tier');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.batch_rows set addon_coating = -1 where id = v_row;
    v_state := 'NO ERROR'; v_con := null;
  exception when others then
    v_state := sqlstate; get stacked diagnostics v_con = constraint_name;
  end;
  reset role;
  return next is(v_con, 'ck_row_addons_non_negative',
    'CP-4 a negative add-on is refused by ck_row_addons_non_negative BY NAME');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.batch_rows set fluting_bcf = 0.31 where id = v_row;
    v_state := 'NO ERROR'; v_con := null;
  exception when others then
    v_state := sqlstate; get stacked diagnostics v_con = constraint_name;
  end;
  reset role;
  return next is(v_con, 'ck_row_fluting_bcf_range',
    'CP-4a a fluting factor above 0.30 is refused by ck_row_fluting_bcf_range BY NAME');

  select content_version into v_cv from public.batches where id = v_batch;

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, v_rel_nag);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '22023',
    'CP-31 a Release belonging to ANOTHER PLANT is refused');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.batches set pricing_basis_release_id = v_rel_nag where id = v_batch;
    v_state := 'NO ERROR'; v_con := null;
  exception when others then
    v_state := sqlstate; get stacked diagnostics v_con = constraint_name;
  end;
  reset role;
  return next is(v_con, 'fk_batch_pricing_basis',
    'CP-31a and a DIRECT write of a foreign-plant Release is unrepresentable - fk_batch_pricing_basis BY NAME');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, v_rel_wd);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '22023', 'CP-32 a WITHDRAWN Release is refused');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, v_rel_draft);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '22023', 'CP-32a a DRAFT Release is refused by the same status test');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, v_rel_fut);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '22023', 'CP-33 a FUTURE Release does not cover today and is refused');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, v_rel_exp);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '22023', 'CP-34 an EXPIRED Release is refused');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, v_rel_edge);
  reset role;
  return next is(
    (select pricing_basis_release_id from public.batches where id = v_batch), v_rel_edge,
    'CP-34a but effective_until EQUAL to the Pricing Date IS covered - the range is inclusive at both ends');

  select content_version into v_cv from public.batches where id = v_batch;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, v_rel_alt);
  reset role;
  return next is(
    (select pricing_basis_release_id from public.batches where id = v_batch), v_rel_alt,
    'CP-35 a MAKER deliberately selects an approved alternative (CDM-27)');
  return next ok(
    (select pricing_basis_is_deliberate from public.batches where id = v_batch),
    'CP-35a and the selection is marked deliberate - the MODE of selection, attesting nothing about who');

  select content_version into v_cv from public.batches where id = v_batch;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, null);
  reset role;
  return next is(
    (select pricing_basis_release_id from public.batches where id = v_batch), v_rel_def,
    'CP-36 passing null REVERTS to the automatic default - reverting is a first-class act');
  return next ok(
    (select not pricing_basis_is_deliberate from public.batches where id = v_batch),
    'CP-36a and the deliberate flag is reset with it');

  select content_version into v_cv from public.batches where id = v_batch;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.set_batch_pricing_basis(v_batch, v_cv, v_today - 100, null);
  reset role;
  return next ok(
    (select pricing_basis_release_id is null from public.batches where id = v_batch),
    'CP-37c a Pricing Date no automatic default covers leaves the Release null rather than guessing');

  select content_version into v_cv from public.batches where id = v_batch;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, null);
  reset role;

  select content_version into v_cv from public.batches where id = v_batch;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.set_batch_pricing_basis(v_batch, v_cv - 1, v_today + 1, v_rel_alt);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'PT409', 'CP-40 a stale expected content_version raises PT409');
  return next is((select pricing_date from public.batches where id = v_batch), v_today,
    'CP-40a and the Pricing Date is unchanged');
  return next is((select pricing_basis_release_id from public.batches where id = v_batch), v_rel_def,
    'CP-40b and the Release is unchanged');
  return next is((select content_version from public.batches where id = v_batch), v_cv,
    'CP-40c and the content version did not advance');

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, v_rel_alt);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'CP-42 a second Maker at the same plant who does NOT hold the edit lock is refused');
  return next is((select content_version from public.batches where id = v_batch), v_cv,
    'CP-42a and nothing moved');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.release_batch_lock(v_batch);
  begin
    perform public.set_batch_pricing_basis(v_batch, v_cv, v_today, v_rel_alt);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  perform public.acquire_batch_lock(v_batch);
  reset role;
  return next is(v_state, '42501',
    'CP-41 and the OWNER is refused too once the lock is released - a released lock and a foreign lock are different states, both refused');

  select content_version into v_cv from public.batches where id = v_batch;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.set_batch_pricing_basis(v_batch, v_cv, v_today + 5, v_rel_edge);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '22023',
    'CP-43 a Release that does not cover the requested Pricing Date is refused');
  return next is((select pricing_date from public.batches where id = v_batch), v_today,
    'CP-43a and the Pricing Date did NOT move - validation completes before the single write, so no Batch is left priced as at a date nobody chose');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.batch_rows set addon_packing = 1, content_version = 99 where id = v_row;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'CP-44 a caller cannot assign content_version - guard_content_version keeps it the database own');

  select content_version into v_cv from public.batch_rows where id = v_row;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.batch_rows set addon_packing = 2 where id = v_row;
  reset role;
  return next is((select content_version from public.batch_rows where id = v_row), v_cv + 1,
    'CP-45 an update OMITTING the expected-version filter SUCCEEDS and the version advances - the filter is a caller/API contract, not database-enforced CAS. Recorded so nobody mistakes it for a guarantee');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups set legacy_freight_value = 2.5 where id = v_pg;
    v_state := 'NO ERROR'; v_con := null;
  exception when others then
    v_state := sqlstate; get stacked diagnostics v_con = constraint_name;
  end;
  reset role;
  return next is(v_con, 'ck_pg_legacy_freight_paired',
    'CP-60 a temporary value without provenance is refused BY NAME - half a reference is not a reference');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups set legacy_freight_source = 'legacy_matrix' where id = v_pg;
    v_state := 'NO ERROR'; v_con := null;
  exception when others then
    v_state := sqlstate; get stacked diagnostics v_con = constraint_name;
  end;
  reset role;
  return next is(v_con, 'ck_pg_legacy_freight_paired',
    'CP-60a and provenance without a value is refused by the same biconditional');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups
       set legacy_freight_value = 2.5, legacy_freight_source = 'master' where id = v_pg;
    v_state := 'NO ERROR'; v_con := null;
  exception when others then
    v_state := sqlstate; get stacked diagnostics v_con = constraint_name;
  end;
  reset role;
  return next is(v_con, 'ck_pg_legacy_freight_source',
    'CP-61 a GOVERNED source is refused in the temporary pair BY NAME - governed freight has its own home');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups
     set legacy_freight_value = 2.5, legacy_freight_source = 'legacy_batch' where id = v_pg;
  reset role;
  return next ok(
    (select legacy_freight_source = 'legacy_batch' and freight_mode = 'master'
       from public.pricing_groups where id = v_pg),
    'CP-64a master mode PERMITS a stored legacy_batch - a delegation is not a value, so the ratified S8 order stands pending U4');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups
       set freight_mode = 'manual', freight_manual_value = 4 where id = v_pg;
    v_state := 'NO ERROR'; v_con := null;
  exception when others then
    v_state := sqlstate; get stacked diagnostics v_con = constraint_name;
  end;
  reset role;
  return next is(v_con, 'ck_pg_legacy_batch_not_with_governed_mode',
    'CP-62 stating MANUAL freight while legacy_batch is stored is refused BY NAME - legacy_batch outranks the Pricing Group tier and would make the Maker selection ineffective');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups set freight_mode = 'ex_factory' where id = v_pg;
    v_state := 'NO ERROR'; v_con := null;
  exception when others then
    v_state := sqlstate; get stacked diagnostics v_con = constraint_name;
  end;
  reset role;
  return next is(v_con, 'ck_pg_legacy_batch_not_with_governed_mode',
    'CP-63 and stating EX-FACTORY freight while legacy_batch is stored is refused by the same rule');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups
     set freight_mode = 'manual', freight_manual_value = 4,
         legacy_freight_value = null, legacy_freight_source = null
   where id = v_pg;
  reset role;
  return next ok(
    (select freight_mode = 'manual' and legacy_freight_source is null
       from public.pricing_groups where id = v_pg),
    'CP-68 stating governed freight AND clearing the pair in ONE statement succeeds - there is no writable intermediate state');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups
     set legacy_freight_value = 3.25, legacy_freight_source = 'legacy_matrix' where id = v_pg;
  reset role;
  return next ok(
    (select legacy_freight_source = 'legacy_matrix' and freight_mode = 'manual'
       from public.pricing_groups where id = v_pg),
    'CP-64 MANUAL mode may retain a dormant legacy_matrix - it is a lower-priority fallback, not a competing authority, so no rule bars it');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups
     set freight_mode = 'ex_factory', freight_manual_value = null where id = v_pg;
  reset role;
  return next ok(
    (select legacy_freight_source = 'legacy_matrix' and freight_mode = 'ex_factory'
       from public.pricing_groups where id = v_pg),
    'CP-64b and EX-FACTORY mode may retain it too - the constraint is narrow and does not over-reach');

  select count(*)::int into v_n
    from public.pricing_groups g join public.batches b on b.id = g.batch_id
   where g.legacy_freight_source is not null
     and b.status in ('working','sent','submitted');
  return next ok(v_n >= 1,
    'CP-69 retirement readiness is measurable: open Batches carrying a stored temporary pair are countable, which is the precondition U3/U4 must drive to zero before the columns can be dropped');

  return next is(
    (select count(*)::int from pg_catalog.pg_constraint con
       join pg_catalog.pg_class rel on rel.oid = con.conrelid
      where con.contype = 'f'
        and con.confrelid = 'public.pricing_groups'::regclass
        and rel.relname in ('quote_families','quote_revisions','calculation_snapshots',
                            'quote_items','quote_item_delivery_groups','quote_workflow_events',
                            'customer_outcome_events','export_events','export_parts')
        and exists (select 1 from unnest(con.confkey) k
                      join pg_catalog.pg_attribute a
                        on a.attrelid = con.confrelid and a.attnum = k
                     where a.attname in ('legacy_freight_value','legacy_freight_source'))),
    0,
    'CP-70 NO Family G foreign key references either temporary-freight column - snapshots COPY the value and provenance, so dropping these columns at U3/U4 removes no historical evidence');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public','app_private')
        and p.proname in ('fingerprint_serialize','calculation_fingerprint')),
    0,
    'CP-80 S9-P built NO fingerprint function - both belong to S7-R with the Calculate writer');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app_private' and p.proname = 'guard_pg_temporary_freight'),
    0,
    'CP-81 and NO temporary-freight guard trigger - a pricing_groups trigger fires only on pricing_groups writes, so it could never see a Ship-to, Delivery Group status, Release or Freight Entry change');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public','app_private') and p.proname = 'send_batch'),
    0,
    'CP-82 and NO Send operation - S9(b) remains unimplemented and unauthorised');
  return next is((select count(*)::int from public.quote_families), 0,
    'CP-83 Family G is still empty - this tranche created no Quote, no revision and no snapshot');
end $fn$;

revoke all on function tests.calculation_persistence() from public, anon, authenticated;