-- P2-1 defect correction: pgtap's assertion functions call their own internals
-- unqualified (e.g. _todo()), so a test function pinned to search_path='' cannot
-- use them. The test functions are pinned to 'extensions, pg_catalog' instead.
-- These are NOT security definer and live in a schema with no client grant, so the
-- looser path carries no privilege risk; every application object stays qualified.

create or replace function tests.access_model()
returns setof text language plpgsql set search_path = 'extensions, pg_catalog' as $fn$
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

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where p.prosecdef and n.nspname in ('app_private','ref_private')
        and coalesce(array_to_string(p.proconfig,','),'') <> 'search_path='),
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

create or replace function tests.deny_by_default()
returns setof text language plpgsql set search_path = 'extensions, pg_catalog' as $fn$
declare n_users int; n_grants int; cap boolean;
begin
  perform pg_catalog.set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000999","role":"authenticated"}', true);
  set local role authenticated;

  select count(*) into n_users  from public.app_users;
  select count(*) into n_grants from public.plant_capability_grants;
  select app_private.has_group_cap('administer_users') into cap;

  reset role;
  return next is(n_users,  0, 'N-9a zero-grant caller sees no app_users');
  return next is(n_grants, 0, 'N-9b zero-grant caller sees no plant grants');
  return next ok(not cap,     'N-3 helper returns false with no recursion error');
end $fn$;

create or replace function tests.run_all()
returns setof text language sql set search_path = 'extensions, pg_catalog' as $fn$
  select * from tests.access_model()
  union all
  select * from tests.deny_by_default();
$fn$;