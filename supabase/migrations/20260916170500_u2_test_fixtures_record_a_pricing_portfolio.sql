-- Database test fixtures state a pricing portfolio for every SKU they insert (CDM-45).
--
-- Amendment 03 (20260916170000) makes skus.pricing_portfolio NOT NULL with no default, on
-- purpose: nothing may classify a SKU by itself. Nineteen fixture inserts in nine registered
-- suites predate it and insert a SKU without one, so tests.run_all would fail on a
-- not-null violation that says nothing about what each suite proves.
--
-- Each fixture now STATES 'Transactional' explicitly, exactly as C-02 requires of any writer.
-- This is a fixture value, not a default: no column, constraint or production path changes.
-- Every rewrite is asserted by count against the live definition, and grants are kept by
-- CREATE OR REPLACE. Runs after Amendment 03.

do $$
declare
  r record; v_def text; v_new text; v_have integer;
  v_expected constant jsonb := '{"__s7r_body": 2, "__s7r_rate_master_gates": 1, "__s9p_body": 1,
    "batch_set_cardinality": 1, "batch_sets": 1, "batch_workspace": 3, "family_c_authority": 3,
    "family_f_security": 1, "sku_master": 6}';
  v_pattern constant text := 'insert into public\.skus \(([^)]*)\)(\s*)values \(([^)]*)\)';
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'skus' and column_name = 'pricing_portfolio') then
    raise exception using errcode = 'object_not_in_prerequisite_state',
      message = 'Fixture portfolios need Amendment 03 storage.',
      hint = 'Apply 20260916170000_u2_sku_pricing_portfolio first.';
  end if;

  for r in select p.oid, p.proname from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'tests' and p.proname in (select pg_catalog.jsonb_object_keys(v_expected))
  loop
    v_def := pg_catalog.pg_get_functiondef(r.oid);
    select count(*) into v_have from pg_catalog.regexp_matches(v_def, v_pattern, 'g');
    if v_have <> (v_expected ->> r.proname)::integer then
      raise exception 'tests.% has % SKU fixture inserts, expected %', r.proname, v_have, v_expected ->> r.proname
        using errcode = '55000';
    end if;
    v_new := pg_catalog.regexp_replace(v_def, v_pattern,
      'insert into public.skus (\1, pricing_portfolio)\2values (\3, ''Transactional'')', 'g');
    execute v_new;
  end loop;

  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'tests'
         and pg_catalog.pg_get_functiondef(p.oid) ~ 'insert into public\.skus \((?![^)]*pricing_portfolio)[^)]*\)') > 0 then
    raise exception 'a test fixture still inserts a SKU without a pricing portfolio' using errcode = '55000';
  end if;
end $$;
