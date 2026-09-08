-- ═══════════════════════════════════════════════════════════════════════════
-- UA-3 — one governed, atomic capability-replacement operation.
--
-- Before this, NINE of thirteen capabilities could not be granted or revoked by
-- any application workflow. The only path was a direct write to the grant
-- tables by an `authenticated` administrator, choosing its own `granted_by`.
-- server.py::_apply_role_and_plant also issued its revokes and inserts as
-- SEPARATE PostgREST statements, so a part-way failure left a user holding a
-- partially applied capability set.
--
-- This replaces both with a declarative desired-set operation: the caller sends
-- the complete intended capability set and it is applied in one transaction, or
-- not at all.
--
-- LOCK ORDER, ALWAYS, so two concurrent administrator edits cannot deadlock:
--   1. advisory transaction lock on the administrator invariant
--   2. the target app_users row, FOR UPDATE
--   3. that user's grant rows, ordered (capability_id) / (plant_id, capability_id)
--
-- STALE CONFLICTS RAISE PT409, NEVER 40001. 40001 is serialization_failure,
-- which the Data API treats as transient and retries; migration
-- 20260908052900 exists because a deliberate conflict raised as 40001 produced
-- a 1,025,464-retry storm and no response at all. A stale desired set is
-- deterministic: retrying it unchanged can only fail again.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function app_private.set_user_capabilities(
  p_app_user                 bigint,
  p_expected_content_version integer,
  p_group_caps               text[],
  p_plant_caps               jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_me            bigint;
  v_version       integer;
  v_changed       boolean := false;
  v_n             integer;
  v_desired_group bigint[];
  v_pp            bigint[];
  v_pc            bigint[];
  v_result        jsonb;
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

  if p_group_caps is null or p_plant_caps is null then
    raise exception 'group_capabilities and plant_capabilities are both required'
      using errcode = '22023';
  end if;
  if jsonb_typeof(p_plant_caps) <> 'object' then
    raise exception 'plant_capabilities must be a JSON object keyed by plant id'
      using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p_plant_caps) k where k !~ '^[0-9]+$') then
    raise exception 'plant_capabilities keys must be numeric plant ids'
      using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_each(p_plant_caps) e where jsonb_typeof(e.value) <> 'array') then
    raise exception 'each plant_capabilities value must be an array of capability keys'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('administer_users_invariant'));

  select content_version into v_version
    from public.app_users where id = p_app_user for update;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;
  if v_version is distinct from p_expected_content_version then
    raise exception 'this user changed since it was loaded' using errcode = 'PT409';
  end if;

  select coalesce(array_agg(distinct c.id), '{}')
    into v_desired_group
    from unnest(p_group_caps) as k(key)
    join public.capabilities c
      on c.capability_key = k.key and c.scope_kind = 'group';
  select count(distinct k.key) into v_n from unnest(p_group_caps) as k(key);
  if v_n <> coalesce(array_length(v_desired_group, 1), 0) then
    raise exception 'unknown capability, or a plant-scoped capability, in group_capabilities'
      using errcode = '22023';
  end if;

  select coalesce(array_agg(pid order by pid, cid), '{}'),
         coalesce(array_agg(cid order by pid, cid), '{}')
    into v_pp, v_pc
    from (select distinct (e.key)::bigint as pid, c.id as cid
            from jsonb_each(p_plant_caps) e
            cross join lateral jsonb_array_elements_text(e.value) as cap(key)
            join public.capabilities c
              on c.capability_key = cap.key and c.scope_kind = 'plant') q;

  select count(*) into v_n from (
    select distinct (e.key)::bigint as pid, cap.key as ckey
      from jsonb_each(p_plant_caps) e
      cross join lateral jsonb_array_elements_text(e.value) as cap(key)) q;
  if v_n <> coalesce(array_length(v_pp, 1), 0) then
    raise exception 'unknown capability, or a group-scoped capability, in plant_capabilities'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from jsonb_object_keys(p_plant_caps) k
     where not exists (select 1 from public.plants p
                        where p.id = k::bigint and p.status = 'active')) then
    raise exception 'unknown or inactive plant' using errcode = '22023';
  end if;

  perform 1 from public.group_capability_grants
    where app_user_id = p_app_user and status = 'active'
    order by capability_id for update;
  perform 1 from public.plant_capability_grants
    where app_user_id = p_app_user and status = 'active'
    order by plant_id, capability_id for update;

  update public.group_capability_grants
     set status = 'revoked', revoked_at = now(), revoked_by = v_me
   where app_user_id = p_app_user and status = 'active'
     and not (capability_id = any (v_desired_group));
  get diagnostics v_n = row_count;
  if v_n > 0 then v_changed := true; end if;

  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select p_app_user, d.id, v_me
    from unnest(v_desired_group) as d(id)
   where not exists (select 1 from public.group_capability_grants g
                      where g.app_user_id = p_app_user
                        and g.capability_id = d.id and g.status = 'active');
  get diagnostics v_n = row_count;
  if v_n > 0 then v_changed := true; end if;

  update public.plant_capability_grants g
     set status = 'revoked', revoked_at = now(), revoked_by = v_me
   where g.app_user_id = p_app_user and g.status = 'active'
     and not exists (select 1 from unnest(v_pp, v_pc) as d(pid, cid)
                      where d.pid = g.plant_id and d.cid = g.capability_id);
  get diagnostics v_n = row_count;
  if v_n > 0 then v_changed := true; end if;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select p_app_user, d.pid, d.cid, v_me
    from unnest(v_pp, v_pc) as d(pid, cid)
   where not exists (select 1 from public.plant_capability_grants g
                      where g.app_user_id = p_app_user and g.plant_id = d.pid
                        and g.capability_id = d.cid and g.status = 'active');
  get diagnostics v_n = row_count;
  if v_n > 0 then v_changed := true; end if;

  if not exists (
    select 1
      from public.group_capability_grants g
      join public.capabilities c on c.id = g.capability_id
      join public.app_users    u on u.id = g.app_user_id
     where c.capability_key = 'administer_users'
       and g.status = 'active' and u.status = 'active') then
    raise exception 'at least one active administrator must remain'
      using errcode = '22023';
  end if;

  if v_changed then
    update public.app_users
       set content_version = content_version + 1
     where id = p_app_user
    returning content_version into v_version;
  end if;

  select jsonb_build_object(
    'content_version', v_version,
    'changed', v_changed,
    'group_capabilities', coalesce((
      select jsonb_agg(c.capability_key order by c.capability_key)
        from public.group_capability_grants g
        join public.capabilities c on c.id = g.capability_id
       where g.app_user_id = p_app_user and g.status = 'active'), '[]'::jsonb),
    'plant_capabilities', coalesce((
      select jsonb_object_agg(t.pid::text, t.keys)
        from (select g.plant_id as pid,
                     jsonb_agg(c.capability_key order by c.capability_key) as keys
                from public.plant_capability_grants g
                join public.capabilities c on c.id = g.capability_id
               where g.app_user_id = p_app_user and g.status = 'active'
               group by g.plant_id) t), '{}'::jsonb))
  into v_result;

  return v_result;
