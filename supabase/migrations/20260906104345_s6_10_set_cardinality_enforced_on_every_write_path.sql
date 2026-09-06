-- S6-10 (S6-C1): SET cardinality enforced through EVERY write path.
--
-- THE DEFECT, stated plainly. §5.9 claims "no write path can produce an active
-- empty SET" and BS-1 was captioned with that sentence. What BS-1 actually
-- exercised was an INSERT that named `status` and left `active_component_count`
-- to its default of 0, so ck_set_active_has_component rejected it. That proves
-- the DEFAULTS cannot produce an active empty SET. It does not prove that no
-- write path can.
--
-- There was one, and it was reachable by an ordinary caller. `authenticated`
-- held table-level INSERT on batch_sets, which carries column INSERT on every
-- column including `status` and `active_component_count`, and the recompute
-- trigger was BEFORE UPDATE only. So:
--
--     insert into batch_sets (batch_id, box_row_id, set_code, status,
--                             active_component_count, created_by)
--     values (..., 'active', 1, me);
--
-- satisfied `status <> 'active' or active_component_count >= 1` with 1 >= 1 and
-- created an ACTIVE SET with no memberships. Nothing corrected it until some
-- later UPDATE happened to fire the recompute. S7's resolver and S9's Send both
-- read that status.
--
-- TWO INDEPENDENT LAYERS CLOSE IT, in the order that gives the caller the
-- clearest answer.
--
-- Layer 1 - the caller cannot name the columns at all. Table-level INSERT and
-- UPDATE are revoked and replaced by column-level grants, which is the accepted
-- technique T-21 already uses on app_users.display_name. A caller naming
-- `status` or `active_component_count` is refused with 42501 before any row is
-- constructed. What remains grantable is what a caller legitimately decides:
-- which Batch, which Box, and what to call the SET - and relabelling stays
-- possible while dissolved (A-15), because `set_code` keeps its UPDATE grant.
--
-- Layer 2 - the database derives both values from reality, on INSERT as well as
-- UPDATE. `status` stops being a storable opinion and becomes a function of the
-- counter, exactly as sync_set_component_count already treats it: one or more
-- active components means 'active', none means 'dissolved'. That closes the
-- symmetric hole in the same place - a privileged path could previously mark a
-- POPULATED SET dissolved, which CDM-20 does not permit either, since
-- dissolution is caused by losing the last component and by nothing else.
--
-- SILENT CORRECTION IS THE RIGHT SEMANTIC HERE, and it is the one already
-- settled. BS-6 established that a client-supplied counter is discarded and
-- recomputed rather than raising. Layer 2 extends that same rule to `status` and
-- to INSERT; Layer 1 is what turns it into an explicit refusal for the callers
-- who reach the table through the API. Both are asserted below.
--
-- sync_set_component_count BECOMES SECURITY DEFINER, and it needed to be. It ran
-- as the invoker and wrote to a FORCE-RLS table, so an RLS-filtered UPDATE would
-- have left the counter stale WITHOUT raising - a fail-open on the one value the
-- cardinality check trusts. It also could not survive Layer 1, since the
-- invoking caller no longer holds UPDATE on the columns it maintains. As a
-- definer it always writes, and the counter is the database's word in fact and
-- not only in intent.

-- ------------------------------------------------ Layer 2: derive, always
create or replace function app_private.derive_set_state()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
  -- new.id is already assigned on INSERT: an identity default is evaluated
  -- before BEFORE ROW triggers fire. On INSERT no membership can reference it
  -- yet, because fk_bsm_set could not have been satisfied, so this is 0 - which
  -- is the point.
  select count(*)::int into v_n
    from public.batch_set_memberships
   where set_id = new.id and status = 'active';

  new.active_component_count := v_n;
  new.status := case when v_n >= 1 then 'active' else 'dissolved' end;
  return new;
end $fn$;

