-- S6-4: the edit-lock lifecycle, Batch creation, and the content_version guard.
--
-- A-23 AND A-24, made structural. The heartbeat writes heartbeat_at on a table
-- that has no content_version column at all, so "heartbeat does not advance
-- content_version" is not a discipline anyone could forget - the two values live
-- in different tables. Staleness is computed server-side from
-- now() - heartbeat_at against operational_settings.edit_lock_stale_seconds, so
-- a skewed client clock cannot make a live lock look stale or the reverse.
--
-- RECLAIM IS ONE CONDITIONAL STATEMENT (§4.6). Two racing reclaims cannot both
-- win, because the first changes holder_user_id and the second's
-- `holder_user_id = expected` no longer matches. Zero rows returned means the
-- caller lost and must not proceed - so the function raises rather than
-- returning quietly, since a silent no-op is exactly how a lost race turns into
-- two editors.
--
-- CONTENT_VERSION, and an honest account of what it does and does not do. The
-- trigger below refuses any client attempt to set content_version to something
-- other than its stored value, and increments it on every update. That makes the
-- token trustworthy: it always moves forward, and it cannot be frozen or rewound
-- to defeat a comparison.
--
-- What the trigger CANNOT do is distinguish "the client sent the version it
-- read" from "the client sent nothing", because in both cases NEW.content_version
-- equals OLD.content_version. So compare-and-swap is the CALLER'S filter, which
-- is also how PostgREST expresses it:
--
--     PATCH /batches?id=eq.1&content_version=eq.3
--
-- A stale version matches no row and updates nothing. That is stated here rather
-- than implied, and BL-14/BL-15 test both halves - the stale write changing
-- nothing, and the fresh one succeeding and advancing the token.

create or replace function app_private.guard_content_version()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.content_version is distinct from old.content_version then
    raise exception 'content_version is maintained by the database and cannot be set by a caller'
      using errcode = '23514';
  end if;
  new.content_version := old.content_version + 1;
  return new;
end $fn$;

create trigger trg_batch_content_version
  before update on public.batches
  for each row execute function app_private.guard_content_version();
create trigger trg_pg_content_version
  before update on public.pricing_groups
  for each row execute function app_private.guard_content_version();
create trigger trg_row_content_version
  before update on public.batch_rows
  for each row execute function app_private.guard_content_version();

