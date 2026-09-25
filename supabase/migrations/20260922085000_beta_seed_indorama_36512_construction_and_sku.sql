-- Beta seed, Product Owner instruction 2026-09-22: the first governed SKU, so the
-- approval path has something to quote. Source of every value: SPEC row 207 of
-- "APSPL NAGPUR Master_20260720.xlsx" (Indo Rama, item code 36512). Nothing is invented;
-- the one mapping the Product Owner ruled is the top layer "35ShG" -> app grade 35GY.
--
-- Runs as app user 45 (ClaudeCode, auth e2ab29bb-94d4-447a-90ca-cafa34e85f83) — the
-- identity doing the work — so created_by attribution is truthful and is NOT written in
-- the Product Owner's name. Both governed RPCs are called exactly as the app calls them,
-- so every capability check and state guard runs; nothing is inserted table-first.
do $$
declare
  v_plant   bigint;
  v_party   bigint;
  v_version bigint;
  v_code    text;
  v_sku     bigint;
  r         record;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e2ab29bb-94d4-447a-90ca-cafa34e85f83","role":"authenticated"}', true);

  select id into strict v_plant from public.plants where plant_code = 'NAG';
  -- The tester already created Indo Rama as a Prospect; a Proposed SKU for a Prospect is
  -- quotable (Amendment 04), which is the whole point of not seeding a fake Customer.
  select id into strict v_party from public.parties
   where display_name = 'Indo Rama' and lifecycle_state = 'prospect';

  if exists (select 1 from public.sku_versions where item_name like '%36512%') then
    raise notice 'SKU 36512 already seeded; nothing to do';
    return;
  end if;

  select construction_version_id, construction_code into v_version, v_code
    from public.admin_publish_and_adopt_construction(
      v_plant,
      'Indo Rama DTY 5-ply BC 35GY/170-16/120-24/170-16/120-24/170',
      5, 'B', 'C',
      '35GY', '16', '24', '16', '24',
      170, 120, 170, 120, 170,
      null);

  v_sku := public.sku_propose(v_plant, v_party, 'Transactional', true, jsonb_build_object(
    'construction_version_id', v_version::text,
    'item_name',       'DTY 5PLY NC 675X450X282mm-M Code- 36512',
    'item_short_name', 'DTY 5PLY NC 675X450X282mm-M Code- 36512',
    'item_family',     'RSC',
    'item_group',      '2L+2W+F',
    'length_mm', 675, 'width_mm', 450, 'height_mm', 282,
    'box_type', 'RSC', 'ups', 2,
    'spec_bs', 14.1));

  raise notice 'seeded construction % (version %) and SKU %', v_code, v_version, v_sku;
end $$;