-- S9-P/7c: make the suite self-contained by construction.
--
-- The assertions are unchanged. What changes is that the suite now removes the
-- fixture graph it built, so it leaves nothing referencing a synthetic identity
-- and tests.synthetic_fixture_integrity()'s SF-1/SF-2 sweep can complete.
--
-- SHAPE. The existing body is renamed to tests.__s9p_body() and a thin
-- tests.calculation_persistence() returns its rows and then tears down. The
-- double-underscore prefix is the established convention for helpers that are
-- NOT suites (tests.__fixture_owner, tests.__cleanup_fixtures,
-- tests.__ua3_last_admin_verdicts), so tests.suite_registration() continues to
-- see exactly one registered suite here and no orphan.
--
-- WHY THE TEARDOWN RUNS AFTER THE ROWS ARE RETURNED. `return query` materialises
-- the suite's verdicts before the teardown executes, so nothing removed here can
-- change an assertion. CP-69 and CP-70, which read the temporary-freight state,
-- have already produced their answers by then.
--
-- TEARDOWN IS SCOPED BY THIS SUITE'S OWN MARKERS. Every predicate below names a
-- literal this suite wrote - '__p2 s9p ...', '__S9P', '__s9p ...', version_no
-- 951, 'p2-s9p-%'. It cannot reach a neighbouring suite's fixture and cannot
-- reach a real row. Batches are found through the Family this suite created, so
-- both the calendar-gap Batch and the main Batch are covered without either
-- being named.

alter function tests.calculation_persistence() rename to __s9p_body;

drop function if exists tests.__s9p_teardown(bigint[],bigint[],bigint,bigint,bigint,bigint,bigint,bigint,bigint[],bigint[],bigint[],bigint[],bigint,bigint,bigint);

create or replace function tests.__s9p_teardown()
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_fam bigint; v_party bigint; v_batches bigint[];
begin
  select id into v_fam   from public.customer_families where name = '__p2 s9p family';
  select id into v_party from public.parties           where display_name = '__p2 s9p party';
  select coalesce(array_agg(id), '{}') into v_batches
    from public.batches where family_id = v_fam;

  delete from public.batch_calculations     where batch_id = any(v_batches);
  delete from public.batch_set_memberships  where batch_id = any(v_batches);
  delete from public.batch_sets             where batch_id = any(v_batches);
  delete from public.batch_rows             where batch_id = any(v_batches);
  delete from public.batch_edit_locks       where batch_id = any(v_batches);
  delete from public.batch_profile_versions where batch_id = any(v_batches);
  delete from public.batch_collaborators    where batch_id = any(v_batches);
  delete from public.delivery_groups        where batch_id = any(v_batches);
  delete from public.pricing_groups         where batch_id = any(v_batches);
  delete from public.batches                where id       = any(v_batches);

  delete from public.pricing_basis_releases where release_name like '\_\_s9p%';
  delete from public.sku_versions           where sku_id in (select id from public.skus where party_id = v_party);
  delete from public.skus                   where party_id = v_party;
  delete from public.construction_versions  where construction_id in
    (select id from public.constructions where name = '__p2 s9p con');
  delete from public.constructions          where name = '__p2 s9p con';
  delete from public.sector_versions        where sector_id in
    (select id from public.sectors where sector_code = '__S9P');
  delete from public.sectors                where sector_code = '__S9P';
  delete from public.rate_set_versions      where rate_set_id in
    (select id from public.rate_sets where name like '\_\_p2 s9p rs%');
  delete from public.rate_sets              where name like '\_\_p2 s9p rs%';
  delete from public.freight_set_versions   where freight_set_id in
    (select id from public.freight_sets where name like '\_\_p2 s9p fs%');
  delete from public.freight_sets           where name like '\_\_p2 s9p fs%';
  delete from public.calculation_default_versions where version_no = 951;
  delete from public.party_family_memberships     where party_id = v_party;
  delete from public.parties                where id = v_party;
  delete from public.customer_families      where id = v_fam;
  delete from app_private.pending_invitations where invite_email like 'p2-s9p-%';
end $fn$;

create or replace function tests.calculation_persistence()
returns setof text language plpgsql set search_path = 'extensions', 'pg_catalog' as $fn$
begin
  return query select * from tests.__s9p_body();
  perform tests.__s9p_teardown();
end $fn$;

revoke all on function tests.__s9p_body() from public, anon, authenticated;
revoke all on function tests.__s9p_teardown() from public, anon, authenticated;
revoke all on function tests.calculation_persistence() from public, anon, authenticated;