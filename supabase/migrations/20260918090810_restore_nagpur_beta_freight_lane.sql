-- Restore the approved Nagpur beta freight lane deleted by test cleanup.
--
-- WHY. Wave B (20260918040738) inserted exactly one governed freight entry into
-- approved Version 1 of 'Nagpur Limited Beta Freight Set': NAG -> Ship-to
-- G0080-001-03 (party 245), 2.0000 per kg, and asserted it. The unscoped test
-- cleanup corrected by 20260918090723 later deleted it while the aggregate ran
-- on production, leaving the version, and Pricing Basis Release 'Nagpur Limited
-- Beta 2026-09-17' that uses it, with no freight lane.
--
-- WHAT. Re-insert the identical Product Owner approved content into the SAME
-- approved version, so the Release in use keeps its identity. created_by is the
-- version's own creator (the Wave B seed actor). The row id and created_at are
-- new and honestly show the restoration; this comment is its record.
--
-- HOW. trg_fe_follows_version admits entries only into a draft version. It is
-- disabled for this one insert and re-enabled in the same transaction; any
-- failure rolls both back. The migration is a no-op where the seeded version
-- does not exist or already holds exactly the approved lane, and refuses any
-- other state.

alter table public.freight_entries disable trigger trg_fe_follows_version;

do $restore$
declare
  v_nag     bigint;
  v_version bigint;
  v_actor   bigint;
  v_ship_to bigint;
  v_count   integer;
begin
  select p.id into strict v_nag
    from public.plants p
   where p.plant_code = 'NAG' and p.status = 'active';

  select v.id, v.created_by into v_version, v_actor
    from public.freight_set_versions v
    join public.freight_sets s on s.id = v.freight_set_id
   where s.plant_id = v_nag
     and s.name = 'Nagpur Limited Beta Freight Set'
     and v.version_no = 1
     and v.status = 'approved';

  if v_version is null then
    raise notice 'no approved Nagpur beta Freight Set version here; nothing to restore';
    return;
  end if;

  if not exists (
    select 1 from public.pricing_basis_releases r
     where r.freight_set_version_id = v_version
       and r.plant_id = v_nag
       and r.release_name = 'Nagpur Limited Beta 2026-09-17'
  ) then
    raise exception 'the beta Release no longer uses this Freight Set version; refusing to restore';
  end if;

  -- The same Ship-to the seed resolved.
  select l.id into strict v_ship_to
    from public.customer_locations l
    join public.parties p on p.id = l.party_id
   where p.id = 245
     and p.customer_code = 'G0080-001'
     and l.location_code = 'G0080-001-03'
     and l.status = 'active'
     and l.ship_to_eligible;

  select count(*) into v_count
    from public.freight_entries where freight_set_version_id = v_version;

  if v_count = 1 and exists (
    select 1 from public.freight_entries
     where freight_set_version_id = v_version
       and plant_id = v_nag and origin_plant_id = v_nag
       and destination_location_id = v_ship_to and rate = 2.0000
  ) then
    raise notice 'approved Nagpur lane already present; nothing to restore';
    return;
  end if;

  if v_count <> 0 then
    raise exception 'Freight Set version % holds % unexpected entries; refusing to restore', v_version, v_count;
  end if;

  insert into public.freight_entries (
    freight_set_version_id, plant_id, origin_plant_id,
    destination_location_id, rate, created_by
  ) values (
    v_version, v_nag, v_nag, v_ship_to, 2.0000, v_actor
  );

  select count(*) into v_count
    from public.freight_entries where freight_set_version_id = v_version;
  if v_count <> 1 then
    raise exception 'expected exactly one governed Freight entry after restore, found %', v_count;
  end if;
end $restore$;

alter table public.freight_entries enable trigger trg_fe_follows_version;
