-- U5-1: governed operations for the Sector master.
--
-- Until now no propose/approve path for Sectors existed anywhere in the
-- application. server.py carried exactly one sector route and it only ATTACHED
-- an existing Sector to a Customer Family; the nineteen live Sectors arrived
-- solely through 20260918040738_seed_nagpur_limited_beta_masters.sql. A Sector
-- could therefore only be born in a migration, which is what stranded the
-- Commercial Policies screen on a browser-local list that no other screen reads.
--
-- SINGLE-STEP EDIT FOR BETA (Product Owner, 2026-09-22). The tables enforce
-- draft -> approved with two distinct capabilities, and that stays true: these
-- operations still move a version through both states and the transition
-- trigger still writes the attribution. What "single step" means is that ONE
-- operator action performs both, inside ONE transaction, so the screen never
-- shows a half-approved master. Both capabilities are therefore required.
--
-- A VERSION IS THE UNIT, A ROW IS THE VERSION. An approved sector_version is
-- immutable (CDM-31), so a commercial edit is a NEW version carrying all six
-- values, never an update of the approved one. The screen saves a whole row at
-- a time for exactly this reason: per-cell saving would mint one version per
-- keystroke and make the version history unreadable.

-- ───────────────────────────────────────────────────── propose a new Sector
-- Identity and its first commercial version are one transaction. There is no
-- reachable state in which a Sector exists with no version to resolve from.
create or replace function app_private.propose_sector(
  p_code text, p_name text,
  p_waste_cbb numeric, p_waste_pp numeric,
  p_conv_box numeric, p_conv_pp numeric,
  p_margin numeric, p_spec_lang text)
returns bigint
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sector bigint; v_version bigint;
begin
  if not app_private.has_any_plant_cap('propose_commercial_master') then
    raise exception 'propose_commercial_master is required to propose a Sector'
      using errcode = '42501';
  end if;
  if not app_private.has_any_plant_cap('approve_commercial_master') then
    raise exception 'approve_commercial_master is required - a Sector is proposed and approved in one step'
      using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_code is null or btrim(p_code) = '' then
    raise exception 'a Sector code is required' using errcode = '22023';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'a Sector name is required' using errcode = '22023';
  end if;
  if p_margin is null then
    raise exception 'a target margin is required - every Sector maintains one'
      using errcode = '22023';
  end if;
  if exists (select 1 from public.sectors where sector_code = btrim(upper(p_code))) then
    raise exception 'Sector code % already exists', btrim(upper(p_code))
      using errcode = '23505';
  end if;

  insert into public.sectors (sector_code, name, status, created_by)
  values (btrim(upper(p_code)), btrim(p_name), 'active', v_me)
  returning id into v_sector;

  insert into public.sector_versions (
    sector_id, version_no, waste_cbb_pct, waste_pp_pct,
    conv_box_rate, conv_pp_rate, margin_pct, spec_lang, created_by)
  values (v_sector, 1, p_waste_cbb, p_waste_pp,
          p_conv_box, p_conv_pp, p_margin, nullif(btrim(coalesce(p_spec_lang, '')), ''), v_me)
  returning id into v_version;

  -- approved_by/approved_at are written by trg_sectorv_transition from
  -- current_app_user() and now(); they are never supplied here (CDM-34).
  update public.sector_versions set status = 'approved' where id = v_version;
  return v_sector;
end $fn$;

-- ──────────────────────────────────────────── revise a Sector's commercials
-- CAS on the version number the operator actually read, so two people editing
-- the same row cannot silently stack two versions on one reading.
create or replace function app_private.revise_sector_commercials(
  p_sector bigint, p_expected_version_no integer,
  p_waste_cbb numeric, p_waste_pp numeric,
  p_conv_box numeric, p_conv_pp numeric,
  p_margin numeric, p_spec_lang text)
returns integer
language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_current integer; v_prior bigint; v_next integer; v_version bigint;
begin
  if not app_private.has_any_plant_cap('propose_commercial_master') then
    raise exception 'propose_commercial_master is required to revise a Sector'
      using errcode = '42501';
  end if;
  if not app_private.has_any_plant_cap('approve_commercial_master') then
    raise exception 'approve_commercial_master is required - a revision is proposed and approved in one step'
      using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if p_expected_version_no is null then
    raise exception 'the Sector version you read must be supplied' using errcode = '22023';
  end if;
  if p_margin is null then
    raise exception 'a target margin is required - every Sector maintains one'
      using errcode = '22023';
  end if;

  -- Lock the identity row so concurrent revisions serialise on it and the
  -- next version number cannot be allocated twice.
  perform 1 from public.sectors where id = p_sector for update;
  if not found then
    raise exception 'Sector not found' using errcode = 'P0002';
  end if;

  select sv.id, sv.version_no into v_prior, v_current
    from public.sector_versions sv
   where sv.sector_id = p_sector and sv.status = 'approved'
   order by sv.version_no desc limit 1;
  if v_prior is null then
    raise exception 'that Sector has no approved version to revise' using errcode = 'P0002';
  end if;
  if v_current <> p_expected_version_no then
    raise exception 'the Sector changed since you read it (expected version %, found %) - re-read and retry',
      p_expected_version_no, v_current using errcode = 'PT409';
  end if;

  select coalesce(max(sv.version_no), 0) + 1 into v_next
    from public.sector_versions sv where sv.sector_id = p_sector;

  insert into public.sector_versions (
    sector_id, version_no, waste_cbb_pct, waste_pp_pct,
    conv_box_rate, conv_pp_rate, margin_pct, spec_lang, created_by)
  values (p_sector, v_next, p_waste_cbb, p_waste_pp,
          p_conv_box, p_conv_pp, p_margin, nullif(btrim(coalesce(p_spec_lang, '')), ''), v_me)
  returning id into v_version;

  update public.sector_versions set status = 'approved' where id = v_version;
  update public.sector_versions set status = 'superseded' where id = v_prior;
  return v_next;
