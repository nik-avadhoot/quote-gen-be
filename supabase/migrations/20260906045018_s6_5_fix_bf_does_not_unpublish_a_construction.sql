-- S6-5 fix: BF-17 publishes a Construction to prove that publishing it LATER
-- leaves an open Batch row pinned - the exact case §5.7 says a cascading
-- denormalised status would have broken. The fixture then tried to put the
-- Construction back to 'proposed' and clear its code.
--
-- S4's guard_construction_permanence refused, correctly: a permanent code is
-- never released and published is terminal (CDM-03/CDM-12). Two accepted rules
-- catching a later slice's fixture is the harness working as intended.
--
-- The revert is removed rather than the guard weakened. Nothing after BF-17
-- needs that Construction proposed again, and the cleanup deletes it outright.

do $rw$
declare
  v_def text; v_out text; v_oid oid;
  v_old text := $q$  update public.constructions set status='proposed', construction_code=null where id=v_kprop;$q$;
  v_new text := $q$  -- deliberately NOT reverted: a permanent code is never released and
  -- published is terminal (CDM-03/CDM-12). Nothing below needs it proposed
  -- again, and the cleanup removes it outright.$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='batch_workspace';
  if v_oid is null then raise exception 'tests.batch_workspace() not found' using errcode='55000'; end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def) = 0 then raise exception 'the revert line was not found' using errcode='55000'; end if;

  v_out := replace(v_def, v_old, v_new);
  execute v_out;

  v_def := pg_get_functiondef(v_oid);
  if position('deliberately NOT reverted' in v_def) = 0 then
    raise exception 'the replacement did not take' using errcode='55000';
  end if;
end $rw$;