drop trigger if exists trg_set_recompute_count on public.batch_sets;
create trigger trg_set_derive_state
  before insert or update on public.batch_sets
  for each row execute function app_private.derive_set_state();

-- the superseded invoker-side recompute; the derive trigger replaces it
drop function if exists app_private.recompute_set_count();

-- ------------------------------ the counter writer must always be able to write
create or replace function app_private.sync_set_component_count()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare v_set bigint; v_n int;
begin
  v_set := coalesce(new.set_id, old.set_id);
  select count(*)::int into v_n
    from public.batch_set_memberships
   where set_id = v_set and status = 'active';

  update public.batch_sets
     set active_component_count = v_n,
         status = case when v_n >= 1 then 'active' else 'dissolved' end
   where id = v_set;

  return coalesce(new, old);
end $fn$;

revoke all on function app_private.derive_set_state() from public, anon, authenticated;
revoke all on function app_private.sync_set_component_count() from public, anon, authenticated;

-- ------------------------------------------- Layer 1: column-level grants
-- A caller decides which Batch, which Box and what the SET is called. It does
-- not decide whether the SET is active or how many components it has.
revoke insert, update on public.batch_sets from authenticated;
grant insert (batch_id, box_row_id, set_code, created_by) on public.batch_sets to authenticated;
grant update (set_code) on public.batch_sets to authenticated;

-- ------------------------------------------------------------------ gates
-- BS-1 is restated where it lives, because its caption was the thing that was
-- wrong. The privileged path is now enforced-correction rather than rejection,
-- and the authenticated path - the one that was actually vulnerable - is proved
-- separately, as `authenticated`, in tests.batch_set_cardinality().
do $rw$
declare
  v_def text; v_out text; v_oid oid;
  v_old text := $q$  begin
    insert into public.batch_sets (batch_id, box_row_id, set_code, status, created_by)
    values (v_batch, v_box, 'S1', 'active', v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23514',
    'BS-1 (§5.9) an ACTIVE SET with no components is impossible - no write path can create one');$q$;
  v_new text := $q$  -- Even on the privileged path, where column grants do not apply, `status` is
  -- not a storable opinion: the derive trigger recomputes it from the
  -- memberships that exist. A SET asserted ACTIVE with none is stored dissolved.
  insert into public.batch_sets (batch_id, box_row_id, set_code, status, active_component_count, created_by)
  values (v_batch, v_box, 'S0', 'active', 1, v_owner);
  return next is((select status from public.batch_sets where batch_id=v_batch and set_code='S0'), 'dissolved',
    'BS-1 (§5.9) an ACTIVE SET with no components cannot be stored - the database derives status from reality');
  return next is((select active_component_count from public.batch_sets where batch_id=v_batch and set_code='S0'), 0,
    'BS-1a and the caller-supplied count of 1 is discarded, not trusted');
  delete from public.batch_sets where batch_id = v_batch and set_code = 'S0';$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='batch_sets';
  if v_oid is null then raise exception 'tests.batch_sets() not found' using errcode='55000'; end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def) = 0 then
    raise exception 'the BS-1 block was not found verbatim' using errcode='55000';
  end if;
  v_out := replace(v_def, v_old, v_new);
  execute v_out;

  v_def := pg_get_functiondef(v_oid);
  if position('BS-1a and the caller-supplied count' in v_def) = 0 then
    raise exception 'the BS-1 replacement did not take' using errcode='55000';
  end if;
end $rw$;

-- --------------------------------------------- the authenticated persona
-- The vulnerable insert was reachable by an ordinary caller, so the gate that
-- forecloses it has to BE an ordinary caller. This suite runs every attempt as
-- `authenticated`, holding a real Batch, a real lock and make_quote at the
-- plant - so nothing here is denied for a reason other than the one named.
create or replace function tests.batch_set_cardinality()
returns setof text language plpgsql set search_path = extensions, pg_catalog as $fn$
declare
  v_owner bigint; v_nag bigint; v_state text; v_set bigint;
  v_mauth uuid; v_mclaims text; v_maker bigint; v_memail text := 'p2-s6card@example.invalid';
  v_fam bigint; v_party bigint; v_kpub bigint; v_cvpub bigint;
  v_sku bigint; v_skuv bigint; v_batch bigint; v_pg bigint; v_box bigint;
