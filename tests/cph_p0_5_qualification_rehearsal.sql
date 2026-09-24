-- ═════ P0.5 QUALIFICATION REHEARSAL TAIL: always ends in RAISE, so the whole batch rolls back ═════
-- Run as ONE batch immediately after the text of
--   supabase/migrations/20260923150000_customer_pricing_history_p0_1.sql
--   supabase/migrations/20260923183000_customer_pricing_history_p0_2.sql
--   supabase/migrations/20260924044157_customer_pricing_history_p0_4.sql
--   supabase/migrations/20260924100057_customer_pricing_history_p0_4_1_sob_allocated_boxes.sql
-- Pre-activation evidence on the FINAL chain:
--   A. advisor-equivalent catalogue lints over every Customer Pricing History object
--      (the hosted advisors cannot see objects that exist only inside a rolled-back batch);
--   B. representative commercial scenarios through the governed writers;
--   C. authorization, identity substitution, direct-write refusal, CAS, paste-preview binding,
--      expiry/reuse, atomic mutation+audit and no hard delete;
--   D. independence: every other public/app_private table is byte-identical before and after.
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

create function pg_temp.val(p_role text, p_sub text, p_sql text) returns text
language plpgsql as $fn$
declare v text;
begin
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', p_role)::text, true);
    execute format('set local role %I', p_role);
    execute p_sql into v;
    execute 'reset role';
    return coalesce(v, '∅');
  exception when others then
    return 'ERR ' || sqlstate;
  end;
end $fn$;

-- Fingerprint of every table the pricing feature must never touch (owner read, RLS bypassed).
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

do $rehearse5$
declare
  log text := ''; fails int := 0; lints int := 0; checks int := 0;
  a_uid text := '79ea4710-1d3b-45b7-9dca-a2dc83503c2b';   -- app user 44, read_party_master
  b_uid text := 'e2ab29bb-94d4-447a-90ca-cafa34e85f83';   -- app user 45, read_party_master
  x_uid text := '39ff307e-504e-4f24-a6e8-5308efb59570';   -- app user 3440, NO read_party_master
  r record; v jsonb; v_t text; v_n int; v_n2 int; fp_before jsonb; fp_after jsonb;
  v_mech int; v_term bigint; v_bf bigint; v_cycle bigint; v_cyc_other bigint; v_line bigint; v_l_loc bigint;
  v_l_plant bigint; v_l_text bigint; v_l_sku bigint; v_cyc_sku bigint; v_offer bigint; v_counter bigint;
  v_final bigint; v_ver int; v_term_other bigint; v_prev jsonb; v_next jsonb; v_freq text; y int := 2030;
  tbl text; v_col text;
  tables text[] := array['customer_pricing_mechanisms','customer_pricing_cycles','customer_pricing_lines',
    'customer_pricing_negotiation_events','customer_pricing_change_events','customer_pricing_term_versions',
    'customer_pricing_bf_delta_sets','customer_pricing_bf_deltas','customer_pricing_line_measures',
    'customer_pricing_event_bf_rates'];
