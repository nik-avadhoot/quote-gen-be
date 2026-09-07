-- Fix, found by tests.function_grants()/tests.access_model()/tests.suite_registration()
-- style assertions in the full run_all(): every newly CREATEd function in this
-- slice kept Postgres's default "EXECUTE TO PUBLIC" grant, because the
-- functions migration's grant/revoke DO block only targeted the public-schema
-- WRAPPERS, never the app_private functions themselves or the new tests
-- suite. anon could therefore reach nine app_private functions directly
-- (unreachable via PostgREST regardless, since app_private is not in the
-- exposed-schema list, but a real gap against this codebase's own standing
-- discipline of explicit revoke on every function it creates).
--
-- Also: CREATE OR REPLACE on merge_families/reassign_party_family with a
-- DIFFERENT argument list does not replace the old function - Postgres
-- functions are identified by name+argument-types, so the old, CAS-less
-- 2-arg merge_families(bigint,bigint) and 3-arg
-- reassign_party_family(bigint,bigint,date) were left standing ALONGSIDE the
-- new CAS-protected ones. Left live, they would be exactly the "argument
-- that permits a caller to bypass concurrency protection" the PO review
-- explicitly ruled out - dropped here, not just superseded.

drop function if exists app_private.merge_families(bigint, bigint);
drop function if exists app_private.reassign_party_family(bigint, bigint, date);

do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app_private'
       and p.proname in ('propose_customer_family', 'create_minimal_prospect',
         'update_customer_family', 'approve_customer_family', 'add_family_alias',
         'update_family_alias', 'retire_family_alias', 'merge_families',
         'reassign_party_family')
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;

  -- tests.* functions carry no execute grant to any of anon/authenticated/
  -- public, matching every existing suite (party_masters, run_all,
  -- fixtures_matrix all verified the same way beforehand).
  revoke all on function tests.customer_family_mutations() from public;
end $$;
