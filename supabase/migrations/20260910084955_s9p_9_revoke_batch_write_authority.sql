-- S9-P/9: remove every direct write path to public.batches (D-T).
--
-- WHAT THIS CORRECTS. S9-P added three governed pricing fields to `batches` and
-- a governed operation to maintain them, then left the pre-existing S6
-- table-level INSERT/UPDATE grant in place. RLS proved the caller could write
-- THAT BATCH; it said nothing about WHICH COLUMNS or WHAT VALUES. Demonstrated
-- as a lock-holding Maker, direct UPDATE could select a draft Release, a
-- withdrawn Release, an approved Release a month before it took effect, flip
-- pricing_basis_is_deliberate on its own, and write an arbitrary Pricing Date -
-- five bypasses of the operation built to prevent exactly those states.
--
-- WHY REVOCATION RATHER THAN A COLUMN-LEVEL GRANT. Enumerating the twelve
-- pre-existing columns would have preserved direct `working -> sent` status
-- mutation, which bypasses the Atomic Send operation assigned to S9(b); and it
-- would have preserved direct mutation of ownership, family, plant, identifiers,
-- timestamps and the content-version token on nothing stronger than the fact
-- that S6 granted them historically. Neither is established as legitimate. The
-- evidence is that NO production path uses this grant at all: the only
-- `update public.batches set` in the entire migration set is `status = status`
-- inside app_private.revise_batch_profile, which is SECURITY DEFINER and runs as
-- postgres, and every other Batch mutation is likewise a DEFINER RPC.
--
-- WHAT SURVIVES. `authenticated` keeps SELECT and the batches_select policy, so
-- Batch visibility is unchanged and still row-scoped by can_read_batch. Every
-- governed mutation - create_batch, revise_batch_profile, the lock RPCs and
-- set_batch_pricing_basis - is SECURITY DEFINER and unaffected by what
-- `authenticated` may do directly.
--
-- THE POLICIES GO WITH THE GRANT. batches_insert and batches_update become
-- unreachable the moment the privilege is gone: a policy gates a privilege, and
-- a policy with no privilege behind it is dead code that reads like a control.
-- Dropping them keeps the access model honest. No gate pins either policy -
-- verified: the only mention in the migration set is the S6-1 line that creates
-- them.
--
-- FOLLOW-UP DEBT, RECORDED NOT PURSUED. Before this migration, a direct
-- authenticated INSERT into batches was already refused 42501 "new row violates
-- row-level security policy" even though every batches_insert WITH CHECK
-- conjunct evaluated true in the same role and transaction, with no restrictive
-- policies present. The cause was never determined. It is moot once INSERT
-- authority is explicitly absent, and it is NOT expanded into an S6 audit here.

revoke insert, update on public.batches from authenticated;

-- Column-level authority is revoked explicitly as well. There is none today, so
-- this changes nothing now; it exists so that the absence is STATED rather than
-- assumed. It does NOT prevent a future column-scoped grant. A revoke is a
-- one-time act, not a standing rule: nothing stops a later migration granting
-- insert(col) or update(col) back, and this line would not notice. What CATCHES
-- that is the regression gate CP-96b, which asserts on every run that no live
-- batches column confers EFFECTIVE insert or update authority on authenticated.
do $$
declare c text;
begin
  for c in select a.attname
             from pg_catalog.pg_attribute a
            where a.attrelid = 'public.batches'::regclass
              and a.attnum > 0 and not a.attisdropped
  loop
    execute format('revoke insert(%I), update(%I) on public.batches from authenticated', c, c);
  end loop;
end $$;

drop policy batches_insert on public.batches;
drop policy batches_update on public.batches;