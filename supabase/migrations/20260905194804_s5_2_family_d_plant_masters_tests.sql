-- S5-2: executable proof gates for the plant-owned commercial masters.

create or replace function tests.family_d_plant_masters()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['rate_sets','rate_set_versions','rate_entries',
                           'freight_sets','freight_set_versions','freight_entries'];
  t text; v_state text; v_seen int; v_owner bigint; v_nag bigint; v_pun bigint;
  v_pauth uuid; v_pclaims text; v_proposer bigint; v_pemail text := 'p2-s5rp@example.invalid';
  v_aauth uuid; v_aclaims text; v_approver bigint; v_aemail text := 'p2-s5ra@example.invalid';
  v_rs_nag bigint; v_rs_pun bigint; v_rsv bigint; v_rsv_pun bigint;
  v_fs bigint; v_fsv bigint; v_party bigint; v_loc bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';

  -- ---------------------------------------------------------- structural
  foreach t in array v_tables loop
    return next ok(
      (select c.relrowsecurity and c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = t),
      format('MR-1 %s has RLS enabled AND forced', t));
    return next ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('anon','public.'||t,'DELETE')),
      format('MR-2 anon holds no privilege of any kind on %s', t));
    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t and pol.polcmd='d'),
      0, format('MR-3 %s has no DELETE policy for any role', t));
    return next ok(
      not pg_catalog.has_table_privilege('authenticated','public.'||t,'DELETE'),
      format('MR-3a and authenticated holds no DELETE grant on %s', t));
  end loop;

  return next is(
    (select coalesce(max(cnt),0)::int from (
       select count(*) cnt from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname = any(v_tables)
        group by c.relname, pol.polcmd) q),
    1, 'MR-4 exactly one permissive policy per plant-master table and action');

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
    0, 'MR-5 every foreign key on a plant-master table is index-covered, composite ones included');

  -- CDM-17: the silent zero has no source
  return next is(
    (select column_default from information_schema.columns
      where table_schema='public' and table_name='freight_entries' and column_name='rate'),
    null, 'MR-6 freight_entries.rate has NO default - a missing pair is absent, never zero (CDM-17)');
  return next is(
    (select is_nullable from information_schema.columns
      where table_schema='public' and table_name='freight_entries' and column_name='rate'),
    'NO', 'MR-6a and cannot be null either - absence is the absence of a ROW');

  -- ---------------------------------------------------------- fixtures
  insert into public.rate_sets (plant_id, name, created_by) values (v_nag, '__p2 mr nag', v_owner)
    returning id into v_rs_nag;
  insert into public.rate_sets (plant_id, name, created_by) values (v_pun, '__p2 mr pun', v_owner)
    returning id into v_rs_pun;
  insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
  values (v_rs_nag, v_nag, 1, v_owner) returning id into v_rsv;
  insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
  values (v_rs_pun, v_pun, 1, v_owner) returning id into v_rsv_pun;
  insert into public.rate_entries (rate_set_version_id, plant_id, grade_code, price, created_by)
  values (v_rsv, v_nag, 'K', 42.0000, v_owner);
  insert into public.rate_entries (rate_set_version_id, plant_id, grade_code, price, created_by)
  values (v_rsv_pun, v_pun, 'K', 43.0000, v_owner);

  insert into public.parties (display_name, created_by) values ('__p2 mr party', v_owner)
    returning id into v_party;
  insert into public.customer_locations (party_id, bill_to_eligible, ship_to_eligible, created_by)
    values (v_party, true, true, v_owner) returning id into v_loc;
  insert into public.freight_sets (plant_id, name, created_by) values (v_nag, '__p2 mr fs', v_owner)
    returning id into v_fs;
  insert into public.freight_set_versions (freight_set_id, plant_id, version_no, created_by)
  values (v_fs, v_nag, 1, v_owner) returning id into v_fsv;
  insert into public.freight_entries (freight_set_version_id, plant_id, origin_plant_id, destination_location_id, rate, created_by)
  values (v_fsv, v_nag, v_nag, v_loc, 2.5000, v_owner);

  -- the composite FK refuses a version under the wrong plant
  begin
    insert into public.rate_set_versions (rate_set_id, plant_id, version_no, created_by)
    values (v_rs_nag, v_pun, 2, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'MR-7 a version cannot be written under a plant its set does not belong to');

  begin
    insert into public.rate_entries (rate_set_version_id, plant_id, grade_code, price, created_by)
    values (v_rsv, v_pun, 'S', 40.0000, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'MR-7a nor an entry under a plant its version does not belong to');

  -- ------------------------------------------------------------ personas
  v_pauth := tests.__fixture_auth_uid();
  v_pclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_pauth, v_pemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_pemail, '__p2_s5r_proposer', false);
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated; v_proposer := public.bootstrap_app_user(); reset role;

  v_aauth := tests.__fixture_auth_uid();
  v_aclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_aauth, v_aemail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_aemail, '__p2_s5r_approver', false);
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated; v_approver := public.bootstrap_app_user(); reset role;

  -- both granted at NAG only
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_proposer, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','propose_commercial_master');
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_approver, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','approve_commercial_master');

  -- ------------------------------------------------------ plant isolation
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  foreach t in array v_tables loop
    set local role authenticated;
    execute format('select count(*) from public.%I where plant_id = $1', t) into v_seen using v_pun;
    reset role;
    return next is(v_seen, 0, format('MR-8 wrong-plant %s rows are invisible', t));
  end loop;

  set local role authenticated;
  select count(*) into v_seen from public.rate_sets where plant_id = v_nag;
  reset role;
  return next ok(v_seen > 0,
    'MR-8a but the caller own plant IS visible - MR-8 is isolation, not emptiness');

  -- naming the wrong plant explicitly is still refused
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    insert into public.rate_sets (plant_id, name, created_by) values (v_pun, '__p2 mr sneak', v_proposer);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'MR-9 and proposing at PUN is refused - the predicate reads the row own plant_id');

  -- attribution cannot be spoofed
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    insert into public.rate_sets (plant_id, name, created_by) values (v_nag, '__p2 mr spoof', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'MR-9a nor attributing a proposal to another user (CDM-34)');

  -- ------------------------------------------------- the transition matrix
  perform pg_catalog.set_config('request.jwt.claims', v_pclaims, true);
  set local role authenticated;
  begin
    update public.rate_set_versions set status = 'approved' where id = v_rsv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'MR-10 the proposer cannot approve - second-person approval holds per plant');

  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.rate_set_versions set status = 'approved' where id = v_rsv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR', 'MR-11 the approver at that plant may approve');
  return next is((select approved_by from public.rate_set_versions where id = v_rsv), v_approver,
                 'MR-11a with attribution taken from the session');

  -- entries freeze with their version
  begin
    insert into public.rate_entries (rate_set_version_id, plant_id, grade_code, price, created_by)
    values (v_rsv, v_nag, 'S', 41.0000, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'MR-12 an approved rate version accepts no further entry - the editing unit is closed');

  -- plant_id is immutable across a transition
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.rate_set_versions set plant_id = v_pun where id = v_rsv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next ok(v_state <> 'NO ERROR',
    'MR-13 a version cannot be walked to another plant ('||v_state||')');

  -- approved -> withdrawn, then terminal
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.rate_set_versions set status = 'withdrawn' where id = v_rsv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR', 'MR-14 an APPROVED version can be withdrawn');

  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.rate_set_versions set status = 'draft' where id = v_rsv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '23514', 'MR-14a and withdrawn is terminal - nothing leaves it');

  -- the freight version follows the same matrix
  perform pg_catalog.set_config('request.jwt.claims', v_aclaims, true);
  set local role authenticated;
  begin
    update public.freight_set_versions set status = 'approved' where id = v_fsv;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, 'NO ERROR', 'MR-15 the freight version obeys the same matrix');

  begin
    insert into public.freight_entries (freight_set_version_id, plant_id, origin_plant_id, destination_location_id, rate, created_by)
    values (v_fsv, v_nag, v_pun, v_loc, 3.0000, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'MR-15a and an approved freight version gains no route afterwards');

  -- ------------------------------------------------------------- cleanup
  delete from public.freight_entries where plant_id in (v_nag, v_pun);
  delete from public.freight_set_versions where freight_set_id = v_fs;
  delete from public.freight_sets where id = v_fs;
  delete from public.rate_entries where rate_set_version_id in (v_rsv, v_rsv_pun);
  delete from public.rate_set_versions where rate_set_id in (v_rs_nag, v_rs_pun);
  delete from public.rate_sets where id in (v_rs_nag, v_rs_pun);
  delete from public.customer_locations where party_id = v_party;
  delete from public.parties where id = v_party;
  delete from public.plant_capability_grants where app_user_id in (v_proposer, v_approver);
  delete from public.group_capability_grants where app_user_id in (v_proposer, v_approver);
  delete from public.operational_settings     where created_by  in (v_proposer, v_approver);
  delete from app_private.pending_invitations where invite_email in (v_pemail, v_aemail);
  delete from public.app_users where id in (v_proposer, v_approver);
  perform tests.__drop_synthetic_auth(v_pauth);
  perform tests.__drop_synthetic_auth(v_aauth);
end $fn$;

revoke all on function tests.family_d_plant_masters() from public;
revoke all on function tests.family_d_plant_masters() from anon;
revoke all on function tests.family_d_plant_masters() from authenticated;