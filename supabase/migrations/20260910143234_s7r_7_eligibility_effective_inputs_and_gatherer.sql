-- S7-R/7: Calculate eligibility, the effective_inputs builder, and the
-- read-only gatherer the trusted executor calls.
--
-- AUTHORITY IS CHECKED BEFORE ANY DEFINER-LEVEL READ, and the gatherer is NOT a
-- generic privileged row reader. It answers exactly one question about exactly
-- one Batch row, and only for a caller who could already write that Batch. An
-- unknown row is refused as an authority failure rather than as "not found", so
-- the endpoint cannot be used to probe which ids exist.
--
-- ONE BUILDER, TWO CALLERS. build_effective_inputs is called by this gatherer
-- and by the writer. The object the executor is shown and the object the
-- database stores are therefore the same object by construction - there is no
-- second assembly that could drift, and nothing about effective_inputs is ever
-- supplied by a caller.
--
-- D-X IS ENFORCED HERE, NOT INFERRED. can_write_batch admits a check_quote
-- holder on a SUBMITTED Batch. Calculate refuses that limb explicitly:
-- recalculation returns to the Maker.
--
-- D-W IS A CALCULATE REFUSAL, NOT A DEGRADATION. A retired basis Ship-to leaves
-- the Freight Entry resolvable and the rate unmoved, so the resolver still
-- resolves; the refusal is the writer's ruling and lives here. Existing
-- snapshots are untouched - the ruling is forward-only.
--
-- D-G FREEZES THE STATUS AND SUBSTITUTES NOTHING. A discontinued SKU may be
-- calculated, and provenance.sku_status records that it was. skus.replacement_
-- sku_id is deliberately never read.
--
-- entered.add_ons CARRIES WHAT THE ENGINE CONSUMED, coalesced to 0, because the
-- engine reads each charge as (+x || 0). The null-versus-zero distinction that
-- D-M protects lives in the FINGERPRINT (addon.printing = \N versus 0), where
-- it changes the hash. entered records consumption; qcf/1 records authority.

create or replace function app_private.assert_calculate_eligible(p_batch_row_id bigint)
returns void language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_row public.batch_rows%rowtype; v_b public.batches%rowtype;
  v_pbr public.pricing_basis_releases%rowtype; v_sv public.sku_versions%rowtype;
  v_cvid bigint; v_origin text; v_cstat text; v_skustat text;
  v_pg public.pricing_groups%rowtype; v_shipstat text;
  v_fr record; v_sc record;
