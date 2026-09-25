-- U4 stored-suite drift correction. TESTS SCHEMA ONLY.
--
-- Since 20260915100440_u4_customer_family_sectors, app_private.create_batch
-- refuses a null Sector (22023) and requires the Sector to be attached to the
-- Family. Seven stored suites still set up their Batch with
-- create_batch(v_fam, <plant>, null), so they raise before their first
-- assertion. This forward correction splices the INSTALLED definitions so each
-- positive fixture:
--   * uses its own governed fixture Sector (__S7R / __S9P where the fixture
--     already owns one; otherwise a fixture-owned __U4F_* Sector minted here);
--   * attaches that Sector to its Family before create_batch;
--   * passes that exact Sector to create_batch;
--   * removes the Family-Sector link in teardown before its Sector or Family
--     is deleted.
--
-- Positive calls corrected (8 in 7 functions):
--   tests.__s7r_body            main Batch            -> __S7R (own)
--   tests.__s9p_body            CP-37 gap Batch       -> __U4F_S9P (minted; __S9P does not exist yet)
--   tests.__s9p_body            main Batch            -> __S9P (own)
--   tests.batch_locks           BL fixture Batch      -> __U4F_BL
--   tests.batch_profile         BP fixture Batch      -> __U4F_BP
--   tests.batch_set_cardinality card fixture Batch    -> __U4F_BSC
--   tests.family_f_security     FS fixture Batch      -> __U4F_FFS
--   tests.interest_authority    IA fixture Batch      -> __U4F_IA
-- Teardowns corrected: tests.__s7r_teardown, tests.__s9p_teardown and the
-- inline teardowns of the five other suites.
--
-- Deliberately UNCHANGED: tests.family_f_security FS-6 and FS-17 call
-- create_batch(v_fam, v_nag, null) inside a refusal block and expect 42501;
-- create_batch checks plant authority before the Sector, so they remain
-- authorization refusals and keep their null.
--
-- Production create_batch, tables, constraints, RLS, application functions and
-- grants are not touched. Every splice is an exact anchor asserted to match
-- once; any drift in the installed definitions aborts the whole migration.

-- ═════ 1. Owner-only fixture helpers ═════
create or replace function tests.__u4_attach_fixture_sector(p_family bigint, p_sector bigint)
returns bigint language plpgsql set search_path = '' as $fn$
begin
  insert into public.customer_family_sectors (family_id, sector_id, created_by)
    select f.id, p_sector, f.created_by from public.customer_families f where f.id = p_family;
  if not found then
    raise exception 'U4 fixture Family % does not exist', p_family using errcode = '23503';
  end if;
  return p_sector;
end $fn$;

create or replace function tests.__u4_mint_fixture_sector(p_family bigint, p_code text)
returns bigint language plpgsql set search_path = '' as $fn$
declare v_sector bigint;
begin
  if left(p_code, 6) <> '__U4F_' then
    raise exception 'U4 fixture Sector codes must start with __U4F_' using errcode = '22023';
  end if;
  insert into public.sectors (sector_code, name, created_by)
    select p_code, '__p2 u4 fixture sector ' || p_code, f.created_by
      from public.customer_families f where f.id = p_family
    returning id into v_sector;
  if v_sector is null then
    raise exception 'U4 fixture Family % does not exist', p_family using errcode = '23503';
  end if;
  return tests.__u4_attach_fixture_sector(p_family, v_sector);
end $fn$;

-- Removes every Family link to the Sector; deletes the Sector only when this
-- migration's helper minted it (__U4F_*). Own fixture Sectors are deleted by
-- their existing teardown lines.
create or replace function tests.__u4_release_fixture_sector(p_code text)
returns void language plpgsql set search_path = '' as $fn$
begin
  delete from public.customer_family_sectors
   where sector_id in (select id from public.sectors where sector_code = p_code);
  if left(p_code, 6) = '__U4F_' then
    delete from public.sectors where sector_code = p_code;
  end if;
end $fn$;

revoke all on function tests.__u4_attach_fixture_sector(bigint,bigint) from public, anon, authenticated;
revoke all on function tests.__u4_mint_fixture_sector(bigint,text) from public, anon, authenticated;
revoke all on function tests.__u4_release_fixture_sector(text) from public, anon, authenticated;

