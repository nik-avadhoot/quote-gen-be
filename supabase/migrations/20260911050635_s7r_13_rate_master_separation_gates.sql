-- S7-R/13: gates for the supplier-credit correction - CP-117 and CP-118.
--
-- CP-117 proves the correction's positive claim: a five-ply board whose five
-- grades carry FIVE DIFFERENT supplier-credit terms upstream (1.5, 2.0, none, 0,
-- 3.0) is eligible and calculates, because those terms were settled inside the
-- Rate Master and Calculate never re-selects them. It also pins what is kept:
-- the governed Rate Set Version and each layer's governed rate entry, by exact
-- identity, in provenance.
--
-- CP-118 proves the separation: customer payment-term interest still moves the
-- Batch calculation through its OWN resolved chain - no terms -> the versioned
-- 0.5 fallback; 60 days -> 6.000% x 60 / 360 = 1.000 derived - and the
-- fingerprint moves with it, while the resolver that produces it reads no rate
-- entry and no Rate Set Version at all.
--
-- THE GATES LIVE IN THEIR OWN __ HELPER, called from __s7r_body with the fixture
-- it already built. That keeps the new assertions in ordinarily-quoted SQL
-- rather than inside a doubly-escaped splice, and the __ prefix keeps it out of
-- tests.suite_registration(), exactly like the other fixture helpers.
--
-- TWO SPLICES INTO __s7r_body, counts asserted: the five rate entries go into the
-- fixture while the Rate Set Version is still DRAFT (trg_re_follows_version
-- refuses them after approval, as it does freight entries - S7-R/9c), and the
-- helper is called after the D-X arm. The teardown is restated in full so it
-- also removes the second Construction.
--
-- PREDICTED DELTA, stated before running: +17 assertions (78 -> 95 focused).

create or replace function tests.__s7r_rate_master_gates(
  p_owner bigint, p_kol bigint, p_party bigint, p_batch bigint, p_pg bigint,
  p_rsv bigint, p_rel bigint, p_oauth uuid, p_other bigint, p_oclaims text)
returns setof text language plpgsql set search_path = 'extensions', 'pg_catalog' as $fn$
declare
  c_key constant bytea := decode(repeat('ab',32),'hex');
  v_con5 bigint; v_cv5 bigint; v_sku3 bigint; v_skuv3 bigint; v_row4 bigint; v_cvn int;
  v_in jsonb; v_fp_a text; v_fp_b text; v_res text; v_att text; v_id bigint; v_state text;
  v_cfp text; v_pfp text;
