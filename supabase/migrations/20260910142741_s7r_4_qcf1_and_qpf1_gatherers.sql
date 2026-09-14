-- S7-R/4: the two gatherers - qcf/1 (calculation) and qpf/1 (presentation).
--
-- STABLE, SECURITY DEFINER, search_path = ''. They answer "what is this row's
-- fingerprint", a property of the database rather than of the caller's
-- visibility. S9-P S5 stated this requirement so S7-R would inherit it rather
-- than rediscover it; CP-54 pins it.
--
-- EVERY READ IS AN OUTER READ. A row whose Pricing Group, current Batch Profile
-- version, Release or SET is absent must yield \N for those keys, never vanish
-- from the result. An inner join is a filter, and a fingerprint that silently
-- omitted a field would compare equal to one that never had it. That is why
-- every lookup below is a scalar sub-select into a variable rather than a join
-- in one statement.
--
-- EVERY KEY IS EMITTED, NULL OR NOT. Omitting null keys would let two different
-- states hash identically - a row with no margin override, and a row whose key
-- a bug dropped.
--
-- ─── qcf/1, fifty keys ────────────────────────────────────────────────────
-- S10.4's list, plus the two approved extensions. D-S adds the five governed-
-- master freight fields, because S10.4's four are not sufficient to determine
-- the resolved master rate: changing the basis Delivery Group's Ship-to moves
-- the resolved Entry with freight_basis_delivery_group_id unchanged, and there
-- is no trigger of any kind on delivery_groups. D-F adds the three spec fields,
-- so an issued Quote can evidence the compliance claim it made.
--
-- THREE FIELDS CARRY BOTH INPUT AND OUTPUT, DELIBERATELY. row.fluting_bcf
-- records the authority the Maker exercised; eff.fluting_bcf the number used;
-- eff.fluting_bcf_source which tier won. A new approved Calculation Defaults
-- version moves the second while the first does not move at all. S10.4 requires
-- the hash be fed the resolver's OUTPUT provenance, not merely its raw input.
--
-- set.members IS SAFE AS A JOINED LINE because both components are constrained
-- - role is the closed list plate|partition|other and row_id is digits - so no
-- value can contain the ':' or ',' that separate them.
--
-- ─── qpf/1, and why its Delivery Group keys are per-id ────────────────────
-- The presentation list is mostly FREE TEXT - labels, route notes, location
-- codes, addressee names. Joining those into one line would let a value
-- containing the separator forge a field boundary, so two different states
-- could hash identically. Emitting one key per Delivery Group per attribute
-- removes every inner delimiter: each value is escaped by fp_text alone and
-- ordering is the serializer's, not the aggregation's. The field set is closed
-- as a set of key PATTERNS rather than a fixed list, which is what a
-- variable-cardinality collection permits without ambiguity.

create or replace function app_private.calculation_payload(p_batch_row_id bigint)
returns text language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_row public.batch_rows%rowtype;
  v_sv  public.sku_versions%rowtype;
  v_pg  public.pricing_groups%rowtype;
  v_b   public.batches%rowtype;
  v_cvid bigint; v_ply int;
  v_ship bigint; v_dgstat text;
  v_eng text; v_round text; v_rel bigint;
  v_bp public.batch_profile_versions%rowtype;
  v_set bigint; v_members text;
  v_fr record; v_fl record;
  k text[]; v text[];
