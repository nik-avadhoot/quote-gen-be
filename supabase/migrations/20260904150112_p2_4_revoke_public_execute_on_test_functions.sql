-- P2-4 defect correction: Postgres grants EXECUTE on every new function to PUBLIC.
-- Revoking USAGE on schema `tests` made those functions unreachable, but the
-- function-level grant remained, so protection rested on a single layer.
--
-- tests.__cleanup_fixtures() is SECURITY DEFINER, owned by postgres (which holds
-- BYPASSRLS), and DELETES rows. A destructive definer primitive should not be one
-- schema-grant away from callable. This applies the same revoke-then-grant standard
-- used for every app_private/ref_private function.

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'tests'
  loop
    execute format('revoke execute on function %s from public', f.sig);
    execute format('revoke execute on function %s from anon, authenticated', f.sig);
  end loop;
end $$;

-- Guard the whole class, not just today's functions.
create or replace function tests.function_grants()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('tests','app_private','ref_private')
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')),
    0, 'G-1 anon can execute NO function in tests/app_private/ref_private');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'tests'
        and pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')),
    0, 'G-2 authenticated can execute NO test function');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where p.prosecdef and n.nspname in ('tests','app_private','ref_private')
        and coalesce(array_to_string(p.proconfig,','),'') <> 'search_path=""'),
    0, 'G-3 every SECURITY DEFINER function in those schemas pins search_path to empty');
  return next ok(
    not pg_catalog.has_schema_privilege('authenticated','tests','USAGE'),
    'G-4 authenticated has no USAGE on schema tests');
end $fn$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
             join pg_namespace n on n.oid = p.pronamespace where n.nspname='tests'
  loop
    execute format('revoke execute on function %s from public', f.sig);
  end loop;
end $$;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.function_grants();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from finish();
end $fn$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
             join pg_namespace n on n.oid = p.pronamespace where n.nspname='tests'
  loop
    execute format('revoke execute on function %s from public', f.sig);
  end loop;
end $$;