-- S4-6: point all four Family C suites at the minted fixture owner.
--
-- The change is one line in each of four functions:
--
--   -  select id into v_owner from public.app_users order by id limit 1;
--   +  v_owner := tests.__fixture_owner();
--
-- WHY THIS IS A TRANSFORMATION AND NOT FOUR RESTATEMENTS. The alternative was to
-- re-paste roughly 60KB of otherwise-identical function bodies so that one line
-- could differ in each. That is worse in the two ways that matter here. A
-- reviewer would have to diff four 300-line blocks to find the change, and a
-- single mis-transcription anywhere in those 60KB could leave a suite silently
-- differing from its reviewed source while still passing.
--
-- This form states the change, and refuses to apply if reality does not match
-- the statement. It requires exactly four target functions, requires the removed
-- line to appear exactly once in each, and re-reads every rewritten definition to
-- confirm the old line is gone and the new call is present. Any drift - a renamed
-- suite, an already-edited body, a second occurrence - aborts the migration
-- rather than silently rewriting something unintended.
--
-- The trade-off, stated rather than hidden: after this runs, prosrc for these
-- four functions is pg_get_functiondef's normalisation of the reviewed source
-- rather than the source text itself. It is deterministic - a replay reaches this
-- migration with the same four definitions and produces the same result - but a
-- later restatement of any of these suites should be written from the migration
-- history, not from prosrc.

do $rw$
declare
  r record;
  v_targets text[] := array['construction_library','sku_master',
                            'family_c_authority','product_workflow'];
  v_old  text := 'select id into v_owner from public.app_users order by id limit 1;';
  v_new  text := 'v_owner := tests.__fixture_owner();';
  v_def text; v_out text; v_hits int; v_done int := 0;
begin
  for r in select p.oid, p.proname
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'tests' and p.proname = any(v_targets)
            order by p.proname
  loop
    v_def  := pg_get_functiondef(r.oid);
    v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);

    if v_hits <> 1 then
      raise exception 'tests.% contains % occurrences of the borrow line, expected exactly 1',
        r.proname, v_hits using errcode = '55000';
    end if;

    v_out := replace(v_def, v_old, v_new);
    execute v_out;

    -- re-read from the catalogue: assert the rewrite actually took
    v_def := pg_get_functiondef(r.oid);
    if position(v_old in v_def) <> 0 then
      raise exception 'tests.% still borrows an identity after rewrite', r.proname
        using errcode = '55000';
    end if;
    if position('tests.__fixture_owner()' in v_def) = 0 then
      raise exception 'tests.% does not call the minted owner after rewrite', r.proname
        using errcode = '55000';
    end if;

    v_done := v_done + 1;
  end loop;

  if v_done <> 4 then
    raise exception 'expected exactly 4 Family C suites, rewrote %', v_done
      using errcode = '55000';
  end if;
end $rw$;