"""
S2 caller-context gate.

Run:  python tests/test_caller_context.py

Hermetic: sets its own dummy Supabase environment before importing anything, so
it never reads .env, never contacts Supabase, and cannot print a real key or
token. create_client() only constructs - no network call is made.

What this proves, and what it deliberately does not:

  PROVES  the backend hands the caller's own token to PostgREST, that two
          concurrent requests cannot observe each other's token, and that
          service-role access is impossible outside the allow-list.

  DOES NOT prove RLS itself. The backend adds no authorization of its own - it
          passes the token through and the database decides. The authorization
          outcomes (wrong plant, missing capability, inactive user, anonymous)
          are proved against the real policies in tests.run_all(), which sets
          request.jwt.claims and the authenticated role exactly as PostgREST
          does. Splitting it this way keeps each layer's test honest about what
          it actually covers.
"""
import os
import sys
import threading

# Dummy environment BEFORE importing the module under test.
os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402
import supabase_client as sc  # noqa: E402

FAILURES = []
PASSES = 0


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


def _auth_header(client):
    return client.options.headers.get("Authorization")


# --- C-1 caller clients are per-request, never a shared singleton ------------
a = cc.get_supabase_for_caller("token-alpha")
b = cc.get_supabase_for_caller("token-beta")
check(a is not b, "C-1 each call returns a distinct client instance (no singleton)")

# --- C-2 the caller's own token reaches PostgREST ----------------------------
check(_auth_header(a) == "Bearer token-alpha", "C-2a client A carries only token A")
check(_auth_header(b) == "Bearer token-beta", "C-2b client B carries only token B")

# --- C-3 building B does not retroactively change A --------------------------
check(_auth_header(a) == "Bearer token-alpha",
      "C-3 building a second client does not mutate the first")

# --- C-4 concurrent-request token isolation ---------------------------------
# The pre-S2 shape - a cached singleton with the token attached per request -
# fails this: the last writer wins and every in-flight request sees it.
observed = {}
barrier = threading.Barrier(16)


def worker(n):
    token = f"token-{n:02d}"
    barrier.wait()                      # maximise overlap
    client = cc.get_supabase_for_caller(token)
    barrier.wait()                      # all clients built before any is read
    observed[n] = _auth_header(client)


threads = [threading.Thread(target=worker, args=(i,)) for i in range(16)]
for t in threads:
    t.start()
for t in threads:
    t.join()

check(len(observed) == 16, "C-4a all 16 concurrent requests produced a client")
check(all(observed[i] == f"Bearer token-{i:02d}" for i in observed),
      "C-4b every concurrent request kept its OWN token (no cross-request bleed)")
check(len(set(observed.values())) == 16,
      "C-4c 16 distinct tokens observed - none overwritten by another request")

# --- C-5 a caller client cannot be built without a token ---------------------
for bad in (None, "", 12345):
    try:
        cc.get_supabase_for_caller(bad)
        check(False, f"C-5 anonymous/invalid token {bad!r} must be refused")
    except (ValueError, TypeError):
        check(True, f"C-5 anonymous/invalid token {bad!r} refused")

# --- C-6 service-role is unreachable outside the allow-list -----------------
try:
    cc.privileged_client("read_parties")
    check(False, "C-6a non-allow-listed operation must be refused")
except cc.PrivilegeError:
    check(True, "C-6a non-allow-listed operation refused")

try:
    cc.privileged_client("list_users")
    check(False, "C-6b admin user listing must NOT be privileged - it is an RLS policy")
except cc.PrivilegeError:
    check(True, "C-6b admin user listing is not allow-listed (RLS policy instead)")

check(set(cc.PRIVILEGED_OPERATIONS) == {
        "auth_admin_create_user", "auth_admin_delete_user",
        "auth_admin_update_user", "auth_admin_sign_out",
        "auth_admin_list_users"},
      "C-6c allow-list contains exactly the five Auth-admin operations")
check(all(v.strip() for v in cc.PRIVILEGED_OPERATIONS.values()),
      "C-6d every allow-listed operation records why caller context cannot serve it")

# every allow-listed operation is an Auth-admin call, never a table bypass
check(all("Auth admin" in v for v in cc.PRIVILEGED_OPERATIONS.values()),
      "C-6e no allow-listed operation is a table read/write bypass")

# --- C-7 privileged clients are not cached either ----------------------------
p1 = cc.privileged_client("auth_admin_sign_out")
p2 = cc.privileged_client("auth_admin_sign_out")
check(p1 is not p2, "C-7 service-role clients are not cached in module scope")

# --- C-8 the pre-S2 singleton is still a singleton (regression witness) ------
# Documents precisely why caller work must not use it: the object is shared, so
# any per-request mutation of it is a cross-request leak.
check(sc.get_supabase() is sc.get_supabase(),
      "C-8 legacy get_supabase() IS a shared singleton - never attach a caller token to it")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  failed: {f}")
    sys.exit(1)
print("caller-context gate PASS")
