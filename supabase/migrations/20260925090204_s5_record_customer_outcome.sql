-- S5 Slice C: record a customer response against an issued Quote revision.
--
-- Reuses the existing append-only customer_outcome_events table (CDM-28) -
-- no parallel mutable status column. Two automatic 'awaiting_response' rows
-- are already inserted by issue_quote_revision / share_quote_revision; this
-- migration adds the ONLY path by which a human can append accepted,
-- rejected, expired or a later awaiting_response correction. It never
-- updates or deletes a prior event, and outcome and standing stay
-- independent: this function never touches quote_revisions.standing or
-- workflow_status.
--
-- AUTHORIZATION (DM-105): the Quote OWNER Maker (not any active collaborator
-- with make_quote - a collaborator may edit rows but does not hold customer-
-- response authority), an authorised Checker for the Batch's Plant, or Admin
-- correction authority (administer_users) may record an outcome. Wrong-plant
-- and unauthorised callers are refused before any write. Only a revision
-- that has actually been issued
-- (workflow_status='issued', any standing - superseded/voided revisions
-- keep their response history recordable, matching "late acceptance may
-- follow Rejected or Expired" and "superseding must not erase response
-- history") may receive an outcome.

create or replace function app_private.record_customer_outcome(
  p_revision bigint, p_outcome text, p_acceptance_date date,
  p_acceptance_reference text, p_note text)
returns bigint
language plpgsql volatile security definer set search_path = '' as $fn$
declare
  v_q public.quote_revisions%rowtype;
  v_batch public.batches%rowtype;
  v_actor bigint;
  v_allowed boolean;
  v_reference text;
  v_note text;
  v_id bigint;
begin
  v_actor := app_private.current_app_user();
  select * into v_q from public.quote_revisions where id = p_revision for update;
  if v_q.id is null then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  select b.* into v_batch from public.quote_families qf join public.batches b on b.id = qf.batch_id
   where qf.id = v_q.family_id for update of b;

  -- DM-105: owner Maker only - a collaborator is deliberately excluded even
  -- with active make_quote, because collaboration on rows is not the same
  -- authority as speaking for the Quote to the customer.
  v_allowed := app_private.has_plant_cap(v_batch.plant_id, 'check_quote')
    or app_private.has_group_cap('administer_users')
    or (app_private.has_plant_cap(v_batch.plant_id, 'make_quote')
        and v_batch.owner_user_id = v_actor);
  if v_actor is null or not v_allowed then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  if p_outcome not in ('awaiting_response', 'accepted', 'rejected', 'expired') then
    raise exception 'outcome_invalid' using errcode = 'PT422';
  end if;
  if v_q.workflow_status <> 'issued' then
    raise exception 'revision_not_issued' using errcode = 'PT422';
  end if;

  v_reference := nullif(btrim(coalesce(p_acceptance_reference, '')), '');
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if v_reference is not null and length(v_reference) > 200 then
    raise exception 'acceptance_reference_too_long' using errcode = 'PT422';
  end if;
  if v_note is not null and length(v_note) > 2000 then
    raise exception 'note_too_long' using errcode = 'PT422';
  end if;
  -- acceptance date/reference are optional evidence for Accepted only; they
  -- must not be silently attached to an unrelated outcome.
  if p_outcome <> 'accepted' and (p_acceptance_date is not null or v_reference is not null) then
    raise exception 'acceptance_fields_require_accepted' using errcode = 'PT422';
  end if;

  insert into public.customer_outcome_events(
    revision_id, outcome, acceptance_date, acceptance_reference, note, recorded_by)
    values (p_revision, p_outcome, p_acceptance_date, v_reference, v_note, v_actor)
  returning id into v_id;

  return v_id;
end $fn$;

create or replace function public.record_customer_outcome(
  p_revision bigint, p_outcome text, p_acceptance_date date,
  p_acceptance_reference text, p_note text)
returns bigint language sql volatile set search_path = '' as $$
  select app_private.record_customer_outcome(
    p_revision, p_outcome, p_acceptance_date, p_acceptance_reference, p_note)
$$;

revoke all on function app_private.record_customer_outcome(bigint, text, date, text, text)
  from public, anon, authenticated;
revoke all on function public.record_customer_outcome(bigint, text, date, text, text)
  from public, anon;
grant execute on function public.record_customer_outcome(bigint, text, date, text, text) to authenticated;

do $verify$
begin
  if has_function_privilege('anon', 'public.record_customer_outcome(bigint,text,date,text,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'app_private.record_customer_outcome(bigint,text,date,text,text)', 'EXECUTE') then
    raise exception 'S5 record_customer_outcome grants are not narrow' using errcode = '55000';
  end if;
end $verify$;

-- S5 Slice A: resolve the exact prior Quote for the governed Batch workspace.
--
-- Two-step authority, never guessed from the frontend:
--   1. if this Batch was reopened through Create Revision, the stashed
--      pending_quote_revision_sources row names the exact source revision -
--      that always wins (D-6's own explicit carve-out) and no search runs;
--   2. otherwise, the latest ISSUED revision for the Batch's own exact
--      customer_party_id + plant_id (never Family-level, never cross-plant),
--      excluding the current Batch's own Family so a not-yet-issued Batch
--      never matches itself.
-- Read-only (stable). Gated by the existing can_read_batch predicate, so it
-- never widens what the caller could already see through the Batch.
create or replace function app_private.resolve_batch_prior_quote(p_batch bigint)
returns table(
  revision_id bigint,
  family_id bigint,
  quote_reference text,
  revision_no integer,
  workflow_status text,
  standing text,
  quote_date date,
  offer_validity_to date,
  issued_at timestamptz,
  source_kind text,
  latest_outcome text,
  latest_outcome_at timestamptz,
  current_revision_id bigint
)
language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_batch public.batches%rowtype;
  v_own_family_id bigint;
  v_pending app_private.pending_quote_revision_sources%rowtype;
  v_current_revision_id bigint;
begin
  if not app_private.can_read_batch(p_batch) then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into v_batch from public.batches where id = p_batch;
  select id into v_own_family_id from public.quote_families where batch_id = p_batch;
  select * into v_pending from app_private.pending_quote_revision_sources where batch_id = p_batch;

  -- The Batch's OWN current frozen revision, if one exists. Frontend uses
  -- this (never a guess) to decide whether "Open and compare" can honestly
  -- offer a comparison, or only "Open prior Quote" is truthful.
  if v_own_family_id is not null then
    select qr.id into v_current_revision_id from public.quote_revisions qr
     where qr.family_id = v_own_family_id and qr.workflow_status = 'issued'
       and qr.standing = 'current'
     order by qr.revision_no desc nulls last, qr.id desc limit 1;
  end if;

  if v_pending.source_revision_id is not null then
    return query
      select qr.id, qr.family_id, qf.quote_reference, qr.revision_no, qr.workflow_status,
             qr.standing, qr.quote_date, qr.offer_validity_to, qr.issued_at,
             'exact_source_revision'::text, oc.outcome, oc.occurred_at, v_current_revision_id
        from public.quote_revisions qr
        join public.quote_families qf on qf.id = qr.family_id
        left join lateral (
          select coe.outcome, coe.occurred_at from public.customer_outcome_events coe
           where coe.revision_id = qr.id order by coe.occurred_at desc, coe.id desc limit 1
        ) oc on true
       where qr.id = v_pending.source_revision_id;
    return;
  end if;

  if v_batch.id is null or v_batch.customer_party_id is null then
    return;
  end if;

  return query
    select qr.id, qr.family_id, qf.quote_reference, qr.revision_no, qr.workflow_status,
           qr.standing, qr.quote_date, qr.offer_validity_to, qr.issued_at,
           'last_quote_customer_plant'::text, oc.outcome, oc.occurred_at, v_current_revision_id
      from public.quote_revisions qr
      join public.quote_families qf on qf.id = qr.family_id
      join public.batches b on b.id = qf.batch_id
      left join lateral (
        select coe.outcome, coe.occurred_at from public.customer_outcome_events coe
         where coe.revision_id = qr.id order by coe.occurred_at desc, coe.id desc limit 1
      ) oc on true
     where b.customer_party_id = v_batch.customer_party_id
       and b.plant_id = v_batch.plant_id
       and qr.workflow_status = 'issued'
       and (v_own_family_id is null or qr.family_id <> v_own_family_id)
     order by qr.issued_at desc nulls last, qr.id desc
     limit 1;
end $fn$;

create or replace function public.resolve_batch_prior_quote(p_batch bigint)
returns table(
  revision_id bigint, family_id bigint, quote_reference text, revision_no integer,
  workflow_status text, standing text, quote_date date, offer_validity_to date,
  issued_at timestamptz, source_kind text, latest_outcome text, latest_outcome_at timestamptz,
  current_revision_id bigint
) language sql stable set search_path = '' as $$
  select * from app_private.resolve_batch_prior_quote(p_batch)
$$;

revoke all on function app_private.resolve_batch_prior_quote(bigint) from public, anon, authenticated;
revoke all on function public.resolve_batch_prior_quote(bigint) from public, anon;
grant execute on function public.resolve_batch_prior_quote(bigint) to authenticated;

do $verify_prior$
begin
  if has_function_privilege('anon', 'public.resolve_batch_prior_quote(bigint)', 'EXECUTE')
     or has_function_privilege('authenticated', 'app_private.resolve_batch_prior_quote(bigint)', 'EXECUTE') then
    raise exception 'S5 resolve_batch_prior_quote grants are not narrow' using errcode = '55000';
  end if;
end $verify_prior$;
