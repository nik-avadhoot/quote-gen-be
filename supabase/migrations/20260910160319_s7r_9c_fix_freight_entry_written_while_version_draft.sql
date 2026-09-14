-- S7-R/9c: fix - a Freight Entry may only be written while its version is draft.
--
-- guard_entry_follows_version refuses an insert into freight_entries once the
-- owning freight_set_version is approved. The fixture built the governed-master
-- route in section M, long after the version had been approved, so CP-65 could
-- never be reached.
--
-- The rule is right and the fixture was wrong: a Freight Master is assembled
-- and THEN approved, which is the whole point of an approved commercial basis.
-- The entry now goes in immediately after the version is created and before the
-- Approver approves it - the order a real Freight Set actually follows.
--
-- Two spliced substitutions, removal first so the remaining anchor is unique.
-- No assertion, message or value changes.

do $mig$
declare
  v_def text; v_old text; v_new text; v_cnt int;
  c_entry constant text :=
    E'  insert into public.freight_entries (freight_set_version_id,plant_id,origin_plant_id,destination_location_id,rate,created_by)\n    values (v_fsv, v_kol, v_kol, v_loc, 3.75, v_owner);\n';
begin
  v_def := pg_catalog.pg_get_functiondef('tests.__s7r_body()'::regprocedure);

  -- 1. remove it from section M
  v_cnt := (length(v_def) - length(replace(v_def, c_entry, ''))) / length(c_entry);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 section-M freight_entries insert, found %', v_cnt;
  end if;
  v_def := replace(v_def, c_entry, '');

  -- 2. re-insert it in the fixture, while the version is still draft
  v_old := '  insert into public.freight_set_versions (freight_set_id,plant_id,version_no,created_by) values (v_fs,v_kol,1,v_owner) returning id into v_fsv;';
  v_cnt := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 freight_set_versions anchor, found %', v_cnt;
  end if;
  v_new := v_old || E'\n' || rtrim(c_entry, E'\n');
  v_def := replace(v_def, v_old, v_new);

  execute v_def;
end $mig$;

revoke all on function tests.__s7r_body() from public, anon, authenticated;