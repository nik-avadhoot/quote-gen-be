-- Customer Pricing History, P0.4: Excel/Sheets paste - bound preview and one atomic apply.
--
-- Successor to 20260923150000_customer_pricing_history_p0_1.sql and
-- 20260923183000_customer_pricing_history_p0_2.sql (must follow both).
-- Authority: quote-gen-fe/docs/customer-pricing-history-phase-0-implementation-plan-2026-09-23.md
-- §7 and §10 P0.4.
--
-- WHAT THIS SLICE ADDS
--   app_private.cph_paste_previews   a server-validated paste batch, bound to its author, its
--                                    Customer, its exact normalised payload (sha-256 digest) and a
--                                    15-minute expiry. NOT in an exposed schema; nobody but the two
--                                    definers below can read or write it.
--   cph_store_paste_preview(party, payload)       re-checks every referenced record's Customer and
--                                                 CAS version, then stores the batch
--   cph_apply_paste(party, preview_id, digest)    applies the WHOLE batch in one transaction
--
-- NO NEW WRITE AUTHORITY. Apply performs every change through the existing P0.1/P0.2 definers
-- (cph_update_cycle, cph_update_line, cph_create_line, cph_add_round, cph_set_bf_override), so
-- their capability checks, CAS, check constraints, snapshot/BF-floor triggers and before/after
-- audit triggers run exactly as for a single edit. Any failure - a stale version, a duplicate
-- scope, a constraint - raises, and the whole batch (including every audit row and the
-- preview's consumed mark) rolls back. There is no partial success.
--
-- BLANK IS NOT ZERO. The payload names only the fields a paste changes; a field absent from
-- `set` keeps its current value. A key present with JSON null is an EXPLICIT clear that the
-- user accepted in the preview. Money is carried as exact two-decimal strings.
--
-- NO HARD DELETE. Previews are never deleted by this code; consumed/expired ones are inert.

-- ───────────────────────────────────────────────────────────── previews
create table app_private.cph_paste_previews (
  id                uuid        primary key default gen_random_uuid(),
  party_id          bigint      not null,
  actor_app_user_id bigint      not null,
  payload           jsonb       not null,
  digest            text        not null,
  op_count          integer     not null,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz not null,
  consumed_at       timestamptz null,
  constraint fk_cpp_party foreign key (party_id) references public.parties(id) on delete restrict,
  constraint fk_cpp_actor foreign key (actor_app_user_id) references public.app_users(id) on delete restrict,
  constraint ck_cpp_payload check (jsonb_typeof(payload) = 'array'),
  constraint ck_cpp_count check (op_count between 1 and 200),
  constraint ck_cpp_expiry check (expires_at > created_at and expires_at <= created_at + interval '30 minutes')
);
create index ix_cpp_party on app_private.cph_paste_previews (party_id);
create index ix_cpp_actor on app_private.cph_paste_previews (actor_app_user_id);

revoke all on app_private.cph_paste_previews from public, anon, authenticated;
alter table app_private.cph_paste_previews enable row level security;
alter table app_private.cph_paste_previews force  row level security;
-- No policy: only the definers below (table owner) touch this table.

-- ─────────────────────────────────────────────── shared payload checks
-- Every op must name a record of THIS Customer at the version the caller read.
-- Used at store time and again at apply time (the apply also re-checks inside
-- each governed definer, under row locks).
create or replace function app_private.cph_paste_check(p_party bigint, p_payload jsonb)
returns void
language plpgsql stable security definer set search_path = '' as $fn$
declare op jsonb; v_kind text; v_party bigint; v_version integer; v_keys text[] := '{}';
        v_targets text[] := '{}'; v_target text;
begin
  if jsonb_typeof(p_payload) is distinct from 'array' then
    raise exception 'the paste payload must be a list of operations' using errcode = '22023';
  end if;
  if jsonb_array_length(p_payload) < 1 or jsonb_array_length(p_payload) > 200 then
    raise exception 'a paste batch carries 1 to 200 changes' using errcode = 'PT413';
  end if;
  for op in select value from jsonb_array_elements(p_payload) loop
    v_kind := op ->> 'op';
    if v_kind in ('update_cycle', 'update_line', 'set_bf_override') and not (op ? 'expected_version') then
      raise exception 'an update must name the version it read' using errcode = '22023';
    end if;
    -- One change per record field: two updates of one Cycle/Line, or two
    -- overrides of one BF grade, would make the result depend on order.
    v_target := case v_kind
      when 'update_cycle' then 'c' || (op ->> 'cycle_id')
      when 'update_line' then 'l' || (op ->> 'line_id')
      when 'set_bf_override' then 'e' || (op ->> 'event_id') || ':' || upper(op ->> 'bf_code') end;
    if v_target is not null then
      if v_target = any (v_targets) then
        raise exception 'a paste batch changes one record only once' using errcode = '22023';
      end if;
      v_targets := v_targets || v_target;
    end if;
    if v_kind = 'update_cycle' then
      select c.party_id, c.content_version into v_party, v_version
        from public.customer_pricing_cycles c where c.id = (op ->> 'cycle_id')::bigint;
    elsif v_kind = 'update_line' then
      select l.party_id, l.content_version into v_party, v_version
        from public.customer_pricing_lines l where l.id = (op ->> 'line_id')::bigint and l.status = 'active';
    elsif v_kind = 'create_line' then
      select c.party_id, null into v_party, v_version
        from public.customer_pricing_cycles c where c.id = (op ->> 'cycle_id')::bigint;
      if coalesce(op ->> 'key', '') = '' or op ->> 'key' = any (v_keys) then
        raise exception 'every new line needs its own key' using errcode = '22023';
      end if;
      v_keys := v_keys || (op ->> 'key');
    elsif v_kind = 'add_round' then
      if op ->> 'line_key' is not null then
        if not (op ->> 'line_key' = any (v_keys)) then
          raise exception 'a round names a new line that is not in this batch' using errcode = '22023';
        end if;
        v_party := p_party; v_version := null;
      else
        select l.party_id, null into v_party, v_version
          from public.customer_pricing_lines l where l.id = (op ->> 'line_id')::bigint and l.status = 'active';
      end if;
      if op ->> 'client_request_id' is null then
        raise exception 'a pasted round needs its idempotency key' using errcode = '22023';
      end if;
    elsif v_kind = 'set_bf_override' then
      select l.party_id, e.content_version into v_party, v_version
        from public.customer_pricing_negotiation_events e
        join public.customer_pricing_lines l on l.id = e.line_id
       where e.id = (op ->> 'event_id')::bigint;
    else
      raise exception 'unknown paste operation' using errcode = '22023';
    end if;
    if v_party is null then
      raise exception 'a pasted change names a record that does not exist' using errcode = 'P0002';
    end if;
    if v_party <> p_party then
      -- Never reveal another Customer's record: same answer as not found.
      raise exception 'a pasted change names a record that does not exist' using errcode = 'P0002';
    end if;
    if op ? 'expected_version' and v_version is distinct from (op ->> 'expected_version')::integer then
      raise exception 'a record changed since the paste was prepared' using errcode = 'PT409';
    end if;
    v_party := null;
  end loop;
end $fn$;

-- ─────────────────────────────────────────────────────────── store
create or replace function app_private.cph_store_paste_preview(p_party bigint, p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id uuid; v_digest text; v_expires timestamptz;
begin
  v_me := app_private.cph_require_editor();
  perform app_private.cph_require_party(p_party);
  perform app_private.cph_paste_check(p_party, p_payload);
  v_digest := encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex');
  v_expires := now() + interval '15 minutes';
  insert into app_private.cph_paste_previews (party_id, actor_app_user_id, payload, digest, op_count, expires_at)
  values (p_party, v_me, p_payload, v_digest, jsonb_array_length(p_payload), v_expires)
  returning id into v_id;
  return jsonb_build_object('preview_id', v_id, 'digest', v_digest, 'expires_at', v_expires,
                            'operations', jsonb_array_length(p_payload));
end $fn$;

-- ─────────────────────────────────────────────────────────── apply
create or replace function app_private.cph_apply_paste(p_party bigint, p_preview uuid, p_digest text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_me bigint; p app_private.cph_paste_previews%rowtype; op jsonb; s jsonb; v jsonb;
  c public.customer_pricing_cycles%rowtype; l public.customer_pricing_lines%rowtype;
  v_keys jsonb := '{}'; v_evver jsonb := '{}'; v_line bigint; v_ver integer; v_n integer := 0;
begin
  v_me := app_private.cph_require_editor();
  perform app_private.cph_require_party(p_party);
  select * into p from app_private.cph_paste_previews where id = p_preview for update;
  if not found or p.party_id <> p_party or p.actor_app_user_id <> v_me then
    -- Another user's or another Customer's preview is not addressable.
    raise exception 'paste preview not found' using errcode = 'P0002';
  end if;
  if p.consumed_at is not null then
    raise exception 'this paste preview was already applied' using errcode = 'PT410';
  end if;
  if p.expires_at <= now() then
    raise exception 'this paste preview expired - prepare it again' using errcode = 'PT410';
  end if;
  if p_digest is distinct from p.digest then
    raise exception 'the reviewed paste does not match the prepared one' using errcode = 'PT412';
  end if;
  perform app_private.cph_paste_check(p_party, p.payload);

  for op in select value from jsonb_array_elements(p.payload) loop
    s := coalesce(op -> 'set', '{}'::jsonb);
    case op ->> 'op'
    when 'update_cycle' then
      select * into c from public.customer_pricing_cycles where id = (op ->> 'cycle_id')::bigint for update;
      perform app_private.cph_update_cycle(c.id, (op ->> 'expected_version')::integer,
        c.period_start, c.period_end, c.initiated_on, c.review_frequency,
        case when s ? 'custom_label' then s ->> 'custom_label' else c.custom_label end,
        c.status,
        case when s ? 'notes' then s ->> 'notes' else c.notes end);
    when 'update_line' then
      select * into l from public.customer_pricing_lines where id = (op ->> 'line_id')::bigint for update;
      perform app_private.cph_update_line(l.id, (op ->> 'expected_version')::integer,
        l.customer_location_id, l.plant_id, l.sku_id,
        case when s ? 'scope_text' then s ->> 'scope_text' else l.scope_text end,
        case when s ? 'sob_state' then s ->> 'sob_state' else l.sob_state end,
        case when s ? 'sob_state' then (s ->> 'sob_pct')::numeric else l.sob_pct end,
        case when s ? 'notes' then s ->> 'notes' else l.notes end);
    when 'create_line' then
      v := app_private.cph_create_line((op ->> 'cycle_id')::bigint,
        (op ->> 'customer_location_id')::bigint, (op ->> 'plant_id')::bigint, (op ->> 'sku_id')::bigint,
        op ->> 'scope_text', coalesce(op ->> 'sob_state', 'not_captured'), (op ->> 'sob_pct')::numeric,
        op ->> 'notes');
      v_keys := v_keys || jsonb_build_object(op ->> 'key', (v ->> 'id')::bigint);
    when 'add_round' then
      v_line := coalesce((op ->> 'line_id')::bigint, (v_keys ->> (op ->> 'line_key'))::bigint);
      perform app_private.cph_add_round(v_line, op ->> 'event_type', (op ->> 'event_date')::date,
        (op ->> 'rate_inr')::numeric, op ->> 'tax_treatment', (op ->> 'gst_pct')::numeric,
        null, null, null, 'excel', null, op ->> 'source_ref', op ->> 'notes',
        (op ->> 'client_request_id')::uuid);
    when 'set_bf_override' then
      -- One round's overrides share its CAS: the first names the version read,
      -- each later one the version the previous override produced.
      v_ver := coalesce((v_evver ->> (op ->> 'event_id'))::integer, (op ->> 'expected_version')::integer);
      v := app_private.cph_set_bf_override((op ->> 'event_id')::bigint, v_ver, op ->> 'bf_code',
        (op ->> 'override_rate_inr')::numeric);
      v_evver := v_evver || jsonb_build_object(op ->> 'event_id', (v ->> 'content_version')::integer);
    end case;
    v_n := v_n + 1;
  end loop;

  update app_private.cph_paste_previews set consumed_at = now() where id = p.id;
  return jsonb_build_object('applied', v_n, 'created_lines', v_keys, 'preview_id', p.id);
end $fn$;

-- ───────────────────────────────────────────────── public invoker wrappers
create or replace function public.cph_store_paste_preview(p_party bigint, p_payload jsonb)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_store_paste_preview(p_party, p_payload);
$fn$;

create or replace function public.cph_apply_paste(p_party bigint, p_preview uuid, p_digest text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_apply_paste(p_party, p_preview, p_digest);
$fn$;

-- ─────────────────────────────────────────────────────────────── grants
do $$
declare f text;
begin
  foreach f in array array['cph_store_paste_preview(bigint,jsonb)', 'cph_apply_paste(bigint,uuid,text)'] loop
    execute format('revoke all on function app_private.%s from public, anon', f);
    execute format('grant execute on function app_private.%s to authenticated', f);
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  execute 'revoke all on function app_private.cph_paste_check(bigint,jsonb) from public, anon, authenticated';
end $$;

-- ────────────────────────────────────────────────────── structural gates
-- Run: select * from tests.cph_p0_4_catalogue();  (every row must be ok)
create or replace function tests.cph_p0_4_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
declare
  v_ops text[] := array['cph_store_paste_preview(bigint,jsonb)', 'cph_apply_paste(bigint,uuid,text)'];
  f text; v_bad text[];
begin
  ok := exists (select 1 from pg_catalog.pg_class k join pg_catalog.pg_namespace n on n.oid = k.relnamespace
                 where n.nspname = 'app_private' and k.relname = 'cph_paste_previews'
                   and k.relrowsecurity and k.relforcerowsecurity)
    and not pg_catalog.has_table_privilege('anon', 'app_private.cph_paste_previews', 'SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('authenticated', 'app_private.cph_paste_previews', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE');
  name := 'CPH4-1 paste previews: unexposed schema, RLS forced, no anon/authenticated table privilege';
  return next;

  v_bad := '{}';
  foreach f in array v_ops loop
    if not pg_catalog.has_function_privilege('authenticated', 'public.' || f, 'EXECUTE')
       or not pg_catalog.has_function_privilege('authenticated', 'app_private.' || f, 'EXECUTE')
       or pg_catalog.has_function_privilege('anon', 'public.' || f, 'EXECUTE')
       or pg_catalog.has_function_privilege('anon', 'app_private.' || f, 'EXECUTE') then
      v_bad := v_bad || f;
    end if;
  end loop;
  ok := cardinality(v_bad) = 0
    and not pg_catalog.has_function_privilege('authenticated', 'app_private.cph_paste_check(bigint,jsonb)', 'EXECUTE');
  name := 'CPH4-2 paste wrappers/definers: authenticated EXECUTE, never anon; the checker is private ' || v_bad::text;
  return next;

  select coalesce(array_agg(p.proname::text), '{}') into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app_private' and p.proname in ('cph_paste_check', 'cph_store_paste_preview', 'cph_apply_paste')
     and (not p.prosecdef or p.proconfig is null
          or not ('search_path=""' = any (p.proconfig) or 'search_path=' = any (p.proconfig)));
  ok := cardinality(v_bad) = 0; name := 'CPH4-3 paste definers pin an empty search_path ' || v_bad::text;
  return next;

  select coalesce(array_agg(c.conname::text), '{}') into v_bad
    from pg_catalog.pg_constraint c
   where c.conrelid = 'app_private.cph_paste_previews'::regclass and c.contype = 'f'
     and not exists (select 1 from pg_catalog.pg_index i where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]);
  ok := cardinality(v_bad) = 0; name := 'CPH4-4 paste preview foreign keys are indexed ' || v_bad::text;
  return next;
end $fn$;
revoke all on function tests.cph_p0_4_catalogue() from public, anon, authenticated;