begin
  select * into v_row from public.batch_rows where id = p_batch_row_id;
  -- An unknown row and an unauthorised row are one answer, deliberately.
  if not found or not app_private.can_write_batch(v_row.batch_id) then
    raise exception 'calculate: not permitted' using errcode = '42501';
  end if;

  select * into v_b from public.batches where id = v_row.batch_id;

  -- D-X
  if v_b.status = 'submitted' then
    raise exception 'calculate_requires_maker' using errcode = 'PT422';
  end if;
  if v_row.status is distinct from 'active' then
    raise exception 'row_inactive' using errcode = 'PT422';
  end if;

  if v_b.pricing_basis_release_id is null then
    raise exception 'pricing_basis_absent' using errcode = 'PT422';
  end if;
  select * into v_pbr from public.pricing_basis_releases where id = v_b.pricing_basis_release_id;
  if v_pbr.status is distinct from 'approved'
     or v_pbr.plant_id is distinct from v_b.plant_id
     or not (daterange(v_pbr.effective_from, v_pbr.effective_until, '[]') @> v_b.pricing_date) then
    raise exception 'pricing_basis_invalid' using errcode = 'PT422';
  end if;

  select s.status into v_skustat from public.skus s where s.id = v_row.sku_id;
  if v_skustat = 'proposed' then
    raise exception 'sku_not_published' using errcode = 'PT422';
  end if;

  select * into v_sv from public.sku_versions where id = v_row.sku_version_id;
  if v_sv.length_mm is null or v_sv.width_mm is null
     or (v_sv.height_mm is null and v_sv.box_type not in ('Board','PP')) then
    raise exception 'dimensions_incomplete' using errcode = 'PT422';
  end if;

  v_cvid   := pg_catalog.coalesce(v_row.proposed_construction_version_id, v_sv.construction_version_id);
  v_origin := case when v_row.proposed_construction_version_id is not null
                   then 'row_proposed' else 'sku_version' end;
  select c.status into v_cstat
    from public.construction_versions cv join public.constructions c on c.id = cv.construction_id
   where cv.id = v_cvid;
  if v_origin = 'row_proposed' and v_cstat is distinct from 'proposed' then
    -- C-2: guard_row_proposed_construction fires on batch_rows writes only, so a
    -- Construction published after the reference was set is caught nowhere else.
    raise exception 'construction_reference_invalid' using errcode = 'PT422';
  end if;
  if v_origin = 'sku_version' then
    if v_cstat is distinct from 'published' then
      raise exception 'construction_reference_invalid' using errcode = 'PT422';
    end if;
    if not exists (select 1 from public.plant_construction_adoptions a
                    where a.plant_id = v_b.plant_id
                      and a.construction_version_id = v_cvid
                      and a.status = 'adopted') then
      raise exception 'construction_reference_invalid' using errcode = 'PT422';
    end if;
  end if;

  -- D-W
  select * into v_pg from public.pricing_groups where id = v_row.pricing_group_id;
  if v_pg.freight_mode = 'master' and v_pg.freight_basis_delivery_group_id is not null then
    select cl.status into v_shipstat
      from public.delivery_groups dg
      join public.customer_locations cl on cl.id = dg.ship_to_location_id
     where dg.id = v_pg.freight_basis_delivery_group_id;
    if v_shipstat = 'inactive' then
      raise exception 'basis_ship_to_retired' using errcode = 'PT422';
    end if;
  end if;

  select * into v_fr from app_private.resolve_row_freight(p_batch_row_id);
  if v_fr.o_source is null or v_fr.o_source = 'unresolved' then
    raise exception 'freight_unresolved' using errcode = 'PT422';
  end if;

  select * into v_sc from app_private.resolve_row_supplier_credit(p_batch_row_id);
  if v_sc.o_ambiguous then
    raise exception 'supplier_credit_ambiguous' using errcode = 'PT422';
  end if;
end $fn$;

