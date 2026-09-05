-- P2-7: generalise the deny-by-default guard so the profiles gap cannot recur.
--
-- N-7 enumerated the seven Family A tables by name, so it could only ever prove
-- what it already listed. Family B was added later and covered by its own F-2
-- loop; `profiles` was covered by neither, which is why an anonymous REST call
-- reached it for the whole of Phase 2 without a single test failing.
--
-- P-6 replaces enumeration with a catalogue sweep: EVERY table in `public`, now
-- and in future, must be unreachable by anon. P-7 covers the one privilege RLS
-- cannot filter - a role holding TRUNCATE empties a table whatever its policies
-- say - for both API-reachable roles.

create or replace function tests.definer_placement()
returns setof text language plpgsql as $fn$
begin
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public','graphql_public') and p.prosecdef
        and p.proname <> 'rls_auto_enable'),
    0, 'P-1 no SECURITY DEFINER function of ours lives in an exposed schema');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('app_private','ref_private') and p.prosecdef
        and coalesce(array_to_string(p.proconfig,','),'') <> 'search_path=""'),
    0, 'P-2 every private definer pins search_path to empty');

  return next ok(
    (select not p.prosecdef from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public' and p.proname='admin_create_app_user'),
    'P-3 the public create shim is SECURITY INVOKER, not definer');
  return next ok(
    (select not p.prosecdef from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public' and p.proname='admin_set_app_user_status'),
    'P-4 the public status shim is SECURITY INVOKER, not definer');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public','app_private','ref_private','tests')
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
        and p.proname <> 'rls_auto_enable'),
    0, 'P-5 anon can execute none of our functions in any schema');

  -- P-6: catalogue sweep, not an enumeration. Any future table in `public` that
  -- carries the Supabase default grant fails this the moment it is created.
  return next is(
    (select count(*)::int
       from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
        and (pg_catalog.has_table_privilege('anon', c.oid, 'SELECT')
          or pg_catalog.has_table_privilege('anon', c.oid, 'INSERT')
          or pg_catalog.has_table_privilege('anon', c.oid, 'UPDATE')
          or pg_catalog.has_table_privilege('anon', c.oid, 'DELETE')
          or pg_catalog.has_table_privilege('anon', c.oid, 'TRUNCATE'))),
    0, 'P-6 anon holds no privilege on ANY table in public, not just Family A/B');

  -- P-7: TRUNCATE is not row-filtered, so RLS cannot contain it.
  return next is(
    (select count(*)::int
       from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      cross join unnest(array['anon','authenticated']) as r(role)
      where n.nspname = 'public' and c.relkind = 'r'
        and pg_catalog.has_table_privilege(r.role, c.oid, 'TRUNCATE')),
    0, 'P-7 no API-reachable role can TRUNCATE past RLS in public');
end $fn$;

revoke all on function tests.definer_placement() from public;
revoke all on function tests.definer_placement() from anon;
revoke all on function tests.definer_placement() from authenticated;