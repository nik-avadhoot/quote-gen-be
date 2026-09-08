"""
UA-5 - PATCH /admin/users/<id> status branch.

Run:  python tests/test_user_status_route.py

Hermetic and offline, same recording-fake convention as
test_user_capabilities_route.py: this proves what the ROUTE decides - which RPC
it calls, with what parameters, whether it uses the caller's own token, what it
refuses before reaching the database, and how it maps a SQLSTATE to an HTTP
answer.

It does NOT prove the compare-and-set, the advisory lock or the administrator
invariant. Those live in the database and are proved by
tests.user_status_governance() (US-1..US-13), because a fake client cannot
demonstrate a transaction.

The point of this file is the mapping. Before UA-5 the whole branch was a bare
`except Exception: return 400`, so a stale conflict, a capability loss, a
missing user and the last-administrator refusal were one indistinguishable
answer. Every one of them is asserted separately below, each with a Postgres
message SHAPED LIKE A REAL LEAK, and none of that text may reach the body.
"""
import os
import sys

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402
from postgrest.exceptions import APIError  # noqa: E402

FAILURES, PASSES = [], 0


def check(cond, label):
    global PASSES
    if cond:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


RPC_CALLS = []
RPC_RESPONSES = {}
LEAK = ('duplicate key value violates unique constraint "uk_app_users_auth" '
        'DETAIL: Key (auth_user_id)=(11111111-2222-3333-4444-555555555555) exists '
        'CONTEXT: PL/pgSQL function app_private.admin_set_user_status(bigint,integer,text)')


def api_error(code, message=LEAK):
    return APIError({"code": code, "message": message, "hint": None, "details": None})


class FakeQuery:
    """
    Real .eq() filtering, unlike the capability-route fake.

    That fake could ignore filters because one request touched one identity.
    This route touches TWO: require_auth resolves the CALLER by auth uid, and
    every read after it is the TARGET. A fake that ignores .eq() would hand the
    caller's grants back for the target and quietly answer the wrong question.
    """

    def __init__(self, token, table, rows):
        self.token, self.table, self.rows = token, table, list(rows)
        self.filters = []

    def select(self, *a, **k): return self
    def in_(self, *a, **k): return self
    def limit(self, *a, **k): return self

    def eq(self, column, value):
        self.filters.append((column, value))
        return self

    def update(self, values):
        self._update = values
        return self

    def _matching(self):
        rows = self.rows
        for col, val in self.filters:
            rows = [r for r in rows if str(r.get(col)) == str(val)]
        return rows

    def execute(self):
        rows = self._matching()
        if getattr(self, "_update", None):
            rows = [dict(r, **self._update) for r in rows]
        return type("R", (), {"data": rows})()


class FakeRPC:
    def __init__(self, token, name, params):
        self.token, self.name, self.params = token, name, params

    def execute(self):
        RPC_CALLS.append((self.token, self.name, self.params))
        outcome = RPC_RESPONSES.get(self.name)
        if isinstance(outcome, Exception):
            raise outcome
        return type("R", (), {"data": outcome})()


class FakeAuth:
    def get_user(self, tok):
        return type("U", (), {"user": type("X", (), {"id": "auth-uuid", "email": "u@x.invalid"})()})()


class FakeClient:
    def __init__(self, token, rows_by_table):
        self.token, self._rows = token, rows_by_table
        self.auth = FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name, self._rows.get(name, []))

    def rpc(self, name, params):
        return FakeRPC(self.token, name, params)


# 42 is the administrator making every request; 43 is the target. Both live in
# one table, so the route has to filter correctly to see the right one.
ADMIN_CAP = {"app_user_id": 42, "status": "active",
             "capabilities": {"capability_key": "administer_users"}}

