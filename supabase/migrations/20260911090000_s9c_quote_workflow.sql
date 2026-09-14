-- S9(c): Quote candidate workflow, first-approval numbering, issue, return,
-- withdrawal, voiding and linear revision adoption.

create table app_private.pending_quote_revision_sources (
  batch_id          bigint primary key references public.batches(id) on delete restrict,
  family_id         bigint not null references public.quote_families(id) on delete restrict,
  source_revision_id bigint not null references public.quote_revisions(id) on delete restrict,
  created_by        bigint not null references public.app_users(id) on delete restrict,
  created_at        timestamptz not null default now(),
  constraint uk_pqrs_family unique (family_id),
  constraint ck_pqrs_source_not_null check (source_revision_id > 0)
);
revoke all on app_private.pending_quote_revision_sources from public,anon,authenticated;

create or replace function app_private.submit_quote_revision(
  p_revision bigint, p_expected_content_version integer)
returns void language plpgsql volatile security definer set search_path = '' as $fn$
declare v_q public.quote_revisions%rowtype; v_b public.batches%rowtype; v_actor bigint;
begin
  v_actor:=app_private.current_app_user();
  select qr.* into v_q from public.quote_revisions qr where qr.id=p_revision for update;
  select b.* into v_b from public.quote_families qf join public.batches b on b.id=qf.batch_id
   where qf.id=v_q.family_id for update of b;
  if v_actor is null or v_q.id is null or not app_private.can_write_batch(v_b.id) then
    raise exception 'permission denied' using errcode='42501';
  end if;
  if v_b.content_version is distinct from p_expected_content_version then
    raise exception 'stale content_version' using errcode='PT409';
  end if;
  if v_q.workflow_status<>'draft' or v_b.status<>'sent' then
    raise exception 'transition not allowed' using errcode='22023';
  end if;
  update public.quote_revisions set workflow_status='submitted' where id=p_revision;
  update public.batches set status='submitted'
   where id=v_b.id and content_version=p_expected_content_version;
  if not found then raise exception 'stale content_version' using errcode='PT409'; end if;
  insert into public.quote_workflow_events(revision_id,event_type,actor_user_id)
    values(p_revision,'submitted',v_actor);
end $fn$;

create or replace function app_private.return_quote_revision(p_revision bigint,p_note text)
returns void language plpgsql volatile security definer set search_path = '' as $fn$
declare v_q public.quote_revisions%rowtype; v_batch bigint; v_plant bigint; v_actor bigint;
begin
  v_actor:=app_private.current_app_user();
  select * into v_q from public.quote_revisions where id=p_revision for update;
  select batch_id into v_batch from public.quote_families where id=v_q.family_id;
  select plant_id into v_plant from public.batches where id=v_batch for update;
  if v_actor is null or not app_private.has_plant_cap(v_plant,'check_quote') then
    raise exception 'permission denied' using errcode='42501';
  end if;
  if nullif(btrim(p_note),'') is null then
    raise exception 'return_note_required' using errcode='PT422';
  end if;
  if v_q.workflow_status<>'submitted' or (select status from public.batches where id=v_batch)<>'submitted' then
    raise exception 'transition not allowed' using errcode='22023';
  end if;
  update public.quote_revisions set workflow_status='returned',return_note=btrim(p_note) where id=p_revision;
  update public.batches set status='working' where id=v_batch;
  update public.batch_edit_locks set released_at=now()
   where batch_id=v_batch and released_at is null;
  insert into app_private.pending_quote_revision_sources(batch_id,family_id,source_revision_id,created_by)
    values(v_batch,v_q.family_id,p_revision,v_actor)
    on conflict(batch_id) do update set family_id=excluded.family_id,
      source_revision_id=excluded.source_revision_id,created_by=excluded.created_by,created_at=now();
  insert into public.quote_workflow_events(revision_id,event_type,actor_user_id,note)
    values(p_revision,'returned',v_actor,btrim(p_note));
end $fn$;

create or replace function app_private.send_revision_batch(
  p_batch bigint,p_expected_content_version integer)
returns bigint language plpgsql volatile security definer set search_path = '' as $fn$
declare v_p app_private.pending_quote_revision_sources%rowtype; v_id bigint;
begin
  select * into v_p from app_private.pending_quote_revision_sources
   where batch_id=p_batch for update;
  if not found then raise exception 'revision_source_missing' using errcode='PT422'; end if;
  v_id:=app_private.send_batch(p_batch,p_expected_content_version,v_p.family_id,v_p.source_revision_id);
  delete from app_private.pending_quote_revision_sources where batch_id=p_batch;
  return v_id;
end $fn$;

create or replace function app_private.approve_quote_revision(p_revision bigint)
returns void language plpgsql volatile security definer set search_path = '' as $fn$
declare
  v_q public.quote_revisions%rowtype; v_family public.quote_families%rowtype;
  v_batch public.batches%rowtype; v_actor bigint; v_no integer;
  v_seq bigint; v_fy text; v_code text;
