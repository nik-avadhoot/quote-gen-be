-- P2-15: greenfield administrator provisioning.
--
-- DEFICIENCY THIS CLOSES. A clean replay of the migration set produces a
-- correct, fully-secured database that NOBODY CAN GET INTO. The first-admin
-- invitation is seeded by 20260904143300, which derives it from
-- `public.profiles` - a legacy table that is itself the S3(c) removal target.
-- So on any genuinely empty deployment that migration legitimately inserts
-- nothing, and the system has no administrator, no invitation, and no route to
-- create either. That is a real greenfield-bootstrap deficiency, not a replay
-- failure, and it must be fixed with a mechanism that does not depend on
-- profiles at all.
--
-- WHY THIS IS NOT A REGISTRATION ROUTE.
--
--   * It lives in `app_private`, which PostgREST cannot route to, and EXECUTE is
--     granted to NOBODY - not anon, not authenticated, not service_role. It is
--     reachable only by a direct privileged database connection (the dashboard
--     or a migration), which is exactly the level of access provisioning the
--     first administrator should require.
--   * It REFUSES once the system has an administrator. The first-admin path is
--     one-shot by construction: it cannot be replayed to mint a second
--     administrator, and it cannot be left switched on by accident because
--     there is no switch - the guard is the state of the system.
--   * Non-admin provisioning is refused UNLESS an administrator already exists,
--     so it can never be used to open a way in on an empty system.
--
-- WHY NO EMAIL OR UUID IS EMBEDDED HERE. The address is a PARAMETER. Nothing
-- identifying is committed to version control; the operator supplies it at the
-- moment of use. That is also what makes the procedure repeatable for a new
-- deployment rather than specific to this one.

create or replace function app_private.provision_pending_invitation(
  p_email        text,
  p_display_name text,
  p_grant_admin  boolean default false)
returns text language plpgsql security definer set search_path = '' as $fn$
declare v_admin_exists boolean; v_email text; v_name text;
begin
  v_email := lower(btrim(coalesce(p_email, '')));
  v_name  := btrim(coalesce(p_display_name, ''));

  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'a valid email address is required' using errcode = '22023';
  end if;
  if v_name = '' then
    raise exception 'a display name is required' using errcode = '22023';
  end if;

  select exists (
    select 1
      from public.group_capability_grants g
      join public.capabilities c on c.id = g.capability_id
      join public.app_users    u on u.id = g.app_user_id
     where c.capability_key = 'administer_users'
       and g.status = 'active' and u.status = 'active')
    into v_admin_exists;

  -- One-shot: the first-administrator path closes the moment one exists.
  if p_grant_admin and v_admin_exists then
    raise exception 'an active administrator already exists - use the administration routes'
      using errcode = '42501';
  end if;

  -- And an ordinary invitation cannot be used to open a way into an empty system.
  if not p_grant_admin and not v_admin_exists then
    raise exception 'no administrator exists yet - provision the first administrator first'
      using errcode = '42501';
  end if;

  if exists (select 1 from public.app_users u
               join auth.users a on a.id = u.auth_user_id
              where lower(a.email) = v_email) then
    raise exception 'that address already has an application identity'
      using errcode = '23505';
  end if;

  if exists (select 1 from app_private.pending_invitations i
              where lower(i.invite_email) = v_email and i.consumed_at is null) then
    return 'unchanged: an open invitation already exists for that address';
  end if;

  delete from app_private.pending_invitations
   where lower(invite_email) = v_email and consumed_at is not null;

  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, v_name, p_grant_admin);

  return case when p_grant_admin
              then 'first-administrator invitation created'
              else 'invitation created' end;
end $fn$;

-- Reachable by no API role at all. Deliberately NOT given a public shim.
revoke all on function app_private.provision_pending_invitation(text,text,boolean)
  from public, anon, authenticated, service_role;