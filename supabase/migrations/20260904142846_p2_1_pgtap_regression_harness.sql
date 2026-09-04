-- P2-1: pgtap + a repeatable regression harness.
-- S1's proofs were run as one-shot queries. This turns them into a callable
-- suite so a later slice cannot silently regress the access model.

create extension if not exists pgtap with schema extensions;

create schema if not exists tests;
revoke all on schema tests from public;
revoke all on schema tests from anon, authenticated;

-- N-4/N-5/N-6/N-7/N-8: structural invariants of the access model.
create or replace function tests.access_model()
returns setof text language plpgsql set search_path = '' as $fn$
declare
  v_tables text[] := array['avadhoot_groups','plants','app_users','capabilities',
                           'group_capability_grants','plant_capability_grants',
                           'operational_settings'];
  t text;
begin
  -- N-5: the entire recursion model rests on postgres holding BYPASSRLS.
  return next extensions.ok(
    (select rolbypassrls from pg_catalog.pg_roles where rolname = 'postgres'),
    'N-5 postgres holds BYPASSRLS (recursion terminates inside definer helpers)');

  -- no client role may bypass RLS
  return next extensions.ok(
    not exists (select 1 from pg_catalog.pg_roles
                 where rolname in ('anon','authenticated') and (rolbypassrls or rolsuper)),
    'N-5b anon/authenticated hold neither BYPASSRLS nor SUPERUSER');

  -- N-6: RLS enabled AND forced on every Family A table
  foreach t in array v_tables loop
    return next extensions.ok(
      (select c.relrowsecurity and c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = t),
      format('N-6 %s has RLS enabled AND forced', t));
  end loop;

  -- N-7: anon holds no privilege anywhere
  foreach t in array v_tables loop
    return next extensions.ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('anon','public.'||t,'DELETE')),
      format('N-7 anon holds no privilege on %s', t));
  end loop;

  -- N-10: app_users self-update is column-limited
  return next extensions.ok(
    pg_catalog.has_column_privilege('authenticated','public.app_users','display_name','UPDATE'),
    'N-10a authenticated may update app_users.display_name');
  return next extensions.ok(
    not pg_catalog.has_column_privilege('authenticated','public.app_users','status','UPDATE'),
    'N-10b authenticated may NOT update app_users.status');
  return next extensions.ok(
    not pg_catalog.has_column_privilege('authenticated','public.app_users','auth_user_id','UPDATE'),
    'N-10c authenticated may NOT update app_users.auth_user_id');

  -- N-8: every SECURITY DEFINER function outside the platform is search_path-pinned
  return next extensions.is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where p.prosecdef and n.nspname in ('app_private','ref_private')
        and coalesce(array_to_string(p.proconfig,','),'') <> 'search_path='),
    0, 'N-8 every app_private/ref_private SECURITY DEFINER pins search_path to empty');

  -- no helper is executable by PUBLIC or anon
  return next extensions.is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('app_private','ref_private')
        and (pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE'))),
    0, 'N-2 anon cannot execute any app_private/ref_private function');

  -- 0006 guard: at most one permissive policy per table/action on Family A
  return next extensions.is(
    (select coalesce(max(cnt),0)::int from (
       select count(*) cnt from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = any(v_tables)
        group by c.relname, pol.polcmd) q),
    1, 'PC-1 exactly one permissive policy per Family A table and action');

  -- ref_private is unreachable by clients
  return next extensions.ok(
    not pg_catalog.has_schema_privilege('authenticated','ref_private','USAGE'),
    'ref_private is not reachable by authenticated');
end $fn$;

-- N-3/N-9: behaviour as a real authenticated caller with no grants.
create or replace function tests.deny_by_default()
returns setof text language plpgsql set search_path = '' as $fn$
declare n_users int; n_grants int; cap boolean;
begin
  perform pg_catalog.set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000999","role":"authenticated"}', true);
  set local role authenticated;

  select count(*) into n_users  from public.app_users;
  select count(*) into n_grants from public.plant_capability_grants;
  -- N-3: this call is the recursion proof. If policies recursed it would raise 42P17.
  select app_private.has_group_cap('administer_users') into cap;

  reset role;
  return next extensions.is(n_users,  0, 'N-9a zero-grant caller sees no app_users');
  return next extensions.is(n_grants, 0, 'N-9b zero-grant caller sees no plant grants');
  return next extensions.ok(not cap,     'N-3 helper returns false with no recursion error');
end $fn$;

create or replace function tests.run_all()
returns setof text language sql set search_path = '' as $fn$
  select * from tests.access_model()
  union all
  select * from tests.deny_by_default();
$fn$;