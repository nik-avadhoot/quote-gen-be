-- S6-17: two lock operations never asked whether the caller may touch the Batch.
--
-- FOUND BY THE HTTP MATRIX, and only by it. The database suites drove the lock
-- lifecycle through personas who all had a legitimate relationship to the Batch,
-- so the missing check never showed. Probing every operation as a Maker at
-- ANOTHER PLANT found two that answered at all:
--
--   POST /rest/v1/rpc/heartbeat_batch_lock  -> 500  55P03 "you do not hold the
--                                             edit lock on that Batch"
--   POST /rest/v1/rpc/release_batch_lock    -> 204  success
--
-- Neither is a breach. heartbeat's UPDATE is filtered by `holder_user_id = me`,
-- so a stranger could never move someone else's heartbeat, and release's UPDATE
-- is filtered the same way, so nothing was released. But both are wrong in the
-- way this programme keeps naming:
--
--   * heartbeat answered an authorisation question with a LOCK error. The caller
--     is told "you do not hold the lock" on a Batch at a plant they hold nothing
--     at - a rule they were never eligible to fail. Every other operation in the
--     family asks about access first: acquire and reclaim call can_read_batch,
--     takeover and create_batch check the plant capability.
--
--   * release reported 204 SUCCESS to a caller with no relationship to the Batch
--     at all. A no-op dressed as success is the exact pattern DS-7, PB-20 and
--     FS-18 exist to catch, and here the API itself was doing it.
--
-- BOTH NOW ASK can_read_batch FIRST, which is where §7.5 already keeps the
-- answer, and raise 42501 when it says no. Nothing else changes.
--
-- RELEASE STAYS IDEMPOTENT FOR AN AUTHORISED CALLER, deliberately. Releasing a
-- lock you no longer hold - because it was reclaimed, or because you already
-- released it - is a cleanup call, and turning that into an error would make
-- every client wrap it in a try. The authorisation hole is closed; the
-- convenience is kept, and it is a choice rather than an oversight.
--
-- CARRY-FORWARD FOR THE API LAYER. PostgREST maps 55P03 to HTTP 500, so an
-- authorised caller who simply does not hold the lock currently gets a server
-- error rather than a 409. That is a routing concern, not a database one, and it
-- joins revise_batch_profile's 40001 as something the HTTP surface should
-- translate when S7 or later exposes these operations through a route.

create or replace function app_private.heartbeat_batch_lock(p_batch bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_n int;
begin
  v_me := app_private.current_app_user();
  if v_me is null then raise exception 'no active app user' using errcode = '42501'; end if;
  -- access first: a caller with no relationship to this Batch must not be told
  -- anything about its lock, including that they do not hold it
  if not app_private.can_read_batch(p_batch) then
    raise exception 'no access to that Batch' using errcode = '42501';
  end if;

  update public.batch_edit_locks
     set heartbeat_at = now()
   where batch_id = p_batch and holder_user_id = v_me and released_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'you do not hold the edit lock on that Batch' using errcode = '55P03';
  end if;
end $fn$;

create or replace function app_private.release_batch_lock(p_batch bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then raise exception 'no active app user' using errcode = '42501'; end if;
  if not app_private.can_read_batch(p_batch) then
    raise exception 'no access to that Batch' using errcode = '42501';
  end if;

  -- idempotent on purpose for a caller who MAY be here: releasing a lock you no
  -- longer hold is cleanup, not an error
  update public.batch_edit_locks
     set released_at = now()
   where batch_id = p_batch and holder_user_id = v_me and released_at is null;
end $fn$;

-- --------------------------------------------------------------- gates
do $rw$
declare
  v_def text; v_out text; v_oid oid;
  v_old text := $q$  return next is(v_state, '42501', 'FS-15a nor revise its profile by knowing its id');$q$;
  v_new text := $q$  return next is(v_state, '42501', 'FS-15a nor revise its profile by knowing its id');

  -- S6-17: every lock operation asks about ACCESS before it says anything about
  -- the lock. Found by the HTTP matrix, where a wrong-plant caller got a lock
  -- error from heartbeat and a 204 SUCCESS from release.
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    perform public.heartbeat_batch_lock(v_batch);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FS-19 a Maker at another plant is refused by heartbeat for ACCESS, not told they do not hold the lock');

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    perform public.release_batch_lock(v_batch);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FS-19a and release refuses them too - it used to report SUCCESS to a caller with no relationship to the Batch');

  perform pg_catalog.set_config('request.jwt.claims', v_xclaims, true);
  set local role authenticated;
  begin
    perform public.heartbeat_batch_lock(v_batch);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'FS-19b as is an unrelated Maker at the SAME plant - plant access is still not Batch access');

  -- an authorised caller who simply does not hold it gets the lock answer, not
  -- the access one, and release stays idempotent for them by design
  perform pg_catalog.set_config('request.jwt.claims', v_kclaims, true);
  set local role authenticated;
  begin
    perform public.release_batch_lock(v_batch);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR',
    'FS-19c while release remains idempotent for a caller who MAY be here - cleanup, not an error');$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='family_f_security';
  if v_oid is null then raise exception 'tests.family_f_security() not found' using errcode='55000'; end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def) = 0 then
    raise exception 'the FS-15a anchor was not found verbatim' using errcode='55000';
  end if;
  v_out := replace(v_def, v_old, v_new);
  execute v_out;

  v_def := pg_get_functiondef(v_oid);
  if position('FS-19c while release remains idempotent' in v_def) = 0 then
    raise exception 'the FS-19 addition did not take' using errcode='55000';
  end if;
end $rw$;
