create or replace function tests.email_management()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_auth uuid; v_admin_auth uuid; v_id bigint; v_admin bigint; v_uid uuid;
  v_email text; v_admin_email text; v_claims text; v_admin_claims text; v_cap bigint; v_n int;
begin
  -- EM-1: the login identity is not duplicated into the application table.
  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='app_users' and column_name = 'email'), 0,
    'EM-1 app_users has no email column - email lives only in auth.users');

  return next ok(
    (select not p.prosecdef from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='admin_prepare_email_change'),
    'EM-2 the public email shims are SECURITY INVOKER, not definer');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.proname in ('admin_prepare_email_change','record_email_change','revoke_user_sessions')
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')), 0,
    'EM-3 anon can execute none of the email shims');
  return next ok(
    not pg_catalog.has_table_privilege('authenticated','app_private.email_change_audit','SELECT'),
    'EM-4 authenticated cannot read the email change audit');

  -- an ADMIN identity and an ORDINARY identity, both synthetic
  v_admin_auth  := tests.__fixture_auth_uid();
  v_admin_email := (select u.email from auth.users u where u.id = v_admin_auth);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_admin_email, '__p2_em_admin', true);
  v_admin_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_admin_auth, v_admin_email);
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  v_admin := public.bootstrap_app_user();
  reset role;

  v_auth  := tests.__fixture_auth_uid();
  v_email := (select u.email from auth.users u where u.id = v_auth);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_em_user', false);
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_id := public.bootstrap_app_user();
  reset role;

  -- EM-5: an ordinary caller cannot prepare an administrator email change
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  begin
    set local role authenticated;
    perform public.admin_prepare_email_change(v_admin, 'no reason');
    reset role;
    return next fail('EM-5 an ordinary caller must not prepare an admin email change');
  exception when others then
    reset role;
    return next ok(true, 'EM-5 UNAUTHORIZED caller refused ('||sqlstate||')');
  end;

  -- EM-6: an administrator must supply a reason
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  begin
    set local role authenticated;
    perform public.admin_prepare_email_change(v_id, '   ');
    reset role;
    return next fail('EM-6 an empty administrative reason must be refused');
  exception when others then
    reset role;
    return next ok(true, 'EM-6 an administrative reason is required ('||sqlstate||')');
  end;

  -- EM-7: the target Auth identity is RESOLVED from the app_users row
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  v_uid := public.admin_prepare_email_change(v_id, 'staff address correction');
  reset role;
  return next is(v_uid, v_auth,
    'EM-7 the target Auth identity is resolved from the app_users row, not supplied');

  -- EM-8: an unknown application identity is refused
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  begin
    set local role authenticated;
    perform public.admin_prepare_email_change(-999999, 'nope');
    reset role;
    return next fail('EM-8 an unknown application identity must be refused');
  exception when others then
    reset role;
    return next ok(true, 'EM-8 unknown application identity refused ('||sqlstate||')');
  end;

  -- EM-9/10: audit records domain and fingerprint, never the address
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.record_email_change(v_id, 'admin', 'staff address correction',
                                     'old.person@example.invalid', 'new.person@example.invalid');
  reset role;
  return next ok(
    exists (select 1 from app_private.email_change_audit a
             where a.app_user_id = v_id and a.actor_app_user_id = v_admin
               and a.actor_kind = 'admin' and a.reason = 'staff address correction'
               and a.old_email_domain = 'example.invalid'
               and a.new_email_domain = 'example.invalid'),
    'EM-9 the change is audited with actor, target, kind and reason');
  return next is(
    (select count(*)::int from app_private.email_change_audit a
      where a.app_user_id = v_id
        and (a.old_email_fp like '%old.person%' or a.new_email_fp like '%new.person%'
          or a.old_email_fp like '%@%'          or a.new_email_fp like '%@%')), 0,
    'EM-10 no full address is stored - only a domain and a one-way fingerprint');
  return next ok(
    (select a.old_email_fp <> a.new_email_fp from app_private.email_change_audit a
      where a.app_user_id = v_id order by a.id desc limit 1),
    'EM-11 the fingerprints distinguish the old and new address');

  -- EM-12: a self record may only describe your own identity
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  begin
    set local role authenticated;
    perform public.record_email_change(v_admin, 'self', null, 'a@example.invalid', 'b@example.invalid');
    reset role;
    return next fail('EM-12 a self record must not describe another identity');
  exception when others then
    reset role;
    return next ok(true, 'EM-12 a self record may only describe your own identity ('||sqlstate||')');
  end;

  -- EM-13: an ordinary caller cannot claim to be acting as an administrator
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  begin
    set local role authenticated;
    perform public.record_email_change(v_id, 'admin', 'pretending', 'a@example.invalid', 'b@example.invalid');
    reset role;
    return next fail('EM-13 an ordinary caller must not record an admin change');
  exception when others then
    reset role;
    return next ok(true, 'EM-13 an ordinary caller cannot record an admin change ('||sqlstate||')');
  end;

  -- EM-14/15: session revocation authorization
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  begin
    set local role authenticated;
    perform public.revoke_user_sessions(v_admin);
    reset role;
    return next fail('EM-14 revoking ANOTHER user''s sessions must require administer_users');
  exception when others then
    reset role;
    return next ok(true, 'EM-14 revoking another user''s sessions requires administer_users ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_n := public.revoke_user_sessions(v_id);
  reset role;
  return next ok(v_n >= 0, 'EM-15 a caller may always revoke their OWN sessions');

  -- EM-16: the change touches no grant
  select id into v_cap from public.capabilities where capability_key = 'plant_access';
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_id, p.id, v_cap, v_admin from public.plants p where p.plant_code = 'NAG';
  perform pg_catalog.set_config('request.jwt.claims', v_admin_claims, true);
  set local role authenticated;
  perform public.admin_prepare_email_change(v_id, 'second correction');
  perform public.record_email_change(v_id, 'admin', 'second correction',
                                     'x@example.invalid', 'y@example.invalid');
  reset role;
  return next is((select count(*)::int from public.plant_capability_grants
                   where app_user_id = v_id and status = 'active'), 1,
    'EM-16 an email change alters no plant or capability grant');
  return next is((select count(*)::int from public.app_users where id = v_id), 1,
    'EM-17 and the application identity itself is unchanged');

  delete from app_private.email_change_audit where app_user_id in (v_id, v_admin);
  delete from app_private.pending_invitations where invite_email in (v_email, v_admin_email);
  perform tests.__drop_synthetic_auth(v_auth);
  perform tests.__drop_synthetic_auth(v_admin_auth);
  return;

exception when others then
  reset role;
  delete from app_private.email_change_audit where app_user_id in (v_id, v_admin);
  delete from app_private.pending_invitations where invite_email in (v_email, v_admin_email);
  perform tests.__drop_synthetic_auth(v_auth);
  perform tests.__drop_synthetic_auth(v_admin_auth);
  raise;
end $fn$;

create or replace function tests.plant_master()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_auth uuid; v_email text; v_claims text; v_id bigint; v_grp bigint;
  v_inactive bigint; v_nag bigint; v_pun bigint; v_kol bigint; v_cap bigint; v_ok boolean;
begin
  return next is((select count(*)::int from public.plants where status = 'active'), 3,
    'PM-1 the Plant Master holds exactly the three seeded active plants');
  return next ok(
    (select array_agg(plant_code order by plant_code) from public.plants where status='active')
      = array['KOL','NAG','PUN'],
    'PM-2 and they are NAG, PUN and KOL');
  return next ok(
    (select count(*) from information_schema.columns
      where table_schema='public' and table_name='plants'
        and column_name in ('plant_code','name','status')) = 3,
    'PM-3 the master exposes code, name and status - what the view needs');

  select id into v_grp from public.avadhoot_groups order by id limit 1;
  select id into v_nag from public.plants where plant_code='NAG';
  insert into public.plants (group_id, plant_code, name, timezone, status)
  values (v_grp, 'ZZI', '__p2 pm inactive plant', 'Asia/Kolkata', 'inactive')
  returning id into v_inactive;

  v_auth  := tests.__fixture_auth_uid();
  v_email := (select u.email from auth.users u where u.id = v_auth);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_pm_maker', false);
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_id := public.bootstrap_app_user();
  reset role;

  select id into v_cap from public.capabilities where capability_key = 'plant_access';

  -- PM-4: an INACTIVE plant cannot receive a new assignment, even from a
  -- privileged writer - the trigger is not RLS and does not yield to it.
  begin
    insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
    values (v_id, v_inactive, v_cap, v_id);
    return next fail('PM-4 an inactive plant must not receive a new assignment');
  exception when others then
    return next ok(true, 'PM-4 an INACTIVE plant cannot receive a new assignment ('||sqlstate||')');
  end;

  -- PM-5: arbitrary text is not a plant and cannot become one by being granted
  begin
    insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
    values (v_id, -424242, v_cap, v_id);
    return next fail('PM-5 an unknown plant id must be refused');
  exception when others then
    return next ok(true, 'PM-5 arbitrary/unknown plant references are refused ('||sqlstate||')');
  end;

  -- PM-6..8: multi-plant assignment persists, and removing one keeps the rest
  select id into v_pun from public.plants where plant_code='PUN';
  select id into v_kol from public.plants where plant_code='KOL';
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_id, p.id, c.id, v_id
    from public.plants p cross join public.capabilities c
   where p.plant_code in ('NAG','PUN','KOL')
     and c.capability_key in ('plant_access','make_quote');
  return next is((select count(*)::int from public.plant_capability_grants
                   where app_user_id = v_id and status='active'), 6,
    'PM-6 a three-plant Maker assignment persists as six active grants');

  update public.plant_capability_grants
     set status='revoked', revoked_at=now(), revoked_by=v_id
   where app_user_id = v_id and plant_id = v_pun;
  return next is((select count(*)::int from public.plant_capability_grants
                   where app_user_id = v_id and status='active'), 4,
    'PM-7 removing PUN revokes only PUN''s grants');
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_ok := app_private.has_plant_cap(v_nag,'make_quote') and app_private.has_plant_cap(v_kol,'make_quote');
  reset role;
  return next ok(v_ok, 'PM-8 and NAG and KOL survive untouched');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_ok := app_private.has_plant_cap(v_pun,'make_quote');
  reset role;
  return next ok(not v_ok, 'PM-9 WRONG-PLANT access remains denied after removal');

  -- PM-10: removing an assignment is not deactivating the master
  return next is((select status from public.plants where id = v_pun), 'active',
    'PM-10 removing a user''s assignment leaves the Plant Master active and untouched');

  delete from public.plant_capability_grants where app_user_id = v_id;
  delete from public.plants where id = v_inactive;
  delete from app_private.pending_invitations where invite_email = v_email;
  perform tests.__drop_synthetic_auth(v_auth);
  return;

exception when others then
  reset role;
  delete from public.plant_capability_grants where app_user_id = v_id;
  delete from public.plants where plant_code = 'ZZI';
  delete from app_private.pending_invitations where invite_email = v_email;
  perform tests.__drop_synthetic_auth(v_auth);
  raise;
end $fn$;

revoke all on function tests.email_management() from public, anon, authenticated;
revoke all on function tests.plant_master() from public, anon, authenticated;

create or replace function tests.run_all()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
begin
  perform no_plan();
  perform tests.__sweep_synthetic_auth();
  return query select * from tests.access_model();
  return query select * from tests.function_grants();
  return query select * from tests.definer_placement();
  return query select * from tests.admin_rpcs();
  return query select * from tests.no_legacy_identity_dependency();
  return query select * from tests.deny_by_default();
  return query select * from tests.bootstrap_security();
  return query select * from tests.bootstrap_routing();
  return query select * from tests.continuity_without_profiles();
  return query select * from tests.multi_plant_access();
  return query select * from tests.email_management();
  return query select * from tests.plant_master();
  return query select * from tests.party_masters();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from finish();
end $fn$;

revoke all on function tests.run_all() from public, anon, authenticated;