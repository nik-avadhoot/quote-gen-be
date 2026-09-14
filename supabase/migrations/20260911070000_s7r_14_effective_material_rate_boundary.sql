-- S7-R/14: supplier-credit authority ends inside Rate Master.
--
-- The earlier correction removed supplier_credit from effective_inputs but
-- still handed raw price components and interest_pct to Calculate. The bundled
-- engine therefore continued to select a per-grade term and apply its own 1.5%
-- fallback. This migration closes that second authority.
--
-- Rate Master now establishes and stores one effective material rate for every
-- entry. Calculate receives only that value plus the governed entry identity.
-- The original components remain on the immutable approved master as upstream
-- evidence, but never cross the Calculate boundary.

alter table public.rate_entries
  add column effective_material_rate numeric(20,8);

lock table public.rate_entries in access exclusive mode;
alter table public.rate_entries disable trigger trg_re_follows_version;
update public.rate_entries re
   set effective_material_rate = pg_catalog.trim_scale(
         re.price + re.price * coalesce(re.interest_pct, rsv.credit_cost_pct) / 100
         - re.discount + re.freight)
  from public.rate_set_versions rsv
 where rsv.id = re.rate_set_version_id
   and rsv.plant_id = re.plant_id;
alter table public.rate_entries enable trigger trg_re_follows_version;

alter table public.rate_entries
  alter column effective_material_rate set not null,
  add constraint ck_re_effective_material_rate_nonnegative
    check (effective_material_rate >= 0);

comment on column public.rate_entries.effective_material_rate is
  'Governed Rate Master output consumed by Calculate. Established from the approved entry components and the entry-or-version supplier-credit term before the Rate Master crosses into Batch calculation. Calculate must never receive or reapply those upstream components.';

create or replace function app_private.establish_rate_entry_effective_material_rate()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_credit numeric;
begin
  select coalesce(new.interest_pct, rsv.credit_cost_pct)
    into v_credit
    from public.rate_set_versions rsv
   where rsv.id = new.rate_set_version_id
     and rsv.plant_id = new.plant_id;
  if not found then
    raise exception 'rate entry version/plant does not exist' using errcode = '23503';
  end if;
  new.effective_material_rate := pg_catalog.trim_scale(
    new.price + new.price * v_credit / 100 - new.discount + new.freight);
  return new;
end $fn$;

create trigger trg_re_effective_material_rate
  before insert or update of rate_set_version_id, plant_id, price, discount,
    freight, interest_pct, effective_material_rate on public.rate_entries
  for each row execute function app_private.establish_rate_entry_effective_material_rate();

-- A draft Rate Set version may change its default supplier-credit term. Refresh
-- its entries immediately, while the parent and children are still editable.
-- Approval itself may not smuggle in a simultaneous value change: finish the
-- draft value first, then approve the frozen result.
create or replace function app_private.refresh_rate_entry_effective_material_rates()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.status is distinct from old.status
     and new.credit_cost_pct is distinct from old.credit_cost_pct then
    raise exception 'credit_cost_pct must be final before approving or withdrawing a Rate Set version'
      using errcode = '23514';
  end if;
  if new.status = 'draft'
     and new.credit_cost_pct is distinct from old.credit_cost_pct then
    update public.rate_entries
       set effective_material_rate = effective_material_rate
     where rate_set_version_id = new.id
       and plant_id = new.plant_id;
  end if;
  return new;
end $fn$;

create trigger trg_rsv_refresh_effective_material_rates
  after update of credit_cost_pct, status on public.rate_set_versions
  for each row execute function app_private.refresh_rate_entry_effective_material_rates();

revoke all on function app_private.establish_rate_entry_effective_material_rate()
  from public, anon, authenticated;
revoke all on function app_private.refresh_rate_entry_effective_material_rates()
  from public, anon, authenticated;

create or replace function app_private.calculate_inputs(p_batch_row_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_row public.batch_rows%rowtype; v_b public.batches%rowtype;
  v_eng text; v_ei jsonb;
begin
  perform app_private.assert_calculate_eligible(p_batch_row_id);

  select * into v_row from public.batch_rows where id = p_batch_row_id;
  select * into v_b   from public.batches      where id = v_row.batch_id;
  select cdv.engine_version into v_eng
    from public.pricing_basis_releases pbr
    join public.calculation_default_versions cdv on cdv.id = pbr.calculation_default_version_id
   where pbr.id = v_b.pricing_basis_release_id;

  v_ei := app_private.build_effective_inputs(p_batch_row_id);

  return jsonb_build_object(
    'effective_inputs', v_ei,
    'rates', (select coalesce(jsonb_agg(jsonb_build_object(
                  'rate_entry_id', re.id,
                  'grade_code', re.grade_code,
                  'effective_material_rate', pg_catalog.trim_scale(re.effective_material_rate))
                  order by re.id), '[]'::jsonb)
                from public.rate_entries re
               where re.id in (select (x.value #>> '{}')::bigint
                                 from jsonb_each(v_ei->'provenance'->'layer_rate_entries') x
                                where jsonb_typeof(x.value) = 'number')),
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

revoke all on function app_private.calculate_inputs(bigint) from public, anon;
grant execute on function app_private.calculate_inputs(bigint) to authenticated;
