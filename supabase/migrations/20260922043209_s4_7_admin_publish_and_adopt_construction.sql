-- S4-7: admin_publish_and_adopt_construction — a single-step Admin shortcut.
--
-- WHY THIS EXISTS. Beta issue log 2026-09-19 item 2 + Product Owner ruling
-- 2026-09-22: a manage_construction_library holder who ALSO holds
-- adopt_construction_for_plant at a given plant may create, approve, publish
-- and adopt a Construction in ONE action, with no separate propose/approve
-- steps. The multi-role propose->approve->publish->adopt lifecycle from S4-3
-- is UNCHANGED and remains the path for a Maker's Batch-Entry proposal; this
-- is an additional entry point for the Admin case, not a replacement.
--
-- COMPOSES S4-3'S PRIMITIVES UNCHANGED. propose_construction,
-- approve_construction_version, publish_construction and
-- adopt_construction_for_plant are called exactly as any other caller would
-- call them, inside one transaction. Every capability check and every
-- state-transition guard those functions already enforce still runs; this
-- wrapper adds no new authority over the row-level tables and no new
-- data shape. A mid-sequence failure (e.g. the Construction is proposed but
-- adoption fails because the plant capability check fails) rolls back the
-- WHOLE transaction, so nothing is left half-done. That is why this is one
-- new function rather than four sequential client-side calls: PostgREST RPCs
-- are independently committed, and a client-side chain of that shape is
-- exactly what would leave an orphaned proposed-but-never-published row.
--
-- WHY BOTH CAPABILITIES ARE CHECKED UP FRONT. manage_construction_library
-- alone would let this function insert a published Construction that then
-- fails to adopt at a plant the caller has no adopt_construction_for_plant
-- grant for. Checking both before the first insert means an unauthorized
-- attempt writes nothing at all, matching CDM-31's append-only, no-orphan
-- posture used everywhere else in Family C.
create or replace function app_private.admin_publish_and_adopt_construction(
  p_plant          bigint,
  p_name           text,
  p_ply            integer,
  p_flute_f1       text    default null,
  p_flute_f2       text    default null,
  p_layer_top_code text    default null,
  p_layer_f1_code  text    default null,
  p_layer_l1_code  text    default null,
  p_layer_f2_code  text    default null,
  p_layer_l2_code  text    default null,
  p_layer_top_gsm  numeric default null,
  p_layer_f1_gsm   numeric default null,
  p_layer_l1_gsm   numeric default null,
  p_layer_f2_gsm   numeric default null,
  p_layer_l2_gsm   numeric default null,
  p_board_gsm      numeric default null)
returns table(construction_id bigint, construction_version_id bigint,
              construction_code text, adoption_id bigint)
language plpgsql security definer set search_path = '' as $fn$
declare
  v_me       bigint;
  v_k        bigint;
  v_version  bigint;
  v_code     text;
  v_adoption bigint;
begin
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_group_cap('manage_construction_library') then
    raise exception 'manage_construction_library required' using errcode = '42501';
  end if;
  if not app_private.has_plant_cap(p_plant, 'adopt_construction_for_plant') then
    raise exception 'adopt_construction_for_plant required at that plant' using errcode = '42501';
  end if;

  v_k := app_private.propose_construction(
    p_name, p_ply, p_flute_f1, p_flute_f2,
    p_layer_top_code, p_layer_f1_code, p_layer_l1_code, p_layer_f2_code, p_layer_l2_code,
    p_layer_top_gsm, p_layer_f1_gsm, p_layer_l1_gsm, p_layer_f2_gsm, p_layer_l2_gsm,
    p_board_gsm);

  select cv.id into v_version
    from public.construction_versions cv
   where cv.construction_id = v_k and cv.version_no = 1;
  if v_version is null then
    raise exception 'propose_construction did not create version 1' using errcode = '22023';
  end if;

  perform app_private.approve_construction_version(v_version);
  v_code     := app_private.publish_construction(v_k);
  v_adoption := app_private.adopt_construction_for_plant(p_plant, v_version);

  return query select v_k, v_version, v_code, v_adoption;
end $fn$;

-- Routing shim - SECURITY INVOKER, no privilege, no decisions. Same shape as
-- every other Family C shim in this file's ancestor migration.
create or replace function public.admin_publish_and_adopt_construction(
  p_plant bigint, p_name text, p_ply integer,
  p_flute_f1 text default null, p_flute_f2 text default null,
  p_layer_top_code text default null, p_layer_f1_code text default null,
  p_layer_l1_code text default null, p_layer_f2_code text default null,
  p_layer_l2_code text default null,
  p_layer_top_gsm numeric default null, p_layer_f1_gsm numeric default null,
  p_layer_l1_gsm numeric default null, p_layer_f2_gsm numeric default null,
  p_layer_l2_gsm numeric default null, p_board_gsm numeric default null)
returns table(construction_id bigint, construction_version_id bigint,
              construction_code text, adoption_id bigint)
language sql set search_path = '' as $fn$
  select * from app_private.admin_publish_and_adopt_construction(
    p_plant, p_name, p_ply, p_flute_f1, p_flute_f2,
    p_layer_top_code, p_layer_f1_code, p_layer_l1_code, p_layer_f2_code, p_layer_l2_code,
    p_layer_top_gsm, p_layer_f1_gsm, p_layer_l1_gsm, p_layer_f2_gsm, p_layer_l2_gsm,
    p_board_gsm);
$fn$;

do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (
             ('app_private','admin_publish_and_adopt_construction'),
             ('public','admin_publish_and_adopt_construction'))
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;

comment on function app_private.admin_publish_and_adopt_construction(bigint, text, integer, text, text, text, text, text, text, text, numeric, numeric, numeric, numeric, numeric, numeric) is
  'S4-7: single-step Admin shortcut composing S4-3''s propose/approve/publish/adopt in one transaction. Beta issue log 2026-09-19 item 2, Product Owner ruling 2026-09-22. Requires manage_construction_library AND adopt_construction_for_plant at p_plant, checked before any write.';
