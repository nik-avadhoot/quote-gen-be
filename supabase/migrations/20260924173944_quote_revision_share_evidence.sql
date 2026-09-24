-- S4: a customer share is an attributed business event, not a download.
-- This migration is deliberately additive and remains unapplied until the
-- controlled S1-S5 activation window.  The event is immutable: application
-- roles can read it only through the existing revision RLS boundary and every
-- write goes through the one caller-bound RPC below.

create table public.quote_share_events (
  id                 bigint      generated always as identity primary key,
  revision_id        bigint      not null,
  channel            text        not null,
  shared_on          date        not null,
  external_reference text        null,
  shared_by          bigint      not null,
  occurred_at        timestamptz not null default now(),
  constraint fk_qse_revision foreign key (revision_id)
    references public.quote_revisions(id) on delete restrict,
  constraint fk_qse_shared_by foreign key (shared_by)
    references public.app_users(id) on delete restrict,
  constraint uk_qse_revision unique (revision_id),
  constraint ck_qse_channel check (channel in
    ('Email','WhatsApp','Printed/hand-delivered','Customer portal','Other')),
  constraint ck_qse_external_reference check (
    external_reference is null or length(btrim(external_reference)) between 1 and 200)
);
create index ix_qse_shared_by on public.quote_share_events(shared_by);

grant select on public.quote_share_events to authenticated;
revoke all on public.quote_share_events from public, anon;
revoke insert, update, delete, truncate on public.quote_share_events from authenticated;
alter table public.quote_share_events enable row level security;
alter table public.quote_share_events force row level security;
create policy quote_share_events_select on public.quote_share_events
  for select to authenticated
  using ((select app_private.can_read_quote_revision(revision_id)));

create or replace function app_private.share_quote_revision(
  p_revision bigint, p_channel text, p_shared_on date, p_external_reference text)
returns void language plpgsql volatile security definer set search_path = '' as $fn$
declare
  v_q public.quote_revisions%rowtype;
  v_batch public.batches%rowtype;
  v_actor bigint;
  v_prior bigint;
  v_channel text := nullif(btrim(p_channel), '');
  v_reference text := nullif(btrim(p_external_reference), '');
begin
  v_actor := app_private.current_app_user();
  select qr.* into v_q from public.quote_revisions qr where qr.id = p_revision for update;
  select b.* into v_batch from public.quote_families qf
    join public.batches b on b.id = qf.batch_id
    where qf.id = v_q.family_id for update of b;

  if v_actor is null or v_q.id is null
     or not app_private.has_plant_cap(v_batch.plant_id, 'make_quote')
     or not (v_batch.owner_user_id = v_actor or exists (
       select 1 from public.batch_collaborators bc
        where bc.batch_id = v_batch.id and bc.app_user_id = v_actor and bc.status = 'active')) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_channel is null or v_channel not in
       ('Email','WhatsApp','Printed/hand-delivered','Customer portal','Other') then
    raise exception 'share_channel_invalid' using errcode = 'PT422';
  end if;
  if p_shared_on is null then
    raise exception 'share_date_required' using errcode = 'PT422';
  end if;
  if v_reference is not null and length(v_reference) > 200 then
    raise exception 'share_reference_invalid' using errcode = 'PT422';
  end if;
  if v_q.workflow_status <> 'approved' or v_batch.status <> 'approved'
     or v_q.standing in ('superseded', 'voided') then
    raise exception 'transition not allowed' using errcode = '22023';
  end if;
  if nullif(btrim(v_q.addressee_name), '') is null
     or coalesce(v_q.addressee_details->>'identity_authority', '') <> 'batches.customer_party_id'
     or nullif(v_q.addressee_details->>'party_id', '') is null then
    raise exception 'exact_recipient_identity_unavailable' using errcode = 'PT422';
  end if;
  if exists (select 1 from public.quote_share_events e where e.revision_id = p_revision) then
    raise exception 'revision_already_shared' using errcode = 'PT409';
  end if;

  select qr.id into v_prior from public.quote_revisions qr
   where qr.family_id = v_q.family_id and qr.id <> p_revision
     and qr.workflow_status = 'issued' and qr.standing = 'current'
   order by qr.revision_no desc limit 1 for update;
  if v_prior is not null then
    update public.quote_revisions set standing = 'superseded' where id = v_prior;
    insert into public.quote_workflow_events(revision_id, event_type, actor_user_id)
      values(v_prior, 'superseded', v_actor);
  end if;

  -- The transition and the evidence are intentionally in this same function:
  -- a refusal rolls back both, and a successful response cannot mean only one.
  update public.quote_revisions
     set workflow_status = 'issued', standing = 'current',
         quote_date = coalesce(quote_date, p_shared_on),
         issued_by = v_actor, issued_at = now()
   where id = p_revision;
  insert into public.quote_share_events(
    revision_id, channel, shared_on, external_reference, shared_by)
    values (p_revision, v_channel, p_shared_on, v_reference, v_actor);
  update public.batches set status = 'issued_locked' where id = v_batch.id;
  update public.batch_edit_locks set released_at = now()
    where batch_id = v_batch.id and released_at is null;
  insert into public.quote_workflow_events(revision_id, event_type, actor_user_id, note)
    values(p_revision, 'issued', v_actor, 'shared_with_customer');
  insert into public.customer_outcome_events(revision_id, outcome, recorded_by)
    values(p_revision, 'awaiting_response', v_actor);
end $fn$;

create or replace function public.share_quote_revision(
  p_revision bigint, p_channel text, p_shared_on date, p_external_reference text)
returns void language sql volatile set search_path = '' as $$
  select app_private.share_quote_revision(p_revision, p_channel, p_shared_on, p_external_reference)
$$;

-- Retire the pre-S4 RPC that could mark a revision issued without the required
-- channel/date evidence.  The private historical helper remains inaccessible.
revoke all on function public.issue_quote_revision(bigint,text,jsonb,date,date)
  from public, anon, authenticated;
revoke all on function app_private.issue_quote_revision(bigint,text,jsonb,date,date)
  from public, anon, authenticated;
revoke all on function app_private.share_quote_revision(bigint,text,date,text)
  from public, anon, authenticated;
revoke all on function public.share_quote_revision(bigint,text,date,text)
  from public, anon;
grant execute on function public.share_quote_revision(bigint,text,date,text) to authenticated;

do $verify$
begin
  if has_function_privilege('anon', 'public.share_quote_revision(bigint,text,date,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'app_private.share_quote_revision(bigint,text,date,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.issue_quote_revision(bigint,text,jsonb,date,date)', 'EXECUTE') then
    raise exception 'S4 share RPC grants are not narrow' using errcode = '55000';
  end if;
end $verify$;
