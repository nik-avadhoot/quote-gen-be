-- The public wrapper is SECURITY INVOKER, so it executes as `authenticated`
-- and therefore needs EXECUTE on the app_private function it delegates to.
-- The previous migration revoked that, and the wrapper failed with
-- "permission denied for function" - which surfaces as SQLSTATE 42501 and
-- would have been reported as CAPABILITY_REQUIRED, a plausible but wrong
-- reason. Same grant shape as create_minimal_prospect and
-- propose_customer_location, verified from pg_proc.proacl rather than assumed.
--
-- Safe because app_private is not exposed through PostgREST (only `public` is)
-- and the function performs its own administer_users check before any write.
grant execute on function app_private.set_user_capabilities(bigint, integer, text[], jsonb)
  to authenticated;

-- service_role must NOT hold it: the U1-CF-C1/C2 discipline is an explicit
-- revoke, not a default.
revoke all on function app_private.set_user_capabilities(bigint, integer, text[], jsonb)
  from anon, service_role;
revoke all on function public.set_user_capabilities(bigint, integer, text[], jsonb)
  from anon, service_role;
