-- Customer Pricing History, P0.4.1: Share of Business as an allocated box quantity.
--
-- Successor to 20260924164751_customer_pricing_history_p0_1.sql,
-- 20260924164806_customer_pricing_history_p0_2.sql and
-- 20260924164820_customer_pricing_history_p0_4.sql (must follow all three).
-- Those three are rehearsed and reviewed but unapplied; this correction is kept
-- separate so their evidence stays valid.
--
-- PRODUCT CORRECTION. SOB is not always a percentage: some Customers allocate a
-- fixed number of boxes for the current Pricing Cycle. The Cycle already names
-- the period, so there is deliberately NO allocation frequency or period here.
--
-- SOB STATES (customer_pricing_lines.sob_state) and the ONLY value each carries:
--   not_captured        nothing asked yet            pct NULL, boxes NULL
--   undefined           Customer left it undefined   pct NULL, boxes NULL
--   not_applicable      SOB does not apply           pct NULL, boxes NULL
--   percentage          0.00-100.00 %                pct SET,  boxes NULL
--   allocated_quantity  0-999,999,999 whole boxes    pct NULL, boxes SET
-- 0.00 % and 0 boxes are deliberate values; neither is a blank.
-- `percentage` replaces P0.1's `defined`, which became ambiguous once a box
-- quantity is also a defined SOB.
--
-- WRITE PATH UNCHANGED IN KIND. cph_create_line / cph_update_line gain one
-- parameter (p_sob_allocated_boxes); the old signatures are dropped so no path
-- can write a line without deciding the box value. CAS, the version/audit
-- triggers (to_jsonb before/after, so the new column is audited automatically),
-- read_party_master checks, RLS and no-hard-delete are untouched.
-- cph_apply_paste is re-issued only to pass the new value through; its digest,
-- binding, expiry and one-transaction semantics are unchanged.
--
-- START NEXT CYCLE needs no change: it inserts new lines without SOB columns, so
-- they take sob_state 'not_captured' with both values NULL.

-- ─────────────────────────────────────────── refuse to reinterpret history
-- P0.1-P0.4 have never been applied, so no 'defined' row can exist. If one
-- does, stop: renaming it here would rewrite audited evidence without an actor.
do $$
begin
  if exists (select 1 from public.customer_pricing_lines where sob_state = 'defined') then
    raise exception 'P0.4.1 expects no SOB rows in the P0.1 ''defined'' state; migrate them deliberately first'
      using errcode = '55000';
  end if;
end $$;

-- ─────────────────────────────────────────────────────────── the column
alter table public.customer_pricing_lines
  add column sob_allocated_boxes integer null;

alter table public.customer_pricing_lines
  drop constraint ck_cpl_sob_state,
  drop constraint ck_cpl_sob_pct;

alter table public.customer_pricing_lines
  add constraint ck_cpl_sob_state check (
    sob_state in ('not_captured','undefined','not_applicable','percentage','allocated_quantity')),
  add constraint ck_cpl_sob_boxes check (
    sob_allocated_boxes is null or (sob_allocated_boxes >= 0 and sob_allocated_boxes <= 999999999)),
  -- Exactly the value the state names, and never both.
  add constraint ck_cpl_sob_value check (
    (sob_state = 'percentage'
       and sob_pct is not null and sob_pct >= 0 and sob_pct <= 100 and sob_allocated_boxes is null)
    or (sob_state = 'allocated_quantity' and sob_allocated_boxes is not null and sob_pct is null)
    or (sob_state in ('not_captured','undefined','not_applicable')
       and sob_pct is null and sob_allocated_boxes is null));

comment on column public.customer_pricing_lines.sob_allocated_boxes is
  'Whole boxes the Customer allocated for this line''s Pricing Cycle; set only when sob_state = allocated_quantity. 0 is deliberate.';

-- ─────────────────────────────────────────────── line definers (re-issued)
drop function public.cph_create_line(bigint,bigint,bigint,bigint,text,text,numeric,text);
drop function public.cph_update_line(bigint,integer,bigint,bigint,bigint,text,text,numeric,text);
drop function app_private.cph_create_line(bigint,bigint,bigint,bigint,text,text,numeric,text);
drop function app_private.cph_update_line(bigint,integer,bigint,bigint,bigint,text,text,numeric,text);

