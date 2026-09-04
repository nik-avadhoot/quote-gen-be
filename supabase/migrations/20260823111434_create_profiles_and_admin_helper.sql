-- Internal-only schema for security-definer helpers — NOT in the Data API's
-- exposed-schemas list (default is just `public`), so functions here are
-- unreachable via PostgREST/RPC regardless of grants.
create schema if not exists app_private;
grant usage on schema app_private to authenticated;

-- ── profiles ────────────────────────────────────────────────────────────
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role         text not null default 'maker' check (role in ('maker','checker','admin')),
  plant        text,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table public.profiles is
  'App-level user profile: role, display name, plant, active flag. 1:1 with auth.users.id. All writes go through the Flask backend service-role client — no INSERT/DELETE policy exists for authenticated users.';

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;

-- ── is_admin() helper — SECURITY DEFINER to avoid RLS self-recursion ─────
create or replace function app_private.is_admin(uid uuid default auth.uid())
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = uid and role = 'admin' and active = true
  );
$$;

revoke all on function app_private.is_admin(uuid) from public;
grant execute on function app_private.is_admin(uuid) to authenticated;

-- ── RLS policies ───────────────────────────────────────────────────────
create policy "profiles_select_own"
on public.profiles for select to authenticated
using ( id = auth.uid() );

create policy "profiles_select_admin_all"
on public.profiles for select to authenticated
using ( app_private.is_admin() );

create policy "profiles_update_admin_all"
on public.profiles for update to authenticated
using ( app_private.is_admin() )
with check ( app_private.is_admin() );

-- Deliberately NO insert/delete policy for authenticated/anon: every write
-- happens through the Flask backend's service-role client, which bypasses
-- RLS by design. This makes self-registration/self-promotion structurally
-- impossible even if the anon key leaks.

grant select, update on public.profiles to authenticated;
