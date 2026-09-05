-- S4-3 fix: the workflow fixture tore down by nulling surviving_construction_id,
-- which ck_construction_merged_has_survivor refuses - a merged Construction
-- without its survivor is exactly the state that constraint exists to forbid.
--
-- The teardown now deletes in lineage order instead: rows that POINT at a
-- survivor go first, then the survivors, so the self-referencing restrict FK is
-- satisfied at every step and no constraint is loosened to make cleanup easy.
-- Only the cleanup block changes; every assertion is untouched.

create or replace function tests.product_workflow()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  fns text[] := array['propose_construction','approve_construction_version',
                      'publish_construction','merge_construction',
                      'adopt_construction_for_plant','propose_sku',
                      'approve_sku_version','assign_plant_item_code','set_sku_status'];
  f text; v_ok boolean;
  v_mauth uuid; v_mclaims text; v_maker bigint; v_memail text := 'p2-s4w-m@example.invalid';
  v_nauth uuid; v_nclaims text; v_npd   bigint; v_nemail text := 'p2-s4w-n@example.invalid';
  v_owner bigint; v_nag bigint; v_pun bigint; v_party bigint;
  v_k1 bigint; v_k2 bigint; v_kdup bigint;
  v_v1 bigint; v_v2 bigint; v_vdup bigint;
  v_code1 text; v_code2 text; v_adopt bigint;
  v_sku bigint; v_sver bigint;
