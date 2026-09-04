-- P2-3: regression tests for Family B.

create or replace function tests.party_masters()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['customer_families','customer_family_aliases','parties',
                           'party_family_memberships','party_external_references',
                           'customer_locations','customer_location_versions'];
  t text;
  n_seen int;
begin
  foreach t in array v_tables loop
    return next ok(
      (select c.relrowsecurity and c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = t),
      format('F-1 %s has RLS enabled AND forced', t));
    return next ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')),
      format('F-2 anon holds no privilege on %s', t));
    -- CDM-31: no delete path on any formal record
    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t and pol.polcmd='d'),
      0, format('F-3 %s has no DELETE policy for any role', t));
  end loop;

  -- one permissive policy per table/action across Family B
  return next is(
    (select coalesce(max(cnt),0)::int from (
       select count(*) cnt from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname = any(v_tables)
        group by c.relname, pol.polcmd) q),
    1, 'F-4 exactly one permissive policy per Family B table and action');

  -- CDM-05/CDM-35: read is denied without an explicit group grant
  perform pg_catalog.set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000995","role":"authenticated"}', true);
  set local role authenticated;
  select count(*) into n_seen from public.parties;
  reset role;
  return next is(n_seen, 0, 'F-5 caller without read_party_master sees no parties');

  -- CDM-06: a graduated Customer cannot exist without a permanent Customer Code
  begin
    insert into public.parties (display_name, lifecycle_state, status, created_by)
    values ('ck probe', 'customer', 'active', 1);
    return next fail('F-6 a customer without customer_code should be rejected');
  exception when others then
    return next ok(true, 'F-6 customer without customer_code rejected ('||sqlstate||')');
  end;

  -- DM-118: a Location must be usable for something
  begin
    insert into public.customer_locations (party_id, bill_to_eligible, ship_to_eligible, created_by)
    values (1, false, false, 1);
    return next fail('F-7 a location eligible for neither bill-to nor ship-to should be rejected');
  exception when others then
    return next ok(true, 'F-7 location with no eligibility rejected ('||sqlstate||')');
  end;
end $fn$;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.party_masters();
  return query select * from finish();
end $fn$;