BASE = {
    "app_users": [
        {"id": 42, "auth_user_id": "auth-uuid", "display_name": "Admin",
         "status": "active", "content_version": 3},
        {"id": 43, "auth_user_id": "auth-other", "display_name": "Target",
         "status": "deactivated", "content_version": 8},
    ],
    "group_capability_grants": [
        ADMIN_CAP,
        {"app_user_id": 43, "status": "active",
         "capabilities": {"capability_key": "read_party_master"}},
    ],
    "plant_capability_grants": [],
    "plants": [{"id": 10, "plant_code": "NAG", "status": "active"}],
}


def _rows(with_admin_cap=True):
    grants = list(BASE["group_capability_grants"])
    if not with_admin_cap:
        grants = [g for g in grants if g is not ADMIN_CAP]
    return dict(BASE, group_capability_grants=grants)


ROWS = {"current": _rows()}


def fake_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return FakeClient(token, ROWS["current"])


cc.get_supabase_for_caller = fake_caller

import server  # noqa: E402
import auth as auth_mod  # noqa: E402
server.get_supabase_for_caller = fake_caller
auth_mod.get_supabase_for_caller = fake_caller

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-x"}

PATH = "/admin/users/43"
RPC_NAME = "admin_set_app_user_status"

OK_RESULT = {"content_version": 9, "status": "active", "active": True, "changed": True}


def reset(response=None, with_admin_cap=True):
    RPC_CALLS.clear()
    RPC_RESPONSES.clear()
    RPC_RESPONSES[RPC_NAME] = response
    ROWS["current"] = _rows(with_admin_cap)


def patch(body, path=PATH, headers=AUTH):
    with app.test_client() as c:
        return c.patch(path, json=body, headers=headers)


DEACTIVATE = {"active": False, "expected_content_version": 8}

# ───────────────────────────────────────────── authentication and capability
reset(OK_RESULT)
r = patch(DEACTIVATE, headers={})
check(r.status_code == 401, "anonymous request refused 401")
check(not RPC_CALLS, "an anonymous request never reaches the database")

reset(OK_RESULT, with_admin_cap=False)
r = patch(DEACTIVATE)
check(r.status_code == 403,
      f"a caller without administer_users is refused 403 ({r.status_code})")
check(not RPC_CALLS, "a caller without administer_users never reaches the database")

# ─────────────────────────────────── the version is MANDATORY, not optional
reset(OK_RESULT)
r = patch({"active": False})
check(r.status_code == 400 and r.get_json().get("error_code") == "INVALID_INPUT",
      f"a status change without expected_content_version is refused 400 ({r.status_code})")
check(not RPC_CALLS,
      "and never reaches the database - an unversioned status write cannot happen")

for bad in (True, "eight", 8.5, None, {}):
    reset(OK_RESULT)
    r = patch({"active": False, "expected_content_version": bad})
    check(r.status_code == 400 and not RPC_CALLS,
          f"a non-integer expected_content_version ({bad!r}) is refused before the database")

reset(OK_RESULT)
r = patch({"active": False, "expected_content_version": "8"})
check(r.status_code == 200 and RPC_CALLS
      and RPC_CALLS[0][2]["p_expected_content_version"] == 8,
      "a numeric string version is accepted and passed as an integer")

# ───────────────────────────────────────────────────────── the success path
reset(OK_RESULT)
r = patch(DEACTIVATE)
check(r.status_code == 200, f"an authorised, versioned request succeeds ({r.status_code})")
check(len(RPC_CALLS) == 1 and RPC_CALLS[0][1] == RPC_NAME,
      "calls exactly one RPC, the governed status operation")
check(RPC_CALLS[0][0] == "tok-x",
      "the RPC is called with the caller's own token, not a service-role client")
check(RPC_CALLS[0][2] == {"p_app_user": 43, "p_expected_content_version": 8,
                          "p_status": "deactivated"},
      f"deactivation sends exactly the governed parameters ({RPC_CALLS[0][2]})")

reset(OK_RESULT)
r = patch({"active": True, "expected_content_version": 8})
check(RPC_CALLS and RPC_CALLS[0][2]["p_status"] == "active",
      "reactivation sends status 'active' through the same one operation")

