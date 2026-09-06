-- S5-3: executable proof gates for the Pricing Basis Release.
--
-- The two gates §16.2 names for S5 are PB-10 (alternatives may overlap, defaults
-- may not) and PB-12..15 (an unapproved component is rejected). Both are proved
-- against the constraint and the trigger rather than against the RPC, because a
-- rule that only the RPC enforces is bypassed by any later write path that
-- forgets to call it.

create or replace function tests.pricing_basis()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_state text; v_seen int; v_owner bigint; v_nag bigint; v_pun bigint;
  v_pauth uuid; v_pclaims text; v_proposer bigint; v_pemail text := 'p2-s5bp@example.invalid';
  v_aauth uuid; v_aclaims text; v_approver bigint; v_aemail text := 'p2-s5ba@example.invalid';
  v_bauth uuid; v_bclaims text; v_both bigint;     v_bemail text := 'p2-s5bb@example.invalid';
  v_party bigint; v_loc bigint;
  v_rs bigint; v_rsv bigint; v_rsv_draft bigint;
  v_fs bigint; v_fsv bigint; v_sec bigint; v_sv bigint; v_cdv bigint;
  v_rs_pun bigint; v_rsv_pun bigint;
  v_rel bigint; v_rel2 bigint; v_rel3 bigint; v_rel4 bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';

  -- ---------------------------------------------------------- structural
  return next ok(
    (select relrowsecurity and relforcerowsecurity from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='pricing_basis_releases'),
    'PB-1 pricing_basis_releases has RLS enabled AND forced');
  return next ok(
    not (pg_catalog.has_table_privilege('anon','public.pricing_basis_releases','SELECT')
      or pg_catalog.has_table_privilege('anon','public.pricing_basis_releases','INSERT')
      or pg_catalog.has_table_privilege('anon','public.pricing_basis_releases','UPDATE')
      or pg_catalog.has_table_privilege('anon','public.pricing_basis_releases','DELETE')),
    'PB-2 anon holds no privilege of any kind on it');
  return next is(
    (select count(*)::int from pg_catalog.pg_policy pol
       join pg_catalog.pg_class c on c.oid=pol.polrelid
       join pg_catalog.pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='pricing_basis_releases' and pol.polcmd='d'),
    0, 'PB-3 it has no DELETE policy - a Release is withdrawn, never deleted (CDM-26)');
  return next is(
    (select coalesce(max(cnt),0)::int from (
       select count(*) cnt from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid=pol.polrelid
         join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname='pricing_basis_releases'
        group by pol.polcmd) q),
    1, 'PB-4 exactly one permissive policy per action - the §7.5 consolidation');

  return next ok((select count(*) from pg_extension where extname='btree_gist') = 1,
                 'PB-5 btree_gist is installed - the = operator class the exclusion needs');
  return next ok(
    (select count(*) from pg_catalog.pg_constraint
      where conname='ex_pbr_default_no_overlap' and contype='x') = 1,
    'PB-6 the default-coverage rule is an EXCLUSION CONSTRAINT, not an RPC check');
  return next ok(
    (select pg_get_constraintdef(oid) like '%WHERE (is_automatic_default AND%'
       from pg_catalog.pg_constraint where conname='ex_pbr_default_no_overlap'),
    'PB-6a and it is PARTIAL - it constrains approved defaults only, never alternatives');

  -- all four components are structurally mandatory (amendment 3)
  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='pricing_basis_releases'
        and column_name in ('rate_set_version_id','freight_set_version_id',
                            'sector_version_id','calculation_default_version_id')
        and is_nullable='NO'),
    4, 'PB-7 all four components are NOT NULL typed FKs - CDM-26 arity is structural');

  -- ---------------------------------------------------------- personas
  v_pauth := tests.__fixture_auth_uid();
  v_pclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_pauth, v_pemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_pemail, '__p2_s5b_proposer', false);
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated; v_proposer := public.bootstrap_app_user(); reset role;

  v_aauth := tests.__fixture_auth_uid();
  v_aclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_aauth, v_aemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_aemail, '__p2_s5b_approver', false);
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated; v_approver := public.bootstrap_app_user(); reset role;

  v_bauth := tests.__fixture_auth_uid();
  v_bclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_bauth, v_bemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_bemail, '__p2_s5b_both', false);
  perform pg_catalog.set_config('request.jwt.claims', v_bclaims, true);
  set local role authenticated; v_both := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_proposer, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','propose_commercial_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_approver, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','approve_commercial_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_both, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','propose_commercial_master','approve_commercial_master');

  -- ------------------------------------------- approved component fixtures
  insert into public.parties (display_name, created_by) values ('__p2 pb party', v_owner) returning id into v_party;
  insert into public.customer_locations (party_id, bill_to_eligible, ship_to_eligible, created_by)
    values (v_party, true, true, v_owner) returning id into v_loc;

  insert into public.rate_sets (plant_id, name, created_by) values (v_nag,'__p2 pb rs',v_owner) returning id into v_rs;
  insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
    values (v_rs, v_nag, 1, v_owner) returning id into v_rsv;
  insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
    values (v_rs, v_nag, 2, v_owner) returning id into v_rsv_draft;
  insert into public.freight_sets (plant_id, name, created_by) values (v_nag,'__p2 pb fs',v_owner) returning id into v_fs;
  insert into public.freight_set_versions (freight_set_id, plant_id, version_no, created_by)
    values (v_fs, v_nag, 1, v_owner) returning id into v_fsv;
  insert into public.sectors (sector_code, name, created_by) values ('__P2PB','__p2 pb sector',v_owner) returning id into v_sec;
  insert into public.sector_versions (sector_id, version_no, margin_pct, created_by)
    values (v_sec, 1, 8.000, v_owner) returning id into v_sv;
  insert into public.calculation_default_versions (version_no, engine_version, rounding_rule_version, created_by)
    values (901, 'engine-pb', 'round-pb', v_owner) returning id into v_cdv;
  -- a PUN rate version, for the cross-plant component gate
  insert into public.rate_sets (plant_id, name, created_by) values (v_pun,'__p2 pb rs pun',v_owner) returning id into v_rs_pun;
  insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
    values (v_rs_pun, v_pun, 1, v_owner) returning id into v_rsv_pun;

  -- approve every component through its own matrix, as the approver
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  update public.rate_set_versions        set status='approved' where id = v_rsv;
  update public.freight_set_versions     set status='approved' where id = v_fsv;
  update public.sector_versions          set status='approved' where id = v_sv;
  update public.calculation_default_versions set status='approved' where id = v_cdv;
  reset role;
  return next is((select status from public.rate_set_versions where id=v_rsv), 'approved',
                 'PB-8 the component fixtures are approved through their own matrices');

  -- ------------------------------------------- V-3: unapproved components
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    perform public.propose_pricing_basis_release(v_nag, date '2026-01-01', v_rsv_draft, v_fsv, v_sv, v_cdv);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'PB-9 a Release citing a DRAFT rate version is rejected (V-3, by trigger not by RPC)');

  -- the trigger binds the table owner too, where an RPC check would not reach
  begin
    insert into public.pricing_basis_releases
      (plant_id, effective_from, rate_set_version_id, freight_set_version_id,
       sector_version_id, calculation_default_version_id, proposed_by)
    values (v_nag, date '2026-01-01', v_rsv_draft, v_fsv, v_sv, v_cdv, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'PB-9a and refuses the same write made AS THE TABLE OWNER - V-3 resolved by trigger');

  -- cross-plant component: a NAG Release may not cite a PUN rate version
  begin
    insert into public.pricing_basis_releases
      (plant_id, effective_from, rate_set_version_id, freight_set_version_id,
       sector_version_id, calculation_default_version_id, proposed_by)
    values (v_nag, date '2026-01-01', v_rsv_pun, v_fsv, v_sv, v_cdv, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'PB-10 a Release cannot cite another plant component - the composite FK binds plant_id');

  -- ------------------------------------------- propose, approve, withdraw
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  v_rel := public.propose_pricing_basis_release(v_nag, date '2026-01-01', v_rsv, v_fsv, v_sv, v_cdv,
                                                null, '__p2 pb release one');
  reset role;
  return next is((select status from public.pricing_basis_releases where id=v_rel), 'draft',
                 'PB-11 a proposer creates a DRAFT Release');
  return next is((select proposed_by from public.pricing_basis_releases where id=v_rel), v_proposer,
                 'PB-11a attributed to the caller from the session (CDM-34)');

  -- N-P1: propose does not confer approve
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    perform public.approve_pricing_basis_release(v_rel, false);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'PB-12 (N-P1) propose_commercial_master alone CANNOT approve a Release (CDM-27)');

  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  perform public.approve_pricing_basis_release(v_rel, true);
  reset role;
  return next is((select status from public.pricing_basis_releases where id=v_rel), 'approved',
                 'PB-13 the approver approves it as the automatic default');
  return next is((select approved_by from public.pricing_basis_releases where id=v_rel), v_approver,
                 'PB-13a with attribution written by the trigger, not the client');
  return next ok((select not self_approved from public.pricing_basis_releases where id=v_rel),
                 'PB-13b and self_approved is false - proposer and approver differ (CDM-27)');

  -- ------------------------- CDM-26: alternatives may overlap, defaults may not
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  v_rel2 := public.propose_pricing_basis_release(v_nag, date '2026-06-01', v_rsv, v_fsv, v_sv, v_cdv,
                                                 null, '__p2 pb alternative');
  reset role;
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    perform public.approve_pricing_basis_release(v_rel2, false);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR',
    'PB-14 an approved ALTERNATIVE may overlap an approved default freely (CDM-26)');

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  v_rel3 := public.propose_pricing_basis_release(v_nag, date '2026-06-01', v_rsv, v_fsv, v_sv, v_cdv,
                                                 null, '__p2 pb second default');
  reset role;
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    perform public.approve_pricing_basis_release(v_rel3, true);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23P01',
    'PB-15 but a SECOND overlapping default is refused by the exclusion constraint (CDM-26)');

  -- a non-overlapping default is fine
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  v_rel4 := public.propose_pricing_basis_release(v_nag, date '2020-01-01', v_rsv, v_fsv, v_sv, v_cdv,
                                                 date '2020-12-31', '__p2 pb historic default');
  reset role;
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    perform public.approve_pricing_basis_release(v_rel4, true);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR',
    'PB-15a a default over a NON-overlapping period is allowed - retrospective Releases are legal');

  -- ------------------------------------------------- the transition matrix
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.pricing_basis_releases set release_name = '__p2 pb edited' where id = v_rel;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'PB-16 an APPROVED Release is immutable - approved -> approved is rejected (CDM-26)');

  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.pricing_basis_releases set status = 'draft' where id = v_rel2;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514', 'PB-17 approved -> draft is rejected');

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  v_rel3 := public.propose_pricing_basis_release(v_nag, date '2027-01-01', v_rsv, v_fsv, v_sv, v_cdv);
  begin
    update public.pricing_basis_releases set status = 'withdrawn' where id = v_rel3;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514', 'PB-18 draft -> withdrawn is rejected - a draft is abandoned, not withdrawn');

  -- the revision-2 defect: an approved Release MUST be withdrawable
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    perform public.withdraw_pricing_basis_release(v_rel);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR',
    'PB-19 an APPROVED Release CAN be withdrawn - the revision-2 defect stays fixed');
  return next is((select withdrawn_by from public.pricing_basis_releases where id=v_rel), v_approver,
                 'PB-19a with the withdrawer recorded from the session');
  return next ok((select not is_automatic_default from public.pricing_basis_releases where id=v_rel),
                 'PB-19b and it is no longer any plant automatic default');

  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.pricing_basis_releases set status = 'approved' where id = v_rel;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'PB-20 withdrawn is terminal - corrections create replacements, never revivals (CDM-26)');

  -- ------------------------------------- CDM-27 audited self-approval (N-P8)
  perform pg_catalog.set_config('request.jwt.claims', v_bclaims, true);
  set local role authenticated;
  v_rel3 := public.propose_pricing_basis_release(v_nag, date '2028-01-01', v_rsv, v_fsv, v_sv, v_cdv,
                                                 null, '__p2 pb self');
  begin
    perform public.approve_pricing_basis_release(v_rel3, false);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR',
    'PB-21 (N-P8) a caller holding BOTH capabilities may self-approve (CDM-27)');
  return next ok((select self_approved from public.pricing_basis_releases where id=v_rel3),
                 'PB-21a and it is RECORDED as self-approved, never silent');

  -- ------------------------------------------------------ plant isolation
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  select count(*) into v_seen from public.pricing_basis_releases where plant_id = v_pun;
  reset role;
  return next is(v_seen, 0, 'PB-22 wrong-plant Releases are invisible');
  set local role authenticated;
  select count(*) into v_seen from public.pricing_basis_releases where plant_id = v_nag;
  reset role;
  return next ok(v_seen > 0, 'PB-22a the caller own plant IS visible - PB-22 is isolation, not emptiness');

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    perform public.propose_pricing_basis_release(v_pun, date '2026-01-01', v_rsv_pun, v_fsv, v_sv, v_cdv);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'PB-23 and proposing at PUN is refused on the row own plant_id');

  -- anon reaches none of the three operations
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.proname in ('propose_pricing_basis_release','approve_pricing_basis_release',
                          'withdraw_pricing_basis_release')
        and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')),
    0, 'PB-24 anon can execute none of the Pricing Basis operations');
  return next is(
    (select count(*)::int from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app_private'
        and p.proname in ('propose_pricing_basis_release','approve_pricing_basis_release',
                          'withdraw_pricing_basis_release')
        and p.prosecdef),
    3, 'PB-24a and all three privileges live in app_private as SECURITY DEFINER');

  -- ------------------------------------------------------------- cleanup
  delete from public.pricing_basis_releases where plant_id in (v_nag, v_pun)
    and (release_name like '\_\_p2 pb%' or release_name is null);
  delete from public.freight_entries where plant_id in (v_nag, v_pun);
  delete from public.freight_set_versions where freight_set_id = v_fs;
  delete from public.freight_sets where id = v_fs;
  delete from public.rate_entries where rate_set_version_id in (v_rsv, v_rsv_draft, v_rsv_pun);
  delete from public.rate_set_versions where rate_set_id in (v_rs, v_rs_pun);
  delete from public.rate_sets where id in (v_rs, v_rs_pun);
  delete from public.payment_interest_map_entries where calculation_default_version_id = v_cdv;
  delete from public.calculation_default_versions where id = v_cdv;
  delete from public.sector_versions where sector_id = v_sec;
  delete from public.sectors where id = v_sec;
  delete from public.customer_locations where party_id = v_party;
  delete from public.parties where id = v_party;
  delete from public.plant_capability_grants where app_user_id in (v_proposer, v_approver, v_both);
  delete from public.group_capability_grants where app_user_id in (v_proposer, v_approver, v_both);
  delete from public.operational_settings     where created_by  in (v_proposer, v_approver, v_both);
  delete from app_private.pending_invitations where invite_email in (v_pemail, v_aemail, v_bemail);
  delete from public.app_users where id in (v_proposer, v_approver, v_both);
  perform tests.__drop_synthetic_auth(v_pauth);
  perform tests.__drop_synthetic_auth(v_aauth);
  perform tests.__drop_synthetic_auth(v_bauth);
end $fn$;

revoke all on function tests.pricing_basis() from public;
revoke all on function tests.pricing_basis() from anon;
revoke all on function tests.pricing_basis() from authenticated;