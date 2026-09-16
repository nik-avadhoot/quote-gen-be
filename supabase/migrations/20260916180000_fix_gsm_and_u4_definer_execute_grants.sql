-- GSM Master and U4 Customer Family Sector correction: the private definer
-- functions behind the public invoker wrappers must be executable by the caller.
--
-- PREPARED, NOT APPLIED. Authored 2026-09-16. Apply only with the owner's
-- explicit approval.
--
-- THE DEFECT. Each public.* wrapper below is SECURITY INVOKER, so its body
-- runs as the calling role, and the first thing it does is call its
-- app_private.* SECURITY DEFINER counterpart. SECURITY DEFINER changes only the
-- privileges INSIDE the called function, never the right to call it. The
-- authoring migrations revoked that right from authenticated:
--   20260915084131_gsm_master.sql lines 126-127
--   20260915100440_u4_customer_family_sectors.sql lines 393-395
-- so every signed-in call raises 42501 "permission denied for function ...",
-- which server.py maps to CAPABILITY_REQUIRED (403) before any capability
-- check inside the function body has run.
--
-- OBSERVED 2026-09-16 (read-only, nothing written): as authenticated,
-- public.add_paper_gsm_value(0) and public.propose_customer_family('', null)
-- both failed with "permission denied for function". A catalogue query over
-- every public invoker function that calls app_private found exactly these five
-- wrappers with an unexecutable callee; every other governed operation
-- (propose_sku, approve_customer_family, update_customer_family,
-- add_family_alias, ...) already grants EXECUTE to authenticated.
--
-- WHY THE GATES PASSED. GSM-6 (tests.gsm_master_catalogue()) asserted the
-- revocation itself, and the U4 gates check only the public wrappers.
--
-- THE CORRECTION follows the established convention
-- (20260907071937_family_b_mutations_fix_grants_and_drop_obsolete.sql): EXECUTE
-- to authenticated, nothing to anon or public. app_private is not an exposed
-- PostgREST schema, so this adds no callable API surface. Authority is still
-- decided inside each function body (manage_construction_library,
-- manage_customer_master, make_quote), which is where it was designed to be.
--
-- DELIBERATELY NOT GRANTED: the private-only compatibility overloads
-- app_private.propose_customer_family(text) and
-- app_private.create_minimal_prospect(text, bigint). No public wrapper calls
-- them; they pick the first active Sector for historical test fixtures, and
-- 20260915100440 lines 295-299 record that no authenticated EXECUTE grant may
-- expose that path. They stay revoked, and the proof below enforces it.

revoke all on function app_private.add_paper_gsm_value(integer)                          from public, anon;
revoke all on function app_private.set_paper_gsm_value_status(bigint, text, integer)     from public, anon;
revoke all on function app_private.propose_customer_family(text, bigint)                 from public, anon;
revoke all on function app_private.create_minimal_prospect(text, bigint, bigint)         from public, anon;
revoke all on function app_private.add_customer_family_sector(bigint, bigint, integer)   from public, anon;

grant execute on function app_private.add_paper_gsm_value(integer)                       to authenticated;
grant execute on function app_private.set_paper_gsm_value_status(bigint, text, integer)  to authenticated;
grant execute on function app_private.propose_customer_family(text, bigint)              to authenticated;
grant execute on function app_private.create_minimal_prospect(text, bigint, bigint)      to authenticated;
grant execute on function app_private.add_customer_family_sector(bigint, bigint, integer) to authenticated;

