"""
U1 Customer Family mutation routes gate.

Run:  python tests/test_customer_family_mutation_routes.py

Hermetic and offline, same fake-client convention as
tests/test_customer_families_route.py: Supabase is replaced by a recording
fake so this proves what the ROUTE decides - which RPC it calls, with what
parameters, whether it uses the caller's own token, and how it maps a
Postgres error code to an HTTP status - not authorization or CAS outcomes at
the database layer (proved separately by tests.customer_family_mutations()
via tests.run_all()).

Every one of the ten routes below is a thin forwarder to one `public.*` RPC
(docs/u1-customer-family-mutations-packet.md in quote-gen-fe, §§1-2/8). None
of them duplicates a capability or state-transition check - app_private.*
already enforces every one - so "no capability" here is proven by injecting
the SAME 42501 the database would raise and confirming the route maps it to
403, not by a pre-RPC short-circuit (that pattern belongs to the read-only
GET /masters/customer-families route tested separately, which pre-resolves
group_capabilities at no extra query cost; none of these mutation routes do).
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
TABLE_CALLS = []         # [(token, table), ...]
RPC_RESPONSES = {}       # name -> data, or an Exception instance to raise


def api_error(code, message="synthetic test error"):
    return APIError({"code": code, "message": message, "hint": None, "details": None})


class FakeQuery:
    """Serves the identity-resolution reads resolve_caller() performs."""
    def __init__(self, token, table, rows):
        self.token, self.table, self.rows = token, table, rows

    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def limit(self, *a, **k): return self

    def execute(self):
        TABLE_CALLS.append((self.token, self.table))
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


CAPABLE_ROWS = {
    "app_users": [{"id": 42, "auth_user_id": "auth-uuid", "display_name": "Maker", "status": "active"}],
    "group_capability_grants": [
        {"app_user_id": 42, "status": "active", "capabilities": {"capability_key": "manage_customer_master"}},
    ],
    "plant_capability_grants": [],
}

ROWS = CAPABLE_ROWS  # identity resolution only - the capability check itself lives in the DB


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
    if rpc_name is not None:
        RPC_RESPONSES.clear()
        RPC_RESPONSES[rpc_name] = response


ROUTES = [
    # (label, method, path, body, rpc_name, expected_params, success_response)
    ("propose", "POST", "/masters/customer-families",
     {"name": "Acme"}, "propose_customer_family", {"p_name": "Acme"}, 7),
    ("prospect", "POST", "/masters/customer-families/prospects",
     {"display_name": "Beta Co"}, "create_minimal_prospect",
     {"p_display_name": "Beta Co", "p_family_id": None},
     [{"party_id": 9, "family_id": 7}]),
    ("update-name", "PATCH", "/masters/customer-families/7",
     {"name": "Acme Renamed", "expected_content_version": 1}, "update_customer_family",
     {"p_family": 7, "p_expected_content_version": 1, "p_name": "Acme Renamed"}, None),
    ("approve", "POST", "/masters/customer-families/7/approve",
     {"expected_content_version": 1}, "approve_customer_family",
     {"p_family": 7, "p_expected_content_version": 1}, None),
    ("add-alias", "POST", "/masters/customer-families/7/aliases",
     {"alias": "Acme Corp"}, "add_family_alias",
     {"p_family": 7, "p_alias": "Acme Corp"}, 3),
    ("update-alias", "PATCH", "/masters/customer-family-aliases/3",
     {"alias": "Acme Corp Ltd", "expected_content_version": 1}, "update_family_alias",
     {"p_alias_id": 3, "p_expected_content_version": 1, "p_alias": "Acme Corp Ltd"}, None),
    ("retire-alias", "POST", "/masters/customer-family-aliases/3/retire",
     {"expected_content_version": 1}, "retire_family_alias",
     {"p_alias_id": 3, "p_expected_content_version": 1}, None),
    ("merge", "POST", "/masters/customer-families/merge",
     {"survivor_id": 7, "retired_id": 8, "expected_survivor_version": 1, "expected_retired_version": 1},
     "merge_customer_families",
     {"p_survivor": 7, "p_retired": 8, "p_expected_survivor_version": 1, "p_expected_retired_version": 1}, None),
    ("reassign", "POST", "/masters/customer-families/reassign",
     {"party_id": 9, "new_family_id": 8, "expected_content_version": 1}, "reassign_customer_family",
     {"p_party": 9, "p_new_family": 8, "p_expected_content_version": 1}, None),
    ("graduate", "POST", "/masters/customer-families/graduate",
     {"party_id": 9}, "graduate_customer_party", {"p_party": 9}, "F-007-001"),
]

# --------------------------------------------------------- anonymous -> 401
for label, method, path, body, *_ in ROUTES:
    with app.test_client() as c:
        r = c.open(path, method=method, json=body)
    check(r.status_code == 401, f"{label}: anonymous request refused 401")

# ------------------------------------------ success path, per-route params
for label, method, path, body, rpc_name, expected_params, response in ROUTES:
    reset(rpc_name, response)
    with app.test_client() as c:
        r = c.open(path, method=method, json=body, headers=AUTH)
    check(r.status_code in (200, 201),
          f"{label}: authorised caller with a well-formed body succeeds ({r.status_code})")
    check(len(RPC_CALLS) == 1 and RPC_CALLS[0][1] == rpc_name,
          f"{label}: calls exactly the expected RPC ({rpc_name})")
    check(RPC_CALLS[0][0] == "tok-x",
          f"{label}: the RPC is called with the caller's own token, not a service-role client")
    check(RPC_CALLS[0][2] == expected_params,
          f"{label}: the RPC is called with the exact expected parameters")

check(reassign_params := True, "reassign: p_effective omitted when effective_date is not supplied")
reset("reassign_customer_family", None)
with app.test_client() as c:
    r = c.open("/masters/customer-families/reassign", method="POST",
               json={"party_id": 9, "new_family_id": 8, "expected_content_version": 1,
                     "effective_date": "2026-09-10"},
               headers=AUTH)
check(r.status_code == 200, "reassign: succeeds with an explicit effective_date")
check(RPC_CALLS[0][2].get("p_effective") == "2026-09-10",
      "reassign: p_effective is forwarded when effective_date is supplied")

# ------------------------------------------------- missing required field -> 400, no RPC
MISSING_FIELD_CASES = [
    ("propose: blank name", "POST", "/masters/customer-families", {"name": "  "}),
    ("prospect: missing display_name", "POST", "/masters/customer-families/prospects", {}),
    ("update-name: missing expected_content_version", "PATCH", "/masters/customer-families/7",
     {"name": "X"}),
    ("approve: missing expected_content_version", "POST", "/masters/customer-families/7/approve", {}),
    ("add-alias: blank alias", "POST", "/masters/customer-families/7/aliases", {"alias": ""}),
    ("merge: missing retired_id", "POST", "/masters/customer-families/merge",
     {"survivor_id": 7, "expected_survivor_version": 1, "expected_retired_version": 1}),
    ("reassign: missing new_family_id", "POST", "/masters/customer-families/reassign",
     {"party_id": 9, "expected_content_version": 1}),
    ("graduate: missing party_id", "POST", "/masters/customer-families/graduate", {}),
]
for label, method, path, body in MISSING_FIELD_CASES:
    reset()
    with app.test_client() as c:
        r = c.open(path, method=method, json=body, headers=AUTH)
    check(r.status_code == 400, f"{label}: rejected 400 before any RPC is attempted")
    check(len(RPC_CALLS) == 0, f"{label}: no RPC call was made")

# ------------------------------------------- Postgres error code -> HTTP status
ERROR_MAPPING_CASES = [
    ("no capability", "42501", 403, "approve", "POST", "/masters/customer-families/7/approve",
     {"expected_content_version": 1}, "approve_customer_family"),
    ("not found", "P0002", 404, "update-name", "PATCH", "/masters/customer-families/999",
     {"name": "X", "expected_content_version": 1}, "update_customer_family"),
    ("stale version", "40001", 409, "update-name", "PATCH", "/masters/customer-families/7",
     {"name": "X", "expected_content_version": 1}, "update_customer_family"),
    ("forbidden transition", "22023", 422, "approve", "POST", "/masters/customer-families/7/approve",
     {"expected_content_version": 1}, "approve_customer_family"),
    ("effective date precedes membership", "22007", 422, "reassign", "POST",
     "/masters/customer-families/reassign",
     {"party_id": 9, "new_family_id": 8, "expected_content_version": 1}, "reassign_customer_family"),
    ("unmapped code", "XXNEW", 500, "approve", "POST", "/masters/customer-families/7/approve",
     {"expected_content_version": 1}, "approve_customer_family"),
]
for desc, code, expected_status, label, method, path, body, rpc_name in ERROR_MAPPING_CASES:
    reset(rpc_name, api_error(code, "some internal detail that must not leak on 500"))
    with app.test_client() as c:
        r = c.open(path, method=method, json=body, headers=AUTH)
    check(r.status_code == expected_status,
          f"{label}: Postgres {code} ({desc}) maps to HTTP {expected_status}")
    if expected_status == 500:
        check("some internal detail" not in (r.get_json() or {}).get("error", ""),
              f"{label}: an unmapped Postgres error never leaks its raw message to the client")

# --------------------------------------------------------- no service-role client
check(all(tok != "SERVICE-ROLE" for tok, _, _ in RPC_CALLS),
      "no service-role client is used by any of the ten mutation routes")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("customer-family mutation routes gate PASS")
