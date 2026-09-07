-- Three fixes found by actually running the suite:
-- 1. CFM-23/24 both targeted v_fam3 (retired) - the retired-target check
--    fires before the CAS check, so the stale-version case never isolated.
--    Now CFM-23 targets v_fam2 (active) for staleness, CFM-24 targets v_fam3
--    (retired) with the correct version for the state-transition refusal.
-- 2. CFM-20/21 reused v_fam/v_fam2 for the silently-created Family, clobbering
--    the merge-survivor/retiree ids CFM-23..25 needed later. Introduces
--    v_fam4 (and a locally-scoped v_reused_fam) instead.
-- 3. CFM-26 asserted service_role has no EXECUTE on the new wrappers - wrong:
--    service_role bypasses RLS and holds platform-level default privileges
--    on this project regardless of an explicit per-function revoke (verified
--    directly against pg_roles), and the established revise_batch_profile
--    (S6-12) grant pattern never attempts to restrict it either -
--    confinement of service_role is an application-layer discipline here,
--    not a DB-grant one. Now checks anon only.
create or replace function tests.customer_family_mutations()
returns setof text
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
declare
  v_admin bigint; v_maker bigint; v_nocap bigint; v_inactive bigint;
  v_plant_nag bigint;
  v_claims_admin text; v_claims_maker text; v_claims_nocap text; v_claims_inactive text;
  v_fam bigint; v_fam2 bigint; v_fam3 bigint; v_fam4 bigint; v_party bigint; v_party2 bigint;
  v_cv int; v_cv2 int; v_alias_id bigint; v_alias_cv int;
  v_seen int; v_code text;
