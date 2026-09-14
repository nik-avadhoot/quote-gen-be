-- S9-P/6: the governed operation for Pricing Date and Pricing Basis Release.
--
-- CDM-27: "The effective default Release is applied automatically for ordinary
-- pricing. MAKER may deliberately choose another approved Release; reasons are
-- optional initially. Calendar gaps warn but allow an approved alternative."
--
-- So the authority gate is can_write_batch - which requires make_quote at the
-- plant, ownership or active collaboration, and the unreleased edit lock. This
-- is a Maker act. Nothing here is a Checker act, and pricing_basis_is_deliberate
-- must never be read as an approval signal.
--
-- VALIDATION RUNS ENTIRELY BEFORE THE WRITE. There is exactly one UPDATE and it
-- is the last statement, so a Release rejected on its last check leaves
-- pricing_date untouched. Writing the date first and validating the Release
-- afterwards would leave a Batch priced as at a date nobody chose - the partial
-- application CP-43 exists to catch.
--
-- CAS IS THE CALLER'S FILTER, HERE THE FUNCTION'S. trg_batch_content_version ->
-- guard_content_version raises 23514 if a caller sends content_version and
-- otherwise increments it. The expected-version match is therefore expressed as
-- a WHERE filter, and zero rows updated means a stale read. Because this
-- function IS the caller, the filter is part of the governed operation rather
-- than left to an API client to remember.
--
-- p_release = null REVERTS to the automatic default, re-resolved against the new
-- date, and resets pricing_basis_is_deliberate. Reverting is a first-class act,
-- not something a Maker has to reconstruct.
--
-- AN EXPLICIT SELECTION EQUAL TO THE DEFAULT IS STILL DELIBERATE. p_release
-- non-null sets the flag even when the id happens to equal today's automatic
-- default - the same discipline S8 established for a freight override typed
-- equal to the matrix rate: equal numbers from different tiers are not
-- interchangeable, and the authority the user exercised is the thing recorded.
--
-- A WITHDRAWN RELEASE is refused by the same status='approved' test that refuses
-- a draft: one check, three rejected states, no separate branch to drift.

create or replace function app_private.set_batch_pricing_basis(
  p_batch bigint,
  p_expected_content_version integer,
  p_pricing_date date,
  p_release bigint default null)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint; v_plant bigint; v_status text; v_release bigint; v_deliberate boolean;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.can_write_batch(p_batch) then
    raise exception 'the Batch edit lock and make_quote at its plant are required'
      using errcode = '42501';
  end if;

  select b.plant_id, b.status into v_plant, v_status
    from public.batches b where b.id = p_batch;
  if v_plant is null then
    raise exception 'unknown Batch' using errcode = 'P0002';
  end if;
  if v_status is distinct from 'working' then
    raise exception 'the Pricing Basis may only be set while the Batch is working'
      using errcode = '22023';
  end if;
  if p_pricing_date is null then
    raise exception 'a Pricing Date is required' using errcode = '22023';
  end if;

  if p_release is null then
    -- revert to the automatic default for the new date. At most one can exist.
    select r.id into v_release
      from public.pricing_basis_releases r
     where r.plant_id = v_plant
       and r.status = 'approved'
       and r.is_automatic_default
       and daterange(r.effective_from, r.effective_until, '[]') @> p_pricing_date;
    v_deliberate := false;
  else
    if not exists (select 1 from public.pricing_basis_releases r
                    where r.id = p_release and r.status = 'approved') then
      raise exception 'the selected Pricing Basis Release is not approved'
        using errcode = '22023';
    end if;
    if not exists (select 1 from public.pricing_basis_releases r
                    where r.id = p_release and r.plant_id = v_plant) then
      raise exception 'the selected Pricing Basis Release belongs to another plant'
        using errcode = '22023';
    end if;
    if not exists (select 1 from public.pricing_basis_releases r
                    where r.id = p_release
                      and daterange(r.effective_from, r.effective_until, '[]') @> p_pricing_date) then
      raise exception 'the selected Pricing Basis Release does not cover that Pricing Date'
        using errcode = '22023';
    end if;
    v_release := p_release;
    v_deliberate := true;
  end if;

  -- the one write. The expected-version filter is the compare-and-swap.
  update public.batches
     set pricing_date                = p_pricing_date,
         pricing_basis_release_id    = v_release,
         pricing_basis_is_deliberate = v_deliberate
   where id = p_batch
     and content_version = p_expected_content_version;

  if not found then
    raise exception 'the Batch changed since it was read' using errcode = 'PT409';
  end if;
end $fn$;

-- the thin invoker shim: authenticated executes this, never the definer
create or replace function public.set_batch_pricing_basis(
  p_batch bigint,
  p_expected_content_version integer,
  p_pricing_date date,
  p_release bigint default null)
returns void language sql set search_path = '' as $fn$
  select app_private.set_batch_pricing_basis(
           p_batch, p_expected_content_version, p_pricing_date, p_release);
$fn$;

revoke all on function app_private.set_batch_pricing_basis(bigint,integer,date,bigint)
  from public, anon, authenticated;
revoke all on function public.set_batch_pricing_basis(bigint,integer,date,bigint)
  from public, anon;
grant execute on function public.set_batch_pricing_basis(bigint,integer,date,bigint)
  to authenticated;