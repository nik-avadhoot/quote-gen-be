-- S9(b) focused gates. Reuse the governed S7-R fixture so Send is exercised
-- against calculations shaped by the real gatherers. All Family G rows made by
-- the positive control are removed before the fixture's existing teardown.

create or replace function tests.__s9b_result(p_in jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $fn$
declare v_n integer; v_add numeric; v_rows jsonb;
begin
  select count(*)::integer into v_n
    from (values ('TOP',1),('F1',2),('L1',3),('F2',4),('L2',5)) x(k,n)
   where p_in->'entered'->'layers'->x.k->>'code' is not null
     and p_in->'entered'->'layers'->x.k->>'gsm' is not null;
  select coalesce(sum(value::numeric),0) into v_add
    from jsonb_each_text(p_in->'entered'->'add_ons');
  select jsonb_agg(
    case when p_in->'entered'->'layers'->x.k->>'code' is null
               or p_in->'entered'->'layers'->x.k->>'gsm' is null
         then jsonb_build_object('k',x.k,'wt',0,'cost',0,'rate',0)
         else jsonb_build_object(
           'k',x.k,'wt',1,'ws',1,'cost',1,'rate',1,
           'code',p_in->'entered'->'layers'->x.k->>'code',
           'gsm',(p_in->'entered'->'layers'->x.k->>'gsm')::numeric,'tu',1)
    end order by x.n) into v_rows
    from (values ('TOP',1),('F1',2),('L1',3),('F2',4),('L2',5)) x(k,n);
  return jsonb_build_object(
    'contract_version',1,
    'engine',jsonb_build_object(
      'deckle',1,'cutting',1,'area',1,'wt',v_n,'wt_sheet',1,
      'mat',v_n,'conv',1,'fr',1,'add_ons',v_add,'int_c',1,'total',1,
      'final_rate',1,'margin_amt',1,'moq_kg',1,'estimated_box_wt',1,
      'calc_moq',1,'calc_bs',1,'calc_gsm',1,'rate_per_kg',1,
      'fr_rate',(p_in->'resolved'->'freight'->>'value')::numeric),
    'row_details',v_rows);
end $fn$;

create or replace function tests.__s9b_state()
returns jsonb language sql stable set search_path = '' as $fn$
  select jsonb_build_array(
    (select count(*) from public.quote_families),
    (select count(*) from public.quote_revisions),
    (select count(*) from public.calculation_snapshots),
    (select count(*) from public.quote_items),
    (select count(*) from public.quote_item_delivery_groups),
    (select count(*) from public.quote_workflow_events),
    (select count(*) from public.customer_outcome_events),
    (select count(*) from public.export_events),
    (select count(*) from public.export_parts))
$fn$;

create or replace function tests.__s9b_gates(
  p_batch bigint, p_pg bigint, p_oclaims text, p_other bigint,
  p_cclaims text, p_checker bigint)
returns setof text language plpgsql set search_path = 'extensions', 'pg_catalog' as $fn$
declare
  v_row bigint; v_dg bigint; v_loc bigint; v_rev bigint; v_fam bigint;
  v_cv integer; v_active integer; v_links integer; v_state text; v_code text;
  v_before jsonb; v_refs jsonb; v_in jsonb; v_snapshot_ids bigint[]; rr record;
begin
  return next ok(not (select p.prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='send_batch'),
    'S9B-1 public.send_batch is an invoker shim, so auth.uid remains the caller');
  return next ok((select p.prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='app_private' and p.proname='send_batch'),
    'S9B-2 the write implementation alone is SECURITY DEFINER');
  return next is((select p.proconfig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='app_private' and p.proname='send_batch'
      and pg_get_function_identity_arguments(p.oid)='p_batch bigint, p_expected_content_version integer, p_existing_family bigint, p_source_revision bigint'), array['search_path=""'],
    'S9B-3 the privileged implementation has an empty search path');
  return next ok(has_function_privilege('authenticated','app_private.send_batch(bigint,integer,bigint,bigint)','EXECUTE')
              and has_function_privilege('authenticated','public.send_batch(bigint,integer)','EXECUTE'),
    'S9B-4 the invoker shim has the minimum implementation grant; app_private remains outside the exposed API schemas');

  select dg.id,dg.ship_to_location_id into v_dg,v_loc
    from public.pricing_groups pg
    join public.delivery_groups dg on dg.id=pg.freight_basis_delivery_group_id
   where pg.id=p_pg;
  update public.delivery_groups set status='active' where id=v_dg;
  update public.customer_locations set status='active', ship_to_eligible=true where id=v_loc;
  update public.pricing_groups set status='active', freight_mode='master',
         freight_basis_delivery_group_id=v_dg, freight_manual_value=null where id=p_pg;
  update public.batches set status='working' where id=p_batch;
  update public.batch_edit_locks set holder_user_id=p_other, released_at=null where batch_id=p_batch;

  -- Refresh every active row after the S7-R fixture's deliberate mutations.
  for rr in select br.id from public.batch_rows br
             where br.batch_id=p_batch and br.status='active' order by br.id loop
    v_in := app_private.build_effective_inputs(rr.id);
    insert into public.batch_calculations(
      batch_row_id,batch_id,calculation_fingerprint,presentation_fingerprint,
      engine_version,schema_version,effective_inputs,results,computed_by,computed_at)
    values (rr.id,p_batch,app_private.calculation_fingerprint(rr.id),
      app_private.presentation_fingerprint(rr.id),v_in->'provenance'->>'engine_version',1,
      v_in,tests.__s9b_result(v_in),p_other,now()-interval '10 seconds')
    on conflict (batch_row_id) do update set
      calculation_fingerprint=excluded.calculation_fingerprint,
      presentation_fingerprint=excluded.presentation_fingerprint,
      engine_version=excluded.engine_version,schema_version=excluded.schema_version,
      effective_inputs=excluded.effective_inputs,results=excluded.results,
      computed_by=excluded.computed_by,computed_at=excluded.computed_at;
  end loop;
  select count(*)::integer into v_active from public.batch_rows
   where batch_id=p_batch and status='active';
  select content_version into v_cv from public.batches where id=p_batch;
  v_before := tests.__s9b_state();
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) into v_refs
    from ref_private.reference_sequences x where x.scope_type='quote';

  -- Missing calculation: error plus all four atomicity quantities.
  select id into v_row from public.batch_rows where batch_id=p_batch and status='active' order by id desc limit 1;
  delete from public.batch_calculations where batch_row_id=v_row;
  perform set_config('request.jwt.claims',p_oclaims,true);
  set local role authenticated;
  begin perform public.send_batch(p_batch,v_cv); v_state:='NO ERROR'; v_code:=null;
  exception when others then v_state:=sqlerrm; v_code:=sqlstate; end;
  reset role;
  return next is(v_code,'PT422','S9B-5 missing calculation returns controlled PT422');
  return next is(v_state,'calculation_missing','S9B-6 missing calculation names its refusal class');
  return next is(tests.__s9b_state(),v_before,'S9B-7 missing calculation leaves all nine Family G tables unchanged');
  return next is((select status from public.batches where id=p_batch),'working','S9B-8 missing calculation leaves Batch status working');
  return next is((select content_version from public.batches where id=p_batch),v_cv,'S9B-9 missing calculation leaves Batch CAS unchanged');
  return next is((select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb)
                   from ref_private.reference_sequences x where x.scope_type='quote'),v_refs,
    'S9B-10 missing calculation has no Quote-sequence effect');

  v_in := app_private.build_effective_inputs(v_row);
  insert into public.batch_calculations(
    batch_row_id,batch_id,calculation_fingerprint,presentation_fingerprint,
    engine_version,schema_version,effective_inputs,results,computed_by,computed_at)
  values (v_row,p_batch,app_private.calculation_fingerprint(v_row),
    app_private.presentation_fingerprint(v_row),v_in->'provenance'->>'engine_version',1,
    v_in,tests.__s9b_result(v_in),p_other,now()-interval '10 seconds');

  -- Stale calculation refuses before writes.
  update public.batch_calculations set calculation_fingerprint='stale' where batch_row_id=v_row;
  set local role authenticated;
  begin perform public.send_batch(p_batch,v_cv); v_state:='NO ERROR'; v_code:=null;
  exception when others then v_state:=sqlerrm; v_code:=sqlstate; end;
  reset role;
  return next is(v_state,'calculation_stale','S9B-11 stale calculation is refused');
  return next is(tests.__s9b_state(),v_before,'S9B-12 stale refusal leaves all Family G tables unchanged');
  return next is((select status||':'||content_version from public.batches where id=p_batch),
                 'working:'||v_cv,'S9B-13 stale refusal leaves Batch status and CAS unchanged');
  return next is((select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb)
                   from ref_private.reference_sequences x where x.scope_type='quote'),v_refs,
    'S9B-14 stale refusal has no Quote-sequence effect');
  update public.batch_calculations set calculation_fingerprint=app_private.calculation_fingerprint(v_row)
   where batch_row_id=v_row;

  -- No active delivery destination refuses the whole candidate.
  update public.delivery_groups set status='removed' where pricing_group_id=p_pg;
  set local role authenticated;
  begin perform public.send_batch(p_batch,v_cv); v_state:='NO ERROR'; v_code:=null;
  exception when others then v_state:=sqlerrm; v_code:=sqlstate; end;
  reset role;
  return next is(v_state,'delivery_group_absent','S9B-15 a Pricing Group with no active Delivery Group is refused');
  return next is(tests.__s9b_state(),v_before,'S9B-16 delivery refusal leaves all Family G tables unchanged');
  return next is((select status||':'||content_version from public.batches where id=p_batch),
                 'working:'||v_cv,'S9B-17 delivery refusal leaves Batch status and CAS unchanged');
  return next is((select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb)
                   from ref_private.reference_sequences x where x.scope_type='quote'),v_refs,
    'S9B-18 delivery refusal has no Quote-sequence effect');
  update public.delivery_groups set status='active' where pricing_group_id=p_pg;

  select sum((select count(*) from public.delivery_groups dg
               where dg.pricing_group_id=br.pricing_group_id and dg.batch_id=p_batch and dg.status='active'))::integer
    into v_links from public.batch_rows br where br.batch_id=p_batch and br.status='active';
  set local role authenticated;
  v_rev := public.send_batch(p_batch,v_cv);
  reset role;
  select family_id into v_fam from public.quote_revisions where id=v_rev;
  return next ok(v_rev is not null,'S9B-19 a complete Batch sends successfully');
  return next is((select count(*)::integer from public.quote_items where revision_id=v_rev),v_active,
    'S9B-20 every active row becomes exactly one Quote Item');
  return next is((select count(*)::integer from public.calculation_snapshots cs join public.quote_items qi
                   on qi.calculation_snapshot_id=cs.id where qi.revision_id=v_rev),v_active,
    'S9B-21 every active row has exactly one immutable calculation snapshot');
  return next is((select count(*)::integer from public.quote_item_delivery_groups qd
                   join public.quote_items qi on qi.id=qd.quote_item_id where qi.revision_id=v_rev),v_links,
    'S9B-22 each Item covers every active Delivery Group in its Pricing Group');
  return next ok(not exists (
      select 1 from public.quote_items qi
      join public.batch_rows br on br.lineage_id=qi.batch_row_lineage_id
      join public.calculation_snapshots cs on cs.id=qi.calculation_snapshot_id
      join public.batch_calculations bc on bc.batch_row_id=br.id
       where qi.revision_id=v_rev and
         (br.batch_id<>p_batch or cs.calculated_at<>bc.computed_at
          or cs.calculated_by<>bc.computed_by
          or cs.calculation_fingerprint<>bc.calculation_fingerprint
          or cs.presentation_fingerprint<>bc.presentation_fingerprint)),
    'S9B-23 lineage, actor, computed_at and both fingerprints are preserved verbatim');
  return next ok((select quote_reference is null from public.quote_families where id=v_fam)
              and (select revision_no is null from public.quote_revisions where id=v_rev),
    'S9B-24 Send allocates neither a Quote reference nor a revision number');
  return next is((select count(*)::integer from public.quote_workflow_events where revision_id=v_rev),0,
    'S9B-25 Send writes no S9(c) workflow event');
  return next is((select status||':'||content_version from public.batches where id=p_batch),
                 'sent:'||(v_cv+1),'S9B-26 Send transitions the Batch exactly once and advances its CAS');
  return next is((select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb)
                   from ref_private.reference_sequences x where x.scope_type='quote'),v_refs,
    'S9B-27 successful Send still has no Quote-sequence effect');

  set local role authenticated;
  begin perform public.send_batch(p_batch,v_cv+1); v_state:='NO ERROR'; v_code:=null;
  exception when others then v_state:=sqlerrm; v_code:=sqlstate; end;
  reset role;
  return next is(v_code,'22023','S9B-28 duplicate Send is a state-transition refusal');
  return next is(tests.__s9b_state(),
    jsonb_build_array((v_before->>0)::bigint+1,(v_before->>1)::bigint+1,
      (v_before->>2)::bigint+v_active,(v_before->>3)::bigint+v_active,
      (v_before->>4)::bigint+v_links,(v_before->>5)::bigint,
      (v_before->>6)::bigint,(v_before->>7)::bigint,(v_before->>8)::bigint),
    'S9B-29 duplicate Send writes nothing');

  -- Owner-only fixture cleanup; application roles retain no delete authority.
  select coalesce(array_agg(qi.calculation_snapshot_id),'{}') into v_snapshot_ids
    from public.quote_items qi join public.quote_revisions qr on qr.id=qi.revision_id
   where qr.family_id=v_fam;
  delete from public.quote_item_delivery_groups where quote_item_id in
    (select qi.id from public.quote_items qi join public.quote_revisions qr on qr.id=qi.revision_id
      where qr.family_id=v_fam);
  delete from public.quote_items where revision_id in
    (select id from public.quote_revisions where family_id=v_fam);
  delete from public.calculation_snapshots where id=any(v_snapshot_ids);
  delete from public.customer_outcome_events where revision_id in
    (select id from public.quote_revisions where family_id=v_fam);
  delete from public.quote_workflow_events where revision_id in
    (select id from public.quote_revisions where family_id=v_fam);
  if to_regclass('app_private.pending_quote_revision_sources') is not null then
    execute 'delete from app_private.pending_quote_revision_sources where family_id=$1' using v_fam;
  end if;
  delete from public.quote_revisions where family_id=v_fam;
  delete from public.quote_families where id=v_fam;
  update public.batches set status='working' where id=p_batch;
