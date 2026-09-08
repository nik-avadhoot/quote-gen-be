-- ═══════════════════════════════════════════════════════════════════════════
-- UA-5 — realign the three live suites that call the status operation.
--
-- This is not cosmetic. A-2 and B-7 both caught `when others` and reported ok
-- WITHOUT asserting the SQLSTATE, so after the previous migration dropped the
-- two-argument signature they would have caught 42883 (undefined_function) and
-- reported "refused without administer_users" - a PASS for a test that was no
-- longer testing anything. Both now pin 42501, which is the refusal they claim
-- to be observing and which cannot be produced by a missing function.
--
-- A-4 pins a signature string, so it moves to the new arity or it silently
-- checks a function that no longer exists.
--
-- tests.__ua3_last_admin_verdicts calls the operation for real and has to pass a
-- version. It passes the administrator's own current version, so the CAS cannot
-- be the thing that refuses; the assertion continues to accept 22023 or 42501
-- for the reason recorded when it was written - the self-deactivation check
-- fires first on this path and the population invariant sits behind it.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function tests.admin_rpcs()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
begin
  perform pg_catalog.set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000902","role":"authenticated"}', true);
  set local role authenticated;
  begin
    perform public.admin_create_app_user(
      '00000000-0000-0000-0000-000000000903'::uuid, 'probe', 'admin', null);
    reset role;
    return next fail('A-1 admin_create_app_user must require administer_users');
  exception when others then
    reset role;
    return next ok(true, 'A-1 admin_create_app_user refused without administer_users ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(1, 0, 'deactivated');
    reset role;
    return next fail('A-2 admin_set_app_user_status must require administer_users');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501',
      'A-2 admin_set_app_user_status refused without administer_users ('||sqlstate||')');
  end;

  return next ok(not pg_catalog.has_function_privilege(
      'anon','public.admin_create_app_user(uuid,text,text,text)','EXECUTE'),
    'A-3 anon cannot execute admin_create_app_user');
  return next ok(not pg_catalog.has_function_privilege(
      'anon','public.admin_set_app_user_status(bigint,integer,text)','EXECUTE'),
    'A-4 anon cannot execute admin_set_app_user_status');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prosecdef
        and coalesce(array_to_string(p.proconfig,','),'') <> 'search_path=""'
        and p.proname <> 'rls_auto_enable'),
    0, 'A-5 every SECURITY DEFINER function exposed in public pins search_path');
end $function$;

create or replace function tests.bootstrap_security()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
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
    perform app_private.admin_set_user_status(1, 0, 'active');
    reset role;
    return next fail('B-7 admin_set_user_status should require administer_users');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501',
      'B-7 admin_set_user_status refused without administer_users ('||sqlstate||')');
  end;
end $function$;

create or replace function tests.__ua3_last_admin_verdicts(
  p_admin bigint, p_cv int, out v_cap boolean, out v_deact boolean)
returns record
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
begin
  v_cap := false;
  v_deact := false;
  begin
    update public.app_users u
       set status = 'deactivated', deactivated_at = now()
     where u.id <> p_admin and u.status = 'active'
       and exists (select 1 from public.group_capability_grants g
                     join public.capabilities c on c.id = g.capability_id
                    where g.app_user_id = u.id and g.status = 'active'
                      and c.capability_key = 'administer_users');

    begin
      set local role authenticated;
      perform public.set_user_capabilities(p_admin, p_cv, '{}'::text[], '{}'::jsonb);
      reset role;
    exception when others then
      reset role;
      v_cap := (sqlstate = '22023');
    end;

    begin
      set local role authenticated;
      perform public.admin_set_app_user_status(p_admin, p_cv, 'deactivated');
      reset role;
    exception when others then
      reset role;
      v_deact := (sqlstate in ('22023','42501'));
    end;

    raise exception using errcode = 'UA999', message = '__ua3_rollback';
  exception when others then
    if sqlerrm <> '__ua3_rollback' then raise; end if;
  end;
end $function$;