begin
  -- ── a five-ply board: five grades, five different supplier-credit terms upstream ──
  insert into public.constructions (name,created_by) values ('__p2 s7r con5',p_owner) returning id into v_con5;
  insert into public.construction_versions (construction_id,version_no,ply,created_by,
      layer_top_code,layer_top_gsm,layer_f1_code,layer_f1_gsm,layer_l1_code,layer_l1_gsm,
      layer_f2_code,layer_f2_gsm,layer_l2_code,layer_l2_gsm)
    values (v_con5,1,5,p_owner,'K150',150,'SF100',100,'K120',120,'SF120',120,'K200',200)
    returning id into v_cv5;
  update public.constructions set construction_code='CON-996102', status='published' where id=v_con5;
  insert into public.plant_construction_adoptions (plant_id,construction_version_id,status,adopted_by,adopted_at)
    values (p_kol,v_cv5,'adopted',p_owner,now());
  insert into public.skus (plant_id,party_id,created_by) values (p_kol,p_party,p_owner) returning id into v_sku3;
  update public.skus set status='active', plant_item_code='PIC-S7R-3' where id=v_sku3;
  insert into public.sku_versions (sku_id,plant_id,version_no,construction_version_id,is_price_driving,
      created_by,length_mm,width_mm,height_mm,box_type,ups)
    values (v_sku3,p_kol,1,v_cv5,true,p_owner,400,300,250,'RSC',1) returning id into v_skuv3;
  update public.sku_versions set approved_at=now(), approved_by=p_owner where id=v_skuv3;

  return next is(
    (select count(distinct coalesce(re.interest_pct, -1))::int from public.rate_entries re
      where re.rate_set_version_id = p_rsv
        and re.grade_code in ('K150','SF100','K120','SF120','K200')), 5,
    'CP-117 pre-condition: the five grades carry FIVE DIFFERENT supplier-credit terms in the governed Rate Set Version (1.5, 2.0, none, 0, 3.0)');

  -- The Checker still holds the lock from the D-X arm; hand it back to a Maker.
  update public.batch_edit_locks set released_at = now() where batch_id = p_batch and released_at is null;
  perform set_config('request.jwt.claims', p_oclaims, true);
  set local role authenticated;
  perform public.acquire_batch_lock(p_batch);
  insert into public.batch_rows (batch_id,plant_id,pricing_group_id,sku_id,sku_version_id,row_type,created_by)
    values (p_batch,p_kol,p_pg,v_sku3,v_skuv3,'box',p_other) returning id into v_row4;
  reset role;

  begin perform app_private.assert_calculate_eligible(v_row4); v_state := 'ELIGIBLE';
  exception when others then v_state := sqlerrm; end;
  return next is(v_state, 'ELIGIBLE',
    'CP-117a the five-grade board is ELIGIBLE - no grade-selection rule and no ambiguity refusal: its five terms were settled inside the Rate Master');

  v_in := app_private.build_effective_inputs(v_row4);
  return next ok(not (v_in->'resolved' ? 'supplier_credit'),
    'CP-117b resolved carries no supplier_credit chain');
  return next is((select array_agg(k order by k) from jsonb_object_keys(v_in->'resolved') k),
                 array['conv','freight','interest','margin','waste'],
    'CP-117c resolved is exactly the five Batch-costing chains');
  return next ok(v_in::text not like '%supplier_credit%',
    'CP-117d no key anywhere in effective_inputs carries a supplier-credit term');
  return next is((v_in->'provenance'->>'rate_set_version_id')::bigint, p_rsv,
    'CP-117e the governed Rate Set Version stays in provenance');
  return next is((select count(*)::int from jsonb_each(v_in->'provenance'->'layer_rate_entries') x
                   where jsonb_typeof(x.value) = 'number'), 5,
    'CP-117f and each of the five layers names its governed rate entry');
  return next ok((select bool_and((v_in->'provenance'->'layer_rate_entries'->>x.k)::bigint = re.id)
                    from (values ('TOP','K150'),('F1','SF100'),('L1','K120'),('F2','SF120'),('L2','K200')) x(k, g)
                    join public.rate_entries re on re.rate_set_version_id = p_rsv and re.grade_code = x.g),
    'CP-117g by exact identity - (rate_set_version_id, grade_code) is unique, so this is a lookup, not a selection');

  v_res := '{"contract_version":1,"engine":{"deckle":1,"cutting":1,"area":1,"wt":1.5,"wt_sheet":1,'
        || '"mat":60,"conv":1,"fr":1,"add_ons":0,"int_c":1,"total":1,"final_rate":1,"margin_amt":1,'
        || '"moq_kg":1,"estimated_box_wt":1,"calc_moq":1,"calc_bs":1,"calc_gsm":1,"rate_per_kg":1,'
        || '"fr_rate":3.75},"row_details":['
        || '{"k":"TOP","wt":0.3,"ws":0.3,"cost":12,"rate":40,"code":"K150","gsm":150,"tu":1},'
        || '{"k":"F1","wt":0.3,"ws":0.3,"cost":12,"rate":40,"code":"SF100","gsm":100,"tu":1},'
        || '{"k":"L1","wt":0.3,"ws":0.3,"cost":12,"rate":40,"code":"K120","gsm":120,"tu":1},'
        || '{"k":"F2","wt":0.3,"ws":0.3,"cost":12,"rate":40,"code":"SF120","gsm":120,"tu":1},'
        || '{"k":"L2","wt":0.3,"ws":0.3,"cost":12,"rate":40,"code":"K200","gsm":200,"tu":1}]}';
  select content_version into v_cvn from public.batch_rows where id = v_row4;
  v_cfp := app_private.calculation_fingerprint(v_row4);
  v_pfp := app_private.presentation_fingerprint(v_row4);
  v_att := tests.__s7r_sign('t1', c_key, p_oauth::text, p_other, p_batch, v_row4, v_cvn,
             p_rel, 'engine/2026.09-a', v_cfp, v_pfp, v_res,
             now() - interval '1 second', now() + interval '60 seconds');
  set local role authenticated;
  begin v_id := public.calculate_batch_row(v_row4, v_cvn, v_res, v_att); v_state := 'WROTE';
  exception when others then v_state := sqlerrm; end;
  reset role;
  return next is(v_state, 'WROTE',
    'CP-117h and the five-grade board CALCULATES through the trusted path - its per-layer rates travel in the attested results');
  return next ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                              where n.nspname='app_private' and p.proname='resolve_row_supplier_credit'),
    'CP-117i the one-slot supplier-credit resolver no longer exists');
  return next ok((select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                   where n.nspname='app_private' and p.proname='assert_calculate_eligible') not like '%supplier%',
    'CP-117j and Calculate eligibility carries no supplier-credit refusal');

  -- ── separation: customer payment-term interest is its own chain ──
  v_fp_a := app_private.calculation_fingerprint(v_row4);
  return next is(v_in->'resolved'->'interest'->>'source', 'system',
    'CP-118 customer interest resolves through its OWN chain - with no payment terms it takes the versioned fallback, whatever the rate entries carry');
  return next is((v_in->'resolved'->'interest'->>'value')::numeric, 0.5,
    'CP-118a the 0.5 fallback from the Calculation Defaults version - not any of the five supplier-credit terms');
  update public.pricing_groups set payment_terms_days = 60 where id = p_pg;
  v_in := app_private.build_effective_inputs(v_row4);
  v_fp_b := app_private.calculation_fingerprint(v_row4);
  return next is(v_in->'resolved'->'interest'->>'source', 'derived_annual',
    'CP-118b 60-day payment terms move customer interest to derived_annual');
  return next is((v_in->'resolved'->'interest'->>'value')::numeric, 1.0,
    'CP-118c 6.000% x 60 / 360 = 1.000 - derived from the Pricing Group terms and the annual rate alone');
  return next ok(v_fp_a <> v_fp_b,
    'CP-118d and the calculation fingerprint moved - customer interest still changes the Batch calculation');
  return next ok((select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                   where n.nspname='app_private' and p.proname='resolve_row_interest')
                 !~ '(rate_entries|rate_set_versions|credit_cost)',
    'CP-118e structurally, the customer-interest resolver reads no rate entry and no Rate Set Version - it cannot be sourced from supplier credit');
  update public.pricing_groups set payment_terms_days = null where id = p_pg;
