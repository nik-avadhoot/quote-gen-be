
-- ═════ REHEARSAL TAIL: always ends in RAISE, so the whole batch rolls back ═════
-- Run as ONE batch immediately after the text of
-- supabase/migrations/20260923150000_customer_pricing_history_p0_1.sql.
-- The final RAISE aborts the batch, so neither the migration nor any row
-- persists; the result is read from the error message.
do $rehearse$
declare
  log text := '';
  fails int := 0;
  a_uid text := '79ea4710-1d3b-45b7-9dca-a2dc83503c2b';   -- app user 44, read_party_master
  b_uid text := 'e2ab29bb-94d4-447a-90ca-cafa34e85f83';   -- app user 45, read_party_master
  x_uid text := '39ff307e-504e-4f24-a6e8-5308efb59570';   -- app user 3440, active, NO read_party_master
  v jsonb; v_mech bigint; v_cycle bigint; v_line bigint; v_ev bigint; v_n int; v_t text;
  v_state text; r record; v_req uuid := gen_random_uuid(); v_other_loc bigint;
  v_cycle2 bigint; v_cycle3 bigint; v_line3 bigint;

  -- no nested functions in DO; use a small inline pattern per step
begin
  -- structural gates (as owner)
  for r in select * from tests.cph_p0_1_catalogue() loop
    if not r.ok then fails := fails + 1; log := log || E'\nFAIL ' || r.name; else log := log || E'\nok   ' || r.name; end if;
  end loop;

  -- ── anon: no table read, no operation
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  execute 'set local role anon';
  begin
    perform count(*) from public.customer_pricing_mechanisms;
    fails := fails + 1; log := log || E'\nFAIL anon read was allowed';
  exception when others then
    log := log || E'\nok   anon table read refused ' || sqlstate;
  end;
  begin
    perform public.cph_save_mechanism(245, null, 'monthly', null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL anon mutation was allowed';
  exception when others then
    log := log || E'\nok   anon mutation refused ' || sqlstate;
  end;
  execute 'reset role';

  -- ── authenticated WITHOUT read_party_master
  perform set_config('request.jwt.claims', json_build_object('sub', x_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.cph_save_mechanism(245, null, 'monthly', null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL unauthorised mutation was allowed';
  exception when others then
    log := log || case when sqlstate = '42501' then E'\nok   ' else E'\nFAIL ' end
      || 'authenticated without read_party_master refused ' || sqlstate;
    if sqlstate <> '42501' then fails := fails + 1; end if;
  end;
  execute 'reset role';

  -- ── persona A creates the record
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';

  v := public.cph_save_mechanism(245, null, 'monthly', 'financial_year', 'box_per_piece', null, 'excluding_gst', 'Monthly Kraft review');
  v_mech := (v->>'id')::bigint;
  log := log || E'\nok   A created mechanism ' || v::text;

  begin
    perform public.cph_save_mechanism(245, null, 'quarterly', null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL second create was allowed';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'second blind create refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;

  v := public.cph_save_mechanism(245, 1, 'monthly', 'financial_year', 'box_per_kg', 'paper_consumed', 'excluding_gst', 'Kraft per kg');
  if (v->>'content_version')::int <> 2 then fails := fails + 1; log := log || E'\nFAIL CAS update did not bump to 2'; else log := log || E'\nok   CAS update -> v2'; end if;

  begin
    perform public.cph_save_mechanism(245, 1, 'annual', null, 'box_per_sqm', null, null, 'stale overwrite');
    fails := fails + 1; log := log || E'\nFAIL stale mechanism write accepted';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale mechanism write refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;
  select rate_basis || '/' || review_frequency || '/' || content_version into v_t
    from public.customer_pricing_mechanisms where id = v_mech;
  if v_t <> 'box_per_kg/monthly/2' then fails := fails + 1; log := log || E'\nFAIL stale write changed data: ' || v_t;
  else log := log || E'\nok   stale write left data unchanged ' || v_t; end if;

  -- direct writes are impossible
  begin
    update public.customer_pricing_mechanisms set notes = 'bypass' where id = v_mech;
    fails := fails + 1; log := log || E'\nFAIL direct UPDATE allowed';
  exception when others then log := log || E'\nok   direct UPDATE refused ' || sqlstate; end;
  begin
    insert into public.customer_pricing_change_events (party_id, entity_type, entity_id, operation, after_state, actor_app_user_id)
    values (245, 'mechanism', v_mech, 'create', '{}'::jsonb, 44);
    fails := fails + 1; log := log || E'\nFAIL forged audit insert allowed';
  exception when others then log := log || E'\nok   forged audit insert refused ' || sqlstate; end;
  begin
    delete from public.customer_pricing_mechanisms where id = v_mech;
    fails := fails + 1; log := log || E'\nFAIL direct DELETE allowed';
  exception when others then log := log || E'\nok   direct DELETE refused ' || sqlstate; end;

  -- cycle
  v := public.cph_create_cycle(245, '2026-09-01', '2026-09-30', '2026-08-25', null, null, null);
  v_cycle := (v->>'id')::bigint;
  log := log || E'\nok   cycle created ' || v::text;
  begin
    perform public.cph_create_cycle(245, '2026-09-01', '2026-09-30', '2026-08-26', null, null, null);
    fails := fails + 1; log := log || E'\nFAIL duplicate period accepted';
  exception when others then
    log := log || case when sqlstate = '23505' then E'\nok   ' else E'\nFAIL ' end || 'duplicate period refused ' || sqlstate;
    if sqlstate <> '23505' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_create_cycle(245, '2026-10-31', '2026-10-01', '2026-10-01', null, null, null);
    fails := fails + 1; log := log || E'\nFAIL inverted period accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'inverted period refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;

  -- line: SOB states
  v := public.cph_create_line(v_cycle, null, null, null, 'All RSC boxes', 'defined', 0, null);
  v_line := (v->>'id')::bigint;
  select sob_state || ':' || sob_pct::text into v_t from public.customer_pricing_lines where id = v_line;
  if v_t <> 'defined:0.00' then fails := fails + 1; log := log || E'\nFAIL explicit 0% SOB not kept: ' || coalesce(v_t,'null');
  else log := log || E'\nok   explicit 0% SOB stored as ' || v_t; end if;
  begin
    perform public.cph_create_line(v_cycle, null, null, null, 'Other', 'defined', null, null);
    fails := fails + 1; log := log || E'\nFAIL defined SOB without % accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'defined SOB without % refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_create_line(v_cycle, null, null, null, 'Other', 'undefined', 10, null);
    fails := fails + 1; log := log || E'\nFAIL undefined SOB with % accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'undefined SOB carrying % refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_create_line(v_cycle, null, null, null, 'all rsc boxes', 'undefined', null, null);
    fails := fails + 1; log := log || E'\nFAIL duplicate scope accepted';
  exception when others then
    log := log || case when sqlstate = '23505' then E'\nok   ' else E'\nFAIL ' end || 'duplicate scope (case-insensitive) refused ' || sqlstate;
    if sqlstate <> '23505' then fails := fails + 1; end if;
  end;
  select id into v_other_loc from public.customer_locations where party_id <> 245 limit 1;
  if v_other_loc is not null then
    begin
      perform public.cph_create_line(v_cycle, v_other_loc, null, null, 'foreign loc', 'not_captured', null, null);
      fails := fails + 1; log := log || E'\nFAIL another Customer''s Location accepted';
    exception when others then
      log := log || case when sqlstate = '23503' then E'\nok   ' else E'\nFAIL ' end || 'another Customer''s Location refused ' || sqlstate;
      if sqlstate <> '23503' then fails := fails + 1; end if;
    end;
  else
    log := log || E'\nskip no other-party Location exists to test the composite FK';
  end if;

  -- negotiation rounds
  perform public.cph_add_event(v_line, 'avadhoot_offer',   '2026-08-25', 100.00, null, null, 'email', '2026-08-25', 'RFQ reply', null, v_req);
  perform public.cph_add_event(v_line, 'customer_counter', '2026-08-27',  90.50, null, null, 'call', null, null, null, gen_random_uuid());
  perform public.cph_add_event(v_line, 'avadhoot_offer',   '2026-08-28',  97.00, null, null, null, null, null, null, gen_random_uuid());
  perform public.cph_add_event(v_line, 'customer_counter', '2026-08-28',  94.00, null, null, 'whatsapp', null, null, null, gen_random_uuid());
  v := public.cph_add_event(v_line, 'final_agreement',     '2026-08-30',  95.25, null, null, 'meeting', null, null, null, gen_random_uuid());
  v_ev := (v->>'id')::bigint;
  select string_agg(event_type || '@' || sequence_no || '=' || rate_inr::text, ' ' order by event_date, sequence_no), count(*)
    into v_t, v_n from public.customer_pricing_negotiation_events where line_id = v_line;
  if v_n <> 5 then fails := fails + 1; end if;
  log := log || case when v_n = 5 then E'\nok   ' else E'\nFAIL ' end || '5 rounds retained in order: ' || v_t;

  begin
    perform public.cph_add_event(v_line, 'avadhoot_offer', '2026-08-25', 100.00, null, null, null, null, null, null, v_req);
    fails := fails + 1; log := log || E'\nFAIL retried add (same request id) recorded twice';
  exception when others then
    log := log || case when sqlstate = '23505' then E'\nok   ' else E'\nFAIL ' end || 'retried add refused as duplicate ' || sqlstate;
    if sqlstate <> '23505' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_add_event(v_line, 'avadhoot_offer', '2026-08-25', 100.00, 'including_gst', null, null, null, null, null, gen_random_uuid());
    fails := fails + 1; log := log || E'\nFAIL GST-inclusive without GST % accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'GST-inclusive without % refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  v := public.cph_add_event(v_line, 'customer_counter', '2026-08-31', 112.10, 'including_gst', 18, null, null, null, null, gen_random_uuid());
  select tax_treatment || ':' || gst_pct::text || ':' || rate_basis || ':' || weight_basis into v_t
    from public.customer_pricing_negotiation_events where id = (v->>'id')::bigint;
  log := log || case when v_t = 'including_gst:18.00:box_per_kg:paper_consumed' then E'\nok   ' else E'\nFAIL ' end
    || 'GST % and basis snapshotted on the event: ' || v_t;
  if v_t <> 'including_gst:18.00:box_per_kg:paper_consumed' then fails := fails + 1; end if;
  begin
    perform public.cph_add_event(v_line, 'avadhoot_offer', '2026-08-25', -1, null, null, null, null, null, null, gen_random_uuid());
    fails := fails + 1; log := log || E'\nFAIL negative rate accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'negative rate refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  v := public.cph_add_event(v_line, 'avadhoot_offer', '2026-09-02', 0, null, null, null, null, null, null, gen_random_uuid());
  select rate_inr::text into v_t from public.customer_pricing_negotiation_events where id = (v->>'id')::bigint;
  log := log || case when v_t = '0.00' then E'\nok   ' else E'\nFAIL ' end || 'explicit zero rate stored as ' || coalesce(v_t, 'NULL');
  if v_t is distinct from '0.00' then fails := fails + 1; end if;
  execute 'reset role';

  -- ── persona B corrects a round: stale refused, current accepted, audited
  perform set_config('request.jwt.claims', json_build_object('sub', b_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.customer_pricing_negotiation_events where line_id = v_line;
  log := log || E'\nok   B reads ' || v_n || ' rounds through RLS';
  perform public.cph_correct_event(v_ev, 1, 'final_agreement', '2026-08-30', 95.50, null, null, 'meeting', null, 'corrected', null);
  begin
    perform public.cph_correct_event(v_ev, 1, 'final_agreement', '2026-08-30', 1.00, null, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL B stale correction accepted';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale correction refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;
  select rate_inr::text || '/v' || content_version || '/by' || updated_by into v_t
    from public.customer_pricing_negotiation_events where id = v_ev;
  log := log || case when v_t = '95.50/v2/by45' then E'\nok   ' else E'\nFAIL ' end || 'corrected round ' || v_t;
  if v_t <> '95.50/v2/by45' then fails := fails + 1; end if;

  select (before_state->>'rate_inr') || '->' || (after_state->>'rate_inr') || ' by ' || actor_app_user_id into v_t
    from public.customer_pricing_change_events
   where entity_type = 'negotiation_event' and entity_id = v_ev and operation = 'update';
  log := log || case when v_t = '95.25->95.50 by 45' then E'\nok   ' else E'\nFAIL ' end || 'audit evidence ' || coalesce(v_t, 'MISSING');
  if v_t is distinct from '95.25->95.50 by 45' then fails := fails + 1; end if;

  select count(*) into v_n from public.customer_pricing_change_events where party_id = 245;
  -- 2 mechanism + 1 cycle + 1 line + 7 events created + 1 correction = 12
  log := log || case when v_n = 12 then E'\nok   ' else E'\nFAIL ' end || 'change events for the Customer: ' || v_n;
  if v_n <> 12 then fails := fails + 1; end if;
  begin
    update public.customer_pricing_change_events set actor_app_user_id = 44;
    fails := fails + 1; log := log || E'\nFAIL audit rewrite allowed';
  exception when others then log := log || E'\nok   audit rewrite refused ' || sqlstate; end;

  -- ── correction pass 2: the idempotency key is mandatory at the RPC too
  begin
    perform public.cph_add_event(v_line, 'avadhoot_offer', '2026-09-03', 10, null, null, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL add round without a request id accepted';
  exception when others then
    log := log || case when sqlstate = '23502' then E'\nok   ' else E'\nFAIL ' end || 'add round with NULL request id refused ' || sqlstate;
    if sqlstate <> '23502' then fails := fails + 1; end if;
  end;

  -- ── correction pass 3: one Cycle per exact period, whatever its label
  begin
    perform public.cph_create_cycle(245, '2026-09-01', '2026-09-30', '2026-08-26', null, 'Relabelled Sep', null);
    fails := fails + 1; log := log || E'\nFAIL same period under a new label accepted';
  exception when others then
    log := log || case when sqlstate = '23505' then E'\nok   ' else E'\nFAIL ' end || 'same period with a different label refused ' || sqlstate;
    if sqlstate <> '23505' then fails := fails + 1; end if;
  end;
  v := public.cph_create_cycle(245, '2026-10-01', '2026-10-31', '2026-09-25', null, null, null);
  v_cycle2 := (v->>'id')::bigint;
  begin
    perform public.cph_update_cycle(v_cycle2, 1, '2026-09-01', '2026-09-30', '2026-09-25', null, 'Sep again', null, null);
    fails := fails + 1; log := log || E'\nFAIL moving a Cycle onto an existing period accepted';
  exception when others then
    log := log || case when sqlstate = '23505' then E'\nok   ' else E'\nFAIL ' end || 'editing a Cycle onto an existing period refused ' || sqlstate;
    if sqlstate <> '23505' then fails := fails + 1; end if;
  end;
  v := public.cph_update_cycle(v_cycle, 1, '2026-09-01', '2026-09-30', '2026-08-24', null, 'Sep 2026 (revised)', 'closed', 'edited by B');
  select custom_label || '/' || status || '/' || initiated_on || '/v' || content_version into v_t
    from public.customer_pricing_cycles where id = v_cycle;
  log := log || case when v_t = 'Sep 2026 (revised)/closed/2026-08-24/v2' then E'\nok   ' else E'\nFAIL ' end || 'Cycle edit (label, status, initiation) under CAS: ' || v_t;
  if v_t <> 'Sep 2026 (revised)/closed/2026-08-24/v2' then fails := fails + 1; end if;
  begin
    perform public.cph_update_cycle(v_cycle, 1, '2026-09-01', '2026-09-30', '2026-08-25', null, 'stale', 'open', null);
    fails := fails + 1; log := log || E'\nFAIL stale Cycle edit accepted';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale Cycle edit refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;
  select count(*) into v_n from public.customer_pricing_cycles
   where party_id = 245 and period_start = '2026-09-01' and period_end = '2026-09-30';
  log := log || case when v_n = 1 then E'\nok   ' else E'\nFAIL ' end || 'Cycles for Sep 2026 after relabelling: ' || v_n;
  if v_n <> 1 then fails := fails + 1; end if;

  -- ── correction pass 1: SKU ownership and SKU/Plant agreement
  -- Live SKU 987 belongs to party 1151 at plant 1 (NAG).
  if exists (select 1 from public.skus where id = 987 and party_id = 1151 and plant_id = 1) then
    begin
      perform public.cph_create_line(v_cycle2, null, null, 987, 'foreign SKU', 'not_captured', null, null);
      fails := fails + 1; log := log || E'\nFAIL another Customer''s SKU accepted';
    exception when others then
      log := log || case when sqlstate = '23503' then E'\nok   ' else E'\nFAIL ' end || 'another Customer''s SKU refused ' || sqlstate;
      if sqlstate <> '23503' then fails := fails + 1; end if;
    end;
    -- ── correction pass 4: an including-GST mechanism is the default for a new round
    perform public.cph_save_mechanism(1151, null, 'quarterly', 'financial_year', 'box_per_piece', null, 'including_gst', null);
    v := public.cph_create_cycle(1151, '2026-10-01', '2026-12-31', '2026-09-20', null, null, null);
    v_cycle3 := (v->>'id')::bigint;
    begin
      perform public.cph_create_line(v_cycle3, null, 2, 987, 'wrong plant', 'not_captured', null, null);
      fails := fails + 1; log := log || E'\nFAIL SKU with a mismatched Plant accepted';
    exception when others then
      log := log || case when sqlstate = '23503' then E'\nok   ' else E'\nFAIL ' end || 'SKU with a mismatched Plant refused ' || sqlstate;
      if sqlstate <> '23503' then fails := fails + 1; end if;
    end;
    v := public.cph_create_line(v_cycle3, null, 1, 987, null, 'not_captured', null, null);
    v_line3 := (v->>'id')::bigint;
    log := log || E'\nok   own SKU at its own Plant accepted (line ' || v_line3 || ')';

    v := public.cph_add_event(v_line3, 'avadhoot_offer', '2026-09-21', 50, null, 18, null, null, null, null, gen_random_uuid());
    select tax_treatment || ':' || gst_pct::text into v_t from public.customer_pricing_negotiation_events where id = (v->>'id')::bigint;
    log := log || case when v_t = 'including_gst:18.00' then E'\nok   ' else E'\nFAIL ' end || 'blank round tax follows the including-GST mechanism: ' || coalesce(v_t, 'NULL');
    if v_t is distinct from 'including_gst:18.00' then fails := fails + 1; end if;
    begin
      perform public.cph_add_event(v_line3, 'customer_counter', '2026-09-22', 45, null, null, null, null, null, null, gen_random_uuid());
      fails := fails + 1; log := log || E'\nFAIL including-GST default without GST % accepted';
    exception when others then
      log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'including-GST default requires a GST % ' || sqlstate;
      if sqlstate <> '23514' then fails := fails + 1; end if;
    end;
    v := public.cph_add_event(v_line3, 'customer_counter', '2026-09-22', 45, 'excluding_gst', null, null, null, null, null, gen_random_uuid());
    select tax_treatment || ':' || coalesce(gst_pct::text, 'null') into v_t from public.customer_pricing_negotiation_events where id = (v->>'id')::bigint;
    log := log || case when v_t = 'excluding_gst:null' then E'\nok   ' else E'\nFAIL ' end || 'a round may override to excluding GST: ' || v_t;
    if v_t <> 'excluding_gst:null' then fails := fails + 1; end if;
  else
    fails := fails + 1; log := log || E'\nFAIL fixture SKU 987 (party 1151, plant 1) not found - SKU cases not exercised';
  end if;
  execute 'reset role';

  -- ── unauthorised authenticated user sees nothing
  perform set_config('request.jwt.claims', json_build_object('sub', x_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select (select count(*) from public.customer_pricing_mechanisms) + (select count(*) from public.customer_pricing_negotiation_events)
       + (select count(*) from public.customer_pricing_change_events) into v_n;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'user without read_party_master sees rows: ' || v_n;
  if v_n <> 0 then fails := fails + 1; end if;
  execute 'reset role';

  -- ── the owner-side append-only guard
  begin
    delete from public.customer_pricing_change_events;
    fails := fails + 1; log := log || E'\nFAIL owner delete of audit allowed';
  exception when others then log := log || E'\nok   audit delete refused even for owner ' || sqlstate; end;

  raise exception 'REHEARSAL ROLLED BACK. failures=% %', fails, log;
end $rehearse$;
