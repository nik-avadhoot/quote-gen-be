-- P2-1 defect correction 5: the N-8 assertion compared proconfig to 'search_path='.
-- Postgres stores an empty search_path as search_path="" (with quotes), so the test
-- failed against a schema that was in fact correct. This is a defect in the TEST, not
-- in the access model: all five helpers were independently confirmed as search_path="".

create or replace function tests.access_model()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['avadhoot_groups','plants','app_users','capabilities',
                           'group_capability_grants','plant_capability_grants',
                           'operational_settings'];
  t text;
begin
  return next ok(
    (select rolbypassrls from pg_catalog.pg_roles where rolname = 'postgres'),
    'N-5 postgres holds BYPASSRLS (recursion terminates inside definer helpers)');

  return next ok(
    not exists (select 1 from pg_catalog.pg_roles
                 where rolname in ('anon','authenticated') and (rolbypassrls or rolsuper)),
    'N-5b anon/authenticated hold neither BYPASSRLS nor SUPERUSER');

  foreach t in array v_tables loop
    return next ok(
      (select c.relrowsecurity and c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = t),
      format('N-6 %s has RLS enabled AND forced', t));
  end loop;

  foreach t in array v_tables loop
    return next ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('anon','public.'||t,'DELETE')),
      format('N-7 anon holds no privilege on %s', t));
  end loop;

  return next ok(
    pg_catalog.has_column_privilege('authenticated','public.app_users','display_name','UPDATE'),
    'N-10a authenticated may update app_users.display_name');
  return next ok(
    not pg_catalog.has_column_privilege('authenticated','public.app_users','status','UPDATE'),
    'N-10b authenticated may NOT update app_users.status');
  return next ok(
    not pg_catalog.has_column_privilege('authenticated','public.app_users','auth_user_id','UPDATE'),
    'N-10c authenticated may NOT update app_users.auth_user_id');

  -- Postgres renders an empty search_path as search_path=""
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where p.prosecdef and n.nspname in ('app_private','ref_private')
        and coalesce(array_to_string(p.proconfig,','),'') <> 'search_path=""'),
    0, 'N-8 every app_private/ref_private SECURITY DEFINER pins search_path to empty');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('app_private','ref_private')
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')),
    0, 'N-2 anon cannot execute any app_private/ref_private function');

  return next is(
    (select coalesce(max(cnt),0)::int from (
       select count(*) cnt from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = any(v_tables)
        group by c.relname, pol.polcmd) q),
    1, 'PC-1 exactly one permissive policy per Family A table and action');

  return next ok(
    not pg_catalog.has_schema_privilege('authenticated','ref_private','USAGE'),
    'ref_private is not reachable by authenticated');
end $fn$;