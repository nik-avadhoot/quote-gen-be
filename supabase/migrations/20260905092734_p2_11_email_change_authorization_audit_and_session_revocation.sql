-- P2-11: email management. Email is the Supabase Auth login identity and is
-- NOT duplicated into app_users - there is deliberately no email column there,
-- and this migration adds none. What lives in the database is authorization,
-- audit and session revocation; the address itself only ever lives in
-- auth.users, and the change is made through Supabase's own Auth API.
--
-- Audit stores a DOMAIN and a one-way fingerprint, never the addresses. That is
-- enough to answer "which account changed, by whom, when, why, and was it the
-- same address" without turning the audit trail into a second copy of everyone's
-- email. sha256 is used rather than md5 because a fingerprint of a low-entropy
-- value is only as good as the hash.

create table if not exists app_private.email_change_audit (
  id                 bigint generated always as identity primary key,
  app_user_id        bigint not null references public.app_users(id) on delete restrict,
  actor_app_user_id  bigint not null references public.app_users(id) on delete restrict,
  actor_kind         text   not null check (actor_kind in ('self','admin')),
  reason             text,
  old_email_domain   text,
  new_email_domain   text,
  old_email_fp       text,
  new_email_fp       text,
  changed_at         timestamptz not null default now(),
  -- an administrator acting on someone else must say why; self-service need not
  constraint ck_email_audit_admin_reason
    check (actor_kind <> 'admin' or coalesce(btrim(reason),'') <> '')
);

create index if not exists ix_email_audit_user  on app_private.email_change_audit(app_user_id);
create index if not exists ix_email_audit_actor on app_private.email_change_audit(actor_app_user_id);

alter table app_private.email_change_audit enable row level security;
alter table app_private.email_change_audit force row level security;
revoke all on app_private.email_change_audit from public, anon, authenticated;

-- Domain and fingerprint only. Kept private so no caller can pass a
-- pre-computed value and poison the trail.
create or replace function app_private.__email_domain(p_email text)
returns text language sql immutable set search_path = '' as $fn$
  select nullif(pg_catalog.split_part(pg_catalog.lower(pg_catalog.btrim(p_email)), '@', 2), '');
$fn$;

create or replace function app_private.__email_fingerprint(p_email text)
returns text language sql immutable set search_path = '' as $fn$
  select case
           when coalesce(pg_catalog.btrim(p_email),'') = '' then null
           else pg_catalog.left(
                  pg_catalog.encode(
                    pg_catalog.sha256(
                      pg_catalog.convert_to(pg_catalog.lower(pg_catalog.btrim(p_email)), 'UTF8')),
                    'hex'), 16)
         end;
$fn$;

