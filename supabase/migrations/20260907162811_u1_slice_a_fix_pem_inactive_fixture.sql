-- Fix: tests.party_edit_mutations()'s inactive fixture violated
-- ck_app_users_deactivated (status='deactivated' requires deactivated_at
-- not null) - insert both columns together instead of status alone.

create or replace function tests.party_edit_mutations()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_admin bigint; v_nocap bigint; v_inactive bigint;
  v_claims_admin text; v_claims_nocap text; v_claims_inactive text;
  v_party bigint; v_cv int;
begin
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1pe admin', 'active') returning id into v_admin;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1pe nocap', 'active') returning id into v_nocap;
  insert into public.app_users (auth_user_id, display_name, status, deactivated_at)
  values (tests.__fixture_auth_uid(), '__u1pe inactive', 'deactivated', now()) returning id into v_inactive;

  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_admin, c.id, v_admin from public.capabilities c where c.capability_key = 'manage_customer_master';
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_inactive, c.id, v_admin from public.capabilities c where c.capability_key = 'manage_customer_master';

  v_claims_admin    := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_admin));
  v_claims_nocap    := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_nocap));
  v_claims_inactive := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_inactive));

  insert into public.parties (display_name, lifecycle_state, status, created_by)
  values ('__u1pe original name', 'prospect', 'proposed', v_admin) returning id into v_party;

  -- ── PEM-1 unauthenticated caller ──────────────────────────────────────────
  perform pg_catalog.set_config('request.jwt.claims', null, true);
  set local role authenticated;
  begin
    perform app_private.update_party(v_party, 1, '__u1pe should not apply');
    reset role;
    return next fail('PEM-1 an anonymous caller must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'PEM-1 anonymous caller refused 42501 ('||sqlstate||')');
  end;

  -- ── PEM-2 authenticated, no capability at all ────────────────────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_nocap, true);
  set local role authenticated;
  begin
    perform app_private.update_party(v_party, 1, '__u1pe should not apply');
    reset role;
    return next fail('PEM-2 a caller with no grant at all must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'PEM-2 no-capability caller refused 42501 ('||sqlstate||')');
  end;

  -- ── PEM-3 a deactivated manage_customer_master holder ────────────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_inactive, true);
  set local role authenticated;
  begin
    perform app_private.update_party(v_party, 1, '__u1pe should not apply');
    reset role;
    return next fail('PEM-3 a deactivated caller must be refused despite holding the grant');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'PEM-3 deactivated caller refused 42501 ('||sqlstate||')');
  end;

  -- ── PEM-4 blank display_name ──────────────────────────────────────────────
  select content_version into v_cv from public.parties where id = v_party;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.update_party(v_party, v_cv, '   ');
    reset role;
    return next fail('PEM-4 a blank display_name must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'PEM-4 blank display_name refused 22023 ('||sqlstate||')');
  end;

  -- ── PEM-5 missing expected_content_version ───────────────────────────────
  set local role authenticated;
  begin
    perform app_private.update_party(v_party, null, '__u1pe renamed');
    reset role;
    return next fail('PEM-5 a missing expected_content_version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'PEM-5 missing content version refused 22023 ('||sqlstate||')');
  end;

  -- ── PEM-6 not found ───────────────────────────────────────────────────────
  set local role authenticated;
  begin
    perform app_private.update_party(-999999, 1, '__u1pe renamed');
    reset role;
    return next fail('PEM-6 a nonexistent Party must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = 'P0002', 'PEM-6 not-found refused P0002 ('||sqlstate||')');
  end;

  -- ── PEM-7 stale content_version ───────────────────────────────────────────
  set local role authenticated;
  begin
    perform app_private.update_party(v_party, v_cv - 1, '__u1pe renamed wrong');
    reset role;
    return next fail('PEM-7 a stale expected version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'PEM-7 stale content_version refused 40001 ('||sqlstate||')');
  end;

  -- ── PEM-8 the correct expected version succeeds, bumping content_version ──
  set local role authenticated;
  perform app_private.update_party(v_party, v_cv, '__u1pe renamed right');
  reset role;
  return next is((select display_name from public.parties where id = v_party), '__u1pe renamed right',
                 'PEM-8 the correct expected version succeeds');
  return next is((select content_version from public.parties where id = v_party), v_cv + 1,
                 'PEM-8a content_version incremented by exactly 1');

  -- ── PEM-9 the now-stale ORIGINAL version is refused a second time ────────
  set local role authenticated;
  begin
    perform app_private.update_party(v_party, v_cv, '__u1pe renamed again');
    reset role;
    return next fail('PEM-9 the now-stale original version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'PEM-9 now-stale original version refused 40001 - proves the bump ('||sqlstate||')');
  end;

  -- ── PEM-10/11 grant posture on the new public wrapper ────────────────────
  return next ok(
    not pg_catalog.has_function_privilege('anon',
      (select oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
        where n2.nspname='public' and p2.proname='update_customer_party' limit 1), 'EXECUTE')
    and not pg_catalog.has_function_privilege('service_role',
      (select oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
        where n2.nspname='public' and p2.proname='update_customer_party' limit 1), 'EXECUTE'),
    'PEM-10 update_customer_party is executable by neither anon nor service_role');
  return next ok(
    pg_catalog.has_function_privilege('authenticated',
      (select oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
        where n2.nspname='public' and p2.proname='update_customer_party' limit 1), 'EXECUTE'),
    'PEM-11 update_customer_party is executable by authenticated');

  -- ── cleanup ────────────────────────────────────────────────────────────────
  delete from public.parties where display_name like '\_\_u1pe%';
  delete from public.group_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1pe%');
  delete from public.app_users where display_name like '\_\_u1pe%';
  return;

exception when others then
  delete from public.parties where display_name like '\_\_u1pe%';
  delete from public.group_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1pe%');
  delete from public.app_users where display_name like '\_\_u1pe%';
  raise;
end $function$;
