-- S4-2 fix: PS-28 wrote status='inactive', but ck_app_users_status admits only
-- 'invited', 'active' and 'deactivated'. The assertion was right and the literal
-- was wrong. Corrected here, and tests.sku_master() is registered in run_all()
-- in the same change so the suite and its registration never ship apart.

create or replace function tests.sku_master()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['skus','sku_versions','sku_external_references',
                           'sku_location_applicabilities'];
  t text; v_ok boolean;
  v_auth uuid; v_claims text; v_uid bigint; v_owner bigint;
  v_email text := 'p2-s4s@example.invalid';
  v_nag bigint; v_pun bigint;
  v_party bigint; v_other_party bigint; v_loc bigint; v_other_loc bigint;
  v_kprop bigint; v_kpub bigint; v_vprop bigint; v_vpub bigint;
  v_sku bigint; v_sku2 bigint; v_ver bigint; v_seen int;
begin
  -- ---------------------------------------------------------- structural gates
  foreach t in array v_tables loop
    return next ok(
      (select c.relrowsecurity and c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = t),
      format('PS-1 %s has RLS enabled AND forced', t));
    return next ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('anon','public.'||t,'DELETE')),
      format('PS-2 anon holds no privilege of any kind on %s', t));
    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t and pol.polcmd='d'),
      0, format('PS-3 %s has no DELETE policy for any role', t));
    return next ok(
      not pg_catalog.has_table_privilege('authenticated','public.'||t,'DELETE'),
      format('PS-3a and authenticated holds no DELETE grant on %s', t));
  end loop;

  return next is(
    (select coalesce(max(cnt),0)::int from (
       select count(*) cnt from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname = any(v_tables)
        group by c.relname, pol.polcmd) q),
    1, 'PS-4 exactly one permissive policy per SKU table and action');

  -- every foreign key, single or composite, is covered by an index whose leading
  -- columns are the key columns in order (advisor 0001)
  return next is(
    (select count(*)::int
       from pg_catalog.pg_constraint con
       join pg_catalog.pg_class c on c.oid = con.conrelid
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = any(v_tables) and con.contype = 'f'
        and not exists (
          select 1 from pg_catalog.pg_index i
           where i.indrelid = con.conrelid
             and (i.indkey::smallint[])[0:array_length(con.conkey,1)-1]
                 = (select array_agg(k) from unnest(con.conkey) k))),
    0, 'PS-5 every foreign key on a SKU table is index-covered, composite ones included');

  -- CDM-13 as structure: a spec version cannot exist without a Construction
  return next is(
    (select is_nullable from information_schema.columns
      where table_schema='public' and table_name='sku_versions'
        and column_name='construction_version_id'),
    'NO', 'PS-13 sku_versions.construction_version_id is NOT NULL - one authority, always');

  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='sku_versions'
        and (column_name ~* 'wast' or column_name ~* 'conv')),
    0, 'PS-13a and no waste or conversion column leaked onto sku_versions either');

  -- --------------------------------------------------------------- fixtures
  select id into v_owner from public.app_users order by id limit 1;
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';

  insert into public.parties (display_name, created_by) values ('__p2 ps customer', v_owner)
    returning id into v_party;
  insert into public.parties (display_name, created_by) values ('__p2 ps other', v_owner)
    returning id into v_other_party;
  insert into public.customer_locations (party_id, bill_to_eligible, ship_to_eligible, created_by)
    values (v_party, true, true, v_owner) returning id into v_loc;
  insert into public.customer_locations (party_id, bill_to_eligible, ship_to_eligible, created_by)
    values (v_other_party, true, true, v_owner) returning id into v_other_loc;

  -- one PROPOSED Construction and one PUBLISHED Construction, each with a version
  insert into public.constructions (name, created_by) values ('__p2 ps proposed con', v_owner)
    returning id into v_kprop;
  insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kprop, 1, 3, v_owner) returning id into v_vprop;
  insert into public.constructions (name, created_by) values ('__p2 ps published con', v_owner)
    returning id into v_kpub;
  insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kpub, 1, 5, v_owner) returning id into v_vpub;
  update public.constructions set construction_code = 'CON-998001', status = 'published'
   where id = v_kpub;

  -- ------------------------------- PS-15: the CDM-13 discriminator, proved now
  -- This is the exact predicate S6's batch_rows trigger will evaluate. It is
  -- asserted here against real rows so the rule is demonstrated in S4 rather than
  -- merely promised for S6.
  return next ok(
    exists (select 1 from public.construction_versions cv
              join public.constructions k on k.id = cv.construction_id
             where cv.id = v_vprop and k.status = 'proposed'),
    'PS-15 a Quote-specific PROPOSED Construction is identifiable as proposable (CDM-13)');
  return next ok(
    not exists (select 1 from public.construction_versions cv
                  join public.constructions k on k.id = cv.construction_id
                 where cv.id = v_vpub and k.status = 'proposed'),
    'PS-15a and a PUBLISHED Construction is not - so the SKU spec version is sole authority');

  -- --------------------------------------------------------- SKU constraints
  insert into public.skus (plant_id, party_id, created_by) values (v_nag, v_party, v_owner)
    returning id into v_sku;

  begin
    update public.skus set replacement_sku_id = v_sku where id = v_sku;
    return next fail('PS-12 a SKU must not replace itself');
  exception when others then
    return next ok(true, 'PS-12 self-replacement rejected ('||sqlstate||')');
  end;

  -- CDM-09: optional until assigned, and multiple nulls must coexist
  insert into public.skus (plant_id, party_id, created_by) values (v_nag, v_party, v_owner)
    returning id into v_sku2;
  return next is((select count(*)::int from public.skus
                   where party_id = v_party and plant_item_code is null), 2,
                 'PS-10 several SKUs may sit at one plant with NO Plant Item Code (CDM-09)');

  update public.skus set plant_item_code = 'NAGPI-0001', status = 'active' where id = v_sku;
  begin
    update public.skus set plant_item_code = 'NAGPI-0001' where id = v_sku2;
    return next fail('PS-9 Plant Item Code must be unique within its plant');
  exception when others then
    return next ok(true, 'PS-9 Plant Item Code is unique within the plant ('||sqlstate||')');
  end;

  -- the same string at a DIFFERENT plant is a different SKU and must be allowed
  insert into public.skus (plant_id, party_id, plant_item_code, created_by)
  values (v_pun, v_party, 'NAGPI-0001', v_owner);
  return next is((select count(*)::int from public.skus where plant_item_code = 'NAGPI-0001'), 2,
                 'PS-9a but the same code at another plant is a different SKU (CDM-09)');

  begin
    update public.skus set plant_item_code = 'NAGPI-0002' where id = v_sku;
    return next fail('PS-20 an assigned Plant Item Code must be permanent');
  exception when others then
    return next ok(true, 'PS-20 an assigned Plant Item Code is permanent ('||sqlstate||')');
  end;

  -- CDM-11 lifecycle, exhaustive
  begin
    update public.skus set status = 'proposed' where id = v_sku;
    return next fail('PS-21 active -> proposed must be rejected');
  exception when others then
    return next ok(true, 'PS-21 the SKU lifecycle is exhaustive ('||sqlstate||')');
  end;
  update public.skus set status = 'discontinued' where id = v_sku;
  update public.skus set status = 'active'       where id = v_sku;
  return next is((select count(*)::int from public.skus where id = v_sku), 1,
                 'PS-21a reactivation returns the SAME row to active - identity preserved (CDM-11)');

  -- ------------------------------------------------------ sku_versions rules
  begin
    insert into public.sku_versions (sku_id, plant_id, version_no, is_price_driving, created_by)
    values (v_sku, v_nag, 1, true, v_owner);
    return next fail('PS-14 a spec version without a Construction must be rejected');
  exception when others then
    return next ok(true, 'PS-14 a spec version with no Construction authority is impossible ('||sqlstate||')');
  end;

  insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id,
                                   is_price_driving, created_by)
  values (v_sku, v_nag, 1, v_vpub, true, v_owner) returning id into v_ver;

  -- PS-18: the composite FK refuses a child under the wrong plant
  begin
    insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id,
                                     is_price_driving, created_by)
    values (v_sku, v_pun, 2, v_vpub, true, v_owner);
    return next fail('PS-18 a child row under the wrong plant must be rejected');
  exception when others then
    return next ok(true, 'PS-18 a SKU child cannot be written under a plant its parent does not belong to ('||sqlstate||')');
  end;

  -- PS-19: with a child present, the composite FK pins the parent's plant
  begin
    update public.skus set plant_id = v_pun where id = v_sku;
    return next fail('PS-19 plant_id must be pinned once a child row exists');
  exception when others then
    return next ok(true, 'PS-19 the composite FK pins skus.plant_id once any child exists ('||sqlstate||')');
  end;

  update public.sku_versions set spec_bct = 12.50 where id = v_ver;
  return next is((select spec_bct from public.sku_versions where id = v_ver), 12.50,
                 'PS-16 an UNapproved spec version is editable');
  update public.sku_versions set approved_by = v_owner, approved_at = now() where id = v_ver;
  begin
    update public.sku_versions set spec_bct = 13.00 where id = v_ver;
    return next fail('PS-17 an approved SKU spec version must not be editable');
  exception when others then
    return next ok(true, 'PS-17 approved SKU spec version is immutable, as the table owner ('||sqlstate||')');
  end;

  -- ------------------------------- PS-26: cross-Family reach closed by the FK
  insert into public.sku_location_applicabilities
    (sku_id, plant_id, party_id, location_id, scope, created_by)
  values (v_sku, v_nag, v_party, v_loc, 'master', v_owner);
  return next ok(true, 'PS-25 a SKU may be made applicable at its own Customer''s Location');

  begin
    insert into public.sku_location_applicabilities
      (sku_id, plant_id, party_id, location_id, scope, created_by)
    values (v_sku, v_nag, v_other_party, v_other_loc, 'master', v_owner);
    return next fail('PS-26 a SKU must not reach another Customer''s Location');
  exception when others then
    return next ok(true, 'PS-26 a third party''s Location is unreachable - (sku,party) and (location,party) bind one column ('||sqlstate||')');
  end;

  -- CDM-10: aliases are deliberately not unique
  insert into public.sku_external_references (sku_id, plant_id, reference_kind, reference_value, created_by)
  values (v_sku, v_nag, 'customer_item_code', 'CUST-XYZ', v_owner);
  insert into public.sku_external_references (sku_id, plant_id, reference_kind, reference_value, created_by)
  values (v_sku2, v_nag, 'customer_item_code', 'CUST-XYZ', v_owner);
  return next is((select count(*)::int from public.sku_external_references
                   where reference_value = 'CUST-XYZ'), 2,
                 'PS-23 external references are non-authoritative and deliberately not unique (CDM-10)');

  -- ------------------------------------------------------------- personas
  v_auth   := tests.__fixture_auth_uid();
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_s4s_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_uid := public.bootstrap_app_user();
  reset role;

  -- Maker at NAG only
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_uid, v_nag, c.id, v_uid from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);

  set local role authenticated;
  select count(*) into v_seen from public.skus where plant_id = v_nag;
  reset role;
  return next ok(v_seen > 0, 'PS-6 a Maker sees the SKUs of the plant they are granted at');

  set local role authenticated;
  select count(*) into v_seen from public.skus where plant_id = v_pun;
  reset role;
  return next is(v_seen, 0,
    'PS-6a and ZERO at PUN - a wrong-plant SKU is invisible, not merely filtered by the UI');

  set local role authenticated;
  begin
    insert into public.skus (plant_id, party_id, status, created_by)
    values (v_pun, v_party, 'proposed', v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok,
    'PS-7 and naming PUN explicitly is refused - the predicate reads the row own plant_id');

  set local role authenticated;
  begin
    insert into public.skus (plant_id, party_id, status, created_by)
    values (v_nag, v_party, 'proposed', v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(v_ok, 'PS-8 a Maker MAY propose a SKU at their own plant (CDM-11/DM-132)');

  set local role authenticated;
  begin
    insert into public.skus (plant_id, party_id, status, plant_item_code, created_by)
    values (v_nag, v_party, 'proposed', 'NAGPI-9999', v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok,
    'PS-11 but never with a Plant Item Code - no pseudo-code is manufactured (CDM-09/DM-132)');

  set local role authenticated;
  begin
    update public.skus set status = 'discontinued' where id = v_sku;
    v_ok := (select status from public.skus where id = v_sku) = 'discontinued';
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PS-22 a Maker holds no manage_sku_master and cannot change SKU status');

  set local role authenticated;
  begin
    insert into public.sku_external_references (sku_id, plant_id, reference_kind, reference_value, created_by)
    values (v_sku, v_nag, 'alias', '__p2 ps maker alias', v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PS-24 and cannot write master aliases - there is no proposal route there');

  -- CDM-11: the batch_only route, and only that route
  set local role authenticated;
  begin
    insert into public.sku_location_applicabilities
      (sku_id, plant_id, party_id, location_id, scope, status, created_by)
    values (v_sku, v_nag, v_party, v_loc, 'batch_only', 'proposed', v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(v_ok, 'PS-27 a Maker MAY add a batch_only applicability - it authorises the Quote, not the master (CDM-11)');

  set local role authenticated;
  begin
    insert into public.sku_location_applicabilities
      (sku_id, plant_id, party_id, location_id, scope, status, created_by)
    values (v_sku2, v_nag, v_party, v_loc, 'master', 'approved', v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PS-27a but not a master applicability - publication stays an NPD/Admin act');

  -- CDM-05: deactivation stops access on the next query, unexpired JWT included.
  -- The literal is 'deactivated' - ck_app_users_status admits no 'inactive'.
  update public.app_users set status = 'deactivated' where id = v_uid;
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  select count(*) into v_seen from public.skus;
  reset role;
  return next is(v_seen, 0,
    'PS-28 a DEACTIVATED user sees nothing, even holding a still-valid token (CDM-05)');
  update public.app_users set status = 'active' where id = v_uid;

  -- ------------------------------------------------------------- cleanup
  delete from public.sku_location_applicabilities
   where sku_id in (select id from public.skus where party_id in (v_party, v_other_party));
  delete from public.sku_external_references
   where sku_id in (select id from public.skus where party_id in (v_party, v_other_party));
  delete from public.sku_versions
   where sku_id in (select id from public.skus where party_id in (v_party, v_other_party));
  delete from public.skus where party_id in (v_party, v_other_party);
  delete from public.construction_versions where construction_id in (v_kprop, v_kpub);
  delete from public.constructions where id in (v_kprop, v_kpub);
  delete from public.customer_locations where party_id in (v_party, v_other_party);
  delete from public.parties where id in (v_party, v_other_party);
  delete from public.plant_capability_grants where app_user_id = v_uid;
  delete from public.group_capability_grants where app_user_id = v_uid;
  delete from public.operational_settings where created_by = v_uid;
  delete from app_private.pending_invitations where invite_email = v_email;
  delete from public.app_users where id = v_uid;
  perform tests.__drop_synthetic_auth(v_auth);
end $fn$;

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
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from finish();
end $fn$;

drop function if exists tests.__probe_sku();