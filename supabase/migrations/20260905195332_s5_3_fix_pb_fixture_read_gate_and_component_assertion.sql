-- S5-3 fix: two corrections to tests.pricing_basis(), applied as guarded
-- replacements so the change is legible and cannot silently hit the wrong text.
--
-- WHAT WENT WRONG, and what it teaches. The fixture approved its four component
-- versions as the approver persona, but that persona held no READ capability.
-- The group-wide masters (sector_versions, calculation_default_versions) are
-- read-gated by a group capability, and PostgreSQL applies SELECT policies to an
-- UPDATE ... WHERE as well as the UPDATE policy's own USING. With the rows
-- invisible, the statement matched nothing and changed nothing - silently, since
-- an RLS-filtered UPDATE is not an error. The two group components stayed draft,
-- and PB-9's component guard then correctly refused the Release built from them.
--
-- So the schema was right and the fixture was wrong, and the property is worth
-- stating plainly: YOU CANNOT APPROVE WHAT YOU CANNOT READ. Least privilege on
-- the read side constrains the write side too, which is a feature rather than an
-- obstacle - but it means an approver must be granted the read capability for
-- the master area they approve in.
--
-- Fix 1 grants read_party_master to all three Pricing Basis personas.
-- Fix 2 replaces PB-8, which checked only the rate component, with an assertion
-- over ALL FOUR. A one-component check is what let two silently-unapproved
-- components through to be discovered three gates later, by a different rule.

do $rw$
declare
  v_def text; v_out text; v_oid oid;
  v_old1 text := '  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_both, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in (''plant_access'',''propose_commercial_master'',''approve_commercial_master'');';
  v_new1 text := '  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_both, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in (''plant_access'',''propose_commercial_master'',''approve_commercial_master'');

  -- You cannot approve what you cannot read: an UPDATE ... WHERE applies SELECT
  -- policies as well as the UPDATE policy, so an approver with no read
  -- capability matches no row on the read-gated group masters and silently
  -- changes nothing.
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select u, c.id, v_owner
    from unnest(array[v_proposer, v_approver, v_both]) u
    cross join public.capabilities c
   where c.capability_key = ''read_party_master'';';
  v_old2 text := '  return next is((select status from public.rate_set_versions where id=v_rsv), ''approved'',
                 ''PB-8 the component fixtures are approved through their own matrices'');';
  v_new2 text := '  return next is(
    (select count(*)::int from (
       select status from public.rate_set_versions            where id = v_rsv
       union all select status from public.freight_set_versions   where id = v_fsv
       union all select status from public.sector_versions        where id = v_sv
       union all select status from public.calculation_default_versions where id = v_cdv) s
      where s.status = ''approved''), 4,
    ''PB-8 ALL FOUR component fixtures are approved through their own matrices'');';
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'tests' and p.proname = 'pricing_basis';
  if v_oid is null then
    raise exception 'tests.pricing_basis() not found' using errcode = '55000';
  end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old1 in v_def) = 0 then
    raise exception 'the persona grant block was not found verbatim' using errcode = '55000';
  end if;
  if position(v_old2 in v_def) = 0 then
    raise exception 'the PB-8 assertion was not found verbatim' using errcode = '55000';
  end if;

  v_out := replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
  execute v_out;

  v_def := pg_get_functiondef(v_oid);
  if position('read_party_master' in v_def) = 0 then
    raise exception 'the read grant did not take' using errcode = '55000';
  end if;
  if position('ALL FOUR component fixtures' in v_def) = 0 then
    raise exception 'the PB-8 replacement did not take' using errcode = '55000';
  end if;
end $rw$;