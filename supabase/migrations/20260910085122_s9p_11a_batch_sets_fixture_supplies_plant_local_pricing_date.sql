-- S9-P/11a: tests.batch_sets() supplies the Pricing Date its inserts now need.
--
-- S9-P/10 removed the server-date default from batches.pricing_date. This suite
-- inserts into batches directly at OWNER level - where the `authenticated`
-- revocation of S9-P/9 does not apply - and did not name the column, so it
-- relied on that default. Without it the fixture fails 23502 before reaching a
-- single assertion.
--
-- The fixture now computes the PRODUCING PLANT's local date, exactly as
-- create_batch does, rather than using current_date. A test fixture that
-- reintroduced the server date would be modelling the very thing S9-P/10
-- removed, in the file set that is supposed to catch it.
--
-- NOT ONE ASSERTION CHANGES. Only the two fixture inserts and one new variable.
-- Every BS-1..BS-11 verdict, and the suite's own cleanup, are byte-identical.

create or replace function tests.batch_sets()
returns setof text language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_owner bigint; v_nag bigint; v_state text;
  v_fam bigint; v_party bigint; v_kpub bigint; v_cvpub bigint;
  v_sku bigint; v_skuv bigint; v_batch bigint; v_batch2 bigint; v_pg bigint; v_pg2 bigint;
  v_box bigint; v_plate bigint; v_plate2 bigint; v_foreign_row bigint;
  v_set bigint; v_m1 bigint; v_pdate date;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';
  -- S9-P/11a: the plant-local Pricing Date, the same rule create_batch follows
  select (now() at time zone p.timezone)::date into v_pdate
    from public.plants p where p.id = v_nag;
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

  insert into public.batches (batch_reference, family_id, plant_id, owner_user_id, created_by, pricing_date)
    values ('x', v_fam, v_nag, v_owner, v_owner, v_pdate) returning id into v_batch;
  insert into public.batches (batch_reference, family_id, plant_id, owner_user_id, created_by, pricing_date)
    values ('x', v_fam, v_nag, v_owner, v_owner, v_pdate) returning id into v_batch2;
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
  -- Even on the privileged path, where column grants do not apply, `status` is
  -- not a storable opinion: the derive trigger recomputes it from the
  -- memberships that exist. A SET asserted ACTIVE with none is stored dissolved.
  insert into public.batch_sets (batch_id, box_row_id, set_code, status, active_component_count, created_by)
  values (v_batch, v_box, 'S0', 'active', 1, v_owner);
  return next is((select status from public.batch_sets where batch_id=v_batch and set_code='S0'), 'dissolved',
    'BS-1 (§5.9) an ACTIVE SET with no components cannot be stored - the database derives status from reality');
  return next is((select active_component_count from public.batch_sets where batch_id=v_batch and set_code='S0'), 0,
    'BS-1a and the caller-supplied count of 1 is discarded, not trusted');
  delete from public.batch_sets where batch_id = v_batch and set_code = 'S0';

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
end $function$;