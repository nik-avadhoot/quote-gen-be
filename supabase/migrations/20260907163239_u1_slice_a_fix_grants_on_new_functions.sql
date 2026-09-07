-- Fix: two new functions this slice created (app_private.update_party,
-- tests.party_edit_mutations) never had their ACL materialised - proacl was
-- NULL (implicit default: PUBLIC has EXECUTE), unlike every sibling function
-- in these schemas, which is why N-2/G-1/G-2/P-5 started failing. Every other
-- app_private/tests function got its ACL explicitly set at some earlier
-- blanket grant that only covered functions existing at the time it ran -
-- a new function created afterward needs the same explicit treatment,
-- individually, same lesson as U1-CF-C1 (a missed explicit revoke, not
-- inherited protection).

revoke all on function app_private.update_party(bigint, integer, text) from public, anon, service_role;
grant execute on function app_private.update_party(bigint, integer, text) to authenticated;

revoke all on function tests.party_edit_mutations() from public, anon, authenticated, service_role;
