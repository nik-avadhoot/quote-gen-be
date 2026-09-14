-- S7-R/12: supplier credit stays inside the Rate Master (Product Owner correction).
--
-- WHAT WAS WRONG. S7-R/6 introduced resolve_row_supplier_credit and S7-R/7
-- carried its answer into effective_inputs.resolved.supplier_credit and into a
-- Calculate refusal, 'supplier_credit_ambiguous', for a board whose five grades
-- carried different per-grade credit terms. That treated supplier credit as a
-- Batch-costing input. It is not. Supplier-credit interest belongs wholly to
-- Rate Master construction; its commercial effect ENDS when the governed
-- material rate is established, and Calculate consumes the resulting effective
-- material rates. The "FINDING 2" recorded at S7-R/6 is withdrawn with it:
-- there was never a one-slot question to answer, because Calculate never owned
-- the slot.
--
-- WHAT CHANGES.
--   * resolved.supplier_credit is removed from effective_inputs;
--   * the supplier_credit_ambiguous refusal is removed from Calculate
--     eligibility, so a five-grade board is never refused because its grades
--     came from different credit terms;
--   * app_private.resolve_row_supplier_credit is dropped - there is no
--     grade-selection rule, because there is nothing to select.
-- qcf/1 and the qca/1 attestation tuple never carried supplier credit, so
-- neither changes and both golden vectors stand.
--
-- WHAT IS PRESERVED, SO THE UPSTREAM AUTHORITY STAYS REPRODUCIBLE.
--   * provenance.rate_set_version_id - the governed Rate Set Version, unchanged;
--   * provenance.layer_rate_entries - NEW: for each of TOP, F1, L1, F2, L2, the
--     id of the governed rate entry for that layer's grade in that version.
--     uk_rate_entry (rate_set_version_id, grade_code) makes this an exact
--     identity lookup, not a selection, and trg_re_follows_version freezes the
--     entry once its version is approved - so the reference is durable.
--   * The effective per-layer material RATE is the engine's output, carried in
--     the attested results.row_details[].rate. The database does not recompute
--     it: doing so would duplicate the Rate Master's internal derivation, which
--     is exactly what this correction forbids.
--
-- THE EXECUTOR STILL NEEDS THE RATE MASTER'S ROWS to run the unchanged engine,
-- so calculate_inputs now also returns `rates` - the governed entries named by
-- layer_rate_entries, passed through as stored. They are an executor input, not
-- part of effective_inputs, and the database interprets nothing in them.
--
-- CUSTOMER PAYMENT-TERM INTEREST IS UNTOUCHED. resolve_row_interest is its own
-- chain (Pricing Group override -> derived annual -> versioned fallback) and
-- never read a rate entry; CP-118 proves that structurally and by effect.
--
-- The Rate Master, rate_entries.interest_pct, rate_set_versions.credit_cost_pct
-- and the settled S7 supplier-credit behaviour are not changed here.
--
-- Spliced against the live definitions with every occurrence count asserted;
-- calculate_inputs, which gains a key, is restated in full.

do $mig$
declare
  v_def text; v_cnt int;
  a1 constant text := E'\n\n  select * into v_sc from app_private.resolve_row_supplier_credit(p_batch_row_id);\n  if v_sc.o_ambiguous then\n    raise exception ''supplier_credit_ambiguous'' using errcode = ''PT422'';\n  end if;';
  a2 constant text := E'  v_fr record; v_sc record;\n';
  b1 constant text := 'v_inh record; v_int record; v_fr record; v_sc record; v_fl record;';
  b2 constant text := E'  select * into v_sc  from app_private.resolve_row_supplier_credit(p_batch_row_id);\n';
  b3 constant text := E'        ''degraded_from'', v_fr.o_degraded_from),\n      ''supplier_credit'', jsonb_build_object(\n        ''value'', pg_catalog.trim_scale(v_sc.o_value), ''source'', v_sc.o_source,\n        ''rate_entry_id'', v_sc.o_rate_entry_id,\n        ''rate_set_version_id'', v_sc.o_rate_set_version_id)),';
  b4 constant text := E'      ''rate_set_version_id'', v_pbr.rate_set_version_id,\n';
  b4n constant text :=
       E'      ''rate_set_version_id'', v_pbr.rate_set_version_id,\n'
    || E'      ''layer_rate_entries'', jsonb_build_object(\n'
    || E'        ''TOP'', (select re.id from public.rate_entries re where re.rate_set_version_id = v_pbr.rate_set_version_id and re.grade_code = v_cv.layer_top_code),\n'
    || E'        ''F1'',  (select re.id from public.rate_entries re where re.rate_set_version_id = v_pbr.rate_set_version_id and re.grade_code = v_cv.layer_f1_code),\n'
    || E'        ''L1'',  (select re.id from public.rate_entries re where re.rate_set_version_id = v_pbr.rate_set_version_id and re.grade_code = v_cv.layer_l1_code),\n'
    || E'        ''F2'',  (select re.id from public.rate_entries re where re.rate_set_version_id = v_pbr.rate_set_version_id and re.grade_code = v_cv.layer_f2_code),\n'
    || E'        ''L2'',  (select re.id from public.rate_entries re where re.rate_set_version_id = v_pbr.rate_set_version_id and re.grade_code = v_cv.layer_l2_code)),\n';
