-- S9-P/5: the narrowly authorised create_batch amendment (D-O).
--
-- app_private.create_batch is closed, accepted S6 work. This amendment does TWO
-- things and nothing else:
--
--   1. sets pricing_date to the PRODUCING PLANT's local date, and
--   2. resolves and sets pricing_basis_release_id from the automatic default,
--      leaving it NULL when no default covers that date.
--
-- Everything else is byte-for-byte the S6 body: the capability check, the
-- unknown-Family check, the edit-lock insert, the default Pricing Group and
-- Delivery Group, the first Batch Profile version, the signature and the return.
-- The amendment is additive within the existing transaction.
--
-- WHY THE PLANT'S LOCAL DATE AND NOT current_date. S12.4 already fixes FY
-- derivation to "the producing plant's local event date, never a user-editable
-- Pricing or Quote Date, computed from now() at time zone plants.timezone"
-- (CDM-34). Using the server's date would put the Pricing Date and the Batch
-- Reference's FY on two different clocks, which around midnight and around
-- 31 March would disagree - and the Batch Reference is assigned by
-- assign_batch_reference in the same INSERT, from that same rule.
--
-- WHY NO `order by ... limit 1` ON THE RELEASE LOOKUP. ex_pbr_default_no_overlap
-- is an exclusion constraint over (plant_id =, daterange(effective_from,
-- effective_until, '[]') &&) where (is_automatic_default and status='approved').
-- Two overlapping automatic defaults for one plant CANNOT exist, so the select
-- can never return two rows. A limit would silently pick one had that guarantee
-- ever failed; its absence turns such a failure into a loud error instead.
--
-- WHY A CALENDAR GAP DOES NOT REFUSE. CDM-27: "Calendar gaps warn but allow an
-- approved alternative." A master-data gap is not the Maker's fault, and the
-- Batch stays fully editable - rows, groups and specification work all proceed.
-- Calculate and Send refuse later, where the missing basis actually bites.

create or replace function app_private.create_batch(
  p_family bigint, p_plant bigint, p_sector bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_batch bigint; v_pg bigint;
        v_pricing_date date; v_release bigint;
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

  -- S9-P: the Pricing Date is the producing plant's local date (S12.4/CDM-34).
  select (now() at time zone p.timezone)::date into v_pricing_date
    from public.plants p where p.id = p_plant;

  -- S9-P: the automatic default Release covering that date, if one exists.
  -- At most one can exist - ex_pbr_default_no_overlap guarantees it.
  select r.id into v_release
    from public.pricing_basis_releases r
   where r.plant_id = p_plant
     and r.status = 'approved'
     and r.is_automatic_default
     and daterange(r.effective_from, r.effective_until, '[]') @> v_pricing_date;

  insert into public.batches (batch_reference, family_id, plant_id, owner_user_id,
                              sector_id, status, created_by,
                              pricing_date, pricing_basis_release_id)
  values ('pending', p_family, p_plant, v_me, p_sector, 'working', v_me,
          v_pricing_date, v_release)
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