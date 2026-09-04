-- =====================================================================
-- SYNTHETIC BASELINE RECONSTRUCTION - NOT AN ORIGINAL HISTORICAL MIGRATION
-- =====================================================================
-- Slice S0d. This file does NOT record a change that was ever applied to
-- the remote project through migration history. It reconstructs objects
-- that already existed in the live database but were created OUT OF BAND,
-- outside migration history, and therefore appear in none of the three
-- recovered historical migrations.
--
-- Purpose: make a fresh-environment replay reproduce the live prerequisite,
-- so that 20260904114045_s0b_revoke_execute_rls_auto_enable.sql - which
-- revokes EXECUTE on this function - does not fail with 42883
-- undefined_function on a clean database.
--
-- Provenance: transcribed verbatim from read-only catalogue evidence of the
-- LIVE project (pg_get_functiondef, pg_event_trigger). No improvement, no
-- reformatting of the function body, no unrelated object.
--
-- This SQL was deliberately NOT executed against the remote project, because
-- the objects already exist there. The version was instead marked applied in
-- remote migration history as a metadata repair. Its `statements` column in
-- supabase_migrations.schema_migrations is therefore NULL - which is the
-- durable marker distinguishing this synthetic baseline from the genuinely
-- applied migrations that carry their SQL.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

-- Event trigger, reconstructed from pg_event_trigger:
--   evtname   = ensure_rls
--   evtevent  = ddl_command_end
--   evttags   = {CREATE TABLE, CREATE TABLE AS, SELECT INTO}   -> WHEN TAG IN (...)
--   evtenabled= 'O' (origin), which is the DEFAULT state of a newly created
--               event trigger, so no ALTER EVENT TRIGGER ... ENABLE is needed
--               and none is added.
-- No grants are issued here. On a fresh project the platform default ACL for
-- functions in `public` re-creates the same anon/authenticated/service_role
-- EXECUTE grants the live database had, which the later S0b migration revokes.
CREATE EVENT TRIGGER ensure_rls
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  EXECUTE FUNCTION public.rls_auto_enable();
