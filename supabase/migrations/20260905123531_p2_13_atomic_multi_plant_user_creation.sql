-- P2-13: creating a user with several plants must be all-or-nothing.
--
-- The previous flow created the identity with the FIRST plant through the RPC
-- and then applied the rest with separate statements, logging a warning if that
-- second step failed. That is a partial-assignment defect wearing a comment: a
-- failure between the two steps left a real, active identity holding some of the
-- requested plant access, and the route still answered 201. An administrator who
-- asked for NAG, PUN and KOL could get a Maker silently limited to NAG.
--
-- The whole set now lands inside ONE function call. PostgREST runs an RPC in a
-- single transaction, so either every grant commits or none does - there is no
-- interval in which a partially granted identity exists to be observed. An
-- inactive or unknown plant anywhere in the list aborts the entire creation
-- rather than being skipped.
--
-- The single-plant signature is kept and delegates here, so nothing that already
-- calls it changes behaviour. The two are distinguished by parameter NAME
-- (p_plant_code vs p_plant_codes), so PostgREST resolves them unambiguously.

create or replace function app_private.admin_create_app_user(
  p_auth_user_id uuid,
  p_display_name text,
  p_role         text default 'maker',
  p_plant_codes  text[] default '{}')
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_id bigint; v_plant bigint; v_cap bigint; v_me bigint; v_code text; v_status text;
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

  if p_role not in ('maker','checker','admin') then
    raise exception 'invalid role' using errcode = '22023';
  end if;
  if coalesce(btrim(p_display_name),'') = '' then
    raise exception 'display_name is required' using errcode = '22023';
  end if;
  if p_auth_user_id is null
     or not exists (select 1 from auth.users u where u.id = p_auth_user_id) then
    raise exception 'unknown authentication account' using errcode = '22023';
  end if;

  -- Validate the WHOLE set before writing anything, so the failure message
  -- names the real problem instead of surfacing as a mid-way constraint error.
  foreach v_code in array coalesce(p_plant_codes, '{}') loop
    select p.status into v_status from public.plants p where p.plant_code = v_code;
    if not found then
      raise exception 'unknown plant' using errcode = '22023';
    end if;
    if v_status <> 'active' then
      raise exception 'plant is not active and cannot receive assignments'
        using errcode = '23514';
    end if;
  end loop;

  insert into public.app_users (auth_user_id, display_name, status)
  values (p_auth_user_id, btrim(p_display_name), 'active')
  returning id into v_id;

  if p_role = 'admin' then
    select id into v_cap from public.capabilities where capability_key = 'administer_users';
    insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
    values (v_id, v_cap, v_me);
  end if;

  foreach v_code in array coalesce(p_plant_codes, '{}') loop
    select id into v_plant from public.plants where plant_code = v_code;
    insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
    select v_id, v_plant, c.id, v_me from public.capabilities c
     where c.capability_key in ('plant_access',
                                case when p_role = 'checker' then 'check_quote' else 'make_quote' end);
  end loop;

  return v_id;
end $fn$;

-- Unchanged entry point for single-plant callers; now a thin delegation so the
-- two paths cannot drift apart.
create or replace function app_private.admin_create_app_user(
  p_auth_user_id uuid,
  p_display_name text,
  p_role         text default 'maker',
  p_plant_code   text default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
begin
  return app_private.admin_create_app_user(
    p_auth_user_id, p_display_name, p_role,
    case when p_plant_code is null then '{}'::text[] else array[p_plant_code] end);
end $fn$;

create or replace function public.admin_create_app_user(
  p_auth_user_id uuid, p_display_name text, p_role text, p_plant_codes text[])
returns bigint language sql set search_path = '' as $fn$
  select app_private.admin_create_app_user(p_auth_user_id, p_display_name, p_role, p_plant_codes);
$fn$;

revoke all on function app_private.admin_create_app_user(uuid,text,text,text[]) from public, anon;
grant execute on function app_private.admin_create_app_user(uuid,text,text,text[]) to authenticated;
revoke all on function public.admin_create_app_user(uuid,text,text,text[]) from public, anon;
grant execute on function public.admin_create_app_user(uuid,text,text,text[]) to authenticated;