-- S7-R/9a: fix - the D-G fixture skipped a governed SKU transition.
--
-- guard_sku_permanence enforces CDM-11: a SKU goes proposed -> active ->
-- discontinued, and proposed -> discontinued is refused as an illegal
-- transition. The fixture tried to mint an already-discontinued SKU in one
-- update, which is not a state the model lets exist.
--
-- The fixture is what was wrong, not the rule. It now walks the SKU through
-- 'active' first, which is also the more honest fixture: a discontinued SKU in
-- production is one that WAS active, and D-G is about quoting exactly that.
--
-- Spliced, not retyped, and the substitution count is asserted.

do $mig$
declare
  v_def text; v_old text; v_new text; v_cnt int;
begin
  v_old := 'update public.skus set status=''discontinued'', plant_item_code=''PIC-S7R-2'', replacement_sku_id=v_sku where id=v_sku2;';
  v_new := 'update public.skus set status=''active'', plant_item_code=''PIC-S7R-2'' where id=v_sku2;'
        || E'\n  update public.skus set status=''discontinued'', replacement_sku_id=v_sku where id=v_sku2;';

  v_def := pg_catalog.pg_get_functiondef('tests.__s7r_body()'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 occurrence of the D-G fixture statement, found %', v_cnt;
  end if;
  execute replace(v_def, v_old, v_new);
end $mig$;

revoke all on function tests.__s7r_body() from public, anon, authenticated;