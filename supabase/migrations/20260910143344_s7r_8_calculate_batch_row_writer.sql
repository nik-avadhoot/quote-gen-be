-- S7-R/8: the Calculate writer.
--
-- WHAT MAKES THIS SAFE. public.calculate_batch_row is granted to authenticated,
-- which means it IS an HTTP endpoint - POST /rest/v1/rpc/calculate_batch_row -
-- reachable by anyone who can log in. That is not a defect to be hidden behind
-- the absence of a route; it is the design, and it is what keeps auth.uid()
-- authentic so can_write_batch needs no actor parameter and there is no
-- impersonation surface. What a direct caller cannot do is produce a valid
-- attestation, so the endpoint stays reachable and useless to forge against.
--
-- p_effective_inputs DOES NOT EXIST. Every input is durable since S9-P, so the
-- database assembles that object itself. A caller cannot describe inputs the
-- database does not hold, and the whole compare-what-was-supplied layer of the
-- withdrawn Revision 1 disappears with the parameter.
--
-- p_results_text IS text, NOT jsonb. Postgres parses jsonb at the parameter
-- boundary, so a jsonb parameter is a parsed VALUE and not the octets that were
-- signed: {"b": 1, "a": 2, "n": 1.50, "e": 1e2} round-trips to
-- {"a": 2, "b": 1, "e": 100, "n": 1.50} - keys reordered, 1e2 rewritten, and
-- the two lengths equal, so even a length check would miss it. The MAC is
-- verified over the exact UTF-8 bytes FIRST; only then is the text parsed, and
-- the parsed jsonb is what is stored. The signed text is not retained: this is
-- write-time admission control, not durable non-repudiation.
--
-- ONE VERIFICATION FAILURE, NOT PER-FIELD DIAGNOSTICS. The whole tuple is
-- rebuilt from the caller's identity and durable state and compared once.
-- Field-level errors would be a forgery oracle.
--
-- REPLACEMENT IS AN EXPLICIT CONDITIONAL. A bare
-- `on conflict do update where stored.computed_at < excluded.computed_at`
-- returns success for BOTH an older attestation and a same-instant different
-- one, silently writing nothing. A lost update must be loud, so those two cases
-- are separated: identical is a true no-op, strictly newer replaces, anything
-- else raises.

create or replace function app_private.validate_results_payload(
  p_results jsonb, p_inputs jsonb)
returns void language plpgsql immutable set search_path = '' as $fn$
declare
  c_engine constant text[] := array[
    'add_ons','area','calc_bs','calc_gsm','calc_moq','conv','cutting','deckle',
    'estimated_box_wt','final_rate','fr','fr_rate','int_c','margin_amt','mat',
    'moq_kg','rate_per_kg','total','wt','wt_sheet'];
  c_layers constant text[] := array['TOP','F1','L1','F2','L2'];
  v_keys text[]; e jsonb; d jsonb; i int; v_sum numeric; v_n numeric; k text;
