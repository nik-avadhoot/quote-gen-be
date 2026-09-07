"""
U1-C3 Customer Families route gate.

Run:  python tests/test_customer_families_route.py

Hermetic and offline, same fake-client convention as
tests/test_routes_caller_context.py: Supabase is replaced by a recording
fake so this proves what the ROUTE decides - status codes, which client it
uses, whether it reads the caller's resolved capabilities before touching
any table - not authorization outcomes at the RLS layer (proved separately
by the real policies via tests.run_all()).

The defect this closes: the route originally relied on RLS alone, so a
caller without read_party_master got HTTP 200 with four empty arrays -
indistinguishable from an authorized caller looking at a genuinely empty
Family Master. It now checks `g.caller["group_capabilities"]` (already
resolved by `require_auth` via `caller_context.resolve_caller()`, at no
extra query) before running any SELECT, and refuses with 403.
"""
import os
import sys

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402

FAILURES, PASSES = [], 0


def check(cond, label):
    global PASSES
    if cond:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


CALLS = []


class FakeQuery:
    def __init__(self, token, table, rows):
        self.token, self.table, self.rows = token, table, rows

    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def limit(self, *a, **k): return self
    def execute(self):
        CALLS.append((self.token, self.table))
        return type("R", (), {"data": self.rows})()


class FakeAuth:
    def get_user(self, tok):
        return type("U", (), {"user": type("X", (), {"id": "auth-uuid", "email": "u@x.invalid"})()})()


class FakeClient:
    def __init__(self, token, rows_by_table):
        self.token, self._rows = token, rows_by_table
        self.auth = FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name, self._rows.get(name, []))


NO_CAP_ROWS = {
    "app_users": [{"id": 1, "auth_user_id": "auth-uuid", "display_name": "NoCap", "status": "active"}],
    "group_capability_grants": [],
    "plant_capability_grants": [],
    "customer_families": [{"id": 1, "group_customer_code": "F-001", "name": "Should Not Be Seen",
                            "status": "active", "surviving_family_id": None}],
    "customer_family_aliases": [], "party_family_memberships": [], "parties": [],
}

WITH_CAP_EMPTY_ROWS = {
    "app_users": [{"id": 2, "auth_user_id": "auth-uuid", "display_name": "HasCap", "status": "active"}],
    "group_capability_grants": [
        {"app_user_id": 2, "status": "active", "capabilities": {"capability_key": "read_party_master"}},
    ],
    "plant_capability_grants": [],
    "customer_families": [], "customer_family_aliases": [], "party_family_memberships": [], "parties": [],
}

WITH_CAP_FIXTURE_ROWS = {
    "app_users": [{"id": 3, "auth_user_id": "auth-uuid", "display_name": "HasCap2", "status": "active"}],
    "group_capability_grants": [
        {"app_user_id": 3, "status": "active", "capabilities": {"capability_key": "read_party_master"}},
    ],
    "plant_capability_grants": [],
    "customer_families": [{"id": 5, "group_customer_code": "F-005", "name": "Acme",
                            "status": "active", "surviving_family_id": None}],
    "customer_family_aliases": [{"id": 1, "family_id": 5, "alias": "Acme Corp"}],
    "party_family_memberships": [{"id": 1, "party_id": 9, "family_id": 5, "effective_from": "2026-01-01",
                                   "effective_until": None, "is_current": True}],
    "parties": [{"id": 9, "customer_code": "C-009", "display_name": "Acme Ltd",
                 "lifecycle_state": "customer", "status": "active"}],
}

ROWS = NO_CAP_ROWS  # swapped per-scenario below


def fake_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return FakeClient(token, ROWS)


cc.get_supabase_for_caller = fake_caller

import server  # noqa: E402
import auth as auth_mod  # noqa: E402
server.get_supabase_for_caller = fake_caller
auth_mod.get_supabase_for_caller = fake_caller

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-x"}

# --------------------------------------------------------------- CF-1 anon
with app.test_client() as c:
    r = c.get("/masters/customer-families")
check(r.status_code == 401, "CF-1 anonymous request refused 401")

# ----------------------------------------- CF-2 active caller, no capability
ROWS = NO_CAP_ROWS
CALLS.clear()
with app.test_client() as c:
    r = c.get("/masters/customer-families", headers=AUTH)
check(r.status_code == 403, "CF-2 an active caller without read_party_master is refused 403")
check(not any(t == "customer_families" for _, t in CALLS),
      "CF-2a and no table is queried before the capability check refuses")

# --------------------------------------- CF-3 authorized, genuinely empty
ROWS = WITH_CAP_EMPTY_ROWS
with app.test_client() as c:
    r = c.get("/masters/customer-families", headers=AUTH)
check(r.status_code == 200, "CF-3 an authorized caller is not refused")
body = r.get_json()
check(body["families"] == [] and body["aliases"] == [] and body["memberships"] == [] and body["parties"] == [],
      "CF-3a and a genuinely empty master reads as empty arrays, not a 403")

# --------------------------------------------- CF-4 authorized, with fixtures
ROWS = WITH_CAP_FIXTURE_ROWS
with app.test_client() as c:
    r = c.get("/masters/customer-families", headers=AUTH)
body = r.get_json()
check(r.status_code == 200, "CF-4 an authorized caller with data succeeds")
check([f["group_customer_code"] for f in body["families"]] == ["F-005"],
      "CF-4a the expected Family is returned")
check(body["aliases"][0]["alias"] == "Acme Corp", "CF-4b with its alias")
check(body["memberships"][0]["is_current"] is True, "CF-4c its current membership")
check(body["parties"][0]["customer_code"] == "C-009", "CF-4d and the Party it points at")
check(body["mutations"] == "not_yet_governed",
      "CF-4e the response states mutations are not governed - no dead action implied")

# ------------------------------------------------- CF-5 no service-role client
check(all(t != "SERVICE-ROLE" for t, _ in CALLS), "CF-5 no service-role client is used at any point")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("customer-families route gate PASS")
