-- P2-2: regression tests for the bootstrap. These pin the escalation boundary that
-- the packet's original display_name matching would have left open.

create or replace function tests.bootstrap_security()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_err text;
begin
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

  -- knowing the invited DISPLAY NAME must not be enough: the packet's original
  -- design would have allowed exactly this
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

  -- the invitation is still unconsumed and no identity was created
  return next is((select count(*)::int from app_private.pending_invitations
                   where consumed_at is null), 1,
                 'B-4 the first-admin invitation survives all refused attempts');
  return next is((select count(*)::int from public.app_users), 0,
                 'B-5 no app_users row was created by any refused attempt');

  -- clients cannot read or write the invitation table directly
  return next ok(not pg_catalog.has_table_privilege(
                   'authenticated','app_private.pending_invitations','SELECT'),
                 'B-6 authenticated cannot read pending_invitations');

  -- admin RPC refuses a caller without the capability
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

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  return query select * from tests.access_model();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from finish();
end $fn$;