-- Catalogue gates for the GSM Master.

create or replace function tests.gsm_master_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
begin
  ok := exists (select 1 from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'paper_gsm_values'
      and c.relrowsecurity and c.relforcerowsecurity);
  name := 'GSM-1 GSM Master has RLS enabled and forced';
  return next;

  ok := exists (select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.paper_gsm_values'::regclass
      and conname = 'uk_paper_gsm_value' and contype = 'u');
  name := 'GSM-2 one row per GSM value';
  return next;

  ok := not pg_catalog.has_table_privilege('authenticated',
    'public.paper_gsm_values', 'INSERT,UPDATE,DELETE');
  name := 'GSM-3 authenticated callers cannot write GSM rows directly';
  return next;

  ok := (select count(*) from public.paper_gsm_values
    where gsm in (80, 100, 110, 120, 140, 150, 170, 180, 200, 220, 230, 250)) = 12;
  name := 'GSM-4 the Product Owner seed list is present';
  return next;

  ok := pg_catalog.has_function_privilege('authenticated',
      'public.add_paper_gsm_value(integer)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',
      'public.add_paper_gsm_value(integer)', 'EXECUTE')
    and pg_catalog.has_function_privilege('authenticated',
      'public.set_paper_gsm_value_status(bigint,text,integer)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',
      'public.set_paper_gsm_value_status(bigint,text,integer)', 'EXECUTE');
  name := 'GSM-5 only authenticated callers can enter the governed GSM operations';
  return next;

  ok := not pg_catalog.has_function_privilege('authenticated',
      'app_private.add_paper_gsm_value(integer)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated',
      'app_private.set_paper_gsm_value_status(bigint,text,integer)', 'EXECUTE');
  name := 'GSM-6 private definer functions are reachable only through the invoker wrappers';
  return next;
end $fn$;

revoke all on function tests.gsm_master_catalogue() from public, anon, authenticated;
grant execute on function tests.gsm_master_catalogue() to service_role;
