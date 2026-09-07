-- U1-CF-C1: service_role held a DIRECT EXECUTE grant on all ten public
-- wrappers, sourced from a platform default privilege (ALTER DEFAULT
-- PRIVILEGES FOR ROLE postgres IN SCHEMA public), not from the grant/revoke DO
-- block in family_b_mutations_functions, which only revoked PUBLIC/anon and
-- granted authenticated - it never explicitly touched service_role. Catalog
-- evidence (pg_proc.proacl showed a direct "service_role=X/postgres" entry on
-- all ten, and pg_default_acl showed the same default applied to every new
-- public-schema function owned by postgres) confirms this was a real gap
-- against the binding instruction ("revoke PUBLIC, anon and service_role
-- unless deliberately required"), not merely a documentation error.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('propose_customer_family', 'create_minimal_prospect',
        'update_customer_family', 'approve_customer_family', 'add_family_alias',
        'update_family_alias', 'retire_family_alias', 'merge_customer_families',
        'reassign_customer_family', 'graduate_customer_party')
  loop
    execute format('revoke execute on function %s from service_role', r.sig);
  end loop;
end $$;

-- Close the gap for FUTURE functions too: this default privilege auto-grants
-- EXECUTE to service_role on every new public-schema function owned by
-- postgres, which is exactly how this slice's ten wrappers ended up holding it
-- without anyone granting it explicitly. Scoped narrowly to service_role only
-- (not anon/authenticated) - changing a default privilege affects only objects
-- created AFTER this statement, never retroactively, so no existing function
-- anywhere in the schema is touched by this change.
alter default privileges for role postgres in schema public
  revoke execute on functions from service_role;
