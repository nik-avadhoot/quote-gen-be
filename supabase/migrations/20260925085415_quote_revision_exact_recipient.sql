-- Freeze the exact Customer/Prospect selected on the Batch into every new
-- immutable Quote revision. This is a forward correction: the already-applied
-- Batch customer handoff migration remains untouched.
--
-- ONE ATOMIC MIGRATION, in this order:
--   1. create and revoke the recipient resolver;
--   2. replace and verify send_batch (exact anchor, matched once);
--   3. replace issue_quote_revision;
--   4. realign the stored S9(b)/S9(c) gates and add the S9R checks;
--   5. final revokes and verification.
-- Any error in any step aborts the whole migration, so exact-recipient
-- behaviour can never be active while the stored gates still expect the old
-- hand-typed addressee.
--
-- AUTHORIZATION (settled 2026-09-24). Send freezes Party-master name, code and
-- lifecycle evidence into an official Quote revision, so the caller needs BOTH
-- the existing Batch/Plant Send authority AND current read_party_master,
-- consistent with governed Batch creation. Losing Party-master read after the
-- Batch was created prevents Send; the refusal writes nothing. The resolver
-- itself stays executable by no application role.

create or replace function app_private.resolve_batch_quote_recipient(p_batch bigint)
returns table(addressee_name text, addressee_details jsonb)
language plpgsql stable security definer set search_path = '' as $fn$
begin
  if app_private.current_app_user() is null
     or not app_private.has_group_cap('read_party_master') then
    raise exception 'read_party_master is required to resolve the selected recipient'
      using errcode = '42501';
  end if;

  return query
    select p.display_name,
           jsonb_build_object(
             'identity_authority', 'batches.customer_party_id',
             'identity_version', 1,
             'party_id', p.id,
             'customer_code', p.customer_code,
             'lifecycle_state', p.lifecycle_state,
             'status_at_send', p.status)
      from public.batches b
      join public.parties p on p.id = b.customer_party_id
     where b.id = p_batch
       and ((p.lifecycle_state = 'customer' and p.status = 'active')
         or (p.lifecycle_state = 'prospect' and p.status in ('proposed', 'active')));

  if not found then
    raise exception 'the Batch has no quoteable exact Customer or Prospect recipient'
      using errcode = 'PT422';
  end if;
end $fn$;

revoke all on function app_private.resolve_batch_quote_recipient(bigint)
  from public, anon, authenticated;

-- Preserve the latest live send_batch definition (including Amendment 04's
-- Proposed-SKU correction) and replace only its revision insert. Exact-anchor
-- checks make unexpected drift fail before CREATE OR REPLACE can run.
do $migration$
declare
  v_def text;
  v_cnt integer;
  old_insert text := $anchor$  insert into public.quote_revisions(family_id, source_revision_id, workflow_status, created_by)
    values (v_family, p_source_revision, 'draft', v_actor) returning id into v_revision;$anchor$;
  new_insert text := $anchor$  insert into public.quote_revisions(
      family_id, source_revision_id, workflow_status, created_by,
      addressee_name, addressee_details)
    select v_family, p_source_revision, 'draft', v_actor,
           recipient.addressee_name, recipient.addressee_details
      from app_private.resolve_batch_quote_recipient(p_batch) recipient
    returning id into v_revision;$anchor$;
