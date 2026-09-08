"""
UA-3 - POST /admin/users/<id>/capabilities route gate.

Run:  python tests/test_user_capabilities_route.py

Hermetic and offline, same recording-fake convention as
test_party_edit_route.py: this proves what the ROUTE decides - which RPC it
calls, with what parameters, whether it uses the caller's own token, how it
translates plant codes to immutable ids, what it refuses before reaching the
database, and how it maps a SQLSTATE to an HTTP answer.

It does NOT prove atomicity, locking, CAS or the administrator invariant. Those
live in the database and are proved by tests.user_capability_governance()
(UC-1..UC-20), because a fake client cannot demonstrate a transaction.

Error-mapping discipline, unchanged from U1-CF-C2: every mapped code is
exercised with a Postgres message SHAPED LIKE A REAL LEAK, and none of that text
may reach the response body.
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


def api_error(code, message="synthetic test error"):
    return APIError({"code": code, "message": message, "hint": None, "details": None})


class FakeQuery:
    def __init__(self, token, table, rows):
        self.token, self.table, self.rows = token, table, rows

    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def in_(self, *a, **k): return self
    def limit(self, *a, **k): return self

    def execute(self):
        return type("R", (), {"data": self.rows})()


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


# NAG and PUN are active; OLD is deactivated and must never become a grant.
ADMIN_ROWS = {
    "app_users": [{"id": 42, "auth_user_id": "auth-uuid", "display_name": "Admin",
                   "status": "active", "content_version": 3}],
    "group_capability_grants": [
        {"app_user_id": 42, "status": "active",
         "capabilities": {"capability_key": "administer_users"}},
    ],
    "plant_capability_grants": [],
    "plants": [{"id": 10, "plant_code": "NAG", "status": "active"},
               {"id": 11, "plant_code": "PUN", "status": "active"},
               {"id": 12, "plant_code": "OLD", "status": "inactive"}],
}
NOCAP_ROWS = dict(ADMIN_ROWS, group_capability_grants=[])

ROWS = {"current": ADMIN_ROWS}


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

PATH = "/admin/users/42/capabilities"
RPC_NAME = "set_user_capabilities"

OK_RESULT = {"content_version": 4, "changed": True,
             "group_capabilities": ["read_party_master"],
             "plant_capabilities": {"10": ["make_quote", "plant_access"]}}


def reset(response=None, rows=None):
    RPC_CALLS.clear()
    RPC_RESPONSES.clear()
    RPC_RESPONSES[RPC_NAME] = response
    ROWS["current"] = rows or ADMIN_ROWS


def post(body, headers=AUTH):
    with app.test_client() as c:
        return c.post(PATH, json=body, headers=headers)


GOOD = {"expected_content_version": 3,
        "group_capabilities": ["read_party_master"],
        "plant_capabilities": {"NAG": ["plant_access", "make_quote"]}}

# ───────────────────────────────────────────── authentication and capability
reset(OK_RESULT)
r = post(GOOD, headers={})
check(r.status_code == 401, "anonymous request refused 401")
check(not RPC_CALLS, "an anonymous request never reaches the database")

reset(OK_RESULT, rows=NOCAP_ROWS)
r = post(GOOD)
check(r.status_code == 403,
      f"a caller without administer_users is refused 403 ({r.status_code})")
check(not RPC_CALLS, "a caller without administer_users never reaches the database")

# ─────────────────────────────────────────────────────── the success path
reset(OK_RESULT)
r = post(GOOD)
check(r.status_code == 200, f"an authorised, well-formed request succeeds ({r.status_code})")
check(len(RPC_CALLS) == 1 and RPC_CALLS[0][1] == RPC_NAME,
      "calls exactly one RPC, the governed capability operation")
check(RPC_CALLS[0][0] == "tok-x",
      "the RPC is called with the caller's own token, not a service-role client")
check(RPC_CALLS[0][2] == {
        "p_app_user": 42,
        "p_expected_content_version": 3,
        "p_group_caps": ["read_party_master"],
        "p_plant_caps": {"10": ["plant_access", "make_quote"]}},
      "plant CODES are translated to immutable plant IDS for the database contract")

body = r.get_json()
check(body.get("content_version") == 4, "the resulting content_version is returned")
check(body.get("changed") is True, "the changed flag is returned")
check(body.get("plant_capabilities") == {"NAG": ["make_quote", "plant_access"]},
      "plant ids are translated BACK to codes on the way out")

# ───────────────────────────────────────────── request-shape refusals (400)
for label, payload in [
    ("expected_content_version is required",
     {"group_capabilities": [], "plant_capabilities": {}}),
    ("group_capabilities must be a list",
     {"expected_content_version": 3, "group_capabilities": "read_party_master",
      "plant_capabilities": {}}),
    ("group_capabilities must contain only strings",
     {"expected_content_version": 3, "group_capabilities": [1],
      "plant_capabilities": {}}),
    ("plant_capabilities must be an object",
     {"expected_content_version": 3, "group_capabilities": [],
      "plant_capabilities": ["NAG"]}),
    ("each plant value must be a list of keys",
     {"expected_content_version": 3, "group_capabilities": [],
      "plant_capabilities": {"NAG": "make_quote"}}),
]:
    reset(OK_RESULT)
    r = post(payload)
    check(r.status_code == 400 and r.get_json().get("error_code") == "INVALID_INPUT",
          f"400 INVALID_INPUT: {label}")
    check(not RPC_CALLS, f"and it never reaches the database: {label}")

# A missing collection is refused rather than guessed: this is a COMPLETE
# replacement, and null is ambiguous between "clear" and "leave alone".
reset(OK_RESULT)
r = post({"expected_content_version": 3, "plant_capabilities": {}})
check(r.status_code == 400, "a missing group_capabilities collection is refused, not defaulted")
reset(OK_RESULT)
r = post({"expected_content_version": 3, "group_capabilities": []})
check(r.status_code == 400, "a missing plant_capabilities collection is refused, not defaulted")

# Case-differing duplicate codes are refused rather than silently folded.
reset(OK_RESULT)
r = post({"expected_content_version": 3, "group_capabilities": [],
          "plant_capabilities": {"NAG": ["plant_access"], "nag": ["plant_access"]}})
check(r.status_code == 400 and r.get_json().get("error_code") == "INVALID_INPUT",
      "duplicate plant codes differing only by case are refused, not folded")
check(not RPC_CALLS, "and never reach the database")

# ──────────────────────────────────────────────── plant resolution refusals
reset(OK_RESULT)
r = post({"expected_content_version": 3, "group_capabilities": [],
          "plant_capabilities": {"OLD": ["plant_access"]}})
check(r.status_code == 422 and r.get_json().get("error_code") == "TRANSITION_NOT_ALLOWED",
      "an INACTIVE plant code is refused 422 before the database is reached")
check(not RPC_CALLS, "an inactive plant never becomes an RPC parameter")

reset(OK_RESULT)
r = post({"expected_content_version": 3, "group_capabilities": [],
          "plant_capabilities": {"ZZZ": ["plant_access"]}})
check(r.status_code == 422, "an unknown plant code is refused 422")

reset(OK_RESULT)
r = post(dict(GOOD), headers=AUTH)
check(RPC_CALLS[0][2]["p_plant_caps"] == {"10": ["plant_access", "make_quote"]},
      "only ACTIVE plants are resolvable, and the id is the immutable one")

# ─────────────────────────────────────────── a bad user id is 404, not 500
reset(OK_RESULT)
with app.test_client() as c:
    r = c.post("/admin/users/not-a-number/capabilities", json=GOOD, headers=AUTH)
check(r.status_code == 404 and r.get_json().get("error_code") == "RECORD_NOT_FOUND",
      "a non-numeric user id is 404 RECORD_NOT_FOUND, not a crash")

# ───────────────────────────────────── SQLSTATE mapping, and no leaked text
LEAK = ("permission denied for table public.group_capability_grants in function "
        "app_private.set_user_capabilities line 42 SQLSTATE 42501")
for code, status, error_code in [
    ("42501", 403, "CAPABILITY_REQUIRED"),
    ("P0002", 404, "RECORD_NOT_FOUND"),
    ("PT409", 409, "STALE_VERSION"),
    ("22023", 422, "TRANSITION_NOT_ALLOWED"),
    ("40001", 409, "SERIALIZATION_FAILURE"),
]:
    reset(api_error(code, LEAK))
    r = post(GOOD)
    payload = r.get_json() or {}
    check(r.status_code == status and payload.get("error_code") == error_code,
          f"SQLSTATE {code} -> {status} {error_code} (got {r.status_code} "
          f"{payload.get('error_code')})")
    blob = str(payload)
    check("group_capability_grants" not in blob and "app_private" not in blob
          and "SQLSTATE" not in blob and code not in blob.replace(error_code, ""),
          f"SQLSTATE {code}: no database text, schema, table or code leaks into the body")

# A stale conflict is answered ONCE. The route must not retry it: retrying an
# unchanged desired set can only fail again, which is why the operation raises
# PT409 rather than 40001 (see migration 20260908052900).
reset(api_error("PT409", LEAK))
r = post(GOOD)
check(len(RPC_CALLS) == 1,
      "a stale conflict is answered after exactly one call - no retry storm")

# An unmapped SQLSTATE must be a stable 500, never a raw database message.
reset(api_error("23514", LEAK))
r = post(GOOD)
payload = r.get_json() or {}
check(r.status_code == 500 and payload.get("error_code") == "INTERNAL_ERROR",
      f"an unmapped SQLSTATE is a stable 500 INTERNAL_ERROR ({r.status_code})")
check("group_capability_grants" not in str(payload),
      "and the unmapped case leaks no database text either")

# ───────────────────────────────────── the legacy mutation path is gone
reset(OK_RESULT)
with app.test_client() as c:
    r = c.patch("/admin/users/42", json={"role": "admin"}, headers=AUTH)
check(r.status_code == 422 and r.get_json().get("error_code") == "TRANSITION_NOT_ALLOWED",
      "PATCH refuses a role change - it can no longer rewrite capability grants")
check(not RPC_CALLS, "and issues no grant mutation of any kind")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
print("user capabilities route gate " + ("PASS" if not FAILURES else "FAIL"))
sys.exit(0 if not FAILURES else 1)
