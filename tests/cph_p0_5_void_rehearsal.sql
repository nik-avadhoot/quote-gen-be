-- ═════ P0.5 VOID-ROUND REHEARSAL TAIL: always ends in RAISE, so the whole batch rolls back ═════
-- Run as ONE batch immediately after the text of the complete chain:
--   supabase/migrations/20260923150000_customer_pricing_history_p0_1.sql
--   supabase/migrations/20260923183000_customer_pricing_history_p0_2.sql
--   supabase/migrations/20260924044157_customer_pricing_history_p0_4.sql
--   supabase/migrations/20260924100057_customer_pricing_history_p0_4_1_sob_allocated_boxes.sql
--   supabase/migrations/20260924153827_customer_pricing_history_p0_5_void_round.sql
-- Rows are synthetic and rolled back; no real Customer commercial value is read or written.
create function pg_temp.try(p_role text, p_sub text, p_sql text) returns text
language plpgsql as $fn$
begin
  begin
    perform set_config('request.jwt.claims', case when p_sub is null then json_build_object('role', p_role)::text
      else json_build_object('sub', p_sub, 'role', p_role)::text end, true);
    execute format('set local role %I', p_role);
    execute p_sql;
    execute 'reset role';
    return 'OK';
  exception when others then
    return sqlstate;
  end;
end $fn$;

create function pg_temp.fingerprint() returns jsonb
language plpgsql as $fn$
declare r record; v text; out jsonb := '{}';
begin
  for r in select n.nspname, c.relname from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
            where n.nspname in ('public', 'app_private') and c.relkind in ('r', 'p')
              and c.relname not like 'customer\_pricing\_%' and c.relname not like 'cph\_%'
            order by 1, 2 loop
    begin
      execute format('select md5(coalesce(string_agg(t::text, %L order by t::text), %L)) from %I.%I t',
                     E'\n', '', r.nspname, r.relname) into v;
    exception when others then v := 'unreadable ' || sqlstate;
    end;
    out := out || jsonb_build_object(r.nspname || '.' || r.relname, v);
  end loop;
  return out;
end $fn$;

do $rehearseV$
declare
  log text := ''; fails int := 0; checks int := 0;
  a_uid text := '79ea4710-1d3b-45b7-9dca-a2dc83503c2b';   -- app user 44, read_party_master
  x_uid text := '39ff307e-504e-4f24-a6e8-5308efb59570';   -- app user 3440, NO read_party_master
  r record; v jsonb; v_t text; v_n int; v_n2 int; fp_before jsonb; fp_after jsonb;
  v_bf bigint; v_cycle bigint; v_line bigint; v_offer bigint; v_counter bigint; v_final1 bigint; v_final2 bigint;
  v_other_ev bigint; v_ver int; v_before jsonb; v_bf_before text; v_events int; v_prev jsonb;
  skip text[] := array['status', 'void_reason', 'content_version', 'updated_at', 'updated_by'];