begin
  select id into v_owner from public.app_users order by id limit 1;
  select id into v_nag   from public.plants where plant_code = 'NAG';
  select id into v_pun   from public.plants where plant_code = 'PUN';

  -- ------------------------------------------------ anon reaches none of them
  foreach f in array fns loop
    return next ok(
      not exists (select 1 from pg_catalog.pg_proc p
                    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = f
                     and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')),
      format('PW-1 anon cannot execute public.%s', f));
    return next ok(
      exists (select 1 from pg_catalog.pg_proc p
                join pg_catalog.pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app_private' and p.proname = f and p.prosecdef),
      format('PW-1a the privilege for %s lives in app_private as SECURITY DEFINER', f));
    return next ok(
      exists (select 1 from pg_catalog.pg_proc p
                join pg_catalog.pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = f and not p.prosecdef),
      format('PW-1b and public.%s is a SECURITY INVOKER shim that decides nothing', f));
  end loop;

  -- ------------------------------------------------------------- identities
  v_mauth   := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_memail, '__p2_s4w_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_maker := public.bootstrap_app_user();
  reset role;

  v_nauth   := tests.__fixture_auth_uid();
  v_nclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_nauth, v_nemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_nemail, '__p2_s4w_npd', false);
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_npd := public.bootstrap_app_user();
  reset role;

  -- Maker: make_quote + plant_access at NAG only. No group capability at all.
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');

  -- NPD: the master capabilities, group-wide library plus NAG plant authority
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_npd, c.id, v_owner from public.capabilities c
   where c.capability_key in ('read_construction_library','manage_construction_library');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_npd, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','manage_sku_master','adopt_construction_for_plant');

  insert into public.parties (display_name, created_by) values ('__p2 pw customer', v_owner)
    returning id into v_party;

  -- ------------------------------------------------- proposal, by the Maker
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_k1 := public.propose_construction('__p2 pw con one', 3, 'B', null,
                                      'K', 'S', 'S', null, 'K',
                                      150, 120, 120, null, 150, 540);
  reset role;
  return next ok(v_k1 is not null, 'PW-2 a Maker may propose a Construction from Batch Entry (CDM-12/DM-144)');
  return next is((select status from public.constructions where id = v_k1), 'proposed',
                 'PW-2a it is born proposed');
  return next ok((select construction_code is null from public.constructions where id = v_k1),
                 'PW-2b and carries NO permanent code - publication allocates that');
  return next is((select created_by from public.constructions where id = v_k1), v_maker,
                 'PW-2c attribution is the caller, taken from current_app_user() (CDM-34)');
  select id into v_v1 from public.construction_versions where construction_id = v_k1;
  return next ok(v_v1 is not null, 'PW-2d version 1 is written in the same operation');

  -- ------------------------------------------- the Maker may do nothing more
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.approve_construction_version(v_v1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-3 a Maker may NOT approve a Construction Version');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.publish_construction(v_k1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-4 nor publish one - publication is a library capability (CDM-12)');

  -- ------------------------------------------- review and publication, by NPD
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.approve_construction_version(v_v1);
  reset role;
  return next is((select approved_by from public.construction_versions where id = v_v1), v_npd,
                 'PW-5 approval records the approver, never a client-supplied value (CDM-34)');
  return next ok((select approved_at is not null from public.construction_versions where id = v_v1),
                 'PW-5a and its timestamp - ck_cv_approval_pair makes them inseparable');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.approve_construction_version(v_v1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-6 an already-approved version cannot be approved again');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_code1 := public.publish_construction(v_k1);
  reset role;
  return next ok(v_code1 ~ '^CON-[0-9]{6}$',
                 'PW-7 publication allocates a neutral permanent sequence code: ' || v_code1);
  return next is((select status from public.constructions where id = v_k1), 'published',
                 'PW-7a and moves the Construction to published');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.publish_construction(v_k1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-8 republishing is refused - published is terminal');
  return next is((select construction_code from public.constructions where id = v_k1), v_code1,
                 'PW-8a and the permanent code is unchanged (CDM-03)');

  -- a second publication must take a DIFFERENT code, never a reused one
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_k2 := public.propose_construction('__p2 pw con two', 5);
  select id into v_v2 from public.construction_versions where construction_id = v_k2;
  perform public.approve_construction_version(v_v2);
  v_code2 := public.publish_construction(v_k2);
  reset role;
  return next ok(v_code2 <> v_code1,
                 'PW-9 a second publication takes a different code - references are never reused (CDM-03)');
  return next ok(v_code2 > v_code1, 'PW-9a allocated from the accepted ref_private sequence, not a max()');

  -- ------------------------------------------------------ adoption, CDM-12
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.adopt_construction_for_plant(v_nag, v_v1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-10 a Maker holds no adopt_construction_for_plant and cannot adopt');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.adopt_construction_for_plant(v_pun, v_v1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-11 and NPD granted only at NAG cannot adopt for PUN - cross-plant isolation');

  -- an unpublished / unapproved Construction is not adoptable: formal use only
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_kdup := public.propose_construction('__p2 pw con dup', 3);
  select id into v_vdup from public.construction_versions where construction_id = v_kdup;
  begin
    perform public.adopt_construction_for_plant(v_nag, v_vdup); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok,
    'PW-12 an unpublished, unapproved Construction cannot be adopted - formal use requires both (CDM-12)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  v_adopt := public.adopt_construction_for_plant(v_nag, v_v1);
  reset role;
  return next ok(v_adopt is not null, 'PW-13 an approved version of a published Construction IS adoptable at the granted plant');
  return next is((select adopted_by from public.plant_construction_adoptions where id = v_adopt), v_npd,
                 'PW-13a with the adopter recorded from the session, not from a parameter');

  -- ------------------------------------------------------------ merge, CDM-12
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.merge_construction(v_kdup, v_kdup); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-14 a Construction cannot merge into itself');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.merge_construction(v_kdup, v_k1);
  reset role;
  return next is((select status from public.constructions where id = v_kdup), 'merged',
                 'PW-15 a duplicate proposal merges into the existing Construction');
  return next is((select surviving_construction_id from public.constructions where id = v_kdup), v_k1,
                 'PW-15a with lineage retained - the merged row survives and points at its survivor (CDM-12)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.merge_construction(v_k2, v_kdup); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-16 lineage must not chain into an already-merged row');

  -- ------------------------------------------------------------- SKU workflow
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_sku := public.propose_sku(v_nag, v_party, v_v1, true, 300, 200, 150);
  reset role;
  return next ok(v_sku is not null, 'PW-17 a Maker may propose a SKU at their own plant (CDM-11)');
  return next is((select status from public.skus where id = v_sku), 'proposed',
                 'PW-17a born proposed');
  return next ok((select plant_item_code is null from public.skus where id = v_sku),
                 'PW-17b with NO Plant Item Code - no pseudo-code is manufactured (DM-132)');
  select id into v_sver from public.sku_versions where sku_id = v_sku;
  return next is((select construction_version_id from public.sku_versions where id = v_sver), v_v1,
                 'PW-17c and its spec version carries exactly one Construction authority (CDM-13)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.propose_sku(v_pun, v_party, v_v1); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-18 but not at PUN - a wrong-plant proposal is refused (CDM-35)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.propose_sku(v_nag, v_party, null); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-19 and a SKU with no Construction authority is impossible (CDM-13)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.assign_plant_item_code(v_sku, 'NAGPW-0001'); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok,
    'PW-20 code assignment and activation are Admin/NPD acts, not Maker acts (CDM-11)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.assign_plant_item_code(v_sku, 'NAGPW-0001');
  reset role;
  return next is((select plant_item_code from public.skus where id = v_sku), 'NAGPW-0001',
                 'PW-21 NPD assigns the permanent Plant Item Code');
  return next is((select status from public.skus where id = v_sku), 'active',
                 'PW-21a and activation happens with it');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.assign_plant_item_code(v_sku, 'NAGPW-0002'); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-22 a second assignment is refused - the code is permanent (CDM-09)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.approve_sku_version(v_sver);
  reset role;
  return next is((select approved_by from public.sku_versions where id = v_sver), v_npd,
                 'PW-23 spec-version approval records the approver from the session');

  begin
    update public.sku_versions set spec_bct = 99.9 where id = v_sver;
    return next fail('PW-24 an approved spec version must be immutable');
  exception when others then
    return next ok(true, 'PW-24 and freezes the version against every role thereafter ('||sqlstate||')');
  end;

  -- CDM-11 lifecycle through the RPC, including the illegal transition
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  begin
    perform public.set_sku_status(v_sku, 'proposed'); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-25 active -> proposed is refused by the transition matrix (CDM-11)');

  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated;
  perform public.set_sku_status(v_sku, 'discontinued');
  perform public.set_sku_status(v_sku, 'active');
  reset role;
  return next is((select plant_item_code from public.skus where id = v_sku), 'NAGPW-0001',
                 'PW-26 reactivation preserves identity and the permanent code (CDM-11)');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.set_sku_status(v_sku, 'discontinued'); v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'PW-27 a Maker cannot drive the SKU lifecycle through the RPC either');

  -- ------------------------------------------------------------- cleanup
  -- Lineage order, not lineage erasure: a merged Construction may never be left
  -- without its survivor, so the rows that POINT at one are removed first.
  delete from public.plant_construction_adoptions
   where construction_version_id in (
     select cv.id from public.construction_versions cv
      join public.constructions k on k.id = cv.construction_id
     where k.name like '\_\_p2 pw%');
  delete from public.sku_location_applicabilities where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.sku_external_references     where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.sku_versions                where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.skus where party_id = v_party;
  delete from public.construction_versions
   where construction_id in (select id from public.constructions where name like '\_\_p2 pw%');
  delete from public.constructions
   where name like '\_\_p2 pw%' and surviving_construction_id is not null;
  delete from public.constructions where name like '\_\_p2 pw%';
  delete from public.customer_locations where party_id = v_party;
  delete from public.parties where id = v_party;
  delete from public.plant_capability_grants where app_user_id in (v_maker, v_npd);
  delete from public.group_capability_grants where app_user_id in (v_maker, v_npd);
  delete from public.operational_settings     where created_by  in (v_maker, v_npd);
  delete from app_private.pending_invitations where invite_email in (v_memail, v_nemail);
  delete from public.app_users where id in (v_maker, v_npd);
  perform tests.__drop_synthetic_auth(v_mauth);
  perform tests.__drop_synthetic_auth(v_nauth);
end $fn$;