end $fn$;

do $mig$
declare v_def text; v_cnt integer;
  c_anchor constant text :=
    E'  return query select * from tests.__s7r_rate_master_gates(v_owner, v_kol, v_party, v_batch, v_pg, v_rsv, v_rel, v_oauth, v_other, v_oclaims);';
  c_call constant text :=
    E'\n  return query select * from tests.__s9b_gates(v_batch, v_pg, v_oclaims, v_other, v_cclaims, v_chk);';
begin
  v_def := pg_get_functiondef('tests.__s7r_body()'::regprocedure);
  v_cnt := (length(v_def)-length(replace(v_def,c_anchor,'')))/length(c_anchor);
  if v_cnt<>1 then raise exception 'S9(b) gate anchor: expected 1, found %',v_cnt; end if;
  execute replace(v_def,c_anchor,c_anchor||c_call);
end $mig$;

revoke all on function tests.__s9b_result(jsonb) from public,anon,authenticated;
revoke all on function tests.__s9b_state() from public,anon,authenticated;
revoke all on function tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint) from public,anon,authenticated;

-- S9-P deliberately asserted that Send did not yet exist. Preserve the tranche
-- boundary as a positive assertion now that S9(b) supplies both entry points.
do $mig$
declare v_def text;v_old text;v_new text;v_cnt integer;
begin
  v_old:=E'    0,\n    ''CP-82 and NO Send operation - S9(b) remains unimplemented and unauthorised'');';
  v_new:=E'    2,\n    ''CP-82 S9(b) now supplies exactly the public Send shim and its app_private implementation'');';
  v_def:=pg_get_functiondef('tests.__s9p_body()'::regprocedure);
  v_cnt:=(length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  if v_cnt<>1 then raise exception 'expected one CP-82 assertion, found %',v_cnt;end if;
  execute replace(v_def,v_old,v_new);
end $mig$;