begin
  fp_before := pg_temp.fingerprint();

  -- ══ A. advisor-equivalent lints ═══════════════════════════════════════════
  -- 0013 rls_disabled_in_public / 0007 policy_exists_rls_disabled
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where (n.nspname = 'public' and c.relname = any (tables) or (n.nspname = 'app_private' and c.relname = 'cph_paste_previews'))
     and not (c.relrowsecurity and c.relforcerowsecurity);
  lints := lints + 1; if v_n <> 0 then fails := fails + 1; end if;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'L0013/0007 RLS enabled+forced on all 11 pricing tables (violations ' || v_n || ')';
  -- 0008 rls_enabled_no_policy: public tables each carry a policy; the private preview table has none BY DESIGN
  select count(*) into v_n from unnest(tables) t
   where not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = t);
  lints := lints + 1; if v_n <> 0 then fails := fails + 1; end if;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'L0008 every exposed pricing table has a policy (missing ' || v_n
    || '); app_private.cph_paste_previews has none by design (definer-only) - the hosted advisor would list it as INFO';
  -- 0006 multiple_permissive_policies
  select count(*) into v_n from (select tablename, cmd, r2 from pg_policies p, unnest(p.roles) r2
    where p.schemaname = 'public' and p.tablename = any (tables) and p.permissive = 'PERMISSIVE'
    group by 1, 2, 3 having count(*) > 1) x;
  lints := lints + 1; if v_n <> 0 then fails := fails + 1; end if;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'L0006 no table/role/command has more than one permissive policy (' || v_n || ')';
  -- 0003 auth_rls_initplan: the capability call is wrapped in a scalar sub-select (evaluated once per statement)
  select count(*) into v_n from pg_policies p
   where p.schemaname = 'public' and p.tablename = any (tables)
     and (p.qual not ilike '%select app_private.has_group_cap%' or p.qual ~* 'auth\.(uid|jwt)\(\)|current_setting\(');
  lints := lints + 1; if v_n <> 0 then fails := fails + 1; end if;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'L0003 every policy wraps its capability check in (select ...), no bare auth.uid()/current_setting (' || v_n || ')';
  -- 0001 unindexed_foreign_keys (splinter rule: an index whose leading columns contain every FK column)
  select coalesce(string_agg(c.conrelid::regclass || '.' || c.conname, ', '), '') into v_t
    from pg_constraint c join pg_class k on k.oid = c.conrelid join pg_namespace n on n.oid = k.relnamespace
   where c.contype = 'f' and ((n.nspname = 'public' and k.relname = any (tables)) or (n.nspname = 'app_private' and k.relname = 'cph_paste_previews'))
     and not exists (select 1 from pg_index i where i.indrelid = c.conrelid
                      and (string_to_array(i.indkey::text, ' ')::smallint[])[1:array_length(c.conkey, 1)] @> c.conkey);
  lints := lints + 1; if v_t <> '' then fails := fails + 1; end if;
  log := log || case when v_t = '' then E'\nok   ' else E'\nFAIL ' end || 'L0001 every pricing foreign key has a covering index [' || v_t || ']';
  -- 0009 duplicate_index
  select count(*) into v_n from (select i.indrelid, i.indkey::text, i.indclass::text, coalesce(pg_get_expr(i.indexprs, i.indrelid), ''),
      coalesce(pg_get_expr(i.indpred, i.indrelid), '') from pg_index i join pg_class k on k.oid = i.indrelid
      join pg_namespace n on n.oid = k.relnamespace
     where (n.nspname = 'public' and k.relname = any (tables)) or (n.nspname = 'app_private' and k.relname = 'cph_paste_previews')
     group by 1, 2, 3, 4, 5 having count(*) > 1) x;
  lints := lints + 1; if v_n <> 0 then fails := fails + 1; end if;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'L0009 no duplicate index on a pricing table (' || v_n || ')';
  -- 0011 function_search_path_mutable
  select coalesce(string_agg(n.nspname || '.' || p.proname, ', '), '') into v_t
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where (p.proname like 'cph\_%' or (n.nspname = 'tests' and p.proname like 'cph\_p0%'))
     and (p.proconfig is null or not exists (select 1 from unnest(p.proconfig) s where s like 'search_path=%'));
  lints := lints + 1; if v_t <> '' then fails := fails + 1; end if;
  log := log || case when v_t = '' then E'\nok   ' else E'\nFAIL ' end || 'L0011 every pricing function pins search_path [' || v_t || ']';
  -- 0028/0029 security definer reachable in an exposed schema: public wrappers must be INVOKER
  select coalesce(string_agg(p.proname, ', '), '') into v_t from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'cph\_%' and p.prosecdef;
  lints := lints + 1; if v_t <> '' then fails := fails + 1; end if;
  log := log || case when v_t = '' then E'\nok   ' else E'\nFAIL ' end || 'L0028/0029 no SECURITY DEFINER pricing function in the exposed public schema [' || v_t || ']';
  -- default PUBLIC execute revoked everywhere; anon executes nothing
  select coalesce(string_agg(n.nspname || '.' || p.proname, ', '), '') into v_t from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where (p.proname like 'cph\_%' or (n.nspname = 'tests' and p.proname like 'cph\_p0%'))
     and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or has_function_privilege('anon', p.oid, 'EXECUTE'));
  lints := lints + 1; if v_t <> '' then fails := fails + 1; end if;
  log := log || case when v_t = '' then E'\nok   ' else E'\nFAIL ' end || 'no pricing function is executable by PUBLIC or anon [' || v_t || ']';
  -- internal helpers/triggers are not executable by authenticated either
  select coalesce(string_agg(p.proname, ', '), '') into v_t from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app_private' and p.proname in ('cph_require_editor','cph_require_party','cph_before_update','cph_audit',
     'cph_freeze_parent','cph_change_log_immutable','cph_freeze_columns','cph_immutable_row','cph_event_snapshot',
     'cph_event_bf_snapshot','cph_event_bf_floor','cph_lock_customer','cph_check_money','cph_paste_check')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  lints := lints + 1; if v_t <> '' then fails := fails + 1; end if;
  log := log || case when v_t = '' then E'\nok   ' else E'\nFAIL ' end || 'internal pricing helpers/trigger functions are not executable by authenticated [' || v_t || ']';
  -- table privileges: authenticated SELECT only, anon nothing, nobody DELETE/TRUNCATE
  select count(*) into v_n from unnest(tables) t
   where not has_table_privilege('authenticated', 'public.' || t, 'SELECT')
      or has_table_privilege('authenticated', 'public.' || t, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      or has_table_privilege('anon', 'public.' || t, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE');
  lints := lints + 1; if v_n <> 0 then fails := fails + 1; end if;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'table grants: authenticated SELECT only, anon none, no DELETE/TRUNCATE (' || v_n || ')';
  -- no function can hard-delete commercial history, and none can void a round
  select coalesce(string_agg(p.proname, ', '), '') into v_t from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app_private') and p.proname like 'cph\_%' and p.prosrc ~* 'delete\s+from|truncate';
  lints := lints + 1; if v_t <> '' then fails := fails + 1; end if;
  log := log || case when v_t = '' then E'\nok   ' else E'\nFAIL ' end || 'no pricing function contains DELETE/TRUNCATE [' || v_t || ']';
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app_private' and p.proname like 'cph\_%' and p.prosrc ilike '%voided%';
  log := log || E'\nobs  functions able to set a round to voided: ' || v_n || ' (the status exists; no governed writer sets it)';
  -- independence, static: no pricing function or trigger reaches Costing/Quote/Pricing Basis/Batch objects
  select coalesce(string_agg(p.proname, ', '), '') into v_t from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app_private') and p.proname like 'cph\_%'
     and p.prosrc ~* 'public\.(quote|calculation|pricing_basis|batch|rate_|freight_|sector|construction|sku_versions)';
  lints := lints + 1; if v_t <> '' then fails := fails + 1; end if;
  log := log || case when v_t = '' then E'\nok   ' else E'\nFAIL ' end || 'no pricing function references a Costing/Quote/Pricing-Basis/Batch table [' || v_t || ']';
  select count(*) into v_n from pg_trigger t join pg_proc p on p.oid = t.tgfoid join pg_class k on k.oid = t.tgrelid
   where p.proname like 'cph\_%' and not (k.relname = any (tables));
  lints := lints + 1; if v_n <> 0 then fails := fails + 1; end if;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'no pricing trigger is attached outside the pricing tables (' || v_n || ')';
  -- preview expiry is bounded by the table itself
  select count(*) into v_n from pg_constraint where conrelid = 'app_private.cph_paste_previews'::regclass
   and conname = 'ck_cpp_expiry' and pg_get_constraintdef(oid) like '%''00:30:00''::interval%';
  lints := lints + 1; if v_n <> 1 then fails := fails + 1; end if;
  log := log || case when v_n = 1 then E'\nok   ' else E'\nFAIL ' end || 'preview expiry bounded to <= 30 minutes by ck_cpp_expiry';

  -- ══ B. representative scenarios ═══════════════════════════════════════════
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  -- mechanism: Kraft paper per kg on Paper consumed, including GST
  perform public.cph_save_mechanism(245, null, 'monthly', 'financial_year', 'kraft_paper_per_kg', 'paper_consumed', 'including_gst', null);
  -- every Rate Basis x Weight Basis is accepted (CAS chain), an unknown one refused
  v_ver := 1;
  for r in select rb, wb from unnest(array['box_per_piece','box_per_kg','kraft_paper_per_kg','box_per_sqm']) rb,
                               unnest(array['paper_consumed','sheet_weight','box_weight']) wb loop
    v := public.cph_save_mechanism(245, v_ver, 'monthly', 'financial_year', r.rb, r.wb, 'including_gst', null);
    v_ver := (v->>'content_version')::int;
  end loop;
  checks := checks + 1;
  log := log || case when v_ver = 13 then E'\nok   ' else E'\nFAIL ' end || 'all 4 Rate Bases x 3 Weight Bases accepted through CAS (version ' || v_ver || ')';
  if v_ver <> 13 then fails := fails + 1; end if;
  v := public.cph_save_mechanism(245, v_ver, 'monthly', 'financial_year', 'kraft_paper_per_kg', 'paper_consumed', 'including_gst', null);
  v_ver := (v->>'content_version')::int;
  begin
    perform public.cph_save_mechanism(245, v_ver, 'monthly', 'financial_year', 'per_tonne', null, 'including_gst', null);
    fails := fails + 1; log := log || E'\nFAIL unknown rate basis accepted';
  exception when others then checks := checks + 1;
    log := log || case when sqlstate = '23514' then E'\nok   ' else E'\nFAIL ' end || 'unknown rate basis refused ' || sqlstate;
    if sqlstate <> '23514' then fails := fails + 1; end if;
  end;
  -- every approved frequency makes a Cycle
  foreach v_freq in array array['monthly','bimonthly','quarterly','half_yearly','annual','ad_hoc'] loop
    perform public.cph_create_cycle(245, make_date(y, 1, 1), make_date(y, 12, 31), make_date(y - 1, 12, 20), v_freq, null, null);
    y := y + 1;
  end loop;
  select string_agg(review_frequency, ',' order by period_start) into v_t from public.customer_pricing_cycles where party_id = 245 and period_start >= '2030-01-01';
  checks := checks + 1;
  log := log || case when v_t = 'monthly,bimonthly,quarterly,half_yearly,annual,ad_hoc' then E'\nok   ' else E'\nFAIL ' end || 'a Cycle for every approved frequency: ' || v_t;
  if v_t is distinct from 'monthly,bimonthly,quarterly,half_yearly,annual,ad_hoc' then fails := fails + 1; end if;
  -- Stable Term with effective dates (fixed annual conversion/freight), a later version closing the prior
  v_term := (public.cph_create_term_version(245, null, null, '2026-04-01', null, false, null, null, 'added_pct', 3.00,
             'delivered_included', 8.50, 0.00, 'email', '2026-03-25', 'FY terms', null)->>'id')::bigint;
  v := public.cph_create_term_version(245, null, null, '2026-10-01', null, true, null, null, 'added_pct', 3.00,
             'delivered_included', 9.00, 0.00, 'email', '2026-09-20', 'H2 terms', null);
  select effective_to::text into v_t from public.customer_pricing_term_versions where id = v_term;
  checks := checks + 1;
  log := log || case when v_t = '2026-09-30' then E'\nok   ' else E'\nFAIL ' end || 'a later Stable Term closes the prior one the day before (' || coalesce(v_t, 'open') || ')';
  if v_t is distinct from '2026-09-30' then fails := fails + 1; end if;
  begin
    perform public.cph_create_term_version(245, null, null, '2026-05-01', '2026-06-30', false, null, null, null, null, null, 1.00, null, null, null, null, null);
    fails := fails + 1; log := log || E'\nFAIL overlapping Stable Term accepted';
  exception when others then checks := checks + 1;
    log := log || case when sqlstate = '23P01' then E'\nok   ' else E'\nFAIL ' end || 'overlapping active Stable Term refused ' || sqlstate;
    if sqlstate <> '23P01' then fails := fails + 1; end if;
  end;
  v_bf := (public.cph_create_bf_delta_set(245, null, null, '2026-04-01', null, false, '18',
           '[{"bf_code":"16","delta_inr":"-1.00"},{"bf_code":"20","delta_inr":"1.50"},{"bf_code":"22","delta_inr":"3.25"}]'::jsonb,
           null, null, null, null)->>'id')::bigint;
  -- scopes: whole Customer, Location, Plant, free text (and SKU on the Customer that owns one)
  v_cycle := (public.cph_create_cycle(245, '2026-09-01', '2026-09-30', '2026-08-24', null, null, null)->>'id')::bigint;
  v_line   := (public.cph_create_line(v_cycle, null, null, null, null, 'not_captured', null, null, null)->>'id')::bigint;
  v_l_loc  := (public.cph_create_line(v_cycle, 122, null, null, null, 'undefined', null, null, null)->>'id')::bigint;
  v_l_plant:= (public.cph_create_line(v_cycle, 122, 1, null, null, 'not_applicable', null, null, null)->>'id')::bigint;
  v_l_text := (public.cph_create_line(v_cycle, null, null, null, 'Printed trays', 'percentage', 0.00, null, null)->>'id')::bigint;
  perform public.cph_create_line(v_cycle, 599, null, null, null, 'allocated_quantity', null, 0, null);
  perform public.cph_create_line(v_cycle, 600, null, null, null, 'percentage', 40.00, null, null);
  select string_agg(coalesce(customer_location_id::text, '-') || '/' || coalesce(plant_id::text, '-') || '/'
         || coalesce(scope_text, '-') || '=' || sob_state || ':' || coalesce(sob_pct::text, '∅') || ':' || coalesce(sob_allocated_boxes::text, '∅'),
         ' ' order by id) into v_t from public.customer_pricing_lines where cycle_id = v_cycle;
  checks := checks + 1;
  if v_t is distinct from '-/-/-=not_captured:∅:∅ 122/-/-=undefined:∅:∅ 122/1/-=not_applicable:∅:∅ -/-/Printed trays=percentage:0.00:∅ 599/-/-=allocated_quantity:∅:0 600/-/-=percentage:40.00:∅' then
    fails := fails + 1; log := log || E'\nFAIL ';
  else log := log || E'\nok   '; end if;
  log := log || 'Customer / Location / Location+Plant / free-text scopes carry all five SOB states: ' || v_t;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.cph_save_mechanism(1151, null, 'quarterly', 'financial_year', 'box_per_piece', null, 'excluding_gst', null);
  v_cyc_sku := (public.cph_create_cycle(1151, '2026-10-01', '2026-12-31', '2026-09-24', null, null, null)->>'id')::bigint;
  v_l_sku := (public.cph_create_line(v_cyc_sku, null, 1, 987, null, 'not_captured', null, null, null)->>'id')::bigint;
  checks := checks + 1; log := log || E'\nok   SKU scope accepted only with the SKU''s own Customer and Plant (line ' || v_l_sku || ')';
  begin
    perform public.cph_create_line(v_cyc_sku, null, 2, 987, 'wrong plant', 'not_captured', null, null, null);
    fails := fails + 1; log := log || E'\nFAIL SKU at another Plant accepted';
  exception when others then checks := checks + 1;
    log := log || case when sqlstate = '23503' then E'\nok   ' else E'\nFAIL ' end || 'SKU at another Plant refused ' || sqlstate;
    if sqlstate <> '23503' then fails := fails + 1; end if;
  end;
  -- negotiation: first offer, two counters, final agreement (GST-inclusive), correction, BF snapshot + override
  select content_version into v_ver from public.customer_pricing_lines where id = v_line;
  perform public.cph_set_line_references(v_line, v_ver, v_term, v_bf);
  v_offer := (public.cph_add_round(v_line, 'avadhoot_offer', '2026-08-25', 56.00, null, 18.00, null, null, null,
              'email', '2026-08-25', 'offer', null, gen_random_uuid())->>'id')::bigint;
  v_counter := (public.cph_add_round(v_line, 'customer_counter', '2026-08-26', 52.00, null, 18.00, null, null, null,
              'call', null, null, null, gen_random_uuid())->>'id')::bigint;
  perform public.cph_add_round(v_line, 'customer_counter', '2026-08-28', 53.50, null, 18.00, null, null, null,
              'whatsapp', null, null, null, gen_random_uuid());
  v_final := (public.cph_add_round(v_line, 'final_agreement', '2026-08-30', 54.25, null, 18.00, 45.00, 8.00, 1.25,
              'meeting', null, null, null, gen_random_uuid())->>'id')::bigint;
  select tax_treatment || ':' || gst_pct || ':' || rate_basis || ':' || weight_basis || ':' || snap_conversion_inr_per_kg || ':' || base_bf_code
    into v_t from public.customer_pricing_negotiation_events where id = v_final;
  checks := checks + 1;
  log := log || case when v_t = 'including_gst:18.00:kraft_paper_per_kg:paper_consumed:8.50:18' then E'\nok   ' else E'\nFAIL ' end
    || 'final agreement snapshots GST-inclusive tax, bases, the applicable Stable Term and the BF base: ' || coalesce(v_t, '∅');
  if v_t is distinct from 'including_gst:18.00:kraft_paper_per_kg:paper_consumed:8.50:18' then fails := fails + 1; end if;
  select content_version into v_ver from public.customer_pricing_negotiation_events where id = v_final;
  perform public.cph_set_bf_override(v_final, v_ver, '22', 57.00);
  select string_agg(bf_code || ':' || delta_inr || ':' || coalesce(override_rate_inr::text, 'derived'), ' ' order by bf_code) into v_t
    from public.customer_pricing_event_bf_rates where event_id = v_final;
  checks := checks + 1;
  log := log || case when v_t = '16:-1.00:derived 20:1.50:derived 22:3.25:57.00' then E'\nok   ' else E'\nFAIL ' end
    || 'BF schedule snapshotted as signed deltas; one explicit override kept beside the derived rate: ' || coalesce(v_t, '∅');
  if v_t is distinct from '16:-1.00:derived 20:1.50:derived 22:3.25:57.00' then fails := fails + 1; end if;
  select content_version into v_ver from public.customer_pricing_negotiation_events where id = v_counter;
  perform public.cph_correct_round(v_counter, v_ver, 'customer_counter', '2026-08-26', 52.50, null, 18.00, null, null, null, 'call', null, 'corrected', null);
  select count(*) into v_n from public.customer_pricing_change_events where entity_type = 'negotiation_event' and entity_id = v_counter and operation = 'update';
  select string_agg(event_type || '#' || sequence_no, ',' order by event_date, sequence_no) into v_t from public.customer_pricing_negotiation_events where line_id = v_line;
  checks := checks + 1;
  log := log || case when v_n = 1 and v_t = 'avadhoot_offer#1,customer_counter#2,customer_counter#3,final_agreement#4' then E'\nok   ' else E'\nFAIL ' end
    || 'correction is one audited update of that round; every round kept in order: ' || coalesce(v_t, '∅');
  if v_n <> 1 or v_t is distinct from 'avadhoot_offer#1,customer_counter#2,customer_counter#3,final_agreement#4' then fails := fails + 1; end if;
  -- a later mechanism change never reinterprets an earlier round
  select content_version into v_ver from public.customer_pricing_mechanisms where party_id = 245;
  perform public.cph_save_mechanism(245, v_ver, 'monthly', 'financial_year', 'box_per_piece', null, 'excluding_gst', null);
  select tax_treatment || ':' || rate_basis into v_t from public.customer_pricing_negotiation_events where id = v_final;
  checks := checks + 1;
  log := log || case when v_t = 'including_gst:kraft_paper_per_kg' then E'\nok   ' else E'\nFAIL ' end || 'mechanism change leaves the earlier round''s snapshot intact: ' || coalesce(v_t, '∅');
  if v_t is distinct from 'including_gst:kraft_paper_per_kg' then fails := fails + 1; end if;
  -- Start next cycle: structure and the applicable term/BF only; SOB, rounds, rates blank
  v_next := public.cph_start_next_cycle(v_cycle, '2026-10-01', '2026-10-31', '2026-09-24', null);
  select count(*), count(*) filter (where sob_state = 'not_captured' and sob_pct is null and sob_allocated_boxes is null
           and prior_line_id is not null
           and not exists (select 1 from public.customer_pricing_negotiation_events e where e.line_id = l.id))
    into v_n, v_n2 from public.customer_pricing_lines l where cycle_id = (v_next->>'id')::bigint;
  select t.effective_from::text into v_t from public.customer_pricing_lines l join public.customer_pricing_term_versions t on t.id = l.term_version_id
   where l.cycle_id = (v_next->>'id')::bigint and l.prior_line_id = v_line;
  checks := checks + 1;
  log := log || case when v_n = 6 and v_n2 = 6 and v_t = '2026-10-01' then E'\nok   ' else E'\nFAIL ' end
    || 'Start next cycle: ' || v_n2 || '/' || v_n || ' lines blank (SOB reset, no rounds, linked to prior) and the Oct term version applies (' || coalesce(v_t, '∅') || ')';
  if v_n <> 6 or v_n2 <> 6 or v_t is distinct from '2026-10-01' then fails := fails + 1; end if;
  execute 'reset role';

  -- ══ C. authorization and concurrency ══════════════════════════════════════
  -- anon
  foreach tbl in array array['customer_pricing_lines', 'customer_pricing_change_events'] loop
    v_t := pg_temp.try('anon', null, format('select count(*) from public.%I', tbl));
    checks := checks + 1; if v_t <> '42501' then fails := fails + 1; end if;
    log := log || case when v_t = '42501' then E'\nok   ' else E'\nFAIL ' end || 'anon read of ' || tbl || ' refused ' || v_t;
  end loop;
  for r in select * from (values
      ('anon mechanism write', 'select public.cph_save_mechanism(245, null, ''monthly'', null, null, null, null, null)'),
      ('anon paste preview', 'select public.cph_store_paste_preview(245, ''[]''::jsonb)'),
      ('anon private definer', format('select app_private.cph_create_cycle(245, %L, %L, %L, null, null, null)', '2027-01-01', '2027-01-31', '2026-12-20'))) t(label, q) loop
    v_t := pg_temp.try('anon', null, r.q);
    checks := checks + 1; if v_t <> '42501' then fails := fails + 1; end if;
    log := log || case when v_t = '42501' then E'\nok   ' else E'\nFAIL ' end || r.label || ' refused ' || v_t;
  end loop;
  -- authenticated WITHOUT read_party_master: sees nothing, writes nothing
  v_t := pg_temp.val('authenticated', x_uid, 'select count(*)::text from public.customer_pricing_cycles where party_id = 245');
  checks := checks + 1; if v_t <> '0' then fails := fails + 1; end if;
  log := log || case when v_t = '0' then E'\nok   ' else E'\nFAIL ' end || 'no-capability user reads 0 of 245''s Cycles (RLS) → ' || v_t;
  v_t := pg_temp.val('authenticated', a_uid, 'select count(*)::text from public.customer_pricing_cycles where party_id = 245');
  checks := checks + 1; if v_t = '0' or v_t like 'ERR%' then fails := fails + 1; end if;
  log := log || case when v_t <> '0' and v_t not like 'ERR%' then E'\nok   ' else E'\nFAIL ' end || 'authorised user reads 245''s Cycles → ' || v_t;
  for r in select * from (values
      ('create Cycle', format('select public.cph_create_cycle(245, %L, %L, %L, null, null, null)', '2027-02-01', '2027-02-28', '2027-01-20')),
      ('update Line', format('select public.cph_update_line(%s, 1, null, null, null, null, ''undefined'', null, null, null)', v_line)),
      ('paste preview', format('select public.cph_store_paste_preview(245, %L::jsonb)', jsonb_build_array(jsonb_build_object('op','update_line','line_id',v_line,'expected_version',1,'set',jsonb_build_object('notes','x')))::text)),
      ('start next cycle', format('select public.cph_start_next_cycle(%s, %L, %L, %L, null)', v_cycle, '2026-11-01', '2026-11-30', '2026-10-24'))) t(label, q) loop
    v_t := pg_temp.try('authenticated', x_uid, r.q);
    checks := checks + 1; if v_t <> '42501' then fails := fails + 1; end if;
    log := log || case when v_t = '42501' then E'\nok   ' else E'\nFAIL ' end || 'no-capability ' || r.label || ' refused ' || v_t;
  end loop;
  -- direct table writes by an AUTHORISED user are refused on every table
  v_n := 0; v_t := '';
  foreach tbl in array tables loop
    -- UPDATE targets an ordinary column: `set id = id` would fail on the identity column (428C9)
    -- before the privilege check, which proves nothing about privileges.
    select a.attname into v_col from pg_attribute a
     where a.attrelid = ('public.' || tbl)::regclass and a.attnum > 0 and not a.attisdropped and a.attidentity = ''
     order by a.attnum limit 1;
    for r in select * from (values ('insert', format('insert into public.%I default values', tbl)),
                                   ('update', format('update public.%I set %I = %I', tbl, v_col, v_col)),
                                   ('delete', format('delete from public.%I', tbl)),
                                   ('truncate', format('truncate public.%I', tbl))) t(op, q) loop
      if pg_temp.try('authenticated', a_uid, r.q) <> '42501' then v_n := v_n + 1; v_t := v_t || tbl || ':' || r.op || ' '; end if;
    end loop;
  end loop;
  foreach tbl in array array['select count(*) from app_private.cph_paste_previews',
      'insert into app_private.cph_paste_previews (party_id, actor_app_user_id, payload, digest, op_count, expires_at) values (245, 44, ''[]'', ''x'', 1, now() + interval ''1 minute'')'] loop
    if pg_temp.try('authenticated', a_uid, tbl) <> '42501' then v_n := v_n + 1; v_t := v_t || 'preview '; end if;
  end loop;
  checks := checks + 1; if v_n <> 0 then fails := fails + 1; end if;
  log := log || case when v_n = 0 then E'\nok   ' else E'\nFAIL ' end || 'authorised user: 40 direct INSERT/UPDATE/DELETE/TRUNCATE (10 tables) + 2 preview-table statements all refused [' || v_t || ']';
  -- no hard delete even for the owner on the append-only / immutable tables
  execute 'reset role';
  begin
    delete from public.customer_pricing_change_events where party_id = 245;
    fails := fails + 1; log := log || E'\nFAIL owner deleted change events';
  exception when others then checks := checks + 1;
    log := log || case when sqlstate = '42501' then E'\nok   ' else E'\nFAIL ' end || 'change log is append-only even for the owner ' || sqlstate;
    if sqlstate <> '42501' then fails := fails + 1; end if;
  end;
  begin
    update public.customer_pricing_bf_deltas set delta_inr = 0 where set_id = v_bf;
    fails := fails + 1; log := log || E'\nFAIL owner rewrote a BF delta';
  exception when others then checks := checks + 1;
    log := log || case when sqlstate = '42501' then E'\nok   ' else E'\nFAIL ' end || 'a BF delta set''s deltas are immutable ' || sqlstate;
    if sqlstate <> '42501' then fails := fails + 1; end if;
  end;
  -- identity / path substitution
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.cph_save_mechanism(315, null, 'monthly', 'financial_year', null, null, 'excluding_gst', null);
  v_cyc_other := (public.cph_create_cycle(315, '2026-09-01', '2026-09-30', '2026-08-24', null, null, null)->>'id')::bigint;
  v_term_other := (public.cph_create_term_version(315, null, null, '2026-04-01', null, false, null, null, null, null, null, 7.00, null, null, null, null, null)->>'id')::bigint;
  execute 'reset role';
  for r in select * from (values
      ('another Customer''s Line addressed through 245''s paste', 'P0002',
        format('select public.cph_store_paste_preview(245, %L::jsonb)', jsonb_build_array(jsonb_build_object('op','update_line',
          'line_id', (select min(id) from public.customer_pricing_lines where party_id = 1151), 'expected_version', 1,
          'set', jsonb_build_object('notes','x')))::text)),
      ('another Customer''s Cycle addressed through 245''s paste', 'P0002',
        format('select public.cph_store_paste_preview(245, %L::jsonb)', jsonb_build_array(jsonb_build_object('op','create_line',
          'key','k1','cycle_id', v_cyc_other, 'scope_text','x'))::text)),
      ('another Customer''s Location on a 245 line', '23503',
        format('select public.cph_create_line(%s, 165, null, null, ''foreign'', ''not_captured'', null, null, null)', v_cycle)),
      ('another Customer''s Stable Term on a 245 line', '22023',
        format('select public.cph_set_line_references(%s, (select content_version from public.customer_pricing_lines where id = %s), %s, null)',
               v_l_text, v_l_text, v_term_other))) t(label, code, q) loop
    v_t := pg_temp.try('authenticated', a_uid, r.q);
    checks := checks + 1; if v_t <> r.code then fails := fails + 1; end if;
    log := log || case when v_t = r.code then E'\nok   ' else E'\nFAIL ' end || r.label || ' refused ' || v_t;
  end loop;
  -- stale CAS on every mutable kind writes nothing and logs nothing
  select count(*) into v_n from public.customer_pricing_change_events;
  for r in select * from (values
      ('mechanism', 'select public.cph_save_mechanism(245, 1, ''monthly'', null, null, null, null, ''stale'')'),
      ('Cycle', format('select public.cph_update_cycle(%s, 99, %L, %L, %L, null, ''stale'', null, null)', v_cycle, '2026-09-01', '2026-09-30', '2026-08-24')),
      ('Line', format('select public.cph_update_line(%s, 99, null, null, null, ''stale'', ''undefined'', null, null, null)', v_l_text)),
      ('Stable Term', format('select public.cph_correct_term_version(%s, 99, null, %L, null, null, null, null, null, null, 1.00, null, null, null, null, null)', v_term, '2026-04-01')),
      ('round', format('select public.cph_correct_round(%s, 99, ''avadhoot_offer'', %L, 1.00, null, 18.00, null, null, null, null, null, null, null)', v_offer, '2026-08-25')),
      ('BF override', format('select public.cph_set_bf_override(%s, 99, ''20'', 1.00)', v_final))) t(label, q) loop
    v_t := pg_temp.try('authenticated', a_uid, r.q);
    checks := checks + 1; if v_t <> 'PT409' then fails := fails + 1; end if;
    log := log || case when v_t = 'PT409' then E'\nok   ' else E'\nFAIL ' end || 'stale ' || r.label || ' refused ' || v_t;
  end loop;
  select count(*) into v_n2 from public.customer_pricing_change_events;
  select count(*) into v_t from public.customer_pricing_lines where scope_text = 'stale';
  checks := checks + 1; if v_n2 <> v_n or v_t <> '0' then fails := fails + 1; end if;
  log := log || case when v_n2 = v_n and v_t = '0' then E'\nok   ' else E'\nFAIL ' end || 'six stale writes: audit delta ' || (v_n2 - v_n) || ', rows changed ' || v_t;
  -- paste previews: stale, reused, expired, another user's, tampered digest
  perform set_config('request.jwt.claims', json_build_object('sub', a_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select content_version into v_ver from public.customer_pricing_lines where id = v_l_text;
  v_prev := public.cph_store_paste_preview(245, jsonb_build_array(jsonb_build_object('op','update_line','line_id',v_l_text,
            'expected_version', v_ver, 'set', jsonb_build_object('sob_state','allocated_quantity','sob_pct',null,'sob_allocated_boxes','25000'))));
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', b_uid, 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.cph_update_line(v_l_text, v_ver, null, null, null, 'Printed trays', 'percentage', 5.00, null, 'saved by B');
  v_t := pg_temp.try('authenticated', b_uid, format('select public.cph_apply_paste(245, %L, %L)', v_prev->>'preview_id', v_prev->>'digest'));
  execute 'reset role';
  checks := checks + 1; if v_t <> 'P0002' then fails := fails + 1; end if;
  log := log || case when v_t = 'P0002' then E'\nok   ' else E'\nFAIL ' end || 'another user cannot apply A''s preview ' || v_t;
  select count(*) into v_n from public.customer_pricing_change_events;
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_apply_paste(245, %L, %L)', v_prev->>'preview_id', v_prev->>'digest'));
  select count(*) into v_n2 from public.customer_pricing_change_events;
  checks := checks + 1;
  if v_t <> 'PT409' or v_n2 <> v_n or (select sob_state || ':' || sob_pct || ':' || notes from public.customer_pricing_lines where id = v_l_text) <> 'percentage:5.00:saved by B'
     or (select consumed_at from app_private.cph_paste_previews where id = (v_prev->>'preview_id')::uuid) is not null then
    fails := fails + 1; log := log || E'\nFAIL stale preview: ' || v_t;
  else
    log := log || E'\nok   stale preview refused PT409; B''s save kept, audit delta 0, preview left unconsumed';
  end if;
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_apply_paste(245, %L, %L)', v_prev->>'preview_id', repeat('0', 64)));
  checks := checks + 1; if v_t <> 'PT412' then fails := fails + 1; end if;
  log := log || case when v_t = 'PT412' then E'\nok   ' else E'\nFAIL ' end || 'tampered digest refused ' || v_t;
  select content_version into v_ver from public.customer_pricing_lines where id = v_l_text;
  v_prev := pg_temp.val('authenticated', a_uid, format('select public.cph_store_paste_preview(245, %L::jsonb)::text',
            jsonb_build_array(jsonb_build_object('op','update_line','line_id',v_l_text,'expected_version',v_ver,
            'set',jsonb_build_object('notes','pasted')))::text))::jsonb;
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_apply_paste(245, %L, %L)', v_prev->>'preview_id', v_prev->>'digest'))
      || '/' || pg_temp.try('authenticated', a_uid, format('select public.cph_apply_paste(245, %L, %L)', v_prev->>'preview_id', v_prev->>'digest'));
  checks := checks + 1; if v_t <> 'OK/PT410' then fails := fails + 1; end if;
  log := log || case when v_t = 'OK/PT410' then E'\nok   ' else E'\nFAIL ' end || 'a preview applies once; reuse refused (' || v_t || ')';
  select content_version into v_ver from public.customer_pricing_lines where id = v_l_text;
  v_prev := pg_temp.val('authenticated', a_uid, format('select public.cph_store_paste_preview(245, %L::jsonb)::text',
            jsonb_build_array(jsonb_build_object('op','update_line','line_id',v_l_text,'expected_version',v_ver,
            'set',jsonb_build_object('notes','late')))::text))::jsonb;
  update app_private.cph_paste_previews set created_at = now() - interval '1 hour', expires_at = now() - interval '45 minutes'
   where id = (v_prev->>'preview_id')::uuid;
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_apply_paste(245, %L, %L)', v_prev->>'preview_id', v_prev->>'digest'));
  checks := checks + 1;
  if v_t <> 'PT410' or (select notes from public.customer_pricing_lines where id = v_l_text) is distinct from 'pasted' then fails := fails + 1; end if;
  log := log || case when v_t = 'PT410' then E'\nok   ' else E'\nFAIL ' end || 'expired preview refused and wrote nothing ' || v_t;
  -- mutation and audit are one transaction: a failing later op undoes the earlier op and its audit
  select content_version into v_ver from public.customer_pricing_cycles where id = v_cycle;
  v_prev := pg_temp.val('authenticated', a_uid, format('select public.cph_store_paste_preview(245, %L::jsonb)::text',
            jsonb_build_array(jsonb_build_object('op','update_cycle','cycle_id',v_cycle,'expected_version',v_ver,'set',jsonb_build_object('notes','roll me back')),
                              jsonb_build_object('op','create_line','key','d1','cycle_id',v_cycle,'scope_text','Printed trays'))::text))::jsonb;
  select count(*) into v_n from public.customer_pricing_change_events;
  v_t := pg_temp.try('authenticated', a_uid, format('select public.cph_apply_paste(245, %L, %L)', v_prev->>'preview_id', v_prev->>'digest'));
  select count(*) into v_n2 from public.customer_pricing_change_events;
  checks := checks + 1;
  if v_t <> '23505' or v_n2 <> v_n or (select notes from public.customer_pricing_cycles where id = v_cycle) is not null then fails := fails + 1; end if;
  log := log || case when v_t = '23505' and v_n2 = v_n then E'\nok   ' else E'\nFAIL ' end || 'duplicate scope in a batch ' || v_t || ' rolled back the earlier Cycle note and its audit (delta ' || (v_n2 - v_n) || ')';

  -- ══ D. independence ═══════════════════════════════════════════════════════
  fp_after := pg_temp.fingerprint();
  select count(*) into v_n from jsonb_object_keys(fp_before);
  select coalesce(string_agg(k, ', '), '') into v_t from jsonb_object_keys(fp_before) k where fp_before -> k is distinct from fp_after -> k;
  checks := checks + 1; if v_t <> '' then fails := fails + 1; end if;
  log := log || case when v_t = '' then E'\nok   ' else E'\nFAIL ' end || 'all ' || v_n || ' non-pricing public/app_private tables byte-identical before and after every pricing write above [' || v_t || ']'
    || case when fp_before::text like '%unreadable%' then ' (unreadable to the owner: '
       || (select string_agg(k, ', ') from jsonb_each_text(fp_before) e(k, x) where x like 'unreadable%') || ')' else '' end;

  log := log || E'\nbatch md5 ' || md5(current_query()) || ' length ' || length(current_query());
  raise exception 'P0.5 REHEARSAL ROLLED BACK. failures=% lints=% checks=% %', fails, lints, checks, log;
end $rehearse5$;
