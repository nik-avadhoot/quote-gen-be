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
                            "status": "active", "surviving_family_id": None, "content_version": 3}],
    "customer_family_aliases": [{"id": 1, "family_id": 5, "alias": "Acme Corp",
                                  "status": "active", "content_version": 1}],
    "party_family_memberships": [{"id": 1, "party_id": 9, "family_id": 5, "effective_from": "2026-01-01",
                                   "effective_until": None, "is_current": True}],
    "parties": [{"id": 9, "customer_code": "C-009", "display_name": "Acme Ltd",
                 "lifecycle_state": "customer", "status": "active", "content_version": 2}],
}

ROWS = NO_CAP_ROWS  # swapped per-scenario below


def fake_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return FakeClient(token, ROWS)


cc.get_supabase_for_caller = fake_caller

# D1: the six master reads run with bounded parallelism, one INDEPENDENT
# caller-scoped client per worker (see server.list_customer_families and
# caller_context.new_caller_client). Every construction is recorded so the
# tests below can prove the workers did not share one client - sharing is what
# broke under HTTP/2 multiplexing.
WORKER_CLIENTS = []
FAIL_ON_TABLE = None          # set to a table name to make that one read raise


class WorkerReadFailure(RuntimeError):
    pass


class FailingQuery(FakeQuery):
    def execute(self):
        CALLS.append((self.token, self.table))
        if FAIL_ON_TABLE is not None and self.table == FAIL_ON_TABLE:
            raise WorkerReadFailure(f"synthetic failure reading {self.table}")
        return type("R", (), {"data": self.rows})()


class WorkerClient(FakeClient):
    def table(self, name):
        return FailingQuery(self.token, name, self._rows.get(name, []))


def fake_worker_client(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    c = WorkerClient(token, ROWS)
    WORKER_CLIENTS.append(c)
    return c


cc.new_caller_client = fake_worker_client

import server  # noqa: E402
import auth as auth_mod  # noqa: E402
server.get_supabase_for_caller = fake_caller
server.new_caller_client = fake_worker_client
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
check(body["families"][0]["content_version"] == 3 and body["parties"][0]["content_version"] == 2
      and body["aliases"][0]["content_version"] == 1,
      "CF-4f every mutable record's content_version is exposed - the frontend needs it for CAS")
check(body["mutations"] == "governed",
      "CF-4e the response states mutations are governed, now that the U1 mutation routes exist")

# ------------------------------------------------- CF-5 no service-role client
check(all(t != "SERVICE-ROLE" for t, _ in CALLS), "CF-5 no service-role client is used at any point")

# ── D1 bounded parallel reads ────────────────────────────────────────────────
# The six Customer Master reads are independent and now run concurrently. What
# has to stay true: all six actually happen, each worker uses its OWN client,
# a failing worker fails the whole request deterministically, and no partial
# result set can ever be serialised into a 200.

EXPECTED_TABLES = {
    "customer_families", "customer_family_aliases", "party_family_memberships",
    "parties", "customer_locations", "customer_location_versions",
}

ROWS = WITH_CAP_FIXTURE_ROWS
FAIL_ON_TABLE = None
CALLS.clear()
WORKER_CLIENTS.clear()
with app.test_client() as c:
    r = c.get("/masters/customer-families", headers=AUTH)

check(r.status_code == 200, "D1-1 parallel reads still answer 200 for an authorised caller")
read_tables = {t for _, t in CALLS if t in EXPECTED_TABLES}
check(read_tables == EXPECTED_TABLES,
      f"D1-2 all six master reads occur (missing: {sorted(EXPECTED_TABLES - read_tables)})")

body = r.get_json()
check(set(body) >= {"families", "aliases", "memberships", "parties",
                    "locations", "location_versions"},
      "D1-3 the response shape is unchanged - every key still present")
check(body["families"] and body["families"][0]["group_customer_code"] == "F-005",
      "D1-4 the parallel path returns the same rows as the sequential one did")

check(len(WORKER_CLIENTS) == 6,
      f"D1-5 exactly one client is built per read, six in total (got {len(WORKER_CLIENTS)})")
check(len({id(c) for c in WORKER_CLIENTS}) == 6,
      "D1-6 no two workers share a client instance - the HTTP/2 multiplexing hazard")
check(all(c.token == "tok-x" for c in WORKER_CLIENTS),
      "D1-7 every worker client carries the CALLER's own token, so RLS is unchanged")

# A worker failure must propagate, not be swallowed into a partial response.
# TESTING=True re-raises out of the test client, which would prove the exception
# escapes but not what a real client receives; PROPAGATE_EXCEPTIONS off lets
# Flask turn it into the 500 an actual caller would see.
app.config["PROPAGATE_EXCEPTIONS"] = False
for failing in ("parties", "customer_location_versions"):
    FAIL_ON_TABLE = failing
    CALLS.clear()
    WORKER_CLIENTS.clear()
    with app.test_client() as c:
        r = c.get("/masters/customer-families", headers=AUTH)
    check(r.status_code >= 500,
          f"D1-8 a failing '{failing}' read fails the whole request ({r.status_code}), never a partial 200")
    payload = r.get_json(silent=True) or {}
    check("families" not in payload,
          f"D1-9 no partial result set is returned when '{failing}' fails")
    check("synthetic failure" not in r.get_data(as_text=True),
          f"D1-10 the worker's raw failure text does not leak to the client ('{failing}')")

FAIL_ON_TABLE = None
app.config["PROPAGATE_EXCEPTIONS"] = None   # back to Flask's default

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("customer-families route gate PASS")
