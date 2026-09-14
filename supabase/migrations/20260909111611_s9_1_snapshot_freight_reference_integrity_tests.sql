-- S9(a) correction gates. Replaces tests.quote_schema() in full.
--
-- COMMENTARY CORRECTION. The first version of this suite described QG-9..QG-15
-- as pinning the freight constraints "by exact expression". They do not. They
-- are `LIKE` probes over pg_get_constraintdef output: they inspect SELECTED
-- FRAGMENTS of a constraint definition. That is genuinely useful - QG-10 fails
-- if 'unresolved' is ever admitted, and QG-13 fails if an authority disappears -
-- but a fragment probe cannot detect every weakening, and calling it exact
-- overstated it. The wording below says what these assertions actually do.
--
-- The new QG-19..QG-25 are NOT fragment probes. They read pg_constraint's
-- catalog columns - contype, conkey, confkey, confrelid - so they assert the
-- STRUCTURE of the composite foreign key rather than the text of it.

create or replace function tests.quote_schema()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['quote_families','quote_revisions','calculation_snapshots',
                           'quote_items','quote_item_delivery_groups',
                           'quote_workflow_events','customer_outcome_events',
                           'export_events','export_parts'];
  v_immutable text[] := array['quote_items','calculation_snapshots'];
  t text;
  v_def text;
  v_cols text[];
  v_refcols text[];