end $fn$;

create or replace function tests.__s7r_teardown()
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_fam bigint; v_party bigint; v_batches bigint[];
begin
  select id into v_fam   from public.customer_families where name = '__p2 s7r fam';
  select id into v_party from public.parties           where display_name = '__p2 s7r party';
  select coalesce(array_agg(id), '{}') into v_batches from public.batches where family_id = v_fam;

  delete from public.batch_calculations     where batch_id = any(v_batches);
  delete from public.batch_set_memberships  where batch_id = any(v_batches);
  delete from public.batch_sets             where batch_id = any(v_batches);
  delete from public.batch_rows             where batch_id = any(v_batches);
  delete from public.batch_edit_locks       where batch_id = any(v_batches);
  delete from public.batch_profile_versions where batch_id = any(v_batches);
  delete from public.batch_collaborators    where batch_id = any(v_batches);
  update public.pricing_groups set freight_basis_delivery_group_id = null where batch_id = any(v_batches);
  delete from public.delivery_groups        where batch_id = any(v_batches);
  delete from public.pricing_groups         where batch_id = any(v_batches);
  delete from public.batches                where id       = any(v_batches);

  delete from public.freight_entries where freight_set_version_id in
    (select id from public.freight_set_versions where freight_set_id in
      (select id from public.freight_sets where name like '\_\_p2 s7r fs%'));
  delete from public.pricing_basis_releases where release_name like '\_\_s7r%';
  delete from public.sku_versions  where sku_id in (select id from public.skus where party_id = v_party);
  update public.skus set replacement_sku_id = null where party_id = v_party;
  delete from public.skus          where party_id = v_party;
  delete from public.plant_construction_adoptions where construction_version_id in
    (select id from public.construction_versions where construction_id in
      (select id from public.constructions where name like '\_\_p2 s7r con%'));
  delete from public.construction_versions where construction_id in
    (select id from public.constructions where name like '\_\_p2 s7r con%');
  delete from public.constructions   where name like '\_\_p2 s7r con%';
  delete from public.sector_versions where sector_id in
    (select id from public.sectors where sector_code = '__S7R');
  delete from public.sectors         where sector_code = '__S7R';
  -- rate_entries go with their version: fk_re_version is ON DELETE CASCADE, and
  -- trg_re_follows_version guards INSERT and UPDATE only.
  delete from public.rate_set_versions where rate_set_id in
    (select id from public.rate_sets where name like '\_\_p2 s7r rs%');
  delete from public.rate_sets       where name like '\_\_p2 s7r rs%';
  delete from public.freight_set_versions where freight_set_id in
    (select id from public.freight_sets where name like '\_\_p2 s7r fs%');
  delete from public.freight_sets    where name like '\_\_p2 s7r fs%';
  delete from public.calculation_default_versions where version_no = 961;
  delete from public.customer_locations       where party_id = v_party;
  delete from public.party_family_memberships where party_id = v_party;
  delete from public.parties          where id = v_party;
  delete from public.customer_families where id = v_fam;
  delete from app_private.pending_invitations where invite_email like 'p2-s7r-%';

  -- The test key never outlives the suite.
  delete from app_private.attestation_keys where keyid = 't1';