-- Authorize an administrator email change and RESOLVE the target Auth identity
-- from the selected app_users row. The backend never supplies an Auth uuid -
-- it passes an application identity and receives the uuid, so an arbitrary or
-- guessed Auth uuid cannot be targeted.
create or replace function app_private.admin_prepare_email_change(
  p_app_user bigint, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_uid uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_group_cap('administer_users') then
    raise exception 'administer_users required' using errcode = '42501';
  end if;
  if coalesce(btrim(p_reason),'') = '' then
    raise exception 'an administrative reason is required' using errcode = '22023';
  end if;

  select auth_user_id into v_uid from public.app_users where id = p_app_user;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;
  if v_uid is null then
    raise exception 'that identity has no authentication account' using errcode = '22023';
  end if;
  return v_uid;
end $fn$;

-- Recorded AFTER the Auth API call succeeds, so the trail never claims a change
-- that did not happen.
create or replace function app_private.record_email_change(
  p_app_user bigint, p_actor_kind text, p_reason text,
  p_old_email text, p_new_email text)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint;
begin
  if (select auth.uid()) is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_actor_kind not in ('self','admin') then
    raise exception 'invalid actor kind' using errcode = '22023';
  end if;
  if p_actor_kind = 'self' and p_app_user <> v_me then
    raise exception 'self-service records may only describe your own identity' using errcode = '42501';
  end if;
  if p_actor_kind = 'admin' and not app_private.has_group_cap('administer_users') then
    raise exception 'administer_users required' using errcode = '42501';
  end if;

  insert into app_private.email_change_audit
    (app_user_id, actor_app_user_id, actor_kind, reason,
     old_email_domain, new_email_domain, old_email_fp, new_email_fp)
  values
    (p_app_user, v_me, p_actor_kind, nullif(btrim(p_reason),''),
     app_private.__email_domain(p_old_email), app_private.__email_domain(p_new_email),
     app_private.__email_fingerprint(p_old_email), app_private.__email_fingerprint(p_new_email))
  returning id into v_id;
  return v_id;
end $fn$;

-- Session revocation for another identity.
--
-- gotrue 2.12.3 exposes auth.admin.sign_out(jwt, scope) only - it revokes BY
-- TOKEN, and an administrator does not hold another user's token. There is no
-- revoke-by-id in the client library, so revocation is done at the only place
-- it actually lives: the refresh tokens and sessions GoTrue stores. This is
-- exactly what a global sign-out does, and it has the same limit - an already
-- issued access token stays valid until it expires, because it is a stateless
-- JWT. Nothing here can revoke that earlier, and no design can.
--
-- This is the one place the programme writes to an auth-managed table. It is
-- scoped to a single resolved user, requires administer_users (or the caller's
-- own identity), and should be replaced the moment Supabase ships revoke-by-id.
create or replace function app_private.revoke_user_sessions(p_app_user bigint)
returns int language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_uid uuid; v_n int;
begin
  if (select auth.uid()) is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_app_user <> v_me and not app_private.has_group_cap('administer_users') then
    raise exception 'administer_users required' using errcode = '42501';
  end if;

  select auth_user_id into v_uid from public.app_users where id = p_app_user;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;
  if v_uid is null then
    return 0;
  end if;

  delete from auth.refresh_tokens where user_id = v_uid::text;
  delete from auth.sessions       where user_id = v_uid;
  get diagnostics v_n = row_count;
  return v_n;
end $fn$;

-- Routing shims: unprivileged, invoker, no decisions - the P2-6 shape.
create or replace function public.admin_prepare_email_change(p_app_user bigint, p_reason text)
returns uuid language sql set search_path = '' as $fn$
  select app_private.admin_prepare_email_change(p_app_user, p_reason);
$fn$;

create or replace function public.record_email_change(
  p_app_user bigint, p_actor_kind text, p_reason text, p_old_email text, p_new_email text)
returns bigint language sql set search_path = '' as $fn$
  select app_private.record_email_change(p_app_user, p_actor_kind, p_reason, p_old_email, p_new_email);
$fn$;

create or replace function public.revoke_user_sessions(p_app_user bigint)
returns int language sql set search_path = '' as $fn$
  select app_private.revoke_user_sessions(p_app_user);
$fn$;

revoke all on function app_private.admin_prepare_email_change(bigint,text) from public, anon;
revoke all on function app_private.record_email_change(bigint,text,text,text,text) from public, anon;
revoke all on function app_private.revoke_user_sessions(bigint) from public, anon;
revoke all on function app_private.__email_domain(text) from public, anon, authenticated;
revoke all on function app_private.__email_fingerprint(text) from public, anon, authenticated;
grant execute on function app_private.admin_prepare_email_change(bigint,text) to authenticated;
grant execute on function app_private.record_email_change(bigint,text,text,text,text) to authenticated;
grant execute on function app_private.revoke_user_sessions(bigint) to authenticated;

revoke all on function public.admin_prepare_email_change(bigint,text) from public, anon;
revoke all on function public.record_email_change(bigint,text,text,text,text) from public, anon;
revoke all on function public.revoke_user_sessions(bigint) from public, anon;
grant execute on function public.admin_prepare_email_change(bigint,text) to authenticated;
grant execute on function public.record_email_change(bigint,text,text,text,text) to authenticated;
grant execute on function public.revoke_user_sessions(bigint) to authenticated;