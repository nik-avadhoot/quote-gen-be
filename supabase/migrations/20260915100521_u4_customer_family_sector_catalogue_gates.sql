-- U4 catalogue gates for Customer Family -> Sector classification.

create or replace function tests.u4_customer_family_sector_catalogue()
returns table(ok boolean, name text)
language plpgsql security definer set search_path = '' as $fn$
begin
  ok := exists (select 1 from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'customer_family_sectors'
      and c.relrowsecurity and c.relforcerowsecurity);
  name := 'U4-CFS-1 membership table has RLS enabled and forced';
  return next;

  ok := exists (select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.customer_family_sectors'::regclass
      and conname = 'pk_customer_family_sectors' and contype = 'p');
  name := 'U4-CFS-2 one Family/Sector pair is unique';
  return next;

  ok := not pg_catalog.has_table_privilege('authenticated',
    'public.customer_family_sectors', 'INSERT,UPDATE,DELETE');
  name := 'U4-CFS-3 authenticated callers cannot write membership rows directly';
  return next;

  ok := exists (select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.batches'::regclass
      and conname = 'ck_batch_sector_required' and contype = 'c');
  name := 'U4-CFS-4 new and changed Batches require a Sector';
  return next;

  ok := exists (select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.batches'::regclass
      and conname = 'fk_batch_family_sector' and contype = 'f');
  name := 'U4-CFS-5 Batch Sector is structurally scoped to its Customer Family';
  return next;

  ok := exists (select 1 from pg_catalog.pg_trigger
    where tgrelid = 'public.customer_families'::regclass
      and tgname = 'trg_customer_family_requires_sector'
      and tgdeferrable and tginitdeferred);
  name := 'U4-CFS-6 Family minimum-one-Sector invariant is transaction-safe';
  return next;

  ok := pg_catalog.has_function_privilege('authenticated',
      'public.add_customer_family_sector(bigint,bigint,integer)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon',
      'public.add_customer_family_sector(bigint,bigint,integer)', 'EXECUTE');
  name := 'U4-CFS-7 only authenticated callers can enter the governed add operation';
  return next;
end $fn$;

revoke all on function tests.u4_customer_family_sector_catalogue() from public, anon, authenticated;
grant execute on function tests.u4_customer_family_sector_catalogue() to service_role;
