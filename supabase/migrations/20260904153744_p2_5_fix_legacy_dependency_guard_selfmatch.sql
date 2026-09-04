-- P2-5 defect correction: the guard matched its own source text.
--
-- tests.no_legacy_identity_dependency contains the literals 'public.profiles' and
-- 'is_admin' in order to search for them, so scanning pg_proc.prosrc found itself.
-- app_private.is_admin legitimately reads public.profiles - it IS one of the S3(c)
-- removal targets, and excluding it is the point: the guard asks whether anything
-- ELSE still depends on the legacy objects.
--
-- Both exclusions are named explicitly rather than filtered by pattern, so adding a
-- third exclusion later is a visible diff.

create or replace function tests.no_legacy_identity_dependency()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_self  text := 'no_legacy_identity_dependency';   -- the guard itself
  v_target text := 'is_admin';                        -- an S3(c) removal target
begin
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('tests','app_private','ref_private','public')
        and p.proname not in (v_self, v_target)
        and p.prosrc ilike '%public.profiles%'),
    0, 'D-1 nothing except the removal targets reads public.profiles');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('tests','app_private','ref_private','public')
        and p.proname not in (v_self, v_target)
        and p.prosrc ilike '%is_admin%'),
    0, 'D-2 nothing calls app_private.is_admin');

  return next is(
    (select count(*)::int from pg_catalog.pg_policy pol
       join pg_catalog.pg_class c on c.oid = pol.polrelid
      where c.relname <> 'profiles'
        and coalesce(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid),'') ilike '%is_admin%'),
    0, 'D-3 no policy outside profiles depends on is_admin');

  -- nothing outside profiles itself references the table by foreign key
  return next is(
    (select count(*)::int from pg_catalog.pg_constraint con
       join pg_catalog.pg_class c  on c.oid  = con.conrelid
       join pg_catalog.pg_class rf on rf.oid = con.confrelid
      where con.contype = 'f' and rf.relname = 'profiles' and c.relname <> 'profiles'),
    0, 'D-4 no table has a foreign key to public.profiles');

  -- and no trigger outside profiles fires on it
  return next is(
    (select count(*)::int from pg_catalog.pg_trigger t
       join pg_catalog.pg_class c on c.oid = t.tgrelid
      where not t.tgisinternal and c.relname = 'profiles'
        and t.tgname not in ('profiles_set_updated_at')),
    0, 'D-5 profiles carries only its own known updated_at trigger');
end $fn$;
revoke execute on function tests.no_legacy_identity_dependency() from public;