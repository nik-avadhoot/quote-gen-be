-- S4-6: the Family C fixtures must MINT their owner identity, not borrow one.
--
-- FOUND BY G-B, and only by G-B. All four S4 suites opened with
--
--   select id into v_owner from public.app_users order by id limit 1;
--
-- and used that id as `created_by` for the master rows each suite sets up. On the
-- live database two governed identities have always existed, so it always found
-- one and the dependency stayed invisible. Replayed from an empty application
-- state there are none, v_owner came back NULL, and every S4 suite failed at its
-- first fixture insert with 23502 on constructions.created_by.
--
-- This is the exact anti-pattern P2-10 removed from the Phase 2 fixtures:
-- "the fixtures are destructive, and an identity chosen from the population is
-- somebody's". The S4 suites reintroduced it for the owner actor while correctly
-- minting their persona actors. The fix restores the principle rather than
-- papering over the symptom - provisioning an identity inside run_all() would
-- have made the replay pass while leaving the fixtures still borrowing, and on a
-- populated database still attributing throwaway rows to a real administrator.
--
-- What this actor IS: a deliberate second party - the administrator or NPD who
-- owns the shared masters a persona does not own. Several gates depend on it
-- being someone OTHER than the caller (FA-10, FA-13..16 assert that a Maker
-- cannot attribute a row to it), so it cannot simply be replaced by the persona.
--
-- Ownership is proved, not assumed: the identity is minted through the existing
-- synthetic-auth fixture, which refuses to hand back a uuid it cannot prove it
-- created. It is marked '__p2_fixture_owner', so __cleanup_fixtures() and
-- __sweep_synthetic_auth() both already collect it, and SF-1/SF-2 still hold.
-- Idempotent within a run, so all four suites share one owner.

create or replace function tests.__fixture_owner()
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_id bigint; v_auth uuid;
begin
  select a.id into v_id
    from public.app_users a
   where a.display_name = '__p2_fixture_owner'
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  v_auth := tests.__new_synthetic_auth_uid();
  insert into public.app_users (auth_user_id, display_name, status)
  values (v_auth, '__p2_fixture_owner', 'active')
  returning id into v_id;

  if v_id is null then
    raise exception 'fixture owner could not be minted' using errcode = '55000';
  end if;
  return v_id;
end $fn$;

revoke all on function tests.__fixture_owner() from public;
revoke all on function tests.__fixture_owner() from anon;
revoke all on function tests.__fixture_owner() from authenticated;