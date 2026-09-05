-- P2-14: make an orphaned authentication account DETECTABLE.
--
-- The Product Owner is right, and the previous wording overclaimed. Creating a
-- user spans two systems: Supabase Auth and this database. The DATABASE half is
-- atomic - every plant grant commits or none does (P2-13). The pair is not, and
-- cannot be: there is no distributed transaction across GoTrue and Postgres.
--
-- The route compensates by deleting the Auth account when the database half
-- fails, and that covers the ordinary case. It cannot cover the case where the
-- compensating delete ITSELF fails - a network fault or an Auth outage at
-- exactly that moment. What survives then is an authentication account with no
-- application identity: harmless, because every route resolves through
-- app_users and refuses anything that does not (R-11), but real, and it must be
-- findable rather than argued away.
--
-- Detection needs one fact the backend cannot read for itself: whether an
-- address has an outstanding invitation. `pending_invitations` is private and
-- stays private, so this returns only the SUBSET OF ADDRESSES THE CALLER ALREADY
-- SUPPLIED that have an open invitation. It cannot be used to enumerate
-- invitations, and it tells the caller nothing about an address they did not
-- already hold.

create or replace function app_private.admin_emails_with_open_invitation(p_emails text[])
returns text[] language plpgsql security definer set search_path = '' as $fn$
declare v_me bigint;
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

  return coalesce((
    select array_agg(distinct e)
      from unnest(coalesce(p_emails, '{}')) as e
     where exists (select 1 from app_private.pending_invitations i
                    where lower(i.invite_email) = lower(e)
                      and i.consumed_at is null)
  ), '{}');
end $fn$;

create or replace function public.admin_emails_with_open_invitation(p_emails text[])
returns text[] language sql set search_path = '' as $fn$
  select app_private.admin_emails_with_open_invitation(p_emails);
$fn$;

revoke all on function app_private.admin_emails_with_open_invitation(text[]) from public, anon;
grant execute on function app_private.admin_emails_with_open_invitation(text[]) to authenticated;
revoke all on function public.admin_emails_with_open_invitation(text[]) from public, anon;
grant execute on function public.admin_emails_with_open_invitation(text[]) to authenticated;