"""
GSM Master routes gate.

Run:  python tests/test_gsm_master_routes.py

Hermetic and offline, same fake-client convention as
tests/test_customer_family_mutation_routes.py: Supabase is replaced by a
recording fake, so this proves what the ROUTES decide - the caller-token read,
the ordering, which RPC is called with which parameters, input refusal before
any RPC, and error mapping without database text. Capability and CAS outcomes
at the database layer are proved by tests.gsm_master_catalogue() and the
migration's own functions once activated.
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


RPC_CALLS = []          # [(token, name, params), ...]
TABLE_CALLS = []        # [(token, table), ...]
RPC_RESPONSES = {}      # name -> data, or an Exception instance to raise
FAILING_TABLES = set()  # tables whose read raises APIError


def api_error(code, message="synthetic test error"):
    return APIError({"code": code, "message": message, "hint": None, "details": None})


class FakeQuery:
    def __init__(self, token, table, rows):
        self.token, self.table, self.rows = token, table, rows

    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def limit(self, *a, **k): return self

    def execute(self):
        TABLE_CALLS.append((self.token, self.table))
        if self.table in FAILING_TABLES:
            raise api_error("PGRST205", "Could not find the table 'public.paper_gsm_values' in the schema cache")
        return type("R", (), {"data": list(self.rows)})()


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


MANAGER_GRANTS = [
    {"app_user_id": 42, "status": "active", "capabilities": {"capability_key": "manage_construction_library"}},
]

ROWS = {
    "app_users": [{"id": 42, "auth_user_id": "auth-uuid", "display_name": "Maker", "status": "active"}],
    "group_capability_grants": list(MANAGER_GRANTS),
    "plant_capability_grants": [],
    "paper_gsm_values": [
        {"id": 2, "gsm": 120, "status": "active", "content_version": 1},
        {"id": 1, "gsm": 80, "status": "active", "content_version": 1},
        {"id": 3, "gsm": 230, "status": "retired", "content_version": 2},
    ],
}


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


def reset(rpc_name=None, response=None):
    RPC_CALLS.clear()
    TABLE_CALLS.clear()
    FAILING_TABLES.clear()
    RPC_RESPONSES.clear()
    if rpc_name is not None:
        RPC_RESPONSES[rpc_name] = response


ROUTES = [
    ("list", "GET", "/masters/gsm-values", None),
    ("add", "POST", "/masters/gsm-values", {"gsm": 150}),
    ("status", "POST", "/masters/gsm-values/3/status", {"status": "active", "expected_content_version": 2}),
]

# --------------------------------------------------------- anonymous -> 401
for label, method, path, body in ROUTES:
    reset()
    with app.test_client() as c:
        r = c.open(path, method=method, json=body)
    check(r.status_code == 401, f"{label}: anonymous request refused 401")
    check(not RPC_CALLS, f"{label}: anonymous request reaches no RPC")

# ---------------------------------------------------------------- list
reset()
with app.test_client() as c:
    r = c.get("/masters/gsm-values", headers=AUTH)
body = r.get_json() or {}
check(r.status_code == 200, "list: authenticated caller reads the GSM Master")
check([v["gsm"] for v in body.get("values", [])] == [80, 120, 230],
      "list: values are returned in ascending GSM order, retired values included")
check(("tok-x", "paper_gsm_values") in TABLE_CALLS,
      "list: the table is read with the caller's own token")
check(body.get("can_manage") is True, "list: can_manage reflects manage_construction_library")
check(not RPC_CALLS, "list: a read calls no RPC")

ROWS["group_capability_grants"] = []
reset()
with app.test_client() as c:
    r = c.get("/masters/gsm-values", headers=AUTH)
check(r.status_code == 200 and (r.get_json() or {}).get("can_manage") is False,
      "list: a caller without manage_construction_library still reads, with can_manage false")
ROWS["group_capability_grants"] = list(MANAGER_GRANTS)

reset()
FAILING_TABLES.add("paper_gsm_values")
with app.test_client() as c:
    r = c.get("/masters/gsm-values", headers=AUTH)
body = r.get_json() or {}
text = r.get_data(as_text=True)
check(r.status_code == 503 and body.get("error_code") == "MASTER_UNAVAILABLE",
      "list: an unreadable table answers MASTER_UNAVAILABLE, not an empty list")
check("values" not in body, "list: no values array is fabricated when the master is unavailable")
check("paper_gsm_values" not in text and "PGRST205" not in text and "schema cache" not in text,
      "list: database text never reaches the response")

# ----------------------------------------------------------------- add
reset("add_paper_gsm_value", 13)
with app.test_client() as c:
    r = c.post("/masters/gsm-values", json={"gsm": 150}, headers=AUTH)
check(r.status_code == 201 and (r.get_json() or {}).get("id") == 13, "add: success returns 201 with the new id")
check(RPC_CALLS == [("tok-x", "add_paper_gsm_value", {"p_gsm": 150})],
      "add: exactly one RPC, caller token, exact parameters")

reset("add_paper_gsm_value", 14)
with app.test_client() as c:
    r = c.post("/masters/gsm-values", json={"gsm": "160"}, headers=AUTH)
check(r.status_code == 201 and RPC_CALLS and RPC_CALLS[0][2] == {"p_gsm": 160},
      "add: a whole-number string is accepted as an integer")

for label, payload in [
    ("missing", {}), ("zero", {"gsm": 0}), ("negative", {"gsm": -80}), ("too large", {"gsm": 2001}),
    ("decimal", {"gsm": "12.5"}), ("boolean", {"gsm": True}), ("text", {"gsm": "abc"}),
]:
    reset("add_paper_gsm_value", 1)
    with app.test_client() as c:
        r = c.post("/masters/gsm-values", json=payload, headers=AUTH)
    check(r.status_code == 400 and not RPC_CALLS, f"add: {label} gsm refused 400 before any RPC")

# -------------------------------------------------------------- status
reset("set_paper_gsm_value_status", None)
with app.test_client() as c:
    r = c.post("/masters/gsm-values/3/status", json={"status": "retired", "expected_content_version": 2},
               headers=AUTH)
check(r.status_code == 200, "status: success returns 200")
check(RPC_CALLS == [("tok-x", "set_paper_gsm_value_status",
                     {"p_id": 3, "p_status": "retired", "p_expected_content_version": 2})],
      "status: exactly one RPC, caller token, exact parameters")

for label, payload in [
    ("unknown status", {"status": "deleted", "expected_content_version": 1}),
    ("missing status", {"expected_content_version": 1}),
    ("missing CAS token", {"status": "retired"}),
    ("zero CAS token", {"status": "retired", "expected_content_version": 0}),
]:
    reset("set_paper_gsm_value_status", None)
    with app.test_client() as c:
        r = c.post("/masters/gsm-values/3/status", json=payload, headers=AUTH)
    check(r.status_code == 400 and not RPC_CALLS, f"status: {label} refused 400 before any RPC")

# --------------------------------------------------------- error mapping
LEAK = "raise in app_private.add_paper_gsm_value on public.paper_gsm_values column gsm"
for code, status, error_code in [
    ("42501", 403, "CAPABILITY_REQUIRED"),
    ("22023", 422, "TRANSITION_NOT_ALLOWED"),
    ("PT409", 409, "STALE_VERSION"),
    ("P0002", 404, "RECORD_NOT_FOUND"),
]:
    reset("set_paper_gsm_value_status", api_error(code, LEAK))
    with app.test_client() as c:
        r = c.post("/masters/gsm-values/3/status", json={"status": "retired", "expected_content_version": 2},
                   headers=AUTH)
    text = r.get_data(as_text=True)
    check(r.status_code == status and (r.get_json() or {}).get("error_code") == error_code,
          f"errors: SQLSTATE {code} maps to {status} {error_code}")
    check("paper_gsm_values" not in text and "app_private" not in text and code not in text,
          f"errors: SQLSTATE {code} leaks no database text")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("GSM Master routes PASS")
