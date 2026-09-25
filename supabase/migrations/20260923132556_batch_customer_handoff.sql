-- One selected Customer/Prospect per newly created Batch. Older Batches remain
-- readable without inventing a member from their Family identity.
-- Membership is validated at creation, not enforced as a permanent composite
-- FK: a later governed Family reassignment must not rewrite historical Batches.
alter table public.batches
  add column customer_party_id bigint null
    references public.parties(id) on delete restrict;
create index ix_batch_customer_party on public.batches (customer_party_id)
  where customer_party_id is not null;
alter table public.delivery_groups add column destination_text text null;
alter table public.delivery_groups add column billing_text text null;

-- Creation is one transaction: identity, initial terms and delivery context
-- are saved together. A typed destination is quote-specific route context,
-- never an assertion that a Customer Location has been approved.
create or replace function app_private.create_batch_handoff(
  p_family bigint, p_plant bigint, p_sector bigint, p_party bigint,
  p_ship_to bigint, p_bill_to bigint, p_destination_text text, p_billing_text text,
  p_payment_terms_days integer
) returns bigint
language plpgsql security definer set search_path = '' as $fn$
declare v_batch bigint; v_pg bigint; v_dg bigint;
begin
  -- This definer can see master rows that the caller's RLS would hide. Match
  -- the established selection boundary before resolving any guessed IDs.
  if app_private.current_app_user() is null
     or not app_private.has_group_cap('read_party_master')
     or not app_private.has_plant_cap(p_plant, 'make_quote') then
    raise exception 'read_party_master and make_quote at the producing Plant are required'
      using errcode = '42501';
  end if;
  perform 1 from public.parties p
    join public.party_family_memberships m on m.party_id = p.id
    join public.customer_families f on f.id = m.family_id
    where p.id = p_party
      and ((p.lifecycle_state = 'customer' and p.status = 'active')
        or (p.lifecycle_state = 'prospect' and p.status in ('proposed', 'active')))
      and f.status in ('proposed', 'active')
      and m.family_id = p_family and m.is_current
    for share of p, m, f;
  if not found then
    raise exception 'select a quoteable Customer or Prospect in the current Family'
      using errcode = '22023';
  end if;
  if p_payment_terms_days is null or p_payment_terms_days not in (30, 45, 60, 90) then
    raise exception 'payment terms must be 30, 45, 60 or 90 days'
      using errcode = '22023';
  end if;
  if p_ship_to is not null then
    perform 1 from public.customer_locations l
    where l.id = p_ship_to and l.party_id = p_party
      and l.status = 'active' and l.ship_to_eligible
    for share;
    if not found then
      raise exception 'delivery location must be active, eligible and belong to the selected Customer'
        using errcode = '22023';
    end if;
  end if;
  if p_bill_to is not null then
    perform 1 from public.customer_locations l
    where l.id = p_bill_to and l.party_id = p_party
      and l.status = 'active' and l.bill_to_eligible
    for share;
    if not found then
      raise exception 'billing location must be active, eligible and belong to the selected Customer'
        using errcode = '22023';
    end if;
  end if;
  if p_ship_to is null and nullif(btrim(p_destination_text), '') is null then
    raise exception 'a delivery destination is required' using errcode = '22023';
  end if;
  if p_bill_to is null and nullif(btrim(p_billing_text), '') is null then
    raise exception 'a billing destination is required' using errcode = '22023';
  end if;
  if length(coalesce(p_destination_text, '')) > 500
     or length(coalesce(p_billing_text, '')) > 500 then
    raise exception 'destination text must be at most 500 characters'
      using errcode = '22023';
  end if;

  v_batch := app_private.create_batch(p_family, p_plant, p_sector);
  update public.batches set customer_party_id = p_party where id = v_batch;
  select id into strict v_pg from public.pricing_groups where batch_id = v_batch;
  update public.pricing_groups set payment_terms_days = p_payment_terms_days
    where id = v_pg;
  select id into strict v_dg from public.delivery_groups where batch_id = v_batch;
  update public.delivery_groups
     set bill_to_location_id = p_bill_to,
         ship_to_location_id = p_ship_to,
         destination_text = nullif(btrim(p_destination_text), ''),
         billing_text = nullif(btrim(p_billing_text), '')
   where id = v_dg;
  return v_batch;
end $fn$;

create or replace function public.create_batch_handoff(
  p_family bigint, p_plant bigint, p_sector bigint, p_party bigint,
  p_ship_to bigint, p_bill_to bigint, p_destination_text text, p_billing_text text,
  p_payment_terms_days integer
) returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.create_batch_handoff(
    p_family, p_plant, p_sector, p_party, p_ship_to, p_bill_to,
    p_destination_text, p_billing_text, p_payment_terms_days);
$fn$;

revoke all on function app_private.create_batch_handoff(bigint,bigint,bigint,bigint,bigint,bigint,text,text,integer)
  from public, anon;
grant execute on function app_private.create_batch_handoff(bigint,bigint,bigint,bigint,bigint,bigint,text,text,integer)
  to authenticated;
revoke all on function public.create_batch_handoff(bigint,bigint,bigint,bigint,bigint,bigint,text,text,integer)
  from public, anon;
grant execute on function public.create_batch_handoff(bigint,bigint,bigint,bigint,bigint,bigint,text,text,integer)
  to authenticated;