begin
  if pg_catalog.jsonb_typeof(p_results) is distinct from 'object' then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;
  select pg_catalog.array_agg(x order by x) into v_keys
    from pg_catalog.jsonb_object_keys(p_results) x;
  if v_keys is distinct from array['contract_version','engine','row_details'] then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;
  if p_results->'contract_version' is distinct from to_jsonb(1) then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;

  e := p_results->'engine';
  if pg_catalog.jsonb_typeof(e) is distinct from 'object' then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;
  select pg_catalog.array_agg(x order by x) into v_keys
    from pg_catalog.jsonb_object_keys(e) x;
  if v_keys is distinct from c_engine then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;
  foreach k in array c_engine loop
    if pg_catalog.jsonb_typeof(e->k) is distinct from 'number' then
      raise exception 'payload_contract' using errcode = 'PT422';
    end if;
  end loop;

  d := p_results->'row_details';
  if pg_catalog.jsonb_typeof(d) is distinct from 'array'
     or pg_catalog.jsonb_array_length(d) <> 5 then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;
  for i in 0..4 loop
    select pg_catalog.array_agg(x order by x) into v_keys
      from pg_catalog.jsonb_object_keys(d->i) x;
    if pg_catalog.jsonb_typeof(d->i) is distinct from 'object'
       or (d->i->>'k') is distinct from c_layers[i+1]
       or (v_keys is distinct from array['cost','k','rate','wt']
           and v_keys is distinct from array['code','cost','gsm','k','rate','tu','ws','wt']) then
      raise exception 'payload_contract' using errcode = 'PT422';
    end if;
  end loop;

  -- The three internal identities. Retained, and demoted to what they always
  -- were: shape checks, not authority. The attestation is the authority.
  select pg_catalog.sum((v)::numeric) into v_sum
    from pg_catalog.jsonb_each_text(p_inputs->'entered'->'add_ons') as t(k2, v);
  if pg_catalog.abs((e->>'add_ons')::numeric - v_sum) > 0.0001 then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;
  v_n := (p_inputs->'resolved'->'freight'->>'value')::numeric;
  if pg_catalog.abs((e->>'fr_rate')::numeric - v_n) > 0.0001 then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;
  select pg_catalog.sum((x->>'wt')::numeric) into v_sum
    from pg_catalog.jsonb_array_elements(d) x;
  if pg_catalog.abs((e->>'wt')::numeric - v_sum) > 0.0001 then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;
  select pg_catalog.sum((x->>'cost')::numeric) into v_sum
    from pg_catalog.jsonb_array_elements(d) x;
  if pg_catalog.abs((e->>'mat')::numeric - v_sum) > 0.0001 then
    raise exception 'payload_contract' using errcode = 'PT422';
  end if;
end $fn$;

create or replace function app_private.calculate_batch_row(
  p_batch_row_id             bigint,
  p_expected_content_version integer,
  p_results_text             text,
  p_attestation              text)
returns bigint language plpgsql volatile security definer set search_path = '' as $fn$
declare
  c_max_life constant interval := interval '120 seconds';
  c_skew     constant interval := interval '5 seconds';
  v_row public.batch_rows%rowtype; v_b public.batches%rowtype;
  v_cdv public.calculation_default_versions%rowtype;
  v_inputs jsonb; v_results jsonb;
  v_calc_fp text; v_pres_fp text; v_sha text;
  v_att record; v_key bytea; v_expect text;
  v_actor bigint; v_sub text; v_id bigint;
  v_ex public.batch_calculations%rowtype;
