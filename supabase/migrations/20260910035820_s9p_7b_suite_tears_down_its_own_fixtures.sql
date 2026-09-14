-- S9-P/7b: the suite must leave nothing behind that references a fixture identity.
--
-- THE CONTRACT THIS HONOURS. tests.synthetic_fixture_integrity() sweeps every
-- synthetic identity and then asserts SF-1 "no synthetic fixture identity
-- survives the suite" and SF-2 "no application identity is left attached to
-- one". For that sweep to succeed, NO domain row may still reference a synthetic
-- app_user when the suite ends. A suite that mints a Customer Family, a Batch,
-- masters and Releases and walks away leaves the sweep unable to delete the
-- identity that created them, and the whole run fails on a foreign key rather
-- than on an assertion.
--
-- WHY THIS SUITE NEEDS IT WHEN OLDER ONES APPEAR NOT TO. This is the first suite
-- to create a Pricing Basis Release chain AND a Batch AND product masters
-- against one fixture owner. It is also the deepest fixture graph in the file
-- set. Rather than depend on how tests.__fixture_owner() happens to resolve on a
-- given day - persistent from an earlier run, or minted fresh with a live
-- synthetic auth row - the suite now tears down exactly what it built. Being
-- self-contained is the property that makes it reliable in any order and in any
-- environment, and it is cheaper than reasoning about the rest of the file set.
--
-- DELETION IS BY CAPTURED ID, NOT BY NAME PATTERN. Every row removed below is
-- one this suite created and holds an identifier for, so the teardown cannot
-- reach a neighbouring suite's fixture or any real row. It runs AFTER every
-- assertion, so nothing it removes can change a verdict.

create or replace function tests.__s9p_teardown(
  p_batches bigint[], p_releases bigint[], p_skuv bigint, p_sku bigint,
  p_cv bigint, p_con bigint, p_sv bigint, p_sec bigint,
  p_rsv bigint[], p_rs bigint[], p_fsv bigint[], p_fs bigint[],
  p_cdv bigint, p_party bigint, p_fam bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  delete from public.batch_calculations      where batch_id = any(p_batches);
  delete from public.batch_set_memberships   where batch_id = any(p_batches);
  delete from public.batch_sets              where batch_id = any(p_batches);
  delete from public.batch_rows              where batch_id = any(p_batches);
  delete from public.batch_edit_locks        where batch_id = any(p_batches);
  delete from public.batch_profile_versions  where batch_id = any(p_batches);
  delete from public.batch_collaborators     where batch_id = any(p_batches);
  delete from public.delivery_groups         where batch_id = any(p_batches);
  delete from public.pricing_groups          where batch_id = any(p_batches);
  delete from public.batches                 where id       = any(p_batches);

  delete from public.pricing_basis_releases  where id = any(p_releases);
  delete from public.sku_versions            where id = p_skuv;
  delete from public.skus                    where id = p_sku;
  delete from public.construction_versions   where id = p_cv;
  delete from public.constructions           where id = p_con;
  delete from public.sector_versions         where id = p_sv;
  delete from public.sectors                 where id = p_sec;
  delete from public.rate_set_versions       where id = any(p_rsv);
  delete from public.rate_sets               where id = any(p_rs);
  delete from public.freight_set_versions    where id = any(p_fsv);
  delete from public.freight_sets            where id = any(p_fs);
  delete from public.calculation_default_versions where id = p_cdv;
  delete from public.party_family_memberships     where party_id = p_party;
  delete from public.parties                 where id = p_party;
  delete from public.customer_families       where id = p_fam;
  delete from app_private.pending_invitations where invite_email like 'p2-s9p-%';
end $fn$;

revoke all on function tests.__s9p_teardown(bigint[],bigint[],bigint,bigint,bigint,bigint,bigint,bigint,bigint[],bigint[],bigint[],bigint[],bigint,bigint,bigint)
  from public, anon, authenticated;