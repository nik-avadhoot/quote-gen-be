-- S6-5: executable proof gates for the Batch workspace structure and the §5
-- cross-table invariants. §16.2's gate for S6 is "every §5 composite FK rejects
-- its negative case" - so each one is exercised with a real negative, and the
-- SQLSTATE is asserted so a composite FK cannot be credited for a rejection some
-- other constraint produced.

create or replace function tests.batch_workspace()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['batches','batch_collaborators','batch_profile_versions',
                           'batch_edit_locks','pricing_groups','delivery_groups',
                           'batch_rows','batch_sets','batch_set_memberships',
                           'batch_calculations'];
  t text; v_state text; v_owner bigint; v_nag bigint; v_pun bigint;
  v_fam bigint; v_fam2 bigint; v_party bigint; v_party2 bigint; v_loc bigint;
  v_kprop bigint; v_kpub bigint; v_cvprop bigint; v_cvpub bigint;
  v_sku bigint; v_skuv bigint; v_sku2 bigint; v_skuv2 bigint; v_sku_pun bigint; v_skuv_pun bigint;
  v_batch bigint; v_batch2 bigint; v_pg bigint; v_pg2 bigint; v_dg bigint; v_dg2 bigint;
  v_row bigint; v_plate bigint; v_ref text; v_lineage bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';

  -- ---------------------------------------------------------- structural
  foreach t in array v_tables loop
    return next ok(
      (select c.relrowsecurity and c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t),
      format('BF-1 %s has RLS enabled AND forced', t));
    return next ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('anon','public.'||t,'DELETE')),
      format('BF-2 anon holds no privilege of any kind on %s', t));
    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid=pol.polrelid
         join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname=t and pol.polcmd='d'),
      0, format('BF-3 %s has no DELETE policy for any role', t));
    return next ok(
      not pg_catalog.has_table_privilege('authenticated','public.'||t,'DELETE'),
      format('BF-3a and authenticated holds no DELETE grant on %s', t));
  end loop;

  -- the two RPC-only tables must have no write grant at all (§7.5)
  return next ok(
    not (pg_catalog.has_table_privilege('authenticated','public.batch_edit_locks','INSERT')
      or pg_catalog.has_table_privilege('authenticated','public.batch_edit_locks','UPDATE')),
    'BF-4 batch_edit_locks is RPC-only - authenticated holds no INSERT or UPDATE grant');
  return next ok(
    not (pg_catalog.has_table_privilege('authenticated','public.batch_calculations','INSERT')
      or pg_catalog.has_table_privilege('authenticated','public.batch_calculations','UPDATE')),
    'BF-4a and so is batch_calculations');
  return next is(
    (select count(*)::int from pg_catalog.pg_policy pol
       join pg_catalog.pg_class c on c.oid=pol.polrelid
       join pg_catalog.pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='batch_profile_versions' and pol.polcmd='w'),
    0, 'BF-4b batch_profile_versions has no UPDATE policy - versions are append-only');

  return next is(
    (select count(*)::int
       from pg_catalog.pg_constraint con
       join pg_catalog.pg_class c on c.oid = con.conrelid
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname='public' and c.relname = any(v_tables) and con.contype='f'
        and not exists (
          select 1 from pg_catalog.pg_index i
           where i.indrelid = con.conrelid
             and (i.indkey::smallint[])[0:array_length(con.conkey,1)-1]
                 = (select array_agg(k) from unnest(con.conkey) k))),
    0, 'BF-5 every foreign key in Family F is index-covered, composite ones included');

  -- D-25 at the storage boundary
  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='batch_profile_versions'
        and column_name in ('waste_cbb_pct','waste_pp_pct','conv_box_rate','conv_pp_rate',
                            'margin_box_pct','margin_pp_pct')
        and (is_nullable='NO' or column_default is not null)),
    0, 'BF-6 every Batch Profile value column is nullable with NO default - blank is null (D-25/CDM-19)');

  -- ---------------------------------------------------------- fixtures
  insert into public.customer_families (name, status, created_by)
    values ('__p2 bf family', 'active', v_owner) returning id into v_fam;
  insert into public.customer_families (name, status, created_by)
    values ('__p2 bf family two', 'active', v_owner) returning id into v_fam2;
  insert into public.parties (display_name, created_by) values ('__p2 bf party', v_owner)
    returning id into v_party;
  insert into public.parties (display_name, created_by) values ('__p2 bf party two', v_owner)
    returning id into v_party2;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    values (v_party, v_fam, current_date, v_owner);
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    values (v_party2, v_fam2, current_date, v_owner);
  insert into public.customer_locations (party_id, bill_to_eligible, ship_to_eligible, created_by)
    values (v_party, true, true, v_owner) returning id into v_loc;

  insert into public.constructions (name, status, created_by)
    values ('__p2 bf proposed','proposed', v_owner) returning id into v_kprop;
  insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kprop, 1, 3, v_owner) returning id into v_cvprop;
  insert into public.constructions (name, created_by) values ('__p2 bf published', v_owner)
    returning id into v_kpub;
  insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kpub, 1, 3, v_owner) returning id into v_cvpub;
  update public.constructions set construction_code='CON-994001', status='published' where id=v_kpub;

  insert into public.skus (plant_id, party_id, created_by) values (v_nag, v_party, v_owner)
    returning id into v_sku;
  insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id, is_price_driving, created_by)
    values (v_sku, v_nag, 1, v_cvpub, true, v_owner) returning id into v_skuv;
  insert into public.skus (plant_id, party_id, created_by) values (v_nag, v_party2, v_owner)
    returning id into v_sku2;
  insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id, is_price_driving, created_by)
    values (v_sku2, v_nag, 1, v_cvpub, true, v_owner) returning id into v_skuv2;
  insert into public.skus (plant_id, party_id, created_by) values (v_pun, v_party, v_owner)
    returning id into v_sku_pun;
  insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id, is_price_driving, created_by)
    values (v_sku_pun, v_pun, 1, v_cvpub, true, v_owner) returning id into v_skuv_pun;

  insert into public.batches (batch_reference, family_id, plant_id, owner_user_id, created_by)
    values ('client-supplied', v_fam, v_nag, v_owner, v_owner) returning id, batch_reference into v_batch, v_ref;
  insert into public.batches (batch_reference, family_id, plant_id, owner_user_id, created_by)
    values ('x', v_fam, v_nag, v_owner, v_owner) returning id into v_batch2;

  -- CDM-14: the reference is the system's word
  return next ok(v_ref <> 'client-supplied',
    'BF-7 the Batch reference is allocated by the database, not accepted from the client (CDM-14)');
  return next ok(v_ref like 'NAG/BAT/%',
    format('BF-7a and carries plant, BAT and Indian FY: %s', v_ref));

  insert into public.pricing_groups (batch_id, created_by) values (v_batch, v_owner) returning id into v_pg;
  insert into public.pricing_groups (batch_id, created_by) values (v_batch2, v_owner) returning id into v_pg2;
  insert into public.delivery_groups (pricing_group_id, batch_id, created_by)
    values (v_pg, v_batch, v_owner) returning id into v_dg;
  insert into public.delivery_groups (pricing_group_id, batch_id, created_by)
    values (v_pg2, v_batch2, v_owner) returning id into v_dg2;

  -- =============================== §5 composite FKs, each with its negative
  -- §5.1 SKU plant must equal Batch plant
  begin
    insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, created_by)
    values (v_batch, v_pun, v_pg, v_sku_pun, v_skuv_pun, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'BF-8 (§5.1) a wrong-plant SKU on a Batch row is REJECTED - both FKs bind the same plant_id');

  -- §5.3 row and pricing group must share the Batch
  begin
    insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, created_by)
    values (v_batch, v_nag, v_pg2, v_sku, v_skuv, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'BF-9 (§5.3) a row in another Batch Pricing Group is REJECTED');

  -- §5.8 the version must belong to the selected SKU
  begin
    insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, created_by)
    values (v_batch, v_nag, v_pg, v_sku, v_skuv2, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'BF-10 (§5.8) a spec version belonging to another SKU is REJECTED');

  -- §5.2 the SKU Customer must belong to the Batch Family - a TRIGGER, so 23514
  begin
    insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, created_by)
    values (v_batch, v_nag, v_pg, v_sku2, v_skuv2, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'BF-11 (§5.2) a SKU whose Customer is in another Family is REJECTED, by trigger not FK');

  -- the legitimate row, at last
  insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, created_by)
  values (v_batch, v_nag, v_pg, v_sku, v_skuv, v_owner) returning id, lineage_id into v_row, v_lineage;
  return next ok(v_row is not null, 'BF-12 a well-formed row is accepted');
  return next ok(v_lineage is not null, 'BF-12a and is given a stable lineage id (CDM-22)');

  -- §5.2's whole point: reassignment afterwards must NOT break existing work
  perform app_private.reassign_party_family(v_party, v_fam2, current_date);
  return next is((select count(*)::int from public.batch_rows where id = v_row), 1,
    'BF-13 (§5.2) reassigning the Party to another Family leaves the existing row untouched (CDM-06)');
  return next is((select family_id from public.party_family_memberships
                   where party_id = v_party and is_current), v_fam2,
    'BF-13a and the reassignment itself succeeded - a composite FK would have blocked it');
  perform app_private.reassign_party_family(v_party, v_fam, current_date);

  -- §5.4 the freight basis must belong to THIS Pricing Group
  begin
    update public.pricing_groups set freight_basis_delivery_group_id = v_dg2 where id = v_pg;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'BF-14 (§5.4) a freight basis from another Pricing Group is REJECTED');

  update public.pricing_groups set freight_basis_delivery_group_id = v_dg where id = v_pg;
  return next is((select freight_basis_delivery_group_id from public.pricing_groups where id=v_pg), v_dg,
    'BF-14a but its own Delivery Group is accepted');

  -- A-11 the basis cannot be removed out from under the calculation
  begin
    delete from public.delivery_groups where id = v_dg;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'BF-15 (A-11) the Delivery Group serving as freight basis cannot be deleted');

  -- §5.7 the row Construction reference must be a PROPOSED one
  begin
    update public.batch_rows set proposed_construction_version_id = v_cvpub where id = v_row;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'BF-16 (§5.7) a PUBLISHED Construction cannot be a row proposed-Construction reference (CDM-13)');

  update public.batch_rows set proposed_construction_version_id = v_cvprop where id = v_row;
  return next is((select proposed_construction_version_id from public.batch_rows where id=v_row), v_cvprop,
    'BF-16a but a genuinely PROPOSED one is accepted');

  -- and publishing it afterwards must NOT retroactively invalidate the row
  update public.constructions set construction_code='CON-994002', status='published' where id=v_kprop;
  return next is((select proposed_construction_version_id from public.batch_rows where id=v_row), v_cvprop,
    'BF-17 (§5.7) publishing the Construction later leaves the open row pinned - a cascade would have failed here');
  update public.constructions set status='proposed', construction_code=null where id=v_kprop;

  -- lineage and identity are immutable
  begin
    update public.batch_rows set lineage_id = v_lineage + 1000 where id = v_row;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514', 'BF-18 lineage is stable across revisions and cannot be changed (CDM-22)');

  begin
    update public.batch_rows set sku_id = v_sku2 where id = v_row;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'BF-19 a row changes SKU by replacement, never by mutation (CDM-11)');

  -- ------------------------------------------------------------- cleanup
  delete from public.batch_calculations where batch_id in (v_batch, v_batch2);
  delete from public.batch_set_memberships where batch_id in (v_batch, v_batch2);
  delete from public.batch_sets where batch_id in (v_batch, v_batch2);
  delete from public.batch_rows where batch_id in (v_batch, v_batch2);
  update public.pricing_groups set freight_basis_delivery_group_id = null
   where batch_id in (v_batch, v_batch2);
  delete from public.delivery_groups where batch_id in (v_batch, v_batch2);
  delete from public.pricing_groups where batch_id in (v_batch, v_batch2);
  delete from public.batch_profile_versions where batch_id in (v_batch, v_batch2);
  delete from public.batch_edit_locks where batch_id in (v_batch, v_batch2);
  delete from public.batches where id in (v_batch, v_batch2);
  delete from public.sku_versions where sku_id in (v_sku, v_sku2, v_sku_pun);
  delete from public.skus where id in (v_sku, v_sku2, v_sku_pun);
  delete from public.construction_versions where construction_id in (v_kprop, v_kpub);
  delete from public.constructions where id in (v_kprop, v_kpub);
  delete from public.customer_locations where party_id in (v_party, v_party2);
  delete from public.party_family_memberships where party_id in (v_party, v_party2);
  delete from public.parties where id in (v_party, v_party2);
  delete from public.customer_families where id in (v_fam, v_fam2);
end $fn$;

revoke all on function tests.batch_workspace() from public, anon, authenticated;