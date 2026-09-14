create or replace function tests.__s9c_gates(
  p_revision bigint,p_family bigint,p_batch bigint,
  p_mclaims text,p_maker bigint,p_cclaims text,p_checker bigint)
returns setof text language plpgsql set search_path='extensions','pg_catalog' as $fn$
declare
  v_cv integer; v_state text; v_code text; v_ref text; v_ref2 text;
  v_rev2 bigint; v_rev3 bigint; v_plant bigint; v_fy text;
  v_seq_id bigint; v_seq_before bigint; v_cap bigint;
begin
  select content_version,plant_id into v_cv,v_plant from public.batches where id=p_batch;
  v_fy:=app_private.indian_fy_label(now());
  select id,next_value into v_seq_id,v_seq_before from ref_private.reference_sequences
   where scope_type='quote' and scope_key=v_plant and fy_label=v_fy;

  perform set_config('request.jwt.claims',p_mclaims,true);
  set local role authenticated;
  perform public.submit_quote_revision(p_revision,v_cv);
  reset role;
  return next is((select workflow_status from public.quote_revisions where id=p_revision),'submitted',
    'S9C-1 Maker submits the draft candidate');
  return next is((select status from public.batches where id=p_batch),'submitted',
    'S9C-2 submission moves the Batch independently to submitted');
  return next is((select actor_user_id from public.quote_workflow_events
                   where revision_id=p_revision and event_type='submitted'),p_maker,
    'S9C-3 submission evidence identifies the Maker');

  perform set_config('request.jwt.claims',p_cclaims,true);
  set local role authenticated;
  begin perform public.return_quote_revision(p_revision,'  '); v_state:='NO ERROR';v_code:=null;
  exception when others then v_state:=sqlerrm;v_code:=sqlstate;end;
  reset role;
  return next is(v_state,'return_note_required','S9C-4 Checker Return refuses a blank note');
  return next is((select workflow_status from public.quote_revisions where id=p_revision),'submitted',
    'S9C-5 refused Return leaves the candidate submitted');

  set local role authenticated;
  perform public.approve_quote_revision(p_revision);
  reset role;
  select quote_reference into v_ref from public.quote_families where id=p_family;
  return next ok(v_ref like '%/Q/'||v_fy||'/%','S9C-6 first Checker approval allocates the permanent Quote reference');
  return next is((select revision_no from public.quote_revisions where id=p_revision),1,
    'S9C-7 first approval allocates revision number 1');
  return next is((select approved_by from public.quote_revisions where id=p_revision),p_checker,
    'S9C-8 approval attribution is the authenticated Checker');
  return next is((select status from public.batches where id=p_batch),'approved',
    'S9C-9 approval and Batch workflow move together');

  perform set_config('request.jwt.claims',p_mclaims,true);
  set local role authenticated;
  begin perform public.withdraw_quote_revision(p_revision,null);v_state:='NO ERROR';
  exception when others then v_state:=sqlerrm;end;
  reset role;
  return next is(v_state,'withdraw_reason_required','S9C-10 approved withdrawal requires a reason');
  set local role authenticated;
  perform public.withdraw_quote_revision(p_revision,'commercial correction');
  reset role;
  return next ok((select workflow_status='draft' and revision_no=1 and withdraw_reason='commercial correction'
                   from public.quote_revisions where id=p_revision),
    'S9C-11 withdrawal returns to draft and retains its allocated revision number and reason');
  return next is((select note from public.quote_workflow_events where revision_id=p_revision
                   and event_type='withdrawn' order by id desc limit 1),'commercial correction',
    'S9C-12 the withdrawal event retains its reason');

  set local role authenticated;
  perform public.acquire_batch_lock(p_batch);
  select content_version into v_cv from public.batches where id=p_batch;
  perform public.submit_quote_revision(p_revision,v_cv);
  reset role;
  perform set_config('request.jwt.claims',p_cclaims,true);
  set local role authenticated;
  perform public.approve_quote_revision(p_revision);
  reset role;
  select quote_reference into v_ref2 from public.quote_families where id=p_family;
  return next ok(v_ref2=v_ref and (select revision_no=1 from public.quote_revisions where id=p_revision),
    'S9C-13 re-approval reuses both the family reference and retained revision number');

  perform set_config('request.jwt.claims',p_mclaims,true);
  set local role authenticated;
  perform public.issue_quote_revision(p_revision,'Buyer',jsonb_build_object('city','Kolkata'),
    current_date,current_date+30);
  reset role;
  return next ok((select workflow_status='issued' and standing='current' and issued_by=p_maker
                   and addressee_name='Buyer' from public.quote_revisions where id=p_revision),
    'S9C-14 Issue is separate, attributed, and freezes the addressee');
  return next is((select status from public.batches where id=p_batch),'issued_locked',
    'S9C-15 issue locks the Batch');
  return next is((select outcome from public.customer_outcome_events where revision_id=p_revision
                   order by id limit 1),'awaiting_response',
    'S9C-16 issue starts the append-only customer outcome history');

  set local role authenticated;
  perform public.create_quote_revision(p_revision);
  reset role;
  return next ok((select status='working' from public.batches where id=p_batch)
              and exists(select 1 from app_private.pending_quote_revision_sources
                          where batch_id=p_batch and source_revision_id=p_revision),
    'S9C-17 deliberate Create Revision opens the Batch from the current issued revision');
  return next ok(not exists(select 1 from public.quote_revisions where family_id=p_family
                             and source_revision_id=p_revision and workflow_status='draft'),
    'S9C-18 merely opening work does not manufacture an immutable candidate before Send');
  select content_version into v_cv from public.batches where id=p_batch;
  set local role authenticated;
  v_rev2:=public.send_revision_batch(p_batch,v_cv);
  reset role;
  return next ok((select source_revision_id=p_revision and revision_no is null
                   from public.quote_revisions where id=v_rev2),
    'S9C-19 revision Send adopts the existing family linearly and remains unnumbered');

  select content_version into v_cv from public.batches where id=p_batch;
  set local role authenticated;
  perform public.submit_quote_revision(v_rev2,v_cv);
  reset role;
  perform set_config('request.jwt.claims',p_cclaims,true);
  set local role authenticated;
  perform public.return_quote_revision(v_rev2,'recalculate one line');
  reset role;
  return next ok((select workflow_status='returned' and return_note='recalculate one line'
                   from public.quote_revisions where id=v_rev2)
              and (select status='working' from public.batches where id=p_batch),
    'S9C-20 Checker Return retains the mandatory note and reopens Batch work');
  return next ok(exists(select 1 from app_private.pending_quote_revision_sources
                        where batch_id=p_batch and source_revision_id=v_rev2),
    'S9C-21 the returned candidate becomes the explicit source for the refreshed candidate');

  perform set_config('request.jwt.claims',p_mclaims,true);
  set local role authenticated;
  perform public.acquire_batch_lock(p_batch);
  select content_version into v_cv from public.batches where id=p_batch;
  v_rev3:=public.send_revision_batch(p_batch,v_cv);
  select content_version into v_cv from public.batches where id=p_batch;
  perform public.submit_quote_revision(v_rev3,v_cv);
  reset role;
  return next is((select source_revision_id from public.quote_revisions where id=v_rev3),v_rev2,
    'S9C-22 refreshed candidates do not branch around the returned attempt');

  -- A dual-capability Maker may self-approve; the ordinary approval event and
  -- created_by fields expose that fact without a hidden actor parameter.
  select id into v_cap from public.capabilities where capability_key='check_quote';
  insert into public.plant_capability_grants(app_user_id,plant_id,capability_id,granted_by)
    values(p_maker,v_plant,v_cap,p_checker) on conflict do nothing;
  set local role authenticated;
  perform public.approve_quote_revision(v_rev3);
  reset role;
  return next ok((select created_by=p_maker and approved_by=p_maker and revision_no=2
                   from public.quote_revisions where id=v_rev3),
    'S9C-23 a dual-capability Maker may self-approve and the row exposes it');
  return next is((select actor_user_id from public.quote_workflow_events
                   where revision_id=v_rev3 and event_type='approved' order by id desc limit 1),p_maker,
    'S9C-24 the self-approval event truthfully identifies the same actor');

  set local role authenticated;
  perform public.issue_quote_revision(v_rev3,'Buyer',null,current_date,current_date+30);
  reset role;
  return next is((select standing from public.quote_revisions where id=p_revision),'superseded',
    'S9C-25 issuing revision 2 supersedes the prior current revision');
  return next is((select standing from public.quote_revisions where id=v_rev3),'current',
    'S9C-26 exactly the new issued revision is current');
  return next ok(exists(select 1 from public.quote_workflow_events
                         where revision_id=p_revision and event_type='superseded'),
    'S9C-27 supersession is retained as workflow evidence');

  perform set_config('request.jwt.claims',p_cclaims,true);
  set local role authenticated;
  begin perform public.void_quote_revision(v_rev3,'');v_state:='NO ERROR';
  exception when others then v_state:=sqlerrm;end;
  reset role;
  return next is(v_state,'void_reason_required','S9C-28 voiding refuses a blank reason');
  set local role authenticated;
  perform public.void_quote_revision(v_rev3,'pricing error');
  reset role;
  return next ok((select standing='voided' and void_reason='pricing error' and voided_by=p_checker
                   from public.quote_revisions where id=v_rev3),
    'S9C-29 Checker voiding retains reason, actor and immutable issued record');

  perform set_config('request.jwt.claims',p_mclaims,true);
  set local role authenticated;
  perform public.create_quote_revision(v_rev3);
  reset role;
  return next ok(exists(select 1 from app_private.pending_quote_revision_sources
                        where batch_id=p_batch and source_revision_id=v_rev3),
    'S9C-30 a corrective next revision may start from the latest voided revision');
  set local role authenticated;
  begin perform public.create_quote_revision(p_revision);v_state:='NO ERROR';v_code:=null;
  exception when others then v_state:=sqlerrm;v_code:=sqlstate;end;
  reset role;
  return next ok(v_code in ('22023','PT409'),
    'S9C-31 a historical superseded revision cannot open a branch');

  delete from public.plant_capability_grants where app_user_id=p_maker and plant_id=v_plant and capability_id=v_cap;
  if v_seq_id is null then
    delete from ref_private.reference_sequences
     where scope_type='quote' and scope_key=v_plant and fy_label=v_fy;
  else
    update ref_private.reference_sequences set next_value=v_seq_before where id=v_seq_id;
  end if;
end $fn$;

do $mig$
declare v_def text;v_cnt integer;
  c_anchor constant text := E'  -- Owner-only fixture cleanup; application roles retain no delete authority.';
  c_call constant text := E'  return query select * from tests.__s9c_gates(v_rev, v_fam, p_batch, p_oclaims, p_other, p_cclaims, p_checker);\n\n';
begin
  v_def:=pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure);
  v_cnt:=(length(v_def)-length(replace(v_def,c_anchor,'')))/length(c_anchor);
  if v_cnt<>1 then raise exception 'S9(c) gate anchor: expected 1, found %',v_cnt;end if;
  execute replace(v_def,c_anchor,c_call||c_anchor);
end $mig$;

revoke all on function tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)
 from public,anon,authenticated;