begin
  v_def := pg_catalog.pg_get_functiondef(
    'app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, old_insert, ''))) / length(old_insert);
  if v_cnt <> 1 then
    raise exception 'send_batch recipient-freeze anchor matched % times, expected 1', v_cnt
      using errcode = '55000';
  end if;
  execute replace(v_def, old_insert, new_insert);

  v_def := pg_catalog.pg_get_functiondef(
    'app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure);
  if position('resolve_batch_quote_recipient(p_batch)' in v_def) = 0
     or position('addressee_name, addressee_details' in v_def) = 0 then
    raise exception 'send_batch does not freeze the selected recipient as intended'
      using errcode = '55000';
  end if;
end $migration$;

create or replace function app_private.issue_quote_revision(
  p_revision bigint,p_addressee_name text,p_addressee_details jsonb,
  p_quote_date date,p_offer_validity_to date)
returns void language plpgsql volatile security definer set search_path = '' as $fn$
declare v_q public.quote_revisions%rowtype; v_batch public.batches%rowtype; v_actor bigint; v_prior bigint;
begin
  v_actor:=app_private.current_app_user();
  select * into v_q from public.quote_revisions where id=p_revision for update;
  select b.* into v_batch from public.quote_families qf join public.batches b on b.id=qf.batch_id
   where qf.id=v_q.family_id for update of b;
  if v_actor is null or not app_private.has_plant_cap(v_batch.plant_id,'make_quote')
     or not (v_batch.owner_user_id=v_actor or exists(select 1 from public.batch_collaborators bc
              where bc.batch_id=v_batch.id and bc.app_user_id=v_actor and bc.status='active')) then
    raise exception 'permission denied' using errcode='42501';
  end if;
  if v_q.workflow_status<>'approved' or v_batch.status<>'approved' then
    raise exception 'transition not allowed' using errcode='22023';
  end if;
  if nullif(btrim(v_q.addressee_name),'') is null
     or coalesce(v_q.addressee_details->>'identity_authority','') <> 'batches.customer_party_id'
     or nullif(v_q.addressee_details->>'party_id','') is null then
    raise exception 'exact_recipient_identity_unavailable' using errcode='PT422';
  end if;
  if p_addressee_name is not null
     and btrim(p_addressee_name) is distinct from v_q.addressee_name then
    raise exception 'recipient_identity_mismatch' using errcode='PT422';
  end if;
  if p_addressee_details is not null
     and p_addressee_details is distinct from v_q.addressee_details then
    raise exception 'recipient_identity_mismatch' using errcode='PT422';
  end if;
  if p_quote_date is not null and p_offer_validity_to is not null
     and p_offer_validity_to<p_quote_date then
    raise exception 'offer_validity_invalid' using errcode='PT422';
  end if;
  select qr.id into v_prior from public.quote_revisions qr
   where qr.family_id=v_q.family_id and qr.id<>p_revision
     and qr.workflow_status='issued' and qr.standing='current'
   order by qr.revision_no desc limit 1 for update;
  if v_prior is not null then
    update public.quote_revisions set standing='superseded' where id=v_prior;
    insert into public.quote_workflow_events(revision_id,event_type,actor_user_id)
      values(v_prior,'superseded',v_actor);
  end if;
  update public.quote_revisions set workflow_status='issued',standing='current',
    quote_date=p_quote_date,offer_validity_to=p_offer_validity_to,
    issued_by=v_actor,issued_at=now() where id=p_revision;
  update public.batches set status='issued_locked' where id=v_batch.id;
  update public.batch_edit_locks set released_at=now() where batch_id=v_batch.id and released_at is null;
  insert into public.quote_workflow_events(revision_id,event_type,actor_user_id)
    values(p_revision,'issued',v_actor);
  insert into public.customer_outcome_events(revision_id,outcome,recorded_by)
    values(p_revision,'awaiting_response',v_actor);
end $fn$;

comment on function app_private.resolve_batch_quote_recipient(bigint) is
  'Resolves the exact Batch-selected Customer/Prospect for atomic Quote-revision freezing.';
comment on function public.issue_quote_revision(bigint,text,jsonb,date,date) is
  'Issues using the recipient frozen at Send; supplied recipient fields may only validate exact equality.';

-- ═════ 4. Stored gate realignment and S9R checks (tests schema only) ═════
-- The stored S9(b)/S9(c) gates predate this rule: their S7-R fixture Batch
-- selects no Customer, its sending Maker holds no read_party_master, and
-- S9C-14/S9C-25 issue with a hand-typed 'Buyer'. They are realigned here, in
-- the same transaction, and the recipient proofs (S9R-1..16) are added to the
-- same governed fixture so Send runs against real gatherers.
--
-- Scenario: the fixture's SKUs stay owned by its original Party (B). A second
-- current member of the same Family (A) becomes the Batch-selected Customer.
-- Every revision must freeze A, never B. Every splice is an exact anchor
-- asserted to match once.

create or replace function tests.__s9r_select_recipient(p_batch bigint)
returns void language plpgsql set search_path = '' as $fn$
declare v_family bigint; v_owner bigint; v_party bigint;
begin
  select family_id, owner_user_id into strict v_family, v_owner
    from public.batches where id = p_batch;
  insert into public.parties (customer_code, display_name, lifecycle_state, status, created_by)
    values ('P2-S9R-A', '__p2 s9r recipient A', 'customer', 'active', v_owner)
    returning id into v_party;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    values (v_party, v_family, current_date, v_owner);
  update public.batches set customer_party_id = v_party where id = p_batch;
end $fn$;

create or replace function tests.__s9r_cleanup(p_batch bigint, p_other bigint)
returns void language plpgsql set search_path = '' as $fn$
begin
  update public.batches set customer_party_id = null where id = p_batch;
  delete from public.party_family_memberships
   where party_id in (select id from public.parties where left(display_name, 9) = '__p2 s9r ');
  delete from public.parties where left(display_name, 9) = '__p2 s9r ';
  delete from public.group_capability_grants g
   using public.capabilities c
   where c.id = g.capability_id and c.capability_key = 'read_party_master'
     and g.app_user_id = p_other;
end $fn$;

-- The resolver's own boundary: eligibility, a proposed Prospect, refusal of a
-- non-quoteable Party, and no execution path for application roles.
create or replace function tests.__s9r_resolver_gates(p_batch bigint, p_oclaims text)
returns setof text language plpgsql set search_path = 'extensions', 'pg_catalog' as $fn$
declare v_a bigint; v_family bigint; v_owner bigint; v_prospect bigint;
  v_name text; v_details jsonb; v_state text; v_code text;
begin
  select id into strict v_a from public.parties where customer_code = 'P2-S9R-A';
  select family_id, owner_user_id into strict v_family, v_owner from public.batches where id = p_batch;

  return next ok(not has_function_privilege('public', 'app_private.resolve_batch_quote_recipient(bigint)', 'EXECUTE')
              and not has_function_privilege('anon', 'app_private.resolve_batch_quote_recipient(bigint)', 'EXECUTE')
              and not has_function_privilege('authenticated', 'app_private.resolve_batch_quote_recipient(bigint)', 'EXECUTE'),
    'S9R-11 the recipient resolver is executable by no application role');
  return next ok((select p.prosecdef and p.proconfig = array['search_path=""']
                    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'app_private' and p.proname = 'resolve_batch_quote_recipient'),
    'S9R-12 the resolver is a definer with an empty search path');

  perform set_config('request.jwt.claims', p_oclaims, true);
  set local role authenticated;
  begin perform app_private.resolve_batch_quote_recipient(p_batch); v_state := 'NO ERROR'; v_code := null;
  exception when others then v_state := sqlerrm; v_code := sqlstate; end;
  reset role;
  return next is(v_code, '42501', 'S9R-13 an authenticated caller cannot resolve a recipient directly');

  insert into public.parties (display_name, lifecycle_state, status, created_by)
    values ('__p2 s9r prospect P', 'prospect', 'proposed', v_owner) returning id into v_prospect;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    values (v_prospect, v_family, current_date, v_owner);
  update public.batches set customer_party_id = v_prospect where id = p_batch;
  select addressee_name, addressee_details into v_name, v_details
    from app_private.resolve_batch_quote_recipient(p_batch);
  return next ok(v_name = '__p2 s9r prospect P'
              and v_details = jsonb_build_object('identity_authority', 'batches.customer_party_id',
                    'identity_version', 1, 'party_id', v_prospect, 'customer_code', null,
                    'lifecycle_state', 'prospect', 'status_at_send', 'proposed'),
    'S9R-14 a proposed Prospect remains a valid exact recipient');

  update public.parties set status = 'inactive' where id = v_prospect;
  begin perform app_private.resolve_batch_quote_recipient(p_batch); v_state := 'NO ERROR'; v_code := null;
  exception when others then v_state := sqlerrm; v_code := sqlstate; end;
  return next is(v_code, 'PT422', 'S9R-15 an inactive Party is never a quoteable recipient');

  update public.batches set customer_party_id = null where id = p_batch;
  begin perform app_private.resolve_batch_quote_recipient(p_batch); v_state := 'NO ERROR'; v_code := null;
  exception when others then v_state := sqlerrm; v_code := sqlstate; end;
  return next is(v_code, 'PT422', 'S9R-16 a Batch without a selected Customer has no recipient to freeze');
  update public.batches set customer_party_id = v_a where id = p_batch;
end $fn$;

do $mig$
declare v_def text; v_cnt integer; v_fn regprocedure; i integer;
  -- __s9b_gates
  b_setup_old constant text := E'  update public.batch_edit_locks set holder_user_id=p_other, released_at=null where batch_id=p_batch;\n';
  b_setup_new constant text := E'  update public.batch_edit_locks set holder_user_id=p_other, released_at=null where batch_id=p_batch;\n'
    || E'  -- S9R: the Batch selects Customer A; the fixture SKUs stay owned by B.\n'
    || E'  perform tests.__s9r_select_recipient(p_batch);\n';
  b_auth_old constant text := E'  update public.delivery_groups set status=''active'' where pricing_group_id=p_pg;\n';
  b_auth_new constant text := E'  update public.delivery_groups set status=''active'' where pricing_group_id=p_pg;\n'
    || E'  -- S9R: Send needs Batch/Plant Send authority AND current read_party_master.\n'
    || E'  set local role authenticated;\n'
    || E'  begin perform public.send_batch(p_batch,v_cv); v_state:=''NO ERROR''; v_code:=null;\n'
    || E'  exception when others then v_state:=sqlerrm; v_code:=sqlstate; end;\n'
    || E'  reset role;\n'
    || E'  return next ok(v_code=''42501'' and tests.__s9b_state()=v_before\n'
    || E'    and (select status||'':''||content_version from public.batches where id=p_batch)=''working:''||v_cv,\n'
    || E'    ''S9R-1 a Batch writer without current read_party_master cannot Send, and the refusal writes nothing'');\n'
    || E'  insert into public.group_capability_grants(app_user_id,capability_id,granted_by)\n'
    || E'    select p_other,c.id,p_checker from public.capabilities c where c.capability_key=''read_party_master'';\n';
  b_sent_old constant text := E'  return next ok(v_rev is not null,''S9B-19 a complete Batch sends successfully'');\n';
  b_sent_new constant text := E'  return next ok(v_rev is not null,''S9B-19 a complete Batch sends successfully'');\n'
    || E'  return next ok(exists(select 1 from public.batch_rows br join public.skus s on s.id=br.sku_id\n'
    || E'      join public.party_family_memberships m on m.party_id=s.party_id and m.is_current\n'
    || E'     where br.batch_id=p_batch and br.status=''active''\n'
    || E'       and m.family_id=(select family_id from public.batches where id=p_batch)\n'
    || E'       and s.party_id<>(select customer_party_id from public.batches where id=p_batch)),\n'
    || E'    ''S9R-2 precondition: the sent SKUs belong to another current member of the Batch Family'');\n'
    || E'  return next ok((select qr.addressee_name=''__p2 s9r recipient A''\n'
    || E'       and qr.addressee_details=jsonb_build_object(''identity_authority'',''batches.customer_party_id'',\n'
    || E'         ''identity_version'',1,''party_id'',p.id,''customer_code'',''P2-S9R-A'',\n'
    || E'         ''lifecycle_state'',''customer'',''status_at_send'',''active'')\n'
    || E'     from public.quote_revisions qr, public.parties p\n'
    || E'    where qr.id=v_rev and p.customer_code=''P2-S9R-A''),\n'
    || E'    ''S9R-3 Send freezes the Batch-selected Customer A as the exact addressee'');\n'
    || E'  return next ok(not exists(select 1 from public.batch_rows br join public.skus s on s.id=br.sku_id\n'
    || E'     where br.batch_id=p_batch\n'
    || E'       and s.party_id=((select addressee_details from public.quote_revisions where id=v_rev)->>''party_id'')::bigint),\n'
    || E'    ''S9R-4 the SKU-owning Family member never becomes the Quote addressee'');\n';
  b_clean_old constant text := E'  -- Owner-only fixture cleanup; application roles retain no delete authority.\n';
  b_clean_new constant text := E'  return query select * from tests.__s9r_resolver_gates(p_batch, p_oclaims);\n\n'
    || E'  -- Owner-only fixture cleanup; application roles retain no delete authority.\n';
  b_tail_old constant text := E'  delete from public.quote_families where id=v_fam;\n';
  b_tail_new constant text := E'  delete from public.quote_families where id=v_fam;\n'
    || E'  perform tests.__s9r_cleanup(p_batch, p_other);\n';
  -- __s9c_gates
  c_decl_old constant text := E'  v_seq_id bigint; v_seq_before bigint; v_cap bigint;\n';
  c_decl_new constant text := E'  v_seq_id bigint; v_seq_before bigint; v_cap bigint;\n'
    || E'  v_s9r_name text; v_s9r_details jsonb; v_s9r_b bigint;\n';
  c_issue_old constant text := E'  perform set_config(''request.jwt.claims'',p_mclaims,true);\n'
    || E'  set local role authenticated;\n'
    || E'  perform public.issue_quote_revision(p_revision,''Buyer'',jsonb_build_object(''city'',''Kolkata''),\n'
    || E'    current_date,current_date+30);\n'
    || E'  reset role;\n'
    || E'  return next ok((select workflow_status=''issued'' and standing=''current'' and issued_by=p_maker\n'
    || E'                   and addressee_name=''Buyer'' from public.quote_revisions where id=p_revision),\n'
    || E'    ''S9C-14 Issue is separate, attributed, and freezes the addressee'');\n';
  c_issue_new constant text := E'  -- S9R: Issue consumes the identity frozen at Send.\n'
    || E'  select addressee_name,addressee_details into v_s9r_name,v_s9r_details\n'
    || E'    from public.quote_revisions where id=p_revision;\n'
    || E'  select s.party_id into v_s9r_b from public.batch_rows br join public.skus s on s.id=br.sku_id\n'
    || E'   where br.batch_id=p_batch order by br.id limit 1;\n'
    || E'  update public.parties set display_name=''__p2 s9r recipient A renamed'' where customer_code=''P2-S9R-A'';\n'
    || E'  update public.customer_families set name=''__p2 s7r fam renamed''\n'
    || E'   where id=(select family_id from public.batches where id=p_batch);\n'
    || E'  return next ok((select addressee_name=v_s9r_name and addressee_details=v_s9r_details\n'
    || E'                   from public.quote_revisions where id=p_revision),\n'
    || E'    ''S9R-5 later Party and Family renames cannot change frozen revision evidence'');\n'
    || E'  update public.customer_families set name=''__p2 s7r fam''\n'
    || E'   where id=(select family_id from public.batches where id=p_batch);\n'
    || E'  perform set_config(''request.jwt.claims'',p_mclaims,true);\n'
    || E'  set local role authenticated;\n'
    || E'  begin perform public.issue_quote_revision(p_revision,''__p2 s9r recipient A renamed'',null,\n'
    || E'      current_date,current_date+30); v_state:=''NO ERROR''; v_code:=null;\n'
    || E'  exception when others then v_state:=sqlerrm; v_code:=sqlstate; end;\n'
    || E'  reset role;\n'
    || E'  return next is(v_code||'':''||v_state,''PT422:recipient_identity_mismatch'',\n'
    || E'    ''S9R-6 a recipient name other than the frozen one is refused, even the current master name'');\n'
    || E'  set local role authenticated;\n'
    || E'  begin perform public.issue_quote_revision(p_revision,null,\n'
    || E'      v_s9r_details||jsonb_build_object(''party_id'',v_s9r_b),current_date,current_date+30);\n'
    || E'    v_state:=''NO ERROR''; v_code:=null;\n'
    || E'  exception when others then v_state:=sqlerrm; v_code:=sqlstate; end;\n'
    || E'  reset role;\n'
    || E'  return next is(v_code||'':''||v_state,''PT422:recipient_identity_mismatch'',\n'
    || E'    ''S9R-7 guessed recipient details naming another Party are refused'');\n'
    || E'  return next ok((select workflow_status=''approved'' and addressee_name=v_s9r_name\n'
    || E'                   and addressee_details=v_s9r_details and issued_at is null\n'
    || E'                   from public.quote_revisions where id=p_revision)\n'
    || E'              and (select status=''approved'' from public.batches where id=p_batch)\n'
    || E'              and not exists(select 1 from public.quote_workflow_events\n'
    || E'                              where revision_id=p_revision and event_type=''issued'')\n'
    || E'              and not exists(select 1 from public.customer_outcome_events where revision_id=p_revision),\n'
    || E'    ''S9R-8 refused Issues leave the revision, Batch and evidence unchanged'');\n'
    || E'  update public.quote_revisions set addressee_details=null where id=p_revision;\n'
    || E'  set local role authenticated;\n'
    || E'  begin perform public.issue_quote_revision(p_revision,null,null,current_date,current_date+30);\n'
    || E'    v_state:=''NO ERROR''; v_code:=null;\n'
    || E'  exception when others then v_state:=sqlerrm; v_code:=sqlstate; end;\n'
    || E'  reset role;\n'
    || E'  return next is(v_code||'':''||v_state,''PT422:exact_recipient_identity_unavailable'',\n'
    || E'    ''S9R-9 a legacy revision without exact frozen identity is refused, never re-derived'');\n'
    || E'  update public.quote_revisions set addressee_details=v_s9r_details where id=p_revision;\n'
    || E'  set local role authenticated;\n'
    || E'  perform public.issue_quote_revision(p_revision,null,null,current_date,current_date+30);\n'
    || E'  reset role;\n'
    || E'  return next ok((select workflow_status=''issued'' and standing=''current'' and issued_by=p_maker\n'
    || E'                   and addressee_name=v_s9r_name and addressee_details=v_s9r_details\n'
    || E'                   from public.quote_revisions where id=p_revision),\n'
    || E'    ''S9C-14 Issue is separate, attributed, and consumes the addressee frozen at Send'');\n';
  c_rev2_old constant text := E'    ''S9C-19 revision Send adopts the existing family linearly and remains unnumbered'');\n';
  c_rev2_new constant text := E'    ''S9C-19 revision Send adopts the existing family linearly and remains unnumbered'');\n'
    || E'  return next ok((select addressee_name=''__p2 s9r recipient A renamed''\n'
    || E'                   and (addressee_details->>''party_id'')::bigint=(v_s9r_details->>''party_id'')::bigint\n'
    || E'                   from public.quote_revisions where id=v_rev2)\n'
    || E'              and (select addressee_name=v_s9r_name from public.quote_revisions where id=p_revision),\n'
    || E'    ''S9R-10 a later revision freezes the same Party as it stands then; the earlier one is untouched'');\n';
  c_rev3_old constant text := E'  perform public.issue_quote_revision(v_rev3,''Buyer'',null,current_date,current_date+30);\n';
  c_rev3_new constant text := E'  perform public.issue_quote_revision(v_rev3,null,null,current_date,current_date+30);\n';
  v_pairs text[][];
begin
  v_fn := 'tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure;
  v_pairs := array[[b_setup_old,b_setup_new],[b_auth_old,b_auth_new],[b_sent_old,b_sent_new],
                   [b_clean_old,b_clean_new],[b_tail_old,b_tail_new]];
  v_def := pg_get_functiondef(v_fn);
  for i in 1..array_length(v_pairs,1) loop
    v_cnt := (length(v_def)-length(replace(v_def,v_pairs[i][1],'')))/length(v_pairs[i][1]);
    if v_cnt<>1 then raise exception 'S9R __s9b_gates anchor % matched %, expected 1', i, v_cnt using errcode='55000'; end if;
    v_def := replace(v_def,v_pairs[i][1],v_pairs[i][2]);
  end loop;
  execute v_def;

  v_fn := 'tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure;
  v_pairs := array[[c_decl_old,c_decl_new],[c_issue_old,c_issue_new],[c_rev2_old,c_rev2_new],
                   [c_rev3_old,c_rev3_new]];
  v_def := pg_get_functiondef(v_fn);
  for i in 1..array_length(v_pairs,1) loop
    v_cnt := (length(v_def)-length(replace(v_def,v_pairs[i][1],'')))/length(v_pairs[i][1]);
    if v_cnt<>1 then raise exception 'S9R __s9c_gates anchor % matched %, expected 1', i, v_cnt using errcode='55000'; end if;
    v_def := replace(v_def,v_pairs[i][1],v_pairs[i][2]);
  end loop;
  execute v_def;

  -- Prove the results rather than trust the replacements.
  v_def := pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure);
  if position('''Buyer''' in v_def) > 0 or position('S9R-9 ' in v_def) = 0 then
    raise exception 'S9R __s9c_gates was not rewritten as intended' using errcode='55000';
  end if;
  v_def := pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure);
  if position('__s9r_select_recipient(p_batch)' in v_def) = 0 or position('__s9r_cleanup(p_batch, p_other)' in v_def) = 0
     or position('__s9r_resolver_gates(p_batch, p_oclaims)' in v_def) = 0 then
    raise exception 'S9R __s9b_gates was not rewritten as intended' using errcode='55000';
  end if;
