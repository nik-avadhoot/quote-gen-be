-- P2-9 correction: B-4 asserted the wrong invariant.
--
-- It checked `count(open invitations) = 1`, using the literal 1 as a proxy for
-- "the first-admin invitation was not consumed by any refused attempt". That
-- held only while exactly one invitation existed in the whole system. P2-9 adds
-- a second - legacy row 2's Maker invitation - and B-4 failed at 2 against a
-- want of 1, even though nothing was consumed and the property it exists to
-- protect was never violated.
--
-- The real invariant is that the refused attempts consume NOTHING. It is now
-- asserted as a before/after comparison, so it stays true for any number of
-- outstanding invitations and still fails loudly if a refusal ever consumes one.

create or replace function tests.bootstrap_security()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_open_before int; v_open_after int;
begin
  select count(*)::int into v_open_before
    from app_private.pending_invitations where consumed_at is null;

  -- unauthenticated caller is refused
  begin
    perform pg_catalog.set_config('request.jwt.claims', null, true);
    set local role authenticated;
    perform app_private.bootstrap_app_user();
    reset role;
    return next fail('B-1 unauthenticated bootstrap should be refused');
  exception when others then
    reset role;
    return next ok(true, 'B-1 unauthenticated bootstrap refused ('||sqlstate||')');
  end;

  -- authenticated caller with NO matching invitation is refused
  begin
    perform pg_catalog.set_config('request.jwt.claims',
      '{"sub":"00000000-0000-0000-0000-000000000998","role":"authenticated",'
      '"email":"not-invited@example.invalid"}', true);
    set local role authenticated;
    perform app_private.bootstrap_app_user();
    reset role;
    return next fail('B-2 uninvited caller should be refused - no public registration');
  exception when others then
    reset role;
    return next ok(true, 'B-2 uninvited caller refused ('||sqlstate||')');
  end;

  -- knowing the invited DISPLAY NAME must not be enough
  begin
    perform pg_catalog.set_config('request.jwt.claims',
      '{"sub":"00000000-0000-0000-0000-000000000997","role":"authenticated",'
      '"email":"impostor@example.invalid"}', true);
    set local role authenticated;
    perform app_private.bootstrap_app_user();
    reset role;
    return next fail('B-3 impostor knowing the display name should be refused');
  exception when others then
    reset role;
    return next ok(true, 'B-3 impostor refused - invitation is bound to email, not display name');
  end;

  select count(*)::int into v_open_after
    from app_private.pending_invitations where consumed_at is null;

  return next is(v_open_after, v_open_before,
                 'B-4 every outstanding invitation survives all refused attempts');
  return next is((select count(*)::int from public.app_users), 0,
                 'B-5 no app_users row was created by any refused attempt');

  return next ok(not pg_catalog.has_table_privilege(
                   'authenticated','app_private.pending_invitations','SELECT'),
                 'B-6 authenticated cannot read pending_invitations');

  begin
    perform pg_catalog.set_config('request.jwt.claims',
      '{"sub":"00000000-0000-0000-0000-000000000996","role":"authenticated"}', true);
    set local role authenticated;
    perform app_private.admin_set_user_status(1, 'active');
    reset role;
    return next fail('B-7 admin_set_user_status should require administer_users');
  exception when others then
    reset role;
    return next ok(true, 'B-7 admin_set_user_status refused without administer_users');
  end;
end $fn$;

revoke all on function tests.bootstrap_security() from public;
revoke all on function tests.bootstrap_security() from anon;
revoke all on function tests.bootstrap_security() from authenticated;