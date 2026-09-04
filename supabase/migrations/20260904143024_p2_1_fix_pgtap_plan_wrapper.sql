-- P2-1 defect correction 3: pgtap requires a plan to be declared before any
-- assertion and finished after the last one. run_all() now wraps the suite in
-- no_plan()/finish(), which is pgtap's canonical harness shape.

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  return query select * from no_plan();
  return query select * from tests.access_model();
  return query select * from tests.deny_by_default();
  return query select * from finish();
end $fn$;