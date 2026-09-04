-- P2-2: caller identity, privileged RPCs, and the one-time first-admin bootstrap.
--
-- DEFECT CORRECTED FROM THE S1 PACKET. The packet's P-2 claimed a pre-created
-- invited app_users row by matching display_name. That is privilege escalation:
-- any authenticated caller could pass the administrator's display name and claim
-- their row. Invitations are therefore bound to the invited EMAIL and matched
-- against the caller's own verified JWT claim.
--
-- Invitations live in app_private, not on app_users, because CDM/DM-181 keeps the
-- permanent user identity separate from login details. app_users still never
-- stores an email.

create table app_private.pending_invitations (
  id             bigint generated always as identity primary key,
  invite_email   text        not null,
  display_name   text        not null,
  grant_admin    boolean     not null default false,
  created_at     timestamptz not null default now(),
  consumed_at    timestamptz null,
  consumed_by    bigint      null,
  constraint uk_invite_email unique (invite_email),
  constraint fk_invite_consumed_by foreign key (consumed_by)
    references public.app_users(id) on delete restrict,
  constraint ck_invite_consumed check ((consumed_at is null) = (consumed_by is null))
);
revoke all on app_private.pending_invitations from public;
revoke all on app_private.pending_invitations from anon, authenticated;

-- P-2: claim an invitation. The ONLY route by which an app_users row becomes active.
-- There is no public registration path: an unmatched caller is refused.
create or replace function app_private.bootstrap_app_user()
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid   uuid := (select auth.uid());
  v_email text := (select auth.jwt() ->> 'email');
  v_inv   app_private.pending_invitations%rowtype;
  v_id    bigint;
  v_cap   bigint;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  -- already bootstrapped: idempotent, returns the existing identity
  select id into v_id from public.app_users where auth_user_id = v_uid;
  if v_id is not null then
    return v_id;
  end if;

  if v_email is null then
    raise exception 'no verified email claim' using errcode = '42501';
  end if;

  select * into v_inv
    from app_private.pending_invitations
   where lower(invite_email) = lower(v_email)
     and consumed_at is null
   for update;

  if v_inv.id is null then
    raise exception 'no pending invitation for this identity' using errcode = '42501';
  end if;

  insert into public.app_users (auth_user_id, display_name, status)
  values (v_uid, v_inv.display_name, 'active')
  returning id into v_id;

  if v_inv.grant_admin then
    select id into v_cap from public.capabilities where capability_key = 'administer_users';
    -- the first administrator has no prior granter; the self-grant is deliberate,
    -- recorded, and the only bootstrap path
    insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
    values (v_id, v_cap, v_id);
  end if;

  update app_private.pending_invitations
     set consumed_at = now(), consumed_by = v_id
   where id = v_inv.id;

  return v_id;
end $fn$;

-- P-3: administrative status change. Never a table UPDATE policy, so the capability
-- check lives in one reviewed place.
create or replace function app_private.admin_set_user_status(p_user bigint, p_status text)
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  if not app_private.has_group_cap('administer_users') then
    raise exception 'administer_users required' using errcode = '42501';
  end if;
  if p_status not in ('invited','active','deactivated') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  update public.app_users
     set status          = p_status,
         deactivated_at  = case when p_status = 'deactivated' then now() else null end,
         content_version = content_version + 1
   where id = p_user;
end $fn$;

-- P-5: reference allocation inside the caller's transaction.
create or replace function ref_private.allocate_reference(
  p_scope_type text, p_scope_key bigint, p_fy text)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v bigint;
begin
  if (select app_private.current_app_user()) is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  insert into ref_private.reference_sequences (scope_type, scope_key, fy_label, next_value)
  values (p_scope_type, p_scope_key, p_fy, 1)
  on conflict (scope_type, scope_key, fy_label) do nothing;

  update ref_private.reference_sequences
     set next_value = next_value + 1
   where scope_type = p_scope_type
     and scope_key  = p_scope_key
     and fy_label is not distinct from p_fy
  returning next_value - 1 into v;
  return v;
end $fn$;

do $$
declare f text;
begin
  foreach f in array array['app_private.bootstrap_app_user()',
                           'app_private.admin_set_user_status(bigint,text)',
                           'ref_private.allocate_reference(text,bigint,text)']
  loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant  execute on function %s to authenticated', f);
  end loop;
end $$;

-- Seed the first-administrator invitation from existing evidence: the single
-- legacy profile carrying role='admin'. No identifier is hardcoded here.
-- On a fresh replay where that user does not exist, this inserts nothing and the
-- migration still succeeds - a fresh environment issues its own invitation.
insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
select u.email, p.display_name, true
  from public.profiles p
  join auth.users u on u.id = p.id
 where p.role = 'admin' and p.active
   and u.email is not null
on conflict (invite_email) do nothing;