begin
  select * into v_row from public.batch_rows where id = p_batch_row_id;
  if not found then return null; end if;

  select * into v_sv from public.sku_versions   where id = v_row.sku_version_id;
  select * into v_pg from public.pricing_groups where id = v_row.pricing_group_id;
  select * into v_b  from public.batches        where id = v_row.batch_id;

  v_cvid := pg_catalog.coalesce(v_row.proposed_construction_version_id,
                                v_sv.construction_version_id);
  select cv.ply into v_ply from public.construction_versions cv where cv.id = v_cvid;

  select dg.ship_to_location_id, dg.status into v_ship, v_dgstat
    from public.delivery_groups dg where dg.id = v_pg.freight_basis_delivery_group_id;

  v_rel := v_b.pricing_basis_release_id;
  select cdv.engine_version, cdv.rounding_rule_version into v_eng, v_round
    from public.pricing_basis_releases pbr
    join public.calculation_default_versions cdv on cdv.id = pbr.calculation_default_version_id
   where pbr.id = v_rel;

  select * into v_bp from public.batch_profile_versions
   where batch_id = v_row.batch_id and is_current;

  v_set := pg_catalog.coalesce(
    (select bs.id from public.batch_sets bs where bs.box_row_id = v_row.id),
    (select m.set_id from public.batch_set_memberships m
      where m.row_id = v_row.id and m.status = 'active' limit 1));
  select pg_catalog.string_agg(m.role || ':' || m.row_id::text, ',' order by m.row_id)
    into v_members
    from public.batch_set_memberships m
   where m.set_id = v_set and m.status = 'active';

  select * into v_fr from app_private.resolve_row_freight(p_batch_row_id);
  select * into v_fl from app_private.resolve_row_fluting_bcf(p_batch_row_id);

  k := array[
    'row.waste_override_pct','row.margin_override_pct','row.conv_override_rate',
    'row.freight_override','row.row_type','row.pricing_group_id','row.sku_version_id',
    'row.fluting_bcf',
    'addon.printing','addon.stitching','addon.coating','addon.handling',
    'addon.moq_charge','addon.packing','addon.other','addon.unloading',
    'skuv.length_mm','skuv.width_mm','skuv.height_mm','skuv.box_type','skuv.ups',
    'skuv.spec_bs','skuv.spec_bct','skuv.spec_ect',
    'cv.id','cv.ply',
    'pg.freight_mode','pg.freight_basis_delivery_group_id','pg.freight_manual_value',
    'pg.interest_override_pct','pg.payment_terms_days',
    'pg.basis_ship_to_location_id','pg.basis_dg_status',
    'bp.waste_cbb_pct','bp.waste_pp_pct','bp.conv_box_rate','bp.conv_pp_rate',
    'bp.margin_box_pct','bp.margin_pp_pct',
    'batch.sector_id',
    'pbr.id','pbr.engine_version','pbr.rounding_rule_version','pbr.pricing_date',
    'set.members',
    'eff.freight','eff.freight_source','eff.freight_entry_id',
    'eff.fluting_bcf','eff.fluting_bcf_source'];

  v := array[
    app_private.fp_num(v_row.waste_override_pct),
    app_private.fp_num(v_row.margin_override_pct),
    app_private.fp_num(v_row.conv_override_rate),
    app_private.fp_num(v_row.freight_override),
    app_private.fp_text(v_row.row_type),
    app_private.fp_int(v_row.pricing_group_id),
    app_private.fp_int(v_row.sku_version_id),
    app_private.fp_num(v_row.fluting_bcf),
    app_private.fp_num(v_row.addon_printing),
    app_private.fp_num(v_row.addon_stitching),
    app_private.fp_num(v_row.addon_coating),
    app_private.fp_num(v_row.addon_handling),
    app_private.fp_num(v_row.addon_moq_charge),
    app_private.fp_num(v_row.addon_packing),
    app_private.fp_num(v_row.addon_other),
    app_private.fp_num(v_row.addon_unloading),
    app_private.fp_num(v_sv.length_mm),
    app_private.fp_num(v_sv.width_mm),
    app_private.fp_num(v_sv.height_mm),
    app_private.fp_text(v_sv.box_type),
    app_private.fp_int(v_sv.ups),
    app_private.fp_num(v_sv.spec_bs),
    app_private.fp_num(v_sv.spec_bct),
    app_private.fp_num(v_sv.spec_ect),
    app_private.fp_int(v_cvid),
    app_private.fp_int(v_ply),
    app_private.fp_text(v_pg.freight_mode),
    app_private.fp_int(v_pg.freight_basis_delivery_group_id),
    app_private.fp_num(v_pg.freight_manual_value),
    app_private.fp_num(v_pg.interest_override_pct),
    app_private.fp_int(v_pg.payment_terms_days),
    app_private.fp_int(v_ship),
    app_private.fp_text(v_dgstat),
    app_private.fp_num(v_bp.waste_cbb_pct),
    app_private.fp_num(v_bp.waste_pp_pct),
    app_private.fp_num(v_bp.conv_box_rate),
    app_private.fp_num(v_bp.conv_pp_rate),
    app_private.fp_num(v_bp.margin_box_pct),
    app_private.fp_num(v_bp.margin_pp_pct),
    app_private.fp_int(v_b.sector_id),
    app_private.fp_int(v_rel),
    app_private.fp_text(v_eng),
    app_private.fp_text(v_round),
    app_private.fp_date(v_b.pricing_date),
    app_private.fp_text(v_members),
    app_private.fp_num(v_fr.o_value),
    app_private.fp_text(v_fr.o_source),
    app_private.fp_int(v_fr.o_freight_entry_id),
    app_private.fp_num(v_fl.o_value),
    app_private.fp_text(v_fl.o_source)];

  return app_private.fingerprint_serialize('qcf/1', k, v);
