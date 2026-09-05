-- P2-7: close anon's reach into the legacy `public.profiles` table.
--
-- Found by a direct anonymous REST probe, not by any existing guard. Every
-- Family A and Family B table refuses anon with 42501 because anon holds no
-- privilege on them. `profiles` is the sole exception: it still carries the
-- Supabase default grant of ALL to anon, authenticated and service_role, so an
-- anonymous request to /rest/v1/profiles returns 200 with an empty array rather
-- than being refused. RLS holds - all three policies are scoped to
-- `authenticated`, so zero rows are readable, writable or deletable by anon -
-- but "accepted and filtered" is not the same posture as "refused", and the
-- existing N-7 guard only enumerated the Family A tables, so nothing caught it.
--
-- The one privilege RLS cannot govern is TRUNCATE: it is not row-filtered, so a
-- role holding it empties the table regardless of policy. anon and authenticated
-- both hold it here. It is not reachable through PostgREST, which has no TRUNCATE
-- verb, and the anon role has no direct login - so this is an inert grant, in the
-- same class as the S0b rls_auto_enable finding and the P2-6 set_updated_at one.
-- It is revoked on the same reasoning: an inert grant on a live table stops being
-- inert after an unrelated change, and revoking costs nothing.
--
-- What is deliberately NOT changed:
--   * The table, its three policies and its updated_at trigger all remain. This
--     is a grant correction, not the S3(c) removal, which stays blocked.
--   * `authenticated` keeps SELECT and UPDATE, the two privileges the existing
--     policies actually gate. INSERT and DELETE are revoked because no policy
--     grants either - so no reachable behaviour changes, only the error code.
--   * `service_role` is left as-is. It is obtainable only with the secret key,
--     the general admin-client escape hatch is already disabled, and none of the
--     five allow-listed Auth-admin operations touches a table.

revoke all on public.profiles from anon;

revoke insert, delete, truncate, references, trigger
    on public.profiles from authenticated;