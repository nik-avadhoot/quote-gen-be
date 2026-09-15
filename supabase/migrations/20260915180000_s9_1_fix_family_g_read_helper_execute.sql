-- S9(a) correction: the Family G read helpers must be executable by the caller.
--
-- PREPARED, NOT APPLIED. Authored 2026-09-15 after the S9 localhost
-- qualification run. Apply only under explicit Product Owner authority, after a
-- branch rehearsal (see quote-gen-fe/docs/s9-qualification-seed-and-quote-read-fix-plan.md).
--
-- THE DEFECT. Every Family G SELECT policy (s9_1_family_g_quote_schema.sql
-- lines 374-406) calls app_private.can_read_quote_family / _revision / _item.
-- The same migration then revoked EXECUTE on those three helpers from
-- authenticated (lines 409-411). A policy expression runs with the privileges of
-- the querying role, and SECURITY DEFINER changes only the privileges INSIDE the
-- function body, never the right to call it. Every caller-token read of
-- quote_revisions, quote_items, calculation_snapshots, quote_item_delivery_groups,
-- quote_workflow_events, customer_outcome_events, export_events or export_parts
-- that reaches a row therefore raises 42501.
--
-- OBSERVED. Localhost qualification, authenticated persona holding make_quote and
-- check_quote at every plant: GET /quotes/catalogue?view=history and ?view=inbox
-- both returned 403 {"error_code":"CAPABILITY_REQUIRED"} (server.py maps 42501
-- to that code at lines 3244-3246). quote_families alone was readable because its
-- policy calls app_private.can_read_batch, which s6_1_family_f_batch_core.sql
-- line 209 grants to authenticated.
--
-- WHY THE GATES PASSED. QG-38 (tests.quote_schema(), as replaced by
-- 20260909111611) asserted the revocation itself. Every S9(b)/S9(c) gate reads
-- Family G tables only after `reset role`, i.e. as the owner, so no gate ever
-- performed an authenticated read of a Family G row.
--
-- THE CORRECTION follows the can_read_batch precedent exactly: EXECUTE to
-- authenticated, nothing to anon or public. The helpers stay in app_private,
-- which is not an exposed PostgREST schema, so this adds no callable API
-- surface; it only lets RLS evaluate the policies it already has. Each helper
-- answers "may the CURRENT caller read this row" through can_read_batch, so it
-- discloses nothing a successful SELECT would not.

grant execute on function app_private.can_read_quote_family(bigint)   to authenticated;
grant execute on function app_private.can_read_quote_revision(bigint) to authenticated;
grant execute on function app_private.can_read_quote_item(bigint)     to authenticated;

-- QG-38 is INVERTED, NOT DELETED (the s7r_11 CP-80 precedent). A deleted gate
-- stops proving anything; the inverted gate now fails if the grant is ever lost
-- again, and still fails if anon ever gains EXECUTE.
--
-- Spliced against the live definition with single-line fragments, so the splice
-- does not depend on the stored body's line endings. Each fragment must occur
-- exactly once or the migration aborts without changing anything.
do $mig$
declare
  v_def  text;
  v_cnt  int;
  v_old1 text := 'not pg_catalog.has_function_privilege(''authenticated'',';
  v_new1 text := 'pg_catalog.has_function_privilege(''authenticated'',';
  v_old2 text := '''QG-38 app_private.%s is not callable by anon or authenticated''';
  v_new2 text := '''QG-38 app_private.%s is callable by authenticated, because every Family G SELECT policy evaluates it as the caller, and still not by anon''';
begin
  v_def := pg_catalog.pg_get_functiondef('tests.quote_schema()'::regprocedure);

  v_cnt := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 QG-38 authenticated privilege probe, found %', v_cnt;
  end if;
  v_cnt := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 QG-38 assertion message, found %', v_cnt;
  end if;

  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end $mig$;

revoke all on function tests.quote_schema() from public, anon, authenticated;

-- One-time structural proof of the defect CLASS, not only these three helpers:
-- every app_private function named in an authenticated SELECT policy on a
-- Family G table must be executable by authenticated. Aborts (and rolls the
-- whole migration back) if any is not.
do $verify$
declare
  r         record;
  v_missing text[] := '{}';
begin
  for r in
    select distinct p.tablename, m[1] as fn
      from pg_catalog.pg_policies p
     cross join lateral regexp_matches(coalesce(p.qual, ''), 'app_private\.([a-z_]+)\(', 'g') as m
     where p.schemaname = 'public'
       and p.cmd = 'SELECT'
       and 'authenticated'::name = any (p.roles)
       and p.tablename = any (array['quote_families','quote_revisions','calculation_snapshots',
                                    'quote_items','quote_item_delivery_groups',
                                    'quote_workflow_events','customer_outcome_events',
                                    'export_events','export_parts'])
  loop
    if not exists (
      select 1
        from pg_catalog.pg_proc pr
        join pg_catalog.pg_namespace n on n.oid = pr.pronamespace
       where n.nspname = 'app_private'
         and pr.proname = r.fn
         and pg_catalog.has_function_privilege('authenticated', pr.oid, 'EXECUTE')
    ) then
      v_missing := v_missing || (r.tablename || ':' || r.fn);
    end if;
  end loop;

  if cardinality(v_missing) > 0 then
    raise exception 'Family G SELECT policies call helpers authenticated cannot execute: %', v_missing;
  end if;
  if pg_catalog.has_function_privilege('anon', 'app_private.can_read_quote_family(bigint)', 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', 'app_private.can_read_quote_revision(bigint)', 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', 'app_private.can_read_quote_item(bigint)', 'EXECUTE') then
    raise exception 'anon must not be able to execute the Family G read helpers';
  end if;
end $verify$;
