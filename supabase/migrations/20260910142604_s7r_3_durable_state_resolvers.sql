-- S7-R/3: the database-side resolvers the fingerprint and the writer both need.
--
-- These are the first database implementations of the freight chain and the
-- fluting tier. Until now both existed only in the browser engine, which is
-- why the fingerprint could not be fed the resolver's OUTPUT provenance as
-- S10.4 requires - there was no resolver on this side to ask.
--
-- STABLE, SECURITY DEFINER, search_path = ''. They answer "what does this row
-- resolve to", which is a property of the database and not of the caller's
-- visibility. An INVOKER resolver would silently become a second, accidental
-- read requirement - the S6 lesson - and would return a different answer to two
-- callers looking at the same row, which is the one thing a fingerprint input
-- may never do.
--
-- THE CHAIN, AND WHY IT HAS EXACTLY ONE WINNER (S9-P S4.4, D-N Path A, D-Q):
--
--   row override            'row'            governed
--     legacy_batch          'legacy_batch'   TEMPORARY    -> U4
--       manual              'pricing_group'  governed     terminates
--       ex_factory          'pricing_group'  governed     terminates, value 0
--       master              delegates downward via its governed BASIS
--         approved master   'master'         governed     freight_entries
--           legacy_matrix   'legacy_matrix'  TEMPORARY    -> U3
--             unresolved                                  blocks
--
-- legacy_batch sits ABOVE the Pricing Group tier and legacy_matrix BELOW the
-- approved master. A stored legacy_matrix that is not selected is the chain
-- working, not a contradiction - which is why the withdrawn guard trigger is
-- not reintroduced here and CP-65/CP-66 prove the behaviour instead.
--
-- degraded_from IS RECORDED, NEVER ACTED ON. It is how an issued Quote can
-- later explain why it did not reach the governed master. The vocabulary is
-- closed so it cannot become free text.
--
-- A RETIRED BASIS SHIP-TO IS NOT A DEGRADATION. The Freight Entry is keyed by
-- location id and stays resolvable, so the rate does not move. D-W makes it a
-- REFUSAL at Calculate, which is the writer's job, not the resolver's. Leaving
-- it out of here keeps the resolver a statement of what the chain yields.

create or replace function app_private.resolve_row_freight(
  p_batch_row_id bigint,
  out o_value                   numeric,
  out o_source                  text,
  out o_authority               text,
  out o_freight_set_version_id  bigint,
  out o_freight_entry_id        bigint,
  out o_degraded_from           text)
returns record language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_row public.batch_rows%rowtype;
  v_pg  public.pricing_groups%rowtype;
  v_b   public.batches%rowtype;
  v_fsv bigint; v_ship bigint; v_dgstat text; v_rate numeric; v_entry bigint;
begin
  select * into v_row from public.batch_rows where id = p_batch_row_id;
  if not found then return; end if;
  select * into v_pg from public.pricing_groups where id = v_row.pricing_group_id;
  select * into v_b  from public.batches         where id = v_row.batch_id;

  if v_pg.id is null then
    o_source := 'unresolved'; o_degraded_from := 'no_pricing_group'; return;
  end if;

  -- 1. row override, governed, terminates
  if v_row.freight_override is not null then
    o_value := v_row.freight_override; o_source := 'row'; o_authority := 'governed';
    return;
  end if;

  -- 2. legacy Batch override, TEMPORARY, outranks the Pricing Group tier
  if v_pg.legacy_freight_source = 'legacy_batch' then
    o_value := v_pg.legacy_freight_value; o_source := 'legacy_batch';
    o_authority := 'temporary'; return;
  end if;

  -- 3. the governed Pricing Group tier
  if v_pg.freight_mode = 'manual' then
    o_value := v_pg.freight_manual_value; o_source := 'pricing_group';
    o_authority := 'governed'; return;
  elsif v_pg.freight_mode = 'ex_factory' then
    o_value := 0; o_source := 'pricing_group'; o_authority := 'governed'; return;
  end if;

  -- 4. master mode delegates to the governed basis
  select fsv.id into v_fsv
    from public.pricing_basis_releases pbr
    join public.freight_set_versions fsv on fsv.id = pbr.freight_set_version_id
   where pbr.id = v_b.pricing_basis_release_id;

  select dg.ship_to_location_id, dg.status into v_ship, v_dgstat
    from public.delivery_groups dg
   where dg.id = v_pg.freight_basis_delivery_group_id;

  if v_pg.freight_basis_delivery_group_id is null or v_dgstat is distinct from 'active' then
    o_degraded_from := 'basis_missing';
  elsif v_ship is null then
    o_degraded_from := 'basis_ship_to_missing';
  else
    select fe.rate, fe.id into v_rate, v_entry
      from public.freight_entries fe
     where fe.freight_set_version_id = v_fsv
       and fe.origin_plant_id        = v_b.plant_id
       and fe.destination_location_id = v_ship;
    if found then
      o_value := v_rate; o_source := 'master'; o_authority := 'governed';
      o_freight_set_version_id := v_fsv; o_freight_entry_id := v_entry;
      return;
    end if;
    o_degraded_from := 'no_approved_pair';
  end if;

  -- 5. the stored matrix fallback, TEMPORARY, only because the master did not resolve
  if v_pg.legacy_freight_source = 'legacy_matrix' then
    o_value := v_pg.legacy_freight_value; o_source := 'legacy_matrix';
    o_authority := 'temporary'; return;
  end if;

  o_source := 'unresolved';
end $fn$;

-- The fluting take-up factor: row override, else the approved versioned tier.
create or replace function app_private.resolve_row_fluting_bcf(
  p_batch_row_id bigint,
  out o_value numeric,
  out o_source text)
returns record language plpgsql stable security definer set search_path = '' as $fn$
declare v_row_bcf numeric; v_default numeric;
begin
  select br.fluting_bcf into v_row_bcf
    from public.batch_rows br where br.id = p_batch_row_id;
  if v_row_bcf is not null then
    o_value := v_row_bcf; o_source := 'row'; return;
  end if;
  select cdv.fluting_bcf_default into v_default
    from public.batch_rows br
    join public.batches b on b.id = br.batch_id
    join public.pricing_basis_releases pbr on pbr.id = b.pricing_basis_release_id
    join public.calculation_default_versions cdv on cdv.id = pbr.calculation_default_version_id
   where br.id = p_batch_row_id;
  o_value := v_default;
  o_source := case when v_default is null then null else 'system' end;
end $fn$;

revoke all on function app_private.resolve_row_freight(bigint)     from public, anon, authenticated;
revoke all on function app_private.resolve_row_fluting_bcf(bigint) from public, anon, authenticated;