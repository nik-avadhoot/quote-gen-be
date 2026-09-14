-- S7-R/9b: fix - the executor stand-in cannot be called while impersonating a caller.
--
-- tests.__s7r_sign is revoked from authenticated and lives in the `tests`
-- schema, which authenticated holds no USAGE on. Several gates signed an
-- attestation while still inside `set local role authenticated`, which failed
-- with 42501 before the gate could run.
--
-- THE FIX IS THE RIGHT SHAPE, NOT A GRANT. Widening `tests` to authenticated so
-- a test could sign would hand the impersonated caller a signing oracle - the
-- precise capability every gate in this suite exists to prove they do NOT have.
-- Signing is the trusted executor's act and belongs at owner level; the role is
-- assumed only around the RPC call itself, which is what the gates are actually
-- about.
--
-- Every sign is therefore hoisted above its `set local role`, and the role is
-- released before the next one. The claims survive: set_config(..., true) is
-- transaction-local and is unaffected by resetting the role, so each call still
-- arrives as the intended persona.
--
-- No assertion, message or fixture value changes.

create or replace function tests.__s7r_body()
returns setof text language plpgsql set search_path = 'extensions', 'pg_catalog' as $fn$
declare
  c_key constant bytea := decode(repeat('ab',32),'hex');
  v_owner bigint; v_kol bigint; v_today date;
  v_mauth uuid; v_mclaims text; v_maker bigint; v_memail text := 'p2-s7r-m@example.invalid';
  v_oauth uuid; v_oclaims text; v_other bigint; v_oemail text := 'p2-s7r-o@example.invalid';
  v_pauth uuid; v_pclaims text; v_prop bigint;  v_pemail text := 'p2-s7r-p@example.invalid';
  v_aauth uuid; v_aclaims text; v_appr bigint;  v_aemail text := 'p2-s7r-a@example.invalid';
  v_cauth uuid; v_cclaims text; v_chk bigint;   v_cemail text := 'p2-s7r-c@example.invalid';
  v_fam bigint; v_party bigint; v_loc bigint; v_con bigint; v_cv bigint;
  v_sku bigint; v_skuv bigint; v_sku2 bigint; v_skuv2 bigint;
  v_rs bigint; v_rsv bigint; v_fs bigint; v_fsv bigint; v_sec bigint; v_sv bigint; v_cdv bigint;
  v_rel bigint; v_batch bigint; v_pg bigint; v_row bigint; v_row2 bigint; v_row3 bigint;
  v_dg bigint; v_res text; v_att text; v_cvn int; v_cvn2 int; v_cvn3 int;
  v_cfp text; v_pfp text; v_id bigint; v_id2 bigint; v_state text;
  v_ca timestamptz; v_ea timestamptz; v_now timestamptz;
  v_n0 int; v_before jsonb; v_after jsonb;
