-- S4-5: repair the Maker proposal route on construction_versions.
--
-- THE DEFECT. The branch added in S4-1 bounded the Maker route with an inline
-- `exists (select 1 from public.constructions k where k.id = construction_id
-- and k.status = 'proposed')`. A WITH CHECK expression is evaluated as the
-- CALLER, so that subquery is itself subject to constructions_select, which
-- requires read_construction_library - a capability a Maker does not hold. The
-- subquery therefore returned no row, the branch could never be true, and the
-- route was dead policy text promising an authority it could not grant.
--
-- Isolated by changing exactly one variable: granting read_construction_library
-- and nothing else turned the identical INSERT from DENIED into ALLOWED.
--
-- This is an implementation correction, not a commercial decision. §7.5 already
-- approves the Maker route here ("as above"); it simply did not work.
--
-- THE FIX is the mechanism §7.2 already established for exactly this problem: a
-- SECURITY DEFINER helper, outside every exposed schema, that answers the one
-- question the check needs. It is deliberately narrow - one bigint in, one
-- boolean out. It exposes no name, no code, no row, and it cannot enumerate:
-- an unknown id and a published id both answer false. Nothing else about the
-- Construction Library becomes reachable, and read authority is unchanged
-- (FA-5, FA-6 assert that rather than assume it).
create or replace function app_private.construction_is_proposed(p_construction bigint)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (select 1 from public.constructions k
                  where k.id = p_construction
                    and k.status = 'proposed');
$fn$;

revoke all on function app_private.construction_is_proposed(bigint) from public;
revoke all on function app_private.construction_is_proposed(bigint) from anon;
grant execute on function app_private.construction_is_proposed(bigint) to authenticated;

-- The policy is replaced within this one atomic migration, so no moment exists
-- in which construction_versions carries no INSERT policy (§16.1).
--
-- Every other condition is preserved exactly as approved: the master-capability
-- branch is untouched, the proposal branch still requires the caller's own
-- attribution and an active make_quote grant, and the parent must still be
-- `proposed`. One condition is made EXPLICIT rather than left to a check
-- constraint - `approved_by is null` now sits beside `approved_at is null`, so
-- an attempt to insert a pre-approved version is refused BY THE POLICY (42501)
-- instead of by ck_cv_approval_pair (23514). That matters for evidence: a
-- denial must be attributable to the authority check, not to a neighbouring
-- restriction that happens to fire first.
drop policy if exists construction_versions_insert on public.construction_versions;

create policy construction_versions_insert on public.construction_versions for insert to authenticated
  with check (
        (select app_private.has_group_cap('manage_construction_library'))
     or ( approved_at is null
          and approved_by is null
          and created_by = (select app_private.current_app_user())
          and (select app_private.construction_is_proposed(construction_id))
          and exists (select 1
                        from public.plant_capability_grants g
                        join public.capabilities c on c.id = g.capability_id
                       where g.app_user_id = (select app_private.current_app_user())
                         and c.capability_key = 'make_quote'
                         and g.status = 'active') ) );