end $fn$;

-- ────────────────────────────────────────────── rename / retire the identity
-- The CODE is not editable here. It is the join key that Costing resolves a
-- Sector by (spec.sector -> sectors.sector_code), so changing it orphans every
-- reference at once. Only the display name moves.
create or replace function app_private.rename_sector(p_sector bigint, p_name text)
returns void
language plpgsql security definer set search_path = '' as $fn$
begin
  if not app_private.has_any_plant_cap('propose_commercial_master') then
    raise exception 'propose_commercial_master is required to rename a Sector'
      using errcode = '42501';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'a Sector name is required' using errcode = '22023';
  end if;
  update public.sectors set name = btrim(p_name) where id = p_sector;
  if not found then
    raise exception 'Sector not found' using errcode = 'P0002';
  end if;
end $fn$;

-- No Family D table has a DELETE policy (CDM-31), so a Sector is never deleted.
-- Deactivation is the governed equivalent, and it is refused while any
-- Customer Family still classifies itself by that Sector - otherwise the
-- Family's classification would silently point at an unusable tier.
create or replace function app_private.set_sector_status(p_sector bigint, p_status text)
returns void
language plpgsql security definer set search_path = '' as $fn$
declare v_refs integer;
begin
  if not app_private.has_any_plant_cap('approve_commercial_master') then
    raise exception 'approve_commercial_master is required to change a Sector''s status'
      using errcode = '42501';
  end if;
  if p_status not in ('active', 'inactive') then
    raise exception 'a Sector is either active or inactive' using errcode = '22023';
  end if;

  if p_status = 'inactive' then
    select count(*)::integer into v_refs
      from public.customer_family_sectors fs
      join public.customer_families f on f.id = fs.family_id
     where fs.sector_id = p_sector and f.status <> 'retired';
    if v_refs > 0 then
      raise exception 'that Sector still classifies % live Customer Familie(s) - reclassify them first', v_refs
        using errcode = '23503';
    end if;
  end if;

  update public.sectors set status = p_status where id = p_sector;
  if not found then
    raise exception 'Sector not found' using errcode = 'P0002';
  end if;
end $fn$;

-- ───────────────────────────────────────────────── public invoker wrappers
create or replace function public.propose_sector(
  p_code text, p_name text,
  p_waste_cbb numeric, p_waste_pp numeric,
  p_conv_box numeric, p_conv_pp numeric,
  p_margin numeric, p_spec_lang text)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.propose_sector(p_code, p_name, p_waste_cbb, p_waste_pp,
                                    p_conv_box, p_conv_pp, p_margin, p_spec_lang);
$fn$;

create or replace function public.revise_sector_commercials(
  p_sector bigint, p_expected_version_no integer,
  p_waste_cbb numeric, p_waste_pp numeric,
  p_conv_box numeric, p_conv_pp numeric,
  p_margin numeric, p_spec_lang text)
returns integer language sql security invoker set search_path = '' as $fn$
  select app_private.revise_sector_commercials(
    p_sector, p_expected_version_no, p_waste_cbb, p_waste_pp,
    p_conv_box, p_conv_pp, p_margin, p_spec_lang);
$fn$;

create or replace function public.rename_sector(p_sector bigint, p_name text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.rename_sector(p_sector, p_name);
$fn$;

create or replace function public.set_sector_status(p_sector bigint, p_status text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.set_sector_status(p_sector, p_status);
$fn$;

-- ───────────────────────────────────────────────────────────────── grants
revoke all on function app_private.propose_sector(text, text, numeric, numeric, numeric, numeric, numeric, text)
  from public, anon, authenticated;
revoke all on function app_private.revise_sector_commercials(bigint, integer, numeric, numeric, numeric, numeric, numeric, text)
  from public, anon, authenticated;
revoke all on function app_private.rename_sector(bigint, text) from public, anon, authenticated;
revoke all on function app_private.set_sector_status(bigint, text) from public, anon, authenticated;

revoke all on function public.propose_sector(text, text, numeric, numeric, numeric, numeric, numeric, text)
  from public, anon;
grant execute on function public.propose_sector(text, text, numeric, numeric, numeric, numeric, numeric, text)
  to authenticated;
revoke all on function public.revise_sector_commercials(bigint, integer, numeric, numeric, numeric, numeric, numeric, text)
  from public, anon;
grant execute on function public.revise_sector_commercials(bigint, integer, numeric, numeric, numeric, numeric, numeric, text)
  to authenticated;
revoke all on function public.rename_sector(bigint, text) from public, anon;
grant execute on function public.rename_sector(bigint, text) to authenticated;
revoke all on function public.set_sector_status(bigint, text) from public, anon;
grant execute on function public.set_sector_status(bigint, text) to authenticated;