begin
  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';

  -- the boundary, stated structurally before any behaviour is exercised
  return next ok(
    not pg_catalog.has_column_privilege('authenticated','public.batch_sets','status','INSERT'),
    'BS-12 authenticated cannot INSERT the status column at all (column-level grant)');
  return next ok(
    not pg_catalog.has_column_privilege('authenticated','public.batch_sets','active_component_count','INSERT'),
    'BS-12a nor the component counter');
  return next ok(
    not pg_catalog.has_column_privilege('authenticated','public.batch_sets','status','UPDATE'),
    'BS-12b nor UPDATE either of them');
  return next ok(
    pg_catalog.has_column_privilege('authenticated','public.batch_sets','set_code','UPDATE'),
    'BS-12c while relabelling a dissolved SET stays possible (A-15)');

  -- ------------------------------------------------------------ fixtures
  v_mauth := tests.__fixture_auth_uid();
  v_mclaims := format('{"sub":"%s","role":"authenticated","email":"%s"}', v_mauth, v_memail);
  insert into app_private.pending_invitations (invite_email, display_name, grant_admin)
  values (v_memail, '__p2_s6_card', false);
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated; v_maker := public.bootstrap_app_user(); reset role;

  insert into public.plant_capability_grants (app_user_id, plant_id, capability_id, granted_by)
  select v_maker, v_nag, c.id, v_owner from public.capabilities c
   where c.capability_key in ('plant_access','make_quote');

  insert into public.customer_families (name, status, created_by)
    values ('__p2 card family','active',v_owner) returning id into v_fam;
  insert into public.parties (display_name, created_by) values ('__p2 card party', v_owner)
    returning id into v_party;
  insert into public.party_family_memberships (party_id, family_id, effective_from, created_by)
    values (v_party, v_fam, current_date, v_owner);
  insert into public.constructions (name, created_by) values ('__p2 card con', v_owner)
    returning id into v_kpub;
  insert into public.construction_versions (construction_id, version_no, ply, created_by)
    values (v_kpub, 1, 3, v_owner) returning id into v_cvpub;
  update public.constructions set construction_code='CON-994001', status='published' where id=v_kpub;
  insert into public.skus (plant_id, party_id, created_by) values (v_nag, v_party, v_owner)
    returning id into v_sku;
  insert into public.sku_versions (sku_id, plant_id, version_no, construction_version_id, is_price_driving, created_by)
    values (v_sku, v_nag, 1, v_cvpub, true, v_owner) returning id into v_skuv;

  -- a real Batch, created through the RPC, so the caller owns it and holds the lock
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  v_batch := public.create_batch(v_fam, v_nag, null);
  reset role;
  select id into v_pg from public.pricing_groups where batch_id = v_batch;

  -- This insert is also the functional proof of S6-9: the Maker holds neither
  -- read_party_master nor read_construction_library, and before the guards
  -- became SECURITY DEFINER it was refused outright.
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  insert into public.batch_rows (batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, row_type, created_by)
  values (v_batch, v_nag, v_pg, v_sku, v_skuv, 'box', v_maker) returning id into v_box;
  reset role;
  return next ok(v_box is not null,
    'BS-13 an ordinary Maker can add a Batch row - so nothing below is denied for the wrong reason (S6-9)');

  -- ============================ the presently vulnerable insert, as the caller
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    insert into public.batch_sets (batch_id, box_row_id, set_code, status, active_component_count, created_by)
    values (v_batch, v_box, 'CARD1', 'active', 1, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501',
    'BS-14 an authenticated caller supplying status=active AND count=1 is REFUSED - the exact insert that was reachable before');
  return next is((select count(*)::int from public.batch_sets where batch_id=v_batch and set_code='CARD1'), 0,
    'BS-14a and no row was created');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    insert into public.batch_sets (batch_id, box_row_id, set_code, active_component_count, created_by)
    values (v_batch, v_box, 'CARD2', 5, v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'BS-15 nor may it supply a counter alone');

  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    insert into public.batch_sets (batch_id, box_row_id, set_code, status, created_by)
    values (v_batch, v_box, 'CARD3', 'active', v_maker);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'BS-15a nor a status alone');

  -- the well-formed insert still works, and is born dissolved
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  insert into public.batch_sets (batch_id, box_row_id, set_code, created_by)
  values (v_batch, v_box, 'CARD4', v_maker) returning id into v_set;
  reset role;
  return next is((select status from public.batch_sets where id=v_set), 'dissolved',
    'BS-16 while the well-formed insert succeeds and the SET is born dissolved (CDM-20)');
  return next is((select active_component_count from public.batch_sets where id=v_set), 0,
    'BS-16a with a counter the database set, not the caller');

  -- and it cannot be talked into being active by an update either
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  begin
    update public.batch_sets set status='active', active_component_count=1 where id = v_set;
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  reset role;
  return next is(v_state, '42501', 'BS-17 nor promoted by UPDATE - the same columns are ungrantable there too');
  return next is((select status from public.batch_sets where id=v_set), 'dissolved',
    'BS-17a and the SET is still dissolved');

  -- relabelling, which A-15 requires, is unaffected
  perform pg_catalog.set_config('request.jwt.claims', v_mclaims, true);
  set local role authenticated;
  update public.batch_sets set set_code = 'CARD4B' where id = v_set;
  reset role;
  return next is((select set_code from public.batch_sets where id=v_set), 'CARD4B',
    'BS-18 a dissolved SET is still relabellable by its caller (A-15)');

  -- the whole-database invariant, which is what all of this is for
  return next is(
    (select count(*)::int from public.batch_sets s
      where s.status = 'active'
        and not exists (select 1 from public.batch_set_memberships m
                         where m.set_id = s.id and m.status = 'active')),
    0, 'BS-19 no ACTIVE SET anywhere in the database is without an active component (§5.9/CDM-20)');

  -- ------------------------------------------------------------- cleanup
  delete from public.batch_set_memberships where batch_id = v_batch;
  delete from public.batch_sets where batch_id = v_batch;
  delete from public.batch_calculations where batch_id = v_batch;
  delete from public.batch_rows where batch_id = v_batch;
  update public.pricing_groups set freight_basis_delivery_group_id = null where batch_id = v_batch;
  delete from public.delivery_groups where batch_id = v_batch;
  delete from public.pricing_groups where batch_id = v_batch;
  delete from public.batch_profile_versions where batch_id = v_batch;
  delete from public.batch_edit_locks where batch_id = v_batch;
  delete from public.batches where id = v_batch;
  delete from public.sku_versions where sku_id = v_sku;
  delete from public.skus where id = v_sku;
  delete from public.construction_versions where construction_id = v_kpub;
  delete from public.constructions where id = v_kpub;
  delete from public.party_family_memberships where party_id = v_party;
  delete from public.parties where id = v_party;
  delete from public.customer_families where id = v_fam;
  delete from public.plant_capability_grants where app_user_id = v_maker;
  delete from public.group_capability_grants where app_user_id = v_maker;
  delete from public.operational_settings     where created_by  = v_maker;
  delete from app_private.pending_invitations where invite_email = v_memail;
  delete from public.app_users where id = v_maker;
  perform tests.__drop_synthetic_auth(v_mauth);
  perform pg_catalog.set_config('request.jwt.claims', null, true);
end $fn$;

revoke all on function tests.batch_set_cardinality() from public, anon, authenticated;
