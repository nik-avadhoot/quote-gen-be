-- UC-17/UC-18 asserted that the fixture administrator was the LAST active
-- administrator. That premise is false against a live database which holds real
-- active administrators, so the invariant was satisfied by those and the
-- fixture's grant was correctly revoked - the function was right, the test was
-- wrong.
--
-- Proving a POPULATION invariant needs the population arranged. That is done
-- inside a plpgsql subtransaction ALWAYS rolled back by a sentinel exception, so
-- no live user row can survive the assertion even if something inside it raises.
-- plpgsql variable assignments are not transactional, so the verdict survives the
-- rollback while the data change does not.

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
      perform public.set_user_capabilities(p_admin, p_cv, '{}'::text[], '{}'::jsonb);
    exception when others then
      v_cap := (sqlstate = '22023');
    end;

    begin
      perform public.admin_set_app_user_status(p_admin, 'deactivated');
    exception when others then
      v_deact := (sqlstate in ('22023','42501'));
    end;

    raise exception using errcode = 'UA999', message = '__ua3_rollback';
  exception when others then
    if sqlerrm <> '__ua3_rollback' then raise; end if;
  end;
end $function$;

create or replace function tests.user_capability_governance()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_admin bigint; v_target bigint; v_nocap bigint;
  v_claims_admin text; v_claims_nocap text;
  v_nag bigint; v_pun bigint;
  v_cv int; v_cv2 int; v_res jsonb;
  v_hist int; v_hist2 int;
  v_live_admins int;
  v_cap boolean; v_deact boolean;