body = r.get_json() or {}
check("content_version" in body,
      "the response carries the refreshed content_version, so the client can act again")
check(body.get("status") in ("active", "deactivated") and "active" in body,
      "and the refreshed status, so the row re-renders from the server's answer")
check("group_capabilities" in body and "plant_capabilities" in body,
      "and the capability sets, so the list does not have to guess them")

# ──────────────────────────────────────── refusals decided before the database
reset(OK_RESULT)
r = patch({"active": False, "expected_content_version": 3}, path="/admin/users/42")
check(r.status_code == 422 and r.get_json().get("error_code") == "TRANSITION_NOT_ALLOWED",
      f"deactivating your own account is refused 422 ({r.status_code})")
check("your own account" in (r.get_json().get("error") or ""),
      "and the message says which rule refused it")
check(not RPC_CALLS, "self-deactivation never reaches the database")

reset(OK_RESULT)
r = patch({"active": True, "expected_content_version": 3}, path="/admin/users/42")
check(bool(RPC_CALLS),
      "re-ACTIVATING yourself is not the same rule and is not blocked here")

reset(OK_RESULT)
r = patch(DEACTIVATE, path="/admin/users/not-a-number")
check(r.status_code == 404 and not RPC_CALLS,
      "a non-numeric user id is refused 404 without a database call")

reset(OK_RESULT)
r = patch({})
check(r.status_code == 400 and not RPC_CALLS,
      "a request with no recognised field is refused")

# ─────────────────────────────────────────────── the legacy role path is gone
for legacy in ({"role": "admin"}, {"plant": "NAG"}, {"plants": ["NAG"]}):
    reset(OK_RESULT)
    r = patch(dict(legacy, expected_content_version=8))
    check(r.status_code == 422
          and r.get_json().get("error_code") == "TRANSITION_NOT_ALLOWED",
          f"PATCH still refuses {list(legacy)[0]} - an editable role cannot return")
    check(not any(c[1] == RPC_NAME for c in RPC_CALLS),
          f"and issues no status write for {list(legacy)[0]}")

# ───────────────────────────────────────────────────── SQLSTATE -> HTTP answer
MAPPED = [
    ("PT409", 409, "STALE_VERSION"),
    ("22023", 422, "TRANSITION_NOT_ALLOWED"),
    ("42501", 403, "CAPABILITY_REQUIRED"),
    ("P0002", 404, "RECORD_NOT_FOUND"),
    ("40001", 409, "SERIALIZATION_FAILURE"),
]
for sqlstate, status, code in MAPPED:
    reset(api_error(sqlstate))
    r = patch(DEACTIVATE)
    payload = r.get_json() or {}
    check(r.status_code == status and payload.get("error_code") == code,
          f"{sqlstate} is answered {status} {code} ({r.status_code} "
          f"{payload.get('error_code')})")
    check("uk_app_users_auth" not in str(payload) and "PL/pgSQL" not in str(payload),
          f"and the database's own text never reaches the body for {sqlstate}")

reset(api_error("23514"))
r = patch(DEACTIVATE)
payload = r.get_json() or {}
check(r.status_code == 500 and payload.get("error_code") == "INTERNAL_ERROR",
      f"an unmapped SQLSTATE is a stable 500 INTERNAL_ERROR ({r.status_code})")
check("uk_app_users_auth" not in str(payload),
      "and the unmapped case leaks no database text either")

# ─────────────────────────────────────────────────── display_name is untouched
reset(OK_RESULT)
r = patch({"display_name": "Renamed"})
check(r.status_code == 200,
      "renaming still works and needs no version - it is not the status operation")
check(not any(c[1] == RPC_NAME for c in RPC_CALLS),
      "and renaming issues no status write")

reset(OK_RESULT)
r = patch({"display_name": "   "})
check(r.status_code == 400, "an empty display_name is still refused")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
print("user status route gate " + ("PASS" if not FAILURES else "FAIL"))
sys.exit(0 if not FAILURES else 1)
