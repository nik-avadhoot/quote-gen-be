-- Customer Pricing History, P0.5: the governed "Void negotiation round" journey.
--
-- Successor to 20260923150000 (P0.1), 20260923183000 (P0.2), 20260924044157 (P0.4) and
-- 20260924100057 (P0.4.1); must follow all four. Those are rehearsed but unapplied and are
-- left untouched so their evidence stays valid.
--
-- WHY. customer_pricing_negotiation_events.status has always allowed 'voided', the read model
-- and the timeline show voided rounds, and every compact summary (first offer, latest counter,
-- final agreement) already ignores them - but no governed path could set it. Commercial history
-- is never hard-deleted, so a round entered in error needs a deliberate, audited void.
--
-- WHAT VOIDING DOES
--   * status 'active' -> 'voided' plus a required reason (void_reason, 3-500 characters);
--   * nothing else about the round changes: rate, type, date, sequence, source, notes, tax,
--     components, Stable-Term snapshot and its BF schedule rows are kept exactly;
--   * the ordinary version + audit triggers run, so the change log records who, when and the
--     before/after (status and void_reason) in the same transaction;
--   * a voided round is frozen: correcting it, or setting a BF override on it, is refused
--     (55000 -> ROUND_VOIDED). A new round is how a Customer's position is re-stated.
--   * nothing is restored: voiding a final agreement makes the previous ACTIVE final agreement
--     the current one if there is one, otherwise the line has no agreement. No rate is copied.
-- There is no un-void and no delete.

-- ─────────────────────────────────────────────────────────── the reason
alter table public.customer_pricing_negotiation_events
  add column void_reason text null;

alter table public.customer_pricing_negotiation_events
  add constraint ck_cpe_void_reason check (
    (status = 'voided') = (void_reason is not null)
    and (void_reason is null or char_length(btrim(void_reason)) between 3 and 500));

comment on column public.customer_pricing_negotiation_events.void_reason is
  'Why the round was voided; set only with status = voided. The round itself is kept unchanged.';

-- ─────────────────────────────────────────────── the freeze / status-only guard
-- Fires before the version/audit triggers (alphabetical order: trg_cpe_a_* first).
--   * a voided round cannot be updated at all (correction, BF-override bump, anything);
--   * the one permitted transition is active -> voided, and in that update only status and
--     void_reason may change - enforced here, not trusted to the caller.
create or replace function app_private.cph_event_void_guard()
returns trigger
language plpgsql security definer set search_path = '' as $fn$
declare v_skip text[] := array['status', 'void_reason', 'content_version', 'updated_at', 'updated_by'];
begin
  if old.status = 'voided' then
    raise exception 'this negotiation round is voided - record a new round instead' using errcode = '55000';
  end if;
  if new.status is distinct from old.status then
    if not (old.status = 'active' and new.status = 'voided') then
      raise exception 'a negotiation round can only move from active to voided' using errcode = '22023';
    end if;
    if (to_jsonb(new) - v_skip) is distinct from (to_jsonb(old) - v_skip) then
      raise exception 'voiding a round changes its status only' using errcode = '22023';
    end if;
  end if;
  return new;
end $fn$;

create trigger trg_cpe_a_void_guard before update on public.customer_pricing_negotiation_events
  for each row execute function app_private.cph_event_void_guard();