begin
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';
  if v_pun is null then
    select id into v_pun from public.plants
     where status = 'active' and id <> v_nag order by id limit 1;
  end if;

  select count(*) into v_live_admins
    from public.app_users u
    join public.group_capability_grants g on g.app_user_id = u.id and g.status = 'active'
    join public.capabilities c on c.id = g.capability_id
   where u.status = 'active' and c.capability_key = 'administer_users';

  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua3 admin', 'active') returning id into v_admin;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua3 target', 'active') returning id into v_target;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua3 nocap', 'active') returning id into v_nocap;

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
    perform public.set_user_capabilities(v_target, 0, '{}'::text[], '{}'::jsonb);
    reset role;
    return next fail('UC-1 an anonymous caller must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate in ('28000','42501'),
      'UC-1 anonymous caller refused ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims_nocap, true);
  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_target, 0, '{}'::text[], '{}'::jsonb);
    reset role;
    return next fail('UC-2 a caller without administer_users must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'UC-2 non-administrator refused 42501 ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);

  set local role authenticated;
  begin
    perform public.set_user_capabilities(-999999, 0, '{}'::text[], '{}'::jsonb);
    reset role;
    return next fail('UC-3 an unknown target must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = 'P0002', 'UC-3 unknown target refused P0002 ('||sqlstate||')');
  end;

  select content_version into v_cv from public.app_users where id = v_target;

  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_target, v_cv + 5, '{}'::text[], '{}'::jsonb);
    reset role;
    return next fail('UC-4 a stale version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = 'PT409',
      'UC-4 stale version refused PT409, not 40001 ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_target, v_cv, null, '{}'::jsonb);
    reset role;
    return next fail('UC-5 a null group set must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'UC-5 null group set refused 22023 ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_target, v_cv, array['not_a_capability'], '{}'::jsonb);
    reset role;
    return next fail('UC-6 an unknown group capability must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'UC-6 unknown group capability refused ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_target, v_cv, array['make_quote'], '{}'::jsonb);
    reset role;
    return next fail('UC-7 a plant capability in the group set must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'UC-7 scope mismatch (plant key in group set) refused');
  end;

  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_target, v_cv, '{}'::text[],
      jsonb_build_object(v_nag::text, jsonb_build_array('read_party_master')));
    reset role;
    return next fail('UC-8 a group capability in the plant set must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'UC-8 scope mismatch (group key in plant set) refused');
  end;

  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_target, v_cv, '{}'::text[],
      jsonb_build_object('NAG', jsonb_build_array('make_quote')));
    reset role;
    return next fail('UC-9 a non-numeric plant key must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023',
      'UC-9 non-numeric plant key refused 22023, not a bare cast error ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_target, v_cv, '{}'::text[],
      jsonb_build_object(v_nag::text, 'make_quote'));
    reset role;
    return next fail('UC-10 a non-array plant value must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'UC-10 non-array plant value refused ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_target, v_cv, '{}'::text[],
      jsonb_build_object('999999', jsonb_build_array('make_quote')));
    reset role;
    return next fail('UC-11 an unknown plant must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'UC-11 unknown plant refused ('||sqlstate||')');
  end;

  set local role authenticated;
  select public.set_user_capabilities(v_target, v_cv,
           array['read_party_master','manage_customer_master'],
           jsonb_build_object(
             v_nag::text, jsonb_build_array('plant_access','make_quote'),
             v_pun::text, jsonb_build_array('plant_access','check_quote')))
    into v_res;
  reset role;

  return next ok((v_res->>'changed')::boolean, 'UC-12 a real change reports changed=true');
  return next is((v_res->'group_capabilities')::text,
    '["manage_customer_master", "read_party_master"]',
    'UC-12 group capabilities returned, canonically sorted');
  return next ok((v_res->>'content_version')::int = v_cv + 1,
    'UC-12 content_version incremented exactly once');
  return next ok((select count(*) from public.group_capability_grants
                   where app_user_id = v_target and status = 'active') = 2,
    'UC-12 both group grants active');
  return next ok((select count(*) from public.plant_capability_grants
                   where app_user_id = v_target and status = 'active') = 4,
    'UC-12 four plant grants across two plants');

  return next ok((select bool_and(granted_by = v_admin)
                    from public.group_capability_grants
                   where app_user_id = v_target and status = 'active'),
    'UC-13 granted_by is the resolved caller');

  select content_version into v_cv2 from public.app_users where id = v_target;
  select count(*) into v_hist from public.group_capability_grants where app_user_id = v_target;
  select count(*) into v_hist2 from public.plant_capability_grants where app_user_id = v_target;

  set local role authenticated;
  select public.set_user_capabilities(v_target, v_cv2,
           array['manage_customer_master','read_party_master','read_party_master'],
           jsonb_build_object(
             v_pun::text, jsonb_build_array('check_quote','plant_access'),
             v_nag::text, jsonb_build_array('make_quote','plant_access','make_quote')))
    into v_res;
  reset role;

  return next ok(not (v_res->>'changed')::boolean,
    'UC-14 resubmitting the same set (reordered, duplicated) reports changed=false');
  return next ok((v_res->>'content_version')::int = v_cv2,
    'UC-14 no version increment on an idempotent request');
  return next ok((select count(*) from public.group_capability_grants
                   where app_user_id = v_target) = v_hist,
    'UC-14 no group grant-history churn');
  return next ok((select count(*) from public.plant_capability_grants
                   where app_user_id = v_target) = v_hist2,
    'UC-14 no plant grant-history churn');

  select content_version into v_cv2 from public.app_users where id = v_target;
  set local role authenticated;
  select public.set_user_capabilities(v_target, v_cv2, array['read_party_master'],
           jsonb_build_object(
             v_nag::text, jsonb_build_array('plant_access','make_quote'),
             v_pun::text, jsonb_build_array('plant_access','check_quote')))
    into v_res;
  reset role;
  return next ok((select count(*) from public.plant_capability_grants
                   where app_user_id = v_target and status = 'active') = 4,
    'UC-15 plant grants represented in the desired set are preserved, not churned');
  return next ok((select count(*) from public.group_capability_grants
                   where app_user_id = v_target and status = 'active') = 1,
    'UC-15 the dropped group capability was revoked');

  select content_version into v_cv2 from public.app_users where id = v_target;
  set local role authenticated;
  select public.set_user_capabilities(v_target, v_cv2, '{}'::text[], '{}'::jsonb) into v_res;
  reset role;
  return next ok((select count(*) from public.plant_capability_grants
                   where app_user_id = v_target and status = 'active') = 0
              and (select count(*) from public.group_capability_grants
                   where app_user_id = v_target and status = 'active') = 0,
    'UC-16 empty collections clear that dimension');
  return next ok((select bool_and(revoked_by = v_admin) from public.group_capability_grants
                   where app_user_id = v_target and status = 'revoked'),
    'UC-16 revoked_by is the resolved caller');

  select content_version into v_cv2 from public.app_users where id = v_admin;
  set local role authenticated;
  select q.v_cap, q.v_deact into v_cap, v_deact
    from tests.__ua3_last_admin_verdicts(v_admin, v_cv2) q;
  reset role;

  return next ok(v_cap,
    'UC-17 removing the last active administrator is refused 22023 on the capability path');
  return next ok(v_deact,
    'UC-18 deactivating the last active administrator is refused (self-check first, invariant behind it)');
  return next ok((select count(*) from public.group_capability_grants
                   where app_user_id = v_admin and status = 'active') = 1,
    'UC-17 the fixture administrator grant survived the refused transaction');
  return next ok((select count(*) from public.app_users u
                    join public.group_capability_grants g
                      on g.app_user_id = u.id and g.status = 'active'
                    join public.capabilities c on c.id = g.capability_id
                   where u.status = 'active'
                     and c.capability_key = 'administer_users') = v_live_admins + 1,
    'UC-17/18 every pre-existing active administrator was restored - no live user altered');

  select content_version into v_cv2 from public.app_users where id = v_target;
  set local role authenticated;
  perform public.set_user_capabilities(v_target, v_cv2, array['read_party_master'], '{}'::jsonb);
  reset role;
  return next ok(exists (select 1 from pg_locks
                          where locktype = 'advisory' and pid = pg_backend_pid()),
    'UC-19 the administrator-invariant advisory lock is held for the transaction');

  return next ok(not has_function_privilege('service_role',
      'public.set_user_capabilities(bigint, integer, text[], jsonb)', 'execute'),
    'UC-20 service_role holds no EXECUTE on the public wrapper');
  return next ok(not has_function_privilege('anon',
      'public.set_user_capabilities(bigint, integer, text[], jsonb)', 'execute'),
    'UC-20 anon holds no EXECUTE on the public wrapper');
  return next ok(has_function_privilege('authenticated',
      'public.set_user_capabilities(bigint, integer, text[], jsonb)', 'execute'),
    'UC-20 authenticated holds EXECUTE on the public wrapper');
end $function$;