begin
  for r in select * from tests.cph_p0_1_catalogue() union all select * from tests.cph_p0_2_catalogue()
           union all select * from tests.cph_p0_4_catalogue() union all select * from tests.cph_p0_4_1_catalogue()
           union all select * from tests.cph_p0_5_catalogue() loop
    checks := checks + 1;
    if not r.ok then fails := fails + 1; log := log || E'\nFAIL ' || r.name; else log := log || E'\nok   ' || r.name; end if;
  end loop;
  fp_before := pg_temp.fingerprint();

  -- ── setup as persona A: a BF-scheduled line with offer, counter and two final agreements
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.cph_save_mechanism(245, null, 'monthly', 'financial_year', 'kraft_paper_per_kg', 'paper_consumed', 'excluding_gst', null);
  v_bf := (public.cph_create_bf_delta_set(245, null, null, '2026-04-01', null, false, '18',
           '[{"bf_code":"16","delta_inr":"-1.00"},{"bf_code":"20","delta_inr":"1.50"}]'::jsonb, null, null, null, null)->>'id')::bigint;
  v_cycle := (public.cph_create_cycle(245, '2026-09-01', '2026-09-30', '2026-08-24', null, null, null)->>'id')::bigint;
  v_line := (public.cph_create_line(v_cycle, null, null, null, 'Main', 'not_captured', null, null, null)->>'id')::bigint;
  select content_version into v_ver from public.customer_pricing_lines where id = v_line;
  perform public.cph_set_line_references(v_line, v_ver, null, v_bf);
  v_offer := (public.cph_add_round(v_line, 'avadhoot_offer', '2026-08-25', 56.00, null, null, null, null, null,
              'email', '2026-08-25', 'offer mail', 'first', gen_random_uuid())->>'id')::bigint;
  v_counter := (public.cph_add_round(v_line, 'customer_counter', '2026-08-26', 52.00, null, null, null, null, null,
              'call', null, null, null, gen_random_uuid())->>'id')::bigint;
  v_final1 := (public.cph_add_round(v_line, 'final_agreement', '2026-08-28', 54.00, null, null, null, null, null,
              'meeting', null, null, null, gen_random_uuid())->>'id')::bigint;
  v_final2 := (public.cph_add_round(v_line, 'final_agreement', '2026-08-30', 54.25, null, null, 45.00, 8.00, 1.25,
              'email', '2026-08-30', 'agreement mail', 'final', gen_random_uuid())->>'id')::bigint;
  select content_version into v_ver from public.customer_pricing_negotiation_events where id = v_final2;
  perform public.cph_set_bf_override(v_final2, v_ver, '20', 56.00);
  perform public.cph_save_mechanism(315, null, 'monthly', 'financial_year', null, null, 'excluding_gst', null);
  v_prev := public.cph_create_cycle(315, '2026-09-01', '2026-09-30', '2026-08-24', null, null, null);
  v_other_ev := (public.cph_add_round((public.cph_create_line((v_prev->>'id')::bigint, null, null, null, 'Other', 'not_captured', null, null, null)->>'id')::bigint,
                 'avadhoot_offer', '2026-08-25', 10.00, null, null, null, null, null, null, null, null, null, gen_random_uuid())->>'id')::bigint;
  execute 'reset role';

  -- ── 1. anonymous and no-capability callers are refused
  v_t := pg_temp.try('anon', null, format('select public.cph_void_round(245, %s, 1, %L)', v_final2, 'wrong line'));
  checks := checks + 1; if v_t <> '42501' then fails := fails + 1; end if;
  log := log || case when v_t = '42501' then E'\nok   ' else E'\nFAIL ' end || 'anon void refused ' || v_t;
  v_t := pg_temp.try('authenticated', x_uid, format('select public.cph_void_round(245, %s, 1, %L)', v_final2, 'wrong line'));
  checks := checks + 1; if v_t <> '42501' then fails := fails + 1; end if;
  log := log || case when v_t = '42501' then E'\nok   ' else E'\nFAIL ' end || 'no-capability void refused ' || v_t;

  -- ── 2. another Customer's event cannot be addressed (either direction answers not found)
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_void_round(245, %s, 1, %L)', v_other_ev, 'wrong line'))
      || '/' || pg_temp.try('authenticated', a_uid, format('select public.cph_void_round(315, %s, %s, %L)', v_final2,
                 (select content_version from public.customer_pricing_negotiation_events where id = v_final2), 'wrong line'));
  checks := checks + 1; if v_t <> 'P0002/P0002' then fails := fails + 1; end if;
  log := log || case when v_t = 'P0002/P0002' then E'\nok   ' else E'\nFAIL ' end || 'another Customer''s event, or this event through another Customer, answers not found ' || v_t;

  -- ── 3. missing / blank / short / overlong reason refused in the database too
  select content_version into v_ver from public.customer_pricing_negotiation_events where id = v_final2;
  v_t := '';
  foreach v_prev in array array['null'::jsonb, '"   "'::jsonb, '"ab"'::jsonb, to_jsonb(repeat('x', 501))] loop
    v_t := v_t || pg_temp.try('authenticated', a_uid, format('select public.cph_void_round(245, %s, %s, %L)', v_final2, v_ver,
             case when v_prev = 'null'::jsonb then null else v_prev #>> '{}' end)) || ' ';
  end loop;
  checks := checks + 1; if v_t <> '22023 22023 22023 22023 ' then fails := fails + 1; end if;
  log := log || case when v_t = '22023 22023 22023 22023 ' then E'\nok   ' else E'\nFAIL ' end || 'missing/blank/2-char/501-char reason refused: ' || v_t;

  -- ── 7. stale CAS writes no event change and no audit row
  select count(*) into v_n from public.customer_pricing_change_events;
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_void_round(245, %s, %s, %L)', v_final2, v_ver + 1, 'wrong line'));
  select count(*) into v_n2 from public.customer_pricing_change_events;
  checks := checks + 1;
  if v_t <> 'PT409' or v_n2 <> v_n or (select status from public.customer_pricing_negotiation_events where id = v_final2) <> 'active' then fails := fails + 1; end if;
  log := log || case when v_t = 'PT409' and v_n2 = v_n then E'\nok   ' else E'\nFAIL ' end || 'stale void refused ' || v_t || ', audit delta ' || (v_n2 - v_n) || ', round still active';

  -- ── 6. mutation and audit commit or roll back together
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.cph_void_round(245, v_final2, v_ver, 'rolled back with its audit');
    raise exception 'force the enclosing block to roll back' using errcode = 'P0001';
  exception when others then
    execute 'reset role';
  end;
  select count(*) into v_n2 from public.customer_pricing_change_events;
  checks := checks + 1;
  if v_n2 <> v_n or (select status from public.customer_pricing_negotiation_events where id = v_final2) <> 'active' then fails := fails + 1; end if;
  log := log || case when v_n2 = v_n then E'\nok   ' else E'\nFAIL ' end || 'a void whose transaction fails leaves neither the status change nor its audit row (delta ' || (v_n2 - v_n) || ')';

  -- ── 4/5. correct id + CAS: status only; rate/date/type/source/notes/snapshot and BF rows kept; audited
  select to_jsonb(e) into v_before from public.customer_pricing_negotiation_events e where id = v_final2;
  select string_agg(bf_code || ':' || delta_inr || ':' || coalesce(override_rate_inr::text, '-') || ':' || content_version, ' ' order by bf_code)
    into v_bf_before from public.customer_pricing_event_bf_rates where event_id = v_final2;
  select count(*) into v_events from public.customer_pricing_negotiation_events where line_id = v_line;
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v := public.cph_void_round(245, v_final2, v_ver, '  Entered against the wrong line  ');
  execute 'reset role';
  checks := checks + 1;
  if (v->>'status') <> 'voided' or (v->>'content_version')::int <> v_ver + 1 then fails := fails + 1; end if;
  log := log || case when (v->>'status') = 'voided' then E'\nok   ' else E'\nFAIL ' end || 'void returns ' || v::text;
  select case when (to_jsonb(e) - skip) = (v_before - skip) then 'kept' else 'CHANGED' end || ':' || e.status || ':' || e.void_reason
    into v_t from public.customer_pricing_negotiation_events e where id = v_final2;
  checks := checks + 1; if v_t <> 'kept:voided:Entered against the wrong line' then fails := fails + 1; end if;
  log := log || case when v_t = 'kept:voided:Entered against the wrong line' then E'\nok   ' else E'\nFAIL ' end
    || 'every other column (rate, type, date, sequence, source, notes, components, snapshot) unchanged; reason trimmed: ' || v_t;
  select string_agg(bf_code || ':' || delta_inr || ':' || coalesce(override_rate_inr::text, '-') || ':' || content_version, ' ' order by bf_code)
    into v_t from public.customer_pricing_event_bf_rates where event_id = v_final2;
  checks := checks + 1; if v_t is distinct from v_bf_before then fails := fails + 1; end if;
  log := log || case when v_t = v_bf_before then E'\nok   ' else E'\nFAIL ' end || 'BF snapshot rows kept exactly (incl. the override): ' || coalesce(v_t, '∅');
  select count(*) into v_n2 from public.customer_pricing_negotiation_events where line_id = v_line;
  checks := checks + 1; if v_n2 <> v_events then fails := fails + 1; end if;
  log := log || case when v_n2 = v_events then E'\nok   ' else E'\nFAIL ' end || 'no round added or removed (' || v_n2 || '); nothing restored as a new decision';
  select string_agg(sequence_no || ':' || event_type || ':' || status, ',' order by event_date, sequence_no) into v_t
    from public.customer_pricing_negotiation_events where line_id = v_line;
  checks := checks + 1;
  if v_t <> '1:avadhoot_offer:active,2:customer_counter:active,3:final_agreement:active,4:final_agreement:voided' then fails := fails + 1; end if;
  log := log || case when v_t = '1:avadhoot_offer:active,2:customer_counter:active,3:final_agreement:active,4:final_agreement:voided' then E'\nok   ' else E'\nFAIL ' end
    || 'chronology and numbering kept; the previous final agreement (#3) is the latest ACTIVE one: ' || v_t;
  select e.operation || ':' || (e.before_state->>'status') || '>' || (e.after_state->>'status') || ':' || coalesce(e.after_state->>'void_reason', '∅')
         || ':actor ' || e.actor_app_user_id
    into v_t from public.customer_pricing_change_events e
   where e.entity_type = 'negotiation_event' and e.entity_id = v_final2 order by e.id desc limit 1;
  checks := checks + 1; if v_t <> 'update:active>voided:Entered against the wrong line:actor 44' then fails := fails + 1; end if;
  log := log || case when v_t = 'update:active>voided:Entered against the wrong line:actor 44' then E'\nok   ' else E'\nFAIL ' end
    || 'audit before/after shows the status change, the reason and the actor: ' || coalesce(v_t, 'NONE');

  -- ── 8/11. a voided round is frozen: re-void, correct, BF override (API and owner) all refused, no audit
  select content_version into v_ver from public.customer_pricing_negotiation_events where id = v_final2;
  select count(*) into v_n from public.customer_pricing_change_events;
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_void_round(245, %s, %s, %L)', v_final2, v_ver, 'again'))
      || '/' || pg_temp.try('authenticated', a_uid, format('select public.cph_correct_round(%s, %s, %L, %L, 1.00, null, null, null, null, null, null, null, null, null)',
                 v_final2, v_ver, 'final_agreement', '2026-08-30'))
      || '/' || pg_temp.try('authenticated', a_uid, format('select public.cph_set_bf_override(%s, %s, %L, 57.00)', v_final2, v_ver, '16'));
  select count(*) into v_n2 from public.customer_pricing_change_events;
  checks := checks + 1; if v_t <> '55000/55000/55000' or v_n2 <> v_n then fails := fails + 1; end if;
  log := log || case when v_t = '55000/55000/55000' and v_n2 = v_n then E'\nok   ' else E'\nFAIL ' end
    || 're-void / correct / BF override on the voided round refused ' || v_t || ', audit delta ' || (v_n2 - v_n);
  select string_agg(bf_code || ':' || delta_inr || ':' || coalesce(override_rate_inr::text, '-') || ':' || content_version, ' ' order by bf_code)
    into v_t from public.customer_pricing_event_bf_rates where event_id = v_final2;
  checks := checks + 1; if v_t is distinct from v_bf_before then fails := fails + 1; end if;
  log := log || case when v_t = v_bf_before then E'\nok   ' else E'\nFAIL ' end || 'the refused BF override left the snapshot unchanged';
  begin
    update public.customer_pricing_negotiation_events set rate_inr = 1.00 where id = v_final2;
    fails := fails + 1; log := log || E'\nFAIL owner rewrote a voided round';
  exception when others then checks := checks + 1;
    log := log || case when sqlstate = '55000' then E'\nok   ' else E'\nFAIL ' end || 'even the owner cannot rewrite a voided round ' || sqlstate;
    if sqlstate <> '55000' then fails := fails + 1; end if;
  end;
  begin
    update public.customer_pricing_negotiation_events set status = 'active', void_reason = null where id = v_final2;
    fails := fails + 1; log := log || E'\nFAIL a voided round was un-voided';
  exception when others then checks := checks + 1;
    log := log || case when sqlstate = '55000' then E'\nok   ' else E'\nFAIL ' end || 'no un-void path, even for the owner ' || sqlstate;
    if sqlstate <> '55000' then fails := fails + 1; end if;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  begin
    update public.customer_pricing_negotiation_events set status = 'voided', void_reason = 'sneaky', rate_inr = 1.00 where id = v_offer;
    fails := fails + 1; log := log || E'\nFAIL a void carried another column change';
  exception when others then checks := checks + 1;
    log := log || case when sqlstate = '22023' then E'\nok   ' else E'\nFAIL ' end || 'a void that also changes the rate is refused (status-only guard) ' || sqlstate;
    if sqlstate <> '22023' then fails := fails + 1; end if;
  end;
  begin
    update public.customer_pricing_negotiation_events set status = 'voided' where id = v_offer;
    fails := fails + 1; log := log || E'\nFAIL a void without a reason was stored';
  exception when others then checks := checks + 1;
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'a void without a reason is refused by the table check ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  v_t := pg_temp.try('authenticated', a_uid, format('delete from public.customer_pricing_negotiation_events where id = %s', v_final2));
  checks := checks + 1; if v_t <> '42501' then fails := fails + 1; end if;
  log := log || case when v_t = '42501' then E'\nok   ' else E'\nFAIL ' end || 'no hard delete of a (voided) round ' || v_t;

  -- ── active rounds still behave: correction and void of an offer work; paste cannot touch the voided round
  select content_version into v_ver from public.customer_pricing_negotiation_events where id = v_counter;
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_correct_round(%s, %s, %L, %L, 52.50, null, null, null, null, null, %L, null, null, %L)',
           v_counter, v_ver, 'customer_counter', '2026-08-26', 'call', 'corrected'));
  select content_version into v_ver from public.customer_pricing_negotiation_events where id = v_offer;
  v_t := v_t || '/' || pg_temp.try('authenticated', a_uid, format('select public.cph_void_round(245, %s, %s, %L)', v_offer, v_ver, 'duplicate of a later offer'));
  checks := checks + 1; if v_t <> 'OK/OK' then fails := fails + 1; end if;
  log := log || case when v_t = 'OK/OK' then E'\nok   ' else E'\nFAIL ' end || 'an ACTIVE counter can still be corrected and an offer voided: ' || v_t;
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v_prev := public.cph_store_paste_preview(245, jsonb_build_array(
    jsonb_build_object('op','update_cycle','cycle_id',v_cycle,'expected_version',(select content_version from public.customer_pricing_cycles where id = v_cycle),
      'set',jsonb_build_object('notes','must roll back')),
    jsonb_build_object('op','set_bf_override','event_id',v_final2,'expected_version',
      (select content_version from public.customer_pricing_negotiation_events where id = v_final2),'bf_code','16','override_rate_inr','57.00')));
  execute 'reset role';
  select count(*) into v_n from public.customer_pricing_change_events;
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_apply_paste(245, %L, %L)', v_prev->>'preview_id', v_prev->>'digest'));
  select count(*) into v_n2 from public.customer_pricing_change_events;
  checks := checks + 1;
  if v_t <> '55000' or v_n2 <> v_n or (select notes from public.customer_pricing_cycles where id = v_cycle) is not null then fails := fails + 1; end if;
  log := log || case when v_t = '55000' and v_n2 = v_n then E'\nok   ' else E'\nFAIL ' end
    || 'a paste batch touching the voided round is refused whole (' || v_t || '), earlier op and audit rolled back';

  -- ── 14. independence
  fp_after := pg_temp.fingerprint();
  select count(*) into v_n from jsonb_object_keys(fp_before);
  select coalesce(string_agg(k, ', '), '') into v_t from jsonb_object_keys(fp_before) k where fp_before -> k is distinct from fp_after -> k;
  checks := checks + 1; if v_t <> '' then fails := fails + 1; end if;
  log := log || case when v_t = '' then E'\nok   ' else E'\nFAIL ' end || 'all ' || v_n || ' non-pricing public/app_private tables byte-identical before and after [' || v_t || ']';

  log := log || E'\nbatch md5 ' || md5(current_query()) || ' length ' || length(current_query());
  raise exception 'P0.5 VOID REHEARSAL ROLLED BACK. failures=% checks=% %', fails, checks, log;
end $rehearseV$;