create function app_private.cph_create_line(
  p_cycle bigint, p_customer_location bigint, p_plant bigint, p_sku bigint,
  p_scope_text text, p_sob_state text, p_sob_pct numeric, p_sob_allocated_boxes integer, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_party bigint; v_id bigint;
begin
  v_me := app_private.cph_require_editor();
  select c.party_id into v_party from public.customer_pricing_cycles c where c.id = p_cycle;
  if v_party is null then
    raise exception 'pricing Cycle not found' using errcode = 'P0002';
  end if;
  insert into public.customer_pricing_lines (
    cycle_id, party_id, customer_location_id, plant_id, sku_id, scope_text,
    sob_state, sob_pct, sob_allocated_boxes, notes, created_by, updated_by)
  values (p_cycle, v_party, p_customer_location, p_plant, p_sku,
          nullif(btrim(coalesce(p_scope_text, '')), ''),
          coalesce(p_sob_state, 'not_captured'), p_sob_pct, p_sob_allocated_boxes,
          nullif(btrim(coalesce(p_notes, '')), ''), v_me, v_me)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'content_version', 1);
end $fn$;

create function app_private.cph_update_line(
  p_line bigint, p_expected_version integer,
  p_customer_location bigint, p_plant bigint, p_sku bigint,
  p_scope_text text, p_sob_state text, p_sob_pct numeric, p_sob_allocated_boxes integer, p_notes text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_current integer; v_version integer;
begin
  perform app_private.cph_require_editor();
  select l.content_version into v_current
    from public.customer_pricing_lines l where l.id = p_line for update;
  if not found then
    raise exception 'pricing Line not found' using errcode = 'P0002';
  end if;
  if p_expected_version is null or v_current <> p_expected_version then
    raise exception 'the Line changed since you read it (expected %, found %)',
      p_expected_version, v_current using errcode = 'PT409';
  end if;
  update public.customer_pricing_lines set
    customer_location_id = p_customer_location,
    plant_id             = p_plant,
    sku_id               = p_sku,
    scope_text           = nullif(btrim(coalesce(p_scope_text, '')), ''),
    sob_state            = coalesce(p_sob_state, 'not_captured'),
    sob_pct              = p_sob_pct,
    sob_allocated_boxes  = p_sob_allocated_boxes,
    notes                = nullif(btrim(coalesce(p_notes, '')), '')
  where id = p_line
  returning content_version into v_version;
  return jsonb_build_object('id', p_line, 'content_version', v_version);
end $fn$;

create function public.cph_create_line(
  p_cycle bigint, p_customer_location bigint, p_plant bigint, p_sku bigint,
  p_scope_text text, p_sob_state text, p_sob_pct numeric, p_sob_allocated_boxes integer, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_create_line(p_cycle, p_customer_location, p_plant, p_sku,
    p_scope_text, p_sob_state, p_sob_pct, p_sob_allocated_boxes, p_notes);
$fn$;

create function public.cph_update_line(
  p_line bigint, p_expected_version integer,
  p_customer_location bigint, p_plant bigint, p_sku bigint,
  p_scope_text text, p_sob_state text, p_sob_pct numeric, p_sob_allocated_boxes integer, p_notes text)
returns jsonb language sql security invoker set search_path = '' as $fn$
  select app_private.cph_update_line(p_line, p_expected_version, p_customer_location,
    p_plant, p_sku, p_scope_text, p_sob_state, p_sob_pct, p_sob_allocated_boxes, p_notes);
$fn$;

-- ─────────────────────────────────────── paste apply (value pass-through)
-- Identical to P0.4 except that SOB travels as a triple: when a paste names
-- sob_state it also names both values (the one the state carries, the other
-- NULL), so the line never keeps a stale value of the other kind.
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
        case when s ? 'sob_state' then (s ->> 'sob_allocated_boxes')::integer else l.sob_allocated_boxes end,
        case when s ? 'notes' then s ->> 'notes' else l.notes end);
    when 'create_line' then
      v := app_private.cph_create_line((op ->> 'cycle_id')::bigint,
        (op ->> 'customer_location_id')::bigint, (op ->> 'plant_id')::bigint, (op ->> 'sku_id')::bigint,
        op ->> 'scope_text', coalesce(op ->> 'sob_state', 'not_captured'), (op ->> 'sob_pct')::numeric,
        (op ->> 'sob_allocated_boxes')::integer, op ->> 'notes');
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

-- ─────────────────────────────────────────────────────────────── grants
do $$
declare f text;
begin
  foreach f in array array[
    'cph_create_line(bigint,bigint,bigint,bigint,text,text,numeric,integer,text)',
    'cph_update_line(bigint,integer,bigint,bigint,bigint,text,text,numeric,integer,text)']
  loop
    execute format('revoke all on function app_private.%s from public, anon', f);
    execute format('grant execute on function app_private.%s to authenticated', f);
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  -- create or replace keeps cph_apply_paste's existing ACL; restate it anyway.
  execute 'revoke all on function app_private.cph_apply_paste(bigint,uuid,text) from public, anon';
  execute 'grant execute on function app_private.cph_apply_paste(bigint,uuid,text) to authenticated';
end $$;

-- ────────────────────────────────────────────────────── structural gates
-- Run: select * from tests.cph_p0_4_1_catalogue();  (every row must be ok)
create or replace function tests.cph_p0_4_1_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
declare
  v_ops text[] := array[
    'cph_create_line(bigint,bigint,bigint,bigint,text,text,numeric,integer,text)',
    'cph_update_line(bigint,integer,bigint,bigint,bigint,text,text,numeric,integer,text)'];
  f text; v_bad text[];
begin
  ok := exists (select 1 from pg_catalog.pg_attribute a
                 where a.attrelid = 'public.customer_pricing_lines'::regclass
                   and a.attname = 'sob_allocated_boxes' and not a.attisdropped
                   and a.atttypid = 'pg_catalog.int4'::regtype and not a.attnotnull);
  name := 'CPH41-1 customer_pricing_lines.sob_allocated_boxes is a nullable whole number';
  return next;

  select coalesce(array_agg(x), '{}') into v_bad
    from unnest(array['ck_cpl_sob_state','ck_cpl_sob_boxes','ck_cpl_sob_value']) x
   where not exists (select 1 from pg_catalog.pg_constraint c
                      where c.conrelid = 'public.customer_pricing_lines'::regclass
                        and c.conname = x and c.contype = 'c' and c.convalidated);
  ok := cardinality(v_bad) = 0
    and not exists (select 1 from pg_catalog.pg_constraint c
                     where c.conrelid = 'public.customer_pricing_lines'::regclass and c.conname = 'ck_cpl_sob_pct');
  name := 'CPH41-2 SOB state/value checks present and validated; the P0.1 pct-only check is gone ' || v_bad::text;
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
  ok := cardinality(v_bad) = 0;
  name := 'CPH41-3 box-aware line wrappers/definers: authenticated EXECUTE, never anon ' || v_bad::text;
  return next;

  select coalesce(array_agg(n.nspname || '.' || p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')'), '{}')
    into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app_private') and p.proname in ('cph_create_line', 'cph_update_line')
     and pg_catalog.pg_get_function_identity_arguments(p.oid) not like '%p_sob_allocated_boxes integer%';
  ok := cardinality(v_bad) = 0;
  name := 'CPH41-4 no line writer survives that ignores allocated boxes ' || v_bad::text;
  return next;
end $fn$;
revoke all on function tests.cph_p0_4_1_catalogue() from public, anon, authenticated;

-- The P0.1 catalogue names the line writers by signature; re-issue it with the
-- new ones so its CPH-5 gate keeps checking the live functions. Body otherwise
-- identical to P0.1.
create or replace function tests.cph_p0_1_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
declare
  v_tables text[] := array['customer_pricing_mechanisms','customer_pricing_cycles',
    'customer_pricing_lines','customer_pricing_negotiation_events','customer_pricing_change_events'];
  v_ops text[] := array[
    'cph_save_mechanism(bigint,integer,text,text,text,text,text,text)',
    'cph_create_cycle(bigint,date,date,date,text,text,text)',
    'cph_update_cycle(bigint,integer,date,date,date,text,text,text,text)',
    'cph_create_line(bigint,bigint,bigint,bigint,text,text,numeric,integer,text)',
    'cph_update_line(bigint,integer,bigint,bigint,bigint,text,text,numeric,integer,text)',
    'cph_add_event(bigint,text,date,numeric,text,numeric,text,date,text,text,uuid)',
    'cph_correct_event(bigint,integer,text,date,numeric,text,numeric,text,date,text,text)'];
  t text; f text; v_bad text[];
begin
  v_bad := '{}';
  foreach t in array v_tables loop
    if not exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relname = t and c.relrowsecurity and c.relforcerowsecurity) then
      v_bad := v_bad || t;
    end if;
  end loop;
  ok := cardinality(v_bad) = 0; name := 'CPH-1 RLS enabled and forced on every pricing-history table ' || v_bad::text;
  return next;

  v_bad := '{}';
  foreach t in array v_tables loop
    if pg_catalog.has_table_privilege('anon', 'public.' || t, 'SELECT,INSERT,UPDATE,DELETE') then
      v_bad := v_bad || t;
    end if;
  end loop;
  ok := cardinality(v_bad) = 0; name := 'CPH-2 anon holds no table privilege ' || v_bad::text;
  return next;

  v_bad := '{}';
  foreach t in array v_tables loop
    if not pg_catalog.has_table_privilege('authenticated', 'public.' || t, 'SELECT')
       or pg_catalog.has_table_privilege('authenticated', 'public.' || t, 'INSERT,UPDATE,DELETE,TRUNCATE') then
      v_bad := v_bad || t;
    end if;
  end loop;
  ok := cardinality(v_bad) = 0;
  name := 'CPH-3 authenticated may SELECT but never write directly (CAS/audit cannot be bypassed) ' || v_bad::text;
  return next;

  -- Every SELECT policy carries the real predicate, not bare TO authenticated.
  select coalesce(array_agg(p.tablename::text), '{}') into v_bad
    from pg_catalog.pg_policies p
   where p.schemaname = 'public' and p.tablename = any (v_tables)
     and (p.cmd <> 'SELECT' or p.qual not like '%read_party_master%' or 'anon' = any (p.roles)
          or 'public' = any (p.roles));
  ok := cardinality(v_bad) = 0
    and (select count(*) from pg_catalog.pg_policies p
          where p.schemaname = 'public' and p.tablename = any (v_tables)) = cardinality(v_tables);
  name := 'CPH-4 exactly one SELECT policy per table, gated by read_party_master ' || v_bad::text;
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
  ok := cardinality(v_bad) = 0;
  name := 'CPH-5 wrappers and their definers are executable by authenticated and never by anon ' || v_bad::text;
  return next;

  -- Every foreign-key column is covered by an index whose leading column matches.
  select coalesce(array_agg(format('%s.%s', c.conrelid::regclass, c.conname)), '{}') into v_bad
    from pg_catalog.pg_constraint c
   where c.contype = 'f' and c.conrelid::regclass::text = any (
           select 'customer_pricing_' || x from unnest(array['mechanisms','cycles','lines',
             'negotiation_events','change_events']) x
           union select 'public.customer_pricing_' || x from unnest(array['mechanisms','cycles','lines',
             'negotiation_events','change_events']) x)
     and not exists (select 1 from pg_catalog.pg_index i
                      where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]);
  ok := cardinality(v_bad) = 0; name := 'CPH-6 every foreign key has a covering index ' || v_bad::text;
  return next;

  select coalesce(array_agg(p.proname::text), '{}') into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app_private' and p.proname like 'cph\_%'
     and (not p.prosecdef or p.proconfig is null
          or not ('search_path=""' = any (p.proconfig) or 'search_path=' = any (p.proconfig)));
  ok := cardinality(v_bad) = 0; name := 'CPH-7 every private definer pins an empty search_path ' || v_bad::text;
  return next;
end $fn$;
revoke all on function tests.cph_p0_1_catalogue() from public, anon, authenticated;
