-- `authenticated` holds no USAGE on schema `tests`, so the helper cannot be
-- called while that role is set. The role switch moves INSIDE the helper, around
-- each governed call, which is where it actually needs to be.
--
-- Honest note on the deactivation path: when only one active administrator
-- remains, the only caller holding administer_users IS that administrator, so the
-- pre-existing self-deactivation check (42501) refuses first and the population
-- invariant (22023) never gets the chance to fire. The invariant is a
-- defence-in-depth backstop on this path, and the assertion accepts either
-- refusal rather than pretending it proves which one fired.

create or replace function tests.__ua3_last_admin_verdicts(
  p_admin bigint, p_cv int, out v_cap boolean, out v_deact boolean)
returns record
language plpgsql set search_path to 'extensions', 'pg_catalog' as $function$
begin
  v_cap := false;
  v_deact := false;
  begin
    update public.app_users u
       set status = 'deactivated', deactivated_at = now()
     where u.id <> p_admin and u.status = 'active'
       and exists (select 1 from public.group_capability_grants g
                     join public.capabilities c on c.id = g.capability_id
                    where g.app_user_id = u.id and g.status = 'active'
                      and c.capability_key = 'administer_users');

    begin
      set local role authenticated;
      perform public.set_user_capabilities(p_admin, p_cv, '{}'::text[], '{}'::jsonb);
      reset role;
    exception when others then
      reset role;
      v_cap := (sqlstate = '22023');
    end;

    begin
      set local role authenticated;
      perform public.admin_set_app_user_status(p_admin, 'deactivated');
      reset role;
    exception when others then
      reset role;
      v_deact := (sqlstate in ('22023','42501'));
    end;

    raise exception using errcode = 'UA999', message = '__ua3_rollback';
  exception when others then
    if sqlerrm <> '__ua3_rollback' then raise; end if;
  end;
end $function$;
