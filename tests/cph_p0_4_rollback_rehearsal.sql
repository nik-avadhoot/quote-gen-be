-- ═════ P0.4 REHEARSAL TAIL: always ends in RAISE, so the whole batch rolls back ═════
-- Run as ONE batch immediately after the text of
--   supabase/migrations/20260924164751_customer_pricing_history_p0_1.sql
--   supabase/migrations/20260924164806_customer_pricing_history_p0_2.sql
--   supabase/migrations/20260924164820_customer_pricing_history_p0_4.sql
-- The final RAISE aborts the batch, so no migration, preview or pricing row persists;
-- the result is read from the error message.
do $rehearse4$
declare
  log text := '';
  fails int := 0;
  a_uid text := '79ea4710-1d3b-45b7-9dca-a2dc83503c2b';   -- app user 44, read_party_master
  b_uid text := 'e2ab29bb-94d4-447a-90ca-cafa34e85f83';   -- app user 45, read_party_master
  x_uid text := '39ff307e-504e-4f24-a6e8-5308efb59570';   -- app user 3440, NO read_party_master
  v jsonb; r record; v_n int; v_n2 int; v_t text; v_other bigint;
  v_bf bigint; v_cycle bigint; v_line bigint; v_ev bigint; v_ver int; v_ev_ver int; v_new bigint;
  v_prev uuid; v_digest text; v_payload jsonb; v_floc bigint;
