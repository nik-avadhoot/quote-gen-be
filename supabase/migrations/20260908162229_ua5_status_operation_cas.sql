-- ═══════════════════════════════════════════════════════════════════════════
-- UA-5 — the status operation gains the concurrency protection it never had.
--
-- THE DEFECT, stated concretely. `app_private.admin_set_user_status(bigint,text)`
-- INCREMENTED `content_version` on every call but never CHECKED it. Two
-- administrators holding the same Users list could therefore both act on the
-- same row and the second write would land silently on top of the first: A
-- deactivates a user, B - still looking at a list that says Active - clicks
-- Deactivate/Activate and reactivates them, with no stale signal anywhere. Every
-- other governed mutation in this codebase compares an expected version and
-- raises PT409; this one did not, so the UA-4 editor's stale handling had no
-- counterpart on the very operation that most needs it.
--
-- The correction is the smallest one consistent with the existing contract:
-- the SAME compare-and-set the capability operation already uses, raising the
-- SAME PT409, mapped by the SAME _RPC_ERROR_MAP entry to the same HTTP 409. No
-- new error code is invented.
--
-- The two-argument forms are DROPPED rather than kept alongside. Leaving them
-- would leave an unprotected path to the same table - exactly the shape UA-3
-- closed on the grant tables - and `authenticated` holds EXECUTE on both, so it
-- would be reachable, not theoretical.
--
-- Behaviour deliberately PRESERVED from the old function: the administer_users
-- check, the self-deactivation refusal, the status whitelist, the advisory lock
-- and the last-active-administrator invariant checked AFTER the write.
--
-- Behaviour deliberately ADDED beyond the CAS: an unchanged status is now a
-- no-op that reports `changed: false` and does NOT bump the version, matching
-- set_user_capabilities. Re-submitting the state a row already has is not a
-- change, and should not invalidate every other administrator's loaded copy.
-- ═══════════════════════════════════════════════════════════════════════════
drop function if exists public.admin_set_app_user_status(bigint, text);
drop function if exists app_private.admin_set_user_status(bigint, text);

create or replace function app_private.admin_set_user_status(
  p_app_user bigint, p_expected_content_version integer, p_status text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v_me bigint; v_version integer; v_prev text; v_changed boolean := false;
begin
  if (select auth.uid()) is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  v_me := app_private.current_app_user();
  if v_me is null then
    raise exception 'no active app user' using errcode = '42501';
  end if;
  if not app_private.has_group_cap('administer_users') then
    raise exception 'administer_users required' using errcode = '42501';
  end if;
  if p_status not in ('invited','active','deactivated') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  if p_app_user = v_me and p_status <> 'active' then
    raise exception 'you cannot deactivate your own account' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('administer_users_invariant'));

  select status, content_version into v_prev, v_version
    from public.app_users where id = p_app_user for update;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;
  if v_version is distinct from p_expected_content_version then
    raise exception 'this user changed since it was loaded' using errcode = 'PT409';
  end if;

  if v_prev is distinct from p_status then
    update public.app_users
       set status          = p_status,
           deactivated_at  = case when p_status = 'deactivated' then now() else null end,
           content_version = content_version + 1
     where id = p_app_user
    returning content_version into v_version;
    v_changed := true;
  end if;

  if not exists (
    select 1
      from public.group_capability_grants g
      join public.capabilities c on c.id = g.capability_id
      join public.app_users    u on u.id = g.app_user_id
     where c.capability_key = 'administer_users'
       and g.status = 'active' and u.status = 'active') then
    raise exception 'at least one active administrator must remain'
      using errcode = '22023';
  end if;

  return jsonb_build_object(
    'content_version', v_version,
    'status',          p_status,
    'active',          p_status = 'active',
    'changed',         v_changed);
end $function$;

create function public.admin_set_app_user_status(
  p_app_user bigint, p_expected_content_version integer, p_status text)
returns jsonb
language sql
set search_path to ''
as $function$
  select app_private.admin_set_user_status(p_app_user, p_expected_content_version, p_status);
$function$;

-- Privileges follow set_user_capabilities exactly: EXECUTE for `authenticated`
-- and nobody else. The dropped public wrapper also carried service_role EXECUTE,
-- which is NOT reproduced - a governed administrative operation resolves the
-- caller through auth.uid(), which is null under service_role, so the grant
-- could only ever have produced a 28000. Nothing calls it that way: every
-- application call goes through get_supabase_for_caller, and privileged_client
-- is used for GoTrue admin work only.
revoke all on function app_private.admin_set_user_status(bigint, integer, text)
  from public, anon, service_role;
grant execute on function app_private.admin_set_user_status(bigint, integer, text)
  to authenticated;

revoke all on function public.admin_set_app_user_status(bigint, integer, text)
  from public, anon, service_role;
grant execute on function public.admin_set_app_user_status(bigint, integer, text)
  to authenticated;