-- ------------------------------------------------------ stale threshold
create or replace function app_private.edit_lock_stale_seconds()
returns integer language sql stable security definer set search_path = '' as $fn$
  select coalesce(
    (select (setting_value #>> '{}')::int
       from public.operational_settings
      where setting_key = 'edit_lock_stale_seconds' and status = 'current'
      order by version_no desc limit 1),
    900);
$fn$;

-- ------------------------------------------------------- create a Batch
-- CDM-15: a new Batch starts with one default Pricing Group and one default
-- Delivery Group. Creating them here, in the same transaction as the Batch and
-- its lock, is what makes that true of every Batch rather than of every Batch
-- the UI happens to create correctly.
create or replace function app_private.create_batch(
  p_family bigint, p_plant bigint, p_sector bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_batch bigint; v_pg bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_plant_cap(p_plant, 'make_quote') then
    raise exception 'make_quote is required at that plant' using errcode = '42501';
  end if;
  if not exists (select 1 from public.customer_families where id = p_family) then
    raise exception 'unknown Customer Family' using errcode = '23503';
  end if;

  insert into public.batches (batch_reference, family_id, plant_id, owner_user_id,
                              sector_id, status, created_by)
  values ('pending', p_family, p_plant, v_me, p_sector, 'working', v_me)
  returning id into v_batch;

  insert into public.batch_edit_locks (batch_id, holder_user_id)
  values (v_batch, v_me);

  insert into public.pricing_groups (batch_id, label, created_by)
  values (v_batch, 'Default', v_me) returning id into v_pg;

  insert into public.delivery_groups (pricing_group_id, batch_id, label, created_by)
  values (v_pg, v_batch, 'Default', v_me);

  insert into public.batch_profile_versions (batch_id, version_no, created_by)
  values (v_batch, 1, v_me);

  return v_batch;
end $fn$;

-- --------------------------------------------------------- lock lifecycle
create or replace function app_private.acquire_batch_lock(p_batch bigint)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then raise exception 'no active app user' using errcode = '42501'; end if;
  if not app_private.can_read_batch(p_batch) then
    raise exception 'no access to that Batch' using errcode = '42501';
  end if;

  -- free only if never taken, released, or already ours
  update public.batch_edit_locks
     set holder_user_id = v_me, acquired_at = now(), heartbeat_at = now(), released_at = null
   where batch_id = p_batch
     and (released_at is not null or holder_user_id = v_me)
  returning id into v_id;

  if v_id is null then
    insert into public.batch_edit_locks (batch_id, holder_user_id)
    values (p_batch, v_me)
    on conflict (batch_id) do nothing
    returning id into v_id;
  end if;

  if v_id is null then
    raise exception 'the Batch is locked by another editor' using errcode = '55P03';
  end if;
  return v_id;
end $fn$;

-- A-23: touches heartbeat_at and nothing else, on a table with no content_version.
create or replace function app_private.heartbeat_batch_lock(p_batch bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_n int;
begin
  v_me := app_private.current_app_user();
  if v_me is null then raise exception 'no active app user' using errcode = '42501'; end if;

  update public.batch_edit_locks
     set heartbeat_at = now()
   where batch_id = p_batch and holder_user_id = v_me and released_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'you do not hold the edit lock on that Batch' using errcode = '55P03';
  end if;
end $fn$;

create or replace function app_private.release_batch_lock(p_batch bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then raise exception 'no active app user' using errcode = '42501'; end if;
  update public.batch_edit_locks
     set released_at = now()
   where batch_id = p_batch and holder_user_id = v_me and released_at is null;
end $fn$;

-- §4.6's statement, exactly: one conditional update, and zero rows means the
-- caller lost the race and must not proceed.
create or replace function app_private.reclaim_batch_lock(p_batch bigint, p_expected_holder bigint)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint; v_stale int;
begin
  v_me := app_private.current_app_user();
  if v_me is null then raise exception 'no active app user' using errcode = '42501'; end if;
  if not app_private.can_read_batch(p_batch) then
    raise exception 'no access to that Batch' using errcode = '42501';
  end if;
  v_stale := app_private.edit_lock_stale_seconds();

  update public.batch_edit_locks
     set holder_user_id = v_me, acquired_at = now(), heartbeat_at = now(), released_at = null
   where batch_id = p_batch
     and holder_user_id = p_expected_holder
     and released_at is null
     and now() - heartbeat_at > (v_stale * interval '1 second')
  returning id into v_id;

  if v_id is null then
    raise exception 'the lock was not stale, or another caller reclaimed it first'
      using errcode = '55P03';
  end if;
  return v_id;
end $fn$;

-- CDM-32: an ACTIVE takeover requires a reason, and is available only to the
-- Checker at that plant or an administrator. It does not wait for staleness -
-- that is what distinguishes it from reclaim, and why the reason is mandatory.
create or replace function app_private.takeover_batch_lock(p_batch bigint, p_reason text)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint; v_plant bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then raise exception 'no active app user' using errcode = '42501'; end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'an active takeover requires a reason (CDM-32)' using errcode = '22023';
  end if;

  select plant_id into v_plant from public.batches where id = p_batch;
  if v_plant is null then
    raise exception 'unknown Batch' using errcode = '23503';
  end if;
  if not (app_private.has_plant_cap(v_plant,'check_quote')
          or app_private.has_group_cap('administer_users')) then
    raise exception 'only the Checker at that plant or an administrator may take over a lock'
      using errcode = '42501';
  end if;

  update public.batch_edit_locks
     set holder_user_id = v_me, acquired_at = now(), heartbeat_at = now(), released_at = null
   where batch_id = p_batch
  returning id into v_id;

  if v_id is null then
    raise exception 'that Batch holds no lock to take over' using errcode = '23503';
  end if;
  return v_id;
end $fn$;

-- ---------------------------------------------------------------- shims
create or replace function public.create_batch(p_family bigint, p_plant bigint, p_sector bigint default null)
returns bigint language sql set search_path = '' as $fn$
  select app_private.create_batch(p_family, p_plant, p_sector);
$fn$;
create or replace function public.acquire_batch_lock(p_batch bigint)
returns bigint language sql set search_path = '' as $fn$
  select app_private.acquire_batch_lock(p_batch);
$fn$;
create or replace function public.heartbeat_batch_lock(p_batch bigint)
returns void language sql set search_path = '' as $fn$
  select app_private.heartbeat_batch_lock(p_batch);
$fn$;
create or replace function public.release_batch_lock(p_batch bigint)
returns void language sql set search_path = '' as $fn$
  select app_private.release_batch_lock(p_batch);
$fn$;
create or replace function public.reclaim_batch_lock(p_batch bigint, p_expected_holder bigint)
returns bigint language sql set search_path = '' as $fn$
  select app_private.reclaim_batch_lock(p_batch, p_expected_holder);
$fn$;
create or replace function public.takeover_batch_lock(p_batch bigint, p_reason text)
returns bigint language sql set search_path = '' as $fn$
  select app_private.takeover_batch_lock(p_batch, p_reason);
$fn$;

-- ---------------------------------------------------------------- grants
do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where p.proname in ('create_batch','acquire_batch_lock','heartbeat_batch_lock',
                         'release_batch_lock','reclaim_batch_lock','takeover_batch_lock')
       and n.nspname in ('public','app_private')
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;

revoke all on function app_private.guard_content_version() from public, anon, authenticated;
revoke all on function app_private.edit_lock_stale_seconds() from public, anon;
grant execute on function app_private.edit_lock_stale_seconds() to authenticated;