-- Repair tests.run_all(): the catalogue suites were registered with the wrong
-- projection and have been aborting the WHOLE regression harness since
-- 20260917182138.
--
-- WHAT WAS WRONG. Every pgTAP suite in this codebase returns SETOF text, and so
-- does tests.run_all(). The three catalogue suites instead return
-- TABLE(ok boolean, name text), which is the right shape for reading a
-- catalogue directly but NOT a pgTAP result. Registering them as
--
--   return query select * from tests.gsm_master_catalogue();
--
-- therefore fed a two-column boolean/text row into a SETOF text function, and
-- Postgres refused it at run time:
--
--   42804 structure of query does not match function result type
--   DETAIL: Returned type boolean does not match expected type text in column 1
--   CONTEXT: SQL statement "select * from tests.gsm_master_catalogue()"
--            PL/pgSQL function tests.run_all() line 34 at RETURN QUERY
--
-- Line 34 is the FIRST catalogue suite, so run_all() aborted there and every
-- suite after it - the large majority of the harness - has not executed since.
-- This was not detected because the failure is a run-time type error, not a
-- failing assertion: nothing reports "0 tests ran", the call simply raises.
--
-- THE FIX. Project each catalogue row through pgTAP's own ok(boolean, text)
-- (it lives in `extensions` here, not `public`). That returns text, so the
-- shape matches, and each gate becomes a properly numbered assertion counted
-- in the plan rather than an untracked side channel.
--
-- SPLICED, NOT RETYPED, with a per-line occurrence guard, so concurrent
-- registrations already present in the stored function survive.

do $mig$
declare
  v_def   text;
  v_suite text;
  v_old   text;
  v_new   text;
  v_cnt   integer;
begin
  v_def := pg_catalog.pg_get_functiondef('tests.run_all()'::regprocedure);

  foreach v_suite in array array[
    'gsm_master_catalogue',
    'u4_customer_family_sector_catalogue',
    'u5_governed_sector_master_catalogue'
  ]
  loop
    v_old := format('  return query select * from tests.%s();', v_suite);
    v_new := format('  return query select extensions.ok(c.ok, c.name) from tests.%s() c;', v_suite);

    if position(v_new in v_def) > 0 then
      raise exception 'suite % is already projected through ok()', v_suite;
    end if;

    v_cnt := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_cnt <> 1 then
      raise exception 'expected exactly 1 registration line for %, found %', v_suite, v_cnt;
    end if;

    v_def := replace(v_def, v_old, v_new);
  end loop;

  execute v_def;

  v_def := pg_catalog.pg_get_functiondef('tests.run_all()'::regprocedure);
  foreach v_suite in array array[
    'gsm_master_catalogue',
    'u4_customer_family_sector_catalogue',
    'u5_governed_sector_master_catalogue'
  ]
  loop
    if position(format('from tests.%s() c;', v_suite) in v_def) = 0 then
      raise exception 'projection repair verification failed for %', v_suite;
    end if;
  end loop;
end $mig$;

revoke all on function tests.run_all() from public, anon, authenticated;
