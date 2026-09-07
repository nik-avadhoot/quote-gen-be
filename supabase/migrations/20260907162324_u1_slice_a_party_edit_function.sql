-- U1 Slice A - Party editing (display_name only).
--
-- Authorised by docs/u1-customer-foundation-authorization-packet.md (quote-gen-fe),
-- Slice A, as narrowed by the second review round. Mirrors
-- app_private.update_customer_family exactly: same CAS technique, same
-- capability, same "permitted fields" framing (display_name only -
-- customer_code, lifecycle_state, origin_family_id/status are not editable
-- through this function).
--
-- CAS. p_expected_content_version is required, no default - no caller can
-- construct a call that skips the check.

create or replace function app_private.update_party(
  p_party bigint, p_expected_content_version integer, p_display_name text)
returns void
language plpgsql security definer set search_path to '' as $fn$
declare v_n int;
begin
  if not app_private.has_group_cap('manage_customer_master') then
    raise exception 'manage_customer_master required' using errcode = '42501';
  end if;
  if p_expected_content_version is null then
    raise exception 'the Party content version you read must be supplied' using errcode = '22023';
  end if;
  if p_display_name is null or btrim(p_display_name) = '' then
    raise exception 'a display name is required' using errcode = '22023';
  end if;

  update public.parties
     set display_name = btrim(p_display_name), content_version = content_version + 1
   where id = p_party and content_version = p_expected_content_version;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    perform 1 from public.parties where id = p_party;
    if not found then
      raise exception 'party not found' using errcode = 'P0002';
    end if;
    raise exception 'the Party changed since you read it (expected content version %) - re-read and retry',
      p_expected_content_version using errcode = '40001';
  end if;
end $fn$;

-- ═══════════════════════ public invoker wrapper ═════════════════════════════
create or replace function public.update_customer_party(
  p_party bigint, p_expected_content_version integer, p_display_name text)
returns void language sql security invoker set search_path = '' as $fn$
  select app_private.update_party(p_party, p_expected_content_version, p_display_name);
$fn$;

-- ═══════════════════════ grant / revoke posture ═════════════════════════════
-- Explicit service_role revoke from the FIRST migration (U1-CF-C1 lesson -
-- not discovered after the fact this time).
do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'update_customer_party'
  loop
    execute format('revoke all on function %I.%I(%s) from public',        r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from anon',          r.nspname, r.proname, r.args);
    execute format('revoke all on function %I.%I(%s) from service_role',  r.nspname, r.proname, r.args);
    execute format('grant execute on function %I.%I(%s) to authenticated', r.nspname, r.proname, r.args);
  end loop;
end $$;
