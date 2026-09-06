-- S6-15: the Family F security personas, which S6 shipped without.
--
-- S5-5 was pulled up for having zero inactive-persona gates and no HTTP-level
-- attack coverage on its own surface. S6 then shipped ten tables and six
-- operations with the same two gaps: no inactive gate anywhere, no wrong-plant
-- READ or WRITE gate on any Family F table, and every existing suite running as
-- the table owner where RLS does not apply. BF-8's "wrong-plant" is a composite
-- FOREIGN KEY gate, not an access gate - it proves a NAG Batch cannot cite a PUN
-- SKU, which is a different question from whether a PUN Maker can see the Batch.
--
-- Five personas, all minted, none borrowed:
--
--   OWNER     Maker at NAG who creates the Batch and holds its lock
--   COLLAB    Maker at NAG added as an active collaborator (CDM-32)
--   OUTSIDER  Maker at NAG with plant_access and make_quote and NO relation to
--             this Batch - the persona that proves plant access alone is not
--             Batch access
--   PUN       Maker at another plant entirely
--   CHECKER   check_quote at NAG
--
-- The ACTIVE baseline comes first on all ten tables, so every zero afterwards is
-- denial rather than emptiness - the rule S5-6 restored for Family D and E,
-- applied here from the start. Where RLS produces a silent no-op rather than an
-- error, the row is read back instead of an exception being expected.

