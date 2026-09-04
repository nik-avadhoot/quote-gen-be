-- P2-1 defect correction 4: no_plan() returns setof boolean, not setof text, so it
-- cannot be RETURN QUERY'd into a text-returning function. Execute it with PERFORM
-- and return only the assertion lines plus finish()'s summary.

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.deny_by_default();
  return query select * from finish();
end $fn$;