end $fn$;

-- Public invoker wrapper - the only thing PostgREST can reach.
create or replace function public.set_user_capabilities(
  p_app_user                 bigint,
  p_expected_content_version integer,
  p_group_caps               text[],
  p_plant_caps               jsonb
) returns jsonb
language sql
security invoker
set search_path = ''
as $w$
  select app_private.set_user_capabilities(
    p_app_user, p_expected_content_version, p_group_caps, p_plant_caps);
$w$;

revoke all on function app_private.set_user_capabilities(bigint, integer, text[], jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.set_user_capabilities(bigint, integer, text[], jsonb)
  from public, anon, service_role;
grant execute on function public.set_user_capabilities(bigint, integer, text[], jsonb)
  to authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- The same invariant, on the OTHER path that can remove administration
-- authority. Self-deactivation was already refused; deactivating the LAST
-- administrator was not.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function app_private.admin_set_user_status(p_app_user bigint, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_me bigint;
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
  if p_status not in ('invited','active','deactivated') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  if p_app_user = v_me and p_status <> 'active' then
    raise exception 'you cannot deactivate your own account' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('administer_users_invariant'));

  update public.app_users
     set status          = p_status,
         deactivated_at  = case when p_status = 'deactivated' then now() else null end,
         content_version = content_version + 1
   where id = p_app_user;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1
      from public.group_capability_grants g
      join public.capabilities c on c.id = g.capability_id
      join public.app_users    u on u.id = g.app_user_id
     where c.capability_key = 'administer_users'
       and g.status = 'active' and u.status = 'active') then
    raise exception 'at least one active administrator must remain'
      using errcode = '22023';
  end if;
end $fn$;
