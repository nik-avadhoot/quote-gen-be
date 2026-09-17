-- Wave A: register the two catalogue suites that were created but never added
-- to tests.run_all(). tests.suite_registration() already makes an omitted suite
-- fail SR-1; this migration restores the register without retyping its body.
-- Applied live as migration 20260917182138 under explicit Product Owner
-- authority on 2026-09-17.
--
-- SPLICED, NOT RETYPED. Each insertion uses one stable neighbouring suite as
-- its anchor and aborts unless that anchor occurs exactly once. This preserves
-- concurrent and future registrations already present in the stored function.

do $mig$
declare
  v_def              text;
  v_plant_anchor     text := '  return query select * from tests.plant_master();';
  v_customer_anchor  text := '  return query select * from tests.customer_family_mutations();';
  v_cnt              integer;
begin
  v_def := pg_catalog.pg_get_functiondef('tests.run_all()'::regprocedure);

  if position('tests.gsm_master_catalogue()' in v_def) > 0
     or position('tests.u4_customer_family_sector_catalogue()' in v_def) > 0 then
    raise exception 'one or both catalogue suites are already registered';
  end if;

  v_cnt := (length(v_def) - length(replace(v_def, v_plant_anchor, '')))
           / length(v_plant_anchor);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 plant_master anchor, found %', v_cnt;
  end if;

  v_cnt := (length(v_def) - length(replace(v_def, v_customer_anchor, '')))
           / length(v_customer_anchor);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 customer_family_mutations anchor, found %', v_cnt;
  end if;

  v_def := replace(
    v_def,
    v_plant_anchor,
    v_plant_anchor || E'\n' ||
      '  return query select * from tests.gsm_master_catalogue();'
  );
  v_def := replace(
    v_def,
    v_customer_anchor,
    v_customer_anchor || E'\n' ||
      '  return query select * from tests.u4_customer_family_sector_catalogue();'
  );

  execute v_def;

  v_def := pg_catalog.pg_get_functiondef('tests.run_all()'::regprocedure);
  if position('tests.gsm_master_catalogue()' in v_def) = 0
     or position('tests.u4_customer_family_sector_catalogue()' in v_def) = 0 then
    raise exception 'catalogue suite registration verification failed';
  end if;
end $mig$;

revoke all on function tests.run_all() from public, anon, authenticated;
