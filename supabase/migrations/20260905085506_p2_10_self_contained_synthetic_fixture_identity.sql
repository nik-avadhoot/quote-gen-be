-- P2-10: the fixtures own their authentication identity outright.
--
-- Until now tests.__fixture_auth_uid() SELECTED an existing auth.users row -
-- first by age, then (after P2-8) by availability. Both are wrong for the same
-- reason: the fixtures are destructive, and an identity chosen from the
-- population is somebody's. Age picked the real administrator; availability
-- merely deferred the collision and made the suite fail once every account was
-- in use, which is a failure mode invented by the fixture rather than by the
-- system under test.
--
-- The fixture now MINTS its own identity, uniquely marked, and can prove it
-- owns it. It never reads, ranks or selects an existing account, so there is no
-- ordering, no availability and nothing to collide with. A permanent "free"
-- account is not required and must not be created.
--
-- Fail-closed is the point of the ownership re-read: if the row it just wrote
-- is not there, or does not carry the marker, the fixture raises instead of
-- returning a uuid that might belong to someone.

create or replace function tests.__new_synthetic_auth_uid()
returns uuid language plpgsql security definer set search_path = '' as $fn$
declare v_id uuid; v_email text;
begin
  v_id    := pg_catalog.gen_random_uuid();
  v_email := 'p2-synthetic-' || pg_catalog.replace(v_id::text, '-', '') || '@fixture.invalid';

  insert into auth.users (id, email, is_sso_user, is_anonymous)
  values (v_id, v_email, false, false);

  -- Ownership proof. Nothing downstream may use this uuid unless the row we
  -- just created is present AND carries the synthetic marker.
  if not exists (
        select 1 from auth.users u
         where u.id = v_id
           and u.email = v_email
           and u.email like 'p2-synthetic-%@fixture.invalid') then
    raise exception 'fixture could not prove ownership of its synthetic auth identity - refusing to proceed'
      using errcode = '55000';
  end if;

  return v_id;
end $fn$;

-- Removal is marker-gated in both directions: it refuses a uuid that is not
-- synthetic, so a mistyped or stale variable can never delete a real account.
create or replace function tests.__drop_synthetic_auth(p_uid uuid)
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  if p_uid is null then
    return;
  end if;
  if not exists (select 1 from auth.users u
                  where u.id = p_uid
                    and u.email like 'p2-synthetic-%@fixture.invalid') then
    raise exception 'refusing to remove an auth identity that is not a synthetic fixture identity'
      using errcode = '55000';
  end if;
  delete from public.operational_settings
   where created_by in (select id from public.app_users where auth_user_id = p_uid);
  delete from public.group_capability_grants
   where app_user_id in (select id from public.app_users where auth_user_id = p_uid);
  delete from public.plant_capability_grants
   where app_user_id in (select id from public.app_users where auth_user_id = p_uid);
  delete from public.app_users where auth_user_id = p_uid;
  delete from auth.users where id = p_uid;
end $fn$;

-- Belt and braces: a sweep that can only ever see marker-matching rows, so an
-- aborted run leaves nothing behind even if its own handler did not fire.
create or replace function tests.__sweep_synthetic_auth()
returns int language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
  delete from public.operational_settings
   where created_by in (select a.id from public.app_users a join auth.users u on u.id = a.auth_user_id
                         where u.email like 'p2-synthetic-%@fixture.invalid');
  delete from public.group_capability_grants
   where app_user_id in (select a.id from public.app_users a join auth.users u on u.id = a.auth_user_id
                          where u.email like 'p2-synthetic-%@fixture.invalid');
  delete from public.plant_capability_grants
   where app_user_id in (select a.id from public.app_users a join auth.users u on u.id = a.auth_user_id
                          where u.email like 'p2-synthetic-%@fixture.invalid');
  delete from public.app_users
   where auth_user_id in (select id from auth.users where email like 'p2-synthetic-%@fixture.invalid');
  delete from auth.users where email like 'p2-synthetic-%@fixture.invalid';
  get diagnostics v_n = row_count;
  return v_n;
end $fn$;

-- Every existing caller goes through this name; it now mints instead of selects.
create or replace function tests.__fixture_auth_uid()
returns uuid language plpgsql security definer set search_path = '' as $fn$
begin
  return tests.__new_synthetic_auth_uid();
end $fn$;

revoke all on function tests.__new_synthetic_auth_uid() from public;
revoke all on function tests.__new_synthetic_auth_uid() from anon;
revoke all on function tests.__new_synthetic_auth_uid() from authenticated;
revoke all on function tests.__drop_synthetic_auth(uuid) from public;
revoke all on function tests.__drop_synthetic_auth(uuid) from anon;
revoke all on function tests.__drop_synthetic_auth(uuid) from authenticated;
revoke all on function tests.__sweep_synthetic_auth() from public;
revoke all on function tests.__sweep_synthetic_auth() from anon;
revoke all on function tests.__sweep_synthetic_auth() from authenticated;
revoke all on function tests.__fixture_auth_uid() from public;
revoke all on function tests.__fixture_auth_uid() from anon;
revoke all on function tests.__fixture_auth_uid() from authenticated;