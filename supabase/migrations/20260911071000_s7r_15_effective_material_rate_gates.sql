-- S7-R/15: executable gates for the effective-material-rate boundary.
-- Predicted delta: +10 assertions (95 -> 105 focused).

do $mig$
declare
  v_def text; v_cnt int;
  c_decl constant text := '  v_in jsonb; v_fp_a text; v_fp_b text; v_res text; v_att text; v_id bigint; v_state text;';
  c_anchor constant text :=
    E'  return next ok((select bool_and((v_in->''provenance''->''layer_rate_entries''->>x.k)::bigint = re.id)\n'
    || E'                    from (values (''TOP'',''K150''),(''F1'',''SF100''),(''L1'',''K120''),(''F2'',''SF120''),(''L2'',''K200'')) x(k, g)\n'
    || E'                    join public.rate_entries re on re.rate_set_version_id = p_rsv and re.grade_code = x.g),\n'
    || E'    ''CP-117g by exact identity - (rate_set_version_id, grade_code) is unique, so this is a lookup, not a selection'');';
  c_add constant text := $sql$

  perform set_config('request.jwt.claims', p_oclaims, true);
  set local role authenticated;
  v_rates := app_private.calculate_inputs(v_row4)->'rates';
  reset role;
  return next is((select count(*)::int from jsonb_array_elements(v_rates)), 5,
    'CP-117k Calculate receives five governed material-rate inputs for the five layers');
  return next ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(x.value) k)
                                  = array['effective_material_rate','grade_code','rate_entry_id'])
                    from jsonb_array_elements(v_rates) x),
    'CP-117l every Calculate rate input has exactly identity, grade and effective_material_rate');
  return next ok(v_rates::text !~ '(interest|credit|price|discount|freight)',
    'CP-117m no supplier-credit term or raw Rate Master price component crosses into Calculate');
  return next is((select re.effective_material_rate from public.rate_entries re
                   where re.rate_set_version_id=p_rsv and re.grade_code='K150'), 40.60000000,
    'CP-117n the Rate Master stored the explicit 1.5 percent K150 outcome before Calculate');
  return next is((select re.effective_material_rate from public.rate_entries re
                   where re.rate_set_version_id=p_rsv and re.grade_code='K120'), 40.60000000,
    'CP-117o the Rate Master stored the version-fallback K120 outcome before Calculate');
  return next is((select re.effective_material_rate from public.rate_entries re
                   where re.rate_set_version_id=p_rsv and re.grade_code='SF120'), 40.00000000,
    'CP-117p an explicit zero supplier-credit term survives in the governed effective rate');
  return next ok((select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                   where n.nspname='app_private' and p.proname='calculate_inputs')
                 !~ '(interest_pct|credit_cost_pct|price|discount|freight)',
    'CP-117q calculate_inputs neither receives nor recalculates supplier-credit components');
  return next ok(not has_function_privilege('authenticated',
                   'app_private.establish_rate_entry_effective_material_rate()','EXECUTE')
              and not has_function_privilege('anon',
                   'app_private.establish_rate_entry_effective_material_rate()','EXECUTE'),
    'CP-117r the Rate Master establishment trigger has no API-role execution grant');
  return next ok(not has_function_privilege('authenticated',
                   'app_private.refresh_rate_entry_effective_material_rates()','EXECUTE')
              and not has_function_privilege('anon',
                   'app_private.refresh_rate_entry_effective_material_rates()','EXECUTE'),
    'CP-117s the Rate Set refresh trigger has no API-role execution grant');
  return next ok((select bool_and(p.proconfig = array['search_path=""'])
                    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                   where n.nspname='app_private'
                     and p.proname in ('establish_rate_entry_effective_material_rate',
                                      'refresh_rate_entry_effective_material_rates')),
    'CP-117t both privileged Rate Master helpers pin an empty search_path');
$sql$;
begin
  v_def := pg_catalog.pg_get_functiondef('tests.__s7r_rate_master_gates(bigint,bigint,bigint,bigint,bigint,bigint,bigint,uuid,bigint,text)'::regprocedure);
  v_cnt := (length(v_def)-length(replace(v_def,c_decl,'')))/length(c_decl);
  if v_cnt <> 1 then raise exception 'declaration anchor: expected 1, found %', v_cnt; end if;
  v_def := replace(v_def,c_decl,replace(c_decl,'v_in jsonb;','v_in jsonb; v_rates jsonb;'));
  v_cnt := (length(v_def)-length(replace(v_def,c_anchor,'')))/length(c_anchor);
  if v_cnt <> 1 then raise exception 'rate identity anchor: expected 1, found %', v_cnt; end if;
  execute replace(v_def,c_anchor,c_anchor || c_add);
end $mig$;

revoke all on function tests.__s7r_rate_master_gates(bigint,bigint,bigint,bigint,bigint,bigint,bigint,uuid,bigint,text)
  from public, anon, authenticated;
