"""
U5 governed Sector master routes gate.

Run:  python tests/test_sector_master_routes.py

Hermetic and offline, same fake-client convention as
tests/test_gsm_master_routes.py: Supabase is replaced by a recording fake, so
this proves what the ROUTES decide - the caller-token read, the read gate, how
the identity row and its approved version are merged, which RPC is called with
which parameters, input refusal BEFORE any RPC, and error mapping without
database text. Capability, CAS and transition outcomes at the database layer
are proved by tests.u5_governed_sector_master_catalogue() and by the
self-rolling-back lifecycle transaction recorded in
20260922150221_fix_u5_sector_definer_execute_grants.sql.

THE DEFECT THIS SLICE CLOSES. A Sector added in Commercial Policies used to
land in a browser-local list no other screen read, so it never reached the
Customer Families dropdown, which reads public.sectors. These routes are the
governed path that replaced that list.
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
TABLE_CALLS = []
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
        TABLE_CALLS.append((self.token, self.table))
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


READER_GRANTS = [
    {"app_user_id": 42, "status": "active", "capabilities": {"capability_key": "read_party_master"}},
]

# Deliberately returned OUT of code order, and with a superseded version mixed
# in, so the route's own merge and ordering are what the assertions observe.
ROWS = {
    "app_users": [{"id": 42, "auth_user_id": "auth-uuid", "display_name": "Maker", "status": "active"}],
    "group_capability_grants": list(READER_GRANTS),
    "plant_capability_grants": [],
    "sectors": [
        {"id": 2, "sector_code": "PHARMA", "name": "Pharmaceuticals", "status": "active"},
        {"id": 1, "sector_code": "ALCOBEV", "name": "Alcobev", "status": "active"},
        {"id": 3, "sector_code": "OLDONE", "name": "Retired tier", "status": "inactive"},
    ],
    "sector_versions": [
        {"id": 11, "sector_id": 1, "version_no": 1, "waste_cbb_pct": 5, "waste_pp_pct": 5,
         "conv_box_rate": 7, "conv_pp_rate": 12.5, "margin_pct": 8, "spec_lang": "BS",
         "status": "superseded", "approved_at": "2026-09-18T00:00:00Z"},
        {"id": 12, "sector_id": 1, "version_no": 2, "waste_cbb_pct": 4, "waste_pp_pct": 5,
         "conv_box_rate": 9, "conv_pp_rate": 12.5, "margin_pct": 10, "spec_lang": "BS",
         "status": "approved", "approved_at": "2026-09-22T00:00:00Z"},
        {"id": 13, "sector_id": 2, "version_no": 1, "waste_cbb_pct": 5, "waste_pp_pct": 5,
         "conv_box_rate": 7, "conv_pp_rate": 10, "margin_pct": 8, "spec_lang": "BCT+BS",
         "status": "approved", "approved_at": "2026-09-18T00:00:00Z"},
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

GOOD_COMMERCIALS = {
    "waste_cbb_pct": 5, "waste_pp_pct": 5, "conv_box_rate": 7,
    "conv_pp_rate": 10, "margin_pct": 8, "spec_lang": "BCT+BS",
}


def reset(rpc_name=None, response=None):
    RPC_CALLS.clear()
    TABLE_CALLS.clear()
    RPC_RESPONSES.clear()
    if rpc_name is not None:
        RPC_RESPONSES[rpc_name] = response


ROUTES = [
    ("list", "GET", "/masters/sectors", None),
    ("propose", "POST", "/masters/sectors", {"sector_code": "X", "name": "X", **GOOD_COMMERCIALS}),
    ("revise", "POST", "/masters/sectors/1/commercials", {"expected_version_no": 2, **GOOD_COMMERCIALS}),
    ("rename", "PATCH", "/masters/sectors/1", {"name": "New"}),
    ("status", "POST", "/masters/sectors/1/status", {"status": "inactive"}),
]

# --------------------------------------------------------- anonymous -> 401
for label, method, path, body in ROUTES:
    reset()
    with app.test_client() as c:
        r = c.open(path, method=method, json=body)
    check(r.status_code == 401, f"{label}: anonymous request refused 401")
    check(not RPC_CALLS, f"{label}: anonymous request reaches no RPC")

# ------------------------------------------------------------------- read
reset()
with app.test_client() as c:
    r = c.get("/masters/sectors", headers=AUTH)
body = r.get_json()
check(r.status_code == 200, "list: a reader is allowed")
check([s["sector_code"] for s in body["sectors"]] == ["ALCOBEV", "OLDONE", "PHARMA"],
      "list: rows are ordered by code, not by whatever PostgREST returned")
alcobev = next(s for s in body["sectors"] if s["sector_code"] == "ALCOBEV")
check(alcobev["version"]["version_no"] == 2 and alcobev["version"]["margin_pct"] == 10,
      "list: the APPROVED version is the one lifted onto the row, not the newest by id")
check([v["version_no"] for v in alcobev["versions"]] == [1, 2],
      "list: the full version history comes back in version order")
old = next(s for s in body["sectors"] if s["sector_code"] == "OLDONE")
check(old["version"] is None and old["versions"] == [],
      "list: a Sector with no approved version reports none rather than borrowing another's")
check(body.get("mutations") == "governed", "list: the payload states the master is governed")
check({t for _, t in TABLE_CALLS} == {"sectors", "sector_versions"}
      or {"sectors", "sector_versions"} <= {t for _, t in TABLE_CALLS},
      "list: reads exactly the two Sector tables on the caller's own token")
check(all(tok == "tok-x" for tok, _ in TABLE_CALLS),
      "list: every read carries the CALLER's token, never a service key")

# read gate: neither read capability -> 403, and no data leaks as an empty list
ROWS["group_capability_grants"] = []
reset()
with app.test_client() as c:
    r = c.get("/masters/sectors", headers=AUTH)
check(r.status_code == 403, "list: a caller with neither read capability gets 403, not an empty list")
check("sectors" not in (r.get_json() or {}), "list: the refusal carries no sector data")

# the OR is real: read_construction_library alone is enough, mirroring the RLS predicate
ROWS["group_capability_grants"] = [
    {"app_user_id": 42, "status": "active",
     "capabilities": {"capability_key": "read_construction_library"}}]
reset()
with app.test_client() as c:
    r = c.get("/masters/sectors", headers=AUTH)
check(r.status_code == 200, "list: read_construction_library alone is enough, as the RLS predicate says")
ROWS["group_capability_grants"] = list(READER_GRANTS)

# ---------------------------------------------------- propose: validation
BAD_PROPOSALS = [
    ({"name": "X", **GOOD_COMMERCIALS}, "a missing code"),
    ({"sector_code": "   ", "name": "X", **GOOD_COMMERCIALS}, "a whitespace-only code"),
    ({"sector_code": "X", **GOOD_COMMERCIALS}, "a missing name"),
    ({"sector_code": "X", "name": "  ", **GOOD_COMMERCIALS}, "a whitespace-only name"),
    ({"sector_code": "X", "name": "X", **{**GOOD_COMMERCIALS, "margin_pct": None}}, "a missing margin"),
    ({"sector_code": "X", "name": "X", **{**GOOD_COMMERCIALS, "margin_pct": -1}}, "a negative margin"),
    ({"sector_code": "X", "name": "X", **{**GOOD_COMMERCIALS, "waste_cbb_pct": -5}}, "a negative waste"),
]
for payload, why in BAD_PROPOSALS:
    reset("propose_sector", 99)
    with app.test_client() as c:
        r = c.post("/masters/sectors", headers=AUTH, json=payload)
    check(r.status_code == 400, f"propose: {why} is refused 400")
    check(not RPC_CALLS, f"propose: {why} is refused BEFORE any RPC runs")

# ------------------------------------------------------- propose: success
reset("propose_sector", 99)
with app.test_client() as c:
    r = c.post("/masters/sectors", headers=AUTH, json={
        "sector_code": " explosives ", "name": "  Explosives & Defence  ",
        "waste_cbb_pct": 5, "waste_pp_pct": 5, "conv_box_rate": 7,
        "conv_pp_rate": 10, "margin_pct": 8, "spec_lang": " BCT+BS "})
check(r.status_code == 201 and r.get_json() == {"id": 99}, "propose: returns 201 and the new id")
token, name, params = RPC_CALLS[0]
check(name == "propose_sector", "propose: calls the governed propose_sector wrapper")
check(token == "tok-x", "propose: the RPC runs on the caller's own token")
check(params == {"p_code": "EXPLOSIVES", "p_name": "Explosives & Defence",
                 "p_waste_cbb": 5.0, "p_waste_pp": 5.0, "p_conv_box": 7.0,
                 "p_conv_pp": 10.0, "p_margin": 8.0, "p_spec_lang": "BCT+BS"},
      "propose: every parameter name matches the RPC signature, code upper-cased and trimmed",
      )

# Blank waste/conversion means "inherit the calculation default" (CDM-19). It
# must reach the RPC as null, NOT as 0 - zero is a real, different value.
reset("propose_sector", 100)
with app.test_client() as c:
    c.post("/masters/sectors", headers=AUTH, json={
        "sector_code": "Y", "name": "Y", "waste_cbb_pct": "", "waste_pp_pct": None,
        "conv_box_rate": "", "conv_pp_rate": 0, "margin_pct": 8, "spec_lang": ""})
_, _, params = RPC_CALLS[0]
check(params["p_waste_cbb"] is None and params["p_waste_pp"] is None
      and params["p_conv_box"] is None and params["p_conv_pp"] == 0.0,
      "propose: blank inherits as null and a real zero stays zero")
check(params["p_spec_lang"] is None, "propose: a blank spec language is null, not an empty string")

# --------------------------------------------------------------- revise
reset("revise_sector_commercials", 3)
with app.test_client() as c:
    r = c.post("/masters/sectors/1/commercials", headers=AUTH, json=GOOD_COMMERCIALS)
check(r.status_code == 400 and not RPC_CALLS,
      "revise: a missing expected_version_no is refused before any RPC")

reset("revise_sector_commercials", 3)
with app.test_client() as c:
    r = c.post("/masters/sectors/1/commercials", headers=AUTH,
               json={"expected_version_no": 2, **GOOD_COMMERCIALS})
_, name, params = RPC_CALLS[0]
check(r.status_code == 200 and r.get_json() == {"version_no": 3},
      "revise: returns the new approved version number")
check(name == "revise_sector_commercials" and params["p_sector"] == 1
      and params["p_expected_version_no"] == 2,
      "revise: carries the sector and the CAS token the caller read")

# --------------------------------------------------------- rename / status
reset("rename_sector", None)
with app.test_client() as c:
    r = c.patch("/masters/sectors/1", headers=AUTH, json={"name": "   "})
check(r.status_code == 400 and not RPC_CALLS, "rename: a blank name is refused before any RPC")

reset("rename_sector", None)
with app.test_client() as c:
    r = c.patch("/masters/sectors/1", headers=AUTH, json={"name": "  Renamed  "})
_, name, params = RPC_CALLS[0]
check(r.status_code == 200 and name == "rename_sector" and params == {"p_sector": 1, "p_name": "Renamed"},
      "rename: trims and sends only the display name")

# There is deliberately NO route that edits sector_code: Costing resolves a
# Sector by it, so a change would orphan every reference.
check(not any(rule.rule.startswith("/masters/sectors") and "code" in rule.rule
              for rule in app.url_map.iter_rules()),
      "no route exists to edit a Sector code - it is permanent by design")

for bad in ("retired", "deleted", "", "ACTIVE"):
    reset("set_sector_status", None)
    with app.test_client() as c:
        r = c.post("/masters/sectors/1/status", headers=AUTH, json={"status": bad})
    check(r.status_code == 400 and not RPC_CALLS,
          f"status: {bad!r} is refused before any RPC - only active/inactive exist")

reset("set_sector_status", None)
with app.test_client() as c:
    r = c.post("/masters/sectors/1/status", headers=AUTH, json={"status": "inactive"})
_, name, params = RPC_CALLS[0]
check(r.status_code == 200 and name == "set_sector_status"
      and params == {"p_sector": 1, "p_status": "inactive"},
      "status: forwards exactly the governed status change")

# ------------------------------------------------------------ error mapping
ERRORS = [
    ("42501", 403, "CAPABILITY_REQUIRED", "a capability refusal"),
    ("PT409", 409, "STALE_VERSION", "a stale CAS conflict"),
    ("P0002", 404, "RECORD_NOT_FOUND", "an unknown Sector"),
    ("23503", 404, "RECORD_NOT_FOUND", "a Sector still classifying a live Family"),
    ("22023", 422, "TRANSITION_NOT_ALLOWED", "a refused transition"),
]
for sqlstate, status, code, why in ERRORS:
    reset("revise_sector_commercials", api_error(sqlstate, "raw database text that must not leak"))
    with app.test_client() as c:
        r = c.post("/masters/sectors/1/commercials", headers=AUTH,
                   json={"expected_version_no": 2, **GOOD_COMMERCIALS})
    payload = r.get_json() or {}
    check(r.status_code == status and payload.get("error_code") == code,
          f"revise: {why} maps to {code} / {status}")
    check("raw database text" not in str(payload),
          f"revise: {why} does not leak the database's own message")

# A duplicate code is a uniqueness refusal, not a missing record.
reset("propose_sector", api_error("23505", "duplicate key value violates unique constraint"))
with app.test_client() as c:
    r = c.post("/masters/sectors", headers=AUTH,
               json={"sector_code": "PHARMA", "name": "Dup", **GOOD_COMMERCIALS})
payload = r.get_json() or {}
check(r.status_code == 422 and payload.get("error_code") == "TRANSITION_NOT_ALLOWED",
      "propose: a duplicate Sector code is refused as a transition, not a 404")
check("duplicate key value" not in str(payload),
      "propose: the duplicate refusal does not leak the constraint text")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("Sector master routes gate PASS")
