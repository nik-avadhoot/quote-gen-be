-- A new tests.* function is created with PUBLIC EXECUTE by default, which the
-- access-model gates G-1, G-2 and P-5 exist to catch - and did, on the first
-- full run after S9(a). The suite is proof machinery, never an API surface.
revoke all on function tests.quote_schema() from public, anon, authenticated;
