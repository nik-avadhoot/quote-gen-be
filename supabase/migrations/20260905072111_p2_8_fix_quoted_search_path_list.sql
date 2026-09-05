-- P2-8 correction: `set search_path = 'extensions, pg_catalog'` is not a two-schema
-- path. The quotes make it ONE identifier - a schema literally named
-- "extensions, pg_catalog", which does not exist - so the pgTAP assertions
-- stopped resolving and tests.run_all() died with `function no_plan() does not
-- exist`. Advisor 0011 was satisfied either way, because it only checks that
-- proconfig is set, not that the value names real schemas. A passing advisor is
-- not a working search_path.
--
-- Three functions took the bad value: definer_placement (from the 0011 fix),
-- and bootstrap_routing and run_all (written the same way in the same session).
-- The correct form is the unquoted list every other tests.* function carries.

alter function tests.definer_placement() set search_path = extensions, pg_catalog;
alter function tests.bootstrap_routing() set search_path = extensions, pg_catalog;
alter function tests.run_all()          set search_path = extensions, pg_catalog;