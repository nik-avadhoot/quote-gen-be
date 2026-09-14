-- S7-R/11: invert CP-80, the S9-P boundary gate the writer was always going to trip.
--
-- CP-80 asserted that S9-P had built NO fingerprint function, and its own
-- message named the reason: "both belong to S7-R with the Calculate writer".
-- S7-R has now built them, so the gate fails - correctly, and by design. This
-- is the same situation as FS-14, and it gets the same treatment.
--
-- INVERTED, NOT DELETED. A deleted gate stops proving anything, and the
-- obligation CP-80 recorded - that these two functions belong to S7-R and to no
-- earlier tranche - is exactly what should stay visible. It now asserts they
-- exist, and the S9-P suite continues to state where they came from.
--
-- CP-81 (no temporary-freight guard trigger), CP-82 (no Send operation) and
-- CP-83 (Family G still empty) are untouched and still true: S7-R built none of
-- those, and S9(b) remains unimplemented and unauthorised.
--
-- Spliced against the live definition, with the occurrence count asserted.

do $mig$
declare
  v_def text; v_old text; v_new text; v_cnt int;
begin
  v_old := E'    0,\n    ''CP-80 S9-P built NO fingerprint function - both belong to S7-R with the Calculate writer'');';
  v_new := E'    2,\n    ''CP-80 S7-R has now built BOTH fingerprint functions - this boundary gate is inverted rather than deleted, so the record that they belong to S7-R and to no earlier tranche stays visible'');';

  v_def := pg_catalog.pg_get_functiondef('tests.__s9p_body()'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_cnt <> 1 then
    raise exception 'expected exactly 1 CP-80 assertion, found %', v_cnt;
  end if;
  execute replace(v_def, v_old, v_new);
end $mig$;

revoke all on function tests.__s9p_body() from public, anon, authenticated;