-- ═════ 2. Exact-anchor splices into the installed suites ═════
do $u4$
declare
  v_def text; v_cnt integer; v_fn text; i integer; v_pairs text[][]; v_shape jsonb; r record;
  -- shared anchors
  decl_old constant text := E'\ndeclare\n';
  decl_new constant text := E'\ndeclare\n  v_u4_sector bigint;\n';
  fam_del constant text := E'  delete from public.customer_families where id = v_fam;\n';
  -- tests.__s7r_body / __s7r_teardown
  s7r_old constant text := E'  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, null); reset role;\n';
  s7r_new constant text := E'  perform tests.__u4_attach_fixture_sector(v_fam, v_sec);\n'
    || E'  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, v_sec); reset role;\n';
  s7t_old constant text := E'  delete from public.sectors         where sector_code = ''__S7R'';\n';
  s7t_new constant text := E'  perform tests.__u4_release_fixture_sector(''__S7R'');\n'
    || E'  delete from public.sectors         where sector_code = ''__S7R'';\n';
  -- tests.__s9p_body / __s9p_teardown
  s9g_old constant text := E'  perform pg_catalog.set_config(''request.jwt.claims'', v_mclaims, true);\n'
    || E'  set local role authenticated;\n'
    || E'  v_batch_gap := public.create_batch(v_fam, v_kol, null);\n';
  s9g_new constant text := E'  v_u4_sector := tests.__u4_mint_fixture_sector(v_fam, ''__U4F_S9P'');\n'
    || E'  perform pg_catalog.set_config(''request.jwt.claims'', v_mclaims, true);\n'
    || E'  set local role authenticated;\n'
    || E'  v_batch_gap := public.create_batch(v_fam, v_kol, v_u4_sector);\n';
  s9m_old constant text := E'  perform pg_catalog.set_config(''request.jwt.claims'', v_mclaims, true);\n'
    || E'  set local role authenticated;\n'
    || E'  v_batch := public.create_batch(v_fam, v_kol, null);\n';
  s9m_new constant text := E'  perform tests.__u4_attach_fixture_sector(v_fam, v_sec);\n'
    || E'  perform pg_catalog.set_config(''request.jwt.claims'', v_mclaims, true);\n'
    || E'  set local role authenticated;\n'
    || E'  v_batch := public.create_batch(v_fam, v_kol, v_sec);\n';
  s9t_old constant text := E'  delete from public.sector_versions        where sector_id in\n'
    || E'    (select id from public.sectors where sector_code = ''__S9P'');\n';
  s9t_new constant text := E'  perform tests.__u4_release_fixture_sector(''__U4F_S9P'');\n'
    || E'  perform tests.__u4_release_fixture_sector(''__S9P'');\n'
    || E'  delete from public.sector_versions        where sector_id in\n'
    || E'    (select id from public.sectors where sector_code = ''__S9P'');\n';
  -- Maker-created NAG fixtures (batch_locks, batch_profile, batch_set_cardinality, interest_authority)
  nag_old constant text := E'  perform pg_catalog.set_config(''request.jwt.claims'', v_mclaims, true);\n'
    || E'  set local role authenticated;\n'
    || E'  v_batch := public.create_batch(v_fam, v_nag, null);\n';
  -- Owner-created NAG fixture (family_f_security)
  ffs_old constant text := E'  perform pg_catalog.set_config(''request.jwt.claims'', v_oclaims, true);\n'
    || E'  set local role authenticated;\n'
    || E'  v_batch := public.create_batch(v_fam, v_nag, null);\n';
  ia_del constant text := E'  delete from public.customer_families      where id = v_fam;\n';
  neg constant text := E'    perform public.create_batch(v_fam, v_nag, null);\n';