begin
  if p_results_text is null
     or pg_catalog.octet_length(pg_catalog.convert_to(p_results_text,'UTF8')) > 65536 then
    raise exception 'results_too_large' using errcode = 'PT422';
  end if;

  perform app_private.assert_calculate_eligible(p_batch_row_id);

  select * into v_row from public.batch_rows where id = p_batch_row_id;
  if v_row.content_version is distinct from p_expected_content_version then
    raise exception 'stale content_version' using errcode = 'PT409';
  end if;
  select * into v_b from public.batches where id = v_row.batch_id;
  select cdv.* into v_cdv
    from public.pricing_basis_releases pbr
    join public.calculation_default_versions cdv on cdv.id = pbr.calculation_default_version_id
   where pbr.id = v_b.pricing_basis_release_id;

  v_inputs  := app_private.build_effective_inputs(p_batch_row_id);
  v_calc_fp := app_private.calculation_fingerprint(p_batch_row_id);
  v_pres_fp := app_private.presentation_fingerprint(p_batch_row_id);
  v_sha     := pg_catalog.encode(
                 pg_catalog.sha256(pg_catalog.convert_to(p_results_text,'UTF8')), 'hex');

  v_actor := app_private.current_app_user();
  v_sub   := (select auth.uid())::text;

  select * into v_att from app_private.qca_parse(p_attestation);
  if v_att.o_keyid is null then
    raise exception 'attestation_invalid' using errcode = 'PT422';
  end if;
  v_key := app_private.qca_key(v_att.o_keyid);
  if v_key is null then
    raise exception 'attestation_invalid' using errcode = 'PT422';
  end if;

  v_expect := pg_catalog.encode(
    pg_catalog.hmac(
      app_private.qca_mac_input(
        v_att.o_keyid, v_sub, v_actor, v_row.batch_id, v_row.id,
        v_row.content_version, v_b.pricing_basis_release_id, v_cdv.engine_version,
        v_calc_fp, v_pres_fp, v_sha, v_att.o_computed_at, v_att.o_expires_at),
      v_key, 'sha256'), 'hex');
  if v_expect is distinct from v_att.o_mac then
    raise exception 'attestation_invalid' using errcode = 'PT422';
  end if;

  if v_att.o_computed_at > pg_catalog.now() + c_skew then
    raise exception 'attestation_future' using errcode = 'PT422';
  end if;
  if v_att.o_expires_at <= pg_catalog.now() then
    raise exception 'attestation_expired' using errcode = 'PT422';
  end if;
  if v_att.o_expires_at <= v_att.o_computed_at
     or v_att.o_expires_at - v_att.o_computed_at > c_max_life then
    raise exception 'attestation_lifetime_exceeded' using errcode = 'PT422';
  end if;

  if not pg_catalog.pg_input_is_valid(p_results_text, 'jsonb') then
    raise exception 'results_not_json' using errcode = 'PT422';
  end if;
  v_results := p_results_text::jsonb;
  perform app_private.validate_results_payload(v_results, v_inputs);

  select * into v_ex from public.batch_calculations where batch_row_id = p_batch_row_id;
  if not found then
    insert into public.batch_calculations
      (batch_row_id, batch_id, calculation_fingerprint, presentation_fingerprint,
       engine_version, schema_version, effective_inputs, results, computed_by, computed_at)
    values (v_row.id, v_row.batch_id, v_calc_fp, v_pres_fp,
            v_cdv.engine_version, 1, v_inputs, v_results, v_actor, v_att.o_computed_at)
    returning id into v_id;
  elsif v_att.o_computed_at > v_ex.computed_at then
    update public.batch_calculations
       set calculation_fingerprint = v_calc_fp, presentation_fingerprint = v_pres_fp,
           engine_version = v_cdv.engine_version, schema_version = 1,
           effective_inputs = v_inputs, results = v_results,
           computed_by = v_actor, computed_at = v_att.o_computed_at
     where id = v_ex.id
    returning id into v_id;
  elsif v_att.o_computed_at = v_ex.computed_at
    and v_ex.computed_by is not distinct from v_actor
    and v_ex.calculation_fingerprint = v_calc_fp
    and v_ex.presentation_fingerprint = v_pres_fp
    and v_ex.results = v_results then
    v_id := v_ex.id;                                  -- genuine idempotent retry
  else
    raise exception 'calculation_superseded' using errcode = 'PT409';
  end if;

  return v_id;
exception when unique_violation then
  raise exception 'calculation_superseded' using errcode = 'PT409';
end $fn$;

create or replace function public.calculate_batch_row(
  p_batch_row_id bigint, p_expected_content_version integer,
  p_results_text text, p_attestation text)
returns bigint language sql volatile set search_path = '' as $$
  select app_private.calculate_batch_row(
           p_batch_row_id, p_expected_content_version, p_results_text, p_attestation)
$$;

revoke all on function app_private.validate_results_payload(jsonb, jsonb) from public, anon, authenticated;
revoke all on function app_private.calculate_batch_row(bigint, integer, text, text) from public, anon, authenticated;
revoke all on function public.calculate_batch_row(bigint, integer, text, text) from public, anon;
grant execute on function public.calculate_batch_row(bigint, integer, text, text) to authenticated;