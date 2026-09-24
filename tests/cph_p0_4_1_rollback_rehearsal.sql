-- ═════ P0.4.1 REHEARSAL TAIL: always ends in RAISE, so the whole batch rolls back ═════
-- Run as ONE batch immediately after the text of
--   supabase/migrations/20260924164751_customer_pricing_history_p0_1.sql
--   supabase/migrations/20260924164806_customer_pricing_history_p0_2.sql
--   supabase/migrations/20260924164820_customer_pricing_history_p0_4.sql
--   supabase/migrations/20260924164835_customer_pricing_history_p0_4_1_sob_allocated_boxes.sql
-- The final RAISE aborts the batch, so no migration, preview or pricing row persists;
-- the result is read from the error message.
do $rehearse41$
declare
  log text := '';
  fails int := 0;
  a_uid text := '79ea4710-1d3b-45b7-9dca-a2dc83503c2b';   -- app user 44, read_party_master
  x_uid text := '39ff307e-504e-4f24-a6e8-5308efb59570';   -- app user 3440, NO read_party_master
  v jsonb; r record; v_n int; v_n2 int; v_t text; v_cycle bigint; v_next bigint;
  l_pct bigint; l_box bigint; l_zero bigint; l_und bigint; v_ver int; v_prev_count int;
begin
  for r in select * from tests.cph_p0_1_catalogue() union all select * from tests.cph_p0_2_catalogue()
           union all select * from tests.cph_p0_4_catalogue() union all select * from tests.cph_p0_4_1_catalogue() loop
    if not r.ok then fails := fails + 1; log := log || E'\nFAIL ' || r.name; else log := log || E'\nok   ' || r.name; end if;
  end loop;

  -- ── authenticated WITHOUT read_party_master cannot write a box quantity
  perform set_config('request.jwt.claims', json_build_object('sub', x_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.cph_create_line(1, null, null, null, 'x', 'allocated_quantity', null, 10, null);
    fails := fails + 1; log := log || E'\nFAIL unauthorised line write allowed';
  exception when others then
    log := log || case when sqlstate = '42501' then E'\nok   ' else E'\nFAIL ' end || 'line write without read_party_master refused ' || sqlstate;
    if sqlstate <> '42501' then fails := fails + 1; end if;
  end;
  execute 'reset role';

  -- ── persona A
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.cph_save_mechanism(245, null, 'monthly', 'financial_year', 'box_per_piece', null, 'excluding_gst', null);
  v_cycle := (public.cph_create_cycle(245, '2026-09-01', '2026-09-30', '2026-08-24', null, null, null)->>'id')::bigint;
  l_pct  := (public.cph_create_line(v_cycle, null, null, null, 'Pct',  'percentage', 40.00, null, null)->>'id')::bigint;
  l_box  := (public.cph_create_line(v_cycle, null, null, null, 'Box',  'allocated_quantity', null, 25000, null)->>'id')::bigint;
  l_zero := (public.cph_create_line(v_cycle, null, null, null, 'Zero', 'allocated_quantity', null, 0, null)->>'id')::bigint;
  l_und  := (public.cph_create_line(v_cycle, null, null, null, 'Und',  'undefined', null, null, null)->>'id')::bigint;
  select string_agg(scope_text || '=' || sob_state || ':' || coalesce(sob_pct::text, '∅') || ':'
                    || coalesce(sob_allocated_boxes::text, '∅'), ' ' order by id) into v_t
    from public.customer_pricing_lines where cycle_id = v_cycle;
  log := log || case when v_t = 'Pct=percentage:40.00:∅ Box=allocated_quantity:∅:25000 Zero=allocated_quantity:∅:0 Und=undefined:∅:∅'
    then E'\nok   ' else E'\nFAIL ' end || 'percentage, 25000 boxes, explicit 0 boxes and undefined stored distinctly: ' || v_t;
  if v_t is distinct from 'Pct=percentage:40.00:∅ Box=allocated_quantity:∅:25000 Zero=allocated_quantity:∅:0 Und=undefined:∅:∅' then
    fails := fails + 1;
  end if;

  -- ── invalid state/value combinations through the governed writer
  for r in select * from (values
      ('percentage with boxes too',      'percentage',         40.00::numeric, 5),
      ('allocated quantity with a %',    'allocated_quantity', 40.00::numeric, 5),
      ('allocated quantity with no boxes','allocated_quantity', null::numeric, null),
      ('percentage with no %',           'percentage',         null::numeric, null),
      ('undefined carrying 0 boxes',     'undefined',          null::numeric, 0),
      ('not captured carrying 0.00%',    'not_captured',       0.00::numeric, null),
      ('negative boxes',                 'allocated_quantity', null::numeric, -1),
      ('boxes above the bound',          'allocated_quantity', null::numeric, 1000000000),
      ('the retired defined state',      'defined',            40.00::numeric, null)) as t(label, st, pct, boxes) loop
    begin
      perform public.cph_create_line(v_cycle, null, null, null, 'Bad ' || r.label, r.st, r.pct, r.boxes, null);
      fails := fails + 1; log := log || E'\nFAIL accepted: ' || r.label;
    exception when others then
      log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'refused by check: ' || r.label || ' ' || sqlstate;
      if sqlstate <> '23514' then fails := fails + 1; end if;
    end;
  end loop;

  -- ── API bypassed: the table itself refuses a mixed row, and authenticated cannot write it at all
  begin
    update public.customer_pricing_lines set sob_pct = 10 where id = l_box;
    fails := fails + 1; log := log || E'\nFAIL authenticated wrote the table directly';
  exception when others then
    log := log || case when sqlstate = '42501' then E'\nok   ' else E'\nFAIL ' end || 'authenticated direct table write refused ' || sqlstate;
    if sqlstate <> '42501' then fails := fails + 1; end if;
  end;
  execute 'reset role';
  begin
    update public.customer_pricing_lines set sob_pct = 10 where id = l_box;   -- as the owner, bypassing every function
    fails := fails + 1; log := log || E'\nFAIL owner wrote % and boxes onto one line';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'owner-level mixed %+boxes row refused by the table check ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  begin
    update public.customer_pricing_lines set sob_allocated_boxes = 7 where id = l_und;
    fails := fails + 1; log := log || E'\nFAIL owner wrote boxes onto an undefined line';
  exception when others then
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'owner-level boxes on an undefined state refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  execute 'set local role authenticated';

  -- ── CAS + audit: a stale write changes nothing and logs nothing; a good one logs before/after
  select content_version into v_ver from public.customer_pricing_lines where id = l_pct;
  select count(*) into v_n from public.customer_pricing_change_events where party_id = 245;
  begin
    perform public.cph_update_line(l_pct, v_ver + 1, null, null, null, 'Pct', 'allocated_quantity', null, 25000, null);
    fails := fails + 1; log := log || E'\nFAIL stale CAS accepted';
  exception when others then
    log := log || case when sqlstate = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale CAS refused ' || sqlstate;
    if sqlstate <> 'PT409' then fails := fails + 1; end if;
  end;
  select count(*) into v_n2 from public.customer_pricing_change_events where party_id = 245;
  select sob_state || ':' || coalesce(sob_pct::text, '∅') || ':' || coalesce(sob_allocated_boxes::text, '∅') into v_t
    from public.customer_pricing_lines where id = l_pct;
  log := log || case when v_n2 = v_n and v_t = 'percentage:40.00:∅' then E'\nok   ' else E'\nFAIL ' end
    || 'stale CAS wrote neither the line (' || v_t || ') nor an audit row (delta ' || (v_n2 - v_n) || ')';
  if v_n2 <> v_n or v_t <> 'percentage:40.00:∅' then fails := fails + 1; end if;

  v := public.cph_update_line(l_pct, v_ver, null, null, null, 'Pct', 'allocated_quantity', null, 25000, null);
  select e.before_state ->> 'sob_state' || '>' || (e.after_state ->> 'sob_state') || ' pct ' ||
         coalesce(e.before_state ->> 'sob_pct', '∅') || '>' || coalesce(e.after_state ->> 'sob_pct', '∅') || ' boxes ' ||
         coalesce(e.before_state ->> 'sob_allocated_boxes', '∅') || '>' || coalesce(e.after_state ->> 'sob_allocated_boxes', '∅')
    into v_t
    from public.customer_pricing_change_events e
   where e.entity_type = 'line' and e.entity_id = l_pct order by e.id desc limit 1;
  log := log || case when v_t = 'percentage>allocated_quantity pct 40.00>∅ boxes ∅>25000' then E'\nok   ' else E'\nFAIL ' end
    || 'audit shows SOB mode and both values before/after: ' || coalesce(v_t, 'NONE');
  if v_t is distinct from 'percentage>allocated_quantity pct 40.00>∅ boxes ∅>25000' then fails := fails + 1; end if;
  -- put it back to a percentage for the next-cycle check
  perform public.cph_update_line(l_pct, (v->>'content_version')::int, null, null, null, 'Pct', 'percentage', 40.00, null, null);

  -- ── Start next cycle copies neither the % nor the box quantity
  v := public.cph_start_next_cycle(v_cycle, '2026-10-01', '2026-10-31', '2026-09-24', null);
  v_next := (v->>'id')::bigint;
  select count(*), count(*) filter (where sob_state = 'not_captured' and sob_pct is null and sob_allocated_boxes is null)
    into v_n, v_n2 from public.customer_pricing_lines where cycle_id = v_next;
  log := log || case when v_n = 4 and v_n2 = 4 then E'\nok   ' else E'\nFAIL ' end
    || 'next cycle: ' || v_n2 || ' of ' || v_n || ' lines reset to Not yet captured with no % and no boxes';
  if v_n <> 4 or v_n2 <> 4 then fails := fails + 1; end if;

  -- ── paste: 0 boxes, blank keeps, explicit clear, new line invents no identity — one preview, one apply
  select count(*) into v_prev_count from public.customer_pricing_change_events where party_id = 245;
  v := public.cph_store_paste_preview(245, jsonb_build_array(
    jsonb_build_object('op','update_line','line_id',l_box,'expected_version',
      (select content_version from public.customer_pricing_lines where id = l_box),
      'set',jsonb_build_object('sob_state','allocated_quantity','sob_pct',null,'sob_allocated_boxes','0')),
    jsonb_build_object('op','update_line','line_id',l_zero,'expected_version',
      (select content_version from public.customer_pricing_lines where id = l_zero),
      'set',jsonb_build_object('notes','blank SOB cell')),
    jsonb_build_object('op','update_line','line_id',l_pct,'expected_version',
      (select content_version from public.customer_pricing_lines where id = l_pct),
      'set',jsonb_build_object('sob_state','not_captured','sob_pct',null,'sob_allocated_boxes',null)),
    jsonb_build_object('op','create_line','key','n1','cycle_id',v_cycle,'scope_text','Pasted boxes',
      'customer_location_id',null,'plant_id',null,'sku_id',null,
      'sob_state','allocated_quantity','sob_pct',null,'sob_allocated_boxes','12000')));
  v := public.cph_apply_paste(245, (v->>'preview_id')::uuid, v->>'digest');
  select string_agg(scope_text || '=' || sob_state || ':' || coalesce(sob_pct::text, '∅') || ':'
                    || coalesce(sob_allocated_boxes::text, '∅') || ':' || coalesce(customer_location_id::text, '∅')
                    || coalesce(plant_id::text, '∅') || coalesce(sku_id::text, '∅'), ' ' order by id) into v_t
    from public.customer_pricing_lines where cycle_id = v_cycle;
  log := log || case when v_t = 'Pct=not_captured:∅:∅:∅∅∅ Box=allocated_quantity:∅:0:∅∅∅ Zero=allocated_quantity:∅:0:∅∅∅ Und=undefined:∅:∅:∅∅∅ Pasted boxes=allocated_quantity:∅:12000:∅∅∅'
    then E'\nok   ' else E'\nFAIL ' end || 'paste applied (0 boxes kept, blank kept, clear emptied both, no identity invented): ' || coalesce(v_t, 'NONE');
  if v_t is distinct from 'Pct=not_captured:∅:∅:∅∅∅ Box=allocated_quantity:∅:0:∅∅∅ Zero=allocated_quantity:∅:0:∅∅∅ Und=undefined:∅:∅:∅∅∅ Pasted boxes=allocated_quantity:∅:12000:∅∅∅' then
    fails := fails + 1;
  end if;
  select count(*) into v_n from public.customer_pricing_change_events where party_id = 245;
  log := log || case when (v->>'applied')::int = 4 and v_n - v_prev_count = 4 then E'\nok   ' else E'\nFAIL ' end
    || 'one apply, 4 changes, 4 audit rows in the same transaction (' || (v_n - v_prev_count) || ')';
  if (v->>'applied')::int <> 4 or v_n - v_prev_count <> 4 then fails := fails + 1; end if;

  -- ── paste that bypassed the route: a mixed triple or a fractional quantity rolls the WHOLE batch back
  for r in select * from (values
      ('mixed % and boxes', jsonb_build_object('sob_state','percentage','sob_pct','5.00','sob_allocated_boxes','5'), '23514'),
      ('fractional boxes',  jsonb_build_object('sob_state','allocated_quantity','sob_pct',null,'sob_allocated_boxes','12.5'), '22P02'))
      as t(label, sob, code) loop
    select count(*) into v_n from public.customer_pricing_change_events where party_id = 245;
    v := public.cph_store_paste_preview(245, jsonb_build_array(
      jsonb_build_object('op','update_line','line_id',l_und,'expected_version',
        (select content_version from public.customer_pricing_lines where id = l_und),
        'set',jsonb_build_object('notes','must roll back')),
      jsonb_build_object('op','update_line','line_id',l_zero,'expected_version',
        (select content_version from public.customer_pricing_lines where id = l_zero),'set',r.sob)));
    begin
      perform public.cph_apply_paste(245, (v->>'preview_id')::uuid, v->>'digest');
      fails := fails + 1; log := log || E'\nFAIL paste applied: ' || r.label;
    exception when others then
      log := log || case when sqlstate = r.code then E'\nok   ' else E'\nFAIL ' end || 'paste refused: ' || r.label || ' ' || sqlstate;
      if sqlstate <> r.code then fails := fails + 1; end if;
    end;
    select count(*) into v_n2 from public.customer_pricing_change_events where party_id = 245;
    select coalesce(notes, 'blank') into v_t from public.customer_pricing_lines where id = l_und;
    log := log || case when v_n2 = v_n and v_t = 'blank' then E'\nok   ' else E'\nFAIL ' end
      || '... earlier op and its audit rolled back too (notes ' || v_t || ', audit delta ' || (v_n2 - v_n) || ')';
    if v_n2 <> v_n or v_t <> 'blank' then fails := fails + 1; end if;
  end loop;
  select sob_allocated_boxes::text into v_t from public.customer_pricing_lines where id = l_zero;
  if v_t is distinct from '0' then fails := fails + 1; log := log || E'\nFAIL 0 boxes changed by a failed batch: ' || coalesce(v_t, 'NULL'); end if;
  execute 'reset role';

  -- Fingerprint of the exact text that ran, to compare with the stripped batch built from the repo files.
  log := log || E'\nbatch md5 ' || md5(current_query()) || ' length ' || length(current_query());
  raise exception 'P0.4.1 REHEARSAL ROLLED BACK. failures=% %', fails, log;
end $rehearse41$;
