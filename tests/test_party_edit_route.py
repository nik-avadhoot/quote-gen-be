"""
U1 Slice A - Party editing route gate.

Run:  python tests/test_party_edit_route.py

Hermetic and offline, same fake-client convention as
test_customer_family_mutation_routes.py: Supabase is replaced by a recording
fake so this proves what the ROUTE decides - which RPC it calls, with what
parameters, whether it uses the caller's own token, and how it maps a
Postgres error code to an HTTP status - not authorization or CAS outcomes at
the database layer (proved separately by tests.party_edit_mutations() via
tests.run_all()).

The one route below (PATCH /masters/parties/<id>) is a thin forwarder to
public.update_customer_party (docs/u1-customer-foundation-authorization-
packet.md, quote-gen-fe, Slice A). It duplicates no capability or CAS check -
app_private.update_party already enforces both - so "no capability" is
proven by injecting the same 42501 the database would raise and confirming
the route maps it to 403, not by a pre-RPC short-circuit.

Same U1-CF-C2 error-mapping discipline as the Family B route gate: every
mapped code is exercised with a Postgres message SHAPED LIKE A REAL LEAK
(schema-qualified table, column, function name, the SQLSTATE itself), and
none of that text may reach the response body.
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


CAPABLE_ROWS = {
    "app_users": [{"id": 42, "auth_user_id": "auth-uuid", "display_name": "Maker", "status": "active"}],
    "group_capability_grants": [
        {"app_user_id": 42, "status": "active", "capabilities": {"capability_key": "manage_customer_master"}},
    ],
    "plant_capability_grants": [],
}


def fake_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return FakeClient(token, CAPABLE_ROWS)


cc.get_supabase_for_caller = fake_caller

import server  # noqa: E402
import auth as auth_mod  # noqa: E402
server.get_supabase_for_caller = fake_caller
auth_mod.get_supabase_for_caller = fake_caller

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-x"}

ROUTE_PATH = "/masters/parties/7"
RPC_NAME = "update_customer_party"


def reset(response=None):
    RPC_CALLS.clear()
    RPC_RESPONSES.clear()
    RPC_RESPONSES[RPC_NAME] = response


# --------------------------------------------------------- anonymous -> 401
with app.test_client() as c:
    r = c.open(ROUTE_PATH, method="PATCH", json={"display_name": "X", "expected_content_version": 1})
check(r.status_code == 401, "anonymous request refused 401")

# ------------------------------------------ success path, exact params
reset(None)
with app.test_client() as c:
    r = c.open(ROUTE_PATH, method="PATCH",
               json={"display_name": "Acme Boxes Ltd", "expected_content_version": 3}, headers=AUTH)
check(r.status_code == 200, f"authorised caller with a well-formed body succeeds ({r.status_code})")
check(len(RPC_CALLS) == 1 and RPC_CALLS[0][1] == RPC_NAME, f"calls exactly the expected RPC ({RPC_NAME})")
check(RPC_CALLS[0][0] == "tok-x", "the RPC is called with the caller's own token, not a service-role client")
check(RPC_CALLS[0][2] == {"p_party": 7, "p_expected_content_version": 3, "p_display_name": "Acme Boxes Ltd"},
      "the RPC is called with the exact expected parameters")
check(r.get_json() == {"ok": True}, "success response is the standard {ok: true} shape")

# ------------------------------------------------- missing required field -> 400, no RPC
MISSING_FIELD_CASES = [
    ("blank display_name", {"display_name": "   ", "expected_content_version": 1}),
    ("missing expected_content_version", {"display_name": "X"}),
    ("missing display_name entirely", {"expected_content_version": 1}),
]
for label, body in MISSING_FIELD_CASES:
    reset()
    with app.test_client() as c:
        r = c.open(ROUTE_PATH, method="PATCH", json=body, headers=AUTH)
    check(r.status_code == 400, f"{label}: rejected 400 before any RPC is attempted")
    check(len(RPC_CALLS) == 0, f"{label}: no RPC call was made")
    check((r.get_json() or {}).get("error_code") == "INVALID_INPUT",
          f"{label}: carries the deterministic error_code INVALID_INPUT")

# ------------------------------------------- Postgres error code -> stable identifier
LEAKY_MESSAGE = (
    'update or delete on table "public.parties" violates foreign key '
    'constraint "party_family_memberships_party_id_fkey" on column '
    '"party_family_memberships.party_id" - function app_private.update_party '
    'raised this at line 17'
)

ERROR_MAPPING_CASES = [
    ("no capability", "42501", 403, "CAPABILITY_REQUIRED"),
    ("not found", "P0002", 404, "RECORD_NOT_FOUND"),
    ("stale version", "PT409", 409, "STALE_VERSION"),
    # D2: a GENUINE serialization failure is transient and keeps its own
    # identity - retrying it unchanged is correct, unlike a stale version.
    ("genuine serialization failure", "40001", 409, "SERIALIZATION_FAILURE"),
    ("forbidden transition", "22023", 422, "TRANSITION_NOT_ALLOWED"),
    ("unmapped code", "XXNEW", 500, "INTERNAL_ERROR"),
]

import server as _server_mod  # noqa: E402

for desc, code, expected_status, expected_error_code in ERROR_MAPPING_CASES:
    reset(api_error(code, LEAKY_MESSAGE))
    with app.test_client() as c:
        r = c.open(ROUTE_PATH, method="PATCH",
                   json={"display_name": "X", "expected_content_version": 1}, headers=AUTH)
    data = r.get_json() or {}
    raw_text = r.get_data(as_text=True)

    check(r.status_code == expected_status, f"Postgres {code} ({desc}) maps to HTTP {expected_status}")
    check(data.get("error_code") == expected_error_code,
          f"response carries the deterministic error_code {expected_error_code} (got {data.get('error_code')!r})")
    check(data.get("error") == _server_mod._ERROR_MESSAGE.get(expected_error_code),
          f"the message is server.py's own fixed text for {expected_error_code}, not derived from the exception")
    check(code not in raw_text, f"the raw SQLSTATE {code} does not appear anywhere in the response")
    check("public.parties" not in raw_text and "party_family_memberships" not in raw_text,
          f"{desc}: no table name leaks into the response")
    check("party_id" not in raw_text, f"{desc}: no column name leaks into the response")
    check("app_private.update_party" not in raw_text, f"{desc}: no function name leaks into the response")
    check("violates foreign key constraint" not in raw_text and "line 17" not in raw_text,
          f"{desc}: no fragment of the raw Postgres exception text leaks into the response")

check({c for _, c, *_ in ERROR_MAPPING_CASES if c != "XXNEW"} <= set(_server_mod._RPC_ERROR_MAP),
      "every mapped SQLSTATE exercised above is a real key in server.py's own _RPC_ERROR_MAP")

# --------------------------------------------------------- no service-role client
check(all(tok != "SERVICE-ROLE" for tok, _, _ in RPC_CALLS),
      "no service-role client is used by this route")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("party edit route gate PASS")
