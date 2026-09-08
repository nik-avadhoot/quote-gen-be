"""
U1 Slice C - Customer Location routes gate.

Run:  python tests/test_customer_location_routes.py

Hermetic and offline, same fake-client convention as
test_customer_family_mutation_routes.py / test_party_edit_route.py: Supabase
is replaced by a recording fake so this proves what the ROUTE decides - which
RPC it calls, with what parameters, whether it uses the caller's own token,
and how it maps a Postgres error code to an HTTP status - not authorization
or CAS outcomes at the database layer (proved separately by
tests.customer_location_mutations() via tests.run_all()).

Every route below is a thin forwarder to one `public.*` RPC
(docs/u1-customer-foundation-authorization-packet.md, quote-gen-fe, Slice C).
None duplicates a capability, eligibility, or state-transition check -
app_private.* already enforces every one. There is deliberately no
eligibility-change route - post-proposal eligibility change is
Product-Owner-blocked, not built.
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


def reset(rpc_name=None, response=None):
    RPC_CALLS.clear()
    if rpc_name is not None:
        RPC_RESPONSES.clear()
        RPC_RESPONSES[rpc_name] = response


ROUTES = [
    # (label, method, path, body, rpc_name, expected_params, success_response)
    ("propose", "POST", "/masters/parties/9/locations",
     {"location_type": "plant", "address_text": "1 Industrial Ave", "contact_name": "A",
      "notes": "n", "bill_to_eligible": True, "ship_to_eligible": False},
     "propose_customer_location",
     {"p_party": 9, "p_location_type": "plant", "p_address_text": "1 Industrial Ave",
      "p_contact_name": "A", "p_notes": "n", "p_bill_to_eligible": True, "p_ship_to_eligible": False},
     11),
    ("update", "PATCH", "/masters/customer-locations/11",
     {"expected_content_version": 1, "address_text": "2 New Ave", "contact_name": "B", "notes": "n2"},
     "update_customer_location",
     {"p_location": 11, "p_expected_content_version": 1,
      "p_address_text": "2 New Ave", "p_contact_name": "B", "p_notes": "n2"}, None),
    ("approve", "POST", "/masters/customer-locations/11/approve",
     {"expected_content_version": 1}, "approve_customer_location",
     {"p_location": 11, "p_expected_content_version": 1}, None),
    ("retire", "POST", "/masters/customer-locations/11/retire",
     {"expected_content_version": 2}, "retire_customer_location",
     {"p_location": 11, "p_expected_content_version": 2}, None),
    ("assign-code", "POST", "/masters/customer-locations/11/assign-code",
     {}, "assign_customer_location_code", {"p_location": 11}, "F-007-001-01"),
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

# ------------------------------------------------- eligibility guard, Flask-side
ELIGIBILITY_CASES = [
    ("propose: neither eligibility checked", {"bill_to_eligible": False, "ship_to_eligible": False}),
    ("propose: eligibility omitted entirely", {}),
]
for label, body in ELIGIBILITY_CASES:
    reset()
    with app.test_client() as c:
        r = c.open("/masters/parties/9/locations", method="POST", json=body, headers=AUTH)
    check(r.status_code == 400, f"{label}: rejected 400 before any RPC is attempted")
    check(len(RPC_CALLS) == 0, f"{label}: no RPC call was made")
    check((r.get_json() or {}).get("error_code") == "INVALID_INPUT",
          f"{label}: carries the deterministic error_code INVALID_INPUT")

# ------------------------------------------------- missing required field -> 400, no RPC
MISSING_FIELD_CASES = [
    ("update: missing expected_content_version", "PATCH", "/masters/customer-locations/11",
     {"address_text": "X"}),
    ("approve: missing expected_content_version", "POST", "/masters/customer-locations/11/approve", {}),
    ("retire: missing expected_content_version", "POST", "/masters/customer-locations/11/retire", {}),
]
for label, method, path, body in MISSING_FIELD_CASES:
    reset()
    with app.test_client() as c:
        r = c.open(path, method=method, json=body, headers=AUTH)
    check(r.status_code == 400, f"{label}: rejected 400 before any RPC is attempted")
    check(len(RPC_CALLS) == 0, f"{label}: no RPC call was made")
    check((r.get_json() or {}).get("error_code") == "INVALID_INPUT",
          f"{label}: carries the deterministic error_code INVALID_INPUT")

# ------------------------------------------- no eligibility-change route exists
with app.test_client() as c:
    r = c.open("/masters/customer-locations/11/eligibility", method="POST",
               json={"bill_to_eligible": True, "ship_to_eligible": True}, headers=AUTH)
check(r.status_code == 404, "no /eligibility route exists - post-proposal change is Product-Owner-blocked")

# ------------------------------------------- Postgres error code -> stable identifier
LEAKY_MESSAGE = (
    'update or delete on table "public.customer_locations" violates foreign key '
    'constraint "customer_location_versions_location_id_fkey" on column '
    '"customer_location_versions.location_id" - function app_private.update_customer_location '
    'raised this at line 23'
)

ERROR_MAPPING_CASES = [
    ("no capability", "42501", 403, "CAPABILITY_REQUIRED", "approve", "POST",
     "/masters/customer-locations/11/approve", {"expected_content_version": 1}, "approve_customer_location"),
    ("not found", "P0002", 404, "RECORD_NOT_FOUND", "update", "PATCH",
     "/masters/customer-locations/999", {"address_text": "X", "expected_content_version": 1},
     "update_customer_location"),
    ("stale version", "PT409", 409, "STALE_VERSION", "update", "PATCH",
     "/masters/customer-locations/11", {"address_text": "X", "expected_content_version": 1},
     "update_customer_location"),
    ("forbidden transition", "22023", 422, "TRANSITION_NOT_ALLOWED", "approve", "POST",
     "/masters/customer-locations/11/approve", {"expected_content_version": 1}, "approve_customer_location"),
    ("unmapped code", "XXNEW", 500, "INTERNAL_ERROR", "approve", "POST",
     "/masters/customer-locations/11/approve", {"expected_content_version": 1}, "approve_customer_location"),
]

import server as _server_mod  # noqa: E402

for desc, code, expected_status, expected_error_code, label, method, path, body, rpc_name in ERROR_MAPPING_CASES:
    reset(rpc_name, api_error(code, LEAKY_MESSAGE))
    with app.test_client() as c:
        r = c.open(path, method=method, json=body, headers=AUTH)
    data = r.get_json() or {}
    raw_text = r.get_data(as_text=True)

    check(r.status_code == expected_status, f"{label}: Postgres {code} ({desc}) maps to HTTP {expected_status}")
    check(data.get("error_code") == expected_error_code,
          f"{label}: response carries the deterministic error_code {expected_error_code} "
          f"(got {data.get('error_code')!r})")
    check(data.get("error") == _server_mod._ERROR_MESSAGE.get(expected_error_code),
          f"{label}: the message is server.py's own fixed text for {expected_error_code}")
    check(code not in raw_text, f"{label}: the raw SQLSTATE {code} does not appear anywhere in the response")
    check("customer_locations" not in raw_text and "customer_location_versions" not in raw_text,
          f"{label}: no table name leaks into the response")
    check("location_id" not in raw_text, f"{label}: no column name leaks into the response")
    check("app_private.update_customer_location" not in raw_text,
          f"{label}: no function name leaks into the response")
    check("violates foreign key constraint" not in raw_text and "line 23" not in raw_text,
          f"{label}: no fragment of the raw Postgres exception text leaks into the response")

# --------------------------------------------------------- no service-role client
check(all(tok != "SERVICE-ROLE" for tok, _, _ in RPC_CALLS),
      "no service-role client is used by any of these routes")

# --- D2 an upstream timeout is a stable 504, never a bare 500 ----------------
# Observed for real in the browser walkthrough: a governed mutation hung on the
# supabase-py 120-second default PostgREST timeout and then surfaced as
# 500 INTERNAL_ERROR carrying nothing the user could act on. The timeout is now
# bounded, and both the httpx-shaped and the socket-shaped failure map to
# UPSTREAM_TIMEOUT / 504 with a fixed message. The underlying text - which names
# the transport, not the application - must never reach the response body.
import httpx  # noqa: E402

TIMEOUT_SHAPES = [
    ("httpx.ReadTimeout", httpx.ReadTimeout("The read operation timed out")),
    ("socket TimeoutError", TimeoutError("The read operation timed out")),
    ("wrapped in a plain Exception",
     Exception("HTTPConnectionPool: Read timed out. (read timeout=120)")),
]

for shape_label, exc in TIMEOUT_SHAPES:
    reset("update_customer_location", exc)
    with app.test_client() as c:
        r = c.open("/masters/customer-locations/11", method="PATCH",
                   json={"address_text": "X", "expected_content_version": 1}, headers=AUTH)
    data = r.get_json() or {}
    body_text = r.get_data(as_text=True)

    check(r.status_code == 504,
          f"timeout ({shape_label}): answered 504, not 500 (got {r.status_code})")
    check(data.get("error_code") == "UPSTREAM_TIMEOUT",
          f"timeout ({shape_label}): carries error_code UPSTREAM_TIMEOUT "
          f"(got {data.get('error_code')!r})")
    check(data.get("error") == _server_mod._ERROR_MESSAGE["UPSTREAM_TIMEOUT"],
          f"timeout ({shape_label}): returns the fixed, actionable message")
    # D2 CORRECTION. A client-side timeout means the RESPONSE was lost, NOT that
    # the server did nothing - the transaction may have committed before the
    # connection gave up. Claiming "nothing was changed" invites a duplicate
    # submission of an operation that already succeeded, so the message must say
    # the outcome is unknown and send the user to refresh first.
    msg = (data.get("error") or "").lower()
    check("unknown" in msg,
          f"timeout ({shape_label}): the message says the OUTCOME IS UNKNOWN")
    check("refresh" in msg,
          f"timeout ({shape_label}): the message tells the user to refresh before retrying")
    check("nothing was changed" not in msg,
          f"timeout ({shape_label}): must NOT claim the write did not happen")
    check("timed out" not in body_text.lower() or "did not respond in time" in body_text.lower(),
          f"timeout ({shape_label}): raw transport text is not echoed to the client")
    check("read timeout=" not in body_text and "HTTPConnectionPool" not in body_text,
          f"timeout ({shape_label}): no infrastructure detail leaks into the body")

# A non-timeout failure must still be an INTERNAL_ERROR 500 - the new branch
# must not swallow unrelated faults into a retryable answer.
reset("update_customer_location", Exception("column \"secret_col\" does not exist"))
with app.test_client() as c:
    r = c.open("/masters/customer-locations/11", method="PATCH",
               json={"address_text": "X", "expected_content_version": 1}, headers=AUTH)
check(r.status_code == 500 and (r.get_json() or {}).get("error_code") == "INTERNAL_ERROR",
      "a NON-timeout failure is still INTERNAL_ERROR 500, not misreported as a timeout")
check("secret_col" not in r.get_data(as_text=True),
      "a non-timeout failure still leaks no database text")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("customer-location routes gate PASS")
