-- P2-12: the seeded plants are the authoritative Plant Master, and a plant
-- assignment may only ever name one of them.
--
-- Two things were previously true only by convention. First, nothing stopped a
-- grant referencing an INACTIVE plant - the FK checks existence, not status.
-- Second, the administration route accepted a free-text plant string; that is
-- fixed in the application, but an application-layer fix is not an integrity
-- rule, so the database now enforces it too.
--
-- Enforced in two places on purpose. The RLS predicate refuses the write for an
-- ordinary caller, which gives the right error at the right layer. The trigger
-- refuses it for EVERY writer including definer code and service_role, which is
-- what makes it an invariant rather than a policy. Neither is redundant: RLS
-- alone is bypassable by privileged paths, and a trigger alone would let the
-- policy drift.
--
-- Deliberately NOT added: any create, edit or deactivate operation for the Plant
-- Master itself. The canonical brief seeds `plants` as a Family A table and
-- approves no maintenance for it, so maintenance stays DEFERRED and the Plant
-- Master view is read-only. No plant deletion semantics are invented here: once
-- a plant is referenced by a grant the FK is ON DELETE RESTRICT, so physical
-- deletion already fails, and retiring a plant is a status change that needs an
-- approved rule before it is built.

create or replace function app_private.enforce_active_plant_grant()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare v_status text;
begin
  select p.status into v_status from public.plants p where p.id = new.plant_id;
  if not found then
    raise exception 'unknown plant' using errcode = '23503';
  end if;
  if v_status <> 'active' then
    raise exception 'plant % is not active and cannot receive new assignments', v_status
      using errcode = '23514';
  end if;
  return new;
end $fn$;

revoke all on function app_private.enforce_active_plant_grant() from public, anon, authenticated;

drop trigger if exists pgrant_active_plant_only on public.plant_capability_grants;
create trigger pgrant_active_plant_only
  before insert on public.plant_capability_grants
  for each row execute function app_private.enforce_active_plant_grant();

-- Same rule expressed where an ordinary caller meets it. Replaced in place so
-- PC-1 / F-4 still see exactly one permissive policy per action.
drop policy if exists pgrant_insert on public.plant_capability_grants;
create policy pgrant_insert on public.plant_capability_grants
  for insert to authenticated
  with check (
    (select app_private.has_group_cap('administer_users'))
    and exists (select 1 from public.plants p
                 where p.id = plant_id and p.status = 'active'));