create or replace function app_private.build_effective_inputs(p_batch_row_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_row public.batch_rows%rowtype; v_b public.batches%rowtype;
  v_sv public.sku_versions%rowtype; v_cv public.construction_versions%rowtype;
  v_pbr public.pricing_basis_releases%rowtype; v_cdv public.calculation_default_versions%rowtype;
  v_pg public.pricing_groups%rowtype;
  v_cvid bigint; v_origin text; v_skustat text; v_set bigint; v_role text;
  v_inh record; v_int record; v_fr record; v_sc record; v_fl record;
begin
  select * into v_row from public.batch_rows where id = p_batch_row_id;
  if not found then return null; end if;
  select * into v_b   from public.batches        where id = v_row.batch_id;
  select * into v_sv  from public.sku_versions   where id = v_row.sku_version_id;
  select * into v_pg  from public.pricing_groups where id = v_row.pricing_group_id;
  select * into v_pbr from public.pricing_basis_releases where id = v_b.pricing_basis_release_id;
  select * into v_cdv from public.calculation_default_versions where id = v_pbr.calculation_default_version_id;

  v_cvid   := pg_catalog.coalesce(v_row.proposed_construction_version_id, v_sv.construction_version_id);
  v_origin := case when v_row.proposed_construction_version_id is not null
                   then 'row_proposed' else 'sku_version' end;
  select * into v_cv from public.construction_versions where id = v_cvid;
  select s.status into v_skustat from public.skus s where s.id = v_row.sku_id;

  select m.set_id, m.role into v_set, v_role
    from public.batch_set_memberships m
   where m.row_id = v_row.id and m.status = 'active' limit 1;

  select * into v_inh from app_private.resolve_row_inheritance(p_batch_row_id);
  select * into v_int from app_private.resolve_row_interest(p_batch_row_id);
  select * into v_fr  from app_private.resolve_row_freight(p_batch_row_id);
  select * into v_sc  from app_private.resolve_row_supplier_credit(p_batch_row_id);
  select * into v_fl  from app_private.resolve_row_fluting_bcf(p_batch_row_id);

  return jsonb_build_object(
    'contract_version', 1,
    'provenance', jsonb_build_object(
      'batch_id', v_row.batch_id,
      'batch_row_id', v_row.id,
      'batch_row_lineage_id', v_row.lineage_id,
      'pricing_group_id', v_row.pricing_group_id,
      'plant_id', v_row.plant_id,
      'sector_id', v_b.sector_id,
      'sku_id', v_row.sku_id,
      'sku_version_id', v_row.sku_version_id,
      'sku_status', v_skustat,
      'construction_version_id', v_cvid,
      'construction_version_origin', v_origin,
      'pricing_basis_release_id', v_b.pricing_basis_release_id,
      'rate_set_version_id', v_pbr.rate_set_version_id,
      'calculation_default_version_id', v_pbr.calculation_default_version_id,
      'pricing_date', pg_catalog.to_char(v_b.pricing_date, 'YYYY-MM-DD'),
      'engine_version', v_cdv.engine_version,
      'rounding_rule_version', v_cdv.rounding_rule_version,
      'rounding_step', pg_catalog.trim_scale(v_cdv.rounding_step),
      'row_type', v_row.row_type,
      'set_id', v_set,
      'set_role', v_role),
    'resolved', jsonb_build_object(
      'waste',  jsonb_build_object('value', pg_catalog.trim_scale(v_inh.o_waste),
                                   'source', v_inh.o_waste_source),
      'conv',   jsonb_build_object('value', pg_catalog.trim_scale(v_inh.o_conv),
                                   'source', v_inh.o_conv_source),
      'margin', jsonb_build_object('value', pg_catalog.trim_scale(v_inh.o_margin),
                                   'source', v_inh.o_margin_source),
      'interest', jsonb_build_object(
        'value', pg_catalog.trim_scale(v_int.o_value), 'source', v_int.o_source,
        'payment_terms_days', v_int.o_payment_terms_days,
        'annual_interest_pct', pg_catalog.trim_scale(v_int.o_annual_pct),
        'day_count_basis', v_int.o_day_count,
        'override_reason', v_int.o_override_reason),
      'freight', jsonb_build_object(
        'value', pg_catalog.trim_scale(v_fr.o_value), 'source', v_fr.o_source,
        'authority', v_fr.o_authority,
        'freight_set_version_id', v_fr.o_freight_set_version_id,
        'freight_entry_id', v_fr.o_freight_entry_id,
        'mode', v_pg.freight_mode,
        'degraded_from', v_fr.o_degraded_from),
      'supplier_credit', jsonb_build_object(
        'value', pg_catalog.trim_scale(v_sc.o_value), 'source', v_sc.o_source,
        'rate_entry_id', v_sc.o_rate_entry_id,
        'rate_set_version_id', v_sc.o_rate_set_version_id)),
    'entered', jsonb_build_object(
      'length_mm', pg_catalog.trim_scale(v_sv.length_mm),
      'width_mm',  pg_catalog.trim_scale(v_sv.width_mm),
      'height_mm', pg_catalog.trim_scale(v_sv.height_mm),
      'ply', v_cv.ply,
      'box_type', v_sv.box_type,
      'ups', v_sv.ups,
      'flute_f1', v_cv.flute_f1,
      'flute_f2', v_cv.flute_f2,
      'layers', jsonb_build_object(
        'TOP', jsonb_build_object('code', v_cv.layer_top_code, 'gsm', pg_catalog.trim_scale(v_cv.layer_top_gsm)),
        'F1',  jsonb_build_object('code', v_cv.layer_f1_code,  'gsm', pg_catalog.trim_scale(v_cv.layer_f1_gsm)),
        'L1',  jsonb_build_object('code', v_cv.layer_l1_code,  'gsm', pg_catalog.trim_scale(v_cv.layer_l1_gsm)),
        'F2',  jsonb_build_object('code', v_cv.layer_f2_code,  'gsm', pg_catalog.trim_scale(v_cv.layer_f2_gsm)),
        'L2',  jsonb_build_object('code', v_cv.layer_l2_code,  'gsm', pg_catalog.trim_scale(v_cv.layer_l2_gsm))),
      'fluting_bcf', pg_catalog.trim_scale(v_fl.o_value),
      'add_ons', jsonb_build_object(
        'printing',   pg_catalog.trim_scale(pg_catalog.coalesce(v_row.addon_printing, 0)),
        'stitching',  pg_catalog.trim_scale(pg_catalog.coalesce(v_row.addon_stitching, 0)),
        'coating',    pg_catalog.trim_scale(pg_catalog.coalesce(v_row.addon_coating, 0)),
        'handling',   pg_catalog.trim_scale(pg_catalog.coalesce(v_row.addon_handling, 0)),
        'moq_charge', pg_catalog.trim_scale(pg_catalog.coalesce(v_row.addon_moq_charge, 0)),
        'packing',    pg_catalog.trim_scale(pg_catalog.coalesce(v_row.addon_packing, 0)),
        'other',      pg_catalog.trim_scale(pg_catalog.coalesce(v_row.addon_other, 0)),
        'unloading',  pg_catalog.trim_scale(pg_catalog.coalesce(v_row.addon_unloading, 0))),
      'sales_moq', v_row.sales_moq,
      'volume', v_row.volume,
      'spec_bs',  pg_catalog.trim_scale(v_sv.spec_bs),
      'spec_bct', pg_catalog.trim_scale(v_sv.spec_bct),
      'spec_ect', pg_catalog.trim_scale(v_sv.spec_ect)));
end $fn$;

create or replace function app_private.calculate_inputs(p_batch_row_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_row public.batch_rows%rowtype; v_b public.batches%rowtype; v_eng text;
begin
  perform app_private.assert_calculate_eligible(p_batch_row_id);

  select * into v_row from public.batch_rows where id = p_batch_row_id;
  select * into v_b   from public.batches      where id = v_row.batch_id;
  select cdv.engine_version into v_eng
    from public.pricing_basis_releases pbr
    join public.calculation_default_versions cdv on cdv.id = pbr.calculation_default_version_id
   where pbr.id = v_b.pricing_basis_release_id;

  return jsonb_build_object(
    'effective_inputs', app_private.build_effective_inputs(p_batch_row_id),
    'binding', jsonb_build_object(
      'auth_sub', (select auth.uid())::text,
      'app_user_id', app_private.current_app_user(),
      'batch_id', v_row.batch_id,
      'batch_row_id', v_row.id,
      'content_version', v_row.content_version,
      'pricing_basis_release_id', v_b.pricing_basis_release_id,
      'engine_version', v_eng,
      'calculation_fingerprint', app_private.calculation_fingerprint(p_batch_row_id),
      'presentation_fingerprint', app_private.presentation_fingerprint(p_batch_row_id)));
end $fn$;

create or replace function public.calculate_inputs(p_batch_row_id bigint)
returns jsonb language sql stable set search_path = '' as $$
  select app_private.calculate_inputs(p_batch_row_id)
$$;

revoke all on function app_private.assert_calculate_eligible(bigint) from public, anon, authenticated;
revoke all on function app_private.build_effective_inputs(bigint)    from public, anon, authenticated;
revoke all on function app_private.calculate_inputs(bigint)          from public, anon, authenticated;
revoke all on function public.calculate_inputs(bigint) from public, anon;
grant execute on function public.calculate_inputs(bigint) to authenticated;