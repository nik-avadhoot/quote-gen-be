-- Family B governed mutations - functions, wrappers, grants.
--
-- CAPABILITY MODEL. Mirrors the existing RLS exactly, re-derived from
-- pg_policies rather than assumed:
--   propose a Family / a Prospect   : manage_customer_master OR make_quote
--                                     at any active plant (has_any_plant_cap)
--   everything else in this file    : manage_customer_master only
-- The database enforces this inside app_private.*, not in Flask (U1-C review
-- item 4) - a public wrapper below is SECURITY INVOKER and adds no check of
-- its own.
--
-- FAMILY CODE TIMING. data-model-sr-dev-proposal.md S12.4 states explicitly,
-- in a table that also distinguishes Construction Code (publication, NOT
-- proposal): "Family Code | group | Family creation". propose_customer_family
-- therefore allocates the code in the same statement that inserts the row,
-- not deferred to approval. This corrects the U1 packet's first draft, which
-- assumed (from the pre-existing test fixture's separate raw UPDATE) that
-- allocation was a later step - that fixture predates any propose/approve
-- operation existing at all and was never evidence of timing.
--
-- CAS EVERYWHERE MUTABLE. Every function that changes an existing row takes
-- a required p_expected_content_version - no default, so no caller can skip
-- the check (U1-C review item 1). The technique is the established one
-- (app_private.revise_batch_profile, S6-12): a self-referential UPDATE
-- guarded by content_version = p_expected is the compare-and-swap; zero rows
-- affected means someone moved first, and 40001 is the conflict code.
--
-- ATOMICITY. Each governed operation is one PL/pgSQL function, so Postgres's
-- own implicit transaction is the atomicity guarantee - no partial effect
-- can survive an exception anywhere inside the function body.

-- ═══════════════════════════════ propose a Family ══════════════════════════
create or replace function app_private.propose_customer_family(p_name text)
returns bigint
language plpgsql security definer set search_path to '' as $fn$
declare v_me bigint; v_code text; v_id bigint;
begin
  if not (app_private.has_group_cap('manage_customer_master')
          or app_private.has_any_plant_cap('make_quote')) then
    raise exception 'manage_customer_master or make_quote at an active plant required'
      using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'a Family name is required' using errcode = '22023';
  end if;

  v_code := app_private.allocate_group_customer_code();

  insert into public.customer_families (name, status, group_customer_code, created_by)
  values (btrim(p_name), 'proposed', v_code, v_me)
  returning id into v_id;

  return v_id;
end $fn$;

-- ══════════════════ atomic minimal Prospect (CDM-06) ═══════════════════════
create or replace function app_private.create_minimal_prospect(
  p_display_name text, p_family_id bigint default null)
returns table(party_id bigint, family_id bigint)
language plpgsql security definer set search_path to '' as $fn$
declare v_me bigint; v_party bigint; v_family bigint;
begin
  if not (app_private.has_group_cap('manage_customer_master')
          or app_private.has_any_plant_cap('make_quote')) then
    raise exception 'manage_customer_master or make_quote at an active plant required'
      using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if p_display_name is null or btrim(p_display_name) = '' then
    raise exception 'a display name is required' using errcode = '22023';
  end if;

  if p_family_id is not null then
    -- reuse an EXISTING Family, named by the caller - lock it so a concurrent
    -- retirement/merge cannot leave the new membership pointing at a dead row
    declare v_status text;
    begin
      select status into v_status from public.customer_families
       where id = p_family_id for update;
      if not found then
        raise exception 'Family not found' using errcode = 'P0002';
      end if;
      if v_status = 'retired' then
        raise exception 'that Family is retired - use its surviving Family instead'
          using errcode = '22023';
      end if;
    end;
    v_family := p_family_id;
  else
    -- CDM-06: "silently establishes a Proposed Family when necessary" - no
    -- Family was named, so one is created for this Prospect, sharing its name
    v_family := app_private.propose_customer_family(p_display_name);
  end if;

  insert into public.parties (display_name, lifecycle_state, status, created_by)
  values (btrim(p_display_name), 'prospect', 'proposed', v_me)
  returning id into v_party;

  insert into public.party_family_memberships
    (party_id, family_id, effective_from, is_current, created_by)
  values (v_party, v_family, current_date, true, v_me);

  return query select v_party, v_family;
end $fn$;

-- ══════════════════════ edit / approve a Family ═════════════════════════════
create or replace function app_private.update_customer_family(
  p_family bigint, p_expected_content_version integer, p_name text)
returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_n int;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_expected_content_version is null then
    raise exception 'the Family content version you read must be supplied' using errcode = '22023';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'a Family name is required' using errcode = '22023';
  end if;

  update public.customer_families
     set name = btrim(p_name), content_version = content_version + 1
   where id = p_family and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    perform 1 from public.customer_families where id = p_family;
    if not found then
      raise exception 'Family not found' using errcode = 'P0002';
    end if;
    raise exception 'the Family changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = '40001';
  end if;
end $fn$;

create or replace function app_private.approve_customer_family(
  p_family bigint, p_expected_content_version integer)
returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_me bigint; v_n int; v_status text;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if p_expected_content_version is null then
    raise exception 'the Family content version you read must be supplied' using errcode = '22023';
  end if;

  select status into v_status from public.customer_families where id = p_family for update;
  if not found then
    raise exception 'Family not found' using errcode = 'P0002';
  end if;
  if v_status <> 'proposed' then
    raise exception 'only a proposed Family may be approved (currently %)', v_status
      using errcode = '22023';
  end if;

  update public.customer_families
     set status = 'active', approved_by = v_me, approved_at = now(),
         content_version = content_version + 1
   where id = p_family and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'the Family changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = '40001';
  end if;
end $fn$;

-- ═══════════════════════════════ aliases ════════════════════════════════════
create or replace function app_private.add_family_alias(p_family bigint, p_alias text)
returns bigint
language plpgsql security definer set search_path to '' as $fn$
declare v_me bigint; v_id bigint;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  v_me := app_private.current_app_user();
  if p_alias is null or btrim(p_alias) = '' then
    raise exception 'an alias is required' using errcode = '22023';
  end if;
  perform 1 from public.customer_families where id = p_family;
  if not found then
    raise exception 'Family not found' using errcode = 'P0002';
  end if;

  insert into public.customer_family_aliases (family_id, alias, created_by)
  values (p_family, btrim(p_alias), v_me)
  returning id into v_id;

  return v_id;
end $fn$;

create or replace function app_private.update_family_alias(
  p_alias_id bigint, p_expected_content_version integer, p_alias text)
returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_n int;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_expected_content_version is null then
    raise exception 'the alias content version you read must be supplied' using errcode = '22023';
  end if;
  if p_alias is null or btrim(p_alias) = '' then
    raise exception 'an alias is required' using errcode = '22023';
  end if;

  update public.customer_family_aliases
     set alias = btrim(p_alias), content_version = content_version + 1
   where id = p_alias_id and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    perform 1 from public.customer_family_aliases where id = p_alias_id;
    if not found then
      raise exception 'alias not found' using errcode = 'P0002';
    end if;
    raise exception 'the alias changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = '40001';
  end if;
end $fn$;

create or replace function app_private.retire_family_alias(
  p_alias_id bigint, p_expected_content_version integer)
returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_n int; v_status text;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_expected_content_version is null then
    raise exception 'the alias content version you read must be supplied' using errcode = '22023';
  end if;

  select status into v_status from public.customer_family_aliases where id = p_alias_id for update;
  if not found then
    raise exception 'alias not found' using errcode = 'P0002';
  end if;
  if v_status = 'retired' then
    raise exception 'alias is already retired' using errcode = '22023';
  end if;

  update public.customer_family_aliases
     set status = 'retired', content_version = content_version + 1
   where id = p_alias_id and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'the alias changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = '40001';
  end if;
end $fn$;

-- ═══════════════════════ merge, with dual-sided CAS ═════════════════════════
-- CHANGED SIGNATURE. The pre-existing merge_families(p_survivor, p_retired)
-- had no public wrapper and was therefore unreachable by any caller - this
-- is safe to change; tests.party_masters()/fixtures_matrix() never called it.
create or replace function app_private.merge_families(
  p_survivor bigint, p_retired bigint,
  p_expected_survivor_version integer, p_expected_retired_version integer)
returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_me bigint; v_n int; v_survivor_status text; v_retired_status text;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_survivor = p_retired then
    raise exception 'a family cannot merge into itself' using errcode = '22023';
  end if;
  if p_expected_survivor_version is null or p_expected_retired_version is null then
    raise exception 'both content versions you read must be supplied' using errcode = '22023';
  end if;
  v_me := app_private.current_app_user();

  select status into v_survivor_status from public.customer_families
   where id = p_survivor for update;
  if not found then
    raise exception 'survivor Family not found' using errcode = 'P0002';
  end if;
  select status into v_retired_status from public.customer_families
   where id = p_retired for update;
  if not found then
    raise exception 'retiring Family not found' using errcode = 'P0002';
  end if;

  -- cycle prevention: the survivor must not itself already be a retired
  -- shell pointing somewhere else, and the retired side must not already be
  -- retired (which would mean merging an already-merged family a second time)
  if v_survivor_status = 'retired' then
    raise exception 'the surviving Family is itself retired - merge into its current survivor instead'
      using errcode = '22023';
  end if;
  if v_retired_status = 'retired' then
    raise exception 'that Family is already retired' using errcode = '22023';
  end if;

  -- dual-sided CAS: touch both rows with their own expected version before
  -- either is changed, so a concurrent edit on EITHER side is caught
  update public.customer_families set content_version = content_version
   where id = p_survivor and content_version = p_expected_survivor_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'the surviving Family changed since you read it (expected content version %) - re-read and retry',
      p_expected_survivor_version using errcode = '40001';
  end if;

  update public.customer_families set content_version = content_version
   where id = p_retired and content_version = p_expected_retired_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'the retiring Family changed since you read it (expected content version %) - re-read and retry',
      p_expected_retired_version using errcode = '40001';
  end if;

  -- the retired family's name survives as an alias of the survivor
  insert into public.customer_family_aliases (family_id, alias, created_by)
  select p_survivor, f.name, v_me
    from public.customer_families f
   where f.id = p_retired
  on conflict (family_id, alias) do nothing;

  update public.customer_families
     set status = 'retired',
         surviving_family_id = p_survivor,
         content_version = content_version + 1
   where id = p_retired;
end $fn$;

-- ═══════════════════ reassignment, now with CAS on the Party ═══════════════
-- CHANGED SIGNATURE. p_expected_content_version added (required, no
-- default). The one existing caller (tests.fixtures_matrix(), L-5/L-6/L-7)
-- is updated in the companion tests migration.
create or replace function app_private.reassign_party_family(
  p_party bigint, p_new_family bigint, p_expected_content_version integer,
  p_effective date default current_date)
returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_current public.party_family_memberships%rowtype; v_me bigint; v_n int;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_expected_content_version is null then
    raise exception 'the Party content version you read must be supplied' using errcode = '22023';
  end if;
  v_me := app_private.current_app_user();

  perform 1 from public.parties where id = p_party for update;
  if not found then
    raise exception 'party not found' using errcode = 'P0002';
  end if;
  declare v_target_status text;
  begin
    select status into v_target_status from public.customer_families where id = p_new_family;
    if not found then
      raise exception 'target Family not found' using errcode = 'P0002';
    end if;
    if v_target_status = 'retired' then
      raise exception 'target Family is retired - use its surviving Family instead'
        using errcode = '22023';
    end if;
  end;

  -- the Party's own CAS protects against a concurrent reassignment OR a
  -- concurrent edit of the Party while this call was in flight
  update public.parties set content_version = content_version
   where id = p_party and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'the Party changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = '40001';
  end if;

  select * into v_current
    from public.party_family_memberships
   where party_id = p_party and is_current
   for update;

  if v_current.family_id = p_new_family then
    return;                                        -- already there; no-op
  end if;

  if v_current.id is not null then
    if p_effective < v_current.effective_from then
      raise exception 'effective date precedes the current membership'
        using errcode = '22007';
    end if;
    update public.party_family_memberships
       set is_current = false, effective_until = p_effective
     where id = v_current.id;
  end if;

  update public.parties set content_version = content_version + 1 where id = p_party;

  insert into public.party_family_memberships
    (party_id, family_id, effective_from, is_current, created_by)
  values (p_party, p_new_family, p_effective, true, v_me);
end $fn$;

-- ═══════════════════ public invoker wrappers ════════════════════════════════
-- SECURITY INVOKER, language sql - the shim does nothing privileged; it
-- exists only so PostgREST can route an authenticated caller's own token to
-- the SECURITY DEFINER app_private function, which enforces everything.

create or replace function public.propose_customer_family(p_name text)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.propose_customer_family(p_name);
$fn$;

create or replace function public.create_minimal_prospect(
  p_display_name text, p_family_id bigint default null)
returns table(party_id bigint, family_id bigint)
language sql security invoker set search_path = '' as $fn$
  select * from app_private.create_minimal_prospect(p_display_name, p_family_id);
$fn$;

create or replace function public.update_customer_family(
  p_family bigint, p_expected_content_version integer, p_name text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.update_customer_family(p_family, p_expected_content_version, p_name);
$fn$;

create or replace function public.approve_customer_family(
  p_family bigint, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.approve_customer_family(p_family, p_expected_content_version);
$fn$;

create or replace function public.add_family_alias(p_family bigint, p_alias text)
returns bigint language sql security invoker set search_path = '' as $fn$
  select app_private.add_family_alias(p_family, p_alias);
$fn$;

create or replace function public.update_family_alias(
  p_alias_id bigint, p_expected_content_version integer, p_alias text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.update_family_alias(p_alias_id, p_expected_content_version, p_alias);
$fn$;

create or replace function public.retire_family_alias(
  p_alias_id bigint, p_expected_content_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.retire_family_alias(p_alias_id, p_expected_content_version);
$fn$;

create or replace function public.merge_customer_families(
  p_survivor bigint, p_retired bigint,
  p_expected_survivor_version integer, p_expected_retired_version integer)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.merge_families(p_survivor, p_retired,
    p_expected_survivor_version, p_expected_retired_version);
$fn$;

create or replace function public.reassign_customer_family(
  p_party bigint, p_new_family bigint, p_expected_content_version integer,
  p_effective date default current_date)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.reassign_party_family(p_party, p_new_family,
    p_expected_content_version, p_effective);
$fn$;

create or replace function public.graduate_customer_party(p_party bigint)
returns text language sql security invoker set search_path = '' as $fn$
  select app_private.graduate_party(p_party);
$fn$;

-- ═══════════════════════ grant / revoke posture ═════════════════════════════
-- Exactly the established pattern (S6-12): revoke from everyone, including
-- PUBLIC (which already covers anon/service_role by default membership) and
-- anon explicitly for defense in depth, then grant to authenticated only.
do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('propose_customer_family', 'create_minimal_prospect',
         'update_customer_family', 'approve_customer_family', 'add_family_alias',
         'update_family_alias', 'retire_family_alias', 'merge_customer_families',
         'reassign_customer_family', 'graduate_customer_party')
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;
