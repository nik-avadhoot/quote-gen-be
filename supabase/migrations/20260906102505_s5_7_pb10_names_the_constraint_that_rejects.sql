-- S5-7: PB-10 names the rule that rejects it.
--
-- ADVISORY, and it closes the last step of the argument PB-10 already makes.
-- S5-3's second fix repaired PB-10 by approving the PUN rate version first, so
-- that guard_release_components_approved could no longer reject the write before
-- the composite foreign key was reached. That was the substantive repair, and it
-- stands.
--
-- What remained is smaller and worth finishing. A `23503` says only "some
-- foreign key rejected this". pricing_basis_releases carries eight of them, two
-- of which - fk_pbr_rate and fk_pbr_freight - are composite against plant_id.
-- Only the rate component is cross-plant in this fixture, so the gate was sound;
-- but it was sound by reasoning about the fixture rather than by measurement, and
-- this slice's own lesson is that a denial is worthless as evidence unless you
-- know which rule produced it. GET STACKED DIAGNOSTICS supplies the constraint
-- name, so PB-10a asserts it directly.
--
-- The failure mode this forecloses is a later schema change - a new FK, a
-- renamed one, a plant column dropped from the composite - that leaves PB-10
-- green while the invariant it claims to prove is gone.

do $rw$
declare
  v_def text; v_out text; v_oid oid;
  v_old1 text := $q$  v_rel bigint; v_rel2 bigint; v_rel3 bigint; v_rel4 bigint;$q$;
  v_new1 text := $q$  v_rel bigint; v_rel2 bigint; v_rel3 bigint; v_rel4 bigint;
  v_constraint text;$q$;

  v_old2 text := $q$    values (v_nag, date '2026-01-01', v_rsv_pun, v_fsv, v_sv, v_cdv, v_owner);
    v_state := 'NO ERROR';
  exception when others then v_state := sqlstate;
  end;
  return next is(v_state, '23503',
    'PB-10 a Release cannot cite another plant component - the composite FK binds plant_id');$q$;
  v_new2 text := $q$    values (v_nag, date '2026-01-01', v_rsv_pun, v_fsv, v_sv, v_cdv, v_owner);
    v_state := 'NO ERROR'; v_constraint := 'NONE';
  exception when others then
    v_state := sqlstate;
    get stacked diagnostics v_constraint = constraint_name;
  end;
  return next is(v_state, '23503',
    'PB-10 a Release cannot cite another plant component - the composite FK binds plant_id');
  return next is(v_constraint, 'fk_pbr_rate',
    'PB-10a and fk_pbr_rate is the constraint that rejected it - named, not inferred from the class');$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'tests' and p.proname = 'pricing_basis';
  if v_oid is null then
    raise exception 'tests.pricing_basis() not found' using errcode = '55000';
  end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old1 in v_def) = 0 then
    raise exception 'the declare block was not found verbatim' using errcode = '55000';
  end if;
  if position(v_old2 in v_def) = 0 then
    raise exception 'the PB-10 block was not found verbatim' using errcode = '55000';
  end if;

  v_out := replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
  execute v_out;

  v_def := pg_get_functiondef(v_oid);
  if position('PB-10a' in v_def) = 0 or position('get stacked diagnostics' in v_def) = 0 then
    raise exception 'the PB-10a replacement did not take' using errcode = '55000';
  end if;
end $rw$;