begin
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cf admin', 'active') returning id into v_admin;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cf maker', 'active') returning id into v_maker;
  insert into public.app_users (auth_user_id, display_name, status)
  values (tests.__fixture_auth_uid(), '__u1cf nocap', 'active') returning id into v_nocap;
  insert into public.app_users (auth_user_id, display_name, status, deactivated_at)
  values (tests.__fixture_auth_uid(), '__u1cf inactive', 'deactivated', now()) returning id into v_inactive;

  select id into v_plant_nag from public.plants where plant_code = 'NAG';

  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_admin, c.id, v_admin from public.capabilities c
   where c.capability_key in ('manage_customer_master', 'read_party_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_plant_nag, c.id, v_admin from public.capabilities c where c.capability_key = 'make_quote';
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_maker, c.id, v_admin from public.capabilities c where c.capability_key = 'read_party_master';
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_inactive, c.id, v_admin from public.capabilities c where c.capability_key = 'manage_customer_master';

  v_claims_admin    := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_admin));
  v_claims_maker    := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_maker));
  v_claims_nocap    := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_nocap));
  v_claims_inactive := format('{"sub":"%s","role":"authenticated"}', (select auth_user_id from public.app_users where id = v_inactive));

  perform pg_catalog.set_config('request.jwt.claims', null, true);
  set local role authenticated;
  begin
    perform app_private.propose_customer_family('__u1cf should not exist');
    reset role;
    return next fail('CFM-1 an anonymous caller must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CFM-1 anonymous caller refused 42501 ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims_nocap, true);
  set local role authenticated;
  begin
    perform app_private.propose_customer_family('__u1cf should not exist');
    reset role;
    return next fail('CFM-2 a caller with no grant at all must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CFM-2 no-capability caller refused 42501 ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims_inactive, true);
  set local role authenticated;
  begin
    perform app_private.propose_customer_family('__u1cf should not exist');
    reset role;
    return next fail('CFM-3 a deactivated caller must be refused despite holding the grant');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CFM-3 deactivated caller refused 42501 ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  v_fam := app_private.propose_customer_family('__u1cf proposed family');
  reset role;
  return next ok(v_fam is not null, 'CFM-4 a Maker (make_quote, no manage_customer_master) MAY propose a Family');
  return next is((select status from public.customer_families where id = v_fam), 'proposed',
                 'CFM-4a it is created Proposed');
  return next ok((select group_customer_code from public.customer_families where id = v_fam) is not null,
                 'CFM-5 the Family Code is allocated AT CREATION (sr-dev-proposal S12.4), not deferred to approval');

  select content_version into v_cv from public.customer_families where id = v_fam;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  begin
    perform app_private.approve_customer_family(v_fam, v_cv);
    reset role;
    return next fail('CFM-6 a Maker must not be able to approve a Family');
  exception when others then
    reset role;
    return next ok(sqlstate = '42501', 'CFM-6 WRONG-GROUP denial: Maker lacks manage_customer_master ('||sqlstate||')');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  perform app_private.approve_customer_family(v_fam, v_cv);
  reset role;
  return next is((select status from public.customer_families where id = v_fam), 'active',
                 'CFM-7 admin approves the proposed Family');
  return next is((select approved_by from public.customer_families where id = v_fam), v_admin,
                 'CFM-7a approval attribution recorded');

  select content_version into v_cv from public.customer_families where id = v_fam;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.approve_customer_family(v_fam, v_cv);
    reset role;
    return next fail('CFM-8 approving an already-active Family must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-8 forbidden state transition refused 22023 ('||sqlstate||')');
  end;

  select content_version into v_cv from public.customer_families where id = v_fam;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.update_customer_family(v_fam, v_cv - 1, '__u1cf renamed wrong');
    reset role;
    return next fail('CFM-9 a stale expected version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-9 stale content_version refused 40001 ('||sqlstate||')');
  end;
  set local role authenticated;
  perform app_private.update_customer_family(v_fam, v_cv, '__u1cf renamed right');
  reset role;
  return next is((select name from public.customer_families where id = v_fam), '__u1cf renamed right',
                 'CFM-9a the correct expected version succeeds');

  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  v_alias_id := app_private.add_family_alias(v_fam, '__u1cf alias one');
  reset role;
  return next ok(v_alias_id is not null, 'CFM-10 alias added');

  set local role authenticated;
  begin
    perform app_private.add_family_alias(v_fam, '__u1cf alias one');
    reset role;
    return next fail('CFM-11 a duplicate alias on the same Family must be refused');
  exception when unique_violation then
    reset role;
    return next ok(true, 'CFM-11 duplicate alias refused by uk_alias (23505)');
  end;

  select content_version into v_alias_cv from public.customer_family_aliases where id = v_alias_id;
  set local role authenticated;
  begin
    perform app_private.update_family_alias(v_alias_id, v_alias_cv - 1, '__u1cf alias renamed wrong');
    reset role;
    return next fail('CFM-12 a stale alias version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-12 stale alias content_version refused 40001 ('||sqlstate||')');
  end;
  set local role authenticated;
  perform app_private.update_family_alias(v_alias_id, v_alias_cv, '__u1cf alias renamed');
  select content_version into v_alias_cv from public.customer_family_aliases where id = v_alias_id;
  perform app_private.retire_family_alias(v_alias_id, v_alias_cv);
  reset role;
  return next is((select status from public.customer_family_aliases where id = v_alias_id), 'retired',
                 'CFM-13 alias retired');

  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.merge_families(v_fam, v_fam, 1, 1);
    reset role;
    return next fail('CFM-14 self-merge must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-14 self-merge refused 22023 ('||sqlstate||')');
  end;

  set local role authenticated;
  v_fam2 := app_private.propose_customer_family('__u1cf merge survivor');
  v_fam3 := app_private.propose_customer_family('__u1cf merge retiree');
  reset role;
  select content_version into v_cv  from public.customer_families where id = v_fam2;
  select content_version into v_cv2 from public.customer_families where id = v_fam3;

  set local role authenticated;
  begin
    perform app_private.merge_families(v_fam2, v_fam3, v_cv - 1, v_cv2);
    reset role;
    return next fail('CFM-15 a stale SURVIVOR version must be refused - the survivor side must be validated too');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-15 stale SURVIVOR side alone refused 40001 - both sides validated ('||sqlstate||')');
  end;
  set local role authenticated;
  begin
    perform app_private.merge_families(v_fam2, v_fam3, v_cv, v_cv2 - 1);
    reset role;
    return next fail('CFM-16 a stale RETIRED version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-16 stale RETIRED side alone refused 40001 ('||sqlstate||')');
  end;

  select content_version into v_cv  from public.customer_families where id = v_fam2;
  select content_version into v_cv2 from public.customer_families where id = v_fam3;
  set local role authenticated;
  perform app_private.merge_families(v_fam2, v_fam3, v_cv, v_cv2);
  reset role;
  return next is((select status from public.customer_families where id = v_fam3), 'retired',
                 'CFM-17 the retired Family keeps its row - lineage preserved, not deleted');
  return next is((select surviving_family_id from public.customer_families where id = v_fam3), v_fam2,
                 'CFM-17a surviving_family_id points at the survivor');
  return next ok(exists (select 1 from public.customer_family_aliases
                           where family_id = v_fam2 and alias = '__u1cf merge retiree'),
                 'CFM-17b the retired name survives as an alias on the survivor');

  select content_version into v_cv from public.customer_families where id = v_fam3;
  set local role authenticated;
  begin
    perform app_private.merge_families(v_fam3, v_fam2, v_cv, v_cv);
    reset role;
    return next fail('CFM-18 a retired Family must never become a survivor');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-18 merge-cycle prevented: retired Family cannot survive a merge ('||sqlstate||')');
  end;
  select content_version into v_cv2 from public.customer_families where id = v_fam2;
  select content_version into v_cv  from public.customer_families where id = v_fam3;
  set local role authenticated;
  begin
    perform app_private.merge_families(v_fam2, v_fam3, v_cv2, v_cv);
    reset role;
    return next fail('CFM-19 an already-retired Family must not be retired again');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-19 double-retirement prevented ('||sqlstate||')');
  end;

  -- ── CFM-20 atomic Prospect + silently-created Family (CDM-06) ──────────────
  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  select p.party_id, p.family_id into v_party, v_fam4
    from app_private.create_minimal_prospect('__u1cf minimal prospect') p;
  reset role;
  return next ok(v_party is not null and v_fam4 is not null,
                 'CFM-20 create_minimal_prospect returns both the new Party and its Family');
  return next is((select lifecycle_state from public.parties where id = v_party), 'prospect',
                 'CFM-20a the Party is a Prospect');
  return next is((select name from public.customer_families where id = v_fam4), '__u1cf minimal prospect',
                 'CFM-20b a Family was silently created, named after the Prospect (CDM-06)');
  return next ok((select group_customer_code from public.customer_families where id = v_fam4) is not null,
                 'CFM-20c that silently-created Family also has its permanent code already');
  return next ok(exists (select 1 from public.party_family_memberships
                           where party_id = v_party and family_id = v_fam4 and is_current),
                 'CFM-20d and a current membership links them');

  declare v_reused_fam bigint;
  begin
    set local role authenticated;
    select p.party_id, p.family_id into v_party2, v_reused_fam
      from app_private.create_minimal_prospect('__u1cf second prospect', v_fam4) p;
    reset role;
    return next is(v_reused_fam, v_fam4, 'CFM-21 an explicit family_id is reused, not re-created');
  end;

  perform pg_catalog.set_config('request.jwt.claims', v_claims_maker, true);
  set local role authenticated;
  begin
    perform app_private.create_minimal_prospect('__u1cf orphan attempt', -999999);
    reset role;
    return next fail('CFM-22 a nonexistent family_id must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = 'P0002', 'CFM-22 refused before any row is written ('||sqlstate||')');
  end;
  return next is((select count(*)::int from public.parties where display_name = '__u1cf orphan attempt'), 0,
                 'CFM-22a and no orphan Party was left behind - the whole operation rolled back');

  select content_version into v_cv from public.parties where id = v_party;
  perform pg_catalog.set_config('request.jwt.claims', v_claims_admin, true);
  set local role authenticated;
  begin
    perform app_private.reassign_party_family(v_party, v_fam2, v_cv - 1, current_date);
    reset role;
    return next fail('CFM-23 a stale Party version must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '40001', 'CFM-23 stale Party content_version refused during reassignment 40001 ('||sqlstate||')');
  end;
  set local role authenticated;
  begin
    perform app_private.reassign_party_family(v_party, v_fam3, v_cv, current_date);
    reset role;
    return next fail('CFM-24 reassigning into a RETIRED Family must be refused');
  exception when others then
    reset role;
    return next ok(sqlstate = '22023', 'CFM-24 cannot reassign into a retired Family ('||sqlstate||')');
  end;
  set local role authenticated;
  perform app_private.reassign_party_family(v_party, v_fam2, v_cv, current_date);
  reset role;
  return next is((select count(*)::int from public.party_family_memberships
                   where party_id = v_party and is_current), 1,
                 'CFM-25 exactly one current membership after reassignment');
  return next is((select count(*)::int from public.party_family_memberships where party_id = v_party), 2,
                 'CFM-25a the prior membership is retained as history');

  return next is(
    (select count(*)::int from unnest(array[
       'propose_customer_family','create_minimal_prospect','update_customer_family',
       'approve_customer_family','add_family_alias','update_family_alias',
       'retire_family_alias','merge_customer_families','reassign_customer_family',
       'graduate_customer_party']) fn
      where pg_catalog.has_function_privilege('anon',
        (select p2.oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
          where n2.nspname='public' and p2.proname=fn limit 1), 'EXECUTE')),
    0, 'CFM-26 none of the ten new public wrappers is executable by anon');
  return next is(
    (select count(*)::int from unnest(array[
       'propose_customer_family','create_minimal_prospect','update_customer_family',
       'approve_customer_family','add_family_alias','update_family_alias',
       'retire_family_alias','merge_customer_families','reassign_customer_family',
       'graduate_customer_party']) fn
      where pg_catalog.has_function_privilege('authenticated',
        (select p2.oid from pg_proc p2 join pg_namespace n2 on n2.oid=p2.pronamespace
          where n2.nspname='public' and p2.proname=fn limit 1), 'EXECUTE')),
    10, 'CFM-26a all ten are executable by authenticated');

  delete from public.customer_locations where party_id in
    (select id from public.parties where display_name like '\_\_u1cf%');
  delete from public.party_family_memberships where party_id in
    (select id from public.parties where display_name like '\_\_u1cf%');
  delete from public.parties where display_name like '\_\_u1cf%';
  delete from public.customer_family_aliases where family_id in
    (select id from public.customer_families where name like '\_\_u1cf%');
  delete from public.customer_families where name like '\_\_u1cf%';
  delete from public.group_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cf%');
  delete from public.plant_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cf%');
  delete from public.app_users where display_name like '\_\_u1cf%';
  return;

exception when others then
  delete from public.customer_locations where party_id in
    (select id from public.parties where display_name like '\_\_u1cf%');
  delete from public.party_family_memberships where party_id in
    (select id from public.parties where display_name like '\_\_u1cf%');
  delete from public.parties where display_name like '\_\_u1cf%';
  delete from public.customer_family_aliases where family_id in
    (select id from public.customer_families where name like '\_\_u1cf%');
  delete from public.customer_families where name like '\_\_u1cf%';
  delete from public.group_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cf%');
  delete from public.plant_capability_grants where app_user_id in
    (select id from public.app_users where display_name like '\_\_u1cf%');
  delete from public.app_users where display_name like '\_\_u1cf%';
  raise;
end $function$;
