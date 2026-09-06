-- S6-9 (S6-C1, prerequisite): the Batch-row integrity guards must evaluate the
-- invariant, not the caller's view of it.
--
-- FOUND WHILE BUILDING THE AUTHENTICATED PERSONA S6-C1 REQUIRES, which is the
-- point of insisting the gate be an ordinary caller rather than the table owner.
-- Every S6 suite ran as the table owner, where RLS does not apply, so this was
-- invisible: an ordinary Maker cannot add a row to a Batch at all.
--
-- app_private.guard_row_sku_family is SECURITY INVOKER and reads
-- public.party_family_memberships, whose SELECT policy requires the GROUP
-- capability read_party_master. A Maker holds plant_access and make_quote at a
-- plant; nothing in CDM-05 or §7.5 gives them read_party_master. So the guard's
--
--     select m.family_id into v_family from public.party_family_memberships ...
--
-- returned no row, v_family came back null, and the trigger raised
--
--     'the SKU Customer has no current Family membership (CDM-07)'
--
-- for a Party that has a perfectly good current membership. The Batch row was
-- refused, and the message blamed the customer data rather than the caller's read
-- scope. §5.2's invariant was not enforced - it was replaced by an accident of
-- visibility that happened to fail closed.
--
-- guard_row_proposed_construction has the same shape: SECURITY INVOKER over
-- public.constructions, gated by read_construction_library. It returns early when
-- the row cites no proposed Construction, so ordinary rows were unaffected - but
-- a Maker exercising the CDM-13 Quote-specific proposal would have been refused
-- for not being able to READ the Construction rather than for the status rule the
-- guard exists to assert.
--
-- BOTH BECOME SECURITY DEFINER, and that is the correct answer rather than the
-- convenient one. An integrity guard is not an access-control decision. It
-- answers "is this row legal", which is a property of the database, and it must
-- see the database. §7.5 already decides who may write a Batch row - the RLS
-- policy, through can_write_batch - and that decision is untouched here. The
-- guard runs after it and adds a constraint; it was never meant to add a second,
-- accidental read requirement.
--
-- NEITHER GUARD LEAKS ANYTHING. Both return void or raise. Their messages name
-- rules and Family relationships, never a Party, a Family name or an id, so a
-- caller learns only that their own write was illegal - which they must be told
-- for the constraint to mean anything.
--
-- THE COMMERCIAL ALTERNATIVE IS NOT TAKEN HERE. The other way to make an
-- ordinary Maker able to add a Batch row is to grant Makers read_party_master,
-- which widens what every Maker can see across the whole Party master. That is a
-- capability-model decision for the Product Owner under CDM-05, not a technical
-- correction, and this migration deliberately does not make it. The definer fix
-- changes no one's read scope at all.

create or replace function app_private.guard_row_sku_family()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare v_party bigint; v_family bigint; v_batch_family bigint;
begin
  select party_id into v_party from public.skus where id = new.sku_id;
  select family_id into v_batch_family from public.batches where id = new.batch_id;
  select m.family_id into v_family
    from public.party_family_memberships m
   where m.party_id = v_party and m.is_current;

  if v_family is null then
    raise exception 'the SKU Customer has no current Family membership (CDM-07)'
      using errcode = '23514';
  end if;
  if v_family is distinct from v_batch_family then
    raise exception 'the SKU Customer belongs to another Customer Family (CDM-06/DM-187)'
      using errcode = '23514';
  end if;
  return new;
end $fn$;

create or replace function app_private.guard_row_proposed_construction()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare v_status text;
begin
  if new.proposed_construction_version_id is null then
    return new;
  end if;
  select k.status into v_status
    from public.construction_versions cv
    join public.constructions k on k.id = cv.construction_id
   where cv.id = new.proposed_construction_version_id;

  if v_status is distinct from 'proposed' then
    raise exception 'a row Construction reference exists only for a Quote-specific PROPOSED Construction; the published SKU spec version is otherwise sole authority (CDM-13)'
      using errcode = '23514';
  end if;
  return new;
end $fn$;

revoke all on function app_private.guard_row_sku_family() from public, anon, authenticated;
revoke all on function app_private.guard_row_proposed_construction() from public, anon, authenticated;