begin
  -- 1. Calculate eligibility: no supplier-credit refusal.
  v_def := pg_catalog.pg_get_functiondef('app_private.assert_calculate_eligible(bigint)'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  if v_cnt <> 1 then raise exception 'a1: expected 1, found %', v_cnt; end if;
  v_def := replace(v_def, a1, '');
  v_cnt := (length(v_def) - length(replace(v_def, a2, ''))) / length(a2);
  if v_cnt <> 1 then raise exception 'a2: expected 1, found %', v_cnt; end if;
  v_def := replace(v_def, a2, E'  v_fr record;\n');
  execute v_def;

  -- 2. effective_inputs: no resolved.supplier_credit; per-layer rate entries in provenance.
  v_def := pg_catalog.pg_get_functiondef('app_private.build_effective_inputs(bigint)'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, b1, ''))) / length(b1);
  if v_cnt <> 1 then raise exception 'b1: expected 1, found %', v_cnt; end if;
  v_def := replace(v_def, b1, 'v_inh record; v_int record; v_fr record; v_fl record;');
  v_cnt := (length(v_def) - length(replace(v_def, b2, ''))) / length(b2);
  if v_cnt <> 1 then raise exception 'b2: expected 1, found %', v_cnt; end if;
  v_def := replace(v_def, b2, '');
  v_cnt := (length(v_def) - length(replace(v_def, b3, ''))) / length(b3);
  if v_cnt <> 1 then raise exception 'b3: expected 1, found %', v_cnt; end if;
  v_def := replace(v_def, b3, E'        ''degraded_from'', v_fr.o_degraded_from)),');
  v_cnt := (length(v_def) - length(replace(v_def, b4, ''))) / length(b4);
  if v_cnt <> 1 then raise exception 'b4: expected 1, found %', v_cnt; end if;
  v_def := replace(v_def, b4, b4n);
  execute v_def;

  -- 3. Nothing may still depend on the resolver about to be dropped.
  if exists (select 1 from pg_catalog.pg_proc p
               join pg_catalog.pg_namespace n on n.oid = p.pronamespace
              where n.nspname in ('app_private','public','tests')
                and p.proname <> 'resolve_row_supplier_credit'
                and p.prosrc like '%resolve_row_supplier_credit%') then
    raise exception 'a function still calls resolve_row_supplier_credit';
  end if;
end $mig$;

drop function app_private.resolve_row_supplier_credit(bigint);

create or replace function app_private.calculate_inputs(p_batch_row_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_row public.batch_rows%rowtype; v_b public.batches%rowtype;
  v_eng text; v_ei jsonb;
begin
  perform app_private.assert_calculate_eligible(p_batch_row_id);

  select * into v_row from public.batch_rows where id = p_batch_row_id;
  select * into v_b   from public.batches      where id = v_row.batch_id;
  select cdv.engine_version into v_eng
    from public.pricing_basis_releases pbr
    join public.calculation_default_versions cdv on cdv.id = pbr.calculation_default_version_id
   where pbr.id = v_b.pricing_basis_release_id;

  v_ei := app_private.build_effective_inputs(p_batch_row_id);

  return jsonb_build_object(
    'effective_inputs', v_ei,
    -- The Rate Master's own rows for this row's layers, exactly as stored, so the
    -- trusted executor can run the unchanged engine. Passed through, never
    -- interpreted here: supplier credit is applied inside the Rate Master's
    -- effective-rate construction, not by Calculate.
    'rates', (select coalesce(jsonb_agg(jsonb_build_object(
                  'rate_entry_id', re.id,
                  'grade_code',    re.grade_code,
                  'price',         pg_catalog.trim_scale(re.price),
                  'discount',      pg_catalog.trim_scale(re.discount),
                  'freight',       pg_catalog.trim_scale(re.freight),
                  'interest_pct',  pg_catalog.trim_scale(re.interest_pct)) order by re.id),
                '[]'::jsonb)
                from public.rate_entries re
               where re.id in (select (x.value #>> '{}')::bigint
                                 from jsonb_each(v_ei->'provenance'->'layer_rate_entries') x
                                where jsonb_typeof(x.value) = 'number')),
    'binding', jsonb_build_object(
      'auth_sub', (select auth.uid())::text,
      'app_user_id', app_private.current_app_user(),
      'batch_id', v_row.batch_id,
      'batch_row_id', v_row.id,
      'content_version', v_row.content_version,
      'pricing_basis_release_id', v_b.pricing_basis_release_id,
      'engine_version', v_eng,
      'calculation_fingerprint', app_private.calculation_fingerprint(p_batch_row_id),
      'presentation_fingerprint', app_private.presentation_fingerprint(p_batch_row_id)));
end $fn$;

-- pg_get_functiondef reproduces definitions, not grants; CREATE OR REPLACE keeps
-- them. Restated so the minimum-grant shape is visible here, not assumed.
revoke all on function app_private.assert_calculate_eligible(bigint) from public, anon, authenticated;
revoke all on function app_private.build_effective_inputs(bigint)    from public, anon, authenticated;
revoke all on function app_private.calculate_inputs(bigint)          from public, anon;
grant execute on function app_private.calculate_inputs(bigint)       to authenticated;