end $fn$;

create or replace function app_private.calculation_fingerprint(p_batch_row_id bigint)
returns text language sql stable security definer set search_path = '' as $$
  select app_private.fingerprint_hex(app_private.calculation_payload(p_batch_row_id))
$$;

create or replace function app_private.presentation_payload(p_batch_row_id bigint)
returns text language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_row public.batch_rows%rowtype;
  v_pg  public.pricing_groups%rowtype;
  v_setcode text;
  k text[]; v text[]; r record;
begin
  select * into v_row from public.batch_rows where id = p_batch_row_id;
  if not found then return null; end if;
  select * into v_pg from public.pricing_groups where id = v_row.pricing_group_id;

  v_setcode := pg_catalog.coalesce(
    (select bs.set_code from public.batch_sets bs where bs.box_row_id = v_row.id),
    (select bs.set_code from public.batch_set_memberships m
       join public.batch_sets bs on bs.id = m.set_id
      where m.row_id = v_row.id and m.status = 'active' limit 1));

  k := array['row.material_code','pg.label','pg.payment_terms_text','set.set_code'];
  v := array[app_private.fp_text(v_row.material_code),
             app_private.fp_text(v_pg.label),
             app_private.fp_text(v_pg.payment_terms_text),
             app_private.fp_text(v_setcode)];

  for r in
    select dg.id, dg.label, dg.status, dg.route_notes,
           dg.bill_to_location_id, dg.ship_to_location_id,
           bl.location_code as bill_code, bp2.display_name as bill_party,
           sl.location_code as ship_code, sp.display_name as ship_party
      from public.delivery_groups dg
      left join public.customer_locations bl on bl.id = dg.bill_to_location_id
      left join public.parties bp2           on bp2.id = bl.party_id
      left join public.customer_locations sl on sl.id = dg.ship_to_location_id
      left join public.parties sp            on sp.id = sl.party_id
     where dg.pricing_group_id = v_row.pricing_group_id
     order by dg.id
  loop
    k := k || array[
      'dg.' || r.id::text || '.label',
      'dg.' || r.id::text || '.status',
      'dg.' || r.id::text || '.route_notes',
      'dg.' || r.id::text || '.bill_to_location_id',
      'dg.' || r.id::text || '.ship_to_location_id',
      'dg.' || r.id::text || '.bill_to_code',
      'dg.' || r.id::text || '.bill_to_party',
      'dg.' || r.id::text || '.ship_to_code',
      'dg.' || r.id::text || '.ship_to_party'];
    v := v || array[
      app_private.fp_text(r.label),
      app_private.fp_text(r.status),
      app_private.fp_text(r.route_notes),
      app_private.fp_int(r.bill_to_location_id),
      app_private.fp_int(r.ship_to_location_id),
      app_private.fp_text(r.bill_code),
      app_private.fp_text(r.bill_party),
      app_private.fp_text(r.ship_code),
      app_private.fp_text(r.ship_party)];
  end loop;

  return app_private.fingerprint_serialize('qpf/1', k, v);
end $fn$;

create or replace function app_private.presentation_fingerprint(p_batch_row_id bigint)
returns text language sql stable security definer set search_path = '' as $$
  select app_private.fingerprint_hex(app_private.presentation_payload(p_batch_row_id))
$$;

revoke all on function app_private.calculation_payload(bigint)      from public, anon, authenticated;
revoke all on function app_private.calculation_fingerprint(bigint)  from public, anon, authenticated;
revoke all on function app_private.presentation_payload(bigint)     from public, anon, authenticated;
revoke all on function app_private.presentation_fingerprint(bigint) from public, anon, authenticated;