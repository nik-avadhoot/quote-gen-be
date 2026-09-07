-- S7-6: the fixed Payment Terms map is withdrawn.
--
-- Canonical Amendment 01, A-03 (Product Owner, 2026-09-06). Its entire content
-- is reproduced exactly by the annual derivation, so keeping it would leave two
-- calculation authorities for one number - the defect this whole slice exists
-- to remove.
--
-- THIS IS THE LAST STEP ON PURPOSE, AND THE ORDER IS CANONICAL. A-03 makes it
-- so: the obsolete structure is not removed while any deployable build still
-- reads it or substitutes a hard-coded percentage. Everything ahead of it is
-- already done and proved - the annual fields exist (S7-1), the gates state the
-- derivation (S7-4), the resolver is the single authority (S7a), the engine no
-- longer carries an unapproved fallback (S7b), and no runtime path reads a map
-- of any kind (S7c, verified by sweep). Only now is this safe.
--
-- WHAT THE REMOVAL DOES NOT RISK. No deployed build ever read this table: the
-- frontend has no Supabase client and the backend exposes no route that touches
-- it, so its only readers were ever the pgTAP suites. And the compatibility
-- window is benign in the one direction that matters - because the approved rate
-- is 6.000%, an application build older than S7 substitutes 0.5/0.75/1.0/1.5,
-- which is precisely what the derivation produces. A rollback mis-resolves
-- inherited waste and conversion (the S7 packet's standing warning) but NOT
-- interest.
--
-- SPLICED, NOT RETYPED. Four suites reference the table. Each is edited by
-- targeted replacement of its live definition, with a raise if any replacement
-- fails to find its anchor. S6-18 chose this over retyping a function; S7-4
-- retyped a list instead and silently lost a suite, which S7-5 had to restore.
-- The lesson is one commit old, so it is applied here.
--
-- GATE ARITHMETIC, stated so the next run can be reconciled rather than trusted:
--   -4  MD-1/2/3/3a no longer loop over a fourth table
--   -7  MD-9, 9a, 9b, 10, 10a, 10b and MD-19, all about the map itself
--   -2  DS-4 and DS-5 no longer loop over an eleventh table
--   +4  IA-31..IA-34, which assert the removal instead of assuming it
--   792 -> 783
--
-- The rules the deleted assertions protected are NOT lost. The closed
-- 30/45/60/90 list is asserted structurally on pricing_groups by IA-27, and the
-- "a miss reaches 0.500 and never 1.500" rule by IA-11 and IA-12.

do $$
declare
  v_def text; v_oid oid;
  v_pairs text[][];
  v_from text; v_to text; i int;
begin
  -- ============================================ tests.family_d_group_masters
  select p.oid into v_oid from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='family_d_group_masters';
  v_def := pg_catalog.pg_get_functiondef(v_oid);

  v_pairs := array[
    [$q$  v_tables text[] := array['sectors','sector_versions','calculation_default_versions',
                           'payment_interest_map_entries'];$q$,
     $q$  v_tables text[] := array['sectors','sector_versions','calculation_default_versions'];$q$],

    [$q$  -- ------------------------------------------- CDM-18 closed list, structural
  insert into public.payment_interest_map_entries (calculation_default_version_id, credit_days, interest_pct, created_by)
  values (v_cdv, 30, 0.500, v_owner), (v_cdv, 45, 0.750, v_owner),
         (v_cdv, 60, 1.000, v_owner), (v_cdv, 90, 1.500, v_owner);
  return next is((select count(*)::int from public.payment_interest_map_entries
                   where calculation_default_version_id = v_cdv), 4,
                 'MD-9 the four approved Payment Terms map to their approved rates');
  return next is((select interest_pct from public.payment_interest_map_entries
                   where calculation_default_version_id = v_cdv and credit_days = 30), 0.500,
                 'MD-9a 30d resolves to 0.500');
  return next is((select interest_pct from public.payment_interest_map_entries
                   where calculation_default_version_id = v_cdv and credit_days = 90), 1.500,
                 'MD-9b 90d resolves to 1.500');

  begin
    insert into public.payment_interest_map_entries (calculation_default_version_id, credit_days, interest_pct, created_by)
    values (v_cdv, 35, 0.600, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'MD-10 a credit-days value outside 30/45/60/90 is REJECTED BY CONSTRAINT, not by convention');

  -- a map miss has nowhere to land but the independent fallback
  return next is(
    (select count(*)::int from public.payment_interest_map_entries
      where calculation_default_version_id = v_cdv and credit_days = 35), 0,
    'MD-10a so a miss resolves to the 0.500 fallback and can never reach 1.500 (CDM-18)');

  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='payment_interest_map_entries'
        and column_name in ('is_open_ended','band_from','band_to')),
    0, 'MD-10b there is no band or open-ended column - lookup is exact match by ruling');
$q$,
     $q$  -- The CDM-18 map assertions lived here. The map is withdrawn (Amendment 01
  -- A-03) and the rules it protected moved rather than lapsed: the closed
  -- 30/45/60/90 list is asserted structurally on pricing_groups by IA-27, and
  -- "a miss reaches 0.500, never 1.500" by IA-11 and IA-12.
$q$],

    [$q$  begin
    insert into public.payment_interest_map_entries (calculation_default_version_id, credit_days, interest_pct, created_by)
    values (v_cdv, 60, 2.000, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'MD-19 and its Payment Terms map is frozen with it - the approved map cannot gain an entry');
$q$, ''],

    [$q$  delete from public.payment_interest_map_entries where calculation_default_version_id = v_cdv;
$q$, '']
  ];

  for i in 1 .. array_length(v_pairs,1) loop
    v_from := v_pairs[i][1]; v_to := coalesce(v_pairs[i][2], '');
    if position(v_from in v_def) = 0 then
      raise exception 'family_d_group_masters: splice % found no anchor', i;
    end if;
    v_def := replace(v_def, v_from, v_to);
  end loop;
  execute v_def;

  -- ================================================ tests.family_de_security
  select p.oid into v_oid from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='family_de_security';
  v_def := pg_catalog.pg_get_functiondef(v_oid);

  v_pairs := array[
    [$q$                           'payment_interest_map_entries','rate_sets','rate_set_versions',$q$,
     $q$                           'rate_sets','rate_set_versions',$q$],
    [$q$  insert into public.payment_interest_map_entries
    (calculation_default_version_id, credit_days, interest_pct, created_by)
    values (v_cdv, 30, 0.500, v_owner);
$q$, ''],
    [$q$  delete from public.payment_interest_map_entries where calculation_default_version_id = v_cdv;
$q$, '']
  ];
  for i in 1 .. array_length(v_pairs,1) loop
    v_from := v_pairs[i][1]; v_to := coalesce(v_pairs[i][2], '');
    if position(v_from in v_def) = 0 then
      raise exception 'family_de_security: splice % found no anchor', i;
    end if;
    v_def := replace(v_def, v_from, v_to);
  end loop;
  execute v_def;

  -- ===================================================== tests.pricing_basis
  select p.oid into v_oid from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='pricing_basis';
  v_def := pg_catalog.pg_get_functiondef(v_oid);
  v_from := $q$  delete from public.payment_interest_map_entries where calculation_default_version_id = v_cdv;
