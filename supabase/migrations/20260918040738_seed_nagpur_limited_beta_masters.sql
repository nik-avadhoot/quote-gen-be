-- Wave B: first governed Nagpur limited-beta commercial masters.
--
-- Product Owner source exception, 2026-09-17/18: the Rate Set and Freight Set
-- below are the application's CURRENT DEFAULTS, not workbook-derived values.
-- They are the first governed Nagpur versions and the alongside-week evidence
-- must retain that distinction. Only the exact active Nagpur Ship-to
-- G0080-001-03 is covered by governed freight; every other destination uses an
-- explicit Maker-entered manual Pricing Group value. Job work and grade 18J are
-- deliberately absent. Grade 25 is its own exact governed identity and carries
-- the same commercial values as grade 24 for now; it is not 24GY or 25WTL.

do $wave_b$
declare
  v_actor bigint;
  v_auth uuid;
  v_nag bigint;
  v_ship_to bigint;
  v_rate_set bigint;
  v_rate_version bigint;
  v_freight_set bigint;
  v_freight_version bigint;
  v_sector_version bigint;
  v_defaults bigint;
  v_release bigint;
  v_construction bigint;
  v_construction_version bigint;
  v_count integer;
begin
  select u.id, u.auth_user_id
    into strict v_actor, v_auth
    from public.app_users u
    join auth.users a on a.id = u.auth_user_id
   where lower(a.email) = lower('nikunj@avadhootpacks.in')
     and u.status = 'active';

  select p.id into strict v_nag
    from public.plants p
   where p.plant_code = 'NAG'
     and p.name = 'Nagpur'
     and p.status = 'active';

  select l.id into strict v_ship_to
    from public.customer_locations l
    join public.parties p on p.id = l.party_id
    join public.customer_location_versions lv
      on lv.location_id = l.id and lv.status = 'current'
   where p.id = 245
     and p.customer_code = 'G0080-001'
     and l.location_code = 'G0080-001-03'
     and l.status = 'active'
     and not l.bill_to_eligible
     and l.ship_to_eligible
     and btrim(lv.address_text) = 'Nagpur';

  if not exists (
    select 1
      from public.group_capability_grants g
      join public.capabilities c on c.id = g.capability_id
     where g.app_user_id = v_actor and g.status = 'active'
       and c.capability_key = 'manage_construction_library'
  ) then
    raise exception 'named seed actor lacks manage_construction_library';
  end if;

  if exists (
    select required.capability_key
      from (values
        ('plant_access'),
        ('propose_commercial_master'),
        ('approve_commercial_master'),
        ('adopt_construction_for_plant')
      ) as required(capability_key)
     where not exists (
       select 1
         from public.plant_capability_grants g
         join public.capabilities c on c.id = g.capability_id
        where g.app_user_id = v_actor
          and g.plant_id = v_nag
          and g.status = 'active'
          and c.capability_key = required.capability_key
     )
  ) then
    raise exception 'named seed actor lacks a required active NAG capability';
  end if;

  if exists (select 1 from public.sectors)
     or exists (select 1 from public.calculation_default_versions)
     or exists (select 1 from public.rate_sets where plant_id = v_nag)
     or exists (select 1 from public.freight_sets where plant_id = v_nag)
     or exists (select 1 from public.pricing_basis_releases where plant_id = v_nag)
     or exists (select 1 from public.constructions where name like 'Beta %') then
    raise exception 'Wave B expects empty governed beta targets; refusing a partial or duplicate seed';
  end if;

  perform pg_catalog.set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_auth::text,
      'role', 'authenticated',
      'email', 'nikunj@avadhootpacks.in'
    )::text,
    true
  );
  set local role authenticated;

  insert into public.sectors (sector_code, name, status, created_by)
  select x.sector_code, x.name, 'active', v_actor
    from (values
      ('PAINTS', 'Paints / Decorative'),
      ('ALCOBEV', 'Alcobev (Glass & PET)'),
      ('ICE-CREAM', 'Ice Cream / Dairy'),
      ('SOLAR-PANEL', 'Solar — Panel Box'),
      ('SOLAR-CELL', 'Solar — Cell/Ingot'),
      ('COOLER', 'Coolers / White Goods'),
      ('TEXTILE', 'Textiles / Warehousing'),
      ('FOOD-SVC', 'Food Service / QSR'),
      ('BISCUIT', 'Biscuits & Confectionery'),
      ('CHIPS', 'Snacks / Chips'),
      ('PETROL', 'Petroleum / Lubricants'),
      ('EDIBLE-OIL', 'FMCG / Edible Oils'),
      ('FOOTWEAR', 'Footwear'),
      ('ELEC-LED', 'Electronics / LED'),
      ('BEAUTY', 'Beauty / D2C'),
      ('CHEMICAL', 'Chemicals / Adhesives'),
      ('FANS', 'Consumer Durables/Fans'),
      ('PHARMA', 'Pharmaceuticals'),
      ('FMCG-FOOD', 'FMCG Food / Staples')
    ) as x(sector_code, name);

  insert into public.sector_versions (
    sector_id, version_no, waste_cbb_pct, waste_pp_pct,
    conv_box_rate, conv_pp_rate, margin_pct, spec_lang, created_by
  )
  select s.id, 1, x.waste_cbb, x.waste_pp,
         x.conv_box, x.conv_pp, 8.000, x.spec_lang, v_actor
    from (values
      ('PAINTS', 5.000, 5.000, 7.0000, 10.0000, 'ECT+BS'),
      ('ALCOBEV', 5.000, 5.000, 7.0000, 12.5000, 'BS'),
      ('ICE-CREAM', 5.000, 5.000, 12.0000, 0.0000, 'BS'),
      ('SOLAR-PANEL', 5.000, 3.000, 15.0000, 0.0000, 'BS+BCT'),
      ('SOLAR-CELL', 5.000, 3.000, 6.5000, 0.0000, 'CS+BS'),
      ('COOLER', 5.000, 0.000, 11.0000, 0.0000, 'BS'),
      ('TEXTILE', 5.000, 0.000, 5.7500, 0.0000, 'BS'),
      ('FOOD-SVC', 5.000, 0.000, 12.0000, 0.0000, 'BCT'),
      ('BISCUIT', 4.000, 5.000, 7.0000, 10.0000, 'BCT+BS'),
      ('CHIPS', 4.000, 5.000, 6.5000, 10.0000, 'BCT+BS'),
      ('PETROL', 5.000, 0.000, 7.0000, 0.0000, 'BCT+BS'),
      ('EDIBLE-OIL', 5.000, 0.000, 7.0000, 0.0000, 'CS+BS'),
      ('FOOTWEAR', 5.000, 0.000, 8.0000, 0.0000, 'BS'),
      ('ELEC-LED', 6.000, 0.000, 7.0000, 0.0000, 'BS'),
      ('BEAUTY', 7.000, 0.000, 6.0000, 0.0000, 'BCT'),
      ('CHEMICAL', 5.000, 5.000, 7.0000, 0.0000, 'BS'),
      ('FANS', 5.000, 5.000, 8.0000, 10.0000, 'BS'),
      ('PHARMA', 5.000, 5.000, 7.0000, 10.0000, 'BCT+BS'),
      ('FMCG-FOOD', 5.000, 5.000, 7.0000, 10.0000, 'BCT+BS')
    ) as x(sector_code, waste_cbb, waste_pp, conv_box, conv_pp, spec_lang)
    join public.sectors s on s.sector_code = x.sector_code;

  update public.sector_versions sv
     set status = 'approved'
   where sv.version_no = 1
     and sv.sector_id in (
       select s.id from public.sectors s
        where s.sector_code in (
          'PAINTS','ALCOBEV','ICE-CREAM','SOLAR-PANEL','SOLAR-CELL',
          'COOLER','TEXTILE','FOOD-SVC','BISCUIT','CHIPS','PETROL',
          'EDIBLE-OIL','FOOTWEAR','ELEC-LED','BEAUTY','CHEMICAL','FANS',
          'PHARMA','FMCG-FOOD'
        )
     );
  get diagnostics v_count = row_count;
  if v_count <> 19 then
    raise exception 'expected to approve 19 Sector versions, approved %', v_count;
  end if;

  select sv.id into strict v_sector_version
    from public.sector_versions sv
    join public.sectors s on s.id = sv.sector_id
   where s.sector_code = 'FMCG-FOOD'
     and sv.version_no = 1
     and sv.status = 'approved';

  insert into public.calculation_default_versions (
    version_no, interest_fallback_pct,
    waste_cbb_fallback_pct, waste_pp_fallback_pct,
    conv_box_fallback_rate, conv_pp_fallback_rate,
    margin_fallback_pct, rounding_step,
    engine_version, rounding_rule_version,
    annual_interest_pct, day_count_basis, fluting_bcf_default,
    created_by
  ) values (
    1, 0.500,
    5.000, 5.000,
    7.0000, 12.5000,
    8.000, 0.0500,
    'engine/qe1-600adcbe1a85be59', 'qe1-rounding-v1',
    6.000, 360, 0.1000,
    v_actor
  ) returning id into v_defaults;

  update public.calculation_default_versions
     set status = 'approved'
   where id = v_defaults;

  insert into public.rate_sets (plant_id, name, created_by)
  values (v_nag, 'Nagpur Limited Beta Rate Set', v_actor)
  returning id into v_rate_set;

  insert into public.rate_set_versions (
    rate_set_id, plant_id, version_no, credit_cost_pct, created_by
  ) values (v_rate_set, v_nag, 1, 1.500, v_actor)
  returning id into v_rate_version;

  insert into public.rate_entries (
    rate_set_version_id, plant_id, grade_code, description,
    price, discount, freight, interest_pct, created_by
  )
  select v_rate_version, v_nag, x.grade_code, x.description,
         x.price, x.discount, x.freight, null, v_actor
    from (values
      ('16', '16 BF Kraft', 31.5000, 1.0000, 0.0000),
      ('18', '18 BF Kraft', 32.0000, 1.0000, 0.0000),
      ('20', '20 BF Kraft', 33.5000, 1.0000, 0.0000),
      ('22', '22 BF Kraft', 35.0000, 1.0000, 0.0000),
      ('24', '24 BF Kraft', 39.0000, 1.0000, 0.0000),
      ('25', '25 BF Kraft', 39.0000, 1.0000, 0.0000),
      ('28', '28 BF Kraft', 44.5000, 1.5000, 0.0000),
      ('35', '35 BF Kraft (calc as 33)', 51.5000, 1.5000, 0.0000),
      ('20GY', '20 BF Golden Yellow', 35.0000, 1.0000, 0.0000),
      ('22GY', '22 BF Golden Yellow', 36.5000, 1.0000, 0.0000),
      ('24GY', '24 BF Golden Yellow (=25VK)', 40.5000, 1.0000, 0.0000),
      ('28GY', '28 BF Golden Yellow', 45.5000, 1.5000, 0.0000),
      ('35GY', '35 BF Golden Yellow (calc 33)', 52.0000, 1.5000, 0.0000),
      ('25WTL', '25 BF White Top Liner', 76.0000, 1.5000, 0.0000),
      ('14DUP', '14 BF Duplex Board', 45.0000, 1.5000, 0.0000),
      ('26HRCT', '26 BF High Recycle Content', 44.5000, 1.5000, 0.0000),
      ('40VKL', '40 BF Imported Virgin Kraft', 68.0000, 1.5000, 0.0000)
    ) as x(grade_code, description, price, discount, freight);

  update public.rate_set_versions
     set status = 'approved'
   where id = v_rate_version;

  insert into public.freight_sets (plant_id, name, created_by)
  values (v_nag, 'Nagpur Limited Beta Freight Set', v_actor)
  returning id into v_freight_set;

  insert into public.freight_set_versions (
    freight_set_id, plant_id, version_no, effective_from, created_by
  ) values (v_freight_set, v_nag, 1, date '2026-09-17', v_actor)
  returning id into v_freight_version;

  insert into public.freight_entries (
    freight_set_version_id, plant_id, origin_plant_id,
    destination_location_id, rate, created_by
  ) values (
    v_freight_version, v_nag, v_nag, v_ship_to, 2.0000, v_actor
  );

  update public.freight_set_versions
     set status = 'approved'
   where id = v_freight_version;

  v_release := public.propose_pricing_basis_release(
    p_plant => v_nag,
    p_effective_from => date '2026-09-17',
    p_rate_set_version_id => v_rate_version,
    p_freight_set_version_id => v_freight_version,
    p_sector_version_id => v_sector_version,
    p_calculation_default_version_id => v_defaults,
    p_effective_until => null,
    p_release_name => 'Nagpur Limited Beta 2026-09-17'
  );
  perform public.approve_pricing_basis_release(v_release, true);

  v_construction := public.propose_construction(
    p_name => 'Beta 3-ply B 16/100', p_ply => 3,
    p_flute_f1 => 'B', p_flute_f2 => null,
    p_layer_top_code => '16', p_layer_f1_code => '16', p_layer_l1_code => '16',
    p_layer_f2_code => null, p_layer_l2_code => null,
    p_layer_top_gsm => 100, p_layer_f1_gsm => 100, p_layer_l1_gsm => 100,
    p_layer_f2_gsm => null, p_layer_l2_gsm => null, p_board_gsm => 337
  );
  select id into strict v_construction_version from public.construction_versions
   where construction_id = v_construction and version_no = 1;
  perform public.approve_construction_version(v_construction_version);
  perform public.publish_construction(v_construction);
  perform public.adopt_construction_for_plant(v_nag, v_construction_version);

  v_construction := public.propose_construction(
    p_name => 'Beta 3-ply C 25/150-16/120-18/150', p_ply => 3,
    p_flute_f1 => 'C', p_flute_f2 => null,
    p_layer_top_code => '25', p_layer_f1_code => '16', p_layer_l1_code => '18',
    p_layer_f2_code => null, p_layer_l2_code => null,
    p_layer_top_gsm => 150, p_layer_f1_gsm => 120, p_layer_l1_gsm => 150,
    p_layer_f2_gsm => null, p_layer_l2_gsm => null, p_board_gsm => 474
  );
  select id into strict v_construction_version from public.construction_versions
   where construction_id = v_construction and version_no = 1;
  perform public.approve_construction_version(v_construction_version);
  perform public.publish_construction(v_construction);
  perform public.adopt_construction_for_plant(v_nag, v_construction_version);

  v_construction := public.propose_construction(
    p_name => 'Beta 3-ply C 16/170', p_ply => 3,
    p_flute_f1 => 'C', p_flute_f2 => null,
    p_layer_top_code => '16', p_layer_f1_code => '16', p_layer_l1_code => '16',
    p_layer_f2_code => null, p_layer_l2_code => null,
    p_layer_top_gsm => 170, p_layer_f1_gsm => 170, p_layer_l1_gsm => 170,
    p_layer_f2_gsm => null, p_layer_l2_gsm => null, p_board_gsm => 586.5
  );
  select id into strict v_construction_version from public.construction_versions
   where construction_id = v_construction and version_no = 1;
  perform public.approve_construction_version(v_construction_version);
  perform public.publish_construction(v_construction);
  perform public.adopt_construction_for_plant(v_nag, v_construction_version);

  v_construction := public.propose_construction(
    p_name => 'Beta 3-ply C 16/120', p_ply => 3,
    p_flute_f1 => 'C', p_flute_f2 => null,
    p_layer_top_code => '16', p_layer_f1_code => '16', p_layer_l1_code => '16',
    p_layer_f2_code => null, p_layer_l2_code => null,
    p_layer_top_gsm => 120, p_layer_f1_gsm => 120, p_layer_l1_gsm => 120,
    p_layer_f2_gsm => null, p_layer_l2_gsm => null, p_board_gsm => 414
  );
  select id into strict v_construction_version from public.construction_versions
   where construction_id = v_construction and version_no = 1;
  perform public.approve_construction_version(v_construction_version);
  perform public.publish_construction(v_construction);
  perform public.adopt_construction_for_plant(v_nag, v_construction_version);

  select count(*)::integer into v_count from public.rate_entries
   where rate_set_version_id = v_rate_version;
  if v_count <> 17 then
    raise exception 'expected 17 Rate entries, found %', v_count;
  end if;

  if not exists (
    select 1 from public.rate_entries
     where rate_set_version_id = v_rate_version
       and grade_code = '25'
       and description = '25 BF Kraft'
       and price = 39.0000
       and discount = 1.0000
       and freight = 0.0000
       and interest_pct is null
       and effective_material_rate = 38.585
  ) then
    raise exception 'exact governed grade 25 did not retain the approved commercial values';
  end if;

  select count(*)::integer into v_count from public.freight_entries
   where freight_set_version_id = v_freight_version;
  if v_count <> 1 then
    raise exception 'expected exactly one governed Freight entry, found %', v_count;
  end if;

  select count(*)::integer into v_count
    from public.plant_construction_adoptions a
    join public.construction_versions cv on cv.id = a.construction_version_id
    join public.constructions c on c.id = cv.construction_id
   where a.plant_id = v_nag and a.status = 'adopted' and c.name like 'Beta %';
  if v_count <> 4 then
    raise exception 'expected four adopted beta Constructions, found %', v_count;
  end if;

  if not exists (
    select 1 from public.pricing_basis_releases
     where id = v_release
       and status = 'approved'
       and is_automatic_default
       and effective_from = date '2026-09-17'
  ) then
    raise exception 'Nagpur beta Pricing Basis Release did not become the approved automatic default';
  end if;

  reset role;
end
$wave_b$;