begin
  -- ═══════════════════════ A. the byte contract, no fixture required ══
  return next is(
    app_private.fingerprint_serialize('qcf/1',
      array['row.waste_override_pct','addon.printing','pg.freight_mode'],
      array[app_private.fp_num(5.000::numeric(7,3)), app_private.fp_num(0::numeric),
            app_private.fp_text('master')]),
    E'qcf/1\naddon.printing=0\npg.freight_mode=master\nrow.waste_override_pct=5',
    'CP-113 GOLDEN VECTOR - a fixed field set serializes to exactly these bytes, sorted by key under COLLATE "C"');
  return next is(
    app_private.fingerprint_hex(app_private.fingerprint_serialize('qcf/1',
      array['row.waste_override_pct','addon.printing','pg.freight_mode'],
      array[app_private.fp_num(5.000::numeric(7,3)), app_private.fp_num(0::numeric),
            app_private.fp_text('master')])),
    '145e7c09d9a324aa3a93db8b43a810660d20742348ba1f77bf271bb6b0a34953',
    'CP-113a and hashes to exactly this digest - any change to ordering, escaping or normalization fails here instead of silently re-staling every row on deploy');
  return next is(
    encode(extensions.hmac(app_private.qca_mac_input(
      'k1','00000000-0000-4000-8000-000000000001', 7, 11, 13, 3, 17, 'engine/x',
      repeat('a',64), repeat('b',64), repeat('c',64),
      '2026-09-10T00:00:00.000000Z'::timestamptz,
      '2026-09-10T00:01:00.000000Z'::timestamptz), c_key, 'sha256'), 'hex'),
    '70828cac95d23e15a4f25c1fc63476511baf03697e8375749e8941fee26aa04b',
    'CP-113b GOLDEN VECTOR - the qca/1 fourteen-field tuple under a fixed key produces exactly this MAC');
  return next ok(
    encode(extensions.hmac(app_private.qca_mac_input('a','b~c',7,11,13,3,17,'engine/x',
      repeat('a',64),repeat('b',64),repeat('c',64),
      '2026-09-10T00:00:00.000000Z'::timestamptz,'2026-09-10T00:01:00.000000Z'::timestamptz),
      c_key,'sha256'),'hex')
    <> encode(extensions.hmac(app_private.qca_mac_input('a~b','c',7,11,13,3,17,'engine/x',
      repeat('a',64),repeat('b',64),repeat('c',64),
      '2026-09-10T00:00:00.000000Z'::timestamptz,'2026-09-10T00:01:00.000000Z'::timestamptz),
      c_key,'sha256'),'hex'),
    'CP-113c FRAMING COLLISION - (a, b~c) and (a~b, c) would be ONE string under delimiter joining and produce DIFFERENT MACs under length framing');
  return next ok(
    app_private.fingerprint_hex('qca/1' || E'\n' || 'x=1')
    <> encode(extensions.hmac(app_private.qca_mac_input('k1','s',1,1,1,1,1,'e',
        repeat('a',64),repeat('b',64),repeat('c',64),
        '2026-09-10T00:00:00.000000Z'::timestamptz,'2026-09-10T00:01:00.000000Z'::timestamptz),
        c_key,'sha256'),'hex'),
    'CP-113d DOMAIN SEPARATION - a qcf/1-shaped payload cannot produce a qca/1 MAC; the domain is the first FRAMED field, not an outer prefix');

  return next ok(app_private.fp_num(5::numeric) = app_private.fp_num(5.0::numeric)
             and app_private.fp_num(5.0::numeric) = app_private.fp_num(5.000::numeric(7,3)),
    'CP-51 numeric normalization - 5, 5.0 and 5.000 in a scaled column all serialize identically');
  return next is(app_private.fp_num((-0.0)::numeric), app_private.fp_num(0::numeric),
    'CP-51a and negative zero collapses onto zero');
  return next ok(app_private.fp_text(null) <> app_private.fp_text(''),
    'CP-52 null is NOT the empty string');
  return next ok(app_private.fp_num(null) <> app_private.fp_num(0::numeric),
    'CP-52a and a null number is NOT an explicit zero - the distinction D-M protects');

  -- ═══════════════════════ B. privilege placement and reachability ══
  return next ok(not has_function_privilege('authenticated',
      'app_private.fingerprint_serialize(text,text[],text[])','EXECUTE'),
    'CP-54 authenticated cannot execute the serializer');
  return next ok(not has_function_privilege('authenticated',
      'app_private.calculation_fingerprint(bigint)','EXECUTE'),
    'CP-54a nor the calculation gatherer');
  return next ok(not has_function_privilege('authenticated',
      'app_private.presentation_fingerprint(bigint)','EXECUTE'),
    'CP-54b nor the presentation gatherer');
  return next ok(not has_function_privilege('authenticated','app_private.qca_key(text)','EXECUTE'),
    'CP-54c nor the key reader - the one function that touches key material');
  return next ok(not has_function_privilege('authenticated',
      'app_private.resolve_row_freight(bigint)','EXECUTE'),
    'CP-54d nor the freight resolver');
  return next ok(not (select p.prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app_private' and p.proname='fingerprint_serialize'),
    'CP-54e the serializer is SECURITY INVOKER - it touches no table and needs no privilege');
  return next ok((select p.prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app_private' and p.proname='calculation_fingerprint'),
    'CP-54f the gatherer is SECURITY DEFINER - it answers a property of the database, not of the caller visibility');
  return next is((select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app_private'
        and p.proname in ('fingerprint_serialize','calculation_fingerprint',
                          'presentation_fingerprint','qca_key','qca_mac_input',
                          'calculate_batch_row','build_effective_inputs')
        and not coalesce(p.proconfig::text like '%search_path=%', false)), 0,
    'CP-54g every one of them pins search_path');
  return next ok(not has_schema_privilege('authenticated','tests','USAGE'),
    'CP-54h and authenticated cannot even reach the tests schema - the executor stand-in is not a signing oracle');

  return next is((select count(*)::int from information_schema.table_privileges
      where table_schema='app_private' and table_name='attestation_keys'
        and grantee in ('anon','authenticated','PUBLIC')), 0,
    'CP-114 the keyring grants nothing to anon, authenticated or PUBLIC at table level');
  return next is((select count(*)::int from information_schema.column_privileges
      where table_schema='app_private' and table_name='attestation_keys'
        and grantee in ('anon','authenticated','PUBLIC')), 0,
    'CP-114a nor at column level');
  return next ok(exists (select 1 from pg_indexes where schemaname='app_private'
        and indexname='uk_attestation_key_active'),
    'CP-114b exactly one ACTIVE key is enforced by a partial unique index, not by convention');

  return next ok(not (has_table_privilege('authenticated','public.batch_calculations','INSERT')
      or has_table_privilege('authenticated','public.batch_calculations','UPDATE')
      or has_table_privilege('authenticated','public.batch_calculations','DELETE')),
    'FS-14 batch_calculations still has NO direct write grant - the only writer is app_private.calculate_batch_row (replaces the S7-owns-that wording)');
  return next is((select count(*)::int from information_schema.column_privileges
      where table_schema='public' and table_name='batch_calculations'
        and grantee='authenticated' and privilege_type in ('INSERT','UPDATE')), 0,
    'FS-14a and none at column level either');
  return next is((select count(*)::int from pg_policy pol join pg_class c on c.oid=pol.polrelid
      where c.relname='batch_calculations' and pol.polcmd <> 'r'), 0,
    'FS-14b and no INSERT or UPDATE policy stands behind an absent privilege');

  return next ok(not (select p.prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='calculate_batch_row'),
    'CP-96 the public shim is SECURITY INVOKER so auth.uid() stays the real caller');
  return next ok((select p.prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app_private' and p.proname='calculate_batch_row'),
    'CP-96a and the implementation is SECURITY DEFINER');
  return next ok(pg_get_function_identity_arguments(
      'public.calculate_batch_row(bigint,integer,text,text)'::regprocedure)
      not like '%effective_inputs%',
    'CP-107 the signature has NO p_effective_inputs - a caller cannot supply inputs at all');

  -- ═══════════════════════════════════════════════════ fixture ══
  v_owner := tests.__fixture_owner();
  select id into v_kol from public.plants where plant_code='KOL';
  select (now() at time zone p.timezone)::date into v_today from public.plants p where p.id=v_kol;

  v_mauth := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin) values (v_memail,'__p2_s7r_maker',false);
  perform set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated; v_maker := public.bootstrap_app_user(); reset role;
  v_oauth := tests.__fixture_auth_uid();
  v_oclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_oauth, v_oemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin) values (v_oemail,'__p2_s7r_other',false);
  perform set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated; v_other := public.bootstrap_app_user(); reset role;
  v_pauth := tests.__fixture_auth_uid();
  v_pclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_pauth, v_pemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin) values (v_pemail,'__p2_s7r_prop',false);
  perform set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated; v_prop := public.bootstrap_app_user(); reset role;
  v_aauth := tests.__fixture_auth_uid();
  v_aclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_aauth, v_aemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin) values (v_aemail,'__p2_s7r_appr',false);
  perform set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated; v_appr := public.bootstrap_app_user(); reset role;
  v_cauth := tests.__fixture_auth_uid();
  v_cclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_cauth, v_cemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin) values (v_cemail,'__p2_s7r_chk',false);
  perform set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated; v_chk := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_kol, c.id, v_owner from public.capabilities c where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_other, v_kol, c.id, v_owner from public.capabilities c where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_chk, v_kol, c.id, v_owner from public.capabilities c where c.capability_key in ('plant_access','check_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_prop, v_kol, c.id, v_owner from public.capabilities c where c.capability_key in ('plant_access','propose_commercial_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_appr, v_kol, c.id, v_owner from public.capabilities c where c.capability_key in ('plant_access','approve_commercial_master');
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_appr, c.id, v_owner from public.capabilities c where c.capability_key='read_party_master';
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_prop, c.id, v_owner from public.capabilities c where c.capability_key='read_party_master';

  insert into public.customer_families (name,status,created_by) values ('__p2 s7r fam','active',v_owner) returning id into v_fam;
  insert into public.parties (display_name,created_by) values ('__p2 s7r party',v_owner) returning id into v_party;
  insert into public.party_family_memberships (party_id,family_id,effective_from,created_by) values (v_party,v_fam,current_date,v_owner);
  insert into public.customer_locations (party_id,bill_to_eligible,ship_to_eligible,status,created_by)
    values (v_party,true,true,'active',v_owner) returning id into v_loc;
  insert into public.constructions (name,created_by) values ('__p2 s7r con',v_owner) returning id into v_con;
  insert into public.construction_versions (construction_id,version_no,ply,created_by,
      layer_top_code,layer_top_gsm,layer_f1_code,layer_f1_gsm,layer_l1_code,layer_l1_gsm)
    values (v_con,1,3,v_owner,'K150',150,'SF100',100,'K120',120) returning id into v_cv;
  update public.constructions set construction_code='CON-996101', status='published' where id=v_con;
  insert into public.plant_construction_adoptions (plant_id,construction_version_id,status,adopted_by,adopted_at)
    values (v_kol,v_cv,'adopted',v_owner,now());
  insert into public.skus (plant_id,party_id,created_by) values (v_kol,v_party,v_owner) returning id into v_sku;
  update public.skus set status='active', plant_item_code='PIC-S7R-1' where id=v_sku;
  insert into public.sku_versions (sku_id,plant_id,version_no,construction_version_id,is_price_driving,
      created_by,length_mm,width_mm,height_mm,box_type,ups,spec_bs)
    values (v_sku,v_kol,1,v_cv,true,v_owner,310,240,180,'RSC',1,14) returning id into v_skuv;
  update public.sku_versions set approved_at=now(), approved_by=v_owner where id=v_skuv;
  insert into public.skus (plant_id,party_id,created_by) values (v_kol,v_party,v_owner) returning id into v_sku2;
  update public.skus set status='active', plant_item_code='PIC-S7R-2' where id=v_sku2;
  update public.skus set status='discontinued', replacement_sku_id=v_sku where id=v_sku2;
  insert into public.sku_versions (sku_id,plant_id,version_no,construction_version_id,is_price_driving,
      created_by,length_mm,width_mm,height_mm,box_type,ups)
    values (v_sku2,v_kol,1,v_cv,true,v_owner,310,240,180,'RSC',1) returning id into v_skuv2;
  update public.sku_versions set approved_at=now(), approved_by=v_owner where id=v_skuv2;

  insert into public.rate_sets (plant_id,name,created_by) values (v_kol,'__p2 s7r rs',v_owner) returning id into v_rs;
  insert into public.rate_set_versions (rate_set_id,plant_id,version_no,created_by) values (v_rs,v_kol,1,v_owner) returning id into v_rsv;
  insert into public.freight_sets (plant_id,name,created_by) values (v_kol,'__p2 s7r fs',v_owner) returning id into v_fs;
  insert into public.freight_set_versions (freight_set_id,plant_id,version_no,created_by) values (v_fs,v_kol,1,v_owner) returning id into v_fsv;
  insert into public.sectors (sector_code,name,created_by) values ('__S7R','__p2 s7r sec',v_owner) returning id into v_sec;
  insert into public.sector_versions (sector_id,version_no,margin_pct,created_by) values (v_sec,1,8.000,v_owner) returning id into v_sv;
  insert into public.calculation_default_versions (version_no,engine_version,rounding_rule_version,created_by)
    values (961,'engine/2026.09-a','round/0.05',v_owner) returning id into v_cdv;
  perform set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  update public.rate_set_versions set status='approved' where id=v_rsv;
  update public.freight_set_versions set status='approved' where id=v_fsv;
  update public.sector_versions set status='approved' where id=v_sv;
  update public.calculation_default_versions set status='approved' where id=v_cdv;
  reset role;
  perform set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  v_rel := public.propose_pricing_basis_release(v_kol, v_today-30, v_rsv, v_fsv, v_sv, v_cdv, null, '__s7r default');
  reset role;
  perform set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated; perform public.approve_pricing_basis_release(v_rel, true); reset role;
  perform set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, null); reset role;
  select id into v_pg from public.pricing_groups where batch_id=v_batch;
  update public.pricing_groups set freight_mode='manual', freight_manual_value=2.5 where id=v_pg;
  insert into public.batch_collaborators (batch_id, app_user_id, status, created_by)
    values (v_batch, v_other, 'active', v_owner);

  perform set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  insert into public.batch_rows (batch_id,plant_id,pricing_group_id,sku_id,sku_version_id,row_type,created_by,addon_printing)
    values (v_batch,v_kol,v_pg,v_sku,v_skuv,'box',v_maker,1.25) returning id into v_row;
  insert into public.batch_rows (batch_id,plant_id,pricing_group_id,sku_id,sku_version_id,row_type,created_by,addon_printing)
    values (v_batch,v_kol,v_pg,v_sku,v_skuv,'box',v_maker,1.25) returning id into v_row2;
  insert into public.batch_rows (batch_id,plant_id,pricing_group_id,sku_id,sku_version_id,row_type,created_by,addon_printing)
    values (v_batch,v_kol,v_pg,v_sku,v_skuv,'box',v_maker,1.25) returning id into v_row3;
  reset role;

  insert into app_private.attestation_keys (keyid,key,status) values ('t1', c_key, 'active');

  v_res := '{"contract_version":1,"engine":{"deckle":1,"cutting":1,"area":1,"wt":1.2,"wt_sheet":1,'
        || '"mat":48,"conv":1,"fr":1,"add_ons":1.25,"int_c":1,"total":1,"final_rate":1,"margin_amt":1,'
        || '"moq_kg":1,"estimated_box_wt":1,"calc_moq":1,"calc_bs":1,"calc_gsm":1,"rate_per_kg":1,'
        || '"fr_rate":2.5},"row_details":['
        || '{"k":"TOP","wt":0.5,"ws":0.5,"cost":20,"rate":1,"code":"K150","gsm":150,"tu":1},'
        || '{"k":"F1","wt":0.3,"ws":0.3,"cost":12,"rate":1,"code":"SF100","gsm":100,"tu":1.4},'
        || '{"k":"L1","wt":0.4,"ws":0.4,"cost":16,"rate":1,"code":"K120","gsm":120,"tu":1},'
        || '{"k":"F2","wt":0,"cost":0,"rate":0},{"k":"L2","wt":0,"cost":0,"rate":0}]}';

  select content_version into v_cvn from public.batch_rows where id=v_row;
  v_cfp := app_private.calculation_fingerprint(v_row);
  v_pfp := app_private.presentation_fingerprint(v_row);
  v_now := now();

  return next ok(v_cfp = app_private.calculation_fingerprint(v_row2),
    'CP-102 two rows with IDENTICAL inputs have the SAME calculation fingerprint - so a cross-row defence cannot rest on an incidental hash difference');

  -- ═══════════════════ C. CP-100, before anything is written ══
  select count(*)::int into v_n0 from public.batch_calculations;
  perform set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row, v_cvn, v_res, null); v_state:='NO ERROR';
  exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state, 'attestation_invalid',
    'CP-100 a fully authorised, lock-holding caller with NO attestation is refused - the direct PostgREST path is harmless');
  return next is((select count(*)::int from public.batch_calculations), v_n0, 'CP-100a and nothing was written');
  v_att := 'qca/1~t1~' || app_private.qca_ts(v_now) || '~'
        || app_private.qca_ts(v_now + interval '60 seconds') || '~' || repeat('0',64);
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row, v_cvn, v_res, v_att); v_state:='NO ERROR';
  exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state, 'attestation_invalid',
    'CP-100b a well-formed envelope with a WRONG MAC is refused by the same single failure - no per-field oracle');
  return next is((select count(*)::int from public.batch_calculations), v_n0, 'CP-100c and still nothing was written');

  -- ═══════════════════ D. the happy path, computed_at deliberately offset ══
  v_ca := v_now - interval '7 seconds';
  v_ea := v_now + interval '60 seconds';
  v_att := tests.__s7r_sign('t1', c_key, v_mauth::text, v_maker, v_batch, v_row, v_cvn,
                            v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_ca, v_ea);
  set local role authenticated;
  v_id := public.calculate_batch_row(v_row, v_cvn, v_res, v_att);
  reset role;
  return next ok(v_id is not null, 'CP-99 a valid attestation from the trusted executor is accepted');
  return next is((select computed_at from public.batch_calculations where id=v_id), v_ca,
    'CP-116 computed_at is the ATTESTED time, stored verbatim to the microsecond - not the transaction time');
  return next ok((select computed_at from public.batch_calculations where id=v_id) <> v_now,
    'CP-116a and demonstrably not now() - the column default never applied');
  return next is((select computed_by from public.batch_calculations where id=v_id), v_maker,
    'CP-116b and computed_by is the caller resolved from their own JWT');
  return next is((select effective_inputs from public.batch_calculations where id=v_id),
                 app_private.build_effective_inputs(v_row),
    'CP-107b the stored effective_inputs equal a FRESH gather from durable state - the database assembled them, no caller supplied them');
  return next is((select schema_version from public.batch_calculations where id=v_id), 1,
    'CP-107c schema_version 1 versions the PAYLOAD, never copied from a snapshot');
  return next is((select engine_version from public.batch_calculations where id=v_id), 'engine/2026.09-a',
    'CP-107d engine_version is governed - taken from the Release Calculation Defaults version, not declared by the client');
  return next is((select results from public.batch_calculations where id=v_id), v_res::jsonb,
    'CP-109d the STORED results are the PARSED jsonb - the signed text itself is not retained');

  -- ═══════════════════ E. CP-101 tampering ══
  select to_jsonb(b) into v_before from public.batch_calculations b where id=v_id;
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row, v_cvn, replace(v_res,'"final_rate":1','"final_rate":99'), v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  return next is(v_state,'attestation_invalid','CP-101 a tampered final_rate is refused');
  begin perform public.calculate_batch_row(v_row, v_cvn, replace(v_res,'"total":1','"total":99'), v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  return next is(v_state,'attestation_invalid','CP-101a a tampered total is refused');
  begin perform public.calculate_batch_row(v_row, v_cvn, replace(v_res,'"rate_per_kg":1','"rate_per_kg":99'), v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  return next is(v_state,'attestation_invalid','CP-101b a tampered rate_per_kg is refused');
  begin perform public.calculate_batch_row(v_row, v_cvn, replace(v_res,'"cost":20','"cost":99'), v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  return next is(v_state,'attestation_invalid','CP-101c a tampered row_details cost is refused');
  begin perform public.calculate_batch_row(v_row, v_cvn,
      replace(replace(replace(v_res,'"mat":48','"mat":96'),'"cost":20','"cost":40'),'"cost":12','"cost":24'), v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  return next is(v_state,'attestation_invalid',
    'CP-101d a CONSISTENTLY SCALED set - mat and the row_details costs moved together, so every internal identity still holds - is refused. This is the case the withdrawn client-writer design would have accepted');
  begin perform public.calculate_batch_row(v_row, v_cvn, replace(v_res,'{"contract_version"','{ "contract_version"'), v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'attestation_invalid',
    'CP-109 a re-serialisation that parses to the SAME jsonb but differs in bytes is refused - the digest is over octets, which a jsonb parameter could never have carried');
  select to_jsonb(b) into v_after from public.batch_calculations b where id=v_id;
  return next ok(v_before = v_after, 'CP-101e and the COMPLETE stored calculation is unchanged after all six attempts');

  -- ═══════════════════ F. CP-109 signed-but-invalid JSON ══
  v_att := tests.__s7r_sign('t1', c_key, v_mauth::text, v_maker, v_batch, v_row, v_cvn,
                            v_rel, 'engine/2026.09-a', v_cfp, v_pfp, '{oops', v_ca, v_ea);
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row, v_cvn, '{oops', v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'results_not_json',
    'CP-109a invalid JSON that IS correctly signed gets a controlled refusal, never an unmapped 22P02');
  v_att := tests.__s7r_sign('t1', c_key, v_mauth::text, v_maker, v_batch, v_row, v_cvn,
                            v_rel, 'engine/2026.09-a', v_cfp, v_pfp, '[]', v_ca, v_ea);
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row, v_cvn, '[]', v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'payload_contract',
    'CP-109b a correctly signed bare array fails the closed payload contract');

  -- ═══════════════════ G. CP-102 cross-row replay ══
  select content_version into v_cvn2 from public.batch_rows where id=v_row2;
  v_att := tests.__s7r_sign('t1', c_key, v_mauth::text, v_maker, v_batch, v_row, v_cvn,
                            v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_ca, v_ea);
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row2, v_cvn2, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'attestation_invalid',
    'CP-102a an attestation issued for row A is refused on row B even though both rows hash identically - the bound batch_row_id is the defence');
  return next ok(not exists (select 1 from public.batch_calculations where batch_row_id=v_row2),
    'CP-102b and row B still has no calculation');

  -- ═══════════════════ H. CP-103 stale durable state ══
  set local role authenticated;
  update public.batch_rows set addon_coating = 3 where id = v_row;
  begin perform public.calculate_batch_row(v_row, v_cvn, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  return next is(v_state,'stale content_version',
    'CP-103 after a durable input changes, the old attestation is refused on the version token');
  select content_version into v_cvn3 from public.batch_rows where id=v_row;
  begin perform public.calculate_batch_row(v_row, v_cvn3, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  update public.batch_rows set addon_coating = null where id = v_row;
  reset role;
  return next is(v_state,'attestation_invalid',
    'CP-103a and refused AGAIN with a matching version token - the RECOMPUTED fingerprint moved, so freshness does not depend on the token alone');
  select content_version into v_cvn from public.batch_rows where id=v_row;
  v_cfp := app_private.calculation_fingerprint(v_row);

  -- ═══════════════════ I. CP-104 actor binding across a lock transfer ══
  v_att := tests.__s7r_sign('t1', c_key, v_mauth::text, v_maker, v_batch, v_row, v_cvn,
                            v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_ca, v_ea);
  set local role authenticated; perform public.release_batch_lock(v_batch); reset role;
  perform set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated; perform public.acquire_batch_lock(v_batch);
  select to_jsonb(b) into v_before from public.batch_calculations b where id=v_id;
  begin perform public.calculate_batch_row(v_row, v_cvn, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'attestation_invalid',
    'CP-104 X attestation replayed by Y is refused EVEN AFTER Y legitimately acquires the lock - a result computed in X trusted invocation may not be recorded as Y work');
  select to_jsonb(b) into v_after from public.batch_calculations b where id=v_id;
  return next ok(v_before = v_after, 'CP-104a and nothing was written');

  v_att := tests.__s7r_sign('t1', c_key, v_oauth::text, v_maker, v_batch, v_row, v_cvn,
                            v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_ca, v_ea);
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row, v_cvn, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'attestation_invalid',
    'CP-104b the right Auth subject with the WRONG app_user_id is still refused - both halves are in the tuple');

  v_att := tests.__s7r_sign('t1', c_key, v_mauth::text, v_other, v_batch, v_row, v_cvn,
                            v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_ca, v_ea);
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row, v_cvn, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'attestation_invalid',
    'CP-104c and the right app_user_id with the WRONG Auth subject is refused too');

  v_ca := now() - interval '1 second';
  v_ea := now() + interval '60 seconds';
  v_att := tests.__s7r_sign('t1', c_key, v_oauth::text, v_other, v_batch, v_row, v_cvn,
                            v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_ca, v_ea);
  set local role authenticated;
  v_id2 := public.calculate_batch_row(v_row, v_cvn, v_res, v_att);
  reset role;
  return next is(v_id2, v_id, 'CP-104d Y obtaining a FRESH attestation bound to Y succeeds, replacing the same row');
  return next is((select computed_by from public.batch_calculations where id=v_id), v_other,
    'CP-104e and computed_by is now Y - the executor never asserts an actor, so the record names whoever actually caused the write');

  -- ═══════════════════ J. CP-105 / CP-110 replacement and idempotency ══
  set local role authenticated;
  return next is(public.calculate_batch_row(v_row, v_cvn, v_res, v_att), v_id,
    'CP-105 an identical replay returns the SAME id');
  reset role;
  return next is((select computed_at from public.batch_calculations where id=v_id), v_ca,
    'CP-105a and computed_at did not advance - a true no-op, not a rewrite');
  v_att := tests.__s7r_sign('t1', c_key, v_oauth::text, v_other, v_batch, v_row, v_cvn,
                            v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res,
                            v_ca - interval '30 seconds', now() + interval '60 seconds');
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row, v_cvn, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'calculation_superseded',
    'CP-110 a valid, unexpired attestation with an OLDER computed_at raises rather than silently writing nothing - a lost update must be loud');
  return next is((select computed_at from public.batch_calculations where id=v_id), v_ca,
    'CP-110a and the newer calculation is untouched');

  -- ═══════════════════ K. CP-111 / CP-112 time boundaries ══
  select content_version into v_cvn3 from public.batch_rows where id=v_row3;
  v_cfp := app_private.calculation_fingerprint(v_row3);
  v_pfp := app_private.presentation_fingerprint(v_row3);
  v_now := now();
  v_att := tests.__s7r_sign('t1', c_key, v_oauth::text, v_other, v_batch, v_row3, v_cvn3,
             v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_now + interval '6 seconds', v_now + interval '60 seconds');
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row3, v_cvn3, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'attestation_future',
    'CP-111 a computed_at beyond the 5-second skew allowance is refused');
  v_att := tests.__s7r_sign('t1', c_key, v_oauth::text, v_other, v_batch, v_row3, v_cvn3,
             v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_now - interval '1 second', v_now - interval '1 microsecond');
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row3, v_cvn3, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'attestation_expired',
    'CP-112 an expires_at one microsecond in the past is refused');
  v_att := tests.__s7r_sign('t1', c_key, v_oauth::text, v_other, v_batch, v_row3, v_cvn3,
             v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_now, v_now + interval '121 seconds');
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row3, v_cvn3, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'attestation_lifetime_exceeded',
    'CP-112a a lifetime of 121 seconds is refused - the executor cannot mint a long-lived attestation');
  v_att := tests.__s7r_sign('t1', c_key, v_oauth::text, v_other, v_batch, v_row3, v_cvn3,
             v_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res, v_now, v_now + interval '120 seconds');
  set local role authenticated;
  return next ok(public.calculate_batch_row(v_row3, v_cvn3, v_res, v_att) is not null,
    'CP-112b and a lifetime of exactly 120 seconds is accepted - the boundary is inclusive');
  reset role;

  -- ═══════════════════ L. CP-114 keyring rotation ══
  update app_private.attestation_keys set status='retiring', retiring_at=now() where keyid='t1';
  set local role authenticated;
  return next is(public.calculate_batch_row(v_row3, v_cvn3, v_res, v_att),
                 (select id from public.batch_calculations where batch_row_id=v_row3),
    'CP-114c a RETIRING key still verifies, so a rotation does not invalidate attestations already in flight');
  reset role;
  update app_private.attestation_keys set retiring_at = now() - interval '121 seconds' where keyid='t1';
  set local role authenticated;
  begin perform public.calculate_batch_row(v_row3, v_cvn3, v_res, v_att);
    v_state:='NO ERROR'; exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state,'attestation_invalid',
    'CP-114d and stops verifying once retired longer than the maximum attestation lifetime - the overlap cannot become a second permanent signing key');
  update app_private.attestation_keys set status='active', retiring_at=null where keyid='t1';

  -- ═══════════════════ M. the approved rulings (Y still holds the lock) ══
  set local role authenticated;
  insert into public.batch_rows (batch_id,plant_id,pricing_group_id,sku_id,sku_version_id,row_type,created_by)
    values (v_batch,v_kol,v_pg,v_sku2,v_skuv2,'box',v_other) returning id into v_row2;
  reset role;
  return next is((app_private.build_effective_inputs(v_row2)->'provenance'->>'sku_status'), 'discontinued',
    'D-G a DISCONTINUED SKU may be calculated, and its status is frozen into provenance as evidence');
  return next ok(not (app_private.build_effective_inputs(v_row2)->'provenance' ? 'replacement_sku_id'),
    'D-Ga and the replacement is NOT substituted - skus.replacement_sku_id is never read');

  update public.pricing_groups set freight_mode='master', freight_manual_value=null where id=v_pg;
  insert into public.delivery_groups (pricing_group_id,batch_id,ship_to_location_id,status,created_by)
    values (v_pg, v_batch, v_loc, 'active', v_owner) returning id into v_dg;
  update public.pricing_groups set freight_basis_delivery_group_id=v_dg where id=v_pg;
  insert into public.freight_entries (freight_set_version_id,plant_id,origin_plant_id,destination_location_id,rate,created_by)
    values (v_fsv, v_kol, v_kol, v_loc, 3.75, v_owner);
  return next is((app_private.build_effective_inputs(v_row)->'resolved'->'freight'->>'source'), 'master',
    'CP-65 an approved Freight Master resolves through the basis Ship-to');
  return next is((app_private.build_effective_inputs(v_row)->'resolved'->'freight'->>'value'), '3.75',
    'CP-65a and the frozen value is the Freight Entry rate');

  update public.customer_locations set status='inactive' where id=v_loc;
  begin perform app_private.assert_calculate_eligible(v_row); v_state:='NO ERROR';
  exception when others then v_state := sqlerrm; end;
  return next is(v_state,'basis_ship_to_retired',
    'D-W calculation against a RETIRED freight-basis Ship-to is refused - a Calculate refusal, not a degradation');
  return next ok(exists (select 1 from public.batch_calculations where id=v_id),
    'D-Wa and calculations frozen before the retirement remain intact - the ruling is forward-only');
  update public.customer_locations set status='active' where id=v_loc;

  set local role authenticated; perform public.release_batch_lock(v_batch); reset role;
  update public.batches set status='submitted' where id=v_batch;
  perform set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated; perform public.acquire_batch_lock(v_batch); reset role;
  return next ok(app_private.can_write_batch(v_batch),
    'D-X pre-condition: can_write_batch ADMITS a check_quote holder on a SUBMITTED Batch - so the refusal below cannot be inherited from it');
  begin perform app_private.assert_calculate_eligible(v_row); v_state:='NO ERROR';
  exception when others then v_state := sqlerrm; end;
  return next is(v_state,'calculate_requires_maker',
    'D-X Checker Calculate is refused explicitly - recalculation returns to the Maker');
  update public.batches set status='working' where id=v_batch;
end $fn$;

revoke all on function tests.__s7r_body() from public, anon, authenticated;