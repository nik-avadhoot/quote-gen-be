-- S9-P/6a: the invoker shim could not reach its own definer.
--
-- WHAT WENT WRONG. S9-P/6 revoked EXECUTE on
-- app_private.set_batch_pricing_basis from `authenticated`, reasoning that the
-- private function should not be an API surface. But public.set_batch_pricing_basis
-- is a SECURITY INVOKER shim: it executes AS THE CALLER, so the caller needs
-- EXECUTE on the inner definer. With the revoke in place every call failed
-- 42501 "permission denied for function set_batch_pricing_basis" - the shim was
-- reachable and useless.
--
-- THE ESTABLISHED PATTERN, VERIFIED AGAINST ITS NEIGHBOURS. Both
-- app_private.create_batch and app_private.revise_batch_profile grant EXECUTE to
-- `authenticated` and revoke it from `anon` and `public`. The privacy of the
-- private function comes from PostgREST never exposing the app_private schema,
-- not from withholding EXECUTE - and tests.definer_placement's P-5 asserts
-- exactly that boundary: anon can execute none of our functions in any schema.
-- It makes no claim about authenticated on app_private, because the shim model
-- depends on that grant.
--
-- This aligns the new operation with its two nearest neighbours rather than
-- inventing a third convention.

grant execute on function app_private.set_batch_pricing_basis(bigint,integer,date,bigint)
  to authenticated;
revoke all on function app_private.set_batch_pricing_basis(bigint,integer,date,bigint)
  from public, anon;