-- S4-4: give the Construction Library gates an unambiguous prefix.
--
-- tests.access_model() has used `PC-1` since S1 for "exactly one permissive
-- policy per Family A table and action". S4-1 introduced a second, unrelated
-- `PC-1`. Both pass, so nothing was broken - but two different gates answering
-- to one id defeats the point of a gate register, and a future reader tracing a
-- failure would have to read the message to know which rule had failed.
--
-- The accepted Phase 2 assertion keeps its id. The newcomer moves: PC- becomes
-- CL- (Construction Library), which no suite uses. Only the labels change - not
-- one predicate, threshold or fixture is touched.

create or replace function tests.construction_library()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_tables text[] := array['constructions','construction_versions','plant_construction_adoptions'];
  t text; v_ok boolean;
  v_auth uuid; v_claims text; v_uid bigint; v_owner bigint;
  v_email text := 'p2-s4c@example.invalid';
  v_nag bigint; v_pun bigint; v_k bigint; v_v bigint; v_seen int;
begin
  -- ---------------------------------------------------------- structural gates
  foreach t in array v_tables loop
    return next ok(
      (select c.relrowsecurity and c.relforcerowsecurity
         from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = t),
      format('CL-1 %s has RLS enabled AND forced', t));
    return next ok(
      not (pg_catalog.has_table_privilege('anon','public.'||t,'SELECT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'INSERT')
        or pg_catalog.has_table_privilege('anon','public.'||t,'UPDATE')
        or pg_catalog.has_table_privilege('anon','public.'||t,'DELETE')),
      format('CL-2 anon holds no privilege of any kind on %s', t));
    return next is(
      (select count(*)::int from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname=t and pol.polcmd='d'),
      0, format('CL-3 %s has no DELETE policy for any role', t));
    return next ok(
      not pg_catalog.has_table_privilege('authenticated','public.'||t,'DELETE'),
      format('CL-3a and authenticated holds no DELETE grant on %s', t));
  end loop;

  return next is(
    (select coalesce(max(cnt),0)::int from (
       select count(*) cnt from pg_catalog.pg_policy pol
         join pg_catalog.pg_class c on c.oid = pol.polrelid
         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname = any(v_tables)
        group by c.relname, pol.polcmd) q),
    1, 'CL-4 exactly one permissive policy per Construction table and action');

  -- every single-column foreign key carries a leading-column index (advisor 0001)
  return next is(
    (select count(*)::int
       from pg_catalog.pg_constraint con
       join pg_catalog.pg_class c on c.oid = con.conrelid
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = any(v_tables)
        and con.contype = 'f' and array_length(con.conkey,1) = 1
        and not exists (
          select 1 from pg_catalog.pg_index i
           where i.indrelid = con.conrelid
             and (i.indkey::smallint[])[0] = con.conkey[1])),
    0, 'CL-24 every single-column foreign key in the Construction Library is indexed');

  -- ------------------------------------------------------- CDM-13, structurally
  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='construction_versions'
        and (column_name ~* 'wast' or column_name ~* 'conv')),
    0, 'CL-11 NO waste or conversion column of any spelling exists on construction_versions');

  return next is(
    (select count(*)::int from information_schema.columns
      where table_schema='public' and table_name='constructions'
        and (column_name ~* 'wast' or column_name ~* 'conv')),
    0, 'CL-11a and none on constructions either - the hidden tier has no destination');

  -- ------------------------------------------------------------- constraints
  select id into v_owner from public.app_users order by id limit 1;

  begin
    insert into public.constructions (name, status, created_by)
    values ('__p2 pc probe','published',v_owner);
    return next fail('CL-5 a published Construction without a code should be rejected');
  exception when others then
    return next ok(true, 'CL-5 published Construction without a permanent code rejected ('||sqlstate||')');
  end;

  begin
    insert into public.constructions (name, status, created_by)
    values ('__p2 pc probe','merged',v_owner);
    return next fail('CL-6 a merged Construction without a survivor should be rejected');
  exception when others then
    return next ok(true, 'CL-6 merged Construction without retained lineage rejected ('||sqlstate||')');
  end;

  begin
    insert into public.constructions (name, construction_code, status, created_by)
    values ('__p2 pc probe','CON-12','published',v_owner);
    return next fail('CL-7 a malformed Construction Code should be rejected');
  exception when others then
    return next ok(true, 'CL-7 malformed Construction Code rejected ('||sqlstate||')');
  end;

  -- CDM-12/DM-143: names may repeat. This must SUCCEED.
  insert into public.constructions (name, created_by) values ('__p2 pc dup', v_owner);
  insert into public.constructions (name, created_by) values ('__p2 pc dup', v_owner) returning id into v_k;
  return next is((select count(*)::int from public.constructions where name = '__p2 pc dup'), 2,
                 'CL-8 Construction names are deliberately NOT unique (CDM-12/DM-143)');

  -- ------------------------------------------------- immutability, every role
  insert into public.construction_versions (construction_id, version_no, ply, board_gsm, created_by)
  values (v_k, 1, 3, 420.00, v_owner) returning id into v_v;

  update public.construction_versions set board_gsm = 430.00 where id = v_v;
  return next is((select board_gsm from public.construction_versions where id = v_v), 430.00,
                 'CL-12 an UNapproved version is editable');

  update public.construction_versions set approved_by = v_owner, approved_at = now() where id = v_v;

  begin
    update public.construction_versions set board_gsm = 440.00 where id = v_v;
    return next fail('CL-13 an approved Construction Version must not be editable');
  exception when others then
    return next ok(true, 'CL-13 approved Construction Version is immutable ('||sqlstate||')');
  end;

  -- The point of the trigger: everything above ran as the table owner, not as
  -- `authenticated`, so CL-13 proves immutability holds exactly where the RLS
  -- policy does not reach.
  return next ok(
    (select tgenabled = 'O' from pg_catalog.pg_trigger
      where tgrelid = 'public.construction_versions'::regclass and tgname = 'trg_cv_immutable'),
    'CL-14 immutability is a trigger, so it binds BYPASSRLS roles too, not only authenticated');

  begin
    update public.construction_versions set version_no = 2 where id = v_v;
    return next fail('CL-15 version_no must be immutable');
  exception when others then
    return next ok(true, 'CL-15 a version cannot be renumbered ('||sqlstate||')');
  end;

  return next is((select count(*)::int from pg_catalog.pg_constraint
                   where conrelid = 'public.construction_versions'::regclass
                     and conname = 'ck_cv_approval_pair'), 1,
                 'CL-16 approval and its attribution cannot be separated (CDM-34)');

  -- ------------------------------------------------------ CDM-03 permanence
  update public.constructions set construction_code = 'CON-999001', status = 'published' where id = v_k;
  begin
    update public.constructions set construction_code = 'CON-999002' where id = v_k;
    return next fail('CL-9 a permanent Construction Code must never change');
  exception when others then
    return next ok(true, 'CL-9 an allocated Construction Code is permanent ('||sqlstate||')');
  end;
  begin
    update public.constructions set construction_code = null where id = v_k;
    return next fail('CL-9a a permanent code must never be released back to null');
  exception when others then
    return next ok(true, 'CL-9a a code is never released back to the pool ('||sqlstate||')');
  end;
  begin
    update public.constructions set status = 'proposed' where id = v_k;
    return next fail('CL-10 published -> proposed must be rejected');
  exception when others then
    return next ok(true, 'CL-10 the Construction lifecycle is exhaustive and published is terminal ('||sqlstate||')');
  end;

  -- ------------------------------------------------------------- personas
  v_auth   := tests.__fixture_auth_uid();
  v_claims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_auth, v_email);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_email, '__p2_s4c_maker', false);
  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  v_uid := public.bootstrap_app_user();
  reset role;

  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';

  -- a Maker granted at NAG only, and holding no group capability at all
  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_uid, v_nag, c.id, v_uid from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);

  set local role authenticated;
  select count(*) into v_seen from public.constructions;
  reset role;
  return next is(v_seen, 0,
    'CL-17 a Maker WITHOUT read_construction_library sees no Constructions at all');

  set local role authenticated;
  begin
    insert into public.constructions (name, status, created_by) values ('__p2 pc maker', 'proposed', v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(v_ok, 'CL-18 but a make_quote holder MAY propose a Construction (CDM-12/DM-144)');

  set local role authenticated;
  begin
    insert into public.constructions (name, construction_code, status, created_by)
    values ('__p2 pc maker pub', 'CON-999003', 'published', v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'CL-19 and may NOT insert a published Construction - the branch is narrow');

  set local role authenticated;
  begin
    update public.constructions set name = '__p2 pc hijack' where id = v_k;
    v_ok := exists (select 1 from public.constructions where name = '__p2 pc hijack');
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok, 'CL-20 a Maker may not edit the shared Construction Library');

  -- adoption is plant-owned, refused on the row's own plant_id
  set local role authenticated;
  begin
    insert into public.plant_construction_adoptions (plant_id, construction_version_id, adopted_by)
    values (v_nag, v_v, v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok,
    'CL-21 a Maker without adopt_construction_for_plant cannot adopt, even at their own plant');

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_uid, v_nag, c.id, v_uid from public.capabilities c
   where c.capability_key = 'adopt_construction_for_plant';

  perform pg_catalog.set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  begin
    insert into public.plant_construction_adoptions (plant_id, construction_version_id, adopted_by)
    values (v_nag, v_v, v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(v_ok, 'CL-22 the explicit plant grant is what admits the adoption');

  set local role authenticated;
  begin
    insert into public.plant_construction_adoptions (plant_id, construction_version_id, adopted_by)
    values (v_pun, v_v, v_uid);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  reset role;
  return next ok(not v_ok,
    'CL-23 and confers nothing at PUN - cross-plant isolation holds on the row own plant_id');

  -- ------------------------------------------------------------- cleanup
  -- Order matters: pending_invitations.consumed_by points AT the app_user, so
  -- the invitation is removed first (the order P2-9 established).
  delete from public.plant_construction_adoptions
   where construction_version_id in (
     select cv.id from public.construction_versions cv
      join public.constructions k on k.id = cv.construction_id
     where k.name like '\_\_p2 pc%');
  delete from public.construction_versions
   where construction_id in (select id from public.constructions where name like '\_\_p2 pc%');
  delete from public.constructions where name like '\_\_p2 pc%';
  delete from public.plant_capability_grants where app_user_id = v_uid;
  delete from public.group_capability_grants where app_user_id = v_uid;
  delete from public.operational_settings where created_by = v_uid;
  delete from app_private.pending_invitations where invite_email = v_email;
  delete from public.app_users where id = v_uid;
  perform tests.__drop_synthetic_auth(v_auth);
end $fn$;