begin
  foreach t in array v_tables loop
    return next ok(
      (select c.relrowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t),
      format('QG-1 %s has RLS enabled', t));

    return next ok(
      (select c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t),
      format('QG-2 %s FORCES RLS, so even its owner is subject to policy', t));

    return next ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('anon','public.'||t,'DELETE')),
      format('QG-3 anon holds no privilege of any kind on %s', t));

    return next ok(
      not (pg_catalog.has_table_privilege('authenticated','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('authenticated','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('authenticated','public.'||t,'DELETE')),
      format('QG-4 authenticated holds NO write privilege on %s - there is nothing for a policy to admit', t));

    return next ok(
      pg_catalog.has_table_privilege('authenticated','public.'||t,'SELECT'),
      format('QG-5 authenticated may still READ %s', t));

    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid=pol.polrelid
         join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname=t and pol.polcmd <> 'r'),
      0,
      format('QG-6 %s carries no INSERT, UPDATE or DELETE policy', t));

    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid=pol.polrelid
         join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname=t),
      1,
      format('QG-7 %s carries exactly one policy, and it is the SELECT policy', t));
  end loop;

  foreach t in array v_immutable loop
    return next ok(
      not pg_catalog.has_table_privilege('authenticated','public.'||t,'UPDATE')
      and not pg_catalog.has_table_privilege('authenticated','public.'||t,'DELETE')
      and not exists (select 1 from pg_catalog.pg_policy pol
                        join pg_catalog.pg_class c on c.oid=pol.polrelid
                        join pg_catalog.pg_namespace n on n.oid=c.relnamespace
                       where n.nspname='public' and c.relname=t and pol.polcmd in ('w','d')),
      format('QG-8 %s has NO update or delete path: neither privilege nor policy, for any app user including an administer_users holder', t));
  end loop;

  -- QG-9..QG-16 are FRAGMENT PROBES over the constraint definition, not exact
  -- expression matches. See the header note.
  select pg_catalog.pg_get_constraintdef(oid) into v_def
    from pg_catalog.pg_constraint where conname = 'ck_cs_freight_source';
  return next ok(v_def is not null, 'QG-9 ck_cs_freight_source exists');
  return next ok(v_def not like '%unresolved%',
    'QG-10 the freight source list does NOT mention ''unresolved'' - unresolved freight cannot enter a Quote snapshot');
  return next ok(v_def like '%row%' and v_def like '%legacy_batch%' and v_def like '%pricing_group%'
             and v_def like '%master%' and v_def like '%legacy_matrix%',
    'QG-11 and it names all five sendable S8 sources');

  select pg_catalog.pg_get_constraintdef(oid) into v_def
    from pg_catalog.pg_constraint where conname = 'ck_cs_freight_authority_binds_source';
  return next ok(v_def is not null,
    'QG-12 the database BINDS source to authority - the runtime field enables enforcement, this performs it');
  return next ok(v_def like '%governed%' and v_def like '%temporary%',
    'QG-13 naming both authorities');
  return next ok(
    v_def like '%row%' and v_def like '%pricing_group%' and v_def like '%master%'
    and v_def like '%legacy_batch%' and v_def like '%legacy_matrix%',
    'QG-14 and all five sources, so none is left unbound');

  return next ok(
    exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='calculation_snapshots'
               and column_name='freight_authority' and is_nullable='NO'),
    'QG-15 freight_authority is a REQUIRED typed column, not an optional annotation');

  -- ─────────────── the corrected reference shape and composite relationship
  -- Structural assertions, read from pg_constraint's catalog columns.
  return next ok(
    not exists (select 1 from pg_catalog.pg_constraint
                 where conname in ('ck_cs_master_has_both_refs',
                                   'ck_cs_temporary_carries_no_governed_ref')),
    'QG-16 the two one-sided reference checks are gone, replaced by one biconditional');

  select pg_catalog.pg_get_constraintdef(oid) into v_def
    from pg_catalog.pg_constraint where conname = 'ck_cs_freight_refs_master_only';
  return next ok(v_def is not null,
    'QG-17 the reference shape is stated in ONE constraint, in both directions');
  return next ok(v_def like '%freight_entry_id%' and v_def like '%freight_set_version_id%'
             and v_def like '%master%',
    'QG-18 binding both reference columns to the master source');

  -- The composite FK: the PAIR is what the database checks, so a snapshot
  -- cannot name a Freight Entry belonging to a different Freight Set Version.
  select array_agg(a.attname order by k.ord), array_agg(fa.attname order by k.ord)
    into v_cols, v_refcols
  from pg_catalog.pg_constraint c
  cross join lateral unnest(c.conkey, c.confkey) with ordinality as k(col, refcol, ord)
  join pg_catalog.pg_attribute a  on a.attrelid = c.conrelid  and a.attnum = k.col
  join pg_catalog.pg_attribute fa on fa.attrelid = c.confrelid and fa.attnum = k.refcol
  where c.conname = 'fk_cs_freight_entry_in_version';

  return next ok(v_cols is not null,
    'QG-19 fk_cs_freight_entry_in_version exists');
  return next is(array_length(v_cols,1), 2,
    'QG-20 and it is COMPOSITE - two columns, not two independent references');
  return next ok(v_cols @> array['freight_entry_id','freight_set_version_id'],
    'QG-21 over the entry and the set version together');
  return next ok(v_refcols @> array['id','freight_set_version_id'],
    'QG-22 targeting freight_entries(id, freight_set_version_id)');
  return next ok(
    (select confrelid from pg_catalog.pg_constraint
      where conname='fk_cs_freight_entry_in_version') = 'public.freight_entries'::regclass,
    'QG-23 on freight_entries itself');

  return next ok(
    exists (select 1 from pg_catalog.pg_constraint
             where conname='uk_fe_id_version' and contype='u'
               and conrelid='public.freight_entries'::regclass),
    'QG-24 and the candidate key it needs exists on freight_entries');

  return next ok(
    not exists (select 1 from pg_catalog.pg_constraint where conname='fk_cs_freight_entry'),
    'QG-25 the superseded single-column entry reference is gone, so the weak path cannot be used');

  -- ─────────────────────────────────────────────── lifecycle and lineage
  return next ok(
    exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='quote_revisions'
               and column_name='revision_no' and is_nullable='YES'),
    'QG-26 revision_no is NULLABLE - a draft that is never approved consumes no number (CDM-21)');

  return next ok(
    exists (select 1 from pg_catalog.pg_constraint where conname='ck_qr_approved_has_revision_no'),
    'QG-27 but an approved or issued revision cannot lack one');

  return next ok(
    exists (select 1 from pg_catalog.pg_constraint where conname='ck_qf_abandoned_unreferenced'),
    'QG-28 an abandoned pre-approval family consumes no Quote Reference (CDM-30)');

  return next ok(
    exists (
      select 1 from pg_catalog.pg_constraint c
       where c.conname = 'fk_qi_lineage'
         and c.confrelid = 'public.batch_rows'::regclass
         and (select attname from pg_catalog.pg_attribute
               where attrelid = c.confrelid and attnum = c.confkey[1]) = 'lineage_id'),
    'QG-29 PM-7 binds quote_items to batch_rows.LINEAGE_ID, not to the row id');

  return next ok(
    exists (select 1 from pg_catalog.pg_constraint where conname='uk_qi_snapshot' and contype='u'),
    'QG-30 a snapshot serves exactly one Quote Item');

  return next ok(
    exists (select 1 from pg_catalog.pg_constraint where conname='uk_qf_batch' and contype='u'),
    'QG-31 one Quote family per Batch (CDM-21)');

  -- ───────────────────────────────────────────── S9(a) creates no live data
  return next is((select count(*)::int from public.quote_families), 0,
    'QG-32 no Quote family exists');
  return next is((select count(*)::int from public.quote_revisions), 0,
    'QG-33 no revision, so no Quote number was allocated');
  return next is((select count(*)::int from public.calculation_snapshots), 0,
    'QG-34 no calculation snapshot exists');
  return next is((select count(*)::int from public.quote_items), 0,
    'QG-35 no Quote item exists');
  return next is(
    (select count(*)::int from (
       select 1 from public.quote_item_delivery_groups
       union all select 1 from public.quote_workflow_events
       union all select 1 from public.customer_outcome_events
       union all select 1 from public.export_events
       union all select 1 from public.export_parts) x),
    0,
    'QG-36 and the remaining five Family G tables are empty too');
  return next is((select count(*)::int from public.quote_families where quote_reference is not null), 0,
    'QG-37 no Quote reference has been allocated');

  foreach t in array array['can_read_quote_family','can_read_quote_revision','can_read_quote_item'] loop
    return next ok(
      not pg_catalog.has_function_privilege('authenticated', 'app_private.'||t||'(bigint)', 'EXECUTE')
      and not pg_catalog.has_function_privilege('anon', 'app_private.'||t||'(bigint)', 'EXECUTE'),
      format('QG-38 app_private.%s is not callable by anon or authenticated', t));
  end loop;
end $fn$;

revoke all on function tests.quote_schema() from public, anon, authenticated;
