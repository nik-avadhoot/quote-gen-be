-- P2-4 DEFECT CORRECTION - reference allocation could reissue codes.
--
-- uk_refseq was `unique (scope_type, scope_key, fy_label)`. Postgres treats NULLs
-- as DISTINCT in a unique constraint, so for every scope that does not use a
-- financial year - group_customer, customer, location - the constraint enforced
-- nothing. allocate_reference's `on conflict do nothing` therefore never fired,
-- each call inserted ANOTHER counter row starting at 1, and the subsequent
-- UPDATE ... RETURNING matched multiple rows.
--
-- Consequences had this shipped: permanent business codes (Group Customer Code,
-- Customer Code, Location Code) could be issued twice, breaking CDM-03's
-- never-reused guarantee - the exact property the sequences exist to provide.
--
-- Postgres 17 (confirmed) supports NULLS NOT DISTINCT, which makes one NULL
-- fy_label collide with another as intended.

alter table ref_private.reference_sequences drop constraint uk_refseq;
alter table ref_private.reference_sequences
  add constraint uk_refseq unique nulls not distinct (scope_type, scope_key, fy_label);

-- Regression test: the same allocation scope must return strictly increasing,
-- never repeating values, and must keep exactly one counter row.
create or replace function tests.reference_allocation()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare a bigint; b bigint; c bigint; n int; v_auth uuid; v_user bigint;
begin
  select id into v_auth from public.profiles where role = 'maker' limit 1;
  insert into public.app_users (auth_user_id, display_name, status)
  values (v_auth, '__p2ref probe', 'active') returning id into v_user;
  perform pg_catalog.set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', v_auth), true);

  a := ref_private.allocate_reference('__p2ref', 0, null);
  b := ref_private.allocate_reference('__p2ref', 0, null);
  c := ref_private.allocate_reference('__p2ref', 0, null);
  select count(*) into n from ref_private.reference_sequences
   where scope_type = '__p2ref';

  return next ok(a <> b and b <> c and a <> c,
                 'R-1 repeated allocation in one scope never repeats a value');
  return next ok(b = a + 1 and c = b + 1,
                 'R-2 allocation is strictly sequential');
  return next is(n, 1,
                 'R-3 a NULL fy_label scope keeps exactly ONE counter row (NULLS NOT DISTINCT)');

  delete from ref_private.reference_sequences where scope_type = '__p2ref';
  delete from public.app_users where id = v_user;
exception when others then
  delete from ref_private.reference_sequences where scope_type = '__p2ref';
  delete from public.app_users where display_name = '__p2ref probe';
  raise;
end $fn$;

revoke execute on function tests.reference_allocation() from public;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from finish();
end $fn$;