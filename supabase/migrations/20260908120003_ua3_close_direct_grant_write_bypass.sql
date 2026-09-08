-- ═══════════════════════════════════════════════════════════════════════════
-- UA-3 — close the direct grant-table write bypass.
--
-- Adding an RPC does not create governance while the same caller can still
-- write the tables directly and choose its own attribution. Until now
-- `authenticated` genuinely held INSERT and UPDATE on both grant tables (read
-- from information_schema.role_table_grants, not assumed), and the four write
-- policies permitted exactly that for an administer_users holder, with
-- granted_by / revoked_by supplied by the CLIENT. That is how the current
-- development capability union was created.
--
-- Applied only now that no application caller writes these tables:
--   * server.py::_apply_role_and_plant is deleted;
--   * PATCH /admin/users/<id> refuses role/plant/plants;
--   * the frontend capability editor calls the governed operation.
-- Closing it earlier would have left the application depending on writes that
-- had already been revoked.
--
-- app_private.admin_create_app_user is UNAFFECTED: it is SECURITY DEFINER owned
-- by `postgres`, which holds rolbypassrls, so it bypasses RLS entirely
-- including FORCE. BY-10 below proves that rather than asserting it.
--
-- SELECT policies are deliberately RETAINED: UA-1's capability display and
-- caller-context resolution both read through them.
-- ═══════════════════════════════════════════════════════════════════════════
revoke insert, update on public.group_capability_grants from authenticated;
revoke insert, update on public.plant_capability_grants from authenticated;

drop policy if exists ggrant_insert on public.group_capability_grants;
drop policy if exists ggrant_update on public.group_capability_grants;
drop policy if exists pgrant_insert on public.plant_capability_grants;
drop policy if exists pgrant_update on public.plant_capability_grants;

create or replace function tests.capability_write_bypass_closed()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_admin bigint; v_claims text; v_nag bigint; v_cap bigint; v_new bigint;
begin
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_cap from public.capabilities where capability_key = 'plant_access';

  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__bypass admin', 'active') returning id into v_admin;
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_admin, c.id, v_admin from public.capabilities c
   where c.capability_key = 'administer_users';

  v_claims := format('{"sub":"%s","role":"authenticated"}',
    (select auth_user_id from public.app_users where id = v_admin));
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);

  set local role authenticated;
  begin
    insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
    values (v_admin, v_cap, v_admin);
    reset role;
    return next fail('BY-1 an administrator must NOT be able to insert a group grant directly');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501',
      'BY-1 direct INSERT on group_capability_grants refused 42501 ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
    values (v_admin, v_nag, v_cap, v_admin);
    reset role;
    return next fail('BY-2 an administrator must NOT be able to insert a plant grant directly');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501',
      'BY-2 direct INSERT on plant_capability_grants refused 42501 ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    update public.group_capability_grants set status = 'revoked'
     where app_user_id = v_admin and status = 'active';
    reset role;
    return next fail('BY-3 an administrator must NOT be able to revoke a grant directly');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501',
      'BY-3 direct UPDATE on group_capability_grants refused 42501 ('||sqlstate||')');
  end;

  set local role authenticated;
  begin
    update public.plant_capability_grants set status = 'revoked' where app_user_id = v_admin;
    reset role;
    return next fail('BY-4 an administrator must NOT be able to revoke a plant grant directly');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501',
      'BY-4 direct UPDATE on plant_capability_grants refused 42501 ('||sqlstate||')');
  end;

  return next ok(not has_table_privilege('authenticated', 'public.group_capability_grants', 'insert')
             and not has_table_privilege('authenticated', 'public.group_capability_grants', 'update')
             and not has_table_privilege('authenticated', 'public.plant_capability_grants', 'insert')
             and not has_table_privilege('authenticated', 'public.plant_capability_grants', 'update'),
    'BY-5 authenticated holds no INSERT or UPDATE privilege on either grant table');

  return next ok(not exists (select 1 from pg_policies
                              where schemaname = 'public'
                                and tablename in ('group_capability_grants','plant_capability_grants')
                                and cmd in ('INSERT','UPDATE')),
    'BY-6 no write policy remains on either grant table');

  return next ok(has_table_privilege('authenticated', 'public.group_capability_grants', 'select')
             and has_table_privilege('authenticated', 'public.plant_capability_grants', 'select'),
    'BY-7 READ access is preserved - UA-1 and caller-context resolution still work');

  set local role authenticated;
  begin
    perform 1 from public.group_capability_grants where app_user_id = v_admin;
    reset role;
    return next ok(true, 'BY-8 an administrator can still READ grants through RLS');
  exception when others then
    reset role;
    return next fail('BY-8 read access was broken by the closure ('||sqlstate||')');
  end;

  return next ok((select count(*) from public.group_capability_grants
                   where app_user_id = v_admin and status = 'active') = 1,
    'BY-9 every refused direct write left the data untouched');

  begin
    v_new := app_private.admin_create_app_user(
      tests.__fixture_auth_uid(), '__bypass created', 'maker', array['NAG']);
    return next ok(v_new is not null,
      'BY-10 admin_create_app_user still works after the closure - the definer bypasses RLS');
    return next ok((select count(*) from public.plant_capability_grants
                     where app_user_id = v_new and status = 'active') = 2,
      'BY-10a and it still seeds plant grants (plant_access + make_quote)');
  exception when others then
    return next fail('BY-10 admin_create_app_user broke after the closure ('||sqlstate||': '||sqlerrm||')');
  end;

  set local role authenticated;
  begin
    perform public.set_user_capabilities(
      v_admin,
      (select content_version from public.app_users where id = v_admin),
      array['administer_users','read_party_master'], '{}'::jsonb);
    reset role;
    return next ok(true, 'BY-11 the governed operation is the path that still works');
  exception when others then
    reset role;
    return next fail('BY-11 the governed operation broke after the closure ('||sqlstate||')');
  end;
  return next ok((select count(*) from public.group_capability_grants
                   where app_user_id = v_admin and status = 'active') = 2,
    'BY-11a and it applied the desired set through the closed tables');
end $function$;

revoke all on function tests.capability_write_bypass_closed()
  from public, anon, authenticated, service_role;
