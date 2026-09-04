-- P2-2: seed edit_lock_stale_seconds with genuine first-admin attribution.
--
-- operational_settings.created_by is NOT NULL and references app_users, so this
-- setting could not be seeded in S1 - no app_user existed. Rather than invent an
-- attribution or leave the setting missing, it is created by the bootstrap itself,
-- at the moment the first administrator exists, attributed to them.
-- CDM-32 value: 900 seconds. A-26: operational settings never enter a Pricing Basis
-- Release or a calculation snapshot.

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
    insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
    values (v_id, v_cap, v_id);

    -- first valid admin attribution for the operational settings baseline
    insert into public.operational_settings
      (scope_type, plant_id, setting_key, setting_value, created_by)
    values ('group', null, 'edit_lock_stale_seconds', to_jsonb(900), v_id)
    on conflict do nothing;
  end if;

  update app_private.pending_invitations
     set consumed_at = now(), consumed_by = v_id
   where id = v_inv.id;

  return v_id;
end $fn$;