-- GSM-6 is REPOINTED, NOT DELETED (the s7r_11 CP-80 and 20260915180000 QG-38
-- precedent). It now fails if authenticated ever loses EXECUTE again, and also
-- fails if anon ever gains it.
--
-- Spliced against the live definition with single-line fragments, so the splice
-- does not depend on the stored body's line endings. Each fragment must occur
-- exactly once or the migration aborts without changing anything.
do $mig$
declare
  v_def  text;
  v_cnt  int;
  v_old  text[] := array[
    'ok := not pg_catalog.has_function_privilege(''authenticated'',',
    'and not pg_catalog.has_function_privilege(''authenticated'',',
    '''app_private.set_paper_gsm_value_status(bigint,text,integer)'', ''EXECUTE'');',
    '''GSM-6 private definer functions are reachable only through the invoker wrappers'''];
  v_new  text[] := array[
    'ok := pg_catalog.has_function_privilege(''authenticated'',',
    'and pg_catalog.has_function_privilege(''authenticated'',',
    '''app_private.set_paper_gsm_value_status(bigint,text,integer)'', ''EXECUTE'') and not pg_catalog.has_function_privilege(''anon'', ''app_private.add_paper_gsm_value(integer)'', ''EXECUTE'') and not pg_catalog.has_function_privilege(''anon'', ''app_private.set_paper_gsm_value_status(bigint,text,integer)'', ''EXECUTE'');',
    '''GSM-6 private definer functions are executable by authenticated, because the invoker wrappers call them as the caller, and still not by anon'''];
  i      int;
begin
  v_def := pg_catalog.pg_get_functiondef('tests.gsm_master_catalogue()'::regprocedure);

  for i in 1 .. array_length(v_old, 1) loop
    v_cnt := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    if v_cnt <> 1 then
      raise exception 'expected exactly 1 GSM-6 splice fragment %, found %', i, v_cnt;
    end if;
  end loop;

  for i in 1 .. array_length(v_old, 1) loop
    v_def := replace(v_def, v_old[i], v_new[i]);
  end loop;
  execute v_def;
end $mig$;

revoke all on function tests.gsm_master_catalogue() from public, anon, authenticated;
grant execute on function tests.gsm_master_catalogue() to service_role;

-- One-time structural proof of the defect CLASS, not only these five functions:
-- every app_private function called by a public SECURITY INVOKER function that
-- authenticated can execute must have an overload of that name executable by
-- authenticated (the exact-signature grants are pinned above and by the static
-- contract test). anon must not execute any of the corrected functions,
-- and the two compatibility overloads must stay closed. Aborts (and rolls the
-- whole migration back) on any violation.
do $verify$
declare
  r         record;
  v_missing text[] := '{}';
begin
  for r in
    select w.oid::regprocedure::text as wrapper, m[1] as callee
      from pg_catalog.pg_proc w
      join pg_catalog.pg_namespace wn on wn.oid = w.pronamespace and wn.nspname = 'public'
     cross join lateral regexp_matches(w.prosrc, 'app_private\.([a-z_0-9]+)\s*\(', 'g') as m
     where not w.prosecdef
       and pg_catalog.has_function_privilege('authenticated', w.oid, 'EXECUTE')
  loop
    if not exists (
      select 1
        from pg_catalog.pg_proc pr
        join pg_catalog.pg_namespace n on n.oid = pr.pronamespace
       where n.nspname = 'app_private'
         and pr.proname = r.callee
         and pg_catalog.has_function_privilege('authenticated', pr.oid, 'EXECUTE')
    ) then
      v_missing := v_missing || (r.wrapper || ' -> app_private.' || r.callee);
    end if;
  end loop;

  if cardinality(v_missing) > 0 then
    raise exception 'public invoker wrappers call private functions authenticated cannot execute: %', v_missing;
  end if;

  if pg_catalog.has_function_privilege('anon', 'app_private.add_paper_gsm_value(integer)', 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', 'app_private.set_paper_gsm_value_status(bigint,text,integer)', 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', 'app_private.propose_customer_family(text,bigint)', 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', 'app_private.create_minimal_prospect(text,bigint,bigint)', 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', 'app_private.add_customer_family_sector(bigint,bigint,integer)', 'EXECUTE') then
    raise exception 'anon must not be able to execute the corrected private definer functions';
  end if;

  if pg_catalog.has_function_privilege('authenticated', 'app_private.propose_customer_family(text)', 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', 'app_private.create_minimal_prospect(text,bigint)', 'EXECUTE') then
    raise exception 'the private-only compatibility overloads must stay unexecutable by authenticated';
  end if;
end $verify$;
