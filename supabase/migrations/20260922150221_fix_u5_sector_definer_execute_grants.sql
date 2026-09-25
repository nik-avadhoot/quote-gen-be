-- U5 correction: the private definer functions behind the public invoker
-- wrappers must be executable by the caller.
--
-- APPLIED to the live project 2026-09-22 as migration 20260922150221.
--
-- THE SAME DEFECT AS 20260916165004 (GSM Master and U4). Each public.* wrapper
-- is SECURITY INVOKER, so its body runs as the calling role, and the first
-- thing it does is call its app_private.* SECURITY DEFINER counterpart.
-- SECURITY DEFINER changes only the privileges INSIDE the called function,
-- never the right to CALL it. 20260922144812 revoked that right from
-- authenticated, so every signed-in call raised
--   42501 permission denied for function propose_sector
-- which server.py maps to CAPABILITY_REQUIRED (403) before any capability
-- check inside the function body has run.
--
-- OBSERVED 2026-09-22 in a self-rolling-back transaction as the authenticated
-- owner: public.propose_sector(...) failed with "permission denied for
-- function propose_sector" at the first statement of the wrapper body. After
-- this migration the same transaction ran the whole lifecycle green:
--   propose -> v1 approved, approved_by written by the trigger
--   revise  -> v2 approved, v1 superseded
--   stale CAS refused PT409; duplicate code refused 23505
--   rename + deactivate -> status inactive
--
-- WHY THE GATE DID NOT CATCH IT. U5-SEC-3 asserted the revocation itself --
-- the identical mistake GSM-6 made and that 20260916165004 had to repoint. It
-- is repointed below, and a STRUCTURAL gate (U5-SEC-8) is added so the next
-- slice that adds a wrapper cannot reintroduce the class: 20260916165004
-- proved the class only in a one-time migration-time DO block, which is why
-- this recurred six days later. U5-SEC-8 is a standing gate over EVERY public
-- invoker wrapper, not only this slice's four.
--
-- app_private is not an exposed PostgREST schema, so this adds no callable API
-- surface. Authority is still decided inside each function body
-- (propose_commercial_master / approve_commercial_master).

revoke all on function app_private.propose_sector(text, text, numeric, numeric, numeric, numeric, numeric, text) from public, anon;
revoke all on function app_private.revise_sector_commercials(bigint, integer, numeric, numeric, numeric, numeric, numeric, text) from public, anon;
revoke all on function app_private.rename_sector(bigint, text) from public, anon;
revoke all on function app_private.set_sector_status(bigint, text) from public, anon;

grant execute on function app_private.propose_sector(text, text, numeric, numeric, numeric, numeric, numeric, text) to authenticated;
grant execute on function app_private.revise_sector_commercials(bigint, integer, numeric, numeric, numeric, numeric, numeric, text) to authenticated;
grant execute on function app_private.rename_sector(bigint, text) to authenticated;
grant execute on function app_private.set_sector_status(bigint, text) to authenticated;

create or replace function tests.u5_governed_sector_master_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
declare v_missing text[] := '{}'; r record;
begin
  ok := pg_catalog.has_function_privilege('authenticated',
      'public.propose_sector(text,text,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',
      'public.propose_sector(text,text,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE');
  name := 'U5-SEC-1 only authenticated callers enter the governed propose operation';
  return next;

  ok := pg_catalog.has_function_privilege('authenticated',
      'public.revise_sector_commercials(bigint,integer,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',
      'public.revise_sector_commercials(bigint,integer,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE');
  name := 'U5-SEC-2 only authenticated callers enter the governed revise operation';
  return next;

  -- REPOINTED, not deleted (the GSM-6 / s7r_11 CP-80 precedent). The private
  -- definer functions MUST be executable by authenticated, because the public
  -- invoker wrappers call them as the caller. anon must still never reach them.
  ok := pg_catalog.has_function_privilege('authenticated',
      'app_private.propose_sector(text,text,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE')
    and pg_catalog.has_function_privilege('authenticated',
      'app_private.revise_sector_commercials(bigint,integer,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE')
    and pg_catalog.has_function_privilege('authenticated',
      'app_private.rename_sector(bigint,text)', 'EXECUTE')
    and pg_catalog.has_function_privilege('authenticated',
      'app_private.set_sector_status(bigint,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',
      'app_private.propose_sector(text,text,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',
      'app_private.revise_sector_commercials(bigint,integer,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE');
  name := 'U5-SEC-3 the private Sector operations are executable by authenticated through their wrappers, and never by anon';
  return next;

  ok := exists (select 1 from pg_catalog.pg_trigger
    where tgrelid = 'public.sector_versions'::regclass
      and tgname = 'trg_sectorv_transition');
  name := 'U5-SEC-4 the Sector version transition guard is still attached';
  return next;

  ok := not exists (select 1 from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename in ('sectors', 'sector_versions')
      and cmd = 'DELETE');
  name := 'U5-SEC-5 a Sector is deactivated, never deleted';
  return next;

  ok := not exists (
    select 1 from public.sectors s
     where s.status = 'active'
       and (select count(*) from public.sector_versions sv
             where sv.sector_id = s.id and sv.status = 'approved') <> 1);
  name := 'U5-SEC-6 every active Sector has exactly one approved version';
  return next;

  ok := exists (select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.sectors'::regclass
      and conname = 'uk_sector_code' and contype = 'u');
  name := 'U5-SEC-7 the Sector code stays unique';
  return next;

  -- STRUCTURAL, and deliberately not limited to this slice: EVERY public
  -- SECURITY INVOKER wrapper that authenticated may execute must call only
  -- app_private functions authenticated may also execute.
  for r in
    select w.oid::regprocedure::text as wrapper, m[1] as callee
      from pg_catalog.pg_proc w
      join pg_catalog.pg_namespace wn on wn.oid = w.pronamespace and wn.nspname = 'public'
     cross join lateral regexp_matches(w.prosrc, 'app_private\.([a-z_0-9]+)\s*\(', 'g') as m
     where not w.prosecdef
       and pg_catalog.has_function_privilege('authenticated', w.oid, 'EXECUTE')
  loop
    if not exists (
      select 1 from pg_catalog.pg_proc pr
        join pg_catalog.pg_namespace n on n.oid = pr.pronamespace
       where n.nspname = 'app_private' and pr.proname = r.callee
         and pg_catalog.has_function_privilege('authenticated', pr.oid, 'EXECUTE')
    ) then
      v_missing := v_missing || (r.wrapper || ' -> app_private.' || r.callee);
    end if;
  end loop;
  ok := cardinality(v_missing) = 0;
  name := 'U5-SEC-8 every public invoker wrapper can execute the private function it calls'
    || case when cardinality(v_missing) = 0 then '' else ' (broken: ' || array_to_string(v_missing, ', ') || ')' end;
  return next;
end $fn$;

revoke all on function tests.u5_governed_sector_master_catalogue() from public, anon, authenticated;
grant execute on function tests.u5_governed_sector_master_catalogue() to service_role;