$q$;
  if position(v_from in v_def) = 0 then
    raise exception 'pricing_basis: splice found no anchor';
  end if;
  execute replace(v_def, v_from, '');

  -- ================================================ tests.interest_authority
  -- The removal is asserted, not assumed.
  select p.oid into v_oid from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='interest_authority';
  v_def := pg_catalog.pg_get_functiondef(v_oid);
  v_from := $q$  -- ------------------------------------------------------------- cleanup$q$;
  if position(v_from in v_def) = 0 then
    raise exception 'interest_authority: splice found no anchor';
  end if;
  v_to := $q$  -- ============================ A-03: the map is GONE, not merely unused
  return next is(
    (select count(*)::int from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname='public' and c.relname='payment_interest_map_entries'),
    0, 'IA-31 payment_interest_map_entries no longer exists - one authority, not two (A-03)');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname='app_private' and p.proname='guard_map_entry_follows_version'),
    0, 'IA-32 and neither does the guard that kept its entries with their version');
  return next is(
    (select count(*)::int from pg_catalog.pg_trigger
      where tgname = 'trg_pime_follows_version' and not tgisinternal),
    0, 'IA-33 nor the trigger - nothing is left behind to be re-enabled by accident');
  return next ok(
    exists (select 1 from pg_catalog.pg_constraint con
              join pg_catalog.pg_class c on c.oid = con.conrelid
             where c.relname='pricing_groups' and con.conname='ck_pg_payment_terms_closed'),
    'IA-34 while the closed 30/45/60/90 list survives on the Pricing Group (A-03)');

  -- ------------------------------------------------------------- cleanup$q$;
  execute replace(v_def, v_from, v_to);
end $$;

-- Now, and only now, the structure itself.
drop trigger if exists trg_pime_follows_version on public.payment_interest_map_entries;
drop table if exists public.payment_interest_map_entries;
drop function if exists app_private.guard_map_entry_follows_version();
