-- S6-18: which Family F tables carry a compare-and-swap token, and why the rest
-- do not. Declared rather than left as an omission.
--
-- §3.5 says "every mutable record uses an integer content version (or equivalent
-- compare-and-swap token)". S6 gave one to batches, pricing_groups and
-- batch_rows and to nothing else, and did not say so. Reviewing the three that
-- went without:
--
--   delivery_groups        label, bill-to, ship-to, route_notes, status
--   batch_sets             set_code only - status and the counter are derived by
--                          the database and are not caller-writable at all
--                          (S6-10)
--   batch_set_memberships  role and status
--
-- THE ARGUMENT, and it is a real one rather than a rationalisation.
--
-- 1. CDM-32 allows ONE ACTIVE EDITOR. can_write_batch requires the caller to
--    hold the edit lock, so two callers cannot be writing the same Batch's
--    children concurrently in the first place. Within a Batch, compare-and-swap
--    is a second line of defence, not the primary one - and the three tables
--    that DO carry a token are the ones where it earns its place, because they
--    are the calculating levels a Send has to pin.
--
-- 2. §4.6 makes delivery_groups presentation only (A-14, CDM-16). The one way a
--    Delivery Group reaches calculation is as a Pricing Group's freight basis,
--    and that reference lives on pricing_groups, WHICH HAS a token. Clearing the
--    basis location is caught by the resolver, which blocks rather than falling
--    back silently (CDM-17).
--
-- 3. batch_sets and batch_set_memberships cannot be raced into an inconsistent
--    state even in principle: the counter and the status are recomputed from the
--    membership rows by trigger on every write (S6-10), so whatever order two
--    writers interleave in, the stored state equals reality afterwards. A token
--    would guard a value that is not stored from the caller anyway.
--
-- WHAT OWNS THE REMAINING RISK. The residual case is two editors of the SAME
-- Batch, which CDM-40 defers as "multiple simultaneous Batch editors". If that
-- deferral is ever lifted, these three tables need tokens, and this gate is
-- where that will be noticed.
--
-- S8 OWNS THE OTHER HALF. The presentation fingerprint (§10.4) is the mechanism
-- that will detect a descriptive change to a Delivery Group and require a fresh
-- Send. That is S8's work, not a gap here.

create or replace function tests.content_version_boundary()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_have text[]; v_want text[] := array['batch_rows','batches','pricing_groups'];
begin
  select array_agg(table_name order by table_name) into v_have
    from information_schema.columns
   where table_schema = 'public' and column_name = 'content_version'
     and table_name in ('batches','batch_collaborators','batch_profile_versions',
                        'batch_edit_locks','pricing_groups','delivery_groups',
                        'batch_rows','batch_sets','batch_set_memberships',
                        'batch_calculations');

  return next is(v_have, v_want,
    'CV-1 exactly the three CALCULATING Family F levels carry a compare-and-swap token, and no others (§3.5, declared)');

  -- A-23 restated as a set rather than as one column: the lock table is not on
  -- the list, and cannot be.
  return next ok(not ('batch_edit_locks' = any(v_have)),
    'CV-2 batch_edit_locks is not among them - the heartbeat and the content token are different tables (A-23)');

  -- The guard is on all three, so the token cannot be set by a caller anywhere
  -- it exists.
  return next is(
    (select count(*)::int from pg_catalog.pg_trigger t
       join pg_catalog.pg_class c on c.oid = t.tgrelid
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
       join pg_catalog.pg_proc p on p.oid = t.tgfoid
      where n.nspname='public' and not t.tgisinternal
        and p.proname = 'guard_content_version'
        and c.relname = any(v_want)),
    3, 'CV-3 and every one of them is guarded, so the token always advances and is never the caller''s to set');

  -- The three that go without are the three the argument covers: the caller
  -- cannot write batch_sets status or counter at all, so there is no value there
  -- for a token to protect.
  return next ok(
    not pg_catalog.has_column_privilege('authenticated','public.batch_sets','status','UPDATE')
    and not pg_catalog.has_column_privilege('authenticated','public.batch_sets','active_component_count','UPDATE'),
    'CV-4 batch_sets needs no token because its stateful columns are not caller-writable (S6-10)');
end $fn$;

revoke all on function tests.content_version_boundary() from public, anon, authenticated;

do $rw$
declare v_def text; v_out text; v_oid oid;
  v_old text := $q$  return query select * from tests.family_f_security();$q$;
  v_new text := $q$  return query select * from tests.family_f_security();
  return query select * from tests.content_version_boundary();$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='run_all';
  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def) = 0 then
    raise exception 'the run_all anchor was not found' using errcode='55000';
  end if;
  v_out := replace(v_def, v_old, v_new);
  execute v_out;
  if position('content_version_boundary' in pg_get_functiondef(v_oid)) = 0 then
    raise exception 'registration did not take' using errcode='55000';
  end if;
end $rw$;
