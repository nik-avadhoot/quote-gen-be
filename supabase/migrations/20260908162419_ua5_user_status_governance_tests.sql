-- ═══════════════════════════════════════════════════════════════════════════
-- UA-5 — the database-layer proof for the status operation.
--
-- US-10 is the check the whole correction exists for: after ONE successful
-- change, the version the caller was holding is refused. That is the lost-update
-- the old two-argument function permitted, demonstrated rather than asserted.
--
-- US-11 proves the unprotected path is GONE, not merely unused. An added
-- function does not create governance while the old signature is still callable
-- by `authenticated` - the same standard UA-3 applied to the grant tables.
--
-- The last-active-administrator invariant on this path is already proved by
-- UC-18 through tests.__ua3_last_admin_verdicts, in a subtransaction that is
-- rolled back, and is deliberately NOT duplicated here.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function tests.user_status_governance()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_admin bigint; v_target bigint; v_nocap bigint;
  v_claims_admin text; v_claims_nocap text;
  v_cv int; v_cv_after int; v_res jsonb; v_deact timestamptz;
begin
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua5 admin', 'active') returning id into v_admin;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua5 target', 'active') returning id into v_target;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua5 nocap', 'active') returning id into v_nocap;

  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_admin, c.id, v_admin from public.capabilities c
   where c.capability_key = 'administer_users';

  v_claims_admin := format('{"sub":"%s","role":"authenticated"}',
    (select auth_user_id from public.app_users where id = v_admin));
  v_claims_nocap := format('{"sub":"%s","role":"authenticated"}',
    (select auth_user_id from public.app_users where id = v_nocap));

  perform pg_catalog.set_config('request.jwt.claims', null, true);
  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(v_target, 0, 'deactivated');
    reset role;
    return next fail('US-1 an anonymous caller must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate in ('28000','42501'),
      'US-1 anonymous caller refused ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims_nocap, true);
  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(v_target, 0, 'deactivated');
    reset role;
    return next fail('US-2 a caller without administer_users must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'US-2 non-administrator refused 42501 ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);

  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(-999999, 0, 'deactivated');
    reset role;
    return next fail('US-3 an unknown target must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = 'P0002', 'US-3 unknown target refused P0002 ('||sqlstate||')');
  end;

  select content_version into v_cv from public.app_users where id = v_target;

  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(v_target, v_cv + 5, 'deactivated');
    reset role;
    return next fail('US-4 a stale version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = 'PT409',
      'US-4 stale version refused PT409, not 40001 ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(v_target, v_cv, 'retired');
    reset role;
    return next fail('US-5 an unknown status must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'US-5 unknown status refused 22023 ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(v_admin,
      (select content_version from public.app_users where id = v_admin), 'deactivated');
    reset role;
    return next fail('US-6 deactivating your own account must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501',
      'US-6 self-deactivation refused 42501 ('||sqlstate||')');
  end;

  set local role authenticated;
  select public.admin_set_app_user_status(v_target, v_cv, 'deactivated') into v_res;
  reset role;

  return next ok((v_res->>'changed')::boolean, 'US-7 a real status change reports changed=true');
  return next ok((v_res->>'content_version')::int = v_cv + 1,
    'US-7 content_version incremented exactly once');
  return next is(v_res->>'status', 'deactivated', 'US-7 the new status is returned');
  return next ok(not (v_res->>'active')::boolean,
    'US-7 active is returned as the derived boolean the client renders');
  return next ok((select status from public.app_users where id = v_target) = 'deactivated',
    'US-7 the row is genuinely deactivated');
  return next ok((select deactivated_at is not null from public.app_users where id = v_target),
    'US-7 deactivated_at is stamped');

  select content_version, deactivated_at into v_cv_after, v_deact
    from public.app_users where id = v_target;

  set local role authenticated;
  select public.admin_set_app_user_status(v_target, v_cv_after, 'deactivated') into v_res;
  reset role;

  return next ok(not (v_res->>'changed')::boolean,
    'US-8 re-submitting the status a user already has reports changed=false');
  return next ok((v_res->>'content_version')::int = v_cv_after,
    'US-8 and does NOT bump the version, so no other administrator is invalidated');
  return next ok((select deactivated_at from public.app_users where id = v_target) = v_deact,
    'US-8 and does not re-stamp deactivated_at');

  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(v_target, v_cv, 'active');
    reset role;
    return next fail('US-10 the version held before the change must no longer be accepted');
  exception when others then
    reset role;
    return next ok(sqlstate = 'PT409',
      'US-10 a second administrator holding the pre-change version is refused PT409 - '
      'the lost update the two-argument function permitted');
  end;

  return next ok((select status from public.app_users where id = v_target) = 'deactivated',
    'US-10 and the refused call changed nothing');

  set local role authenticated;
  select public.admin_set_app_user_status(v_target, v_cv_after, 'active') into v_res;
  reset role;

  return next ok((v_res->>'changed')::boolean and (v_res->>'active')::boolean,
    'US-9 reactivation succeeds with the current version');
  return next ok((select deactivated_at is null from public.app_users where id = v_target),
    'US-9 reactivation clears deactivated_at');

  return next ok(not exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'admin_set_app_user_status'
       and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_app_user bigint, p_status text'),
    'US-11 the unprotected two-argument public wrapper no longer exists');
  return next ok(not exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app_private' and p.proname = 'admin_set_user_status'
       and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_app_user bigint, p_status text'),
    'US-11 nor the unprotected two-argument definer behind it');

  return next ok(not has_function_privilege('anon',
      'public.admin_set_app_user_status(bigint, integer, text)', 'execute'),
    'US-12 anon holds no EXECUTE on the status wrapper');
  return next ok(not has_function_privilege('service_role',
      'public.admin_set_app_user_status(bigint, integer, text)', 'execute'),
    'US-12 service_role holds no EXECUTE either - it cannot resolve a caller');
  return next ok(has_function_privilege('authenticated',
      'public.admin_set_app_user_status(bigint, integer, text)', 'execute'),
    'US-12 authenticated holds EXECUTE on the status wrapper');

  return next ok(exists (select 1 from pg_locks
                          where locktype = 'advisory' and pid = pg_backend_pid()),
    'US-13 the administrator-invariant advisory lock is held for the transaction');
end $function$;

revoke all on function tests.user_status_governance()
  from public, anon, authenticated, service_role;