create or replace function tests.family_f_security()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['batches','batch_collaborators','batch_profile_versions',
                           'batch_edit_locks','pricing_groups','delivery_groups',
                           'batch_rows','batch_sets','batch_set_memberships',
                           'batch_calculations'];
  t text; v_owner bigint; v_nag bigint; v_pun bigint; v_n int; v_state text;
  v_oauth uuid; v_oclaims text; v_own bigint; v_oemail text := 'p2-s6fo@example.invalid';
  v_cauth uuid; v_cclaims text; v_collab bigint; v_cemail text := 'p2-s6fc@example.invalid';
  v_xauth uuid; v_xclaims text; v_outsider bigint; v_xemail text := 'p2-s6fx@example.invalid';
  v_pauth uuid; v_pclaims text; v_punmk bigint; v_pemail text := 'p2-s6fp@example.invalid';
  v_kauth uuid; v_kclaims text; v_checker bigint; v_kemail text := 'p2-s6fk@example.invalid';
  v_fam bigint; v_party bigint; v_kpub bigint; v_cvpub bigint;
  v_sku bigint; v_skuv bigint; v_batch bigint; v_pg bigint; v_dg bigint;
  v_box bigint; v_plate bigint; v_set bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';

  -- ------------------------------------------------------------ personas
  v_oauth := tests.__fixture_auth_uid();
  v_oclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_oauth, v_oemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_oemail, '__p2_s6f_owner', false);
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated; v_own := public.bootstrap_app_user(); reset role;

  v_cauth := tests.__fixture_auth_uid();
  v_cclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_cauth, v_cemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_cemail, '__p2_s6f_collab', false);
  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated; v_collab := public.bootstrap_app_user(); reset role;

  v_xauth := tests.__fixture_auth_uid();
  v_xclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_xauth, v_xemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_xemail, '__p2_s6f_outsider', false);
  perform pg_catalog.set_config('request.jwt.claims', v_xclaims, true);
  set local role authenticated; v_outsider := public.bootstrap_app_user(); reset role;

  v_pauth := tests.__fixture_auth_uid();
  v_pclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_pauth, v_pemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_pemail, '__p2_s6f_pun', false);
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated; v_punmk := public.bootstrap_app_user(); reset role;

  v_kauth := tests.__fixture_auth_uid();
  v_kclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_kauth, v_kemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_kemail, '__p2_s6f_checker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_kclaims, true);
  set local role authenticated; v_checker := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select u, v_nag, c.id, v_owner
    from unnest(array[v_own, v_collab, v_outsider]) u
    cross join public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_punmk, v_pun, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_checker, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','check_quote');

  -- ------------------------------------------------------------ fixtures
  insert into public.customer_families (name, status, created_by)
    values ('__p2 fsec family','active',v_owner) returning id into v_fam;
  insert into public.parties (display_name, created_by) values ('__p2 fsec party', v_owner)
    returning id into v_party;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    values (v_party, v_fam, current_date, v_owner);
  insert into public.constructions (name, created_by) values ('__p2 fsec con', v_owner)
    returning id into v_kpub;
  insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kpub, 1, 3, v_owner) returning id into v_cvpub;
  update public.constructions set construction_code='CON-995001', status='published' where id=v_kpub;
  insert into public.skus (plant_id, party_id, created_by) values (v_nag, v_party, v_owner)
    returning id into v_sku;
  insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id, is_price_driving, created_by)
    values (v_sku, v_nag, 1, v_cvpub, true, v_owner) returning id into v_skuv;

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  v_batch := public.create_batch(v_fam, v_nag, null);
  reset role;
  select id into v_pg from public.pricing_groups where batch_id = v_batch;
  select id into v_dg from public.delivery_groups where batch_id = v_batch;

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  insert into public.batch_collaborators (batch_id, app_user_id, created_by)
  values (v_batch, v_collab, v_own);
  insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, row_type, created_by)
  values (v_batch, v_nag, v_pg, v_sku, v_skuv, 'box', v_own) returning id into v_box;
  insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, row_type, created_by)
  values (v_batch, v_nag, v_pg, v_sku, v_skuv, 'plate', v_own) returning id into v_plate;
  insert into public.batch_sets (batch_id, box_row_id, set_code, created_by)
  values (v_batch, v_box, 'FSEC1', v_own) returning id into v_set;
  insert into public.batch_set_memberships (set_id, row_id, batch_id, role, created_by)
  values (v_set, v_plate, v_batch, 'plate', v_own);
  reset role;

  -- batch_calculations is RPC-only and has no write grant at all, so the fixture
  -- seeds it privileged; FS-12 asserts that a caller cannot
  insert into public.batch_calculations
    (batch_row_id, batch_id, calculation_fingerprint, presentation_fingerprint,
     engine_version, schema_version, effective_inputs, results, computed_by)
  values (v_box, v_batch, 'fp-c', 'fp-p', 'engine-test', 1, '{}'::jsonb, '{}'::jsonb, v_own);

  -- ============================================== the ACTIVE baseline
  foreach t in array v_tables loop
    perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
    set local role authenticated;
    execute format('select count(*) from public.%I', t) into v_n;
    reset role;
    return next ok(v_n > 0,
      format('FS-1 the OWNER can see rows in %s - the baseline every zero below is measured against', t));
  end loop;

  -- ====================================== wrong plant: reads see nothing
  foreach t in array v_tables loop
    perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
    set local role authenticated;
    execute format('select count(*) from public.%I', t) into v_n;
    reset role;
    return next is(v_n, 0,
      format('FS-2 a Maker at ANOTHER plant sees nothing in %s (CDM-35)', t));
  end loop;

  -- ============================ same plant, no relation: also sees nothing
  perform pg_catalog.set_config('request.jwt.claims', v_xclaims, true);
  set local role authenticated;
  select count(*) into v_n from public.batches where id = v_batch; reset role;
  return next is(v_n, 0,
    'FS-3 plant access alone is NOT Batch access - an unrelated Maker at the same plant sees no Batch (CDM-32)');
  perform pg_catalog.set_config('request.jwt.claims', v_xclaims, true);
  set local role authenticated;
  select count(*) into v_n from public.batch_rows where batch_id = v_batch; reset role;
  return next is(v_n, 0, 'FS-3a nor its rows');

  -- ====================================== wrong plant: writes are refused
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, row_type, created_by)
    values (v_batch, v_nag, v_pg, v_sku, v_skuv, 'other', v_punmk);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FS-4 a Maker at another plant cannot add a row to this Batch');
  return next is((select count(*)::int from public.batch_rows where batch_id=v_batch), 2,
    'FS-4a and the Batch still has exactly its two rows');

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 pun write' where id = v_pg;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), 'Default',
    'FS-5 an UPDATE from another plant matches no row and changes nothing - read back, not trusted to raise');

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    perform public.create_batch(v_fam, v_nag, null);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FS-6 nor may they create a Batch AT a plant they hold nothing at - the RPC checks the plant, not the caller''s wish');

  -- ================================== owner versus collaborator authority
  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  select count(*) into v_n from public.batches where id = v_batch; reset role;
  return next is(v_n, 1, 'FS-7 an active COLLABORATOR can read the Batch (CDM-32)');

  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 collab no lock' where id = v_pg;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), 'Default',
    'FS-7a but cannot write while the OWNER holds the lock - one active editor (CDM-32)');

  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  begin
    insert into public.batch_collaborators (batch_id, app_user_id, created_by)
    values (v_batch, v_outsider, v_collab);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FS-8 a collaborator cannot add collaborators - that is the owner''s, Checker''s or Admin''s act (CDM-32)');

  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  begin
    perform public.reclaim_batch_lock(v_batch, v_own);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FS-9 nor reclaim a lock - CDM-32 names owner reclaim and Checker/Admin takeover, and a collaborator is neither');

  -- the collaborator CAN write once the lock is genuinely theirs
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated; perform public.release_batch_lock(v_batch); reset role;
  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  perform public.acquire_batch_lock(v_batch);
  update public.pricing_groups set label = '__p2 collab with lock' where id = v_pg;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), '__p2 collab with lock',
    'FS-10 and writes normally once it holds the lock - collaboration works, it is just serialised');

  -- ======================================== Checker and Admin boundaries
  perform pg_catalog.set_config('request.jwt.claims', v_kclaims, true);
  set local role authenticated;
  select count(*) into v_n from public.batches where id = v_batch; reset role;
  return next is(v_n, 1, 'FS-11 the Checker at that plant can read the Batch');

  perform pg_catalog.set_config('request.jwt.claims', v_kclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 checker working' where id = v_pg;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), '__p2 collab with lock',
    'FS-11a but cannot edit a WORKING Batch - CDM-33 gives the Checker edit only once it is submitted');

  perform pg_catalog.set_config('request.jwt.claims', v_xclaims, true);
  set local role authenticated;
  begin
    perform public.takeover_batch_lock(v_batch);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FS-12 an unrelated Maker cannot take over the lock');

  perform pg_catalog.set_config('request.jwt.claims', v_kclaims, true);
  set local role authenticated;
  perform public.takeover_batch_lock(v_batch);
  reset role;
  return next is((select holder_user_id from public.batch_edit_locks where batch_id=v_batch), v_checker,
    'FS-12a while the Checker may, at any time, without waiting for staleness (CDM-32)');

  -- ============================ direct-table and RPC bypass attempts
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    insert into public.batch_edit_locks (batch_id, holder_user_id) values (v_batch, v_own);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FS-13 the lock table is RPC-only - even the owner cannot write it directly and grant themselves the lock');

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    update public.batch_edit_locks set holder_user_id = v_own where batch_id = v_batch;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FS-13a nor take it back by UPDATE');

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    insert into public.batch_calculations
      (batch_row_id, batch_id, calculation_fingerprint, presentation_fingerprint,
       engine_version, schema_version, effective_inputs, results, computed_by)
    values (v_plate, v_batch, 'x', 'y', 'e', 1, '{}'::jsonb, '{}'::jsonb, v_own);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FS-14 and batch_calculations has no write grant at all - a caller cannot publish a calculation (S7 owns that)');

  perform pg_catalog.set_config('request.jwt.claims', v_xclaims, true);
  set local role authenticated;
  begin
    perform public.acquire_batch_lock(v_batch);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FS-15 an unrelated Maker cannot acquire a lock on a Batch they cannot even read - the id is not the authority (IDOR)');

  perform pg_catalog.set_config('request.jwt.claims', v_xclaims, true);
  set local role authenticated;
  begin
    perform public.revise_batch_profile(v_batch, 1, 1.000, null, null, null, null, null);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FS-15a nor revise its profile by knowing its id');

  -- ============================================ the INACTIVE persona
  update public.app_users set status='deactivated', deactivated_at=now() where id = v_own;
  foreach t in array v_tables loop
    perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
    set local role authenticated;
    execute format('select count(*) from public.%I', t) into v_n;
    reset role;
    return next is(v_n, 0,
      format('FS-16 a DEACTIVATED owner holding the same token sees nothing in %s (CDM-05)', t));
  end loop;

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    perform public.create_batch(v_fam, v_nag, null);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FS-17 nor may they create a Batch');

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    perform public.acquire_batch_lock(v_batch);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'FS-17a nor reach any lock operation');

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 dead write' where id = v_pg;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), '__p2 collab with lock',
    'FS-18 and a deactivated write matches no row rather than raising - so the row is read back, not the exception trusted');

  update public.app_users set status='active', deactivated_at=null where id = v_own;

  -- ------------------------------------------------------------- cleanup
  delete from public.batch_set_memberships where batch_id = v_batch;
  delete from public.batch_sets where batch_id = v_batch;
  delete from public.batch_calculations where batch_id = v_batch;
  delete from public.batch_rows where batch_id = v_batch;
  update public.pricing_groups set freight_basis_delivery_group_id = null where batch_id = v_batch;
  delete from public.delivery_groups where batch_id = v_batch;
  delete from public.pricing_groups where batch_id = v_batch;
  delete from public.batch_profile_versions where batch_id = v_batch;
  delete from public.batch_collaborators where batch_id = v_batch;
  delete from public.batch_edit_locks where batch_id = v_batch;
  delete from public.batches where id = v_batch;
  delete from public.sku_versions where sku_id = v_sku;
  delete from public.skus where id = v_sku;
  delete from public.construction_versions where construction_id = v_kpub;
  delete from public.constructions where id = v_kpub;
  delete from public.party_family_memberships where party_id = v_party;
  delete from public.parties where id = v_party;
  delete from public.customer_families where id = v_fam;
  delete from public.plant_capability_grants where app_user_id in (v_own, v_collab, v_outsider, v_punmk, v_checker);
  delete from public.group_capability_grants where app_user_id in (v_own, v_collab, v_outsider, v_punmk, v_checker);
  delete from public.operational_settings     where created_by  in (v_own, v_collab, v_outsider, v_punmk, v_checker);
  delete from app_private.pending_invitations where invite_email in (v_oemail, v_cemail, v_xemail, v_pemail, v_kemail);
  delete from public.app_users where id in (v_own, v_collab, v_outsider, v_punmk, v_checker);
  perform tests.__drop_synthetic_auth(v_oauth);
  perform tests.__drop_synthetic_auth(v_cauth);
  perform tests.__drop_synthetic_auth(v_xauth);
  perform tests.__drop_synthetic_auth(v_pauth);
  perform tests.__drop_synthetic_auth(v_kauth);
  perform pg_catalog.set_config('request.jwt.claims', null, true);
end $fn$;

revoke all on function tests.family_f_security() from public, anon, authenticated;
