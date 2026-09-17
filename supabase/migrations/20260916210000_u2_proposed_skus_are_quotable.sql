-- U2 SKU Master: a Proposed SKU and an unapproved version are quotable (Amendment 04, D-01).
--
-- Product Owner ruling, 2026-09-16: a Proposed SKU "should be allowed to be calculated just like
-- prospects / new customers are allowed to be added in an incomplete manner in the Customer
-- Family Master, without holding back the quote per se. Exactly the same behaviour." CDM-11 already
-- said a Maker may quote a Proposed SKU; the applied gates said otherwise:
--
--   app_private.assert_calculate_eligible  refused a Proposed SKU       (sku_not_published)
--   app_private.send_batch                 refused an unapproved version (sku_version_unapproved)
--                                          and any SKU not active/discontinued (sku_not_published)
--
-- Both now admit Proposed SKUs and unapproved versions, exactly as a Prospect is admitted, and
-- refuse only a WITHDRAWN SKU (sku_withdrawn), which is the one state that means "this will never be
-- supplied". Nothing else in either function changes: the Construction, adoption, dimension, pricing
-- basis, freight and lock gates are untouched, and the calculation provenance already records the
-- SKU status it calculated, so a Checker sees a Proposed SKU in the evidence (the Maker/Checker
-- workflow is where a settled customer's approval is exercised - Amendment 04 D-06).
--
-- DEPENDS ON 20260916200000 (the 'withdrawn' status). Each change is an exact-anchor replacement of
-- the live definition, asserted to match exactly once, the S7R-8b / S7R-12 technique. Grants are
-- unchanged by CREATE OR REPLACE.
--
-- S9: no Family G table, route or runtime is enabled or relied on; S9 activation stays pending.

do $$
declare v_def text; v_cnt integer;
  c_old text := $q$  if v_skustat = 'proposed' then
    raise exception 'sku_not_published' using errcode = 'PT422';
  end if;$q$;
  c_new text := $q$  -- Amendment 04 D-01: a Proposed SKU is calculable, as a Prospect is. Only a withdrawn one is not.
  if v_skustat = 'withdrawn' then
    raise exception 'sku_withdrawn' using errcode = 'PT422';
  end if;$q$;
  s_old_version text := $q$  if exists (
      select 1 from public.batch_rows br
      join public.sku_versions sv on sv.id = br.sku_version_id and sv.sku_id = br.sku_id
       where br.batch_id = p_batch and br.status = 'active' and sv.approved_at is null) then
    raise exception 'sku_version_unapproved' using errcode = 'PT422';
  end if;
$q$;
  s_old_status text := $q$         and s.status not in ('active','discontinued')) then
    raise exception 'sku_not_published' using errcode = 'PT422';$q$;
  s_new_status text := $q$         and s.status = 'withdrawn') then
    -- Amendment 04 D-01: Proposed SKUs and unapproved versions send, as Prospects do.
    raise exception 'sku_withdrawn' using errcode = 'PT422';$q$;
begin
  if not exists (select 1 from pg_catalog.pg_constraint where conname = 'ck_sku_status'
                  and pg_catalog.pg_get_constraintdef(oid) like '%withdrawn%') then
    raise exception using errcode = 'object_not_in_prerequisite_state',
      message = 'Proposed-SKU quotability needs the withdrawn SKU status.',
      hint = 'Apply 20260916200000_u2_sku_master_governed_operations first.';
  end if;

  v_def := pg_catalog.pg_get_functiondef('app_private.assert_calculate_eligible(bigint)'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, c_old, ''))) / length(c_old);
  if v_cnt <> 1 then
    raise exception 'assert_calculate_eligible anchor matched % times, expected 1', v_cnt using errcode = '55000';
  end if;
  execute replace(v_def, c_old, c_new);

  v_def := pg_catalog.pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, s_old_version, ''))) / length(s_old_version);
  if v_cnt <> 1 then
    raise exception 'send_batch version anchor matched % times, expected 1', v_cnt using errcode = '55000';
  end if;
  v_def := replace(v_def, s_old_version, '');
  v_cnt := (length(v_def) - length(replace(v_def, s_old_status, ''))) / length(s_old_status);
  if v_cnt <> 1 then
    raise exception 'send_batch status anchor matched % times, expected 1', v_cnt using errcode = '55000';
  end if;
  execute replace(v_def, s_old_status, s_new_status);

  -- Prove the result rather than trust the replacement.
  v_def := pg_catalog.pg_get_functiondef('app_private.assert_calculate_eligible(bigint)'::regprocedure);
  if position('sku_not_published' in v_def) > 0 or position('sku_withdrawn' in v_def) = 0 then
    raise exception 'assert_calculate_eligible was not rewritten as intended' using errcode = '55000';
  end if;
  v_def := pg_catalog.pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure);
  if position('sku_not_published' in v_def) > 0 or position('sku_version_unapproved' in v_def) > 0
     or position('sku_withdrawn' in v_def) = 0 then
    raise exception 'send_batch was not rewritten as intended' using errcode = '55000';
  end if;
end $$;
