-- S7-R/6: the remaining CDM-19 / CDM-18 / CDM-41 chains, database-side.
--
-- The S7 resolver lives in JavaScript and answers for the browser. These answer
-- for the database, which is what lets effective_inputs be ASSEMBLED here
-- rather than accepted from a caller. Same tier order, same blank-versus-zero
-- discipline: only NULL advances a chain, and an explicit 0 terminates it.
--
-- THE PP / BOX ARM. CDM-19 gives row -> Batch (Box|PP) -> Sector -> system with
-- NO cross-over. row_type 'box' takes the CBB/Box columns; every other row_type
-- takes the PP columns. Margin's third tier is sector_versions.margin_pct,
-- which is a single column and not split - that is the Sector Margin ruling,
-- not an omission here.
--
-- ─── FINDING 1, recorded not resolved: which Sector version the tier reads ──
-- pricing_basis_releases pins exactly ONE sector_version_id for the whole
-- plant, while every Batch carries its own nullable sector_id. When the two
-- name different Sectors the Release's pinned version is not this Batch's
-- Sector's version, and nothing in the ratified sources says how to find the
-- latter. The only non-inventive reading is implemented: the pinned version
-- governs when it belongs to the Batch's Sector, and otherwise the Sector tier
-- does not resolve and the chain falls through to the versioned system tier -
-- which is also what S9(b) S1.1 already requires for a null Sector ("resolves
-- through to the system tier and is NOT a completeness failure"). Flagged.
--
-- ─── FINDING 2, recorded and made to FAIL CLOSED: supplier credit ──────────
-- CDM-41 puts supplier paper-credit cost on the Rate Set version, and
-- rate_entries.interest_pct is a per-GRADE exception. A board row has up to
-- five grades - the five layer codes of its Construction version - so a row can
-- carry several different per-grade overrides at once. The ratified contract
-- has ONE slot (S9(b) S1.4: value, source, rate_entry_id, rate_set_version_id).
-- Rather than invent a grade-selection rule, which would silently become
-- commercial policy, this resolver refuses when the row's grades disagree.
-- Nothing is guessed and nothing is hidden.

create or replace function app_private.resolve_row_inheritance(
  p_batch_row_id bigint,
  out o_waste numeric,  out o_waste_source text,
  out o_conv numeric,   out o_conv_source text,
  out o_margin numeric, out o_margin_source text)
returns record language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_row public.batch_rows%rowtype;
  v_bp  public.batch_profile_versions%rowtype;
  v_sv  public.sector_versions%rowtype;
  v_cdv public.calculation_default_versions%rowtype;
  v_b   public.batches%rowtype;
  v_pp  boolean;
begin
  select * into v_row from public.batch_rows where id = p_batch_row_id;
  if not found then return; end if;
  select * into v_b from public.batches where id = v_row.batch_id;
  v_pp := v_row.row_type is distinct from 'box';

  select * into v_bp from public.batch_profile_versions
   where batch_id = v_row.batch_id and is_current;

  -- The Release's pinned Sector version governs only its OWN Sector. See
  -- FINDING 1: no other rule is stated anywhere, so none is invented.
  select sv.* into v_sv
    from public.pricing_basis_releases pbr
    join public.sector_versions sv on sv.id = pbr.sector_version_id
   where pbr.id = v_b.pricing_basis_release_id
     and v_b.sector_id is not null
     and sv.sector_id = v_b.sector_id;

  select cdv.* into v_cdv
    from public.pricing_basis_releases pbr
    join public.calculation_default_versions cdv on cdv.id = pbr.calculation_default_version_id
   where pbr.id = v_b.pricing_basis_release_id;

  -- waste
  if v_row.waste_override_pct is not null then
    o_waste := v_row.waste_override_pct; o_waste_source := 'row';
  elsif (case when v_pp then v_bp.waste_pp_pct else v_bp.waste_cbb_pct end) is not null then
    o_waste := case when v_pp then v_bp.waste_pp_pct else v_bp.waste_cbb_pct end;
    o_waste_source := 'batch';
  elsif (case when v_pp then v_sv.waste_pp_pct else v_sv.waste_cbb_pct end) is not null then
    o_waste := case when v_pp then v_sv.waste_pp_pct else v_sv.waste_cbb_pct end;
    o_waste_source := 'sector';
  else
    o_waste := case when v_pp then v_cdv.waste_pp_fallback_pct else v_cdv.waste_cbb_fallback_pct end;
    o_waste_source := case when o_waste is null then null else 'system' end;
  end if;

  -- conversion
  if v_row.conv_override_rate is not null then
    o_conv := v_row.conv_override_rate; o_conv_source := 'row';
  elsif (case when v_pp then v_bp.conv_pp_rate else v_bp.conv_box_rate end) is not null then
    o_conv := case when v_pp then v_bp.conv_pp_rate else v_bp.conv_box_rate end;
    o_conv_source := 'batch';
  elsif (case when v_pp then v_sv.conv_pp_rate else v_sv.conv_box_rate end) is not null then
    o_conv := case when v_pp then v_sv.conv_pp_rate else v_sv.conv_box_rate end;
    o_conv_source := 'sector';
  else
    o_conv := case when v_pp then v_cdv.conv_pp_fallback_rate else v_cdv.conv_box_fallback_rate end;
    o_conv_source := case when o_conv is null then null else 'system' end;
  end if;

  -- margin: the Sector tier is a single column, not split
  if v_row.margin_override_pct is not null then
    o_margin := v_row.margin_override_pct; o_margin_source := 'row';
  elsif (case when v_pp then v_bp.margin_pp_pct else v_bp.margin_box_pct end) is not null then
    o_margin := case when v_pp then v_bp.margin_pp_pct else v_bp.margin_box_pct end;
    o_margin_source := 'batch';
  elsif v_sv.margin_pct is not null then
    o_margin := v_sv.margin_pct; o_margin_source := 'sector';
  else
    o_margin := v_cdv.margin_fallback_pct;
    o_margin_source := case when o_margin is null then null else 'system' end;
  end if;
end $fn$;

create or replace function app_private.resolve_row_interest(
  p_batch_row_id bigint,
  out o_value numeric, out o_source text, out o_payment_terms_days integer,
  out o_annual_pct numeric, out o_day_count integer, out o_override_reason text)
returns record language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_pg public.pricing_groups%rowtype;
  v_cdv public.calculation_default_versions%rowtype;
begin
  select pg2.* into v_pg
    from public.batch_rows br join public.pricing_groups pg2 on pg2.id = br.pricing_group_id
   where br.id = p_batch_row_id;
  if not found then return; end if;

  select cdv.* into v_cdv
    from public.batch_rows br
    join public.batches b on b.id = br.batch_id
    join public.pricing_basis_releases pbr on pbr.id = b.pricing_basis_release_id
    join public.calculation_default_versions cdv on cdv.id = pbr.calculation_default_version_id
   where br.id = p_batch_row_id;

  o_payment_terms_days := v_pg.payment_terms_days;
  o_annual_pct := v_cdv.annual_interest_pct;
  o_day_count  := v_cdv.day_count_basis;

  if v_pg.interest_override_pct is not null then
    o_value := v_pg.interest_override_pct;
    o_source := 'pricing_group';
    o_override_reason := v_pg.interest_override_reason;
  elsif v_pg.payment_terms_days is not null and v_cdv.id is not null then
    -- CDM-18: 6.000% per annum on a strict 360-day denominator, derived rather
    -- than mapped. The four derived figures reproduce the withdrawn map exactly.
    o_value := pg_catalog.round(v_cdv.annual_interest_pct
                                * v_pg.payment_terms_days / v_cdv.day_count_basis, 3);
    o_source := 'derived_annual';
  else
    o_value := v_cdv.interest_fallback_pct;
    o_source := case when o_value is null then null else 'system' end;
  end if;
end $fn$;

create or replace function app_private.resolve_row_supplier_credit(
  p_batch_row_id bigint,
  out o_value numeric, out o_source text,
  out o_rate_entry_id bigint, out o_rate_set_version_id bigint,
  out o_ambiguous boolean)
returns record language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_rsv bigint; v_credit numeric; v_cvid bigint; v_grades text[];
  v_n int; v_entry bigint; v_pct numeric;
begin
  select pbr.rate_set_version_id, rsv.credit_cost_pct
    into v_rsv, v_credit
    from public.batch_rows br
    join public.batches b on b.id = br.batch_id
    join public.pricing_basis_releases pbr on pbr.id = b.pricing_basis_release_id
    join public.rate_set_versions rsv on rsv.id = pbr.rate_set_version_id
   where br.id = p_batch_row_id;
  if v_rsv is null then return; end if;
  o_rate_set_version_id := v_rsv;
  o_ambiguous := false;

  select pg_catalog.coalesce(br.proposed_construction_version_id, sv.construction_version_id)
    into v_cvid
    from public.batch_rows br join public.sku_versions sv on sv.id = br.sku_version_id
   where br.id = p_batch_row_id;

  select pg_catalog.array_remove(array[cv.layer_top_code, cv.layer_f1_code, cv.layer_l1_code,
                                       cv.layer_f2_code, cv.layer_l2_code], null)
    into v_grades
    from public.construction_versions cv where cv.id = v_cvid;

  -- Distinct per-grade overrides among THIS row's grades, in THIS Rate Set
  -- version. See FINDING 2: one slot, possibly several answers.
  select pg_catalog.count(distinct re.interest_pct),
         pg_catalog.min(re.id), pg_catalog.min(re.interest_pct)
    into v_n, v_entry, v_pct
    from public.rate_entries re
   where re.rate_set_version_id = v_rsv
     and re.grade_code = any(pg_catalog.coalesce(v_grades, '{}'::text[]))
     and re.interest_pct is not null;

  if v_n = 0 or v_n is null then
    o_value := v_credit; o_source := 'rate_set_version';
  elsif v_n = 1 then
    o_value := v_pct; o_source := 'rate_entry'; o_rate_entry_id := v_entry;
    o_rate_set_version_id := null;
  else
    o_ambiguous := true;
  end if;
end $fn$;

revoke all on function app_private.resolve_row_inheritance(bigint)     from public, anon, authenticated;
revoke all on function app_private.resolve_row_interest(bigint)        from public, anon, authenticated;
revoke all on function app_private.resolve_row_supplier_credit(bigint) from public, anon, authenticated;