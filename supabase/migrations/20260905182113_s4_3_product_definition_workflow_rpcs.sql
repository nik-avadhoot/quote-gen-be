-- S4-3: the Family C proposal, approval, publication and adoption operations.
--
-- Shape is the restored P2-6 design, unchanged: routing in `public` as a thin
-- SECURITY INVOKER shim that decides nothing, privilege in `app_private` as
-- SECURITY DEFINER with search_path='' and its own capability checks. No definer
-- function is created in an exposed schema, and no new authority exists - the
-- shim runs as the caller, so reaching the implementation still needs USAGE on
-- app_private plus EXECUTE, which `authenticated` already holds and `anon` does
-- not.
--
-- Why these are RPCs at all rather than table writes: every one of them either
-- allocates a permanent code, sets approval attribution, or crosses a capability
-- boundary. CDM-34 requires attribution to be the system's word, not the
-- client's, so approved_by / approved_at / adopted_by / created_by are written
-- from current_app_user() and now() and are never accepted as parameters.

-- ==========================================================================
-- Construction Library
-- ==========================================================================

-- CDM-12/DM-144: a Maker may create a stable Proposed Construction from Batch
-- Entry. Version 1 is written in the same statement, because a Construction with
-- no technical definition is not a proposal - it is an empty row.
create or replace function app_private.propose_construction(
  p_name           text,
  p_ply            integer,
  p_flute_f1       text    default null,
  p_flute_f2       text    default null,
  p_layer_top_code text    default null,
  p_layer_f1_code  text    default null,
  p_layer_l1_code  text    default null,
  p_layer_f2_code  text    default null,
  p_layer_l2_code  text    default null,
  p_layer_top_gsm  numeric default null,
  p_layer_f1_gsm   numeric default null,
  p_layer_l1_gsm   numeric default null,
  p_layer_f2_gsm   numeric default null,
  p_layer_l2_gsm   numeric default null,
  p_board_gsm      numeric default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_k bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not ( app_private.has_group_cap('manage_construction_library')
        or exists (select 1
                     from public.plant_capability_grants g
                     join public.capabilities c on c.id = g.capability_id
                    where g.app_user_id = v_me
                      and c.capability_key = 'make_quote'
                      and g.status = 'active') ) then
    raise exception 'manage_construction_library or a make_quote grant is required'
      using errcode = '42501';
  end if;
  if coalesce(btrim(p_name),'') = '' then
    raise exception 'a Construction name is required' using errcode = '22023';
  end if;

  insert into public.constructions (name, status, created_by)
  values (btrim(p_name), 'proposed', v_me)
  returning id into v_k;

  insert into public.construction_versions (
    construction_id, version_no, ply, flute_f1, flute_f2,
    layer_top_code, layer_f1_code, layer_l1_code, layer_f2_code, layer_l2_code,
    layer_top_gsm,  layer_f1_gsm,  layer_l1_gsm,  layer_f2_gsm,  layer_l2_gsm,
    board_gsm, created_by)
  values (
    v_k, 1, p_ply, p_flute_f1, p_flute_f2,
    p_layer_top_code, p_layer_f1_code, p_layer_l1_code, p_layer_f2_code, p_layer_l2_code,
    p_layer_top_gsm,  p_layer_f1_gsm,  p_layer_l1_gsm,  p_layer_f2_gsm,  p_layer_l2_gsm,
    p_board_gsm, v_me);

  return v_k;
end $fn$;

-- Approval freezes the version. After this the guard trigger refuses every
-- further write to it, for every role (CDM-12).
create or replace function app_private.approve_construction_version(p_version bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_approved timestamptz;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_group_cap('manage_construction_library') then
    raise exception 'manage_construction_library required' using errcode = '42501';
  end if;

  select approved_at into v_approved
    from public.construction_versions where id = p_version for update;
  if not found then
    raise exception 'unknown construction version' using errcode = '22023';
  end if;
  if v_approved is not null then
    raise exception 'construction version % is already approved', p_version
      using errcode = '23514';
  end if;

  -- attribution is the system's word, never the client's
  update public.construction_versions
     set approved_by = v_me, approved_at = now()
   where id = p_version;
end $fn$;

-- CDM-12: publication allocates the neutral permanent sequence code. CDM-03: the
-- code is unique in its approved scope and never reused, so it comes from the
-- accepted ref_private allocator (P-5) rather than from a count or a max().
create or replace function app_private.publish_construction(p_construction bigint)
returns text language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_status text; v_code text; v_n bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_group_cap('manage_construction_library') then
    raise exception 'manage_construction_library required' using errcode = '42501';
  end if;

  select status into v_status from public.constructions where id = p_construction for update;
  if not found then
    raise exception 'unknown construction' using errcode = '22023';
  end if;
  if v_status <> 'proposed' then
    raise exception 'only a proposed Construction may be published (found %)', v_status
      using errcode = '23514';
  end if;
  if not exists (select 1 from public.construction_versions
                  where construction_id = p_construction) then
    raise exception 'a Construction with no technical version cannot be published'
      using errcode = '23514';
  end if;

  v_n    := ref_private.allocate_reference('construction', 0, null);
  v_code := 'CON-' || lpad(v_n::text, 6, '0');

  update public.constructions
     set construction_code = v_code, status = 'published'
   where id = p_construction;

  return v_code;
end $fn$;

-- CDM-12: a duplicate proposal merges INTO the existing Construction with lineage
-- retained. The merged row is never deleted - it keeps pointing at its survivor.
create or replace function app_private.merge_construction(
  p_duplicate bigint, p_survivor bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_dup_status text; v_surv_status text;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_group_cap('manage_construction_library') then
    raise exception 'manage_construction_library required' using errcode = '42501';
  end if;
  if p_duplicate = p_survivor then
    raise exception 'a Construction cannot merge into itself' using errcode = '23514';
  end if;

  select status into v_dup_status  from public.constructions where id = p_duplicate for update;
  if not found then
    raise exception 'unknown duplicate Construction' using errcode = '22023';
  end if;
  select status into v_surv_status from public.constructions where id = p_survivor;
  if not found then
    raise exception 'unknown surviving Construction' using errcode = '22023';
  end if;
  if v_surv_status = 'merged' then
    raise exception 'the survivor is itself merged - lineage must not chain into a merged row'
      using errcode = '23514';
  end if;

  -- the transition matrix in guard_construction_permanence rejects anything
  -- other than proposed -> merged, so an illegal source state fails there
  update public.constructions
     set status = 'merged', surviving_construction_id = p_survivor
   where id = p_duplicate;
end $fn$;

-- CDM-12: formal Batch use requires adoption of an EXACT version by an EXACT
-- plant. "Formal" is what makes both preconditions real: the Construction must be
-- published and the version approved. A Quote-specific proposal needs no adoption
-- precisely because it is not formal use.
create or replace function app_private.adopt_construction_for_plant(
  p_plant bigint, p_version bigint)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_id bigint; v_k_status text; v_approved timestamptz;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_plant_cap(p_plant, 'adopt_construction_for_plant') then
    raise exception 'adopt_construction_for_plant required at that plant' using errcode = '42501';
  end if;

  select k.status, cv.approved_at into v_k_status, v_approved
    from public.construction_versions cv
    join public.constructions k on k.id = cv.construction_id
   where cv.id = p_version;
  if not found then
    raise exception 'unknown construction version' using errcode = '22023';
  end if;
  if v_k_status <> 'published' then
    raise exception 'only a published Construction may be adopted for formal use (found %)', v_k_status
      using errcode = '23514';
  end if;
  if v_approved is null then
    raise exception 'only an approved Construction Version may be adopted' using errcode = '23514';
  end if;

  insert into public.plant_construction_adoptions (plant_id, construction_version_id, adopted_by)
  values (p_plant, p_version, v_me)
  returning id into v_id;
  return v_id;
end $fn$;

-- ==========================================================================
-- SKU master
-- ==========================================================================

-- CDM-11/DM-132: a Maker may create a stable Proposed SKU and quote it BEFORE
-- Plant Item Code assignment. No pseudo-code is manufactured, so the SKU is born
-- with plant_item_code null and status 'proposed'.
create or replace function app_private.propose_sku(
  p_plant                bigint,
  p_party                bigint,
  p_construction_version bigint,
  p_is_price_driving     boolean default true,
  p_length_mm            numeric default null,
  p_width_mm             numeric default null,
  p_height_mm            numeric default null,
  p_box_type             text    default 'RSC',
  p_ups                  integer default 1,
  p_spec_bs              numeric default null,
  p_spec_bct             numeric default null,
  p_spec_ect             numeric default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_sku bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not ( app_private.has_plant_cap(p_plant, 'manage_sku_master')
        or app_private.has_plant_cap(p_plant, 'make_quote') ) then
    raise exception 'manage_sku_master or make_quote is required at that plant'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.parties where id = p_party) then
    raise exception 'unknown Customer' using errcode = '22023';
  end if;
  -- CDM-13: a spec version always has exactly one Construction authority. The
  -- not null FK enforces it; this raises the readable error first.
  if p_construction_version is null
     or not exists (select 1 from public.construction_versions where id = p_construction_version) then
    raise exception 'a SKU spec version requires a Construction Version' using errcode = '22023';
  end if;

  insert into public.skus (plant_id, party_id, status, created_by)
  values (p_plant, p_party, 'proposed', v_me)
  returning id into v_sku;

  insert into public.sku_versions (
    sku_id, plant_id, version_no, construction_version_id, is_price_driving,
    length_mm, width_mm, height_mm, box_type, ups, spec_bs, spec_bct, spec_ect, created_by)
  values (
    v_sku, p_plant, 1, p_construction_version, p_is_price_driving,
    p_length_mm, p_width_mm, p_height_mm, coalesce(p_box_type,'RSC'), coalesce(p_ups,1),
    p_spec_bs, p_spec_bct, p_spec_ect, v_me);

  return v_sku;
end $fn$;

create or replace function app_private.approve_sku_version(p_version bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_plant bigint; v_approved timestamptz;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;

  select plant_id, approved_at into v_plant, v_approved
    from public.sku_versions where id = p_version for update;
  if not found then
    raise exception 'unknown SKU version' using errcode = '22023';
  end if;
  if not app_private.has_plant_cap(v_plant, 'manage_sku_master') then
    raise exception 'manage_sku_master required at that plant' using errcode = '42501';
  end if;
  if v_approved is not null then
    raise exception 'SKU version % is already approved', p_version using errcode = '23514';
  end if;

  update public.sku_versions
     set approved_by = v_me, approved_at = now()
   where id = p_version;
end $fn$;

-- CDM-11: SKU code assignment and activation are Admin/NPD acts, not Maker acts.
-- CDM-09: the code is permanent from this moment - guard_sku_permanence refuses
-- every later change to it, for every role.
create or replace function app_private.assign_plant_item_code(p_sku bigint, p_code text)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_plant bigint; v_status text; v_existing text;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if coalesce(btrim(p_code),'') = '' then
    raise exception 'a Plant Item Code is required' using errcode = '22023';
  end if;

  select plant_id, status, plant_item_code into v_plant, v_status, v_existing
    from public.skus where id = p_sku for update;
  if not found then
    raise exception 'unknown SKU' using errcode = '22023';
  end if;
  if not app_private.has_plant_cap(v_plant, 'manage_sku_master') then
    raise exception 'manage_sku_master required at that plant' using errcode = '42501';
  end if;
  if v_existing is not null then
    raise exception 'SKU % already carries the permanent code %', p_sku, v_existing
      using errcode = '23514';
  end if;
  if v_status <> 'proposed' then
    raise exception 'only a proposed SKU may be assigned its code and activated (found %)', v_status
      using errcode = '23514';
  end if;

  update public.skus
     set plant_item_code = btrim(p_code), status = 'active'
   where id = p_sku;
end $fn$;

-- CDM-11: discontinued SKUs cannot be newly selected; reactivation preserves
-- identity, so it returns the SAME row to active rather than creating another.
-- The legal transitions live in guard_sku_permanence and are not restated here -
-- one statement of a rule is better than two that can drift apart.
create or replace function app_private.set_sku_status(p_sku bigint, p_status text)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_plant bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;

  select plant_id into v_plant from public.skus where id = p_sku for update;
  if not found then
    raise exception 'unknown SKU' using errcode = '22023';
  end if;
  if not app_private.has_plant_cap(v_plant, 'manage_sku_master') then
    raise exception 'manage_sku_master required at that plant' using errcode = '42501';
  end if;

  update public.skus set status = p_status where id = p_sku;
end $fn$;

-- ==========================================================================
-- Routing shims - SECURITY INVOKER, no privilege, no decisions
-- ==========================================================================

create or replace function public.propose_construction(
  p_name text, p_ply integer,
  p_flute_f1 text default null, p_flute_f2 text default null,
  p_layer_top_code text default null, p_layer_f1_code text default null,
  p_layer_l1_code text default null, p_layer_f2_code text default null,
  p_layer_l2_code text default null,
  p_layer_top_gsm numeric default null, p_layer_f1_gsm numeric default null,
  p_layer_l1_gsm numeric default null, p_layer_f2_gsm numeric default null,
  p_layer_l2_gsm numeric default null, p_board_gsm numeric default null)
returns bigint language sql set search_path = '' as $fn$
  select app_private.propose_construction(
    p_name, p_ply, p_flute_f1, p_flute_f2,
    p_layer_top_code, p_layer_f1_code, p_layer_l1_code, p_layer_f2_code, p_layer_l2_code,
    p_layer_top_gsm, p_layer_f1_gsm, p_layer_l1_gsm, p_layer_f2_gsm, p_layer_l2_gsm,
    p_board_gsm);
$fn$;

create or replace function public.approve_construction_version(p_version bigint)
returns void language sql set search_path = '' as $fn$
  select app_private.approve_construction_version(p_version);
$fn$;

create or replace function public.publish_construction(p_construction bigint)
returns text language sql set search_path = '' as $fn$
  select app_private.publish_construction(p_construction);
$fn$;

create or replace function public.merge_construction(p_duplicate bigint, p_survivor bigint)
returns void language sql set search_path = '' as $fn$
  select app_private.merge_construction(p_duplicate, p_survivor);
$fn$;

create or replace function public.adopt_construction_for_plant(p_plant bigint, p_version bigint)
returns bigint language sql set search_path = '' as $fn$
  select app_private.adopt_construction_for_plant(p_plant, p_version);
$fn$;

create or replace function public.propose_sku(
  p_plant bigint, p_party bigint, p_construction_version bigint,
  p_is_price_driving boolean default true,
  p_length_mm numeric default null, p_width_mm numeric default null,
  p_height_mm numeric default null, p_box_type text default 'RSC',
  p_ups integer default 1, p_spec_bs numeric default null,
  p_spec_bct numeric default null, p_spec_ect numeric default null)
returns bigint language sql set search_path = '' as $fn$
  select app_private.propose_sku(
    p_plant, p_party, p_construction_version, p_is_price_driving,
    p_length_mm, p_width_mm, p_height_mm, p_box_type, p_ups,
    p_spec_bs, p_spec_bct, p_spec_ect);
$fn$;

create or replace function public.approve_sku_version(p_version bigint)
returns void language sql set search_path = '' as $fn$
  select app_private.approve_sku_version(p_version);
$fn$;

create or replace function public.assign_plant_item_code(p_sku bigint, p_code text)
returns void language sql set search_path = '' as $fn$
  select app_private.assign_plant_item_code(p_sku, p_code);
$fn$;

create or replace function public.set_sku_status(p_sku bigint, p_status text)
returns void language sql set search_path = '' as $fn$
  select app_private.set_sku_status(p_sku, p_status);
$fn$;

-- ==========================================================================
-- Grants - anon is granted nothing, ever
-- ==========================================================================
do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (
             ('app_private','propose_construction'),
             ('app_private','approve_construction_version'),
             ('app_private','publish_construction'),
             ('app_private','merge_construction'),
             ('app_private','adopt_construction_for_plant'),
             ('app_private','propose_sku'),
             ('app_private','approve_sku_version'),
             ('app_private','assign_plant_item_code'),
             ('app_private','set_sku_status'),
             ('public','propose_construction'),
             ('public','approve_construction_version'),
             ('public','publish_construction'),
             ('public','merge_construction'),
             ('public','adopt_construction_for_plant'),
             ('public','propose_sku'),
             ('public','approve_sku_version'),
             ('public','assign_plant_item_code'),
             ('public','set_sku_status'))
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;