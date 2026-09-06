-- S5-1 fix: the Payment Terms map guard covered DELETE, which contradicts the
-- standard this programme already accepted and breaks the §4.9 cascade.
--
-- S4-1 stated the rule and gave the reason: "DELETE is deliberately NOT
-- trigger-blocked. It is governed exactly as every Family A and Family B table
-- governs it - no DELETE grant and no DELETE policy, so no role reaching the
-- table through PostgREST can issue one (CDM-31). Adding a trigger block here
-- would be stricter than the standard accepted at 217/217 and would leave the
-- regression fixtures unable to clean up after themselves."
--
-- S5-1 then did exactly that. Two concrete consequences, both real rather than
-- theoretical:
--
--   1. §4.9 makes payment_interest_map_entries cascade from its version, because
--      a draft version and its entries are one editing unit. A BEFORE DELETE
--      guard fires on the cascade too, so deleting even a DRAFT version whose
--      status had since changed would have been blocked - the cascade §4.9
--      approves could not complete.
--   2. The fixture could not tear itself down, which is how this surfaced.
--
-- The guard now covers INSERT and UPDATE only. Nothing is weakened: MD-19 still
-- proves an approved map cannot gain an entry, and MD-3/MD-3a still prove no
-- role reaching the table through the API holds any DELETE path at all.

create or replace function app_private.guard_map_entry_follows_version()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_status text;
begin
  select status into v_status
    from public.calculation_default_versions
   where id = new.calculation_default_version_id;
  if v_status is distinct from 'draft' then
    raise exception 'the Payment Terms map may only be edited while its version is draft (found %)',
      coalesce(v_status,'unknown') using errcode = '23514';
  end if;
  return new;
end $fn$;

drop trigger if exists trg_pime_follows_version on public.payment_interest_map_entries;

create trigger trg_pime_follows_version
  before insert or update on public.payment_interest_map_entries
  for each row execute function app_private.guard_map_entry_follows_version();