-- S6-5 fix: BF-13 reassigns a Party to another Family to prove §5.2's whole
-- point - that reassignment leaves existing Batch rows untouched, which is why
-- the rule is a trigger rather than a composite FK. It does that through
-- app_private.reassign_party_family, which requires manage_customer_master.
--
-- The adopted fixture identity held no group capability, so the RPC refused.
-- That refusal is correct. The fixture is granted the capability for the run
-- rather than reaching around the RPC and editing party_family_memberships
-- directly - going around it would prove the trigger tolerates a membership
-- change, but not that the APPROVED reassignment path still works, which is the
-- half CDM-06 actually cares about.

do $rw$
declare
  v_def text; v_out text; v_oid oid;
  v_old1 text := $q$       from public.app_users a where a.id = v_owner), true);$q$;
  v_new1 text := $q$       from public.app_users a where a.id = v_owner), true);

  -- BF-13 exercises the approved reassignment RPC, which requires
  -- manage_customer_master. Granting it to the fixture identity keeps the gate
  -- on the real path instead of reaching around it.
  insert into public.group_capability_grants (app_user_id, capability_id, granted_by)
  select v_owner, c.id, v_owner from public.capabilities c
   where c.capability_key = 'manage_customer_master'
     and not exists (select 1 from public.group_capability_grants g
                      where g.app_user_id = v_owner and g.capability_id = c.id);$q$;
  v_old2 text := $q$  delete from public.customer_families where id in (v_fam, v_fam2);
  -- do not let the adopted session leak into a later suite$q$;
  v_new2 text := $q$  delete from public.customer_families where id in (v_fam, v_fam2);
  delete from public.group_capability_grants g
   using public.capabilities c
   where g.capability_id = c.id and g.app_user_id = v_owner
     and c.capability_key = 'manage_customer_master';
  -- do not let the adopted session leak into a later suite$q$;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='tests' and p.proname='batch_workspace';
  if v_oid is null then raise exception 'tests.batch_workspace() not found' using errcode='55000'; end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old1 in v_def) = 0 then raise exception 'claims block not found' using errcode='55000'; end if;
  if position(v_old2 in v_def) = 0 then raise exception 'cleanup tail not found' using errcode='55000'; end if;

  v_out := replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
  execute v_out;

  v_def := pg_get_functiondef(v_oid);
  if position('keeps the gate' in v_def) = 0
     or position('and c.capability_key = ''manage_customer_master''' in v_def) = 0 then
    raise exception 'one of the two replacements did not take' using errcode='55000';
  end if;
end $rw$;