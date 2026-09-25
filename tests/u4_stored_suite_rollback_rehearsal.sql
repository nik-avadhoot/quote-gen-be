-- ═════ U4 STORED-SUITE DRIFT REHEARSAL: always ends in RAISE, so everything rolls back ═════
--
-- Rehearses, in ONE transaction that aborts itself, the tests-only migration
--   supabase/migrations/20260924084505_u4_stored_suite_sector_drift.sql
-- against the database's ACTUAL installed suites, then runs every suite it
-- corrects and proves each one now executes its assertions instead of raising
-- 22023 'a Batch requires one Customer Family Sector' during fixture setup.
--
-- TARGET: an explicitly authorized database with every earlier migration
-- applied, an EMPTY app_private.attestation_keys (the S7-R suite's CP-115) and
-- no concurrent writers (sequences are restored with setval, which is not
-- transactional). A previous authorization to rehearse elsewhere does not
-- carry over. The head refuses to run unless the session was started with
--   PGOPTIONS='-c qos.rehearsal_target=isolated'
--
-- HOW TO RUN (from quote-gen-be/):
--   PGOPTIONS='-c qos.rehearsal_target=isolated' \
--     psql "$REHEARSAL_DB_URL" --single-transaction -v ON_ERROR_STOP=1 \
--     -f tests/u4_stored_suite_rollback_rehearsal.sql
-- The run ALWAYS fails with "REHEARSAL ROLLED BACK. failures=N ..."; failures=0
-- is a pass. A runner without psql's \ir must inline the migration at the \ir
-- line as one batch (and may set the guard with set_config(..., true)).
--
-- WHAT IT PROVES
--   PRE-*      U4 is active, the drift is present exactly as expected, keyring empty
--   POST-*     no positive null-Sector create_batch survives; FS-6/FS-17 keep theirs;
--              no product function, product privilege or table grant changed;
--              the helpers are owner-only invokers
--   SUITE-*    each corrected suite runs assertions, none fail, none raise
--   NEG-*      FS-6 and FS-17 (authorization refusals with a null Sector) still pass
--   RESIDUE-*  no fixture Sector, Family link, Family or Batch survives; sequences restored

do $guard$
begin
  if coalesce(current_setting('qos.rehearsal_target', true), '') <> 'isolated' then
    raise exception 'refusing to run: start the session with PGOPTIONS=''-c qos.rehearsal_target=isolated'' against an AUTHORIZED rehearsal database';
  end if;
end $guard$;

create temp table qos_u4_baseline (k text primary key, v jsonb) on commit drop;

do $capture$
declare v_pre text := ''; v_last bigint; v_called boolean; r record; v_seq jsonb := '{}'::jsonb; v_n int;
begin
  if position('a Batch requires one Customer Family Sector' in
       pg_get_functiondef('app_private.create_batch(bigint,bigint,bigint)'::regprocedure)) = 0 then
    v_pre := v_pre || E'\nPRE-1 the U4 create_batch Sector requirement is not installed';
  end if;
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
    lateral regexp_matches(pg_get_functiondef(p.oid), 'create_batch\([^)]*null\)', 'g')
   where n.nspname = 'tests';
  if v_n <> 10 then
    v_pre := v_pre || format(E'\nPRE-2 expected 10 null-Sector create_batch calls in tests (8 positive + FS-6/FS-17), found %s', v_n);
  end if;
  if to_regprocedure('tests.__u4_mint_fixture_sector(bigint,text)') is not null then
    v_pre := v_pre || E'\nPRE-3 the U4 stored-suite correction is already applied here';
  end if;
  if exists (select 1 from app_private.attestation_keys) then
    v_pre := v_pre || E'\nPRE-4 app_private.attestation_keys is not empty; the S7-R suite (CP-115) needs an empty keyring';
  end if;
  if exists (select 1 from public.sectors where sector_code like '\_\_U4F\_%') then
    v_pre := v_pre || E'\nPRE-5 a __U4F_ fixture Sector already exists';
  end if;
  if v_pre <> '' then
    raise exception 'REHEARSAL PRECONDITIONS FAILED (nothing was run):%', v_pre;
  end if;

  -- Every non-tests function: definition, ACL, security mode and search path.
  insert into qos_u4_baseline values ('product_functions', (
    select to_jsonb(md5(string_agg(p.oid::regprocedure::text || '|' || coalesce(p.proacl::text, 'default') || '|'
                                   || p.prosecdef || '|' || coalesce(p.proconfig::text, 'none') || '|'
                                   || md5(pg_get_functiondef(p.oid)), E'\n' order by p.oid::regprocedure::text)))
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app_private', 'ref_private') and p.prokind = 'f'));
  -- Every table/view grant and RLS switch in the application schemas.
  insert into qos_u4_baseline values ('product_relations', (
    select to_jsonb(md5(string_agg(c.oid::regclass::text || '|' || coalesce(c.relacl::text, 'default') || '|'
                                   || c.relrowsecurity || '|' || c.relforcerowsecurity, E'\n' order by c.oid::regclass::text)))
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'app_private', 'ref_private') and c.relkind in ('r', 'v', 'p')));
  insert into qos_u4_baseline values ('policies', (
    select to_jsonb(md5(coalesce(string_agg(schemaname || '.' || tablename || '.' || policyname || '|' || cmd || '|'
                                   || coalesce(qual, '') || '|' || coalesce(with_check, ''), E'\n'
                                   order by schemaname, tablename, policyname), '')))
      from pg_policies where schemaname in ('public', 'app_private', 'ref_private')));
  insert into qos_u4_baseline values ('rows', (select jsonb_build_object(
    'sectors', (select count(*) from public.sectors),
    'sector_versions', (select count(*) from public.sector_versions),
    'customer_family_sectors', (select count(*) from public.customer_family_sectors),
    'customer_families', (select count(*) from public.customer_families),
    'batches', (select count(*) from public.batches),
    'attestation_keys', (select count(*) from app_private.attestation_keys))));

  -- Application sequences only: auth/realtime/storage belong to live platform
  -- services, and restoring them with setval could make them reissue an id.
  for r in select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.relkind = 'S' and n.nspname in ('public', 'app_private', 'ref_private') loop
    execute format('select last_value, is_called from %I.%I', r.nspname, r.relname) into v_last, v_called;
    v_seq := v_seq || jsonb_build_object(format('%I.%I', r.nspname, r.relname), jsonb_build_array(v_last, v_called));
  end loop;
  insert into qos_u4_baseline values ('sequences', v_seq);
end $capture$;

-- ═════ THE MIGRATION UNDER REHEARSAL, exactly as it would ship ═════
\ir ../supabase/migrations/20260924084505_u4_stored_suite_sector_drift.sql

-- ═════ TAIL: structure, the corrected suites, residue, then RAISE ═════
do $rehearse$
declare
  log text := ''; fails int := 0; v_ok boolean; v_n int; v_line text; v_suite text;
  v_ran int; v_bad int; v_err text; v_neg int := 0; v_total int := 0;
  v_seq jsonb; v_seq_key text; v_last bigint; v_called boolean; v_restored text := ''; v_now jsonb;
begin
  -- POST: the durable correction is in place and nothing outside tests moved.
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
    lateral regexp_matches(pg_get_functiondef(p.oid), 'create_batch\([^)]*null\)', 'g')
   where n.nspname = 'tests';
  v_ok := v_n = 2;
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end
    || format('POST-1 only the two deliberate null-Sector refusal calls remain (%s)', v_n);
  if not v_ok then fails := fails + 1; end if;

  v_ok := (select to_jsonb(md5(string_agg(p.oid::regprocedure::text || '|' || coalesce(p.proacl::text, 'default') || '|'
                                   || p.prosecdef || '|' || coalesce(p.proconfig::text, 'none') || '|'
                                   || md5(pg_get_functiondef(p.oid)), E'\n' order by p.oid::regprocedure::text)))
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('public', 'app_private', 'ref_private') and p.prokind = 'f')
          = (select v from qos_u4_baseline where k = 'product_functions');
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-2 no product function, privilege, security mode or search path changed (create_batch included)';
  if not v_ok then fails := fails + 1; end if;

  v_ok := (select to_jsonb(md5(string_agg(c.oid::regclass::text || '|' || coalesce(c.relacl::text, 'default') || '|'
                                   || c.relrowsecurity || '|' || c.relforcerowsecurity, E'\n' order by c.oid::regclass::text)))
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname in ('public', 'app_private', 'ref_private') and c.relkind in ('r', 'v', 'p'))
          = (select v from qos_u4_baseline where k = 'product_relations')
      and (select to_jsonb(md5(coalesce(string_agg(schemaname || '.' || tablename || '.' || policyname || '|' || cmd || '|'
                                   || coalesce(qual, '') || '|' || coalesce(with_check, ''), E'\n'
                                   order by schemaname, tablename, policyname), '')))
             from pg_policies where schemaname in ('public', 'app_private', 'ref_private'))
          = (select v from qos_u4_baseline where k = 'policies');
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-3 no table grant, RLS switch or policy changed';
  if not v_ok then fails := fails + 1; end if;

  v_ok := not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'tests' and p.proname like '\_\_u4\_%'
                         and (p.prosecdef or has_function_privilege('anon', p.oid, 'EXECUTE')
                              or has_function_privilege('authenticated', p.oid, 'EXECUTE')))
      and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'tests' and p.proname like '\_\_u4\_%') = 3;
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-4 the three U4 fixture helpers are owner-only invokers';
  if not v_ok then fails := fails + 1; end if;

  -- SUITE: each corrected suite must now run its assertions.
  -- One plan for all suites, as tests.run_all() does; each suite runs in its
  -- own subtransaction so one raising suite cannot hide another's result.
  perform set_config('search_path', 'extensions, pg_catalog', true);
  perform extensions.no_plan();
  foreach v_suite in array array['calculation_writer', 'calculation_persistence', 'batch_locks', 'batch_profile',
                                 'batch_set_cardinality', 'family_f_security', 'interest_authority'] loop
    v_ran := 0; v_bad := 0; v_err := null;
    begin
      for v_line in execute format('select * from tests.%I()', v_suite) loop
        if v_line like 'ok %' or v_line like 'not ok %' then v_ran := v_ran + 1; end if;
        if v_line like 'not ok %' then
          v_bad := v_bad + 1; log := log || E'\nFAIL   ' || v_suite || ': ' || v_line;
        end if;
        if v_line ~ '^ok [0-9]+ - FS-(6|17) nor may they create a Batch' then v_neg := v_neg + 1; end if;
      end loop;
    exception when others then
      v_err := sqlstate || ': ' || sqlerrm;
    end;
    v_total := v_total + v_ran;
    v_ok := v_err is null and v_bad = 0 and v_ran > 0;
    log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end
      || format('SUITE %s ran %s assertions, %s not ok%s', v_suite, v_ran, v_bad,
                case when v_err is null then '' else ', raised ' || v_err end);
    if not v_ok then fails := fails + 1; end if;
  end loop;
  perform set_config('search_path', '', true);

  v_ok := v_neg = 2;
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end
    || format('NEG-1 FS-6 and FS-17 (null-Sector calls refused on authority) still pass (%s of 2)', v_neg);
  if not v_ok then fails := fails + 1; end if;

  -- RESIDUE: what this correction creates must be gone inside the transaction.
  select jsonb_build_object(
    'sectors', (select count(*) from public.sectors),
    'sector_versions', (select count(*) from public.sector_versions),
    'customer_family_sectors', (select count(*) from public.customer_family_sectors),
    'customer_families', (select count(*) from public.customer_families),
    'batches', (select count(*) from public.batches),
    'attestation_keys', (select count(*) from app_private.attestation_keys)) into v_now;
  v_ok := v_now = (select v from qos_u4_baseline where k = 'rows');
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'RESIDUE-1 no fixture Sector, Family link, Family or Batch survives: '
    || case when v_ok then 'counts equal baseline' else v_now::text end;
  if not v_ok then fails := fails + 1; end if;
  v_ok := not exists (select 1 from public.sectors where sector_code like '\_\_U4F\_%' or sector_code in ('__S7R', '__S9P'));
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'RESIDUE-2 no __U4F_, __S7R or __S9P fixture Sector survives';
  if not v_ok then fails := fails + 1; end if;

  v_seq := (select v from qos_u4_baseline where k = 'sequences');
  for v_seq_key in select jsonb_object_keys(v_seq) loop
    execute format('select last_value, is_called from %s', v_seq_key) into v_last, v_called;
    if v_last is distinct from (v_seq->v_seq_key->>0)::bigint or v_called is distinct from (v_seq->v_seq_key->>1)::boolean then
      perform setval(v_seq_key::regclass, (v_seq->v_seq_key->>0)::bigint, (v_seq->v_seq_key->>1)::boolean);
      v_restored := v_restored || ' ' || v_seq_key;
    end if;
  end loop;
  log := log || E'\nok   RESIDUE-3 sequences restored to baseline:' || coalesce(nullif(v_restored, ''), ' none advanced');
  log := log || E'\n-- corrected suites ran ' || v_total || ' assertions in total';

  raise exception 'REHEARSAL ROLLED BACK. failures=% %', fails, log;
end $rehearse$;