end $mig$;

-- ═════ 5. Final revokes and verification ═════
revoke all on function app_private.resolve_batch_quote_recipient(bigint) from public, anon, authenticated;
revoke all on function tests.__s9r_select_recipient(bigint) from public, anon, authenticated;
revoke all on function tests.__s9r_cleanup(bigint,bigint) from public, anon, authenticated;
revoke all on function tests.__s9r_resolver_gates(bigint,text) from public, anon, authenticated;
revoke all on function tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint) from public, anon, authenticated;
revoke all on function tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint) from public, anon, authenticated;

do $verify$
declare v_fn text;
begin
  foreach v_fn in array array[
    'app_private.resolve_batch_quote_recipient(bigint)',
    'tests.__s9r_select_recipient(bigint)',
    'tests.__s9r_cleanup(bigint,bigint)',
    'tests.__s9r_resolver_gates(bigint,text)'] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE')
       or has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception '% is executable by an application role', v_fn using errcode = '55000';
    end if;
  end loop;
  if position('resolve_batch_quote_recipient(p_batch)' in pg_catalog.pg_get_functiondef(
       'app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure)) = 0
     or position('exact_recipient_identity_unavailable' in pg_catalog.pg_get_functiondef(
       'app_private.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure)) = 0
     or position('__s9r_select_recipient(p_batch)' in pg_catalog.pg_get_functiondef(
       'tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure)) = 0
     or position('S9R-9 ' in pg_catalog.pg_get_functiondef(
       'tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)) = 0 then
    raise exception 'exact-recipient migration did not install every part' using errcode = '55000';
  end if;
end $verify$;
