"""
S2 route-conversion gate.

Run:  python tests/test_routes_caller_context.py

Hermetic and offline. Supabase is replaced by recording fakes, so this asserts
what the ROUTES do - which client they use, whose token it carries, what they
read and write - without a network call, a real token, or a real identity.

Authorization OUTCOMES are not asserted here. The backend adds none: it passes
the caller's token to PostgREST and the database decides. Those outcomes are
proved against the real policies by tests.run_all() in the database. This file
proves the other half: that the right token gets there, that no ordinary route
reaches for service-role, and that concurrent requests cannot mix.
"""
import os
import sys
import threading

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402
import supabase_client as sc  # noqa: E402

FAILURES, PASSES = [], 0


def check(cond, label):
    global PASSES
    if cond:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


# ---------------------------------------------------------------- fakes
CALLS = threading.local()


def _log(entry):
    if not hasattr(CALLS, "items"):
        CALLS.items = []
    CALLS.items.append(entry)


def _reset():
    CALLS.items = []


class FakeQuery:
    def __init__(self, token, table, rows):
        self.token, self.table, self.rows = token, table, rows
        self.written = None

    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def in_(self, *a, **k): return self
    def limit(self, *a, **k): return self

    def update(self, payload):
        self.written = ("update", payload)
        _log((self.token, self.table, "update", tuple(sorted(payload))))
        return self

    def insert(self, payload):
        self.written = ("insert", payload)
        _log((self.token, self.table, "insert", None))
        return self

    def execute(self):
        _log((self.token, self.table, "select", None))
        return type("R", (), {"data": self.rows})()


class FakeAuthAdmin:
    """The Supabase Auth admin surface. Present so the allow-listed calls succeed."""
    def create_user(self, payload):
        return type("C", (), {"user": type("X", (), {"id": "new-auth-uuid"})()})()

    def delete_user(self, uid):
        return True

    def update_user_by_id(self, uid, payload):
        return True

    def sign_out(self, token, scope):
        return True

    def list_users(self):
        return []


class FakeAuth:
    def __init__(self):
        self.admin = FakeAuthAdmin()

    def get_user(self, tok):
        return type("U", (), {
            "user": type("X", (), {"id": "auth-uuid", "email": "u@x.invalid"})()})()

    def sign_in_with_password(self, payload):
        return type("S", (), {"session": None, "user": None})()


class FakeClient:
    def __init__(self, token, kind, rows_by_table):
        self.token, self.kind, self._rows = token, kind, rows_by_table
        self.auth = FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name, self._rows.get(name, []))

    def rpc(self, name, params):
        _log((self.token, f"rpc:{name}", "call", tuple(sorted(params))))
        return type("R", (), {"execute": lambda s=None: type("D", (), {"data": 1})()})()


ROWS = {
    "app_users": [{"id": 7, "auth_user_id": "auth-uuid",
                   "display_name": "Tester", "status": "active"}],
    # The fixture caller holds administer_users, so the derived role is "admin" and
    # the /admin routes are reachable. Without it the decorator refuses first - which
    # is correct behaviour, but it would stop these tests reaching the route bodies.
    "group_capability_grants": [
        {"app_user_id": 7, "status": "active",
         "capabilities": {"capability_key": "administer_users"}},
    ],
    "plant_capability_grants": [],
    "capabilities": [{"id": 1, "capability_key": "administer_users"},
                     {"id": 2, "capability_key": "make_quote"},
                     {"id": 3, "capability_key": "plant_access"},
                     {"id": 4, "capability_key": "check_quote"}],
    "plants": [{"id": 10, "plant_code": "NAG"}],
}

CALLER_CLIENTS, PRIVILEGED_CALLS = [], []

_real_caller = cc.get_supabase_for_caller
_real_priv = cc.privileged_client


def fake_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    c = FakeClient(token, "caller", ROWS)
    CALLER_CLIENTS.append(c)
    return c


def fake_priv(op):
    if op not in cc.PRIVILEGED_OPERATIONS:
        raise cc.PrivilegeError(op)
    PRIVILEGED_CALLS.append(op)
    return FakeClient("SERVICE-ROLE", "privileged", ROWS)


cc.get_supabase_for_caller = fake_caller
cc.privileged_client = fake_priv
cc.get_supabase_anon = lambda: FakeClient(None, "anon", ROWS)

import server  # noqa: E402
server.get_supabase_for_caller = fake_caller
server.privileged_client = fake_priv
server.get_supabase_anon = cc.get_supabase_anon

import auth as auth_mod  # noqa: E402
auth_mod.get_supabase_for_caller = fake_caller

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-alpha"}


# ------------------------------------------------- R-1 every converted route
_reset(); PRIVILEGED_CALLS.clear()
with app.test_client() as c:
    r = c.patch("/auth/me", json={"display_name": "New Name"}, headers=AUTH)
check(r.status_code == 200, "R-1 /auth/me PATCH succeeds")
check(any(t == "tok-alpha" and tbl == "app_users" and op == "update"
          for t, tbl, op, _ in CALLS.items),
      "R-1a /auth/me writes app_users under the CALLER's token")
check(not any(t == "SERVICE-ROLE" for t, *_ in CALLS.items),
      "R-1b /auth/me uses no service-role client")