begin
  -- Read as the owner, before any role switch, so RLS cannot hide them and make
  -- the cross-Customer checks below pass vacuously.
  select min(p.id) into v_other from public.parties p where p.id <> 245 and p.status <> 'merged';
  select min(l.id) into v_floc from public.customer_locations l where l.party_id <> 245;
  if v_other is null or v_floc is null then
    raise exception 'P0.4 REHEARSAL PRECONDITION: needs another Customer and a foreign Location';
  end if;
  for r in select * from tests.cph_p0_1_catalogue() union all select * from tests.cph_p0_2_catalogue()
           union all select * from tests.cph_p0_4_catalogue() loop
    if not r.ok then fails := fails + 1; log := log || E'\nFAIL ' || r.name; else log := log || E'\nok   ' || r.name; end if;
  end loop;

  -- ── anon: no preview store, no apply, no preview table
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  execute 'set local role anon';
  begin
    perform public.cph_store_paste_preview(245, '[]'::jsonb);
    fails := fails + 1; log := log || E'\nFAIL anon preview store allowed';
  exception when others then log := log || E'\nok   anon preview store refused ' || sqlstate; end;
  begin
    perform count(*) from app_private.cph_paste_previews;
    fails := fails + 1; log := log || E'\nFAIL anon preview table read allowed';
  exception when others then log := log || E'\nok   anon preview table read refused ' || sqlstate; end;
  execute 'reset role';

  -- ── authenticated WITHOUT read_party_master
  perform set_config('request.jwt.claims', json_build_object('sub', x_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.cph_store_paste_preview(245, '[{"op":"update_cycle","cycle_id":1,"expected_version":1,"set":{}}]'::jsonb);
    fails := fails + 1; log := log || E'\nFAIL unauthorised preview store allowed';
  exception when others then
    log := log || case when sqlstate = '42501' then E'\nok   ' else E'\nFAIL ' end || 'preview store without read_party_master refused ' || sqlstate;
    if sqlstate <> '42501' then fails := fails + 1; end if;
  end;
  execute 'reset role';

  -- ── persona A: a Customer with a BF-scheduled line and one round
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.cph_save_mechanism(245, null, 'monthly', 'financial_year', 'kraft_paper_per_kg', 'paper_consumed', 'excluding_gst', null);
  v := public.cph_create_bf_delta_set(245, null, null, '2026-04-01', null, false, '18',
    '[{"bf_code":"20","delta_inr":"1.50"},{"bf_code":"16","delta_inr":"-1.00"}]'::jsonb, null, null, null, null);
  v_bf := (v->>'id')::bigint;
  v_cycle := (public.cph_create_cycle(245, '2026-09-01', '2026-09-30', '2026-08-24', null, null, null)->>'id')::bigint;
  v_line := (public.cph_create_line(v_cycle, null, null, null, 'Main', 'not_captured', null, 'keep me')->>'id')::bigint;
  v := public.cph_set_line_references(v_line, 1, null, v_bf);
  v_ev := (public.cph_add_round(v_line, 'avadhoot_offer', '2026-08-25', 56.00, null, null, null, null, null,
           null, null, null, null, gen_random_uuid())->>'id')::bigint;
  select content_version into v_ver from public.customer_pricing_lines where id = v_line;
  select content_version into v_ev_ver from public.customer_pricing_negotiation_events where id = v_ev;

  begin
    perform count(*) from app_private.cph_paste_previews;
    fails := fails + 1; log := log || E'\nFAIL authenticated read the preview table directly';
  exception when others then log := log || E'\nok   authenticated cannot read the preview table directly ' || sqlstate; end;

  -- ── bounds
  begin
    perform public.cph_store_paste_preview(245, '[]'::jsonb);
    fails := fails + 1; log := log || E'\nFAIL empty batch accepted';
  exception when others then
    log := log || case when sqlstate = 'PT413' then E'\nok   ' else E'\nFAIL ' end || 'empty batch refused ' || sqlstate;
    if sqlstate <> 'PT413' then fails := fails + 1; end if;
  end;
  select jsonb_agg(jsonb_build_object('op','update_cycle','cycle_id',v_cycle,'expected_version',1,'set','{}'::jsonb))
    into v_payload from generate_series(1, 201);
  begin
    perform public.cph_store_paste_preview(245, v_payload);
    fails := fails + 1; log := log || E'\nFAIL 201-change batch accepted';
  exception when others then
    log := log || case when sqlstate = 'PT413' then E'\nok   ' else E'\nFAIL ' end || '201-change batch refused ' || sqlstate;
    if sqlstate <> 'PT413' then fails := fails + 1; end if;
  end;

  -- ── stale at store time, and another Customer's record
  begin
    perform public.cph_store_paste_preview(245, jsonb_build_array(jsonb_build_object(
      'op','update_line','line_id',v_line,'expected_version',v_ver - 1,'set',jsonb_build_object('notes','x'))));
    fails := fails + 1; log := log || E'\nFAIL stale preview stored';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale version refused at preview ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;
  begin
    perform public.cph_store_paste_preview(v_other, jsonb_build_array(jsonb_build_object(
      'op','update_line','line_id',v_line,'expected_version',v_ver,'set',jsonb_build_object('notes','x'))));
    fails := fails + 1; log := log || E'\nFAIL a line addressed through another Customer was accepted';
  exception when others then
    log := log || case when sqlstate = 'P0002' then E'\nok   ' else E'\nFAIL ' end || 'line addressed through another Customer refused as not found ' || sqlstate;
    if sqlstate <> 'P0002' then fails := fails + 1; end if;
  end;

  -- ── the representative batch
  v_payload := jsonb_build_array(
    jsonb_build_object('op','update_cycle','cycle_id',v_cycle,'expected_version',1,'set',jsonb_build_object('custom_label','Sep revised')),
    jsonb_build_object('op','update_line','line_id',v_line,'expected_version',v_ver,
      'set',jsonb_build_object('sob_state','defined','sob_pct','0.00','notes',null)),
    jsonb_build_object('op','create_line','key','n1','cycle_id',v_cycle,'scope_text','Lids'),
    jsonb_build_object('op','create_line','key','n2','cycle_id',v_cycle,'scope_text','Trays'),
    jsonb_build_object('op','add_round','line_id',v_line,'event_type','customer_counter','event_date','2026-08-27',
      'rate_inr','53.00','source_ref','Pasted: 53','client_request_id',gen_random_uuid()),
    jsonb_build_object('op','add_round','line_key','n1','event_type','final_agreement','event_date','2026-08-30',
      'rate_inr','54.50','source_ref','Pasted: 54.5','client_request_id',gen_random_uuid()),
    jsonb_build_object('op','add_round','line_key','n2','event_type','avadhoot_offer','event_date','2026-08-30',
      'rate_inr','0.00','source_ref','Pasted: 0','client_request_id',gen_random_uuid()),
    jsonb_build_object('op','set_bf_override','event_id',v_ev,'expected_version',v_ev_ver,'bf_code','20','override_rate_inr','57.10'),
    jsonb_build_object('op','set_bf_override','event_id',v_ev,'expected_version',v_ev_ver,'bf_code','16','override_rate_inr','55.00'));
  v := public.cph_store_paste_preview(245, v_payload);
  v_prev := (v->>'preview_id')::uuid; v_digest := v->>'digest';
  log := log || E'\nok   preview stored ' || (v->>'operations') || ' ops, digest ' || left(v_digest, 12);
  if v_digest <> encode(sha256(convert_to(v_payload::text, 'UTF8')), 'hex') then
    fails := fails + 1; log := log || E'\nFAIL digest is not the sha-256 of the stored payload';
  end if;

  begin
    perform public.cph_apply_paste(245, v_prev, repeat('0', 64));
    fails := fails + 1; log := log || E'\nFAIL apply with a different digest accepted';
  exception when others then
    log := log || case when sqlstate = 'PT412' then E'\nok   ' else E'\nFAIL ' end || 'apply with another digest refused ' || sqlstate;
    if sqlstate <> 'PT412' then fails := fails + 1; end if;
  end;
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', b_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.cph_apply_paste(245, v_prev, v_digest);
    fails := fails + 1; log := log || E'\nFAIL another user applied A''s preview';
  exception when others then
    log := log || case when sqlstate = 'P0002' then E'\nok   ' else E'\nFAIL ' end || 'another user cannot apply A''s preview ' || sqlstate;
    if sqlstate <> 'P0002' then fails := fails + 1; end if;
  end;
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.customer_pricing_change_events where party_id = 245;
  v := public.cph_apply_paste(245, v_prev, v_digest);
  select count(*) into v_n2 from public.customer_pricing_change_events where party_id = 245;
  log := log || case when (v->>'applied')::int = 9 then E'\nok   ' else E'\nFAIL ' end || 'batch applied: ' || v::text;
  if (v->>'applied')::int <> 9 then fails := fails + 1; end if;

  select sob_state || ':' || sob_pct::text || ':' || coalesce(notes, 'CLEARED') || ':' || scope_text into v_t
    from public.customer_pricing_lines where id = v_line;
  log := log || case when v_t = 'defined:0.00:CLEARED:Main' then E'\nok   ' else E'\nFAIL ' end
    || 'explicit 0% kept, accepted clear cleared, untouched scope kept: ' || v_t;
  if v_t <> 'defined:0.00:CLEARED:Main' then fails := fails + 1; end if;
  select custom_label into v_t from public.customer_pricing_cycles where id = v_cycle;
  if v_t is distinct from 'Sep revised' then fails := fails + 1; log := log || E'\nFAIL cycle label not applied'; end if;
  select string_agg(l.scope_text || '=' || e.event_type || ':' || e.rate_inr::text || ':' || e.source_type, ' ' order by l.scope_text)
    into v_t from public.customer_pricing_lines l join public.customer_pricing_negotiation_events e on e.line_id = l.id
   where l.cycle_id = v_cycle and l.scope_text in ('Lids', 'Trays');
  log := log || case when v_t = 'Lids=final_agreement:54.50:excel Trays=avadhoot_offer:0.00:excel' then E'\nok   ' else E'\nFAIL ' end
    || 'new lines + their rounds, explicit 0.00 rate, source excel: ' || coalesce(v_t, 'NONE');
  if v_t is distinct from 'Lids=final_agreement:54.50:excel Trays=avadhoot_offer:0.00:excel' then fails := fails + 1; end if;
  select string_agg(bf_code || ':' || delta_inr::text || ':' || coalesce(override_rate_inr::text, 'derived'), ' ' order by bf_code)
    into v_t from public.customer_pricing_event_bf_rates where event_id = v_ev;
  log := log || case when v_t = '16:-1.00:55.00 20:1.50:57.10' then E'\nok   ' else E'\nFAIL ' end
    || 'two overrides on one round under running CAS; snapshotted deltas untouched: ' || coalesce(v_t, 'NONE');
  if v_t is distinct from '16:-1.00:55.00 20:1.50:57.10' then fails := fails + 1; end if;
  select string_agg(event_type || '#' || sequence_no, ',' order by sequence_no) into v_t
    from public.customer_pricing_negotiation_events where line_id = v_line;
  log := log || case when v_t = 'avadhoot_offer#1,customer_counter#2' then E'\nok   ' else E'\nFAIL ' end
    || 'pasted round appended after the existing one (chronology kept, nothing overwritten): ' || v_t;
  if v_t <> 'avadhoot_offer#1,customer_counter#2' then fails := fails + 1; end if;
  log := log || case when v_n2 - v_n >= 11 then E'\nok   ' else E'\nFAIL ' end
    || 'audit rows written in the same transaction: ' || (v_n2 - v_n);
  if v_n2 - v_n < 11 then fails := fails + 1; end if;

  begin
    perform public.cph_apply_paste(245, v_prev, v_digest);
    fails := fails + 1; log := log || E'\nFAIL a preview applied twice';
  exception when others then
    log := log || case when sqlstate = 'PT410' then E'\nok   ' else E'\nFAIL ' end || 'second apply of one preview refused ' || sqlstate;
    if sqlstate <> 'PT410' then fails := fails + 1; end if;
  end;

  -- ── stale at APPLY time: nothing of the batch persists, the preview stays unconsumed
  select content_version into v_ver from public.customer_pricing_lines where id = v_line;
  v := public.cph_store_paste_preview(245, jsonb_build_array(
    jsonb_build_object('op','create_line','key','s1','cycle_id',v_cycle,'scope_text','Stale lids'),
    jsonb_build_object('op','update_line','line_id',v_line,'expected_version',v_ver,'set',jsonb_build_object('notes','stale'))));
  perform public.cph_update_line(v_line, v_ver, null, null, null, 'Main', 'defined', 0.00, 'someone else');
  select count(*) into v_n from public.customer_pricing_change_events where party_id = 245;
  begin
    perform public.cph_apply_paste(245, (v->>'preview_id')::uuid, v->>'digest');
    fails := fails + 1; log := log || E'\nFAIL stale batch applied';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale version at apply refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;
  select count(*) into v_n2 from public.customer_pricing_change_events where party_id = 245;
  select count(*) into v_new from public.customer_pricing_lines where scope_text = 'Stale lids';
  log := log || case when v_new = 0 and v_n2 = v_n then E'\nok   ' else E'\nFAIL ' end
    || 'stale apply wrote nothing (new lines ' || v_new || ', audit delta ' || (v_n2 - v_n) || ')';
  if v_new <> 0 or v_n2 <> v_n then fails := fails + 1; end if;
  select notes into v_t from public.customer_pricing_lines where id = v_line;
  if v_t is distinct from 'someone else' then fails := fails + 1; log := log || E'\nFAIL the other user''s save was overwritten'; end if;

  -- ── mid-batch constraint failure: whole batch and its audit roll back
  select content_version into v_ver from public.customer_pricing_cycles where id = v_cycle;
  v := public.cph_store_paste_preview(245, jsonb_build_array(
    jsonb_build_object('op','update_cycle','cycle_id',v_cycle,'expected_version',v_ver,'set',jsonb_build_object('notes','must roll back')),
    jsonb_build_object('op','create_line','key','d1','cycle_id',v_cycle,'scope_text','Lids')));
  select count(*) into v_n from public.customer_pricing_change_events where party_id = 245;
  begin
    perform public.cph_apply_paste(245, (v->>'preview_id')::uuid, v->>'digest');
    fails := fails + 1; log := log || E'\nFAIL duplicate-scope batch applied';
  exception when others then
    log := log || case when sqlstate = '23505' then E'\nok   ' else E'\nFAIL ' end || 'duplicate scope inside a batch refused ' || sqlstate;
    if sqlstate <> '23505' then fails := fails + 1; end if;
  end;
  select count(*) into v_n2 from public.customer_pricing_change_events where party_id = 245;
  select coalesce(notes, 'blank') into v_t from public.customer_pricing_cycles where id = v_cycle;
  log := log || case when v_t = 'blank' and v_n2 = v_n then E'\nok   ' else E'\nFAIL ' end
    || 'earlier change in the failed batch rolled back with its audit (notes ' || v_t || ', audit delta ' || (v_n2 - v_n) || ')';
  if v_t <> 'blank' or v_n2 <> v_n then fails := fails + 1; end if;

  -- ── unresolved identity: another Customer's Location cannot be linked
  v := public.cph_store_paste_preview(245, jsonb_build_array(
    jsonb_build_object('op','create_line','key','u1','cycle_id',v_cycle,'scope_text','Foreign loc',
      'customer_location_id',v_floc)));
  begin
    perform public.cph_apply_paste(245, (v->>'preview_id')::uuid, v->>'digest');
    fails := fails + 1; log := log || E'\nFAIL another Customer''s Location linked';
  exception when others then
    log := log || case when sqlstate = '23503' then E'\nok   ' else E'\nFAIL ' end || 'another Customer''s Location refused by the composite key ' || sqlstate;
    if sqlstate <> '23503' then fails := fails + 1; end if;
  end;

  -- ── expiry
  v := public.cph_store_paste_preview(245, jsonb_build_array(
    jsonb_build_object('op','create_line','key','e1','cycle_id',v_cycle,'scope_text','Late')));
  execute 'reset role';
  update app_private.cph_paste_previews
     set created_at = now() - interval '1 hour', expires_at = now() - interval '45 minutes'
   where id = (v->>'preview_id')::uuid;
  execute 'set local role authenticated';
  begin
    perform public.cph_apply_paste(245, (v->>'preview_id')::uuid, v->>'digest');
    fails := fails + 1; log := log || E'\nFAIL expired preview applied';
  exception when others then
    log := log || case when sqlstate = 'PT410' then E'\nok   ' else E'\nFAIL ' end || 'expired preview refused ' || sqlstate;
    if sqlstate <> 'PT410' then fails := fails + 1; end if;
  end;
  select count(*) into v_new from public.customer_pricing_lines where scope_text = 'Late';
  if v_new <> 0 then fails := fails + 1; log := log || E'\nFAIL expired preview wrote a line'; end if;

  begin
    insert into app_private.cph_paste_previews (party_id, actor_app_user_id, payload, digest, op_count, expires_at)
    values (245, 44, '[]', 'x', 1, now() + interval '1 minute');
    fails := fails + 1; log := log || E'\nFAIL direct preview insert allowed';
  exception when others then log := log || E'\nok   direct preview insert refused ' || sqlstate; end;
  execute 'reset role';

  raise exception 'P0.4 REHEARSAL ROLLED BACK. failures=% %', fails, log;
end $rehearse4$;