-- ─────────────────────────────────────────────────────────── the writer
-- p_party is the Customer the caller is looking at; an event of another Customer is answered
-- exactly like a missing one (P0002), never revealed.
create or replace function app_private.cph_void_round(
  p_party bigint, p_event bigint, p_expected_version integer, p_reason text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_party bigint; v_status text; v_current integer; v_version integer; v_reason text;
begin
  perform app_private.cph_require_editor();
  select l.party_id, e.status, e.content_version into v_party, v_status, v_current
    from public.customer_pricing_negotiation_events e
    join public.customer_pricing_lines l on l.id = e.line_id
   where e.id = p_event
     for update of e;
  if not found or v_party is distinct from p_party then
    raise exception 'negotiation event not found' using errcode = 'P0002';
  end if;
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a void needs a reason of 3 to 500 characters' using errcode = '22023';
  end if;
  if v_status = 'voided' then
    raise exception 'this negotiation round is already voided' using errcode = '55000';
  end if;
  if p_expected_version is null or v_current <> p_expected_version then
    raise exception 'the negotiation event changed since you read it (expected %, found %)',
      p_expected_version, v_current using errcode = 'PT409';
  end if;
  update public.customer_pricing_negotiation_events
     set status = 'voided', void_reason = v_reason
   where id = p_event
  returning content_version into v_version;
  return jsonb_build_object('id', p_event, 'content_version', v_version, 'status', 'voided');
end $fn$;

create or replace function public.cph_void_round(
  p_party bigint, p_event bigint, p_expected_version integer, p_reason text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_void_round(p_party, p_event, p_expected_version, p_reason);
$fn$;

-- ─────────────────────────────────────────────────────────────── grants
revoke all on function app_private.cph_void_round(bigint,bigint,integer,text) from public, anon;
grant execute on function app_private.cph_void_round(bigint,bigint,integer,text) to authenticated;
revoke all on function public.cph_void_round(bigint,bigint,integer,text) from public, anon;
grant execute on function public.cph_void_round(bigint,bigint,integer,text) to authenticated;
revoke all on function app_private.cph_event_void_guard() from public, anon, authenticated;

-- ────────────────────────────────────────────────────── structural gates
-- Run: select * from tests.cph_p0_5_catalogue();  (every row must be ok)
create or replace function tests.cph_p0_5_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
begin
  ok := exists (select 1 from pg_catalog.pg_attribute a
                 where a.attrelid = 'public.customer_pricing_negotiation_events'::regclass
                   and a.attname = 'void_reason' and not a.attisdropped and not a.attnotnull)
    and exists (select 1 from pg_catalog.pg_constraint c
                 where c.conrelid = 'public.customer_pricing_negotiation_events'::regclass
                   and c.conname = 'ck_cpe_void_reason' and c.convalidated);
  name := 'CPH5-1 void_reason column and its status/reason check exist';
  return next;

  ok := exists (select 1 from pg_catalog.pg_trigger t
                 where t.tgrelid = 'public.customer_pricing_negotiation_events'::regclass
                   and t.tgname = 'trg_cpe_a_void_guard' and not t.tgisinternal and t.tgenabled <> 'D');
  name := 'CPH5-2 the void guard trigger is enabled on negotiation events';
  return next;

  ok := pg_catalog.has_function_privilege('authenticated', 'public.cph_void_round(bigint,bigint,integer,text)', 'EXECUTE')
    and pg_catalog.has_function_privilege('authenticated', 'app_private.cph_void_round(bigint,bigint,integer,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon', 'public.cph_void_round(bigint,bigint,integer,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon', 'app_private.cph_void_round(bigint,bigint,integer,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated', 'app_private.cph_event_void_guard()', 'EXECUTE')
    and not exists (select 1 from pg_catalog.pg_proc p, aclexplode(p.proacl) a
                     where p.proname in ('cph_void_round', 'cph_event_void_guard') and a.grantee = 0);
  name := 'CPH5-3 void wrapper/definer: authenticated EXECUTE only; guard private; no PUBLIC grant';
  return next;

  ok := not exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'app_private' and p.proname in ('cph_void_round', 'cph_event_void_guard')
                       and (not p.prosecdef or p.proconfig is null
                            or not ('search_path=""' = any (p.proconfig) or 'search_path=' = any (p.proconfig))))
    and exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'cph_void_round' and not p.prosecdef);
  name := 'CPH5-4 void definer pins an empty search_path; the public wrapper is SECURITY INVOKER';
  return next;
end $fn$;
revoke all on function tests.cph_p0_5_catalogue() from public, anon, authenticated;
