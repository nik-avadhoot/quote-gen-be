-- ═════ EXACT-RECIPIENT REHEARSAL: always ends in RAISE, so everything rolls back ═════
--
-- Rehearses, in ONE transaction that aborts itself, the single atomic migration
--   supabase/migrations/20260925085415_quote_revision_exact_recipient.sql
--   (applied on main 2026-09-25; the connector assigned this version, not the
--   original file's 20260923170000)
-- against the database's ACTUAL current definitions, then runs the governed
-- S7-R/S9(b)/S9(c)/S9R suite (tests.calculation_writer) on top of it.
--
-- STATUS: run 2026-09-24 against the not-yet-in-use main project with the
-- Product Owner's explicit authorization (no isolated database existed); the
-- migration was inlined at the \ir line and the guard GUC set transaction-locally.
--
-- PREREQUISITE: an isolated, migration-complete database whose
-- app_private.attestation_keys is EMPTY. The S7-R fixture installs its own
-- test key and CP-115 asserts the keyring is empty after the suite, so a
-- database holding a real key cannot host this rehearsal (PRE-7 refuses it).
--
-- ISOLATED DATABASES ONLY (a Supabase branch or a local stack with every earlier
-- migration applied). NEVER the live/main project. Two reasons beyond policy:
--   * the suite writes (and removes) fixture users, Batches and Quote rows;
--   * PostgreSQL sequences are not transactional, so the tail restores every
--     APPLICATION sequence the rehearsal advanced with setval(). That is only
--     safe when no other session is writing those sequences.
-- SEQUENCE SCOPE: only public, app_private and ref_private are captured,
-- restored and verified. auth, storage, realtime, extensions and every
-- PostgreSQL/Supabase-managed schema belong to live platform services (a live
-- sign-in moves auth.refresh_tokens_id_seq on its own); restoring one could make
-- it reissue an id, so the tail refuses to setval anything outside the allowlist.
-- The head refuses to run unless the session was started with
--   PGOPTIONS='-c qos.rehearsal_target=isolated'
--
-- HOW TO RUN (from quote-gen-be/):
--   PGOPTIONS='-c qos.rehearsal_target=isolated' \
--     psql "$ISOLATED_DB_URL" --single-transaction -v ON_ERROR_STOP=1 \
--     -f tests/quote_recipient_rollback_rehearsal.sql
-- The run ALWAYS fails with "REHEARSAL ROLLED BACK. failures=N ..."; the result
-- is that message. failures=0 is a pass. A runner without psql's \ir must
-- inline the migration file at the \ir line, as one batch.
--
-- WHAT IT PROVES (numbers follow the handoff brief):
--   1  the preceding definitions are the expected ones, incl. the Proposed-SKU
--      amendment and the applied Batch customer handoff; empty keyring (PRE-*)
--   2  the exact anchor matched once and send_batch is valid and freezes  (POST-1..4)
--   3  helper, public shims and private definers stay least-privileged     (POST-5..9, S9R-11..13)
--   4  Batch Customer A is frozen, never SKU-owning Family member B       (S9R-2..4)
--   5  a proposed Prospect is a valid recipient                           (S9R-14)
--   6  Party / Family renames cannot change frozen evidence               (S9R-5, S9R-10)
--   7  Issue with omitted recipient fields consumes the frozen identity   (S9C-14)
--   8  mismatching recipient fields are refused, revision unchanged       (S9R-6..8)
--   9  a legacy revision without exact identity is refused               (S9R-9)
--   10 unauthorized / guessed Party access stays refused                 (S9R-1, S9R-7, S9R-13, S9R-15)
--   11 no trial rows, reference-sequence effects, grants or sequence advance remain
--                                                                          (RESIDUE-*)
--   12 the U4 compatibility branch ran only where the correction is missing, and
--      never rewrote the corrected stored S7-R functions                   (DRIFT-*)

-- ═════ HEAD: isolation guard, preconditions and baseline (as the owner) ═════
do $guard$
begin
  if coalesce(current_setting('qos.rehearsal_target', true), '') <> 'isolated' then
    raise exception 'refusing to run: start the session with PGOPTIONS=''-c qos.rehearsal_target=isolated'' against an ISOLATED database';
  end if;
end $guard$;

create temp table qos_rcp_baseline (k text primary key, v jsonb) on commit drop;

do $capture$
declare
  v_def text; v_anchor text; r record; v_seq jsonb := '{}'::jsonb; v_last bigint; v_called boolean;
  v_pre text := '';
begin
  v_anchor := $a$  insert into public.quote_revisions(family_id, source_revision_id, workflow_status, created_by)
    values (v_family, p_source_revision, 'draft', v_actor) returning id into v_revision;$a$;
  v_def := pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    v_pre := v_pre || E'\nPRE-1 send_batch does not carry the revision-insert anchor exactly once';
  end if;
  if position('sku_withdrawn' in v_def) = 0 or position('sku_not_published' in v_def) > 0
     or position('sku_version_unapproved' in v_def) > 0 then
    v_pre := v_pre || E'\nPRE-2 send_batch is not the Proposed-SKU (Amendment 04 D-01) definition';
  end if;
  if to_regprocedure('app_private.resolve_batch_quote_recipient(bigint)') is not null then
    v_pre := v_pre || E'\nPRE-3 the recipient migration is already applied here';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'batches' and column_name = 'customer_party_id') then
    v_pre := v_pre || E'\nPRE-4 the Batch customer handoff (batches.customer_party_id) is not applied';
  end if;
  if position('exact_recipient_identity_unavailable' in
       pg_get_functiondef('app_private.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure)) > 0 then
    v_pre := v_pre || E'\nPRE-5 issue_quote_revision already carries the exact-recipient rule';
  end if;
  if position('''Buyer''' in pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)) = 0 then
    v_pre := v_pre || E'\nPRE-6 tests.__s9c_gates is not the definition the migration splices';
  end if;
  if exists (select 1 from app_private.attestation_keys) then
    v_pre := v_pre || E'\nPRE-7 app_private.attestation_keys is not empty; the S7-R fixture and CP-115 need an empty isolated keyring';
  end if;
  if v_pre <> '' then
    raise exception 'REHEARSAL PRECONDITIONS FAILED (nothing was run):%', v_pre;
  end if;

  -- Privilege and security shape of every function the migrations touch.
  insert into qos_rcp_baseline
  select 'fn:' || p.oid::regprocedure::text,
         jsonb_build_object('acl', coalesce(p.proacl::text, 'default'), 'definer', p.prosecdef,
                            'config', coalesce(p.proconfig::text, 'none'))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where (n.nspname in ('app_private', 'public')
          and p.proname in ('send_batch', 'send_revision_batch', 'issue_quote_revision'))
      or (n.nspname = 'tests' and p.proname in ('__s9b_gates', '__s9c_gates', 'calculation_writer'));

  -- Row counts of every table the suite or the migrations can write.
  insert into qos_rcp_baseline values ('rows', (select jsonb_build_object(
    'quote_families', (select count(*) from public.quote_families),
    'quote_revisions', (select count(*) from public.quote_revisions),
    'calculation_snapshots', (select count(*) from public.calculation_snapshots),
    'quote_items', (select count(*) from public.quote_items),
    'quote_item_delivery_groups', (select count(*) from public.quote_item_delivery_groups),
    'quote_workflow_events', (select count(*) from public.quote_workflow_events),
    'customer_outcome_events', (select count(*) from public.customer_outcome_events),
    'export_events', (select count(*) from public.export_events),
    'export_parts', (select count(*) from public.export_parts),
    'batches', (select count(*) from public.batches),
    'batch_rows', (select count(*) from public.batch_rows),
    'batch_calculations', (select count(*) from public.batch_calculations),
    'parties', (select count(*) from public.parties),
    'party_family_memberships', (select count(*) from public.party_family_memberships),
    'customer_families', (select count(*) from public.customer_families),
    'group_capability_grants', (select count(*) from public.group_capability_grants),
    'plant_capability_grants', (select count(*) from public.plant_capability_grants),
    'app_users', (select count(*) from public.app_users),
    'attestation_keys', (select count(*) from app_private.attestation_keys))));
  insert into qos_rcp_baseline values ('reference_sequences',
    (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) from ref_private.reference_sequences x
      where x.scope_type <> 'batch'));

  -- Application sequences only (see SEQUENCE SCOPE), so the tail can undo
  -- non-transactional advances without touching platform-managed sequences.
  for r in select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.relkind = 'S' and n.nspname = any (array['public', 'app_private', 'ref_private']) loop
    execute format('select last_value, is_called from %I.%I', r.nspname, r.relname) into v_last, v_called;
    v_seq := v_seq || jsonb_build_object(format('%I.%I', r.nspname, r.relname),
                                         jsonb_build_array(v_last, v_called));
  end loop;
  insert into qos_rcp_baseline values ('sequences', v_seq);

  -- The stored S7-R functions the U4 compatibility branch may rewrite.
  insert into qos_rcp_baseline values ('s7r_defs', jsonb_build_object(
    'body', md5(pg_get_functiondef('tests.__s7r_body()'::regprocedure)),
    'teardown', md5(pg_get_functiondef('tests.__s7r_teardown()'::regprocedure))));
