"""
Users/Access route authority - the capability decides, never the role label.

Run:  python tests/test_admin_route_authority.py

WHY THIS FILE EXISTS. Every administration route used to be gated by
`require_role("admin")`. That was never wrong in EFFECT - derive_role computes
`admin` from `administer_users`, so the two coincide today - but it made a
PRESENTATION LABEL the thing a route consults. Two consequences follow, and
neither is hypothetical:

  * a change to derive_role silently regates every route wearing that
    decorator, with no test anywhere noticing; and
  * the label is deliberately lossy - it cannot express nine of the thirteen
    capabilities - so it can never be the authority for anything finer.

So the property under test is not "an administrator can reach these routes". It
is that the LABEL IS IRRELEVANT IN BOTH DIRECTIONS:

  * a caller holding administer_users is admitted while its role reads "maker";
  * a caller whose role reads "admin" is refused when the grant is absent.

Only a resolved caller can express those two states, because in production
derive_role makes them impossible to separate - which is exactly why the gate
must not read the derived field. resolve_caller is therefore stubbed here to
hand back the two callers directly; that is the point of the test, not a
shortcut around it.

The database independently enforces administer_users on every one of these
paths - app_private.admin_create_app_user, admin_prepare_email_change,
admin_set_user_status and set_user_capabilities each raise 42501 without it, and
the app_users SELECT policy exposes other users' rows only to a holder. Read
from pg_proc and pg_policies, not assumed. This file proves the ROUTE agrees
with that; it does not replace it.
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


REACHED = []          # routes whose body actually ran
PRIVILEGED = []       # allow-listed Auth-admin operations attempted


class FakeQuery:
    def __init__(self, table, rows):
        self.table, self.rows, self.filters = table, list(rows), []

    def select(self, *a, **k): return self
    def in_(self, *a, **k): return self
    def limit(self, *a, **k): return self
    def update(self, values):
        self._update = values
        return self

    def eq(self, column, value):
        self.filters.append((column, value))
        return self

    def execute(self):
        rows = self.rows
        for col, val in self.filters:
            rows = [r for r in rows if str(r.get(col)) == str(val)]
        return type("R", (), {"data": rows})()


class FakeRPC:
    def __init__(self, name, params):
        self.name, self.params = name, params

    def execute(self):
        REACHED.append("rpc:" + self.name)
        return type("R", (), {"data": RPC_RESULTS.get(self.name)})()


class FakeAuth:
    def get_user(self, tok):
        return type("U", (), {"user": type("X", (), {"id": "auth-uuid",
                                                     "email": "u@x.invalid"})()})()


class AuthAdmin:
    def list_users(self):
        PRIVILEGED.append("list_users")
        return []

    def update_user_by_id(self, uid, attrs):
        PRIVILEGED.append("update_user_by_id")
        return type("R", (), {"user": None})()

    def create_user(self, attrs):
        PRIVILEGED.append("create_user")
        return type("R", (), {"user": type("X", (), {"id": "new-uuid"})()})()

    def delete_user(self, uid):
        PRIVILEGED.append("delete_user")


class FakeClient:
    def __init__(self, token=None):
        self.token = token
        self.auth = FakeAuth()
        self.auth.admin = AuthAdmin()

    def table(self, name):
        return FakeQuery(name, ROWS.get(name, []))

    def rpc(self, name, params):
        return FakeRPC(name, params)


ROWS = {
    "app_users": [
        {"id": 42, "auth_user_id": "auth-uuid", "display_name": "Caller",
         "status": "active", "content_version": 3},
        {"id": 43, "auth_user_id": "auth-other", "display_name": "Target",
         "status": "active", "content_version": 8},
    ],
    "group_capability_grants": [],
    "plant_capability_grants": [],
    "plants": [{"id": 10, "plant_code": "NAG", "status": "active"}],
}
RPC_RESULTS = {
    "admin_create_app_user": 99,
    "admin_prepare_email_change": {"ok": True},
    "admin_set_app_user_status": {"content_version": 9, "status": "active",
                                  "active": True, "changed": True},
    "set_user_capabilities": {"content_version": 4, "changed": True,
                              "group_capabilities": [], "plant_capabilities": {}},
    "admin_emails_with_open_invitation": [],
}

cc.get_supabase_for_caller = lambda token: FakeClient(token)

import server  # noqa: E402
import auth as auth_mod  # noqa: E402

server.get_supabase_for_caller = lambda token: FakeClient(token)
auth_mod.get_supabase_for_caller = lambda token: FakeClient(token)
server.privileged_client = lambda op: FakeClient()

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-x"}


# ── the two callers the derived label can never separate in production ──────
#
# CAPABLE reads as a MAKER and holds administer_users.
# LABELLED reads as an ADMIN and holds nothing.
CAPABLE = {"id": 42, "auth_user_id": "auth-uuid", "display_name": "Caller",
           "status": "active", "role": "maker",
           "group_capabilities": ["administer_users"], "plant_capabilities": {}}
LABELLED = {"id": 42, "auth_user_id": "auth-uuid", "display_name": "Caller",
            "status": "active", "role": "admin",
            "group_capabilities": [], "plant_capabilities": {}}

CURRENT = {"caller": CAPABLE}
auth_mod.resolve_caller = lambda token, known_auth_uid=None: CURRENT["caller"]


def as_caller(caller):
    CURRENT["caller"] = caller
    REACHED.clear()
    PRIVILEGED.clear()


# Every Users/Access administration route, with a body that is valid enough to
# reach its own logic once the gate has admitted it.
ROUTES = [
    ("GET",   "/admin/users",                     None,
     "the Users list"),
    ("POST",  "/admin/users",                     {"email": "n@x.invalid",
                                                   "display_name": "N",
                                                   "role": "maker",
                                                   "plants": ["NAG"]},
     "user creation"),
    ("PATCH", "/admin/users/43",                  {"active": False,
                                                   "expected_content_version": 8},
     "the status change"),
    ("POST",  "/admin/users/43/capabilities",     {"expected_content_version": 8,
                                                   "group_capabilities": [],
                                                   "plant_capabilities": {}},
     "the capability editor"),
    ("PATCH", "/admin/users/43/email",            {"new_email": "moved@x.invalid",
                                                   "reason": "administrative"},
     "the administrator email change"),
    ("POST",  "/admin/users/43/reset-password",   {},
     "the temporary-password reset"),
    ("GET",   "/admin/auth-orphans",              None,
     "the orphan report"),
    ("POST",  "/admin/users/adopt",               {"email": "orphan@x.invalid",
                                                   "display_name": "R",
                                                   "role": "maker",
                                                   "plants": ["NAG"]},
     "orphan adoption"),
]


def call(method, path, body):
    with app.test_client() as c:
        fn = getattr(c, method.lower())
        return fn(path, json=body, headers=AUTH) if body is not None \
            else fn(path, headers=AUTH)


# ── 1. the capability admits, while the label says "maker" ─────────────────
for method, path, body, name in ROUTES:
    as_caller(CAPABLE)
    r = call(method, path, body)
    check(r.status_code != 403,
          f"{name}: a holder of administer_users is admitted although its derived "
          f"role reads 'maker' ({method} {path} -> {r.status_code})")

# ── 2. the label alone does NOT admit ──────────────────────────────────────
for method, path, body, name in ROUTES:
    as_caller(LABELLED)
    r = call(method, path, body)
    check(r.status_code == 403,
          f"{name}: a caller whose derived role reads 'admin' is REFUSED without "
          f"the grant ({method} {path} -> {r.status_code})")
    check(not REACHED,
          f"{name}: and the refused request reaches no database operation")
    check(not PRIVILEGED,
          f"{name}: and attempts no Auth-admin operation either")

# ── 3. no route is left reading the derived label ─────────────────────────
import inspect  # noqa: E402

source = inspect.getsource(server)
# The bare name still appears in two comments explaining WHY it is not used;
# what must be absent is the decorator itself.
check("@require_role" not in source,
      "server.py applies the require_role decorator nowhere")
check(source.count('@require_group_capability("administer_users")') == 8,
      "all eight Users/Access administration routes gate on the capability "
      f"(found {source.count(chr(64) + 'require_group_capability(' + chr(34) + 'administer_users' + chr(34) + ')')})")
check('from auth import require_auth, require_group_capability\n' in source,
      "and the role shim is no longer even imported")

# The shim itself survives for out-of-tree importers, but must have no caller.
check("require_role" in inspect.getsource(auth_mod),
      "auth.require_role still exists, so an out-of-tree import does not break")
check("NO CALLERS" in inspect.getsource(auth_mod.require_role),
      "and is documented as having no callers, so one is not added back by habit")

# ── 4. the label is still REPORTED - this changed authority, not presentation
as_caller(CAPABLE)
r = call("GET", "/admin/users", None)
check(r.status_code == 200, "the Users list still answers 200 for a real holder")
users = (r.get_json() or {}).get("users", [])
check(all("role" in u for u in users) or not users,
      "every listed user still carries its derived role for display")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
print("admin route authority gate " + ("PASS" if not FAILURES else "FAIL"))
sys.exit(0 if not FAILURES else 1)
