-- ═════ P0.2 REHEARSAL TAIL: always ends in RAISE, so the whole batch rolls back ═════
-- Run as ONE batch immediately after the text of
--   supabase/migrations/20260923150000_customer_pricing_history_p0_1.sql
--   supabase/migrations/20260923183000_customer_pricing_history_p0_2.sql
-- The final RAISE aborts the batch, so neither migration nor any row persists;
-- the result is read from the error message.
do $rehearse2$
declare
  log text := '';
  fails int := 0;
  a_uid text := '79ea4710-1d3b-45b7-9dca-a2dc83503c2b';   -- app user 44, read_party_master
  b_uid text := 'e2ab29bb-94d4-447a-90ca-cafa34e85f83';   -- app user 45, read_party_master
  x_uid text := '39ff307e-504e-4f24-a6e8-5308efb59570';   -- app user 3440, NO read_party_master
  v jsonb; r record; v_n int; v_t text;
  v_term1 bigint; v_term2 bigint; v_bf1 bigint; v_bf2 bigint; v_cycle bigint; v_line bigint;
  v_ev bigint; v_ev2 bigint; v_next bigint; v_new_line bigint; v_w1 bigint; v_w2 bigint;
  v_before text; v_after text;

  -- expect(sqlstate) helper is inlined as: begin ... exception when others then <check> end