end $capture$;

-- ═════ U4 COMPATIBILITY BRANCH (tests schema only; rolled back with everything) ═════
-- Since U4 (20260915100440) create_batch refuses a null Sector. Migration
-- 20260924084505_u4_stored_suite_sector_drift corrects the stored S7-R fixture
-- (and is applied on main), so there this block must SKIP and rewrite nothing.
-- A historical isolated database may predate that correction: only there, attach
-- the fixture's own __S7R Sector to its Family, pass it, and unlink it before
-- teardown deletes the Sector. Any other shape (neither the uncorrected nor the
-- corrected anchor exactly once, or a half-corrected pair) fails closed.
do $drift$
declare v_body text; v_tear text; n_old integer; n_u4 integer; t_rel integer; t_del integer;
  a_old constant text := E'  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, null); reset role;\n';
  a_new constant text := E'  insert into public.customer_family_sectors (family_id, sector_id, created_by) values (v_fam, v_sec, v_owner);\n'
    || E'  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, v_sec); reset role;\n';
  a_u4 constant text := E'  perform tests.__u4_attach_fixture_sector(v_fam, v_sec);\n'
    || E'  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, v_sec); reset role;\n';
  t_old constant text := E'  delete from public.sectors         where sector_code = ''__S7R'';\n';
  t_new constant text := E'  delete from public.customer_family_sectors\n'
    || E'   where sector_id in (select id from public.sectors where sector_code = ''__S7R'');\n'
    || E'  delete from public.sectors         where sector_code = ''__S7R'';\n';
  t_u4 constant text := E'  perform tests.__u4_release_fixture_sector(''__S7R'');\n' || t_old;
