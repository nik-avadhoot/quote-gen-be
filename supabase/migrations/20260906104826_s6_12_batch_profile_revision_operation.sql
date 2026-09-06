-- S6-12 (S6-C2): the Batch Profile becomes editable, atomically.
--
-- WHAT WAS WRONG. §10.7 puts "profile" in S6's scope and §3.5 describes
-- batch_profile_versions as "immutable profile history or append-only change
-- versions; one current pointer". S6-1 built the table correctly and then made
-- the pointer unmovable: SELECT and INSERT grants, a select policy and an insert
-- policy, no UPDATE anywhere, and no operation. create_batch inserts version 1
-- with is_current true, and uk_bpv_one_current is a partial unique index on
-- (batch_id) where is_current - so inserting version 2 as current collides, and
-- demoting version 1 first is impossible because nothing may update the table.
-- The Batch Profile was write-once from the moment the Batch was created. Every
-- CDM-19 Batch-level default was therefore fixed at creation and could never be
-- set at all.
--
-- WHY AN RPC RATHER THAN AN UPDATE POLICY. Moving the pointer is two writes that
-- must not be separable - demote the old, insert the new - and a policy cannot
-- make them one act. Handing `authenticated` UPDATE on is_current would also
-- hand it the ability to demote the current version and stop, leaving a Batch
-- with NO current profile and every inherited value unresolvable. So the table
-- stays append-only to the API, exactly as it is today, and the pointer belongs
-- to one operation - the same shape batch_edit_locks and batch_calculations
-- already use.
--
-- AUTHORITY IS NOT RESTATED. The RPC asks can_write_batch, which is where §7.5
-- already put the answer: the caller holds the active edit lock, the Batch is in
-- an editable state, and they are owner or active collaborator with make_quote,
-- or a Checker while the Batch is submitted (CDM-33). Nothing new is invented,
-- and an inactive caller fails at current_app_user() before that.
--
-- CAS IS THE ESTABLISHED ONE. A profile change is a change to the Batch's
-- calculating content, so it advances batches.content_version, and the caller
-- passes the version it read. The conditional UPDATE is the compare-and-swap:
--
--     update public.batches set status = status
--      where id = p_batch and content_version = p_expected;
--
-- Zero rows means someone else moved first, and the caller must re-read rather
-- than proceed - the same rule reclaim_batch_lock follows, and the reason
-- BL-7/BL-7a describe. `status = status` is deliberate: guard_content_version
-- refuses a caller-set content_version and increments it itself, so the update
-- needs to touch the row without naming the token.
--
-- ATOMICITY IS STRUCTURAL, not sequenced carefully. All three writes are one
-- statement from the caller's side, so a failure anywhere rolls back all of
-- them. Two current versions cannot survive a partial failure because a partial
-- failure cannot survive; and uk_bpv_one_current would refuse them anyway.
-- BP-9 induces a failure inside the operation and proves the Batch still has
-- exactly one current profile, the one it had before.
--
-- 40001 IS THE CONFLICT CODE. serialization_failure is what a lost
-- compare-and-swap is. Carried forward for the API layer: PostgREST maps class
-- 40 to a 500, so the HTTP surface should translate it to 409 when S7 or later
-- exposes this operation through a route. Recorded rather than worked around.

create or replace function app_private.revise_batch_profile(
  p_batch                bigint,
  p_expected_content_version integer,
  p_waste_cbb_pct        numeric default null,
  p_waste_pp_pct         numeric default null,
  p_conv_box_rate        numeric default null,
  p_conv_pp_rate         numeric default null,
  p_margin_box_pct       numeric default null,
  p_margin_pp_pct        numeric default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_n int; v_next int; v_id bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_expected_content_version is null then
    raise exception 'the Batch content version you read must be supplied' using errcode = '22023';
  end if;
  if not app_private.can_write_batch(p_batch) then
    raise exception 'you may not write that Batch - it needs the active edit lock, an editable state and make_quote (or Checker authority while submitted)'
      using errcode = '42501';
  end if;

  -- the compare-and-swap, and the row lock that serialises two revisers
  update public.batches set status = status
   where id = p_batch and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'the Batch changed since you read it (expected content version %) - re-read and retry', p_expected_content_version
      using errcode = '40001';
  end if;

  -- demote first, so the partial unique index is never momentarily violated
  update public.batch_profile_versions
     set is_current = false
   where batch_id = p_batch and is_current;

  select coalesce(max(version_no), 0) + 1 into v_next
    from public.batch_profile_versions where batch_id = p_batch;

  insert into public.batch_profile_versions
    (batch_id, version_no, waste_cbb_pct, waste_pp_pct, conv_box_rate, conv_pp_rate,
     margin_box_pct, margin_pp_pct, is_current, created_by)
  values
    (p_batch, v_next, p_waste_cbb_pct, p_waste_pp_pct, p_conv_box_rate, p_conv_pp_rate,
     p_margin_box_pct, p_margin_pp_pct, true, v_me)
  returning id into v_id;

  return v_id;
end $fn$;

create or replace function public.revise_batch_profile(
  p_batch bigint, p_expected_content_version integer,
  p_waste_cbb_pct numeric default null, p_waste_pp_pct numeric default null,
  p_conv_box_rate numeric default null, p_conv_pp_rate numeric default null,
  p_margin_box_pct numeric default null, p_margin_pp_pct numeric default null)
returns bigint language sql set search_path = '' as $fn$
  select app_private.revise_batch_profile(p_batch, p_expected_content_version,
    p_waste_cbb_pct, p_waste_pp_pct, p_conv_box_rate, p_conv_pp_rate,
    p_margin_box_pct, p_margin_pp_pct);
$fn$;

do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where p.proname = 'revise_batch_profile' and n.nspname in ('public','app_private')
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;
