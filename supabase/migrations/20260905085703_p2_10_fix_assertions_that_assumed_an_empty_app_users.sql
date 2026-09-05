-- P2-10: three assertions broke the moment a real administrator existed. All
-- three were correct-as-written and wrong-as-intended, in the same way B-4 was:
-- they used a GLOBAL count as a proxy for a LOCAL invariant, which only held
-- while the system was empty. The first real bootstrap is not a regression, so
-- the assertions are corrected rather than the behaviour.
--
-- D-1 additionally fired on two functions added in this same migration set.
-- That is the guard working: continuity_without_profiles and
-- synthetic_fixture_integrity both name public.profiles because they exist to
-- make assertions ABOUT it. They are added to the same explicit exclusion list
-- the guard already keeps for itself and for is_admin - named one by one, so
-- the exclusion stays auditable and the tests schema is not blanket-exempted.

create or replace function tests.no_legacy_identity_dependency()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  -- the guard itself, the S3(c) removal target, and the two tests whose subject
  -- IS the table. Everything else naming profiles is a real dependency.
  v_exempt text[] := array['no_legacy_identity_dependency',
                           'is_admin',
                           'continuity_without_profiles',
                           'synthetic_fixture_integrity'];
begin
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('tests','app_private','ref_private','public')
        and p.proname <> all(v_exempt)
        and p.prosrc ilike '%public.profiles%'),
    0, 'D-1 nothing except the removal targets reads public.profiles');

  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('tests','app_private','ref_private','public')
        and p.proname <> all(v_exempt)
        and p.prosrc ilike '%is_admin%'),
    0, 'D-2 nothing calls app_private.is_admin');

  return next is(
    (select count(*)::int from pg_catalog.pg_policy pol
       join pg_catalog.pg_class c on c.oid = pol.polrelid
      where c.relname <> 'profiles'
        and coalesce(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid),'') ilike '%is_admin%'),
    0, 'D-3 no policy outside profiles depends on is_admin');

  return next is(
    (select count(*)::int from pg_catalog.pg_constraint con
       join pg_catalog.pg_class c  on c.oid  = con.conrelid
       join pg_catalog.pg_class rf on rf.oid = con.confrelid
      where con.contype = 'f' and rf.relname = 'profiles' and c.relname <> 'profiles'),
    0, 'D-4 no table has a foreign key to public.profiles');

  return next is(
    (select count(*)::int from pg_catalog.pg_trigger t
       join pg_catalog.pg_class c on c.oid = t.tgrelid
      where not t.tgisinternal and c.relname = 'profiles'
        and t.tgname not in ('profiles_set_updated_at')),
    0, 'D-5 profiles carries only its own known updated_at trigger');
end $fn$;

-- B-5: "no row was created BY THESE ATTEMPTS", not "the table is empty".
create or replace function tests.bootstrap_security()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare v_open_before int; v_open_after int; v_users_before int; v_users_after int;
begin
  select count(*)::int into v_open_before
    from app_private.pending_invitations where consumed_at is null;
  select count(*)::int into v_users_before from public.app_users;

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
  select count(*)::int into v_users_after from public.app_users;

  return next is(v_open_after, v_open_before,
                 'B-4 every outstanding invitation survives all refused attempts');
  return next is(v_users_after, v_users_before,
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

revoke all on function tests.no_legacy_identity_dependency() from public;
revoke all on function tests.no_legacy_identity_dependency() from anon;
revoke all on function tests.no_legacy_identity_dependency() from authenticated;
revoke all on function tests.bootstrap_security() from public;
revoke all on function tests.bootstrap_security() from anon;
revoke all on function tests.bootstrap_security() from authenticated;