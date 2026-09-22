-- U5 catalogue gates for the governed Sector master operations, plus the
-- registration splice that puts them in tests.run_all().

create or replace function tests.u5_governed_sector_master_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
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

  -- The private operations stay private; the public wrappers are the only door.
  ok := not pg_catalog.has_function_privilege('authenticated',
      'app_private.propose_sector(text,text,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated',
      'app_private.revise_sector_commercials(bigint,integer,numeric,numeric,numeric,numeric,numeric,text)', 'EXECUTE');
  name := 'U5-SEC-3 the private Sector operations are not directly executable';
  return next;

  -- CDM-31: an approved version is corrected by a new version, never in place.
  ok := exists (select 1 from pg_catalog.pg_trigger
    where tgrelid = 'public.sector_versions'::regclass
      and tgname = 'trg_sectorv_transition');
  name := 'U5-SEC-4 the Sector version transition guard is still attached';
  return next;

  -- No Family D table may acquire a DELETE policy (CDM-31).
  ok := not exists (select 1 from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename in ('sectors', 'sector_versions')
      and cmd = 'DELETE');
  name := 'U5-SEC-5 a Sector is deactivated, never deleted';
  return next;

  -- Every live Sector must resolve to exactly one approved version, or the
  -- Costing resolution chain has nothing to read.
  ok := not exists (
    select 1 from public.sectors s
     where s.status = 'active'
       and (select count(*) from public.sector_versions sv
             where sv.sector_id = s.id and sv.status = 'approved') <> 1);
  name := 'U5-SEC-6 every active Sector has exactly one approved version';
  return next;

  -- The unique code is what Costing resolves a Sector by; duplicates would
  -- make that lookup ambiguous.
  ok := exists (select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.sectors'::regclass
      and conname = 'uk_sector_code' and contype = 'u');
  name := 'U5-SEC-7 the Sector code stays unique';
  return next;
end $fn$;

revoke all on function tests.u5_governed_sector_master_catalogue() from public, anon, authenticated;
grant execute on function tests.u5_governed_sector_master_catalogue() to service_role;

-- Register the suite, spliced onto a stable neighbouring anchor rather than
-- retyped, so concurrent registrations already in the stored function survive.
do $mig$
declare
  v_def    text;
  v_anchor text := '  return query select * from tests.u4_customer_family_sector_catalogue();';
  v_cnt    integer;
begin
  v_def := pg_catalog.pg_get_functiondef('tests.run_all()'::regprocedure);

  if position('tests.u5_governed_sector_master_catalogue()' in v_def) > 0 then
    raise exception 'the U5 Sector catalogue suite is already registered';
  end if;

  v_cnt := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 u4_customer_family_sector_catalogue anchor, found %', v_cnt;
  end if;

  v_def := replace(
    v_def,
    v_anchor,
    v_anchor || E'\n' ||
      '  return query select * from tests.u5_governed_sector_master_catalogue();'
  );

  execute v_def;

  v_def := pg_catalog.pg_get_functiondef('tests.run_all()'::regprocedure);
  if position('tests.u5_governed_sector_master_catalogue()' in v_def) = 0 then
    raise exception 'U5 Sector catalogue suite registration verification failed';
  end if;
end $mig$;

revoke all on function tests.run_all() from public, anon, authenticated;
