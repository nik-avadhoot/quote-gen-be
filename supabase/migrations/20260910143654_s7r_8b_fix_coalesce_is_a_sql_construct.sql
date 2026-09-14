-- S7-R/8b: fix - coalesce cannot be schema-qualified.
--
-- COALESCE is SQL syntax, not a function in pg_catalog, so
-- `pg_catalog.coalesce(a, b)` does not resolve: it looks for a two-argument
-- function of that name and finds none. The same class of mistake as the
-- two-argument unnest at S7-R/2a and the NORMALIZE keyword at S7-R/2 - three
-- constructs that LOOK like functions and are not. Leaving them unqualified is
-- safe because the parser resolves them, not the search path.
--
-- It surfaced only when a real Batch row reached assert_calculate_eligible,
-- because PL/pgSQL resolves expressions at first execution rather than at
-- CREATE time. Every one of the five functions had applied cleanly.
--
-- SPLICED, NOT RETYPED. That is the S7-5 rule, and S7-5 is exactly why it
-- exists: rewriting a live function by retyping it from another source silently
-- dropped four assertions from tests.run_all(), and the loss was found by
-- reconciling a count rather than by any gate. This migration therefore reads
-- each function's own current definition, substitutes one exact token, and puts
-- it back - so nothing else can change even by accident.
--
-- IT ASSERTS ITS OWN ARITHMETIC. Fifteen occurrences were counted across five
-- functions before this ran; the block refuses to commit unless it made exactly
-- fifteen substitutions and left none behind. A silent partial repair is the
-- failure mode being guarded against.

do $mig$
declare
  v_oids oid[];
  v_oid  oid;
  v_def  text;
  v_cnt  int;
  v_total int := 0;
begin
  -- Snapshot the target set FIRST. Iterating pg_proc while CREATE OR REPLACE
  -- rewrites it would be reading a catalog this loop is mutating.
  select array_agg(p.oid order by p.proname) into v_oids
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app_private'
     and p.prosrc like '%pg_catalog.coalesce%';

  if array_length(v_oids, 1) is distinct from 5 then
    raise exception 'expected 5 affected functions, found %', coalesce(array_length(v_oids,1), 0);
  end if;

  foreach v_oid in array v_oids loop
    v_def := pg_catalog.pg_get_functiondef(v_oid);
    v_cnt := (length(v_def) - length(replace(v_def, 'pg_catalog.coalesce', '')))
             / length('pg_catalog.coalesce');
    execute replace(v_def, 'pg_catalog.coalesce', 'coalesce');
    v_total := v_total + v_cnt;
  end loop;

  if v_total <> 15 then
    raise exception 'expected 15 substitutions, made %', v_total;
  end if;
  if exists (select 1 from pg_catalog.pg_proc p
               join pg_catalog.pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app_private' and p.prosrc like '%pg_catalog.coalesce%') then
    raise exception 'pg_catalog.coalesce still present after repair';
  end if;
end $mig$;

-- pg_get_functiondef reproduces the definition but NOT the grants, and
-- CREATE OR REPLACE preserves them - so these are restated rather than assumed.
revoke all on function app_private.assert_calculate_eligible(bigint)   from public, anon, authenticated;
revoke all on function app_private.build_effective_inputs(bigint)      from public, anon, authenticated;
revoke all on function app_private.calculation_payload(bigint)         from public, anon, authenticated;
revoke all on function app_private.presentation_payload(bigint)        from public, anon, authenticated;
revoke all on function app_private.resolve_row_supplier_credit(bigint) from public, anon, authenticated;