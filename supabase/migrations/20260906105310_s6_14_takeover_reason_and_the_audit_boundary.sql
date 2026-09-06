-- S6-14 (S6-C3): stop accepting a reason that is thrown away, and name the
-- obligation that is genuinely outstanding.
--
-- WHAT WAS WRONG. takeover_batch_lock(p_batch, p_reason) validated that a reason
-- was present and non-blank, raised 22023 if it was not - and then never
-- referenced p_reason again. The reason went nowhere. There is no audit_events
-- table; §3.7 places it in Family H, which no slice has built. So the signature
-- advertised an accountability record that does not exist, and BL-11 asserted
-- the validation as though it were CDM-32's audit requirement being met.
--
-- WHY NOT PERSIST IT INSTEAD. batch_edit_locks holds one row per Batch, unique
-- on batch_id, overwritten by every acquire, reclaim and takeover. A
-- takeover_reason column there would keep only the MOST RECENT reason and would
-- be erased by the next ordinary acquire. That is a scratch field wearing the
-- costume of an audit trail, and CDM-34 asks for append-only events with actor,
-- timestamp, action and material before/after. Storing something lossy in a
-- place that looks authoritative is worse than storing nothing, because the next
-- reader believes it.
--
-- The other way to persist it is a new append-only Family F lock-event table.
-- §4.6 lists exactly ten Family F tables and that is not among them, so it is a
-- schema decision rather than a correction, and the authorisation for this pass
-- is explicit that a partial general-purpose audit architecture is not to be
-- introduced inside S6 to close this point. It is not built here.
--
-- SO THE PARAMETER GOES, and the deficit becomes visible. Read CDM-32 as one
-- sentence: "Owner reclaim and Checker/Admin takeover are atomic and audited;
-- active takeover requires reason." The requirement to state a reason exists so
-- that the reason is ON THE RECORD. With no record, demanding the reason is a
-- speed bump that produces nothing - it does not deter, does not inform, and
-- cannot be reviewed. Removing it loses no control that was actually operating,
-- and it stops the API from implying one.
--
-- WHAT IS AND IS NOT AUDITED TODAY, stated plainly so the closure record can
-- carry it unchanged:
--
--   AUDITED NOW  - who holds a lock, when they acquired it, when they last
--                  heartbeat, and whether it is released. batch_edit_locks
--                  carries holder_user_id, acquired_at, heartbeat_at,
--                  released_at, and a takeover or reclaim overwrites them, so
--                  the CURRENT state is always attributable.
--   NOT AUDITED  - the HISTORY of those acts. Who took a lock from whom, when,
--                  and why; and the same for reclaim. Nothing anywhere records
--                  a previous holder.
--
-- THE FAMILY H OBLIGATION, carried forward explicitly:
--
--   O-1  CDM-32/CDM-34 require an append-only audit event for Checker/Admin
--        TAKEOVER carrying actor, previous holder, timestamp and a MANDATORY
--        reason, and for owner RECLAIM carrying actor, previous holder and
--        timestamp. Neither exists. The reason parameter returns with the event
--        that stores it, and not before.
--
-- BL-11 is restated to assert the boundary rather than the speed bump: the
-- two-argument form is gone, and the absence of any lock-event record is
-- asserted so that the day Family H lands, the gate fails and forces this
-- carry-forward to be closed rather than quietly outlived.

drop function if exists public.takeover_batch_lock(bigint, text);
drop function if exists app_private.takeover_batch_lock(bigint, text);

-- CDM-32: an ACTIVE takeover does not wait for staleness, and is available only
-- to the Checker at that plant or an administrator. That authority is unchanged.
-- What is gone is the reason parameter, until there is somewhere to put it.
create or replace function app_private.takeover_batch_lock(p_batch bigint)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint; v_plant bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then raise exception 'no active app user' using errcode = '42501'; end if;

  select plant_id into v_plant from public.batches where id = p_batch;
  if v_plant is null then
    raise exception 'unknown Batch' using errcode = '23503';
  end if;
  if not (app_private.has_plant_cap(v_plant,'check_quote')
          or app_private.has_group_cap('administer_users')) then
    raise exception 'only the Checker at that plant or an administrator may take over a lock'
      using errcode = '42501';
  end if;

  -- O-1: the append-only takeover event, with its mandatory reason and the
  -- previous holder, belongs here and does not exist yet (Family H).
  update public.batch_edit_locks
     set holder_user_id = v_me, acquired_at = now(), heartbeat_at = now(), released_at = null
   where batch_id = p_batch
  returning id into v_id;

  if v_id is null then
    raise exception 'that Batch holds no lock to take over' using errcode = '23503';
  end if;
  return v_id;
end $fn$;

create or replace function public.takeover_batch_lock(p_batch bigint)
returns bigint language sql set search_path = '' as $fn$
  select app_private.takeover_batch_lock(p_batch);
$fn$;

do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where p.proname = 'takeover_batch_lock' and n.nspname in ('public','app_private')
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;

-- ------------------------------------------------------------------ gates
do $rw$
declare
  v_def text; v_out text; v_oid oid;
  v_old text := $q$  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
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
    'BL-12a while the Checker with a reason succeeds, without waiting for staleness');$q$;

  v_new text := $q$  -- S6-C3. The reason parameter is gone because nothing stored it, and the
  -- obligation it belonged to is carried forward as O-1 rather than simulated.
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='takeover_batch_lock'
        and pg_catalog.pg_get_function_identity_arguments(p.oid) like '%text%'),
    0, 'BL-11 (S6-C3) takeover no longer accepts a reason it cannot store - the parameter is gone, not silently discarded');
  return next is(
    (select count(*)::int from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relkind='r'
        and c.relname in ('audit_events','batch_lock_events')),
    0, 'BL-11a and no lock-event record exists yet - O-1 is an open Family H obligation, asserted so it cannot be quietly outlived');
  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='batch_edit_locks'
        and column_name in ('takeover_reason','previous_holder_user_id')),
    0, 'BL-11b nor is a lossy reason column hiding on the lock row itself');

  perform pg_catalog.set_config('request.jwt.claims', v_oclaims, true);
  set local role authenticated;
  begin
    perform public.takeover_batch_lock(v_batch);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'BL-12 and a plain Maker cannot take over - it is the Checker''s or an administrator''s act (CDM-32, unchanged)');

  perform pg_catalog.set_config('request.jwt.claims', v_cclaims, true);
  set local role authenticated;
  perform public.takeover_batch_lock(v_batch);
  reset role;
  return next is((select holder_user_id from public.batch_edit_locks where batch_id=v_batch), v_check,
    'BL-12a while the Checker succeeds, without waiting for staleness - the distinction from reclaim survives');$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='batch_locks';
  if v_oid is null then raise exception 'tests.batch_locks() not found' using errcode='55000'; end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def) = 0 then
    raise exception 'the BL-11..BL-12a block was not found verbatim' using errcode='55000';
  end if;
  v_out := replace(v_def, v_old, v_new);
  execute v_out;

  v_def := pg_get_functiondef(v_oid);
  if position('BL-11a and no lock-event record exists yet' in v_def) = 0 then
    raise exception 'the BL-11 replacement did not take' using errcode='55000';
  end if;
end $rw$;