_reset()
with app.test_client() as c:
    r = c.patch("/auth/me", json={"plant": "PUN"}, headers=AUTH)
check(r.status_code == 403,
      "R-2 /auth/me refuses self-editing plant (now a capability grant, CDM-05)")

_reset(); PRIVILEGED_CALLS.clear()
with app.test_client() as c:
    r = c.get("/admin/users", headers=AUTH)
check(r.status_code in (200, 403), "R-3 /admin/users GET responds")
check(any(t == "tok-alpha" and tbl == "app_users" for t, tbl, *_ in CALLS.items),
      "R-3a /admin/users reads app_users under the CALLER's token, not service-role")
check(all(op in ("auth_admin_list_users",) for op in PRIVILEGED_CALLS),
      "R-3b the only privileged call is the Auth-admin email lookup")

_reset(); PRIVILEGED_CALLS.clear()
with app.test_client() as c:
    r = c.post("/admin/users", json={"email": "n@x.invalid", "display_name": "N",
                                     "role": "maker", "plant": "NAG"}, headers=AUTH)
check(any(tbl == "rpc:admin_create_app_user" for _, tbl, *_ in CALLS.items),
      "R-4 /admin/users POST creates identity via the capability-checked RPC")
check("auth_admin_create_user" in PRIVILEGED_CALLS,
      "R-4a auth account creation uses the allow-listed Auth-admin call")
check(not any(t == "SERVICE-ROLE" and tbl == "app_users" for t, tbl, *_ in CALLS.items),
      "R-4b no service-role table write to app_users")

_reset(); PRIVILEGED_CALLS.clear()
with app.test_client() as c:
    r = c.patch("/admin/users/7", json={"active": False}, headers=AUTH)
check(r.status_code == 400,
      "R-5 /admin/users PATCH refuses self-deactivation")

_reset(); PRIVILEGED_CALLS.clear()
with app.test_client() as c:
    r = c.patch("/admin/users/8", json={"active": False}, headers=AUTH)
check(any(tbl == "rpc:admin_set_app_user_status" for _, tbl, *_ in CALLS.items),
      "R-6 status change goes through the capability-checked RPC")

_reset(); PRIVILEGED_CALLS.clear()
with app.test_client() as c:
    r = c.post("/admin/users/8/reset-password", json={}, headers=AUTH)
check(any(t == "tok-alpha" and tbl == "app_users" for t, tbl, *_ in CALLS.items),
      "R-7 reset-password resolves the target as the CALLER before acting")

_reset(); PRIVILEGED_CALLS.clear()
with app.test_client() as c:
    r = c.post("/auth/logout", headers=AUTH)
check("auth_admin_sign_out" in PRIVILEGED_CALLS,
      "R-8 logout uses the allow-listed global sign-out")

# ------------------------------------------------- R-9 anonymous / invalid
with app.test_client() as c:
    check(c.get("/admin/users").status_code == 401,
          "R-9 anonymous request refused 401")
    check(c.patch("/auth/me", json={"display_name": "x"},
                  headers={"Authorization": "NotBearer"}).status_code == 401,
          "R-10 malformed Authorization header refused 401")

# inactive / unrecognised identity: resolve_caller returns nothing
_orig_rows = ROWS["app_users"]
ROWS["app_users"] = []
with app.test_client() as c:
    r = c.get("/admin/users", headers=AUTH)
check(r.status_code == 403 and b"not active" in r.data,
      "R-11 inactive/unrecognised identity refused 403 even with a valid token")
check(b"profiles" not in r.data and b"app_users" not in r.data,
      "R-12 the refusal exposes no table or internal identifier")
ROWS["app_users"] = _orig_rows

# ------------------------------------------------- R-13 concurrency
_results = {}
_barrier = threading.Barrier(12)


def worker(i):
    tok = f"tok-{i:02d}"
    with app.test_client() as c:
        _reset()
        _barrier.wait()
        c.patch("/auth/me", json={"display_name": f"U{i}"},
                headers={"Authorization": f"Bearer {tok}"})
        seen = {t for t, *_ in CALLS.items if t}
        _results[i] = seen


threads = [threading.Thread(target=worker, args=(i,)) for i in range(12)]
for t in threads:
    t.start()
for t in threads:
    t.join()

check(len(_results) == 12, "R-13a all 12 concurrent requests completed")
check(all(_results[i] == {f"tok-{i:02d}"} for i in _results),
      "R-13b every concurrent request used ONLY its own token - no cross-request bleed")

# ------------------------------------------------- R-14 no ordinary route can
# reach service-role, structurally
try:
    sc.get_supabase_admin()
    check(False, "R-14 get_supabase_admin must be a closed escape hatch")
except RuntimeError:
    check(True, "R-14 get_supabase_admin() now raises - the escape hatch is closed")

check(set(cc.PRIVILEGED_OPERATIONS) == {
        "auth_admin_create_user", "auth_admin_delete_user", "auth_admin_update_user",
        "auth_admin_sign_out", "auth_admin_list_users"},
      "R-15 allow-list inventory is exactly the five Auth-admin operations")
check(all("Auth admin" in v for v in cc.PRIVILEGED_OPERATIONS.values()),
      "R-16 no allow-listed operation is a table read/write bypass")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  failed: {f}")
    sys.exit(1)
print("route caller-context gate PASS")
