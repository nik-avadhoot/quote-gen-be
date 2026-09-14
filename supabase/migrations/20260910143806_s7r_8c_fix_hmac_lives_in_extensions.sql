-- S7-R/8c: fix - hmac() is pgcrypto, and pgcrypto is installed in `extensions`.
--
-- sha256() is a pg_catalog builtin (PostgreSQL 11+) and resolved correctly.
-- hmac() is not: it comes from pgcrypto, which this project installs into the
-- `extensions` schema, so pg_catalog.hmac does not exist. Under
-- search_path = '' the call has to name that schema.
--
-- WHY THE VERIFIER MUST STILL PIN search_path = ''. Leaving `extensions` on the
-- path so hmac resolves by search would make the function that decides whether
-- a price may be written depend on a session-settable variable. The
-- qualification is the point, not an inconvenience.
--
-- Spliced rather than retyped, for the S7-5 reason, and the substitution count
-- is asserted.

do $mig$
declare v_def text; v_cnt int;
begin
  v_def := pg_catalog.pg_get_functiondef(
             'app_private.calculate_batch_row(bigint,integer,text,text)'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, 'pg_catalog.hmac', '')))
           / length('pg_catalog.hmac');
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 pg_catalog.hmac, found %', v_cnt;
  end if;
  execute replace(v_def, 'pg_catalog.hmac', 'extensions.hmac');
end $mig$;

revoke all on function app_private.calculate_batch_row(bigint, integer, text, text) from public, anon;
grant execute on function app_private.calculate_batch_row(bigint, integer, text, text) to authenticated;