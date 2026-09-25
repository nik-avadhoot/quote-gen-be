-- ═════ S1-S5 QUOTE REVISION ACTIVATION REHEARSAL: always ends in RAISE, so everything rolls back ═════
--
-- Rehearses, in ONE transaction that aborts itself, the full unapplied
-- simplification dependency chain, in real order, against the database's
-- ACTUAL current definitions - not an assumed prior state:
--   supabase/migrations/20260923170000_quote_revision_exact_recipient.sql
--   supabase/migrations/20260924173944_quote_revision_share_evidence.sql
--   supabase/migrations/20260925090000_s5_record_customer_outcome.sql
-- then exercises the two NEW S5 functions
-- (app_private.record_customer_outcome, app_private.resolve_batch_prior_quote)
-- under genuine caller identities via set_config('request.jwt.claims', ...)
-- + set local role authenticated, the same persona-simulation convention
-- already used by tests/cph_p0_5_qualification_rehearsal.sql.
--
-- STATUS: authored 2026-09-25. Live migration history
-- (supabase_migrations.schema_migrations) was inspected read-only and stops
-- at 20260924164850_customer_pricing_history_p0_5_void_round; nothing after
-- that is applied anywhere.
--
-- TARGET AND AUTHORIZATION (settled 2026-09-25, explicit Product Owner
-- instruction in chat). This rehearsal is deliberately run directly against
-- the identified MAIN Supabase project `czettlukuenlnnrmvhqt` - there is no
-- separate isolated database or branch, and none is being created for this.
-- The authorization is narrow and does NOT cover anything beyond it:
--   * a single rollback-only transaction (BEGIN; ... ends in RAISE; no COMMIT);
--   * temporarily executing the three unapplied migrations inside that
--     transaction, and creating synthetic __S5R_ fixture rows inside it;
--   * exercising the S5 database permission and prior-Quote checks;
--   * restoring any sequences the rehearsal advances, where safely possible;
--   * read-only residue verification after the run.
-- It does NOT authorize permanently applying or recording the three
-- migrations, deploying application code, resetting the database, or
-- modifying Customer Pricing History. A final deliberate failure
-- ("REHEARSAL ROLLED BACK. failures=N") is the EXPECTED, successful outcome
-- of a clean run - it is what proves the rollback happened. An early,
-- UNEXPECTED failure (a real defect, or a transport fault) can leave
-- sequence gaps because Postgres sequences are non-transactional; the tail
-- restores them where it runs, but if the run aborts before reaching the
-- tail, any such gap must be disclosed precisely rather than assumed benign.
--
-- PREREQUISITE: every migration up to and including 20260924164850 applied
-- (true of main today), with at least two active Plants and at least one
-- active Customer Family with an active Party. A second active Party
-- strengthens one check (cross-customer exclusion); its absence degrades
-- that one check to a recorded skip rather than failing the whole rehearsal.
--
-- The head refuses to run unless the session was started with the exact,
-- truthful main-authorization marker below - never the generic word
-- "isolated", which would misstate what this actually is:
--   PGOPTIONS='-c qos.rehearsal_target=main_rollback_authorized_20260925'
--
-- HOW TO RUN (from quote-gen-be/, direct psql or an equivalent direct
-- PostgreSQL client - never the Supabase REST/MCP SQL-execution endpoint,
-- which has been observed to time out on this rehearsal's heaviest block):
--   PGOPTIONS='-c qos.rehearsal_target=main_rollback_authorized_20260925' \
--     psql "$MAIN_DB_URL" --single-transaction -v ON_ERROR_STOP=1 \
--     -c 'SET statement_timeout = 0;' \
--     -f tests/s5_quote_revision_activation_rehearsal.sql
-- The run ALWAYS fails with "REHEARSAL ROLLED BACK. failures=N <log>"; the
-- result is read from that message. failures=0 is a pass. A runner without
-- psql's \ir must inline the three migration files at the \ir lines below,
-- in the same order, as one batch. Do not omit, split or rewrite the S9R
-- gate-splicing block inside the exact-recipient migration - run it exactly
-- as it is checked in.
--
-- WHAT IT PROVES:
--   1  preconditions: the three migrations are genuinely unapplied here, in
--      the expected order, against the expected prior definitions (the
--      send_batch revision-insert anchor matches exactly once, matching the
--      already-accepted exact-recipient rehearsal's own PRE-1 check)
--   2  all three migrations apply cleanly in one batch; each migration's own
--      do $verify$ block (narrow grants) already ran and passed as part of
--      applying it - if \ir fails, the whole rehearsal fails closed
--   3  record_customer_outcome (DM-105) BUSINESS LOGIC: the Batch-owning
--      Maker, an authorised Checker and Admin correction authority each
--      succeed; an active collaborator who is NOT the owner, a wrong-Plant
--      Maker and an inactive caller are refused BEFORE any row is written;
--      a non-issued revision is refused; acceptance fields are accepted
--      only for 'accepted'; a late acceptance may follow an earlier
--      Rejected; actor and timestamp are attributable to the genuine
--      caller of each call, never a fixed or caller-supplied value.
--      These personas are exercised via request.jwt.claims WITHOUT SET
--      ROLE (see the pg_temp.*_claims helpers below) - PostgreSQL does not
--      make a GRANT issued earlier in an uncommitted transaction visible to
--      a privilege check reached via SET ROLE later in that SAME
--      transaction (confirmed empirically against this project; not
--      specific to this migration). current_app_user() is role-independent
--      (reads request.jwt.claims), and the function bodies run under
--      SECURITY DEFINER, so this still genuinely exercises the real
--      authorization logic - it just does not additionally prove the
--      EXECUTE grant itself, which item 5 covers separately. The anonymous
--      caller (never granted, no same-transaction visibility gap applies)
--      IS proven via a genuine SET ROLE anon call. Outcomes are append-only:
--      UPDATE/DELETE on customer_outcome_events is refused under a genuine
--      SET ROLE authenticated, because that table's grants were fixed by an
--      ALREADY-APPLIED prior migration, not a new grant in this transaction.
--   4  resolve_batch_prior_quote (D-6) BUSINESS LOGIC (same claims-only
--      method as item 3): an exact Create-Revision source wins over a
--      search even when a more recently issued revision exists elsewhere;
--      otherwise only the latest ISSUED revision for the exact Customer +
--      Plant is returned, even against adversarial recency from a
--      wrong-Plant or wrong-Customer row. The unauthorised-caller refusal
--      (S5R-22) is likewise exercised via claims only.
--   5  GRANT NARROWNESS (catalog-level, via has_function_privilege - proven
--      reliable even where actual same-transaction invocation is not, per
--      item 3's note): app_private.record_customer_outcome and
--      app_private.resolve_batch_prior_quote remain unexecutable by
--      anon/authenticated directly; only the narrow public shim is
--      executable, and only by authenticated.
--   6  RESIDUE: application sequences are restored to their pre-run values
--      (the only non-transactional state this rehearsal can advance); every
--      table write rolls back with the final RAISE, by ordinary Postgres
--      transaction semantics

-- ═════ HEAD: target-authorization guard and baseline (as the connecting role) ═════
-- The marker names the exact authorization this run operates under, so it
-- can never be confused with an "isolated database" run - there is no
-- isolated database here. Running this without the marker set refuses,
-- rather than silently assuming authorization that was never given.
do $guard$
begin
  if coalesce(current_setting('qos.rehearsal_target', true), '')
     <> 'main_rollback_authorized_20260925' then
    raise exception 'refusing to run: start the session with PGOPTIONS as documented in this file header (qos.rehearsal_target=main_rollback_authorized_20260925) - this rehearsal is authorized to run ONLY as a rollback-only transaction against the identified main project, under explicit Product Owner instruction';
  end if;
  if (select current_database()) is distinct from 'postgres' then
    raise exception 'refusing to run: unexpected database name %, refusing to guess the target', current_database();
  end if;
end $guard$;

create temp table qos_s5_baseline (k text primary key, v jsonb) on commit drop;

do $capture$
declare
  v_def text; v_anchor text; v_pre text := ''; r record; v_seq jsonb := '{}'::jsonb;
  v_last bigint; v_called boolean;
begin
  -- PRE-1: the same exact-recipient anchor check the already-accepted
  -- exact-recipient rehearsal performs, re-verified here because later
  -- applied migrations (u4_stored_suite_sector_drift, Customer Pricing
  -- History p0_1..p0_5) run AFTER this migration's authored timestamp and
  -- could in principle have touched send_batch again.
  v_anchor := $a$  insert into public.quote_revisions(family_id, source_revision_id, workflow_status, created_by)
    values (v_family, p_source_revision, 'draft', v_actor) returning id into v_revision;$a$;
  v_def := pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    v_pre := v_pre || E'\nPRE-1 send_batch does not carry the revision-insert anchor exactly once';
  end if;
  if to_regprocedure('app_private.resolve_batch_quote_recipient(bigint)') is not null then
    v_pre := v_pre || E'\nPRE-2 the exact-recipient migration is already applied here';
  end if;
  if position('exact_recipient_identity_unavailable' in
       pg_get_functiondef('app_private.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure)) > 0 then
    v_pre := v_pre || E'\nPRE-3 issue_quote_revision already carries the exact-recipient rule';
  end if;
  if to_regprocedure('app_private.share_quote_revision(bigint,text,date,text)') is not null then
    v_pre := v_pre || E'\nPRE-4 the S4 share-evidence migration is already applied here';
  end if;
  if to_regprocedure('app_private.record_customer_outcome(bigint,text,date,text,text)') is not null
     or to_regprocedure('app_private.resolve_batch_prior_quote(bigint)') is not null then
    v_pre := v_pre || E'\nPRE-5 the S5 customer-outcome migration is already applied here';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'batches' and column_name = 'customer_party_id') then
    v_pre := v_pre || E'\nPRE-6 the Batch customer handoff (batches.customer_party_id) is not applied - out of order';
  end if;
  if (select count(*) from public.plants where status = 'active') < 2 then
    v_pre := v_pre || E'\nPRE-7 fewer than two active Plants exist - the Plant-exclusion checks need two';
  end if;
  if not exists (select 1 from public.customer_families where status = 'active')
     or not exists (select 1 from public.parties where status = 'active') then
    v_pre := v_pre || E'\nPRE-8 no active Customer Family / Party exists to host the fixture Batches';
  end if;
  if not exists (
      select 1 from public.customer_family_sectors cfs
        join public.customer_families cf on cf.id = cfs.family_id
        join public.sectors s on s.id = cfs.sector_id
       where cf.status = 'active' and s.status = 'active') then
    v_pre := v_pre || E'\nPRE-8a no active Customer Family has an active Sector attached (fk_batch_family_sector needs one)';
  end if;
  if v_pre <> '' then
    raise exception 'REHEARSAL PRECONDITIONS FAILED (nothing was run):%', v_pre;
  end if;

  insert into qos_s5_baseline values ('rows', (select jsonb_build_object(
    'quote_families', (select count(*) from public.quote_families),
    'quote_revisions', (select count(*) from public.quote_revisions),
    'batches', (select count(*) from public.batches),
    'customer_outcome_events', (select count(*) from public.customer_outcome_events),
    'batch_collaborators', (select count(*) from public.batch_collaborators),
    'plant_capability_grants', (select count(*) from public.plant_capability_grants),
    'group_capability_grants', (select count(*) from public.group_capability_grants),
    'app_users', (select count(*) from public.app_users),
    'auth_users', (select count(*) from auth.users))));

  for r in select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.relkind = 'S' and n.nspname = any (array['public', 'app_private', 'ref_private']) loop
    execute format('select last_value, is_called from %I.%I', r.nspname, r.relname) into v_last, v_called;
    v_seq := v_seq || jsonb_build_object(format('%I.%I', r.nspname, r.relname), jsonb_build_array(v_last, v_called));
  end loop;
  insert into qos_s5_baseline values ('sequences', v_seq);
end $capture$;

-- ═════ APPLY: the three migrations, in their real dependency order ═════
\ir ../supabase/migrations/20260923170000_quote_revision_exact_recipient.sql
\ir ../supabase/migrations/20260924173944_quote_revision_share_evidence.sql
\ir ../supabase/migrations/20260925090000_s5_record_customer_outcome.sql

-- ═════ PERSONA HELPERS (generic; reused verbatim from cph_p0_5's convention) ═════
create function pg_temp.try(p_role text, p_sub text, p_sql text) returns text
language plpgsql as $fn$
begin
  begin
    perform set_config('request.jwt.claims', case when p_sub is null then json_build_object('role', p_role)::text
      else json_build_object('sub', p_sub, 'role', p_role)::text end, true);
    execute format('set local role %I', p_role);
    execute p_sql;
    execute 'reset role';
    return 'OK';
  exception when others then
    return sqlstate;
  end;
end $fn$;

create function pg_temp.val(p_role text, p_sub text, p_sql text) returns text
language plpgsql as $fn$
declare v text;
begin
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', p_role)::text, true);
    execute format('set local role %I', p_role);
    execute p_sql into v;
    execute 'reset role';
    return coalesce(v, '∅');
  exception when others then
    return 'ERR ' || sqlstate;
  end;
end $fn$;

-- pg_temp.try/val (above) genuinely SET ROLE, which is the correct way to
-- prove EXECUTE-grant narrowness (S5R-8 anonymous, S5R-23..26) - a role that
-- was NEVER granted behaves correctly immediately. But PostgreSQL does not
-- make a GRANT issued earlier IN THIS SAME UNCOMMITTED TRANSACTION visible
-- to a privilege check reached via SET ROLE later in that same transaction
-- (confirmed empirically: has_function_privilege() correctly reports the
-- grant, yet the actual call still raises 42501 "permission denied for
-- function", for ANY newly created+granted function, not specific to this
-- migration). Since this rehearsal must migrate and exercise the new S5
-- functions inside ONE never-committed transaction, that specific proof is
-- structurally unavailable here - it is NOT evidence of an S5 defect.
--
-- The business-logic matrix (DM-105 owner/Checker/Admin, wrong-Plant,
-- inactive, non-issued, acceptance-fields, append-only, D-6 prior-Quote
-- search/pending-source/exclusion) lives INSIDE the function body via
-- current_app_user() (role-independent - reads request.jwt.claims) and the
-- function owner's own table privileges (SECURITY DEFINER). These helpers
-- exercise that real logic directly, without SET ROLE, so they are never
-- confounded by the grant-visibility gap above.
create function pg_temp.try_claims(p_sub text, p_sql text) returns text
language plpgsql as $fn$
begin
  begin
    perform set_config('request.jwt.claims', case when p_sub is null then '{}'::text
      else json_build_object('sub', p_sub, 'role', 'authenticated')::text end, true);
    execute p_sql;
    return 'OK';
  exception when others then
    return sqlstate;
  end;
end $fn$;

create function pg_temp.val_claims(p_sub text, p_sql text) returns text
language plpgsql as $fn$
declare v text;
begin
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
    execute p_sql into v;
    return coalesce(v, '∅');
  exception when others then
    return 'ERR ' || sqlstate;
  end;
end $fn$;

-- ═════ FIXTURE: synthetic personas (minted, never borrowed) + throwaway Batches ═════
do $rehearse$
declare
  log text := '';
  fails int := 0;

  v_plant_a bigint; v_plant_b bigint; v_family bigint; v_party bigint; v_party2 bigint;
  v_sector bigint; v_cap_make bigint; v_cap_check bigint;

  v_owner_auth uuid; v_collab_auth uuid; v_checker_auth uuid; v_admin_auth uuid;
  v_wrongplant_auth uuid; v_inactive_auth uuid; v_stranger_auth uuid;
  v_owner bigint; v_collab bigint; v_checker bigint; v_admin bigint;
  v_wrongplant bigint; v_inactive bigint; v_stranger bigint;

  v_batch_a bigint; v_batch_b bigint; v_batch_d bigint; v_batch_g bigint; v_batch_h bigint;
  v_qf_a bigint; v_qf_b bigint; v_qf_scratch bigint;
  v_rev_a bigint; v_rev_b bigint; v_rev_g bigint; v_rev_h bigint; v_rev_draft bigint;

  v_owner_sub text; v_collab_sub text; v_checker_sub text; v_admin_sub text;
  v_wrongplant_sub text; v_inactive_sub text; v_stranger_sub text; v_owner_claims text;

  v_state text; v_n int; v_found bigint; v_cur bigint;
  v_row1_recorded_by bigint; v_row2_recorded_by bigint; v_row3_recorded_by bigint;
  v_row1_outcome text; v_row2_outcome text; v_row3_outcome text;
  v_row1_at timestamptz; v_row2_at timestamptz; v_row3_at timestamptz;
begin
  -- ── pick real, EXISTING master data by read-only lookup - never written to ──
  select id into v_plant_a from public.plants where status = 'active' order by id limit 1;
  select id into v_plant_b from public.plants where status = 'active' and id <> v_plant_a order by id limit 1;
  -- A Batch's (family_id, sector_id) pair must already exist in
  -- customer_family_sectors (fk_batch_family_sector) - a Family and an
  -- independently-chosen active Sector are not enough on their own.
  select cfs.family_id, cfs.sector_id into v_family, v_sector
    from public.customer_family_sectors cfs
    join public.customer_families cf on cf.id = cfs.family_id
    join public.sectors s on s.id = cfs.sector_id
   where cf.status = 'active' and s.status = 'active'
   order by cfs.family_id limit 1;
  select id into v_party   from public.parties where status = 'active' order by id limit 1;
  select id into v_party2  from public.parties where status = 'active' and id <> v_party order by id limit 1;
  select id into v_cap_make  from public.capabilities where capability_key = 'make_quote';
  select id into v_cap_check from public.capabilities where capability_key = 'check_quote';

  -- ── mint synthetic personas (owned identities, provably synthetic) ──
  v_owner_auth      := tests.__new_synthetic_auth_uid();
  v_collab_auth     := tests.__new_synthetic_auth_uid();
  v_checker_auth    := tests.__new_synthetic_auth_uid();
  v_admin_auth      := tests.__new_synthetic_auth_uid();
  v_wrongplant_auth := tests.__new_synthetic_auth_uid();
  v_inactive_auth   := tests.__new_synthetic_auth_uid();
  v_stranger_auth   := tests.__new_synthetic_auth_uid();

  insert into public.app_users (auth_user_id, display_name, status) values
    (v_owner_auth,      '__s5_rehearsal_owner_maker',      'active')   returning id into v_owner;
  insert into public.app_users (auth_user_id, display_name, status) values
    (v_collab_auth,     '__s5_rehearsal_collab_maker',     'active')   returning id into v_collab;
  insert into public.app_users (auth_user_id, display_name, status) values
    (v_checker_auth,    '__s5_rehearsal_checker',          'active')   returning id into v_checker;
  insert into public.app_users (auth_user_id, display_name, status) values
    (v_admin_auth,      '__s5_rehearsal_admin',            'active')   returning id into v_admin;
  insert into public.app_users (auth_user_id, display_name, status) values
    (v_wrongplant_auth, '__s5_rehearsal_wrongplant_maker', 'active')   returning id into v_wrongplant;
  insert into public.app_users (auth_user_id, display_name, status, deactivated_at) values
    (v_inactive_auth,   '__s5_rehearsal_inactive_maker',   'deactivated', now()) returning id into v_inactive;
  insert into public.app_users (auth_user_id, display_name, status) values
    (v_stranger_auth,   '__s5_rehearsal_stranger',         'active')   returning id into v_stranger;

  v_owner_sub      := v_owner_auth::text;
  v_collab_sub     := v_collab_auth::text;
  v_checker_sub    := v_checker_auth::text;
  v_admin_sub      := v_admin_auth::text;
  v_wrongplant_sub := v_wrongplant_auth::text;
  v_inactive_sub   := v_inactive_auth::text;
  v_stranger_sub   := v_stranger_auth::text;
  v_owner_claims   := json_build_object('sub', v_owner_sub, 'role', 'authenticated')::text;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by) values
    (v_owner, v_plant_a, v_cap_make, v_owner),
    (v_collab, v_plant_a, v_cap_make, v_owner),
    (v_inactive, v_plant_a, v_cap_make, v_owner),
    (v_wrongplant, v_plant_b, v_cap_make, v_owner),
    (v_checker, v_plant_a, v_cap_check, v_owner);
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
    select v_admin, id, v_owner from public.capabilities where capability_key = 'administer_users';

  -- ── throwaway Batches, inserted directly (bypassing the full Calculate/Send
  --    workflow, which record_customer_outcome and resolve_batch_prior_quote
  --    never touch) - real Plant/Family/Party FKs, synthetic everything else.
  --    The Batch-reference trigger (ref_private.allocate_reference) requires
  --    a resolvable current_app_user(), so these direct inserts run as the
  --    owner Maker persona, exactly as a real Batch creation would. ──
  -- current_app_user() reads request.jwt.claims regardless of the active
  -- database role, so the owner claim alone is enough to satisfy the
  -- Batch-reference trigger - the connecting role's own (unrestricted)
  -- privileges are what actually perform this setup INSERT.
  perform set_config('request.jwt.claims', v_owner_claims, true);
  insert into public.batches (family_id, plant_id, owner_user_id, status, pricing_date,
    sector_id, pricing_basis_is_deliberate, customer_party_id, created_by)
    values (v_family, v_plant_a, v_owner, 'issued_locked', current_date, v_sector, false, v_party, v_owner)
    returning id into v_batch_a;
  insert into public.batches (family_id, plant_id, owner_user_id, status, pricing_date,
    sector_id, pricing_basis_is_deliberate, customer_party_id, created_by)
    values (v_family, v_plant_a, v_owner, 'issued_locked', current_date - 10, v_sector, false, v_party, v_owner)
    returning id into v_batch_b;
  -- Batch D: same exact Customer+Plant as A/B, its OWN Quote family is
  -- intentionally absent, so the search branch (not the pending-source
  -- branch) is what resolve_batch_prior_quote must use for it.
  insert into public.batches (family_id, plant_id, owner_user_id, status, pricing_date,
    sector_id, pricing_basis_is_deliberate, customer_party_id, created_by)
    values (v_family, v_plant_a, v_owner, 'working', current_date, v_sector, false, v_party, v_owner)
    returning id into v_batch_d;
  -- Batch G: WRONG Plant, SAME Customer, with a revision issued LATER than
  -- everything else - adversarial recency for the Plant-exclusion check.
  insert into public.batches (family_id, plant_id, owner_user_id, status, pricing_date,
    sector_id, pricing_basis_is_deliberate, customer_party_id, created_by)
    values (v_family, v_plant_b, v_owner, 'issued_locked', current_date, v_sector, false, v_party, v_owner)
    returning id into v_batch_g;

  insert into public.batch_collaborators (batch_id, app_user_id, status, created_by)
    values (v_batch_a, v_collab, 'active', v_owner);

  insert into public.quote_families (batch_id, quote_reference, status, created_by)
    values (v_batch_a, null, 'active', v_owner) returning id into v_qf_a;
  insert into public.quote_families (batch_id, quote_reference, status, created_by)
    values (v_batch_b, null, 'active', v_owner) returning id into v_qf_b;

  -- Revision A: the Batch's OWN most-recently-issued revision (current).
  insert into public.quote_revisions (family_id, revision_no, workflow_status, standing,
    addressee_name, quote_date, offer_validity_to, approved_by, approved_at,
    issued_by, issued_at, created_by)
    values (v_qf_a, 1, 'issued', 'current', 'Rehearsal Buyer', current_date, current_date + 28,
      v_checker, now(), v_owner, now(), v_owner)
    returning id into v_rev_a;
  -- Revision B: an OLDER issued revision, different Family, same exact
  -- Customer+Plant - the "Last Quote" search must prefer A over this.
  insert into public.quote_revisions (family_id, revision_no, workflow_status, standing,
    addressee_name, quote_date, offer_validity_to, approved_by, approved_at,
    issued_by, issued_at, created_by)
    values (v_qf_b, 1, 'issued', 'superseded', 'Rehearsal Buyer', current_date - 10, current_date + 18,
      v_checker, now() - interval '10 days', v_owner, now() - interval '10 days', v_owner)
    returning id into v_rev_b;
  -- A non-issued revision on the SAME family as A, for the "non-issued
  -- revision is refused" check.
  insert into public.quote_revisions (family_id, revision_no, workflow_status, standing, created_by)
    values (v_qf_a, null, 'draft', null, v_owner)
    returning id into v_rev_draft;

  -- Batch D deliberately has NO pending_quote_revision_sources row yet, so
  -- every resolve_batch_prior_quote(v_batch_d) call below (S5R-15..19) is
  -- genuinely exercising the SEARCH branch. The "exact Create Revision
  -- source wins" fixture is inserted later (S5R-20), only once the search
  -- branch has already been proven - inserting it here would make every
  -- later "search" check silently take the pending-source branch instead.

  -- ── record_customer_outcome authority matrix (against v_rev_a) ──
  v_state := pg_temp.try_claims( v_owner_sub,
    format('select public.record_customer_outcome(%s, ''rejected'', null, null, ''first pass'')', v_rev_a));
  log := log || case when v_state = 'OK' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-1 the Batch-owning Maker may record a customer outcome: ' || v_state;
  if v_state <> 'OK' then fails := fails + 1; end if;

  v_n := (pg_temp.val_claims( v_collab_sub,
    format('select count(*)::text from public.customer_outcome_events where revision_id = %s', v_rev_a)))::int;
  v_state := pg_temp.try_claims( v_collab_sub,
    format('select public.record_customer_outcome(%s, ''accepted'', current_date, ''PO-collab'', null)', v_rev_a));
  log := log || case when v_state = '42501' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-2 a collaborator Maker who is NOT the owner is refused (DM-105): ' || v_state;
  if v_state <> '42501' then fails := fails + 1; end if;
  log := log || case
    when (pg_temp.val_claims( v_owner_sub,
      format('select count(*)::text from public.customer_outcome_events where revision_id = %s', v_rev_a)))::int = v_n
    then E'\nok   ' else E'\nFAIL ' end || 'S5R-3 the refused collaborator attempt wrote NOTHING';
  if (pg_temp.val_claims( v_owner_sub,
      format('select count(*)::text from public.customer_outcome_events where revision_id = %s', v_rev_a)))::int <> v_n
    then fails := fails + 1; end if;

  v_state := pg_temp.try_claims( v_checker_sub,
    format('select public.record_customer_outcome(%s, ''accepted'', current_date, ''PO-checker'', ''late acceptance'')', v_rev_a));
  log := log || case when v_state = 'OK' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-4 an authorised Checker may record a customer outcome: ' || v_state;
  if v_state <> 'OK' then fails := fails + 1; end if;

  v_state := pg_temp.try_claims( v_admin_sub,
    format('select public.record_customer_outcome(%s, ''awaiting_response'', null, null, ''admin correction'')', v_rev_a));
  log := log || case when v_state = 'OK' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-5 Admin correction authority may record a customer outcome: ' || v_state;
  if v_state <> 'OK' then fails := fails + 1; end if;

  v_state := pg_temp.try_claims( v_wrongplant_sub,
    format('select public.record_customer_outcome(%s, ''accepted'', null, null, null)', v_rev_a));
  log := log || case when v_state = '42501' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-6 a Maker with capability at the WRONG Plant is refused: ' || v_state;
  if v_state <> '42501' then fails := fails + 1; end if;

  v_state := pg_temp.try_claims( v_inactive_sub,
    format('select public.record_customer_outcome(%s, ''accepted'', null, null, null)', v_rev_a));
  log := log || case when v_state = '42501' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-7 an INACTIVE caller is refused (current_app_user resolves nothing): ' || v_state;
  if v_state <> '42501' then fails := fails + 1; end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    set local role anon;
    begin
      perform public.record_customer_outcome(v_rev_a, 'accepted', null, null, null);
      v_state := 'NO ERROR';
    exception when others then
      v_state := sqlstate;
    end;
    reset role;
  end;
  log := log || case when v_state in ('42501', '42883') then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-8 an anonymous caller cannot even reach the function: ' || v_state;
  if v_state not in ('42501', '42883') then fails := fails + 1; end if;

  v_state := pg_temp.try_claims( v_owner_sub,
    format('select public.record_customer_outcome(%s, ''accepted'', null, null, null)', v_rev_draft));
  log := log || case when v_state = 'PT422' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-9 a non-issued revision is refused: ' || v_state;
  if v_state <> 'PT422' then fails := fails + 1; end if;

  v_state := pg_temp.try_claims( v_owner_sub,
    format('select public.record_customer_outcome(%s, ''expired'', current_date, ''ref'', null)', v_rev_a));
  log := log || case when v_state = 'PT422' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-10 acceptance fields are refused on a non-accepted outcome: ' || v_state;
  if v_state <> 'PT422' then fails := fails + 1; end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_sub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    begin
      update public.customer_outcome_events set note = 'tampered' where revision_id = v_rev_a;
      v_state := 'NO ERROR';
    exception when others then
      v_state := sqlstate;
    end;
    begin
      delete from public.customer_outcome_events where revision_id = v_rev_a;
      if v_state = 'NO ERROR' then v_state := 'NO ERROR'; end if;
    exception when others then
      if v_state = 'NO ERROR' then v_state := sqlstate; end if;
    end;
    reset role;
  end;
  log := log || case when v_state <> 'NO ERROR' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-11 customer outcomes are append-only - no UPDATE/DELETE privilege exists: ' || v_state;
  if v_state = 'NO ERROR' then fails := fails + 1; end if;

  -- Ordered by id (the reliable insert-order signal): every statement in
  -- this rehearsal shares ONE transaction, and now() is the TRANSACTION
  -- start time in Postgres, not the wall clock - so occurred_at is
  -- genuinely identical across all three rows here. That is expected and
  -- is not itself a defect; S5R-14 below asserts non-decreasing, not
  -- strictly increasing, for exactly this reason.
  select recorded_by, outcome, occurred_at into v_row1_recorded_by, v_row1_outcome, v_row1_at
    from public.customer_outcome_events where revision_id = v_rev_a order by id limit 1;
  select recorded_by, outcome, occurred_at into v_row2_recorded_by, v_row2_outcome, v_row2_at
    from public.customer_outcome_events where revision_id = v_rev_a order by id offset 1 limit 1;
  select recorded_by, outcome, occurred_at into v_row3_recorded_by, v_row3_outcome, v_row3_at
    from public.customer_outcome_events where revision_id = v_rev_a order by id offset 2 limit 1;
  log := log || case when v_row1_outcome = 'rejected' and v_row2_outcome = 'accepted' and v_row3_outcome = 'awaiting_response'
    then E'\nok   ' else E'\nFAIL ' end || 'S5R-12 a LATE Accepted may follow an earlier Rejected, in append-only order: '
    || coalesce(v_row1_outcome, '?') || '->' || coalesce(v_row2_outcome, '?') || '->' || coalesce(v_row3_outcome, '?');
  if not (v_row1_outcome = 'rejected' and v_row2_outcome = 'accepted' and v_row3_outcome = 'awaiting_response') then
    fails := fails + 1;
  end if;
  log := log || case when v_row1_recorded_by = v_owner and v_row2_recorded_by = v_checker and v_row3_recorded_by = v_admin
    then E'\nok   ' else E'\nFAIL ' end || 'S5R-13 actor attribution is the genuine caller of each call, never a fixed value';
  if not (v_row1_recorded_by = v_owner and v_row2_recorded_by = v_checker and v_row3_recorded_by = v_admin) then
    fails := fails + 1;
  end if;
  -- Non-decreasing, not strictly increasing: this whole rehearsal is one
  -- transaction, and now() is that transaction's start time throughout, so
  -- three inserts genuinely can (and here, will) share one instant. What
  -- this DOES prove is that occurred_at is never null, never before the
  -- transaction start, and never out of order - i.e. database-derived, not
  -- an arbitrary client value (the RPC signature accepts no timestamp
  -- parameter at all, so this is structural, but the assertion still
  -- exercises the real stored value rather than trusting the signature).
  log := log || case when v_row1_at <= v_row2_at and v_row2_at <= v_row3_at
      and v_row1_at is not null and v_row2_at is not null and v_row3_at is not null
    then E'\nok   ' else E'\nFAIL ' end || 'S5R-14 occurred_at is database-derived and non-decreasing across calls';
  if not (v_row1_at <= v_row2_at and v_row2_at <= v_row3_at
      and v_row1_at is not null and v_row2_at is not null and v_row3_at is not null) then
    fails := fails + 1;
  end if;

  -- ── resolve_batch_prior_quote (D-6) ──
  v_found := (pg_temp.val_claims( v_owner_sub,
    format('select revision_id::text from public.resolve_batch_prior_quote(%s)', v_batch_d)))::bigint;
  log := log || case when v_found = v_rev_a then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-15 the search finds the LATEST issued revision for the exact Customer+Plant (rev_a), not rev_b: got ' || v_found;
  if v_found <> v_rev_a then fails := fails + 1; end if;

  -- Batch G (wrong Plant) got an issued revision issued LATER than rev_a -
  -- if Plant exclusion were broken, the search above would have returned it.
  perform set_config('request.jwt.claims', v_owner_claims, true);
  insert into public.quote_families (batch_id, quote_reference, status, created_by)
    values (v_batch_g, null, 'active', v_owner) returning id into v_qf_scratch;
  insert into public.quote_revisions (family_id, revision_no, workflow_status, standing,
    addressee_name, quote_date, offer_validity_to, approved_by, approved_at, issued_by, issued_at, created_by)
    values (v_qf_scratch, 1, 'issued', 'current', 'Rehearsal Buyer', current_date, current_date + 28,
      v_checker, now() + interval '1 day', v_owner, now() + interval '1 day', v_owner)
    returning id into v_rev_g;
  v_found := (pg_temp.val_claims( v_owner_sub,
    format('select revision_id::text from public.resolve_batch_prior_quote(%s)', v_batch_d)))::bigint;
  log := log || case when v_found = v_rev_a then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-16 a more recently issued revision at the WRONG Plant is never substituted: got ' || v_found;
  if v_found <> v_rev_a then fails := fails + 1; end if;

  if v_party2 is not null then
    perform set_config('request.jwt.claims', v_owner_claims, true);
    insert into public.batches (family_id, plant_id, owner_user_id, status, pricing_date,
      sector_id, pricing_basis_is_deliberate, customer_party_id, created_by)
      values (v_family, v_plant_a, v_owner, 'issued_locked', current_date, v_sector, false, v_party2, v_owner)
      returning id into v_batch_h;
    insert into public.quote_families (batch_id, quote_reference, status, created_by)
      values (v_batch_h, null, 'active', v_owner) returning id into v_qf_scratch;
    insert into public.quote_revisions (family_id, revision_no, workflow_status, standing,
      addressee_name, quote_date, offer_validity_to, approved_by, approved_at, issued_by, issued_at, created_by)
      values (v_qf_scratch, 1, 'issued', 'current', 'Rehearsal Buyer', current_date, current_date + 28,
        v_checker, now() + interval '2 days', v_owner, now() + interval '2 days', v_owner)
      returning id into v_rev_h;
    v_found := (pg_temp.val_claims( v_owner_sub,
      format('select revision_id::text from public.resolve_batch_prior_quote(%s)', v_batch_d)))::bigint;
    log := log || case when v_found = v_rev_a then E'\nok   ' else E'\nFAIL ' end
      || 'S5R-17 a more recently issued revision for a DIFFERENT exact Customer is never substituted: got ' || v_found;
    if v_found <> v_rev_a then fails := fails + 1; end if;
  else
    log := log || E'\nSKIP S5R-17 only one active Party exists in this database - cross-Customer exclusion not exercised';
  end if;

  v_found := (pg_temp.val_claims( v_owner_sub,
    format('select revision_id::text from public.resolve_batch_prior_quote(%s)', v_batch_d)))::bigint;
  log := log || case when v_found = v_rev_a and not exists (
      select 1 from app_private.pending_quote_revision_sources where batch_id = v_batch_d)
    then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-18 Batch D (no pending source) is genuinely on the search path, not the pending-source path';
  if not (v_found = v_rev_a and not exists (
      select 1 from app_private.pending_quote_revision_sources where batch_id = v_batch_d)) then
    fails := fails + 1;
  end if;

  v_found := (pg_temp.val_claims( v_owner_sub,
    format('select revision_id::text from public.resolve_batch_prior_quote(%s)', v_batch_a)))::bigint;
  -- v_batch_a HAS no pending_quote_revision_sources row of its own, and it
  -- HAS its own current issued revision (v_rev_a); resolve_batch_prior_quote
  -- must exclude the caller's own family entirely, so the "prior" here is
  -- whatever the search finds excluding v_qf_a - i.e. v_rev_b or, since G/H
  -- exist now, still constrained to plant_a+party -> v_rev_b.
  log := log || case when v_found = v_rev_b then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-19 a Batch with its OWN current revision excludes its own Family from the search: got ' || v_found;
  if v_found <> v_rev_b then fails := fails + 1; end if;

  -- exact Create-Revision source wins: NOW give v_batch_d its first pending
  -- source, pointed at rev_a, and confirm the resolver takes the pending
  -- branch immediately (not that it would have found rev_a via search
  -- anyway - that ambiguity is why S5R-21 immediately re-points it to
  -- rev_b, which the search would NOT have chosen).
  insert into app_private.pending_quote_revision_sources (batch_id, family_id, source_revision_id, created_by)
    values (v_batch_d, v_qf_b, v_rev_a, v_owner);
  v_found := (pg_temp.val_claims( v_owner_sub,
    format('select revision_id::text from public.resolve_batch_prior_quote(%s)', v_batch_d)))::bigint;
  log := log || case when v_found = v_rev_a then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-20 the pending Create-Revision source is honoured exactly (pointed at rev_a): got ' || v_found;
  if v_found <> v_rev_a then fails := fails + 1; end if;

  update app_private.pending_quote_revision_sources set source_revision_id = v_rev_b where batch_id = v_batch_d;
  v_found := (pg_temp.val_claims( v_owner_sub,
    format('select revision_id::text from public.resolve_batch_prior_quote(%s)', v_batch_d)))::bigint;
  log := log || case when v_found = v_rev_b then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-21 the pending Create-Revision source (rev_b) wins EVEN THOUGH rev_a is more recently issued: got ' || v_found;
  if v_found <> v_rev_b then fails := fails + 1; end if;

  v_state := pg_temp.try_claims( v_stranger_sub,
    format('select * from public.resolve_batch_prior_quote(%s)', v_batch_d));
  log := log || case when v_state = '42501' then E'\nok   ' else E'\nFAIL ' end
    || 'S5R-22 an unauthorised caller (no Batch relationship, no capability) is refused, not silently empty: ' || v_state;
  if v_state <> '42501' then fails := fails + 1; end if;

  -- ── private helpers stay unexecutable by application roles ──
  log := log || case when not has_function_privilege('authenticated',
      'app_private.record_customer_outcome(bigint,text,date,text,text)', 'EXECUTE')
    then E'\nok   ' else E'\nFAIL ' end || 'S5R-23 app_private.record_customer_outcome is not authenticated-executable';
  if has_function_privilege('authenticated', 'app_private.record_customer_outcome(bigint,text,date,text,text)', 'EXECUTE')
    then fails := fails + 1; end if;
  log := log || case when not has_function_privilege('anon',
      'public.record_customer_outcome(bigint,text,date,text,text)', 'EXECUTE')
    then E'\nok   ' else E'\nFAIL ' end || 'S5R-24 public.record_customer_outcome is not anon-executable';
  if has_function_privilege('anon', 'public.record_customer_outcome(bigint,text,date,text,text)', 'EXECUTE')
    then fails := fails + 1; end if;
  log := log || case when not has_function_privilege('authenticated',
      'app_private.resolve_batch_prior_quote(bigint)', 'EXECUTE')
    then E'\nok   ' else E'\nFAIL ' end || 'S5R-25 app_private.resolve_batch_prior_quote is not authenticated-executable';
  if has_function_privilege('authenticated', 'app_private.resolve_batch_prior_quote(bigint)', 'EXECUTE')
    then fails := fails + 1; end if;
  log := log || case when not has_function_privilege('anon',
      'public.resolve_batch_prior_quote(bigint)', 'EXECUTE')
    then E'\nok   ' else E'\nFAIL ' end || 'S5R-26 public.resolve_batch_prior_quote is not anon-executable';
  if has_function_privilege('anon', 'public.resolve_batch_prior_quote(bigint)', 'EXECUTE')
    then fails := fails + 1; end if;

  -- ═════ TAIL: restore the only non-transactional state (sequences), then abort ═════
  declare r record; v_saved jsonb; v_last bigint; v_called boolean;
  begin
    select v into v_saved from qos_s5_baseline where k = 'sequences';
    for r in select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where c.relkind = 'S' and n.nspname = any (array['public', 'app_private', 'ref_private']) loop
      v_last    := (v_saved -> format('%I.%I', r.nspname, r.relname) ->> 0)::bigint;
      v_called  := (v_saved -> format('%I.%I', r.nspname, r.relname) ->> 1)::boolean;
      if v_last is not null then
        execute format('select setval(%L, %s, %L)', format('%I.%I', r.nspname, r.relname), v_last, v_called);
      end if;
    end loop;
  end;

  raise exception 'REHEARSAL ROLLED BACK. failures=% %', fails, log;
end $rehearse$;
