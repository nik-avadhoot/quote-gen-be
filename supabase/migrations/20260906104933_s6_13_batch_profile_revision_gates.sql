-- S6-13 (S6-C2): the gates for the Batch Profile revision operation.
--
-- Every attempt below runs as `authenticated`. The suite mints three personas -
-- the owning Maker, a second Maker at the same plant who holds make_quote but
-- not the lock, and a Maker at another plant - so each denial can only come from
-- the rule it names. Successes are proved by reading the stored rows back, never
-- by the absence of an exception, which is the lesson DS-7 and PB-20 record.
--
-- BP-9 is the induced failure S6-C2 asks for. It drives a value through the
-- operation that ck_bpv_non_negative refuses, at a point AFTER the current
-- pointer has been demoted, and then proves the Batch still has exactly one
-- current profile version and that it is the same one as before - so neither
-- "two current" nor "none current" survives a partial failure, and the
-- content_version the compare-and-swap advanced is rolled back with it.

create or replace function tests.batch_profile()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_owner bigint; v_nag bigint; v_pun bigint; v_state text; v_cv int; v_cv2 int; v_id bigint;
  v_mauth uuid; v_mclaims text; v_maker bigint; v_memail text := 'p2-s6bp@example.invalid';
  v_oauth uuid; v_oclaims text; v_other bigint; v_oemail text := 'p2-s6bpo@example.invalid';
  v_pauth uuid; v_pclaims text; v_pmaker bigint; v_pemail text := 'p2-s6bpp@example.invalid';
  v_fam bigint; v_batch bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';

  -- ------------------------------------------------------- structural
  return next is(
    (select count(*)::int from pg_catalog.pg_policy p
       join pg_catalog.pg_class c on c.oid = p.polrelid
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname='public' and c.relname='batch_profile_versions' and p.polcmd='w'),
    0, 'BP-1 batch_profile_versions still has NO update policy - the pointer belongs to the operation, not to the API');
  return next ok(
    not pg_catalog.has_table_privilege('authenticated','public.batch_profile_versions','UPDATE'),
    'BP-1a and authenticated holds no UPDATE grant on it either');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='revise_batch_profile'
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')),
    0, 'BP-1b anon cannot execute the revision operation');

  -- --------------------------------------------------------- personas
  v_mauth := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_memail, '__p2_s6_bp_owner', false);
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated; v_maker := public.bootstrap_app_user(); reset role;

  v_oauth := tests.__fixture_auth_uid();
  v_oclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_oauth, v_oemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_oemail, '__p2_s6_bp_other', false);
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated; v_other := public.bootstrap_app_user(); reset role;

  v_pauth := tests.__fixture_auth_uid();
  v_pclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_pauth, v_pemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_pemail, '__p2_s6_bp_pun', false);
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated; v_pmaker := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_other, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_pmaker, v_pun, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');

  insert into public.customer_families (name, status, created_by)
    values ('__p2 bp family','active',v_owner) returning id into v_fam;

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_batch := public.create_batch(v_fam, v_nag, null);
  reset role;
  return next is((select count(*)::int from public.batch_profile_versions where batch_id=v_batch and is_current), 1,
    'BP-2 a new Batch starts with exactly one current profile version');

  -- ================================================= the positive path
  select content_version into v_cv from public.batches where id = v_batch;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_id := public.revise_batch_profile(v_batch, v_cv, 6.500, null, null, null, 12.000, null);
  reset role;

  return next ok(v_id is not null, 'BP-3 the owner revises the profile through the operation');
  return next is((select version_no from public.batch_profile_versions where id=v_id), 2,
    'BP-3a the new version is the next version number');
  return next is((select count(*)::int from public.batch_profile_versions where batch_id=v_batch and is_current), 1,
    'BP-3b and there is still EXACTLY ONE current version');
  return next is((select id from public.batch_profile_versions where batch_id=v_batch and is_current), v_id,
    'BP-3c which is the new one - the pointer moved');
  return next is((select is_current from public.batch_profile_versions where batch_id=v_batch and version_no=1), false,
    'BP-3d and version 1 is demoted, not deleted - the history is immutable (§3.5)');
  return next is((select waste_cbb_pct from public.batch_profile_versions where id=v_id), 6.500,
    'BP-3e the value the caller sent is stored');
  return next ok((select waste_pp_pct is null from public.batch_profile_versions where id=v_id),
    'BP-3f and a blank field is stored as NULL, never as zero (D-25/CDM-19)');
  return next is((select created_by from public.batch_profile_versions where id=v_id), v_maker,
    'BP-3g attributed to the caller from the session (CDM-34)');
  return next is((select content_version from public.batches where id=v_batch), v_cv + 1,
    'BP-4 and the Batch content version advanced, because a profile change is a content change');

  -- ==================================================== stale version
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.revise_batch_profile(v_batch, v_cv, 1.000, null, null, null, null, null);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '40001',
    'BP-5 a revision carrying a STALE content version is refused - compare-and-swap, not last-write-wins');
  return next is((select count(*)::int from public.batch_profile_versions where batch_id=v_batch), 2,
    'BP-5a and no version was created');
  return next is((select id from public.batch_profile_versions where batch_id=v_batch and is_current), v_id,
    'BP-5b the current pointer is untouched');

  -- ================================================ authority denials
  select content_version into v_cv2 from public.batches where id = v_batch;

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    perform public.revise_batch_profile(v_batch, v_cv2, 2.000, null, null, null, null, null);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'BP-6 a second Maker at the same plant, holding make_quote but NOT the lock, is refused (CDM-32)');

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    perform public.revise_batch_profile(v_batch, v_cv2, 3.000, null, null, null, null, null);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'BP-7 a Maker at ANOTHER plant is refused - the Batch is not theirs to write');

  update public.app_users set status='deactivated', deactivated_at=now() where id = v_maker;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.revise_batch_profile(v_batch, v_cv2, 4.000, null, null, null, null, null);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'BP-8 a DEACTIVATED owner holding the same token and the same lock is refused (CDM-05)');
  update public.app_users set status='active', deactivated_at=null where id = v_maker;

  return next is((select count(*)::int from public.batch_profile_versions where batch_id=v_batch), 2,
    'BP-8a none of the three refusals created a version');
  return next is((select content_version from public.batches where id=v_batch), v_cv2,
    'BP-8b and none of them advanced the Batch content version either');

  -- ================================================== induced failure
  -- A negative margin is refused by ck_bpv_non_negative, and it is refused
  -- AFTER the current pointer has been demoted and the content version
  -- advanced. If the operation were not atomic this Batch would be left with no
  -- current profile version at all.
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.revise_batch_profile(v_batch, v_cv2, null, null, null, null, -1.000, null);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514', 'BP-9 an illegal profile value is refused by the check constraint');
  return next is((select count(*)::int from public.batch_profile_versions where batch_id=v_batch and is_current), 1,
    'BP-9a and the Batch still has EXACTLY ONE current profile version - the demote rolled back with the insert');
  return next is((select id from public.batch_profile_versions where batch_id=v_batch and is_current), v_id,
    'BP-9b and it is the same version that was current before the failed attempt');
  return next is((select count(*)::int from public.batch_profile_versions where batch_id=v_batch), 2,
    'BP-9c with no orphan version left behind');
  return next is((select content_version from public.batches where id=v_batch), v_cv2,
    'BP-9d and the compare-and-swap increment rolled back too - the whole operation is one act');

  -- the invariant, database-wide
  return next is(
    (select count(*)::int from public.batches b
      where (select count(*) from public.batch_profile_versions v
              where v.batch_id = b.id and v.is_current) <> 1),
    0, 'BP-10 every Batch in the database has exactly one current profile version');

  -- ------------------------------------------------------------- cleanup
  delete from public.batch_calculations where batch_id = v_batch;
  delete from public.batch_rows where batch_id = v_batch;
  update public.pricing_groups set freight_basis_delivery_group_id = null where batch_id = v_batch;
  delete from public.delivery_groups where batch_id = v_batch;
  delete from public.pricing_groups where batch_id = v_batch;
  delete from public.batch_profile_versions where batch_id = v_batch;
  delete from public.batch_edit_locks where batch_id = v_batch;
  delete from public.batches where id = v_batch;
  delete from public.customer_families where id = v_fam;
  delete from public.plant_capability_grants where app_user_id in (v_maker, v_other, v_pmaker);
  delete from public.group_capability_grants where app_user_id in (v_maker, v_other, v_pmaker);
  delete from public.operational_settings     where created_by  in (v_maker, v_other, v_pmaker);
  delete from app_private.pending_invitations where invite_email in (v_memail, v_oemail, v_pemail);
  delete from public.app_users where id in (v_maker, v_other, v_pmaker);
  perform tests.__drop_synthetic_auth(v_mauth);
  perform tests.__drop_synthetic_auth(v_oauth);
  perform tests.__drop_synthetic_auth(v_pauth);
  perform pg_catalog.set_config('request.jwt.claims', null, true);
end $fn$;

revoke all on function tests.batch_profile() from public, anon, authenticated;
