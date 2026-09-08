-- G-1 / G-2 / P-5 caught these: a newly created function defaults to PUBLIC
-- EXECUTE, and no test function may be executable by anon or authenticated.
-- Same discipline as p2_4_revoke_public_execute_on_test_functions.
revoke all on function tests.user_capability_governance() from public, anon, authenticated, service_role;
revoke all on function tests.__ua3_last_admin_verdicts(bigint, int) from public, anon, authenticated, service_role;
