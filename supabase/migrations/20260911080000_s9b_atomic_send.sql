-- S9(b): first Send creates one complete, immutable Quote candidate atomically.
-- It allocates neither a Quote reference nor a revision number and emits no
-- workflow event; those acts belong to S9(c).

create or replace function app_private.send_batch(
  p_batch bigint,
  p_expected_content_version integer,
  p_existing_family bigint,
  p_source_revision bigint)
returns bigint
language plpgsql volatile security definer set search_path = '' as $fn$
declare
  v_b public.batches%rowtype;
  v_actor bigint;
  v_family bigint;
  v_revision bigint;
  v_snapshot bigint;
  v_item bigint;
  v_active integer;
  r record;
  v_in jsonb;
  v_fr jsonb;
begin
  v_actor := app_private.current_app_user();
  if v_actor is null then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into v_b from public.batches where id = p_batch for update;
  if not found or not app_private.can_write_batch(p_batch) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_b.content_version is distinct from p_expected_content_version then
    raise exception 'stale content_version' using errcode = 'PT409';
  end if;
  if v_b.status <> 'working' then
    raise exception 'transition not allowed' using errcode = '22023';
  end if;
  if p_existing_family is null then
    if p_source_revision is not null
       or exists (select 1 from public.quote_families qf where qf.batch_id = p_batch) then
      raise exception 'quote_family_exists' using errcode = 'PT422';
    end if;
  elsif not exists (select 1 from public.quote_families qf
                     where qf.id=p_existing_family and qf.batch_id=p_batch
                       and qf.status<>'abandoned')
     or p_source_revision is null
     or not exists (select 1 from public.quote_revisions qr
                     where qr.id=p_source_revision and qr.family_id=p_existing_family) then
    raise exception 'quote_family_invalid' using errcode = 'PT422';
  end if;

  select count(*)::integer into v_active
    from public.batch_rows br where br.batch_id = p_batch and br.status = 'active';
  if v_active = 0 then
    raise exception 'no_active_rows' using errcode = 'PT422';
  end if;

  if v_b.pricing_basis_release_id is null or not exists (
      select 1 from public.pricing_basis_releases pbr
       where pbr.id = v_b.pricing_basis_release_id
         and pbr.status = 'approved'
         and pbr.plant_id = v_b.plant_id
         and v_b.pricing_date >= pbr.effective_from
         and (pbr.effective_until is null or v_b.pricing_date <= pbr.effective_until)) then
    raise exception 'pricing_basis_inconsistent' using errcode = 'PT422';
  end if;

  if exists (
      select 1 from public.batch_rows br
      join public.pricing_groups pg on pg.id = br.pricing_group_id
       where br.batch_id = p_batch and br.status = 'active'
         and (pg.batch_id <> p_batch or pg.status <> 'active')) then
    raise exception 'pricing_group_inactive' using errcode = 'PT422';
  end if;
  if exists (
      select 1 from public.batch_rows br
       where br.batch_id = p_batch and br.status = 'active'
         and not exists (select 1 from public.delivery_groups dg
                          where dg.pricing_group_id = br.pricing_group_id
                            and dg.batch_id = p_batch and dg.status = 'active')) then
    raise exception 'delivery_group_absent' using errcode = 'PT422';
  end if;
  if exists (
      select 1 from public.batch_rows br
      join public.pricing_groups pg on pg.id = br.pricing_group_id
      left join public.delivery_groups dg
        on dg.id = pg.freight_basis_delivery_group_id
       and dg.pricing_group_id = pg.id and dg.batch_id = p_batch
      left join public.customer_locations cl on cl.id = dg.ship_to_location_id
       where br.batch_id = p_batch and br.status = 'active'
         and pg.freight_mode = 'master'
         and (dg.id is null or dg.status <> 'active' or dg.ship_to_location_id is null
              or cl.id is null or cl.status <> 'active' or not cl.ship_to_eligible)) then
    raise exception 'freight_basis_invalid' using errcode = 'PT422';
  end if;
  if exists (
      select 1 from public.batch_rows br
      join public.pricing_groups pg on pg.id = br.pricing_group_id
       where br.batch_id = p_batch and br.status = 'active'
         and ((pg.freight_mode = 'manual' and pg.freight_manual_value is null)
           or (pg.freight_mode = 'ex_factory' and pg.freight_basis_delivery_group_id is not null))) then
    raise exception 'freight_mode_invalid' using errcode = 'PT422';
  end if;

  if exists (
      select 1 from public.batch_rows br
      join public.sku_versions sv on sv.id = br.sku_version_id and sv.sku_id = br.sku_id
       where br.batch_id = p_batch and br.status = 'active' and sv.approved_at is null) then
    raise exception 'sku_version_unapproved' using errcode = 'PT422';
  end if;
  if exists (
      select 1 from public.batch_rows br
      join public.skus s on s.id = br.sku_id
       where br.batch_id = p_batch and br.status = 'active'
         and s.status not in ('active','discontinued')) then
    raise exception 'sku_not_published' using errcode = 'PT422';
  end if;
  if exists (
      select 1
        from public.batch_rows br
        join public.sku_versions sv on sv.id = br.sku_version_id
        join public.construction_versions cv
          on cv.id = coalesce(br.proposed_construction_version_id, sv.construction_version_id)
        join public.constructions c on c.id = cv.construction_id
       where br.batch_id = p_batch and br.status = 'active'
         and ((br.proposed_construction_version_id is not null and c.status <> 'proposed')
           or (br.proposed_construction_version_id is null and
               (c.status <> 'published' or not exists (
                 select 1 from public.plant_construction_adoptions pca
                  where pca.plant_id = br.plant_id
                    and pca.construction_version_id = cv.id and pca.status = 'adopted'))))) then
    raise exception 'construction_reference_invalid' using errcode = 'PT422';
  end if;

  if exists (
      select 1 from public.batch_rows br
       where br.batch_id = p_batch and br.status = 'active'
         and not exists (select 1 from public.batch_calculations bc
                          where bc.batch_row_id = br.id and bc.batch_id = p_batch)) then
    raise exception 'calculation_missing' using errcode = 'PT422';
  end if;
  if exists (
      select 1 from public.batch_rows br
      join public.batch_calculations bc on bc.batch_row_id = br.id and bc.batch_id = p_batch
       where br.batch_id = p_batch and br.status = 'active'
         and bc.calculation_fingerprint is distinct from app_private.calculation_fingerprint(br.id)) then
    raise exception 'calculation_stale' using errcode = 'PT422';
  end if;

  -- Pre-validate every row before the first insert. Effective inputs are not
  -- caller data: equality with a fresh gather proves every provenance identity,
  -- construction field, spec and resolved value against durable authority.
  for r in
    select br.*, bc.id as calculation_id, bc.schema_version, bc.engine_version,
           bc.calculation_fingerprint, bc.presentation_fingerprint,
           bc.effective_inputs, bc.results, bc.computed_by, bc.computed_at
      from public.batch_rows br
      join public.batch_calculations bc on bc.batch_row_id = br.id and bc.batch_id = p_batch
     where br.batch_id = p_batch and br.status = 'active'
     order by br.id
  loop
    v_in := app_private.build_effective_inputs(r.id);
    if r.computed_by is null or r.schema_version <> 1
       or r.effective_inputs is distinct from v_in
       or r.engine_version is distinct from v_in->'provenance'->>'engine_version'
       or r.effective_inputs->'provenance'->>'sku_status' not in ('active','discontinued')
       or (select array_agg(k order by k) from jsonb_object_keys(r.effective_inputs) k)
          is distinct from array['contract_version','entered','provenance','resolved']
       or (select array_agg(k order by k) from jsonb_object_keys(r.effective_inputs->'provenance') k)
          is distinct from array['batch_id','batch_row_id','batch_row_lineage_id',
            'calculation_default_version_id','construction_version_id','construction_version_origin',
            'engine_version','layer_rate_entries','plant_id','pricing_basis_release_id','pricing_date',
            'pricing_group_id','rate_set_version_id','rounding_rule_version','rounding_step','row_type',
            'sector_id','set_id','set_role','sku_id','sku_status','sku_version_id']
       or (select array_agg(k order by k) from jsonb_object_keys(r.effective_inputs->'resolved') k)
          is distinct from array['conv','freight','interest','margin','waste']
       or (select array_agg(k order by k) from jsonb_object_keys(r.effective_inputs->'entered') k)
          is distinct from array['add_ons','box_type','flute_f1','flute_f2','fluting_bcf','height_mm',
            'layers','length_mm','ply','sales_moq','spec_bct','spec_bs','spec_ect','ups','volume','width_mm']
    then
      raise exception 'payload_contract' using errcode = 'PT422';
    end if;
    perform app_private.validate_results_payload(r.results, r.effective_inputs);
    v_fr := r.effective_inputs->'resolved'->'freight';
    if v_fr->>'source' not in ('row','legacy_batch','pricing_group','master','legacy_matrix') then
      raise exception 'freight_unresolved' using errcode = 'PT422';
    end if;
    if ((v_fr->>'source' in ('row','pricing_group','master')) <> (v_fr->>'authority' = 'governed')) then
      raise exception 'freight_authority_mismatch' using errcode = 'PT422';
    end if;
    if ((v_fr->>'source' = 'master') <> ((v_fr->>'freight_set_version_id') is not null
                                          and (v_fr->>'freight_entry_id') is not null)) then
      raise exception 'freight_reference_shape' using errcode = 'PT422';
    end if;
    if v_fr->>'source' = 'master' and not exists (
        select 1 from public.freight_entries fe
         where fe.id = (v_fr->>'freight_entry_id')::bigint
           and fe.freight_set_version_id = (v_fr->>'freight_set_version_id')::bigint) then
      raise exception 'freight_reference_mismatch' using errcode = 'PT422';
    end if;
  end loop;

  if p_existing_family is null then
    insert into public.quote_families(batch_id, status, created_by)
      values (p_batch, 'draft', v_actor) returning id into v_family;
  else
    v_family := p_existing_family;
  end if;
  insert into public.quote_revisions(family_id, source_revision_id, workflow_status, created_by)
    values (v_family, p_source_revision, 'draft', v_actor) returning id into v_revision;

  for r in
    select br.*, bc.schema_version, bc.engine_version, bc.calculation_fingerprint,
           bc.presentation_fingerprint, bc.effective_inputs, bc.results,
           bc.computed_by, bc.computed_at
      from public.batch_rows br
      join public.batch_calculations bc on bc.batch_row_id = br.id and bc.batch_id = p_batch
     where br.batch_id = p_batch and br.status = 'active'
     order by br.id
  loop
    v_in := r.effective_inputs;
    v_fr := v_in->'resolved'->'freight';
    insert into public.calculation_snapshots(
      schema_version, engine_version, rounding_rule_version,
      pricing_basis_release_id, calculation_default_version_id, pricing_date,
      effective_waste_pct, waste_source, effective_conv_rate, conv_source,
      effective_margin_pct, margin_source, effective_interest_pct, interest_source,
      effective_freight, freight_source, freight_authority,
      freight_set_version_id, freight_entry_id,
      total_cost, final_rate, rate_per_kg, calc_moq,
      calculation_fingerprint, presentation_fingerprint, effective_inputs, results,
      calculated_by, calculated_at)
    values (
      1, r.engine_version, v_in->'provenance'->>'rounding_rule_version',
      (v_in->'provenance'->>'pricing_basis_release_id')::bigint,
      (v_in->'provenance'->>'calculation_default_version_id')::bigint,
      (v_in->'provenance'->>'pricing_date')::date,
      (v_in->'resolved'->'waste'->>'value')::numeric, v_in->'resolved'->'waste'->>'source',
      (v_in->'resolved'->'conv'->>'value')::numeric, v_in->'resolved'->'conv'->>'source',
      (v_in->'resolved'->'margin'->>'value')::numeric, v_in->'resolved'->'margin'->>'source',
      (v_in->'resolved'->'interest'->>'value')::numeric, v_in->'resolved'->'interest'->>'source',
      (v_fr->>'value')::numeric, v_fr->>'source', v_fr->>'authority',
      (v_fr->>'freight_set_version_id')::bigint, (v_fr->>'freight_entry_id')::bigint,
      (r.results->'engine'->>'total')::numeric,
      (r.results->'engine'->>'final_rate')::numeric,
      (r.results->'engine'->>'rate_per_kg')::numeric,
      (r.results->'engine'->>'calc_moq')::bigint,
      r.calculation_fingerprint, r.presentation_fingerprint, r.effective_inputs, r.results,
      r.computed_by, r.computed_at)
    returning id into v_snapshot;

    insert into public.quote_items(
      revision_id, batch_row_lineage_id, pricing_group_id, calculation_snapshot_id)
    values (v_revision, r.lineage_id, r.pricing_group_id, v_snapshot)
    returning id into v_item;

    insert into public.quote_item_delivery_groups(quote_item_id, delivery_group_id)
      select v_item, dg.id from public.delivery_groups dg
       where dg.pricing_group_id = r.pricing_group_id
         and dg.batch_id = p_batch and dg.status = 'active'
       order by dg.id;
  end loop;

  update public.batches
     set status = 'sent'
   where id = p_batch and content_version = p_expected_content_version;
  if not found then
    raise exception 'stale content_version' using errcode = 'PT409';
  end if;
  return v_revision;
end $fn$;

create or replace function public.send_batch(
  p_batch bigint,
  p_expected_content_version integer)
returns bigint language sql volatile set search_path = '' as $fn$
  select app_private.send_batch(p_batch, p_expected_content_version, null, null)
$fn$;

-- The invoker shim needs this grant to enter the definer implementation. The
-- app_private schema is not exposed by PostgREST, so this does not create a
-- second HTTP entry point (the established Calculate RPC uses the same shape).
revoke all on function app_private.send_batch(bigint,integer,bigint,bigint) from public, anon;
grant execute on function app_private.send_batch(bigint,integer,bigint,bigint) to authenticated;
revoke all on function public.send_batch(bigint,integer) from public, anon;
grant execute on function public.send_batch(bigint,integer) to authenticated;

comment on function public.send_batch(bigint,integer) is
  'S9(b) first Send: validates every active row and atomically creates an unnumbered draft Quote candidate.';
