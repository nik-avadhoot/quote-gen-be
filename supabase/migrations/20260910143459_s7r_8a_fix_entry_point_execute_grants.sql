-- S7-R/8a: fix - the invoker shims execute AS THE CALLER.
--
-- public.calculate_inputs and public.calculate_batch_row are SECURITY INVOKER,
-- so the caller needs EXECUTE on the app_private implementation they call. With
-- it revoked, an authorised Maker got a bare 42501 'permission denied for
-- function calculate_inputs' before any authority check ran - the same defect
-- corrected at S9-P/6a on set_batch_pricing_basis, reproduced here.
--
-- WHAT THIS DOES NOT WIDEN. app_private is not exposed by PostgREST; only
-- public is. Granting EXECUTE here therefore adds no HTTP surface, and matches
-- exactly what create_batch, revise_batch_profile and set_batch_pricing_basis
-- already do. It is the minimum the approved path requires.
--
-- THE HELPERS STAY REVOKED. Only the two ENTRY POINTS are granted. Every
-- serializer, gatherer, resolver, encoder, attestation function and the key
-- reader remain revoked from public, anon and authenticated, and are reachable
-- only from inside these two.

grant execute on function app_private.calculate_inputs(bigint) to authenticated;
grant execute on function app_private.calculate_batch_row(bigint, integer, text, text) to authenticated;

revoke all on function app_private.calculate_inputs(bigint) from public, anon;
revoke all on function app_private.calculate_batch_row(bigint, integer, text, text) from public, anon;