-- S6-7: reclaim authority was broader than CDM-32, and is tightened to match.
--
-- FOUND BY THE TEST, and it is a divergence rather than a bug. S6-4 gated
-- reclaim on can_read_batch, so anyone who could READ a Batch - including a
-- plain collaborator - could take a stale lock. CDM-32 names two acts and only
-- two: "Owner reclaim and Checker/Admin takeover are atomic and audited; active
-- takeover requires reason." A collaborator reclaim is not among them.
--
-- The working rule on this programme is to flag divergence rather than diverge,
-- so the implementation moves to what the canonical record actually says:
-- reclaim requires the Batch OWNER, or the same authority that may take over -
-- check_quote at that plant, or administer_users. Every one of those is named by
-- CDM-32; none is invented here.
--
-- STATED FOR THE PRODUCT OWNER, not decided here: whether an authorised
-- COLLABORATOR should also be able to reclaim a stale lock is a real question -
-- without it, work stalls when an owner goes away mid-edit - but it is a product
-- decision and CDM-32 does not grant it. The narrower reading ships.
--
-- The distinction between the two acts is preserved and is the point: reclaim
-- waits for server-judged staleness and needs no reason; takeover does not wait
-- and requires one.

create or replace function app_private.reclaim_batch_lock(p_batch bigint, p_expected_holder bigint)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint; v_stale int; v_plant bigint; v_owner bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then raise exception 'no active app user' using errcode = '42501'; end if;

  select plant_id, owner_user_id into v_plant, v_owner
    from public.batches where id = p_batch;
  if v_plant is null then
    raise exception 'unknown Batch' using errcode = '23503';
  end if;

  -- CDM-32: owner reclaim, or the authority that may also take over
  if not ( v_owner = v_me
        or app_private.has_plant_cap(v_plant,'check_quote')
        or app_private.has_group_cap('administer_users') ) then
    raise exception 'only the Batch owner, the Checker at that plant or an administrator may reclaim a lock (CDM-32)'
      using errcode = '42501';
  end if;

  v_stale := app_private.edit_lock_stale_seconds();

  update public.batch_edit_locks
     set holder_user_id = v_me, acquired_at = now(), heartbeat_at = now(), released_at = null
   where batch_id = p_batch
     and holder_user_id = p_expected_holder
     and released_at is null
     and now() - heartbeat_at > (v_stale * interval '1 second')
  returning id into v_id;

  if v_id is null then
    raise exception 'the lock was not stale, or another caller reclaimed it first'
      using errcode = '55P03';
  end if;
  return v_id;
end $fn$;

