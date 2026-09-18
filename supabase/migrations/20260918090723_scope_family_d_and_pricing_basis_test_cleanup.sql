-- Scope the Family D and Pricing Basis test cleanups to their own fixtures.
--
-- WHY. tests.family_d_plant_masters() and tests.pricing_basis() were written
-- while the live commercial masters were empty, and cleaned up with plant-wide
-- predicates:
--
--   delete from public.freight_entries where plant_id in (v_nag, v_pun);
--   delete from public.pricing_basis_releases where plant_id in (v_nag, v_pun)
--     and (release_name like '\_\_p2 pb%' or release_name is null);
--
-- After the Wave B seed (20260918040738) the aggregate tests.run_all() ran
-- against production and the first statement deleted the one governed Nagpur
-- freight lane from approved Freight Set Version 1 of 'Nagpur Limited Beta
-- Freight Set'. The second would delete any real unnamed NAG/PUN release.
--
-- WHAT. Every freight entry and every release either suite creates hangs off
-- the suite's own freight set (v_fs): entries are written to its version and
-- every fixture release names that version. Cleanup is therefore scoped to
-- versions of v_fs, which removes exactly the fixtures and nothing real.
--
-- HOW. The functions are rewritten in place from their current definitions.
-- Each replaced statement must occur exactly once, or nothing changes. No
-- assertion, fixture or grant is altered; CREATE OR REPLACE keeps ownership
-- and privileges. The restore of the deleted lane is a separate migration.

do $scope$
declare
  c_fe_old  constant text := 'delete from public.freight_entries where plant_id in (v_nag, v_pun);';
  c_fe_new  constant text := E'delete from public.freight_entries where freight_set_version_id in\n'
                          || E'    (select id from public.freight_set_versions where freight_set_id = v_fs);';
  c_pbr_old constant text := E'delete from public.pricing_basis_releases where plant_id in (v_nag, v_pun)\n'
                          || E'    and (release_name like ''\\_\\_p2 pb%'' or release_name is null);';
  c_pbr_new constant text := E'delete from public.pricing_basis_releases where freight_set_version_id in\n'
                          || E'    (select id from public.freight_set_versions where freight_set_id = v_fs);';
  v_def text;
  r record;
begin
  for r in
    select * from (values
      ('family_d_plant_masters', c_fe_old,  c_fe_new),
      ('pricing_basis',          c_fe_old,  c_fe_new),
      ('pricing_basis',          c_pbr_old, c_pbr_new)
    ) as t(fn, old_text, new_text)
  loop
    v_def := pg_catalog.pg_get_functiondef(format('tests.%I()', r.fn)::regprocedure);
    if (length(v_def) - length(replace(v_def, r.old_text, ''))) / length(r.old_text) <> 1 then
      raise exception 'tests.%(): expected exactly one plant-wide cleanup statement to scope', r.fn;
    end if;
    execute replace(v_def, r.old_text, r.new_text);
  end loop;

  -- No plant-wide cleanup may survive in either suite.
  if exists (
    select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'tests'
       and p.proname in ('family_d_plant_masters', 'pricing_basis')
       and p.prosrc ~* 'delete\s+from\s+public\.(freight_entries|pricing_basis_releases)\s+where\s+plant_id'
  ) then
    raise exception 'a plant-wide freight or release cleanup remains';
  end if;
end $scope$;