begin
  for r in select * from tests.cph_p0_1_catalogue() union all select * from tests.cph_p0_2_catalogue() loop
    if not r.ok then fails := fails + 1; log := log || E'\nFAIL ' || r.name; else log := log || E'\nok   ' || r.name; end if;
  end loop;

  -- ── anon and unauthorised callers
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  execute 'set local role anon';
  begin
    perform count(*) from public.customer_pricing_term_versions;
    fails := fails + 1; log := log || E'\nFAIL anon read of Stable Terms allowed';
  exception when others then log := log || E'\nok   anon Stable Term read refused ' || sqlstate; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', x_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.cph_create_term_version(245, null, null, '2026-04-01', null, false, null, null,
      null, null, null, null, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL unauthorised term create allowed';
  exception when others then
    log := log || case when sqlstate = '42501' then E'\nok   ' else E'\nFAIL ' end || 'term create without read_party_master refused ' || sqlstate;
    if sqlstate <> '42501' then fails := fails + 1; end if;
  end;
  execute 'reset role';

  -- ── persona A: mechanism, Stable Terms
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.cph_create_term_version(245, null, null, '2026-04-01', null, false, null, null,
      null, null, null, null, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL term before mechanism accepted';
  exception when others then
    log := log || case when sqlstate = '22023' then E'\nok   ' else E'\nFAIL ' end || 'term before any mechanism refused ' || sqlstate;
    if sqlstate <> '22023' then fails := fails + 1; end if;
  end;
  perform public.cph_save_mechanism(245, null, 'monthly', 'financial_year', 'kraft_paper_per_kg', 'paper_consumed', 'excluding_gst', null);

  v := public.cph_create_term_version(245, null, null, '2026-04-01', null, false, 'kraft_paper_per_kg', 'paper_consumed',
    'added_pct', 3.5, 'ex_factory_separate', 8.00, 1.25, 'email', '2026-03-28', 'Annual terms mail', null);
  v_term1 := (v->>'id')::bigint;
  log := log || E'\nok   Stable Term v1 created ' || v::text;
  begin
    perform public.cph_create_term_version(245, null, null, '2026-06-01', null, false, null, null,
      null, null, null, null, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL overlapping active term accepted';
  exception when others then
    log := log || case when sqlstate = '23P01' then E'\nok   ' else E'\nFAIL ' end || 'overlapping active term for same scope refused ' || sqlstate;
    if sqlstate <> '23P01' then fails := fails + 1; end if;
  end;
  v := public.cph_create_term_version(245, null, 1, '2026-04-01', null, false, null, null,
    'added_pct', 0, 'delivered_included', 0, null, null, null, null, null);
  select wastage_treatment || ':' || wastage_pct::text || ':' || conversion_inr_per_kg::text || ':' || coalesce(freight_inr_per_kg::text, 'blank')
    into v_t from public.customer_pricing_term_versions where id = (v->>'id')::bigint;
  log := log || case when v_t = 'added_pct:0.00:0.00:blank' then E'\nok   ' else E'\nFAIL ' end
    || 'plant-scoped term overlaps whole-Customer term legally; explicit 0 kept apart from blank: ' || v_t;
  if v_t <> 'added_pct:0.00:0.00:blank' then fails := fails + 1; end if;
  begin
    perform public.cph_create_term_version(245, null, 2, '2026-04-01', null, false, null, null,
      'added_pct', null, null, null, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL wastage added without % accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'wastage added without % refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_create_term_version(245, null, 2, '2026-04-01', null, false, null, null,
      'included_in_weight', 3, null, null, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL wastage included carrying a % accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'wastage included carrying a % refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_create_term_version(245, null, 2, '2026-04-01', null, false, null, null,
      null, null, null, 8.555, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL three-decimal conversion accepted';
  exception when others then
    log := log || case when sqlstate = '22023' then E'\nok   ' else E'\nFAIL ' end || 'three-decimal conversion refused, not rounded ' || sqlstate;
    if sqlstate <> '22023' then fails := fails + 1; end if;
  end;

  -- ── BF delta set v1
  begin
    perform public.cph_create_bf_delta_set(245, null, null, '2026-04-01', null, false, '18',
      '[{"bf_code":"18","delta_inr":"1.00"}]'::jsonb, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL base BF inside its own schedule accepted';
  exception when others then
    log := log || case when sqlstate = '22023' then E'\nok   ' else E'\nFAIL ' end || 'base BF carrying a delta refused ' || sqlstate;
    if sqlstate <> '22023' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_create_bf_delta_set(245, null, null, '2026-04-01', null, false, '18',
      '[{"bf_code":"20","delta_inr":"1.555"}]'::jsonb, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL three-decimal delta accepted';
  exception when others then
    log := log || case when sqlstate = '22023' then E'\nok   ' else E'\nFAIL ' end || 'three-decimal BF delta refused ' || sqlstate;
    if sqlstate <> '22023' then fails := fails + 1; end if;
  end;
  v := public.cph_create_bf_delta_set(245, null, null, '2026-04-01', null, false, '18',
    '[{"bf_code":"20","delta_inr":"1.50"},{"bf_code":"16","delta_inr":"-1.00"},{"bf_code":"22GY","delta_inr":"3.25"}]'::jsonb,
    'excel', null, null, 'PepsiCo-style schedule');
  v_bf1 := (v->>'id')::bigint;
  log := log || E'\nok   BF set v1 created ' || v::text;

  -- ── cycle, line, references
  v := public.cph_create_cycle(245, '2026-09-01', '2026-09-30', '2026-08-25', null, null, null);
  v_cycle := (v->>'id')::bigint;
  v := public.cph_create_line(v_cycle, null, null, null, 'All RSC', 'not_captured', null, null);
  v_line := (v->>'id')::bigint;
  begin
    perform public.cph_set_line_references(v_line, 1, (select id from public.customer_pricing_term_versions
      where party_id = 245 and plant_id = 1), null);
    fails := fails + 1; log := log || E'\nFAIL plant-scoped term on a whole-Customer line accepted';
  exception when others then
    log := log || case when sqlstate = '22023' then E'\nok   ' else E'\nFAIL ' end || 'term narrower than the line''s scope refused ' || sqlstate;
    if sqlstate <> '22023' then fails := fails + 1; end if;
  end;
  v := public.cph_set_line_references(v_line, 1, v_term1, v_bf1);
  log := log || case when (v->>'content_version')::int = 2 then E'\nok   ' else E'\nFAIL ' end || 'line references set under CAS ' || v::text;
  begin
    perform public.cph_set_line_references(v_line, 1, null, null);
    fails := fails + 1; log := log || E'\nFAIL stale reference change accepted';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale reference change refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;

  -- ── a round with components: snapshot of term + BF schedule
  v := public.cph_add_round(v_line, 'avadhoot_offer', '2026-08-26', 54.26, null, null, 45.00, 8.00, 1.25,
    'email', null, null, null, gen_random_uuid());
  v_ev := (v->>'id')::bigint;
  select coalesce(rate_basis, '?') || '/' || coalesce(weight_basis, '?') || '/' || snap_conversion_inr_per_kg::text || '/'
         || snap_freight_inr_per_kg::text || '/' || snap_wastage_treatment || ':' || snap_wastage_pct::text || '/'
         || base_bf_code || '/' || (rate_inr - (component_kraft_inr + component_conversion_inr + component_freight_inr))::text
    into v_t from public.customer_pricing_negotiation_events where id = v_ev;
  log := log || case when v_t = 'kraft_paper_per_kg/paper_consumed/8.00/1.25/added_pct:3.50/18/0.01' then E'\nok   ' else E'\nFAIL ' end
    || 'round snapshot (basis/conv/freight/wastage/base BF/reconciliation diff): ' || v_t;
  if v_t <> 'kraft_paper_per_kg/paper_consumed/8.00/1.25/added_pct:3.50/18/0.01' then fails := fails + 1; end if;
  select string_agg(bf_code || '=' || delta_inr::text || '->' || (54.26 + delta_inr)::text, ' ' order by bf_code), count(*)
    into v_t, v_n from public.customer_pricing_event_bf_rates where event_id = v_ev;
  log := log || case when v_n = 3 and v_t = '16=-1.00->53.26 20=1.50->55.76 22GY=3.25->57.51' then E'\nok   ' else E'\nFAIL ' end
    || 'full BF schedule snapshotted, derived = base + signed delta: ' || coalesce(v_t, 'none');
  if v_n <> 3 or v_t <> '16=-1.00->53.26 20=1.50->55.76 22GY=3.25->57.51' then fails := fails + 1; end if;
  -- the P0.1 add path snapshots too (triggers, not the RPC, own the snapshot)
  v := public.cph_add_event(v_line, 'customer_counter', '2026-08-27', 52.00, null, null, null, null, null, null, gen_random_uuid());
  v_ev2 := (v->>'id')::bigint;
  select count(*) into v_n from public.customer_pricing_event_bf_rates where event_id = v_ev2;
  log := log || case when v_n = 3 then E'\nok   ' else E'\nFAIL ' end || 'P0.1 add path also snapshots the BF schedule: ' || v_n;
  if v_n <> 3 then fails := fails + 1; end if;
  begin
    perform public.cph_add_round(v_line, 'avadhoot_offer', '2026-08-28', 53.00, null, null, 45.005, null, null,
      null, null, null, null, gen_random_uuid());
    fails := fails + 1; log := log || E'\nFAIL three-decimal component accepted';
  exception when others then
    log := log || case when sqlstate = '22023' then E'\nok   ' else E'\nFAIL ' end || 'three-decimal component refused ' || sqlstate;
    if sqlstate <> '22023' then fails := fails + 1; end if;
  end;

  -- ── later versions never reinterpret the earlier round
  v := public.cph_create_term_version(245, null, null, '2026-10-01', null, true, 'kraft_paper_per_kg', 'paper_consumed',
    'added_pct', 3.5, 'ex_factory_separate', 9.00, 1.40, null, null, null, 'FY revision');
  v_term2 := (v->>'id')::bigint;
  select coalesce(effective_to::text, 'open') into v_t from public.customer_pricing_term_versions where id = v_term1;
  log := log || case when v_t = '2026-09-30' then E'\nok   ' else E'\nFAIL ' end || 'v2 explicitly closed v1 at ' || v_t
    || ' (closed_prior_id ' || coalesce(v->>'closed_prior_id', 'none') || ')';
  if v_t <> '2026-09-30' then fails := fails + 1; end if;
  v := public.cph_create_bf_delta_set(245, null, null, '2026-10-01', null, true, '18',
    '[{"bf_code":"20","delta_inr":"2.00"},{"bf_code":"16","delta_inr":"-1.25"}]'::jsonb, null, null, null, null);
  v_bf2 := (v->>'id')::bigint;
  select snap_conversion_inr_per_kg::text || '/' || (select delta_inr::text from public.customer_pricing_event_bf_rates
      where event_id = v_ev and bf_code = '20') || '/' || bf_delta_set_id::text
    into v_t from public.customer_pricing_negotiation_events where id = v_ev;
  log := log || case when v_t = '8.00/1.50/' || v_bf1 then E'\nok   ' else E'\nFAIL ' end
    || 'earlier round keeps its snapshot after new term and BF versions: ' || v_t;
  if v_t <> '8.00/1.50/' || v_bf1 then fails := fails + 1; end if;
  execute 'reset role';
  begin
    update public.customer_pricing_bf_deltas set delta_inr = 9 where set_id = v_bf1;
    fails := fails + 1; log := log || E'\nFAIL owner rewrite of a BF delta allowed';
  exception when others then log := log || E'\nok   BF delta entries immutable even for owner ' || sqlstate; end;
  begin
    update public.customer_pricing_negotiation_events set snap_conversion_inr_per_kg = 99 where id = v_ev;
    fails := fails + 1; log := log || E'\nFAIL owner rewrite of a round snapshot allowed';
  exception when others then log := log || E'\nok   round snapshot frozen even for owner ' || sqlstate; end;

  -- ── persona B: overrides, corrections, measures
  perform set_config('request.jwt.claims', json_build_object('sub', b_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v := public.cph_set_bf_override(v_ev, 1, '20', 56.00);
  select delta_inr::text || '/' || override_rate_inr::text || '/' || (54.26 + delta_inr)::text into v_t
    from public.customer_pricing_event_bf_rates where event_id = v_ev and bf_code = '20';
  log := log || case when v_t = '1.50/56.00/55.76' and (v->>'content_version')::int = 2 then E'\nok   ' else E'\nFAIL ' end
    || 'BF override kept beside the derived rate (delta/override/derived): ' || v_t;
  if v_t <> '1.50/56.00/55.76' then fails := fails + 1; end if;
  begin
    perform public.cph_set_bf_override(v_ev, 1, '16', 50.00);
    fails := fails + 1; log := log || E'\nFAIL stale override accepted';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale BF override refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_set_bf_override(v_ev, 2, '99', 50.00);
    fails := fails + 1; log := log || E'\nFAIL override for a BF outside the snapshot accepted';
  exception when others then
    log := log || case when sqlstate = 'P0002' then E'\nok   ' else E'\nFAIL ' end || 'override for a BF outside the schedule refused ' || sqlstate;
    if sqlstate <> 'P0002' then fails := fails + 1; end if;
  end;
  perform public.cph_correct_round(v_ev, 2, 'avadhoot_offer', '2026-08-26', 54.25, null, null, 45.00, 8.00, 1.25,
    'email', null, null, 'total corrected');
  select (before_state->>'rate_inr') || '->' || (after_state->>'rate_inr') || ' by ' || actor_app_user_id
    into v_t from public.customer_pricing_change_events
   where entity_type = 'negotiation_event' and entity_id = v_ev and operation = 'update'
   order by id desc limit 1;
  log := log || case when v_t = '54.26->54.25 by 45' then E'\nok   ' else E'\nFAIL ' end || 'round correction audited: ' || coalesce(v_t, 'MISSING');
  if v_t is distinct from '54.26->54.25 by 45' then fails := fails + 1; end if;
  -- ── BF floor: signed deltas are fine, a negative derived rate never is
  v := public.cph_add_round(v_line, 'customer_counter', '2026-08-29', 1.00, null, null, null, null, null,
    null, null, null, 'floor exactly 0.00 for BF 16', gen_random_uuid());
  select min(1.00 + delta_inr)::text into v_t from public.customer_pricing_event_bf_rates where event_id = (v->>'id')::bigint;
  log := log || case when v_t = '0.00' then E'\nok   ' else E'\nFAIL ' end
    || 'negative delta accepted while the derived rate stays >= 0 (lowest derived ' || coalesce(v_t, 'none') || ')';
  if v_t is distinct from '0.00' then fails := fails + 1; end if;
  select (select count(*) from public.customer_pricing_negotiation_events where line_id = v_line) || '/'
      || (select count(*) from public.customer_pricing_event_bf_rates br join public.customer_pricing_negotiation_events e
            on e.id = br.event_id where e.line_id = v_line) || '/'
      || (select count(*) from public.customer_pricing_change_events where party_id = 245)
    into v_before;
  begin
    perform public.cph_add_round(v_line, 'customer_counter', '2026-08-29', 0.99, null, null, null, null, null,
      null, null, null, null, gen_random_uuid());
    fails := fails + 1; log := log || E'\nFAIL round with a negative derived BF rate accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'round whose BF 16 would be -0.01 refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_add_event(v_line, 'customer_counter', '2026-08-29', 0.50, null, null, null, null, null, null, gen_random_uuid());
    fails := fails + 1; log := log || E'\nFAIL P0.1 path with a negative derived BF rate accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'direct P0.1 RPC with a negative derived BF rate refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  select content_version into v_n from public.customer_pricing_negotiation_events where id = v_ev;
  begin
    perform public.cph_correct_round(v_ev, v_n, 'avadhoot_offer', '2026-08-26', 0.90, null, null, null, null, null,
      null, null, null, 'would take BF 16 to -0.10');
    fails := fails + 1; log := log || E'\nFAIL base-rate correction below the BF floor accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'base-rate correction taking a snapshotted BF negative refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  select (select count(*) from public.customer_pricing_negotiation_events where line_id = v_line) || '/'
      || (select count(*) from public.customer_pricing_event_bf_rates br join public.customer_pricing_negotiation_events e
            on e.id = br.event_id where e.line_id = v_line) || '/'
      || (select count(*) from public.customer_pricing_change_events where party_id = 245)
    into v_after;
  select rate_inr::text || '/v' || content_version into v_t from public.customer_pricing_negotiation_events where id = v_ev;
  log := log || case when v_before = v_after and v_t = '54.25/v' || v_n then E'\nok   ' else E'\nFAIL ' end
    || 'refused BF-floor writes changed nothing (rounds/snapshots/audit ' || v_before || ' -> ' || v_after
    || '; round still ' || v_t || ')';
  if v_before <> v_after or v_t <> '54.25/v' || v_n then fails := fails + 1; end if;
  begin
    perform public.cph_correct_term_version(v_term2, 1, null, '2026-09-15', null, null, null,
      null, null, null, null, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL term correction into an overlap accepted';
  exception when others then
    log := log || case when sqlstate = '23P01' then E'\nok   ' else E'\nFAIL ' end || 'term correction into an overlap refused ' || sqlstate;
    if sqlstate <> '23P01' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_correct_term_version(v_term2, 9, null, '2026-10-01', null, null, null,
      null, null, null, null, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL stale term correction accepted';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale term correction refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;

  v := public.cph_set_line_measure(v_line, 'paper_consumed_kg', 'costing_snapshot', 0.4520, null, 'from Costing');
  v_w1 := (v->>'id')::bigint;
  v := public.cph_set_line_measure(v_line, 'paper_consumed_kg', 'customer_confirmed', 0.4600, null, 'buyer mail');
  v_w2 := (v->>'id')::bigint;
  select string_agg(source || '=' || value::text, ' ' order by source) into v_t
    from public.customer_pricing_line_measures where line_id = v_line and status = 'active';
  log := log || case when v_t = 'costing_snapshot=0.4520 customer_confirmed=0.4600' then E'\nok   ' else E'\nFAIL ' end
    || 'Customer-confirmed weight sits beside the Costing value: ' || coalesce(v_t, 'none');
  if v_t is distinct from 'costing_snapshot=0.4520 customer_confirmed=0.4600' then fails := fails + 1; end if;
  begin
    perform public.cph_set_line_measure(v_line, 'paper_consumed_kg', 'costing_snapshot', 0.5, null, null);
    fails := fails + 1; log := log || E'\nFAIL blind overwrite of a recorded weight accepted';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'blind overwrite of a recorded weight refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_set_line_measure(v_line, 'sheet_weight_kg', 'manual', 0, null, null);
    fails := fails + 1; log := log || E'\nFAIL zero weight accepted';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'zero weight refused (blank means not recorded) ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_set_line_measure(v_line, 'area_sqm', 'manual', 0.12345, null, null);
    fails := fails + 1; log := log || E'\nFAIL five-decimal area accepted';
  exception when others then
    log := log || case when sqlstate = '22023' then E'\nok   ' else E'\nFAIL ' end || 'five-decimal area refused ' || sqlstate;
    if sqlstate <> '22023' then fails := fails + 1; end if;
  end;
  v := public.cph_set_line_measure(v_line, 'paper_consumed_kg', 'customer_confirmed', null, 1, null);
  select status || '/' || value::text into v_t from public.customer_pricing_line_measures where id = v_w2;
  log := log || case when v_t = 'withdrawn/0.4600' then E'\nok   ' else E'\nFAIL ' end || 'withdrawing keeps the value on record: ' || v_t;
  if v_t <> 'withdrawn/0.4600' then fails := fails + 1; end if;

  -- ── Start next cycle
  begin
    perform public.cph_start_next_cycle(v_cycle, '2026-08-01', '2026-08-31', '2026-07-25', null);
    fails := fails + 1; log := log || E'\nFAIL next cycle starting before the prior accepted';
  exception when others then
    log := log || case when sqlstate = '22023' then E'\nok   ' else E'\nFAIL ' end || 'next cycle before the prior refused ' || sqlstate;
    if sqlstate <> '22023' then fails := fails + 1; end if;
  end;
  v := public.cph_start_next_cycle(v_cycle, '2026-10-01', '2026-10-31', '2026-09-24', null);
  v_next := (v->>'id')::bigint;
  select l.id, (l.term_version_id = v_term2)::text || '/' || (l.bf_delta_set_id = v_bf2)::text || '/'
         || (l.prior_line_id = v_line)::text || '/' || l.sob_state || '/' || l.scope_text || '/'
         || (select count(*) from public.customer_pricing_negotiation_events e where e.line_id = l.id)::text || '/'
         || (select string_agg(w.source || '=' || w.value::text, ' ') from public.customer_pricing_line_measures w where w.line_id = l.id)
         || '/' || c.review_frequency
    into v_new_line, v_t
    from public.customer_pricing_lines l join public.customer_pricing_cycles c on c.id = l.cycle_id
   where l.cycle_id = v_next;
  log := log || case when v_t = 'true/true/true/not_captured/All RSC/0/costing_snapshot=0.4520/monthly' then E'\nok   ' else E'\nFAIL ' end
    || 'next cycle copies structure only (term v2/BF v2/prior link/SOB/scope/rounds/measures/frequency): ' || coalesce(v_t, 'none');
  if v_t is distinct from 'true/true/true/not_captured/All RSC/0/costing_snapshot=0.4520/monthly' then fails := fails + 1; end if;
  begin
    perform public.cph_start_next_cycle(v_cycle, '2026-10-01', '2026-10-31', '2026-09-24', null);
    fails := fails + 1; log := log || E'\nFAIL second next cycle for the same period accepted';
  exception when others then
    log := log || case when sqlstate = '23505' then E'\nok   ' else E'\nFAIL ' end || 'duplicate next cycle refused ' || sqlstate;
    if sqlstate <> '23505' then fails := fails + 1; end if;
  end;

  -- ── direct writes impossible on the new tables
  begin
    insert into public.customer_pricing_term_versions (party_id, version_no, effective_from, created_by, updated_by)
    values (245, 99, '2030-01-01', 45, 45);
    fails := fails + 1; log := log || E'\nFAIL direct term insert allowed';
  exception when others then log := log || E'\nok   direct Stable Term insert refused ' || sqlstate; end;
  begin
    update public.customer_pricing_event_bf_rates set override_rate_inr = 1 where event_id = v_ev;
    fails := fails + 1; log := log || E'\nFAIL direct override update allowed';
  exception when others then log := log || E'\nok   direct BF override update refused ' || sqlstate; end;

  select string_agg(entity_type || ':' || n, ' ' order by entity_type) into v_t from (
    select entity_type, count(*) n from public.customer_pricing_change_events
     where party_id = 245 and entity_type in ('term_version','bf_delta_set','bf_delta','line_measure','event_bf_rate')
     group by entity_type) s;
  log := log || E'\nok   audit rows for new entities: ' || coalesce(v_t, 'NONE');
  if v_t is null or v_t not like '%bf_delta:5%' or v_t not like '%event_bf_rate:%' or v_t not like '%line_measure:%'
     or v_t not like '%term_version:%' then
    fails := fails + 1; log := log || E'\nFAIL audit coverage incomplete';
  end if;
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', x_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select (select count(*) from public.customer_pricing_term_versions) + (select count(*) from public.customer_pricing_bf_delta_sets)
       + (select count(*) from public.customer_pricing_bf_deltas) + (select count(*) from public.customer_pricing_line_measures)
       + (select count(*) from public.customer_pricing_event_bf_rates) into v_n;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'user without read_party_master sees new-table rows: ' || v_n;
  if v_n <> 0 then fails := fails + 1; end if;
  execute 'reset role';

  raise exception 'P0.2 REHEARSAL ROLLED BACK. failures=% %', fails, log;
end $rehearse2$;
