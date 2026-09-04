-- P2-4: the rest of the S3 Party slice - graduation, merge, family reassignment,
-- and permanent non-reused code allocation. Creating the seven Family B tables was
-- not the whole slice; these are the operations CDM-06/07 and DM-109..129 require.
--
-- All are SECURITY DEFINER because they must allocate from ref_private sequences,
-- which no client may touch. Each therefore performs its own explicit capability
-- check first - the RLS policies do not protect a definer function.

-- DM-109: Group Customer Code is a neutral permanent sequence, independent of name.
create or replace function app_private.allocate_group_customer_code()
returns text language plpgsql security definer set search_path = '' as $fn$
declare v bigint;
begin
  v := ref_private.allocate_reference('group_customer', 0, null);
  return 'G' || lpad(v::text, 4, '0');
end $fn$;

-- CDM-06: graduation changes the LIFECYCLE STATE of one permanent identity.
-- DM-111/112: the Customer Code embeds the ORIGINAL Family code plus a simple
-- sequence within that family, and stays permanent through later reassignment.
create or replace function app_private.graduate_party(p_party bigint)
returns text language plpgsql security definer set search_path = '' as $fn$
declare
  v_party   public.parties%rowtype;
  v_family  public.customer_families%rowtype;
  v_seq     bigint;
  v_code    text;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;

  select * into v_party from public.parties where id = p_party for update;
  if v_party.id is null then
    raise exception 'party not found' using errcode = 'P0002';
  end if;
  if v_party.lifecycle_state = 'customer' then
    -- idempotent: graduation never mints a second code for the same identity
    return v_party.customer_code;
  end if;

  select f.* into v_family
    from public.party_family_memberships m
    join public.customer_families f on f.id = m.family_id
   where m.party_id = p_party and m.is_current;
  if v_family.id is null then
    raise exception 'party has no current family membership' using errcode = 'P0002';
  end if;
  if v_family.group_customer_code is null then
    raise exception 'family has no Group Customer Code' using errcode = 'P0002';
  end if;

  v_seq  := ref_private.allocate_reference('customer', v_family.id, null);
  v_code := v_family.group_customer_code || '-' || lpad(v_seq::text, 3, '0');

  update public.parties
     set lifecycle_state = 'customer',
         status          = 'active',
         customer_code   = v_code,
         content_version = content_version + 1
   where id = p_party;

  return v_code;
end $fn$;

-- DM-113: Location Code is a permanent sequence beneath its Customer Code.
create or replace function app_private.assign_location_code(p_location bigint)
returns text language plpgsql security definer set search_path = '' as $fn$
declare v_loc public.customer_locations%rowtype; v_party public.parties%rowtype;
        v_seq bigint; v_code text;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  select * into v_loc from public.customer_locations where id = p_location for update;
  if v_loc.id is null then
    raise exception 'location not found' using errcode = 'P0002';
  end if;
  if v_loc.location_code is not null then
    return v_loc.location_code;                    -- permanent, never reissued
  end if;
  select * into v_party from public.parties where id = v_loc.party_id;
  if v_party.customer_code is null then
    raise exception 'party is not graduated; no Customer Code to nest beneath'
      using errcode = 'P0002';
  end if;
  v_seq  := ref_private.allocate_reference('location', v_loc.party_id, null);
  v_code := v_party.customer_code || '-' || lpad(v_seq::text, 2, '0');
  update public.customer_locations
     set location_code = v_code, content_version = content_version + 1
   where id = p_location;
  return v_code;
end $fn$;

-- DM-128/129: family reassignment is effective-dated with exactly one current row.
-- The party row is locked first so two concurrent reassignments serialise rather
-- than racing the partial unique index into an error.
create or replace function app_private.reassign_party_family(
  p_party bigint, p_new_family bigint, p_effective date default current_date)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_current public.party_family_memberships%rowtype; v_me bigint;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();

  perform 1 from public.parties where id = p_party for update;
  if not found then
    raise exception 'party not found' using errcode = 'P0002';
  end if;

  select * into v_current
    from public.party_family_memberships
   where party_id = p_party and is_current
   for update;

  if v_current.family_id = p_new_family then
    return;                                        -- already there; no-op
  end if;

  if v_current.id is not null then
    if p_effective < v_current.effective_from then
      raise exception 'effective date precedes the current membership'
        using errcode = '22007';
    end if;
    update public.party_family_memberships
       set is_current = false, effective_until = p_effective
     where id = v_current.id;
  end if;

  insert into public.party_family_memberships
    (party_id, family_id, effective_from, is_current, created_by)
  values (p_party, p_new_family, p_effective, true, v_me);
end $fn$;

-- DM-125: duplicate parties merge into ONE surviving identity. The merged row is
-- retained, never deleted, and keeps pointing at its survivor so issued history
-- stays resolvable.
create or replace function app_private.merge_parties(p_survivor bigint, p_merged bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_survivor = p_merged then
    raise exception 'a party cannot merge into itself' using errcode = '22023';
  end if;
  perform 1 from public.parties where id in (p_survivor, p_merged) for update;

  if (select status from public.parties where id = p_survivor) = 'merged' then
    raise exception 'survivor is itself merged' using errcode = '22023';
  end if;

  -- external references follow the survivor so legacy codes stay searchable
  update public.party_external_references
     set party_id = p_survivor
   where party_id = p_merged
     and not exists (select 1 from public.party_external_references x
                      where x.party_id = p_survivor
                        and x.ref_kind = party_external_references.ref_kind
                        and x.ref_value = party_external_references.ref_value);

  update public.parties
     set status = 'merged',
         surviving_party_id = p_survivor,
         content_version = content_version + 1
   where id = p_merged;
end $fn$;

-- DM-127: family consolidation retains one survivor plus retired aliases.
create or replace function app_private.merge_families(p_survivor bigint, p_retired bigint)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_survivor = p_retired then
    raise exception 'a family cannot merge into itself' using errcode = '22023';
  end if;
  v_me := app_private.current_app_user();
  perform 1 from public.customer_families where id in (p_survivor, p_retired) for update;

  -- the retired family's name survives as an alias of the survivor
  insert into public.customer_family_aliases (family_id, alias, created_by)
  select p_survivor, f.name, v_me
    from public.customer_families f
   where f.id = p_retired
  on conflict (family_id, alias) do nothing;

  update public.customer_families
     set status = 'retired',
         surviving_family_id = p_survivor,
         content_version = content_version + 1
   where id = p_retired;
end $fn$;

do $$
declare f text;
begin
  foreach f in array array['app_private.allocate_group_customer_code()',
                           'app_private.graduate_party(bigint)',
                           'app_private.assign_location_code(bigint)',
                           'app_private.reassign_party_family(bigint,bigint,date)',
                           'app_private.merge_parties(bigint,bigint)',
                           'app_private.merge_families(bigint,bigint)']
  loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant  execute on function %s to authenticated', f);
  end loop;
end $$;