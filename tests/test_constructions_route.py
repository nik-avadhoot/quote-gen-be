"""
U2 Construction Library route gate.

Run:  python tests/test_constructions_route.py

Hermetic and offline, same fake-client convention as
tests/test_customer_families_route.py: Supabase is replaced by a recording
fake, so this proves what the ROUTE decides - status codes, which client it
uses, which columns it selects, how it degrades - not authorization outcomes
at the RLS layer, which the real policies prove via tests.run_all().

WHAT EACH GROUP WOULD CATCH:

  CL-2  a route relying on RLS alone returns 200 with an empty list to a
        caller without read_construction_library. That says "no constructions
        exist", which is false. This is the PRIMARY case for this master, not
        an edge case: S4-5/FA-6 proved a Maker does not hold the capability.
  CL-4  a route that over-selects leaks actor attribution. created_by,
        adopted_by and approved_by are present in the fake rows ON PURPOSE, so
        a test that never supplied them could prove nothing.
  CL-5  a route that renders adoptions for versions the caller cannot read
        would leak the existence of those versions. Orphans must be dropped.
  CL-6  adoptions_partial must be TRUE only on a FAILED optional read, and
        FALSE on a successful read that legitimately returned zero rows.
        Conflating them overstates completeness in one direction and invents a
        failure in the other.
  CL-7  a failure of a REQUIRED read must never be reported as partial
        success.
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
_PLAIN_COLS = __import__("re").compile(r"^[a-z_][a-z0-9_]*$")


def _project(cols, rows):
    if not cols:
        return rows
    wanted = [c.strip() for c in str(cols).split(",")]
    if not all(_PLAIN_COLS.match(c) for c in wanted):
        return rows
    return [{k: r[k] for k in wanted if k in r} for r in rows]


class FakeQuery:
    def __init__(self, token, table, rows):
        self.token, self.table, self.rows = token, table, rows
        self.cols = None

    def select(self, *a, **k):
        if a:
            self.cols = a[0]
        return self

    def eq(self, *a, **k): return self
    def limit(self, *a, **k): return self

    def execute(self):
        CALLS.append((self.token, self.table, self.cols))
        return type("R", (), {"data": _project(self.cols, self.rows)})()


class FakeAuth:
    def get_user(self, tok):
        return type("U", (), {"user": type("X", (), {"id": "auth-uuid", "email": "u@x.invalid"})()})()


class FakeClient:
    def __init__(self, token, rows_by_table):
        self.token, self._rows = token, rows_by_table
        self.auth = FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name, self._rows.get(name, []))


_CONSTRUCTIONS = [{"id": 5, "construction_code": "CON-000125", "name": "5-ply BC RSC",
                   "status": "published", "surviving_construction_id": None, "created_by": 3}]

# Actor attribution and a full layer stack are BOTH present so the projection
# assertions below have something real to catch.
_VERSIONS = [{
    "id": 41, "construction_id": 5, "version_no": 2, "ply": 5,
    "flute_f1": "B", "flute_f2": "A", "board_gsm": 780, "effective_from": "2026-01-01",
    "layer_top_code": "24", "layer_top_gsm": 180,
    "layer_f1_code": "20", "layer_f1_gsm": 150,
    "layer_l1_code": "20", "layer_l1_gsm": 150,
    "layer_f2_code": "20", "layer_f2_gsm": 150,
    "layer_l2_code": "24", "layer_l2_gsm": 180,
    "approved_at": "2026-02-01T00:00:00Z", "approved_by": 3, "created_by": 3,
}]

NO_CAP_ROWS = {
    "app_users": [{"id": 1, "auth_user_id": "auth-uuid", "display_name": "NoCap", "status": "active"}],
    "group_capability_grants": [],
    "plant_capability_grants": [],
    "constructions": _CONSTRUCTIONS,
    "construction_versions": _VERSIONS,
    "plant_construction_adoptions": [],
}

_CAP = [{"app_user_id": 2, "status": "active",
         "capabilities": {"capability_key": "read_construction_library"}}]

WITH_CAP_EMPTY_ROWS = {
    "app_users": [{"id": 2, "auth_user_id": "auth-uuid", "display_name": "HasCap", "status": "active"}],
    "group_capability_grants": _CAP,
    "plant_capability_grants": [],
    "constructions": [], "construction_versions": [], "plant_construction_adoptions": [],
}

WITH_CAP_ROWS = {
    "app_users": [{"id": 2, "auth_user_id": "auth-uuid", "display_name": "HasCap", "status": "active"}],
    "group_capability_grants": _CAP,
    "plant_capability_grants": [],
    "constructions": _CONSTRUCTIONS,
    "construction_versions": _VERSIONS,
    "plant_construction_adoptions": [
        {"id": 1, "plant_id": 7, "construction_version_id": 41, "status": "adopted", "adopted_by": 3},
        # Orphan: points at a version this caller cannot read. Must be DROPPED,
        # never rendered as a bare construction_version_id.
        {"id": 2, "plant_id": 7, "construction_version_id": 999, "status": "adopted", "adopted_by": 3},
    ],
}

# The capability is held and the adoption read SUCCEEDS returning zero rows.
# That is an answer, not a partial result.
WITH_CAP_NO_ADOPTIONS = dict(WITH_CAP_ROWS, plant_construction_adoptions=[])

ROWS = NO_CAP_ROWS


def fake_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return FakeClient(token, ROWS)


cc.get_supabase_for_caller = fake_caller

WORKER_CLIENTS = []
FAIL_ON_TABLE = None


class WorkerReadFailure(RuntimeError):
    pass


class FailingQuery(FakeQuery):
    def execute(self):
        CALLS.append((self.token, self.table, self.cols))
        if FAIL_ON_TABLE is not None and self.table == FAIL_ON_TABLE:
            raise WorkerReadFailure(f"synthetic failure reading {self.table}")
        return type("R", (), {"data": _project(self.cols, self.rows)})()


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

# ------------------------------------------------------------- CL-1 anon
with app.test_client() as c:
    r = c.get("/masters/constructions")
check(r.status_code == 401, "CL-1 anonymous request refused 401")

# ------------------------------------ CL-2 active caller, no capability
ROWS = NO_CAP_ROWS
CALLS.clear()
with app.test_client() as c:
    r = c.get("/masters/constructions", headers=AUTH)
check(r.status_code == 403,
      "CL-2 an active caller without read_construction_library is refused 403")
check(not any(t == "constructions" for _, t, _ in CALLS),
      "CL-2a and no master table is queried before the capability check refuses")
body = r.get_data(as_text=True)
check("constructions" not in (r.get_json() or {}),
      "CL-2b the denial is NOT an empty list - 'you may not see them' never reads as 'none exist'")
check("read_construction_library" in body,
      "CL-2c and the denial names the capability required")

# --------------------------------- CL-3 authorized, genuinely empty master
ROWS = WITH_CAP_EMPTY_ROWS
with app.test_client() as c:
    r = c.get("/masters/constructions", headers=AUTH)
payload = r.get_json()
check(r.status_code == 200, "CL-3 an authorized caller is served 200")
check(payload["constructions"] == [],
      "CL-3a an empty master is an empty list - reachable ONLY with the capability")
check(payload["adoptions_partial"] is False,
      "CL-3b and an empty master is not a partial read")

# ------------------------------------------ CL-4 shape and no over-select
ROWS = WITH_CAP_ROWS
CALLS.clear()
with app.test_client() as c:
    r = c.get("/masters/constructions", headers=AUTH)
payload = r.get_json()
con = payload["constructions"][0]
ver = con["versions"][0]

check(con["construction_code"] == "CON-000125" and con["status"] == "published",
      "CL-4 construction identity and status are returned")
check(ver["version_no"] == 2 and ver["ply"] == 5 and ver["board_gsm"] == 780,
      "CL-4a version identity, ply and board GSM are returned")
check(ver["approved"] is True and "approved_at" not in ver,
      "CL-4b approval is a derived boolean; the timestamp is not exposed")

_selected = " ".join(str(c or "") for _, t, c in CALLS if t in
                     ("constructions", "construction_versions", "plant_construction_adoptions"))
check("created_by" not in _selected,
      "CL-4c created_by is never selected")
check("adopted_by" not in _selected,
      "CL-4d adopted_by is never selected")
check("approved_by" not in _selected,
      "CL-4e approved_by is never selected")
_flat = str(payload)
check("created_by" not in _flat and "adopted_by" not in _flat and "approved_by" not in _flat,
      "CL-4f and no actor attribution reaches the response body")

# The five layer pairs: the compact technical stack that distinguishes versions.
layers = {l["layer"]: l for l in ver["layers"]}
check([l["layer"] for l in ver["layers"]] == ["TOP", "F1", "L1", "F2", "L2"],
      "CL-4g all five layers are returned in fixed TOP-to-L2 order")
check(layers["TOP"]["code"] == "24" and layers["TOP"]["gsm"] == 180,
      "CL-4h each layer carries BOTH its code and its GSM")
check(layers["F2"]["code"] == "20" and layers["L2"]["gsm"] == 180,
      "CL-4i including the 5-ply-only layers")

# ------------------------------------------------- CL-5 adoption handling
check(len(ver["adoptions"]) == 1 and ver["adoptions"][0]["plant_id"] == 7,
      "CL-5 adoption is attached to the version it belongs to")
check(all(a["construction_version_id"] != 999
          for v in con["versions"] for a in [dict(x, construction_version_id=None)
                                             for x in v["adoptions"]]),
      "CL-5a the orphan adoption is dropped, not rendered as a bare identifier")
check("999" not in str(payload),
      "CL-5b and the unreadable version's identifier never reaches the client")
check("plant_id" in ver["adoptions"][0] and "name" not in ver["adoptions"][0],
      "CL-5c adoption carries plant_id only - this route does not invent plant identity")
check(not any(t == "plants" for _, t, _ in CALLS),
      "CL-5d and it does not read the Plants table, so it claims no relationship it did not fetch")

# ------------------------------- CL-6 adoptions_partial - the exact meaning
check(payload["adoptions_partial"] is False,
      "CL-6 a SUCCESSFUL adoption read is not partial")

ROWS = WITH_CAP_NO_ADOPTIONS
with app.test_client() as c:
    r = c.get("/masters/constructions", headers=AUTH)
payload = r.get_json()
check(payload["adoptions_partial"] is False,
      "CL-6a zero caller-visible adoptions is an ANSWER, not a partial result")
check(payload["constructions"][0]["versions"][0]["adoptions"] == [],
      "CL-6b and the version simply has no adoptions")

ROWS = WITH_CAP_ROWS
FAIL_ON_TABLE = "plant_construction_adoptions"
with app.test_client() as c:
    r = c.get("/masters/constructions", headers=AUTH)
payload = r.get_json()
check(r.status_code == 200,
      "CL-6c a FAILED optional adoption read still serves the screen")
check(payload["adoptions_partial"] is True,
      "CL-6d and it is reported as partial - true ONLY on failure")
check(len(payload["constructions"]) == 1,
      "CL-6e the required construction data is still returned in full")
check("synthetic failure" not in r.get_data(as_text=True),
      "CL-6f the raw failure text does not leak to the client")
FAIL_ON_TABLE = None

# --------------------- CL-7 a REQUIRED read failure is NOT partial success
app.config["PROPAGATE_EXCEPTIONS"] = False
for failing in ("constructions", "construction_versions"):
    FAIL_ON_TABLE = failing
    with app.test_client() as c:
        r = c.get("/masters/constructions", headers=AUTH)
    payload = r.get_json() or {}
    check(r.status_code >= 500,
          f"CL-7 a failed REQUIRED read ('{failing}') is an error, not a degraded success")
    check(payload.get("adoptions_partial") is not True,
          f"CL-7a and it is never reported as adoptions_partial ('{failing}')")
    check("constructions" not in payload,
          f"CL-7b no partial result set is returned when '{failing}' fails")
FAIL_ON_TABLE = None
app.config["PROPAGATE_EXCEPTIONS"] = None

# ------------------------------------------------------ CL-8 caller context
check(all(tok == "tok-x" for tok, _, _ in CALLS),
      "CL-8 every read carries the CALLER's token - no service-role client is used")
check(len(WORKER_CLIENTS) >= 2,
      "CL-8a each parallel read gets its own client, never a shared one")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("constructions route gate PASS")
