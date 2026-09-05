-- P2-8: make the approved first-sign-in bootstrap reachable by the application.
--
-- ACCEPTANCE DEFECT, found by the Product Owner on the running localhost app,
-- not by any gate here. /auth/login resolves the caller and refuses with 403
-- "Account is not active" when no app_users row exists - but the documented
-- recovery, "claim the pending invitation", had no route into the running
-- system: app_private.bootstrap_app_user() is private, and PostgREST can only
-- route to `public`. A direct anonymous probe confirmed it (PGRST202). So the
-- invited first administrator could authenticate and then be refused forever,
-- and the S3(c) packet's claim that row 1 "recovers by claiming the pending
-- invitation" described a path that did not exist. Both the code and that claim
-- were wrong.
--
-- The fix is the P2-6 shape, unchanged, applied to one more function: routing
-- in `public`, privilege in `app_private`.
--
--   public.bootstrap_app_user()   SECURITY INVOKER, search_path='', no owner
--                                 privilege, reads nothing, decides nothing.
--                                 Exists only so PostgREST has a target.
--   app_private.bootstrap_app_user()  unchanged - still SECURITY DEFINER,
--                                 search_path='', and still the only thing that
--                                 decides anything.
--
-- No new authority is created. The shim runs as the caller, so reaching the
-- implementation still requires USAGE on app_private plus EXECUTE, which
-- `authenticated` already holds. anon holds neither and is refused at the shim.
--
-- The private implementation is deliberately NOT modified. It already binds the
-- invitation to the caller's verified `auth.jwt() ->> 'email'` top-level claim -
-- issued by GoTrue, not user-editable metadata - validates auth.uid(), takes
-- FOR UPDATE on the invitation so a concurrent second caller re-evaluates the
-- `consumed_at is null` predicate and is refused, consumes the invitation once,
-- creates exactly one app_users row (uk_app_users_auth makes a duplicate
-- impossible at the storage layer), grants only administer_users, and seeds the
-- attributed edit_lock_stale_seconds baseline. An already-known identity returns
-- its existing id and takes none of those paths, so a deactivated user cannot
-- re-bootstrap: they get their own id back, and resolve_caller still refuses
-- them for status.

create or replace function public.bootstrap_app_user()
returns bigint language sql set search_path = '' as $fn$
  select app_private.bootstrap_app_user();
$fn$;

revoke all on function public.bootstrap_app_user() from public;
revoke all on function public.bootstrap_app_user() from anon;
grant execute on function public.bootstrap_app_user() to authenticated;