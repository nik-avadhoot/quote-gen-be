-- S6-5 fix: the Batch workspace fixture had no active app user, so
-- ref_private.allocate_reference refused to mint a Batch reference.
--
-- That refusal is correct and stays. A permanent business reference must be
-- attributable (CDM-34), and the allocator has enforced "no active app user" as
-- an error since P2-4. The fixture was the thing in the wrong: it created
-- Batches as the table owner, which has no application identity at all.
--
-- The fix adopts the minted fixture owner - already a real, active identity -
-- for the duration of the suite, rather than relaxing the allocator or handing
-- the fixture a privileged bypass. Claims are cleared again at the end so the
-- adopted session cannot leak into a later suite in the same transaction.

do $rw$
declare
  v_def text; v_out text; v_oid oid;
  v_old1 text := $q$  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';$q$;
  v_new1 text := $q$  v_owner := tests.__fixture_owner();
  select id into v_nag from public.plants where plant_code = 'NAG';
  select id into v_pun from public.plants where plant_code = 'PUN';

  -- The permanent-reference allocator refuses to run without an active app user,
  -- and rightly so: a reference must be attributable (CDM-34). The fixture owner
  -- is a real active identity, so the suite adopts it rather than weakening the
  -- allocator or granting the fixture a bypass.
  perform pg_catalog.set_config('request.jwt.claims',
    (select format('{"sub":"%s","role":"authenticated"}', a.auth_user_id)
       from public.app_users a where a.id = v_owner), true);$q$;
  v_old2 text := $q$  delete from public.customer_families where id in (v_fam, v_fam2);
end$q$;
  v_new2 text := $q$  delete from public.customer_families where id in (v_fam, v_fam2);
  -- do not let the adopted session leak into a later suite
  perform pg_catalog.set_config('request.jwt.claims', null, true);
end$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='batch_workspace';
  if v_oid is null then raise exception 'tests.batch_workspace() not found' using errcode='55000'; end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old1 in v_def) = 0 then raise exception 'fixture header not found' using errcode='55000'; end if;
  if position(v_old2 in v_def) = 0 then raise exception 'cleanup tail not found'  using errcode='55000'; end if;

  v_out := replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
  execute v_out;

  v_def := pg_get_functiondef(v_oid);
  if position('adopts it rather than weakening' in v_def) = 0
     or position('do not let the adopted session leak' in v_def) = 0 then
    raise exception 'one of the two replacements did not take' using errcode='55000';
  end if;
end $rw$;