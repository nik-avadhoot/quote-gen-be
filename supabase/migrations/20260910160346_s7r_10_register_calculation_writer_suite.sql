-- S7-R/10: register tests.calculation_writer() in tests.run_all().
--
-- SPLICED, NOT RETYPED. This is the exact edit that caused the S7-5 defect:
-- run_all was rewritten by retyping the suite list from an older migration,
-- which silently dropped four assertions, and it was found by reconciling a
-- count rather than by any gate. tests.suite_registration() now fails loudly if
-- a suite in the tests schema is missing from run_all - but the safer edit is
-- still to substitute one anchor and leave every other line untouched, which is
-- what this does.
--
-- PLACED BEFORE synthetic_fixture_integrity, deliberately. That sweep asserts
-- no synthetic fixture identity survives, so it has to run after every suite
-- that mints one. calculation_writer tears down its own graph and its own test
-- key, so the sweep finds nothing left to object to.
--
-- PREDICTED DELTA, stated before running: +78 assertions.

do $mig$
declare
  v_def text; v_old text; v_cnt int;
begin
  v_old := '  return query select * from tests.synthetic_fixture_integrity();';
  v_def := pg_catalog.pg_get_functiondef('tests.run_all()'::regprocedure);

  if v_def like '%tests.calculation_writer()%' then
    raise exception 'calculation_writer is already registered';
  end if;
  v_cnt := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 synthetic_fixture_integrity anchor, found %', v_cnt;
  end if;

  execute replace(v_def, v_old,
    '  return query select * from tests.calculation_writer();' || E'\n' || v_old);
end $mig$;

revoke all on function tests.run_all() from public, anon, authenticated;