begin
  v_actor:=app_private.current_app_user();
  select * into v_q from public.quote_revisions where id=p_revision for update;
  select * into v_family from public.quote_families where id=v_q.family_id for update;
  select * into v_batch from public.batches where id=v_family.batch_id for update;
  if v_actor is null or not app_private.has_plant_cap(v_batch.plant_id,'check_quote') then
    raise exception 'permission denied' using errcode='42501';
  end if;
  if v_q.workflow_status<>'submitted' or v_batch.status<>'submitted' then
    raise exception 'transition not allowed' using errcode='22023';
  end if;
  if v_family.quote_reference is null then
    v_fy:=app_private.indian_fy_label(now());
    select plant_code into v_code from public.plants where id=v_batch.plant_id;
    v_seq:=ref_private.allocate_reference('quote',v_batch.plant_id,v_fy);
    update public.quote_families set quote_reference=
      format('%s/Q/%s/%s',v_code,v_fy,lpad(v_seq::text,5,'0')),status='active'
      where id=v_family.id;
  else
    update public.quote_families set status='active' where id=v_family.id;
  end if;
  v_no:=v_q.revision_no;
  if v_no is null then
    select coalesce(max(revision_no),0)+1 into v_no from public.quote_revisions
     where family_id=v_family.id;
  end if;
  update public.quote_revisions set workflow_status='approved',revision_no=v_no,
    approved_by=v_actor,approved_at=now() where id=p_revision;
  update public.batches set status='approved' where id=v_batch.id;
  insert into public.quote_workflow_events(revision_id,event_type,actor_user_id)
    values(p_revision,'approved',v_actor);
end $fn$;

create or replace function app_private.withdraw_quote_revision(p_revision bigint,p_reason text)
returns void language plpgsql volatile security definer set search_path = '' as $fn$
declare v_q public.quote_revisions%rowtype; v_batch public.batches%rowtype; v_actor bigint; v_allowed boolean;
begin
  v_actor:=app_private.current_app_user();
  select qr.* into v_q from public.quote_revisions qr where id=p_revision for update;
  select b.* into v_batch from public.quote_families qf join public.batches b on b.id=qf.batch_id
   where qf.id=v_q.family_id for update of b;
  v_allowed:=app_private.has_plant_cap(v_batch.plant_id,'check_quote') or
    (app_private.has_plant_cap(v_batch.plant_id,'make_quote') and
      (v_batch.owner_user_id=v_actor or exists(select 1 from public.batch_collaborators bc
        where bc.batch_id=v_batch.id and bc.app_user_id=v_actor and bc.status='active')));
  if v_actor is null or not v_allowed then raise exception 'permission denied' using errcode='42501'; end if;
  if nullif(btrim(p_reason),'') is null then
    raise exception 'withdraw_reason_required' using errcode='PT422';
  end if;
  if v_q.workflow_status<>'approved' or v_batch.status<>'approved' then
    raise exception 'transition not allowed' using errcode='22023';
  end if;
  update public.quote_revisions set workflow_status='draft',withdraw_reason=btrim(p_reason)
   where id=p_revision;
  update public.batches set status='sent' where id=v_batch.id;
  update public.batch_edit_locks set released_at=now() where batch_id=v_batch.id and released_at is null;
  insert into public.quote_workflow_events(revision_id,event_type,actor_user_id,note)
    values(p_revision,'withdrawn',v_actor,btrim(p_reason));
end $fn$;

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
    addressee_name=p_addressee_name,addressee_details=p_addressee_details,
    quote_date=p_quote_date,offer_validity_to=p_offer_validity_to,
    issued_by=v_actor,issued_at=now() where id=p_revision;
  update public.batches set status='issued_locked' where id=v_batch.id;
  update public.batch_edit_locks set released_at=now() where batch_id=v_batch.id and released_at is null;
  insert into public.quote_workflow_events(revision_id,event_type,actor_user_id)
    values(p_revision,'issued',v_actor);
  insert into public.customer_outcome_events(revision_id,outcome,recorded_by)
    values(p_revision,'awaiting_response',v_actor);
end $fn$;

create or replace function app_private.create_quote_revision(p_source_revision bigint)
returns bigint language plpgsql volatile security definer set search_path = '' as $fn$
declare v_q public.quote_revisions%rowtype; v_family public.quote_families%rowtype;
  v_batch public.batches%rowtype; v_actor bigint;
