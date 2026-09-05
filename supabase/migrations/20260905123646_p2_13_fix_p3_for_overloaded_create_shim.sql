-- P2-13: P-3 assumed exactly one public.admin_create_app_user and broke the
-- moment the atomic array-based overload was added - the scalar subquery
-- returned two rows. Rewritten as a COUNT of definer overloads, which is both
-- correct with any number of signatures and a stronger claim than the original:
-- it now says "no overload of either shim is a definer" rather than "the one I
-- happened to find is not".

create or replace function tests.definer_placement()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
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

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public' and p.proname='admin_create_app_user' and p.prosecdef),
    0, 'P-3 NO overload of the public create shim is SECURITY DEFINER');
  return next ok(
    (select count(*) from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public' and p.proname='admin_create_app_user') >= 1,
    'P-3a and the public create shim exists');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='public' and p.proname='admin_set_app_user_status' and p.prosecdef),
    0, 'P-4 NO overload of the public status shim is SECURITY DEFINER');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public','app_private','ref_private','tests')
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
        and p.proname <> 'rls_auto_enable'),
    0, 'P-5 anon can execute none of our functions in any schema');

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

  return next is(
    (select count(*)::int
       from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      cross join unnest(array['anon','authenticated']) as r(role)
      where n.nspname = 'public' and c.relkind = 'r'
        and pg_catalog.has_table_privilege(r.role, c.oid, 'TRUNCATE')),
    0, 'P-7 no API-reachable role can TRUNCATE past RLS in public');
end $fn$;

revoke all on function tests.definer_placement() from public, anon, authenticated;