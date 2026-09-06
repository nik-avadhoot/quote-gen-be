-- S5-3: the Pricing Basis propose / approve / withdraw operations.
--
-- Same P2-6 shape as every other operation in this programme: routing in
-- `public` as a SECURITY INVOKER shim that decides nothing, privilege in
-- `app_private` as SECURITY DEFINER with search_path='' and its own capability
-- checks.
--
-- Note what the approve RPC does NOT offer: a way to make an already-approved
-- Release the automatic default. §7.5 rejects approved -> approved outright, and
-- CDM-26 is explicit that a different default is a NEW Release, not an edit to an
-- old one. So the default flag is decided at the moment of approval and is
-- immutable thereafter - which is also why ck_pbr_default_requires_approved and
-- the partial exclusion constraint can both be trusted.

create or replace function app_private.propose_pricing_basis_release(
  p_plant                        bigint,
  p_effective_from               date,
  p_rate_set_version_id          bigint,
  p_freight_set_version_id       bigint,
  p_sector_version_id            bigint,
  p_calculation_default_version_id bigint,
  p_effective_until              date default null,
  p_release_name                 text default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_plant_cap(p_plant,'propose_commercial_master') then
    raise exception 'propose_commercial_master is required at that plant' using errcode = '42501';
  end if;
  if p_effective_from is null then
    raise exception 'a Release must state when it takes effect' using errcode = '22023';
  end if;

  -- the four components are not null columns, so a missing one cannot be stored;
  -- guard_release_components_approved then refuses any that is not approved
  insert into public.pricing_basis_releases
    (plant_id, release_name, effective_from, effective_until,
     rate_set_version_id, freight_set_version_id, sector_version_id,
     calculation_default_version_id, status, proposed_by)
  values
    (p_plant, p_release_name, p_effective_from, p_effective_until,
     p_rate_set_version_id, p_freight_set_version_id, p_sector_version_id,
     p_calculation_default_version_id, 'draft', v_me)
  returning id into v_id;

  return v_id;
end $fn$;

-- CDM-26/CDM-27. The automatic-default decision is made HERE, at approval, and
-- never afterwards. A second approved default overlapping the same plant and
-- dates is refused by ex_pbr_default_no_overlap, not by this function - so the
-- rule holds for every writer, including one that never calls this RPC.
create or replace function app_private.approve_pricing_basis_release(
  p_release bigint,
  p_is_automatic_default boolean default false)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_plant bigint; v_status text;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;

  select plant_id, status into v_plant, v_status
    from public.pricing_basis_releases where id = p_release for update;
  if not found then
    raise exception 'unknown Pricing Basis Release' using errcode = '22023';
  end if;
  if not app_private.has_plant_cap(v_plant,'approve_commercial_master') then
    raise exception 'approve_commercial_master is required at that plant' using errcode = '42501';
  end if;
  if v_status <> 'draft' then
    raise exception 'only a draft Release may be approved (found %)', v_status using errcode = '23514';
  end if;

  -- attribution and self_approved are written by the transition trigger, not here
  update public.pricing_basis_releases
     set status = 'approved',
         is_automatic_default = coalesce(p_is_automatic_default, false)
   where id = p_release;
end $fn$;

create or replace function app_private.withdraw_pricing_basis_release(p_release bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_plant bigint; v_status text;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;

  select plant_id, status into v_plant, v_status
    from public.pricing_basis_releases where id = p_release for update;
  if not found then
    raise exception 'unknown Pricing Basis Release' using errcode = '22023';
  end if;
  if not app_private.has_plant_cap(v_plant,'approve_commercial_master') then
    raise exception 'approve_commercial_master is required at that plant' using errcode = '42501';
  end if;
  if v_status <> 'approved' then
    raise exception 'only an approved Release may be withdrawn (found %)', v_status using errcode = '23514';
  end if;

  update public.pricing_basis_releases set status = 'withdrawn' where id = p_release;
end $fn$;

-- ---------------------------------------------------------------- shims
create or replace function public.propose_pricing_basis_release(
  p_plant bigint, p_effective_from date,
  p_rate_set_version_id bigint, p_freight_set_version_id bigint,
  p_sector_version_id bigint, p_calculation_default_version_id bigint,
  p_effective_until date default null, p_release_name text default null)
returns bigint language sql set search_path = '' as $fn$
  select app_private.propose_pricing_basis_release(
    p_plant, p_effective_from, p_rate_set_version_id, p_freight_set_version_id,
    p_sector_version_id, p_calculation_default_version_id, p_effective_until, p_release_name);
$fn$;

create or replace function public.approve_pricing_basis_release(
  p_release bigint, p_is_automatic_default boolean default false)
returns void language sql set search_path = '' as $fn$
  select app_private.approve_pricing_basis_release(p_release, p_is_automatic_default);
$fn$;

create or replace function public.withdraw_pricing_basis_release(p_release bigint)
returns void language sql set search_path = '' as $fn$
  select app_private.withdraw_pricing_basis_release(p_release);
$fn$;

-- ---------------------------------------------------------------- grants
do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (
             ('app_private','propose_pricing_basis_release'),
             ('app_private','approve_pricing_basis_release'),
             ('app_private','withdraw_pricing_basis_release'),
             ('public','propose_pricing_basis_release'),
             ('public','approve_pricing_basis_release'),
             ('public','withdraw_pricing_basis_release'))
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;