begin
  v_actor:=app_private.current_app_user();
  select * into v_q from public.quote_revisions where id=p_source_revision for update;
  select * into v_family from public.quote_families where id=v_q.family_id for update;
  select * into v_batch from public.batches where id=v_family.batch_id for update;
  if v_actor is null or not app_private.has_plant_cap(v_batch.plant_id,'make_quote')
     or not (v_batch.owner_user_id=v_actor or exists(select 1 from public.batch_collaborators bc
              where bc.batch_id=v_batch.id and bc.app_user_id=v_actor and bc.status='active')) then
    raise exception 'permission denied' using errcode='42501';
  end if;
  if v_q.workflow_status<>'issued' or v_q.standing not in ('current','voided')
     or v_batch.status<>'issued_locked' then
    raise exception 'transition not allowed' using errcode='22023';
  end if;
  if v_q.standing='voided' and exists(select 1 from public.quote_revisions x
      where x.family_id=v_q.family_id and x.workflow_status='issued' and x.standing='current') then
    raise exception 'revision_not_latest' using errcode='PT422';
  end if;
  if exists(select 1 from app_private.pending_quote_revision_sources p where p.batch_id=v_batch.id) then
    raise exception 'revision_already_open' using errcode='PT409';
  end if;
  update public.batches set status='working' where id=v_batch.id;
  update public.batch_edit_locks set released_at=now() where batch_id=v_batch.id and released_at is null;
  perform app_private.acquire_batch_lock(v_batch.id);
  insert into app_private.pending_quote_revision_sources(batch_id,family_id,source_revision_id,created_by)
    values(v_batch.id,v_family.id,p_source_revision,v_actor);
  return v_batch.id;
end $fn$;

create or replace function app_private.void_quote_revision(p_revision bigint,p_reason text)
returns void language plpgsql volatile security definer set search_path = '' as $fn$
declare v_q public.quote_revisions%rowtype; v_batch public.batches%rowtype; v_actor bigint;
begin
  v_actor:=app_private.current_app_user();
  select * into v_q from public.quote_revisions where id=p_revision for update;
  select b.* into v_batch from public.quote_families qf join public.batches b on b.id=qf.batch_id
   where qf.id=v_q.family_id for update of b;
  if v_actor is null or not (app_private.has_plant_cap(v_batch.plant_id,'check_quote')
                             or app_private.has_group_cap('administer_users')) then
    raise exception 'permission denied' using errcode='42501';
  end if;
  if nullif(btrim(p_reason),'') is null then raise exception 'void_reason_required' using errcode='PT422'; end if;
  if v_q.workflow_status<>'issued' or v_q.standing='voided' then
    raise exception 'transition not allowed' using errcode='22023';
  end if;
  update public.quote_revisions set standing='voided',voided_by=v_actor,voided_at=now(),
    void_reason=btrim(p_reason) where id=p_revision;
  insert into public.quote_workflow_events(revision_id,event_type,actor_user_id,note)
    values(p_revision,'voided',v_actor,btrim(p_reason));
end $fn$;

-- Public invoker shims keep auth.uid() authentic; app_private remains unexposed.
create or replace function public.submit_quote_revision(p_revision bigint,p_expected_content_version integer)
returns void language sql volatile set search_path='' as $$select app_private.submit_quote_revision(p_revision,p_expected_content_version)$$;
create or replace function public.return_quote_revision(p_revision bigint,p_note text)
returns void language sql volatile set search_path='' as $$select app_private.return_quote_revision(p_revision,p_note)$$;
create or replace function public.send_revision_batch(p_batch bigint,p_expected_content_version integer)
returns bigint language sql volatile set search_path='' as $$select app_private.send_revision_batch(p_batch,p_expected_content_version)$$;
create or replace function public.approve_quote_revision(p_revision bigint)
returns void language sql volatile set search_path='' as $$select app_private.approve_quote_revision(p_revision)$$;
create or replace function public.withdraw_quote_revision(p_revision bigint,p_reason text)
returns void language sql volatile set search_path='' as $$select app_private.withdraw_quote_revision(p_revision,p_reason)$$;
create or replace function public.issue_quote_revision(p_revision bigint,p_addressee_name text,p_addressee_details jsonb,p_quote_date date,p_offer_validity_to date)
returns void language sql volatile set search_path='' as $$select app_private.issue_quote_revision(p_revision,p_addressee_name,p_addressee_details,p_quote_date,p_offer_validity_to)$$;
create or replace function public.create_quote_revision(p_source_revision bigint)
returns bigint language sql volatile set search_path='' as $$select app_private.create_quote_revision(p_source_revision)$$;
create or replace function public.void_quote_revision(p_revision bigint,p_reason text)
returns void language sql volatile set search_path='' as $$select app_private.void_quote_revision(p_revision,p_reason)$$;

do $grants$
declare r record;
begin
  for r in select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) args
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','app_private') and p.proname in
    ('submit_quote_revision','return_quote_revision','send_revision_batch','approve_quote_revision',
     'withdraw_quote_revision','issue_quote_revision','create_quote_revision','void_quote_revision')
  loop
    execute format('revoke all on function %I.%I(%s) from public,anon',r.nspname,r.proname,r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated',r.nspname,r.proname,r.args);
  end loop;
end $grants$;
