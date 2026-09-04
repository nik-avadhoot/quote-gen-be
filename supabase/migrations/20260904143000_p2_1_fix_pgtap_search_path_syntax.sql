-- P2-1 defect correction 2: SET search_path = 'a, b' is parsed as ONE schema named
-- "a, b". The list must be unquoted and comma-separated. pgtap is confirmed installed
-- in `extensions`.

alter function tests.access_model()    set search_path = extensions, pg_catalog;
alter function tests.deny_by_default() set search_path = extensions, pg_catalog;
alter function tests.run_all()         set search_path = extensions, pg_catalog;