end $fn$;

do $mig$
declare
  v_def text; v_cnt int;
  c_rsv constant text :=
    '  insert into public.rate_set_versions (rate_set_id,plant_id,version_no,created_by) values (v_rs,v_kol,1,v_owner) returning id into v_rsv;';
  c_entries constant text :=
       E'\n  insert into public.rate_entries (rate_set_version_id,plant_id,grade_code,price,discount,freight,interest_pct,created_by) values\n'
    || E'    (v_rsv,v_kol,''K150'',40,0,0,1.5,v_owner), (v_rsv,v_kol,''SF100'',40,0,0,2.0,v_owner), (v_rsv,v_kol,''K120'',40,0,0,null,v_owner),\n'
    || E'    (v_rsv,v_kol,''SF120'',40,0,0,0,v_owner), (v_rsv,v_kol,''K200'',40,0,0,3.0,v_owner);';
  c_end constant text := '  update public.batches set status=''working'' where id=v_batch;';
  c_call constant text :=
    E'\n  return query select * from tests.__s7r_rate_master_gates(v_owner, v_kol, v_party, v_batch, v_pg, v_rsv, v_rel, v_oauth, v_other, v_oclaims);';
begin
  v_def := pg_catalog.pg_get_functiondef('tests.__s7r_body()'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, c_rsv, ''))) / length(c_rsv);
  if v_cnt <> 1 then raise exception 'rate_set_versions anchor: expected 1, found %', v_cnt; end if;
  v_def := replace(v_def, c_rsv, c_rsv || c_entries);
  v_cnt := (length(v_def) - length(replace(v_def, c_end, ''))) / length(c_end);
  if v_cnt <> 1 then raise exception 'D-X restore anchor: expected 1, found %', v_cnt; end if;
  v_def := replace(v_def, c_end, c_end || c_call);
  execute v_def;
end $mig$;

revoke all on function tests.__s7r_rate_master_gates(bigint,bigint,bigint,bigint,bigint,bigint,bigint,uuid,bigint,text)
  from public, anon, authenticated;
revoke all on function tests.__s7r_teardown() from public, anon, authenticated;
revoke all on function tests.__s7r_body()     from public, anon, authenticated;