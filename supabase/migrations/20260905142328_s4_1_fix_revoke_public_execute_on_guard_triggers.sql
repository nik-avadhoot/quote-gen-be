-- S4-1 fix: the three Family C guard trigger functions were created with
-- PostgreSQL's default PUBLIC EXECUTE, which `anon` inherits. N-2, G-1 and P-5
-- caught it - that is what those guards exist for.
--
-- A trigger function needs no EXECUTE grant to anyone: the trigger invokes it as
-- the table owner. Revoking is therefore free of consequence and mandatory
-- (§7.1, and the P2-4 / P2-6 precedent for every other function this project owns).

revoke all on function app_private.guard_construction_version_immutable() from public;
revoke all on function app_private.guard_construction_version_immutable() from anon;
revoke all on function app_private.guard_construction_version_immutable() from authenticated;

revoke all on function app_private.guard_construction_permanence() from public;
revoke all on function app_private.guard_construction_permanence() from anon;
revoke all on function app_private.guard_construction_permanence() from authenticated;

revoke all on function app_private.guard_adoption_binding() from public;
revoke all on function app_private.guard_adoption_binding() from anon;
revoke all on function app_private.guard_adoption_binding() from authenticated;