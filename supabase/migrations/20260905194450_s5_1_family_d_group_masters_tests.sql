-- S5-1: executable proof gates for the group-wide commercial masters.
--
-- Every transition gate runs inside a real persona session, because the matrix
-- is capability-gated: as the table owner there is no app user, so the trigger
-- would refuse for lack of capability and prove nothing about the matrix itself.
--
-- Denials assert the SQLSTATE and distinguish the two kinds deliberately:
-- 42501 means "you may not do this" (capability) and 23514 means "this is not a
-- legal move" (transition or constraint). Collapsing them would let a broken
-- capability check hide behind a constraint, or the reverse.

create or replace function tests.family_d_group_masters()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['sectors','sector_versions','calculation_default_versions',
                           'payment_interest_map_entries'];
  t text; v_state text; v_seen int; v_owner bigint; v_nag bigint;
  v_pauth uuid; v_pclaims text; v_proposer bigint; v_pemail text := 'p2-s5p@example.invalid';
  v_aauth uuid; v_aclaims text; v_approver bigint; v_aemail text := 'p2-s5a@example.invalid';
  v_nauth uuid; v_nclaims text; v_none bigint;     v_nemail text := 'p2-s5n@example.invalid';
  v_sector bigint; v_sv bigint; v_cdv bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';

  -- ---------------------------------------------------------- structural
  foreach t in array v_tables loop
    return next ok(
      (select c.relrowsecurity and c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = t),
      format('MD-1 %s has RLS enabled AND forced', t));
    return next ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('anon','public.'||t,'DELETE')),
      format('MD-2 anon holds no privilege of any kind on %s', t));
    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t and pol.polcmd='d'),
      0, format('MD-3 %s has no DELETE policy for any role', t));
    return next ok(
      not pg_catalog.has_table_privilege('authenticated','public.'||t,'DELETE'),
      format('MD-3a and authenticated holds no DELETE grant on %s', t));
  end loop;

  return next is(
    (select coalesce(max(cnt),0)::int from (
       select count(*) cnt from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname = any(v_tables)
        group by c.relname, pol.polcmd) q),
    1, 'MD-4 exactly one permissive policy per Family D group table and action');

  return next is(
    (select count(*)::int
       from pg_catalog.pg_constraint con
       join pg_catalog.pg_class c on c.oid = con.conrelid
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = any(v_tables) and con.contype = 'f'
        and not exists (
          select 1 from pg_catalog.pg_index i
           where i.indrelid = con.conrelid
             and (i.indkey::smallint[])[0:array_length(con.conkey,1)-1]
                 = (select array_agg(k) from unnest(con.conkey) k))),
    0, 'MD-5 every foreign key on a Family D group table is index-covered');

  -- ------------------------------------------- the Sector Margin ruling
  return next is(
    (select is_nullable from information_schema.columns
      where table_schema='public' and table_name='sector_versions' and column_name='margin_pct'),
    'NO', 'MD-6 sector_versions.margin_pct is NOT NULL - every Sector maintains a target margin');
  return next ok(
    (select is_nullable = 'YES' from information_schema.columns
      where table_schema='public' and table_name='sector_versions' and column_name='waste_cbb_pct'),
    'MD-6a but waste stays nullable - null there means inherit, not zero (CDM-19)');

  -- ---------------------------------------------------------- fixtures
  insert into public.sectors (sector_code, name, created_by)
  values ('__P2FA', '__p2 md sector', v_owner) returning id into v_sector;

  begin
    insert into public.sector_versions (sector_id, version_no, created_by)
    values (v_sector, 1, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23502',
    'MD-7 a Sector version without a target margin cannot be written at all');

  insert into public.sector_versions (sector_id, version_no, margin_pct, created_by)
  values (v_sector, 1, 8.000, v_owner) returning id into v_sv;

  insert into public.calculation_default_versions
    (version_no, engine_version, rounding_rule_version, created_by)
  values (1, 'engine-1', 'round-1', v_owner) returning id into v_cdv;

  -- the fallbacks reproduce today's reachable literals (A-21)
  return next is((select interest_fallback_pct from public.calculation_default_versions where id=v_cdv),
                 0.500, 'MD-8 the interest fallback is 0.500 - never the 1.500 top of the map (CDM-18)');
  return next is((select rounding_step from public.calculation_default_versions where id=v_cdv),
                 0.0500, 'MD-8a and the rounding step reproduces costing.js exactly (A-21)');

  -- ------------------------------------------- CDM-18 closed list, structural
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

  -- ------------------------------------------------------------ personas
  v_pauth := tests.__fixture_auth_uid();
  v_pclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_pauth, v_pemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_pemail, '__p2_s5_proposer', false);
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated; v_proposer := public.bootstrap_app_user(); reset role;

  v_aauth := tests.__fixture_auth_uid();
  v_aclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_aauth, v_aemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_aemail, '__p2_s5_approver', false);
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated; v_approver := public.bootstrap_app_user(); reset role;

  v_nauth := tests.__fixture_auth_uid();
  v_nclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_nauth, v_nemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_nemail, '__p2_s5_none', false);
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated; v_none := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_proposer, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','propose_commercial_master');
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_proposer, c.id, v_owner from public.capabilities c
   where c.capability_key = 'read_party_master';

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_approver, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','approve_commercial_master');
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_approver, c.id, v_owner from public.capabilities c
   where c.capability_key = 'read_party_master';

  -- an ungranted user reads nothing
  perform pg_catalog.set_config('request.jwt.claims', v_nclaims, true);
  set local role authenticated; select count(*) into v_seen from public.sectors; reset role;
  return next is(v_seen, 0, 'MD-11 a user with no read capability sees no Sector at all');

  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated; select count(*) into v_seen from public.sectors; reset role;
  return next ok(v_seen > 0, 'MD-11a a granted reader does see them - MD-11 is denial, not emptiness');

  -- ------------------------------------------------- the transition matrix
  -- draft -> draft, by the proposer
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    update public.sector_versions set margin_pct = 9.000 where id = v_sv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR', 'MD-12 the proposer may edit a DRAFT version');

  -- an edit may not smuggle approval in
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    update public.sector_versions set margin_pct = 9.500, approved_by = v_proposer, approved_at = now()
     where id = v_sv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514', 'MD-12a but may NOT set the approval fields by editing (CDM-34)');

  -- the proposer cannot approve
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    update public.sector_versions set status = 'approved' where id = v_sv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'MD-13 propose_commercial_master does NOT confer approval - second-person approval holds (CDM-31)');

  -- the approver can, and attribution is the system's word
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.sector_versions set status = 'approved', approved_by = v_owner where id = v_sv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR', 'MD-14 approve_commercial_master approves the draft');
  return next is((select approved_by from public.sector_versions where id = v_sv), v_approver,
                 'MD-14a and the approver is recorded from the session, overriding what the client sent');
  return next ok((select approved_at is not null from public.sector_versions where id = v_sv),
                 'MD-14b with its timestamp, which ck_sectorv_approval_pair makes inseparable');

  -- approved is immutable
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.sector_versions set margin_pct = 12.000 where id = v_sv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514',
    'MD-15 an APPROVED version is immutable - a correction is a new version (CDM-31/PM-3)');

  -- approved -> superseded is the one legal exit; draft -> superseded is not
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.sector_versions set status = 'superseded' where id = v_sv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR', 'MD-16 approved -> superseded is legal for the approver');

  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.sector_versions set status = 'draft' where id = v_sv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514', 'MD-17 superseded is terminal - nothing leaves it');

  -- the map follows its version: no edit once approved
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.calculation_default_versions set status = 'approved' where id = v_cdv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR', 'MD-18 the calculation defaults version approves');

  begin
    insert into public.payment_interest_map_entries (calculation_default_version_id, credit_days, interest_pct, created_by)
    values (v_cdv, 60, 2.000, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'MD-19 and its Payment Terms map is frozen with it - the approved map cannot gain an entry');

  -- ------------------------------------------------------------- cleanup
  delete from public.payment_interest_map_entries where calculation_default_version_id = v_cdv;
  delete from public.calculation_default_versions where id = v_cdv;
  delete from public.sector_versions where sector_id = v_sector;
  delete from public.sectors where id = v_sector;
  delete from public.plant_capability_grants where app_user_id in (v_proposer, v_approver, v_none);
  delete from public.group_capability_grants where app_user_id in (v_proposer, v_approver, v_none);
  delete from public.operational_settings     where created_by  in (v_proposer, v_approver, v_none);
  delete from app_private.pending_invitations where invite_email in (v_pemail, v_aemail, v_nemail);
  delete from public.app_users where id in (v_proposer, v_approver, v_none);
  perform tests.__drop_synthetic_auth(v_pauth);
  perform tests.__drop_synthetic_auth(v_aauth);
  perform tests.__drop_synthetic_auth(v_nauth);
end $fn$;

revoke all on function tests.family_d_group_masters() from public;
revoke all on function tests.family_d_group_masters() from anon;
revoke all on function tests.family_d_group_masters() from authenticated;