begin
  -- The U4 contract this corrects for must be the one installed.
  if position('a Batch requires one Customer Family Sector' in
       pg_catalog.pg_get_functiondef('app_private.create_batch(bigint,bigint,bigint)'::regprocedure)) = 0 then
    raise exception 'U4 create_batch Sector requirement is not installed; nothing to correct' using errcode = '55000';
  end if;

  -- Security shape before, so it can be proven unchanged after.
  select jsonb_object_agg(p.oid::regprocedure::text,
           jsonb_build_array(coalesce(p.proacl::text, 'default'), p.prosecdef, coalesce(p.proconfig::text, 'none'),
                             pg_catalog.pg_get_userbyid(p.proowner), pg_catalog.pg_get_function_result(p.oid)))
    into v_shape
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'tests' and p.proname in ('__s7r_body', '__s7r_teardown', '__s9p_body', '__s9p_teardown',
         'batch_locks', 'batch_profile', 'batch_set_cardinality', 'family_f_security', 'interest_authority');
  if (select count(*) from jsonb_object_keys(v_shape)) <> 9 then
    raise exception 'U4 expected 9 installed stored functions, found %', (select count(*) from jsonb_object_keys(v_shape))
      using errcode = '55000';
  end if;

  for r in select * from (values
      ('tests.__s7r_body()',            array[[s7r_old, s7r_new]]),
      ('tests.__s7r_teardown()',        array[[s7t_old, s7t_new]]),
      ('tests.__s9p_body()',            array[[decl_old, decl_new], [s9g_old, s9g_new], [s9m_old, s9m_new]]),
      ('tests.__s9p_teardown()',        array[[s9t_old, s9t_new]]),
      ('tests.batch_locks()',           array[[decl_old, decl_new],
         [nag_old, E'  v_u4_sector := tests.__u4_mint_fixture_sector(v_fam, ''__U4F_BL'');\n' || replace(nag_old, 'v_nag, null)', 'v_nag, v_u4_sector)')],
         [fam_del, E'  perform tests.__u4_release_fixture_sector(''__U4F_BL'');\n' || fam_del]]),
      ('tests.batch_profile()',         array[[decl_old, decl_new],
         [nag_old, E'  v_u4_sector := tests.__u4_mint_fixture_sector(v_fam, ''__U4F_BP'');\n' || replace(nag_old, 'v_nag, null)', 'v_nag, v_u4_sector)')],
         [fam_del, E'  perform tests.__u4_release_fixture_sector(''__U4F_BP'');\n' || fam_del]]),
      ('tests.batch_set_cardinality()', array[[decl_old, decl_new],
         [nag_old, E'  v_u4_sector := tests.__u4_mint_fixture_sector(v_fam, ''__U4F_BSC'');\n' || replace(nag_old, 'v_nag, null)', 'v_nag, v_u4_sector)')],
         [fam_del, E'  perform tests.__u4_release_fixture_sector(''__U4F_BSC'');\n' || fam_del]]),
      ('tests.family_f_security()',     array[[decl_old, decl_new],
         [ffs_old, E'  v_u4_sector := tests.__u4_mint_fixture_sector(v_fam, ''__U4F_FFS'');\n' || replace(ffs_old, 'v_nag, null)', 'v_nag, v_u4_sector)')],
         [fam_del, E'  perform tests.__u4_release_fixture_sector(''__U4F_FFS'');\n' || fam_del]]),
      ('tests.interest_authority()',    array[[decl_old, decl_new],
         [nag_old, E'  v_u4_sector := tests.__u4_mint_fixture_sector(v_fam, ''__U4F_IA'');\n' || replace(nag_old, 'v_nag, null)', 'v_nag, v_u4_sector)')],
         [ia_del, E'  perform tests.__u4_release_fixture_sector(''__U4F_IA'');\n' || ia_del]])
    ) as t(fn, pairs) loop
    v_fn := r.fn; v_pairs := r.pairs;
    v_def := pg_catalog.pg_get_functiondef(v_fn::regprocedure);
    for i in 1..array_length(v_pairs, 1) loop
      v_cnt := (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]);
      if v_cnt <> 1 then
        raise exception 'U4 % anchor % matched % times, expected 1', v_fn, i, v_cnt using errcode = '55000';
      end if;
      v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
    end loop;
    execute v_def;
  end loop;

  -- Prove the results rather than trust the replacements.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
        lateral regexp_matches(pg_catalog.pg_get_functiondef(p.oid), 'create_batch\([^)]*null\)', 'g')
       where n.nspname = 'tests') <> 2 then
    raise exception 'U4 a positive null-Sector create_batch survives, or a negative one was lost' using errcode = '55000';
  end if;
  v_def := pg_catalog.pg_get_functiondef('tests.family_f_security()'::regprocedure);
  if (length(v_def) - length(replace(v_def, neg, ''))) / length(neg) <> 2
     or position('FS-6 nor may they create a Batch' in v_def) = 0 or position('FS-17 nor may they create a Batch' in v_def) = 0 then
    raise exception 'U4 the FS-6/FS-17 authorization refusals were not preserved' using errcode = '55000';
  end if;
  if v_shape is distinct from (
       select jsonb_object_agg(p.oid::regprocedure::text,
                jsonb_build_array(coalesce(p.proacl::text, 'default'), p.prosecdef, coalesce(p.proconfig::text, 'none'),
                                  pg_catalog.pg_get_userbyid(p.proowner), pg_catalog.pg_get_function_result(p.oid)))
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'tests' and p.proname in ('__s7r_body', '__s7r_teardown', '__s9p_body', '__s9p_teardown',
              'batch_locks', 'batch_profile', 'batch_set_cardinality', 'family_f_security', 'interest_authority')) then
    raise exception 'U4 a corrected suite changed signature, owner, ACL, security mode or search path' using errcode = '55000';
  end if;
end $u4$;

-- ═════ 3. Final verification ═════
do $verify$
declare v_fn text;
begin
  foreach v_fn in array array[
    'tests.__u4_attach_fixture_sector(bigint,bigint)',
    'tests.__u4_mint_fixture_sector(bigint,text)',
    'tests.__u4_release_fixture_sector(text)'] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE')
       or has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception '% is executable by an application role', v_fn using errcode = '55000';
    end if;
    if (select p.prosecdef from pg_proc p where p.oid = v_fn::regprocedure) then
      raise exception '% must not be SECURITY DEFINER', v_fn using errcode = '55000';
    end if;
  end loop;
end $verify$;