-- The lock gates in tests.batch_locks() are restated so their personas match the
-- tightened rule: the Checker reclaims the stale lock, and the OWNER then loses
-- the replayed reclaim - both parties authorised, so the only thing deciding the
-- race is the conditional statement itself, which is what BL-10 exists to prove.
create or replace function tests.batch_locks()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_owner bigint; v_nag bigint; v_state text; v_n int; v_cv int; v_hb timestamptz;
  v_fam bigint;
  v_mauth uuid; v_mclaims text; v_maker bigint; v_memail text := 'p2-s6m@example.invalid';
  v_oauth uuid; v_oclaims text; v_other bigint; v_oemail text := 'p2-s6o@example.invalid';
  v_cauth uuid; v_cclaims text; v_check bigint; v_cemail text := 'p2-s6c@example.invalid';
  v_batch bigint; v_pg bigint; v_lock bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';

  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='batch_edit_locks' and column_name='content_version'),
    0, 'BL-1 (A-23) batch_edit_locks has no content_version column at all - the two cannot be confused');

  v_mauth := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_memail, '__p2_s6_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated; v_maker := public.bootstrap_app_user(); reset role;

  v_oauth := tests.__fixture_auth_uid();
  v_oclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_oauth, v_oemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_oemail, '__p2_s6_other', false);
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated; v_other := public.bootstrap_app_user(); reset role;

  v_cauth := tests.__fixture_auth_uid();
  v_cclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_cauth, v_cemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_cemail, '__p2_s6_checker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated; v_check := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_other, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_check, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','check_quote');

  insert into public.customer_families (name, status, created_by)
    values ('__p2 bl family','active',v_owner) returning id into v_fam;

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_batch := public.create_batch(v_fam, v_nag, null);
  reset role;
  return next ok(v_batch is not null, 'BL-2 a Maker creates a Batch through the RPC');
  return next is((select count(*)::int from public.pricing_groups where batch_id=v_batch), 1,
    'BL-2a with exactly one default Pricing Group (CDM-15)');
  return next is((select count(*)::int from public.delivery_groups where batch_id=v_batch), 1,
    'BL-2b and one default Delivery Group');
  return next is((select count(*)::int from public.batch_profile_versions where batch_id=v_batch and is_current), 1,
    'BL-2c and exactly one current Batch Profile version');
  return next is((select count(*)::int from public.batch_edit_locks where batch_id=v_batch and holder_user_id=v_maker), 1,
    'BL-2d and the creator holds the edit lock');

  select id into v_pg from public.pricing_groups where batch_id = v_batch;

  select content_version into v_cv from public.batches where id = v_batch;
  select heartbeat_at into v_hb from public.batch_edit_locks where batch_id = v_batch;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  perform public.heartbeat_batch_lock(v_batch);
  reset role;
  return next is((select content_version from public.batches where id=v_batch), v_cv,
    'BL-3 (A-23) the heartbeat leaves batches.content_version untouched');
  return next ok((select heartbeat_at from public.batch_edit_locks where batch_id=v_batch) >= v_hb,
    'BL-3a while advancing heartbeat_at, which is all it may touch');

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 no lock' where id = v_pg;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), 'Default',
    'BL-4 a second Maker WITHOUT the lock changes nothing, even holding make_quote');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 with lock' where id = v_pg;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), '__p2 with lock',
    'BL-4a while the lock holder writes normally');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.pricing_groups set content_version = 99 where id = v_pg;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'BL-5 content_version is the database''s to maintain - a caller cannot set it');

  select content_version into v_cv from public.pricing_groups where id = v_pg;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 again' where id = v_pg;
  reset role;
  return next is((select content_version from public.pricing_groups where id=v_pg), v_cv + 1,
    'BL-6 and it advances on every write, so it is a usable CAS token');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 stale write'
   where id = v_pg and content_version = v_cv - 1;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), '__p2 again',
    'BL-7 a write carrying a STALE content_version matches no row and changes nothing');

  select content_version into v_cv from public.pricing_groups where id = v_pg;
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.pricing_groups set label = '__p2 fresh write'
   where id = v_pg and content_version = v_cv;
  reset role;
  return next is((select label from public.pricing_groups where id=v_pg), '__p2 fresh write',
    'BL-7a while the current one succeeds - CAS works through the filter (PostgREST style)');

  -- CDM-32 reclaim authority, tightened in this slice
  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    perform public.reclaim_batch_lock(v_batch, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'BL-8 (CDM-32) a second Maker who is neither owner nor Checker cannot reclaim at all');

  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  begin
    perform public.reclaim_batch_lock(v_batch, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '55P03',
    'BL-8a (A-24) and even the Checker cannot reclaim a LIVE lock - staleness is judged server-side');

  update public.batch_edit_locks
     set heartbeat_at = now() - ((app_private.edit_lock_stale_seconds() + 60) * interval '1 second')
   where batch_id = v_batch;

  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  v_lock := public.reclaim_batch_lock(v_batch, v_maker);
  reset role;
  return next ok(v_lock is not null, 'BL-9 a STALE lock is reclaimable by an authorised caller');
  return next is((select holder_user_id from public.batch_edit_locks where batch_id=v_batch), v_check,
                 'BL-9a and the reclaimer now holds it');

  -- the owner replays the SAME reclaim: authorised, but the condition has moved
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    perform public.reclaim_batch_lock(v_batch, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '55P03',
    'BL-10 a second reclaim naming the SAME expected holder loses - one conditional statement, one winner');
  return next is((select holder_user_id from public.batch_edit_locks where batch_id=v_batch), v_check,
    'BL-10a and the first winner still holds it - the loser changed nothing');

  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  begin
    perform public.takeover_batch_lock(v_batch, '   ');
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '22023', 'BL-11 (CDM-32) an active takeover REQUIRES a reason');

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    perform public.takeover_batch_lock(v_batch, 'maker attempting takeover');
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'BL-12 and a plain Maker cannot take over - it is the Checker''s or an administrator''s act');

  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  perform public.takeover_batch_lock(v_batch, 'checker takeover with reason');
  reset role;
  return next is((select holder_user_id from public.batch_edit_locks where batch_id=v_batch), v_check,
    'BL-12a while the Checker with a reason succeeds, without waiting for staleness');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.proname in ('create_batch','acquire_batch_lock','heartbeat_batch_lock',
                          'release_batch_lock','reclaim_batch_lock','takeover_batch_lock')
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')),
    0, 'BL-13 anon can execute none of the Batch or lock operations');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app_private'
        and p.proname in ('create_batch','acquire_batch_lock','heartbeat_batch_lock',
                          'release_batch_lock','reclaim_batch_lock','takeover_batch_lock')
        and p.prosecdef),
    6, 'BL-13a and all six privileges live in app_private as SECURITY DEFINER');

  delete from public.batch_calculations where batch_id = v_batch;
  delete from public.batch_rows where batch_id = v_batch;
  update public.pricing_groups set freight_basis_delivery_group_id = null where batch_id = v_batch;
  delete from public.delivery_groups where batch_id = v_batch;
  delete from public.pricing_groups where batch_id = v_batch;
  delete from public.batch_profile_versions where batch_id = v_batch;
  delete from public.batch_edit_locks where batch_id = v_batch;
  delete from public.batches where id = v_batch;
  delete from public.customer_families where id = v_fam;
  delete from public.plant_capability_grants where app_user_id in (v_maker, v_other, v_check);
  delete from public.group_capability_grants where app_user_id in (v_maker, v_other, v_check);
  delete from public.operational_settings     where created_by  in (v_maker, v_other, v_check);
  delete from app_private.pending_invitations where invite_email in (v_memail, v_oemail, v_cemail);
  delete from public.app_users where id in (v_maker, v_other, v_check);
  perform tests.__drop_synthetic_auth(v_mauth);
  perform tests.__drop_synthetic_auth(v_oauth);
  perform tests.__drop_synthetic_auth(v_cauth);
  perform pg_catalog.set_config('request.jwt.claims', null, true);
end $fn$;

revoke all on function tests.batch_locks() from public, anon, authenticated;