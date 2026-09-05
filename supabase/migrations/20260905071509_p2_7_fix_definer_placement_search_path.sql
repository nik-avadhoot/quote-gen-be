-- P2-7 correction: restore the pinned search_path on tests.definer_placement().
--
-- The P-6/P-7 rewrite used `create or replace function` without repeating the
-- SET clause. Postgres does not carry function attributes across a replace, so
-- the pin was silently dropped and advisor 0011 fired on it - my own guard
-- migration regressed the property that G-3/N-8 exist to protect.
--
-- The value restored is the one every other tests.* function carries:
-- `extensions, pg_catalog`, which is what lets the unqualified pgTAP assertions
-- (is/ok/finish) resolve, since pgTAP is installed into `extensions`.
--
-- Body is unchanged from 20260905071316 - this migration alters only the
-- search_path attribute.

alter function tests.definer_placement() set search_path = 'extensions, pg_catalog';