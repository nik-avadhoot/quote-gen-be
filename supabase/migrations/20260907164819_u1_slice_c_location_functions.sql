-- U1 Slice C - Customer Location proposal/version/approval/retirement.
--
-- Authorised by docs/u1-customer-foundation-authorization-packet.md
-- (quote-gen-fe), Slice C, as narrowed by the second review round:
--   - eligibility is chosen ONLY at proposal (p_bill_to_eligible/
--     p_ship_to_eligible on propose_customer_location); ck_loc_eligible
--     ("at least one") is retained unchanged. There is NO
--     update_location_eligibility function - post-proposal eligibility
--     change is Product-Owner-blocked, not designed here.
--   - Location-to-Party reassignment is out of scope - no schema mechanism
--     exists (confirmed live: customer_location_versions carries no
--     party_id, no parent-history table exists) and none is built here.
--
-- CAS EVERYWHERE MUTABLE. Every function that changes an EXISTING row takes
-- a required p_expected_content_version - no default. Same technique as
-- every Family B function: a self-referential UPDATE guarded by
-- content_version = p_expected is the compare-and-swap.
--
-- ATOMICITY. propose_customer_location is two inserts (customer_locations,
-- then its first customer_location_versions row) in one function body -
-- Postgres's own implicit transaction is the atomicity guarantee.

-- ══════════════════════ propose a Customer Location ═════════════════════════
create or replace function app_private.propose_customer_location(
  p_party bigint,
  p_location_type text,
  p_address_text text,
  p_contact_name text,
  p_notes text,
  p_bill_to_eligible boolean,
  p_ship_to_eligible boolean
) returns bigint
language plpgsql security definer set search_path to '' as $fn$
declare v_me bigint; v_location_id bigint;
begin
  if not (app_private.has_group_cap('manage_customer_master')
          or app_private.has_any_plant_cap('make_quote')) then
    raise exception 'manage_customer_master or make_quote at an active plant required'
      using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not (p_bill_to_eligible or p_ship_to_eligible) then
    raise exception 'a Location must be Bill-to, Ship-to or both' using errcode = '22023';
  end if;
  perform 1 from public.parties where id = p_party for update;
  if not found then
    raise exception 'party not found' using errcode = 'P0002';
  end if;

  insert into public.customer_locations
    (party_id, bill_to_eligible, ship_to_eligible, status, created_by)
  values (p_party, p_bill_to_eligible, p_ship_to_eligible, 'proposed', v_me)
  returning id into v_location_id;

  insert into public.customer_location_versions
    (location_id, version_no, location_type, address_text, contact_name, notes, status, created_by)
  values (v_location_id, 1, p_location_type, p_address_text, p_contact_name, p_notes, 'current', v_me);

  return v_location_id;
end $fn$;

-- ══════════════════ edit descriptive detail (new version) ═══════════════════
create or replace function app_private.update_customer_location(
  p_location bigint,
  p_expected_content_version integer,
  p_address_text text,
  p_contact_name text,
  p_notes text
) returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_me bigint; v_n int; v_type text; v_next_version int;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if p_expected_content_version is null then
    raise exception 'the Location content version you read must be supplied' using errcode = '22023';
  end if;

  update public.customer_locations set content_version = content_version
   where id = p_location and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    perform 1 from public.customer_locations where id = p_location;
    if not found then
      raise exception 'location not found' using errcode = 'P0002';
    end if;
    raise exception 'the Location changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = '40001';
  end if;

  select location_type, version_no + 1 into v_type, v_next_version
    from public.customer_location_versions
   where location_id = p_location and status = 'current';

  update public.customer_location_versions
     set status = 'superseded'
   where location_id = p_location and status = 'current';

  insert into public.customer_location_versions
    (location_id, version_no, location_type, address_text, contact_name, notes, status, created_by)
  values (p_location, v_next_version, v_type, p_address_text, p_contact_name, p_notes, 'current', v_me);

  update public.customer_locations
     set content_version = content_version + 1
   where id = p_location;
end $fn$;

-- ══════════════════════════════ approve / retire ═════════════════════════════
create or replace function app_private.approve_customer_location(
  p_location bigint, p_expected_content_version integer)
returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_n int; v_status text;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_expected_content_version is null then
    raise exception 'the Location content version you read must be supplied' using errcode = '22023';
  end if;

  select status into v_status from public.customer_locations where id = p_location for update;
  if not found then
    raise exception 'location not found' using errcode = 'P0002';
  end if;
  if v_status <> 'proposed' then
    raise exception 'only a proposed Location may be approved (currently %)', v_status
      using errcode = '22023';
  end if;

  update public.customer_locations
     set status = 'active', content_version = content_version + 1
   where id = p_location and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'the Location changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = '40001';
  end if;
end $fn$;

create or replace function app_private.retire_customer_location(
  p_location bigint, p_expected_content_version integer)
returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_n int; v_status text;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_expected_content_version is null then
    raise exception 'the Location content version you read must be supplied' using errcode = '22023';
  end if;

  select status into v_status from public.customer_locations where id = p_location for update;
  if not found then
    raise exception 'location not found' using errcode = 'P0002';
  end if;
  if v_status <> 'active' then
    raise exception 'only an active Location may be retired (currently %)', v_status
      using errcode = '22023';
  end if;

  update public.customer_locations
     set status = 'inactive', content_version = content_version + 1
   where id = p_location and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'the Location changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = '40001';
  end if;
end $fn$;

-- ═══════════════════════ public invoker wrappers ════════════════════════════
create or replace function public.propose_customer_location(
  p_party bigint, p_location_type text, p_address_text text, p_contact_name text,
  p_notes text, p_bill_to_eligible boolean, p_ship_to_eligible boolean)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.propose_customer_location(
    p_party, p_location_type, p_address_text, p_contact_name, p_notes,
    p_bill_to_eligible, p_ship_to_eligible);
$fn$;

create or replace function public.update_customer_location(
  p_location bigint, p_expected_content_version integer,
  p_address_text text, p_contact_name text, p_notes text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.update_customer_location(
    p_location, p_expected_content_version, p_address_text, p_contact_name, p_notes);
$fn$;

create or replace function public.approve_customer_location(
  p_location bigint, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.approve_customer_location(p_location, p_expected_content_version);
$fn$;

create or replace function public.retire_customer_location(
  p_location bigint, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.retire_customer_location(p_location, p_expected_content_version);
$fn$;

-- assign_location_code already exists and is already governed (idempotent,
-- refuses an un-graduated Party with P0002) - needs only a public wrapper.
create or replace function public.assign_customer_location_code(p_location bigint)
returns text language sql security invoker set search_path = '' as $fn$
  select app_private.assign_location_code(p_location);
$fn$;

-- ═══════════════════════ grant / revoke posture ═════════════════════════════
-- Explicit service_role revoke from the FIRST migration for every new
-- object - app_private functions AND their public wrappers alike (the
-- U1-CF-C1 lesson, and this slice's own Slice-A lesson that a brand-new
-- function's ACL is NULL/implicit-default until explicitly materialised).
do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app_private'
       and p.proname in ('propose_customer_location', 'update_customer_location',
         'approve_customer_location', 'retire_customer_location')
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from service_role',  r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;

  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('propose_customer_location', 'update_customer_location',
         'approve_customer_location', 'retire_customer_location', 'assign_customer_location_code')
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from service_role',  r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;
