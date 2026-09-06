-- S5-3 fix: three assertion defects in tests.pricing_basis(). The schema was
-- correct in all three cases; the gates were not measuring what they claimed.
--
-- PB-6a matched the constraint definition against a literal fragment. PostgreSQL
-- renders the predicate as "WHERE ((is_automatic_default AND (status = ...)))" -
-- doubled parentheses - so the LIKE never matched. Replaced by a regex over the
-- two facts that matter, which no longer depends on how the planner prints.
--
-- PB-10 claimed to prove the composite FK binds a Release to its own plant, but
-- the PUN rate version it cited was still DRAFT. guard_release_components_approved
-- rejected it first, with 23514, so the gate would have passed for entirely the
-- wrong reason had the expected code matched - and proved nothing about plant
-- binding. The PUN component is now approved first, so the composite FK is the
-- only rule left that can reject, and 23503 means what the gate says it means.
-- This is the same failure mode the S4-5 review named: a denial is worthless as
-- evidence unless you know which rule produced it.
--
-- PB-20 expected an error where correct behaviour is silence. For `authenticated`
-- the UPDATE policy's envelope is `status in ('draft','approved')`, so a withdrawn
-- row is filtered out and the statement changes nothing without raising - an
-- RLS-filtered UPDATE is not an error. The gate now reads the row back instead of
-- trusting the absence of an exception, and PB-20a adds what the original was
-- reaching for: the trigger refuses the same revival AS THE TABLE OWNER, where
-- no policy applies.

do $rw$
declare
  v_def text; v_out text; v_oid oid;
  v_old1 text := $q$    (select pg_get_constraintdef(oid) like '%WHERE (is_automatic_default AND%'$q$;
  v_new1 text := $q$    (select pg_get_constraintdef(oid) ~ 'WHERE .*is_automatic_default.*status'$q$;

  v_old2 text := $q$  -- cross-plant component: a NAG Release may not cite a PUN rate version
  begin$q$;
  v_new2 text := $q$  -- Cross-plant component. The PUN rate version is APPROVED first, deliberately:
  -- otherwise guard_release_components_approved rejects it for being draft, the
  -- composite FK is never reached, and the gate would pass for the wrong reason
  -- while proving nothing about plant binding.
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_approver, v_pun, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','approve_commercial_master');
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  update public.rate_set_versions set status = 'approved' where id = v_rsv_pun;
  reset role;
  return next is((select status from public.rate_set_versions where id = v_rsv_pun), 'approved',
                 'PB-9b the PUN component is approved, so only the plant binding can reject next');
  begin$q$;

  v_old3 text := $q$  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.pricing_basis_releases set status = 'approved' where id = v_rel;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'PB-20 withdrawn is terminal - corrections create replacements, never revivals (CDM-26)');$q$;
  v_new3 text := $q$  -- Withdrawn is terminal, and it is enforced twice over. For `authenticated`
  -- the policy envelope excludes terminal rows, so the statement matches nothing
  -- and changes nothing - silently, which is why this reads the row back rather
  -- than trusting the absence of an error.
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  update public.pricing_basis_releases set status = 'approved' where id = v_rel;
  reset role;
  return next is((select status from public.pricing_basis_releases where id = v_rel), 'withdrawn',
    'PB-20 withdrawn is terminal for authenticated - the policy envelope excludes it');

  begin
    update public.pricing_basis_releases set status = 'approved' where id = v_rel;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'PB-20a and the trigger refuses the same revival AS THE TABLE OWNER (CDM-26)');$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'tests' and p.proname = 'pricing_basis';
  if v_oid is null then
    raise exception 'tests.pricing_basis() not found' using errcode = '55000';
  end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old1 in v_def) = 0 then raise exception 'PB-6a fragment not found'  using errcode='55000'; end if;
  if position(v_old2 in v_def) = 0 then raise exception 'PB-10 fragment not found'  using errcode='55000'; end if;
  if position(v_old3 in v_def) = 0 then raise exception 'PB-20 fragment not found'  using errcode='55000'; end if;

  v_out := replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
  execute v_out;

  v_def := pg_get_functiondef(v_oid);
  if position('PB-9b' in v_def) = 0 or position('PB-20a' in v_def) = 0
     or position($q$~ 'WHERE .*is_automatic_default$q$ in v_def) = 0 then
    raise exception 'one of the three replacements did not take' using errcode = '55000';
  end if;
end $rw$;