begin
  v_body := pg_get_functiondef('tests.__s7r_body()'::regprocedure);
  v_tear := pg_get_functiondef('tests.__s7r_teardown()'::regprocedure);
  n_old := (length(v_body) - length(replace(v_body, a_old, ''))) / length(a_old);
  n_u4  := (length(v_body) - length(replace(v_body, a_u4, ''))) / length(a_u4);
  t_rel := (length(v_tear) - length(replace(v_tear, t_u4, ''))) / length(t_u4);
  t_del := (length(v_tear) - length(replace(v_tear, t_old, ''))) / length(t_old);
  if n_old = 0 and n_u4 = 1 and t_rel = 1 and t_del = 1 then
    insert into qos_rcp_baseline values ('drift_compat', '"skipped: U4 correction 20260924084505 present"');
  elsif n_old = 1 and n_u4 = 0 and t_rel = 0 and t_del = 1 then
    execute replace(v_body, a_old, a_new);
    execute replace(v_tear, t_old, t_new);
    insert into qos_rcp_baseline values ('drift_compat', '"ran: historical null-Sector S7-R fixture compensated"');
  else
    raise exception 'DRIFT-1 unexpected S7-R fixture shape (body: uncorrected % / corrected %, teardown: release % / delete %); refusing to rehearse',
      n_old, n_u4, t_rel, t_del;
  end if;
end $drift$;

-- ═════ THE MIGRATION UNDER REHEARSAL, exactly as it would ship ═════
\ir ../supabase/migrations/20260925085415_quote_revision_exact_recipient.sql

