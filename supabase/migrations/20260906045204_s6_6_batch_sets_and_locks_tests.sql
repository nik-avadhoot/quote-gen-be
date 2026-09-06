-- S6-6: proof gates for SET cardinality (§5.9, CDM-20) and for the edit lock,
-- content_version and concurrency (A-23, A-24, CDM-32).

create or replace function tests.batch_sets()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_owner bigint; v_nag bigint; v_state text;
  v_fam bigint; v_party bigint; v_kpub bigint; v_cvpub bigint;
  v_sku bigint; v_skuv bigint; v_batch bigint; v_batch2 bigint; v_pg bigint; v_pg2 bigint;
  v_box bigint; v_plate bigint; v_plate2 bigint; v_foreign_row bigint;
  v_set bigint; v_m1 bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';
  perform pg_catalog.set_config('request.jwt.claims',
    (select format('{"sub":"%s","role":"authenticated"}', a.auth_user_id)
       from public.app_users a where a.id = v_owner), true);

  insert into public.customer_families (name, status, created_by)
    values ('__p2 bs family','active',v_owner) returning id into v_fam;
  insert into public.parties (display_name, created_by) values ('__p2 bs party', v_owner)
    returning id into v_party;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    values (v_party, v_fam, current_date, v_owner);
  insert into public.constructions (name, created_by) values ('__p2 bs con', v_owner) returning id into v_kpub;
  insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kpub, 1, 3, v_owner) returning id into v_cvpub;
  update public.constructions set construction_code='CON-993001', status='published' where id=v_kpub;
  insert into public.skus (plant_id, party_id, created_by) values (v_nag, v_party, v_owner) returning id into v_sku;
  insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id, is_price_driving, created_by)
    values (v_sku, v_nag, 1, v_cvpub, true, v_owner) returning id into v_skuv;

  insert into public.batches (batch_reference, family_id, plant_id, owner_user_id, created_by)
    values ('x', v_fam, v_nag, v_owner, v_owner) returning id into v_batch;
  insert into public.batches (batch_reference, family_id, plant_id, owner_user_id, created_by)
    values ('x', v_fam, v_nag, v_owner, v_owner) returning id into v_batch2;
  insert into public.pricing_groups (batch_id, created_by) values (v_batch, v_owner) returning id into v_pg;
  insert into public.pricing_groups (batch_id, created_by) values (v_batch2, v_owner) returning id into v_pg2;

  insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, row_type, created_by)
    values (v_batch, v_nag, v_pg, v_sku, v_skuv, 'box', v_owner) returning id into v_box;
  insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, row_type, created_by)
    values (v_batch, v_nag, v_pg, v_sku, v_skuv, 'plate', v_owner) returning id into v_plate;
  insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, row_type, created_by)
    values (v_batch, v_nag, v_pg, v_sku, v_skuv, 'plate', v_owner) returning id into v_plate2;
  insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, row_type, created_by)
    values (v_batch2, v_nag, v_pg2, v_sku, v_skuv, 'plate', v_owner) returning id into v_foreign_row;

  -- ================================================= §5.9 cardinality
  begin
    insert into public.batch_sets (batch_id, box_row_id, set_code, status, created_by)
    values (v_batch, v_box, 'S1', 'active', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'BS-1 (§5.9) an ACTIVE SET with no components is impossible - no write path can create one');

  insert into public.batch_sets (batch_id, box_row_id, set_code, created_by)
    values (v_batch, v_box, 'S1', v_owner) returning id into v_set;
  return next is((select status from public.batch_sets where id=v_set), 'dissolved',
    'BS-2 a SET with no components is born dissolved - the truthful state (CDM-20)');

  -- §5.6 the parent must be a Box
  begin
    insert into public.batch_sets (batch_id, box_row_id, set_code, created_by)
    values (v_batch, v_plate, 'S2', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'BS-3 (§5.6) a non-Box row cannot be a SET parent - it has no matching parent key');

  -- attaching the first component promotes the SAME row
  insert into public.batch_set_memberships (set_id, row_id, batch_id, role, created_by)
    values (v_set, v_plate, v_batch, 'plate', v_owner) returning id into v_m1;
  return next is((select status from public.batch_sets where id=v_set), 'active',
    'BS-4 attaching the first component creates the SET, on the same row (CDM-20)');
  return next is((select active_component_count from public.batch_sets where id=v_set), 1,
    'BS-4a and the counter follows it');

  -- §5.5 a component from another Batch is impossible
  begin
    insert into public.batch_set_memberships (set_id, row_id, batch_id, role, created_by)
    values (v_set, v_foreign_row, v_batch, 'plate', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'BS-5 (§5.5) a component from another Batch is REJECTED');

  -- the counter is the database's word, not the client's
  update public.batch_sets set active_component_count = 99 where id = v_set;
  return next is((select active_component_count from public.batch_sets where id=v_set), 1,
    'BS-6 a client-supplied component count is discarded and recomputed from the memberships');

  -- removing the last component dissolves WITHOUT deleting (A-9, A-15)
  update public.batch_set_memberships set status='removed' where id = v_m1;
  return next is((select status from public.batch_sets where id=v_set), 'dissolved',
    'BS-7 removing the last component dissolves the SET (CDM-20)');
  return next is((select count(*)::int from public.batch_sets where id=v_set), 1,
    'BS-7a but does not delete it - identity and label survive (A-9/A-15)');
  return next is((select set_code from public.batch_sets where id=v_set), 'S1',
    'BS-7b with its label intact and still relabellable');

  -- A-16: the code stays reserved while dissolved, normalised
  begin
    insert into public.batch_sets (batch_id, box_row_id, set_code, created_by)
    values (v_batch, v_plate2, 's1', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23505',
    'BS-8 (A-16) a dissolved SET keeps reserving its code, case-insensitively - `s1` collides with `S1`');

  -- reattaching reactivates the SAME row
  update public.batch_set_memberships set status='active' where id = v_m1;
  return next is((select status from public.batch_sets where id=v_set), 'active',
    'BS-9 reattaching a component reactivates the SET');
  return next is((select id from public.batch_sets where batch_id=v_batch and set_code='S1'), v_set,
    'BS-9a on the SAME row - reactivation preserves identity, never a new SET (A-9)');

  -- one SET per Box, and no blank code
  begin
    insert into public.batch_sets (batch_id, box_row_id, set_code, created_by)
    values (v_batch, v_box, 'S3', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23505', 'BS-10 a Box carries at most one SET');

  begin
    insert into public.batch_sets (batch_id, box_row_id, set_code, created_by)
    values (v_batch, v_plate2, '   ', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514', 'BS-11 a SET code is mandatory and cannot be blank (CDM-20)');

  -- ------------------------------------------------------------- cleanup
  delete from public.batch_set_memberships where batch_id in (v_batch, v_batch2);
  delete from public.batch_sets where batch_id in (v_batch, v_batch2);
  delete from public.batch_rows where batch_id in (v_batch, v_batch2);
  delete from public.pricing_groups where batch_id in (v_batch, v_batch2);
  delete from public.batch_edit_locks where batch_id in (v_batch, v_batch2);
  delete from public.batches where id in (v_batch, v_batch2);
  delete from public.sku_versions where sku_id = v_sku;
  delete from public.skus where id = v_sku;
  delete from public.construction_versions where construction_id = v_kpub;
  delete from public.constructions where id = v_kpub;
  delete from public.party_family_memberships where party_id = v_party;
  delete from public.parties where id = v_party;
  delete from public.customer_families where id = v_fam;
  perform pg_catalog.set_config('request.jwt.claims', null, true);
end $fn$;

create or replace function tests.batch_locks()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_owner bigint; v_nag bigint; v_state text; v_n int; v_cv int; v_hb timestamptz;
  v_fam bigint;
  v_mauth uuid; v_mclaims text; v_maker bigint; v_memail text := 'p2-s6m@example.invalid';
  v_oauth uuid; v_oclaims text; v_other bigint; v_oemail text := 'p2-s6o@example.invalid';
  v_cauth uuid; v_cclaims text; v_check bigint; v_cemail text := 'p2-s6c@example.invalid';
  v_batch bigint; v_pg bigint; v_lock bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';

  -- A-23 as a structural fact, before any behaviour is exercised
  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='batch_edit_locks' and column_name='content_version'),
    0, 'BL-1 (A-23) batch_edit_locks has no content_version column at all - the two cannot be confused');

  -- personas
  v_mauth := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_memail, '__p2_s6_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated; v_maker := public.bootstrap_app_user(); reset role;

  v_oauth := tests.__fixture_auth_uid();
  v_oclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_oauth, v_oemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_oemail, '__p2_s6_other', false);
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated; v_other := public.bootstrap_app_user(); reset role;

  v_cauth := tests.__fixture_auth_uid();
  v_cclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_cauth, v_cemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_cemail, '__p2_s6_checker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated; v_check := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_other, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_check, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','check_quote');

  insert into public.customer_families (name, status, created_by)
    values ('__p2 bl family','active',v_owner) returning id into v_fam;

  -- ---------------------------------------------- CDM-15 Batch creation
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_batch := public.create_batch(v_fam, v_nag, null);
  reset role;
  return next ok(v_batch is not null, 'BL-2 a Maker creates a Batch through the RPC');
  return next is((select count(*)::int from public.pricing_groups where batch_id=v_batch), 1,
    'BL-2a with exactly one default Pricing Group (CDM-15)');
  return next is((select count(*)::int from public.delivery_groups where batch_id=v_batch), 1,
    'BL-2b and one default Delivery Group');
  return next is((select count(*)::int from public.batch_profile_versions where batch_id=v_batch and is_current), 1,
    'BL-2c and exactly one current Batch Profile version');
  return next is((select count(*)::int from public.batch_edit_locks where batch_id=v_batch and holder_user_id=v_maker), 1,
    'BL-2d and the creator holds the edit lock');

  select id into v_pg from public.pricing_groups where batch_id = v_batch;

  -- ------------------------------------------- A-23 heartbeat isolation
  select content_version into v_cv from public.batches where id = v_batch;
  select heartbeat_at into v_hb from public.batch_edit_locks where batch_id = v_batch;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.heartbeat_batch_lock(v_batch);
  reset role;
  return next is((select content_version from public.batches where id=v_batch), v_cv,
    'BL-3 (A-23) the heartbeat leaves batches.content_version untouched');
  return next ok((select heartbeat_at from public.batch_edit_locks where batch_id=v_batch) >= v_hb,
    'BL-3a while advancing heartbeat_at, which is all it may touch');

  -- ------------------------------------------------ the lock gates writes
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups set label = '__p2 no lock' where id = v_pg;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), 'Default',
    'BL-4 a second Maker WITHOUT the lock changes nothing, even holding make_quote');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 with lock' where id = v_pg;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), '__p2 with lock',
    'BL-4a while the lock holder writes normally');

  -- ------------------------------------------------ content_version rules
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups set content_version = 99 where id = v_pg;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'BL-5 content_version is the database''s to maintain - a caller cannot set it');

  select content_version into v_cv from public.pricing_groups where id = v_pg;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 again' where id = v_pg;
  reset role;
  return next is((select content_version from public.pricing_groups where id=v_pg), v_cv + 1,
    'BL-6 and it advances on every write, so it is a usable CAS token');

  -- CAS is the caller's filter, and a stale token matches nothing
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 stale write'
   where id = v_pg and content_version = v_cv - 1;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), '__p2 again',
    'BL-7 a write carrying a STALE content_version matches no row and changes nothing');

  select content_version into v_cv from public.pricing_groups where id = v_pg;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 fresh write'
   where id = v_pg and content_version = v_cv;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), '__p2 fresh write',
    'BL-7a while the current one succeeds - CAS works through the filter (PostgREST style)');

  -- --------------------------------------------------- reclaim and takeover
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    perform public.reclaim_batch_lock(v_batch, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '55P03',
    'BL-8 (A-24) a LIVE lock cannot be reclaimed - staleness is judged server-side, not by the caller');

  -- backdate the heartbeat past the configured threshold
  update public.batch_edit_locks
     set heartbeat_at = now() - ((app_private.edit_lock_stale_seconds() + 60) * interval '1 second')
   where batch_id = v_batch;

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  v_lock := public.reclaim_batch_lock(v_batch, v_maker);
  reset role;
  return next ok(v_lock is not null, 'BL-9 a STALE lock is reclaimable');
  return next is((select holder_user_id from public.batch_edit_locks where batch_id=v_batch), v_other,
                 'BL-9a and the reclaimer now holds it');

  -- the same reclaim, replayed: the loser's condition no longer matches
  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  begin
    perform public.reclaim_batch_lock(v_batch, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '55P03',
    'BL-10 a second reclaim naming the SAME expected holder loses - one conditional statement, one winner');
  return next is((select holder_user_id from public.batch_edit_locks where batch_id=v_batch), v_other,
    'BL-10a and the first winner still holds it - the loser changed nothing');

  -- CDM-32 takeover
  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  begin
    perform public.takeover_batch_lock(v_batch, '   ');
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '22023', 'BL-11 (CDM-32) an active takeover REQUIRES a reason');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.takeover_batch_lock(v_batch, 'maker attempting takeover');
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'BL-12 and a Maker cannot take over - it is the Checker''s or an administrator''s act');

  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  perform public.takeover_batch_lock(v_batch, 'checker takeover with reason');
  reset role;
  return next is((select holder_user_id from public.batch_edit_locks where batch_id=v_batch), v_check,
    'BL-12a while the Checker with a reason succeeds, without waiting for staleness');

  -- ------------------------------------------------------------- anon
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.proname in ('create_batch','acquire_batch_lock','heartbeat_batch_lock',
                          'release_batch_lock','reclaim_batch_lock','takeover_batch_lock')
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')),
    0, 'BL-13 anon can execute none of the Batch or lock operations');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app_private'
        and p.proname in ('create_batch','acquire_batch_lock','heartbeat_batch_lock',
                          'release_batch_lock','reclaim_batch_lock','takeover_batch_lock')
        and p.prosecdef),
    6, 'BL-13a and all six privileges live in app_private as SECURITY DEFINER');

  -- ------------------------------------------------------------- cleanup
  delete from public.batch_calculations where batch_id = v_batch;
  delete from public.batch_rows where batch_id = v_batch;
  update public.pricing_groups set freight_basis_delivery_group_id = null where batch_id = v_batch;
  delete from public.delivery_groups where batch_id = v_batch;
  delete from public.pricing_groups where batch_id = v_batch;
  delete from public.batch_profile_versions where batch_id = v_batch;
  delete from public.batch_edit_locks where batch_id = v_batch;
  delete from public.batches where id = v_batch;
  delete from public.customer_families where id = v_fam;
  delete from public.plant_capability_grants where app_user_id in (v_maker, v_other, v_check);
  delete from public.group_capability_grants where app_user_id in (v_maker, v_other, v_check);
  delete from public.operational_settings     where created_by  in (v_maker, v_other, v_check);
  delete from app_private.pending_invitations where invite_email in (v_memail, v_oemail, v_cemail);
  delete from public.app_users where id in (v_maker, v_other, v_check);
  perform tests.__drop_synthetic_auth(v_mauth);
  perform tests.__drop_synthetic_auth(v_oauth);
  perform tests.__drop_synthetic_auth(v_cauth);
  perform pg_catalog.set_config('request.jwt.claims', null, true);
end $fn$;

revoke all on function tests.batch_sets() from public, anon, authenticated;
revoke all on function tests.batch_locks() from public, anon, authenticated;