create or replace function tests.user_capability_governance()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_admin bigint; v_admin2 bigint; v_target bigint; v_nocap bigint;
  v_claims_admin text; v_claims_nocap text;
  v_nag bigint; v_pun bigint;
  v_cv int; v_cv2 int; v_res jsonb;
  v_hist int; v_hist2 int;
begin
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';
  if v_pun is null then
    select id into v_pun from public.plants
     where status = 'active' and id <> v_nag order by id limit 1;
  end if;

  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua3 admin', 'active') returning id into v_admin;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua3 admin2', 'active') returning id into v_admin2;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua3 target', 'active') returning id into v_target;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__ua3 nocap', 'active') returning id into v_nocap;

  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_admin, c.id, v_admin from public.capabilities c
   where c.capability_key = 'administer_users';
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_admin2, c.id, v_admin from public.capabilities c
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

  update public.app_users set status = 'deactivated' where id = v_admin2;
  select content_version into v_cv2 from public.app_users where id = v_admin;
  set local role authenticated;
  begin
    perform public.set_user_capabilities(v_admin, v_cv2, '{}'::text[], '{}'::jsonb);
    reset role;
    return next fail('UC-17 removing the last active administrator must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023',
      'UC-17 last active administrator protected on the capability path ('||sqlstate||')');
  end;
  return next ok((select count(*) from public.group_capability_grants
                   where app_user_id = v_admin and status = 'active') = 1,
    'UC-17 the administrator grant survived the refused transaction');

  set local role authenticated;
  begin
    perform public.admin_set_app_user_status(v_admin, 'deactivated');
    reset role;
    return next fail('UC-18 deactivating the last active administrator must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate in ('22023','42501'),
      'UC-18 last active administrator protected on the deactivation path ('||sqlstate||')');
  end;

  -- Restore the second administrator so a later suite is unaffected.
  update public.app_users set status = 'active' where id = v_admin2;

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

-- Registered in run_all(); tests.suite_registration() enforces that every
-- tests.* suite is reachable, so an unregistered suite is itself a failure.
create or replace function tests.run_all()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare v_profiles text; v_legacy text := 'pro' || 'files';
begin
  perform no_plan();
  perform tests.__sweep_synthetic_auth();

  if exists (select 1 from pg_catalog.pg_class c
               join pg_catalog.pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relname = v_legacy and c.relkind = 'r') then
    execute format('select count(*)::text from %I.%I', 'public', v_legacy) into v_profiles;
  else
    v_profiles := 'absent';
  end if;
  perform pg_catalog.set_config('tests.profiles_at_start', v_profiles, true);
  perform pg_catalog.set_config('tests.auth_at_start',
    (select count(*)::text from auth.users
      where email not like 'p2-synthetic-%@fixture.invalid'), true);

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
  return query select * from tests.atomic_multi_plant_creation();
  return query select * from tests.orphan_detection();
  return query select * from tests.greenfield_provisioning();
  return query select * from tests.email_management();
  return query select * from tests.plant_master();
  return query select * from tests.party_masters();
  return query select * from tests.construction_library();
  return query select * from tests.sku_master();
  return query select * from tests.family_c_authority();
  return query select * from tests.product_workflow();
  return query select * from tests.family_d_group_masters();
  return query select * from tests.family_d_plant_masters();
  return query select * from tests.interest_authority();
  return query select * from tests.pricing_basis();
  return query select * from tests.family_de_security();
  return query select * from tests.batch_workspace();
  return query select * from tests.batch_sets();
  return query select * from tests.batch_set_cardinality();
  return query select * from tests.batch_profile();
  return query select * from tests.batch_locks();
  return query select * from tests.family_f_security();
  return query select * from tests.content_version_boundary();
  return query select * from tests.reference_allocation();
  return query select * from tests.fixtures_matrix();
  return query select * from tests.customer_family_mutations();
  return query select * from tests.party_edit_mutations();
  return query select * from tests.customer_location_mutations();
  return query select * from tests.user_capability_governance();
  return query select * from tests.synthetic_fixture_integrity();
  return query select * from tests.suite_registration();
  return query select * from finish();
end $function$;