-- ═════ TAIL: structure, privileges, the governed suite, residue, then RAISE ═════
do $rehearse$
declare
  log text := ''; fails int := 0; v_def text; v_ok boolean; r record; v_line text;
  v_ran int := 0; v_s9 int := 0; v_now jsonb; v_seq jsonb; v_last bigint; v_called boolean;
  v_seq_key text; v_base_last bigint; v_base_called boolean; v_changed int := 0; v_nspname text;
  c_new constant text := $a$  insert into public.quote_revisions(
      family_id, source_revision_id, workflow_status, created_by,
      addressee_name, addressee_details)
    select v_family, p_source_revision, 'draft', v_actor,
           recipient.addressee_name, recipient.addressee_details
      from app_private.resolve_batch_quote_recipient(p_batch) recipient
    returning id into v_revision;$a$;
begin
  -- 2: one exact replacement, and the rest of send_batch intact.
  v_def := pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure);
  v_ok := (length(v_def) - length(replace(v_def, c_new, ''))) / length(c_new) = 1;
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-1 send_batch carries the recipient-freezing insert exactly once';
  if not v_ok then fails := fails + 1; end if;
  v_ok := position('values (v_family, p_source_revision, ''draft'', v_actor) returning id into v_revision' in v_def) = 0;
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-2 the unfrozen revision insert is gone';
  if not v_ok then fails := fails + 1; end if;
  v_ok := position('sku_withdrawn' in v_def) > 0 and position('calculation_stale' in v_def) > 0
      and position('freight_reference_mismatch' in v_def) > 0 and position('insert into public.quote_items(' in v_def) > 0;
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-3 the Proposed-SKU, staleness, freight and Item logic survive the replacement';
  if not v_ok then fails := fails + 1; end if;
  v_ok := (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app_private' and p.proname = 'send_batch') = 1;
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-4 replacement created no second send_batch overload';
  if not v_ok then fails := fails + 1; end if;

  -- 3: privileges and security shape unchanged on every pre-existing function.
  for r in select b.k, b.v,
                  (select jsonb_build_object('acl', coalesce(p.proacl::text, 'default'), 'definer', p.prosecdef,
                                             'config', coalesce(p.proconfig::text, 'none'))
                     from pg_proc p where p.oid = to_regprocedure(substr(b.k, 4))) as now_v
             from qos_rcp_baseline b where b.k like 'fn:%' loop
    v_ok := r.now_v is not distinct from r.v
         or (r.k like 'fn:tests.%' and r.now_v->'acl' = r.v->'acl' and r.now_v->'definer' = r.v->'definer');
    log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-5 privileges and definer shape unchanged: ' || substr(r.k, 4);
    if not v_ok then fails := fails + 1; end if;
  end loop;
  v_ok := not has_function_privilege('public', 'app_private.resolve_batch_quote_recipient(bigint)', 'EXECUTE')
      and not has_function_privilege('anon', 'app_private.resolve_batch_quote_recipient(bigint)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'app_private.resolve_batch_quote_recipient(bigint)', 'EXECUTE');
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-6 the recipient helper grants EXECUTE to no application role';
  if not v_ok then fails := fails + 1; end if;
  v_ok := not has_function_privilege('anon', 'public.send_batch(bigint,integer)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.issue_quote_revision(bigint,text,jsonb,date,date)', 'EXECUTE');
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-7 anon still cannot Send or Issue';
  if not v_ok then fails := fails + 1; end if;
  v_ok := not (select p.prosecdef from pg_proc p where p.oid = 'public.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure)
      and (select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p
            where p.oid = 'app_private.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure);
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-8 Issue stays an invoker shim over an empty-search-path definer';
  if not v_ok then fails := fails + 1; end if;
  v_ok := not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'tests' and p.proname like '\_\_s9r\_%'
                         and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                              or has_function_privilege('anon', p.oid, 'EXECUTE')));
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'POST-9 the new S9R test helpers are not callable by application roles';
  if not v_ok then fails := fails + 1; end if;

  -- 4..10: the governed suite, with the S9R gates spliced into S9(b)/S9(c).
  perform set_config('search_path', 'extensions, pg_catalog', true);
  perform extensions.no_plan();
  begin
    for v_line in select * from tests.calculation_writer() loop
      if v_line like 'ok %' or v_line like 'not ok %' then v_ran := v_ran + 1; end if;
      if v_line like 'not ok %' then
        fails := fails + 1; log := log || E'\nFAIL ' || v_line;
      elsif v_line ~ '^ok [0-9]+ - (S9R|S9B|S9C)-' then
        v_s9 := v_s9 + 1; log := log || E'\n' || v_line;
      elsif v_line like '#%' then
        log := log || E'\n  ' || v_line;
      end if;
    end loop;
  exception when others then
    fails := fails + 1;
    log := log || E'\nFAIL the governed suite raised ' || sqlstate || ': ' || sqlerrm;
  end;
  log := log || E'\n-- suite assertions run: ' || v_ran || ', S9B/S9C/S9R passed: ' || v_s9;
  if v_s9 <> 76 then  -- S9B-1..29 + S9C-1..31 + S9R-1..16, every one passing
    fails := fails + 1; log := log || E'\nFAIL expected 76 passing S9B/S9C/S9R assertions, saw ' || v_s9;
  end if;
  perform set_config('search_path', '', true);

  -- 11: residue inside the transaction, before the rollback removes the rest.
  -- The S7-R suite deliberately leaves its five __p2_s7r_* users, their grants
  -- and one Batch-scope reference allocation for the outer rollback (measured
  -- identically on main without this migration), so those are excluded here;
  -- RESIDUE-1b pins the one grant S9R adds to a fixture user.
  select jsonb_build_object(
    'quote_families', (select count(*) from public.quote_families),
    'quote_revisions', (select count(*) from public.quote_revisions),
    'calculation_snapshots', (select count(*) from public.calculation_snapshots),
    'quote_items', (select count(*) from public.quote_items),
    'quote_item_delivery_groups', (select count(*) from public.quote_item_delivery_groups),
    'quote_workflow_events', (select count(*) from public.quote_workflow_events),
    'customer_outcome_events', (select count(*) from public.customer_outcome_events),
    'export_events', (select count(*) from public.export_events),
    'export_parts', (select count(*) from public.export_parts),
    'batches', (select count(*) from public.batches),
    'batch_rows', (select count(*) from public.batch_rows),
    'batch_calculations', (select count(*) from public.batch_calculations),
    'parties', (select count(*) from public.parties),
    'party_family_memberships', (select count(*) from public.party_family_memberships),
    'customer_families', (select count(*) from public.customer_families),
    'group_capability_grants', (select count(*) from public.group_capability_grants g
                                 where g.app_user_id not in (select u.id from public.app_users u
                                                              where u.display_name like '\_\_p2\_s7r\_%')),
    'plant_capability_grants', (select count(*) from public.plant_capability_grants g
                                 where g.app_user_id not in (select u.id from public.app_users u
                                                              where u.display_name like '\_\_p2\_s7r\_%')),
    'app_users', (select count(*) from public.app_users where display_name not like '\_\_p2\_s7r\_%'),
    'attestation_keys', (select count(*) from app_private.attestation_keys)) into v_now;
  v_ok := v_now = (select v from qos_rcp_baseline where k = 'rows');
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'RESIDUE-1 suite teardown left no trial rows or grants: '
    || case when v_ok then 'counts equal baseline' else v_now::text end;
  if not v_ok then fails := fails + 1; end if;
  v_ok := (select coalesce(jsonb_agg(u.display_name || ':' || c.capability_key
                                    order by u.display_name, c.capability_key), '[]'::jsonb)
             from public.group_capability_grants g join public.app_users u on u.id = g.app_user_id
             join public.capabilities c on c.id = g.capability_id
            where u.display_name like '\_\_p2\_s7r\_%')
          = '["__p2_s7r_appr:read_party_master", "__p2_s7r_prop:read_party_master"]'::jsonb;
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'RESIDUE-1b S9R removed its read_party_master grant; only the S7-R fixture''s own group grants remain';
  if not v_ok then fails := fails + 1; end if;
  v_ok := (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) from ref_private.reference_sequences x
            where x.scope_type <> 'batch')
          = (select v from qos_rcp_baseline where k = 'reference_sequences');
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'RESIDUE-2 no Quote reference-sequence effect';
  if not v_ok then fails := fails + 1; end if;
  v_ok := not exists (select 1 from public.parties where left(display_name, 9) = '__p2 s9r ');
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'RESIDUE-3 no S9R fixture Party survives the suite';
  if not v_ok then fails := fails + 1; end if;

  -- 12: the U4 compatibility branch, and the corrected S7-R functions untouched.
  log := log || E'\n-- U4 compatibility branch: ' || (select v #>> '{}' from qos_rcp_baseline where k = 'drift_compat');
  if (select v #>> '{}' from qos_rcp_baseline where k = 'drift_compat') like 'skipped:%' then
    v_ok := md5(pg_get_functiondef('tests.__s7r_body()'::regprocedure))
              = (select v->>'body' from qos_rcp_baseline where k = 's7r_defs')
        and md5(pg_get_functiondef('tests.__s7r_teardown()'::regprocedure))
              = (select v->>'teardown' from qos_rcp_baseline where k = 's7r_defs');
    log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'DRIFT-2 the corrected stored S7-R body and teardown were never rewritten';
    if not v_ok then fails := fails + 1; end if;
  end if;

  -- Sequences are not transactional: put back every APPLICATION sequence the
  -- rehearsal advanced. Keys come only from the allowlisted capture, and each is
  -- re-checked against the allowlist before setval, so a managed sequence
  -- (auth, storage, realtime, extensions, ...) can never be reset.
  v_seq := (select v from qos_rcp_baseline where k = 'sequences');
  for v_seq_key in select jsonb_object_keys(v_seq) order by 1 loop
    v_base_last := (v_seq->v_seq_key->>0)::bigint; v_base_called := (v_seq->v_seq_key->>1)::boolean;
    v_nspname := null;
    select n.nspname into v_nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.oid = to_regclass(v_seq_key) and c.relkind = 'S';
    if v_nspname is null or not (v_nspname = any (array['public', 'app_private', 'ref_private'])) then
      fails := fails + 1; log := log || E'\nFAIL RESIDUE-4 refused to restore a sequence outside the application schemas: ' || v_seq_key;
      continue;
    end if;
    execute format('select last_value, is_called from %s', v_seq_key) into v_last, v_called;
    if v_last is distinct from v_base_last or v_called is distinct from v_base_called then
      v_changed := v_changed + 1;
      perform setval(v_seq_key::regclass, v_base_last, v_base_called);
      log := log || E'\n  # seq ' || v_seq_key
        || ' baseline=' || v_base_last || '/' || v_base_called
        || ' after-suites=' || v_last || '/' || v_called
        || ' advanced=' || case when v_called and v_base_called then (v_last - v_base_last)::text
                                when v_called then (v_last - v_base_last + 1)::text || ' (first call)'
                                else 'n/a' end;
      execute format('select last_value, is_called from %s', v_seq_key) into v_last, v_called;
      log := log || ' restored=' || v_last || '/' || v_called;
    end if;
  end loop;
  log := log || E'\nok   RESIDUE-4 application sequences captured: ' || (select count(*) from jsonb_object_keys(v_seq))
    || ', changed and restored: ' || v_changed;

  -- Prove the restore: every captured application sequence equals its baseline.
  v_ok := true;
  for v_seq_key in select jsonb_object_keys(v_seq) order by 1 loop
    execute format('select last_value, is_called from %s', v_seq_key) into v_last, v_called;
    if v_last is distinct from (v_seq->v_seq_key->>0)::bigint or v_called is distinct from (v_seq->v_seq_key->>1)::boolean then
      v_ok := false; log := log || E'\nFAIL RESIDUE-5 ' || v_seq_key || ' is ' || v_last || '/' || v_called || ' after restore';
    end if;
  end loop;
  log := log || case when v_ok then E'\nok   ' else E'\nFAIL ' end || 'RESIDUE-5 every captured application sequence equals its baseline';
  if not v_ok then fails := fails + 1; end if;

  raise exception 'REHEARSAL ROLLED BACK. failures=% %', fails, log;
end $rehearse$;
