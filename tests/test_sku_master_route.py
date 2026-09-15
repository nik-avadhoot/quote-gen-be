"""U2 caller-scoped, read-only SKU Master route gate.

Run:  venv/Scripts/python.exe tests/test_sku_master_route.py

Hermetic and offline, same convention as tests/test_constructions_route.py and
tests/test_pricing_basis_route.py. The fake applies eq / in / ilike / limit
filters for real, so a filter the route forgets to push into the query changes
the result instead of passing silently. What this proves is the ROUTE: status
codes, error codes, which client and columns, which filters, how optional
reads degrade. Row visibility itself is RLS (has_plant_cap(plant_id,
'plant_access')), proved by the S4-2 database suites.

WHAT EACH GROUP WOULD CATCH:

  SKU-2   a caller with no plant_access served 200 [] - "no SKUs exist" is false.
  SKU-3   make_quote alone treated as SKU read scope, or an unscoped plant query.
  SKU-4   party/Family reads issued without read_party_master, letting RLS turn
          a denial into "no customer" for a NOT NULL party_id.
  SKU-5/6 unvalidated or in-memory filters; a literal `_` search matching as a
          LIKE wildcard.
  SKU-8   an unbounded catalogue, or a silent truncation.
  SKU-9   blank/zero collapse, or a stale (non-current) Family label.
  SKU-10  actor attribution leaking into selected columns or the body.
  SKU-12+ construction, adoption, location or lineage detail guessed when the
          caller cannot read it or the read failed.
"""
import os
import re
import sys

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402

PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


CALLS = []
FAIL_TABLE = None
RAISE_API_ERROR = False
CALLER = None
_PLAIN = re.compile(r"^[a-z_][a-z0-9_]*$")


def project(columns, rows):
    wanted = [c.strip() for c in str(columns or "").split(",")]
    if not wanted or not all(_PLAIN.match(c) for c in wanted):
        return rows
    return [{key: row[key] for key in wanted if key in row} for row in rows]


def like_regex(pattern):
    out, i = "", 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "\\" and i + 1 < len(pattern):
            out += re.escape(pattern[i + 1])
            i += 2
            continue
        out += ".*" if ch == "%" else "." if ch == "_" else re.escape(ch)
        i += 1
    return re.compile("^" + out + "$", re.I | re.S)


def matches(row, flt):
    kind, col, val = flt
    if kind == "eq":
        return row.get(col) == val
    if kind == "in":
        return row.get(col) in val
    if kind == "ilike":
        return row.get(col) is not None and like_regex(val).match(str(row.get(col))) is not None
    return True


class FakeQuery:
    def __init__(self, token, table):
        self.token, self.table = token, table
        self.columns, self.filters, self.limit_n = None, [], None

    def select(self, columns):
        self.columns = columns
        return self

    def eq(self, col, val):
        self.filters.append(("eq", col, val))
        return self

    def in_(self, col, vals):
        self.filters.append(("in", col, list(vals)))
        return self

    def ilike(self, col, pattern):
        self.filters.append(("ilike", col, pattern))
        return self

    def order(self, col, **_kw):
        self.filters.append(("order", col, None))
        return self

    def limit(self, n):
        self.limit_n = n
        return self

    def execute(self):
        CALLS.append({"token": self.token, "table": self.table, "columns": self.columns,
                      "filters": list(self.filters), "limit": self.limit_n})
        if self.table == FAIL_TABLE:
            if RAISE_API_ERROR:
                raise server.APIError({"code": "42501", "message": "permission denied"})
            raise RuntimeError(f"synthetic failure reading {self.table}")
        rows = [r for r in ROWS.get(self.table, []) if all(matches(r, f) for f in self.filters)]
        if self.limit_n is not None:
            rows = rows[:self.limit_n]
        return type("Response", (), {"data": project(self.columns, rows)})()


class FakeAuth:
    def get_user(self, token):
        user = type("User", (), {"id": "auth-uuid", "email": "npd@example.invalid"})()
        return type("AuthResponse", (), {"user": user})()


class FakeClient:
    def __init__(self, token):
        self.token, self.auth = token, FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name)


def fake_client(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return FakeClient(token)


cc.get_supabase_for_caller = fake_client
cc.new_caller_client = fake_client

import server  # noqa: E402
import auth as auth_mod  # noqa: E402

server.get_supabase_for_caller = fake_client
server.new_caller_client = fake_client
auth_mod.get_supabase_for_caller = fake_client
auth_mod.resolve_caller = lambda _token, known_auth_uid=None: CALLER
server.privileged_client = lambda _operation: (_ for _ in ()).throw(
    AssertionError("SKU Master reads must never request a privileged client"))

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-u2-sku"}

BASE_ROWS = {
    "plants": [
        {"id": 7, "plant_code": "NAG", "name": "Nagpur", "status": "active"},
        {"id": 8, "plant_code": "PUN", "name": "Pune", "status": "active"},
    ],
    # Actor attribution is present ON PURPOSE so the projection checks can fail.
    "skus": [
        {"id": 101, "plant_id": 7, "party_id": 501, "plant_item_code": "NAG-IT-0001", "status": "active",
         "replacement_sku_id": None, "content_version": 2, "created_by": 3},
        {"id": 102, "plant_id": 7, "party_id": 501, "plant_item_code": None, "status": "proposed",
         "replacement_sku_id": None, "content_version": 1, "created_by": 3},
        {"id": 103, "plant_id": 7, "party_id": 502, "plant_item_code": "NAG_IT_0003", "status": "discontinued",
         "replacement_sku_id": 101, "content_version": 4, "created_by": 3},
        {"id": 104, "plant_id": 7, "party_id": 502, "plant_item_code": "NAG-IT-0004", "status": "discontinued",
         "replacement_sku_id": 999, "content_version": 3, "created_by": 3},
        {"id": 201, "plant_id": 8, "party_id": 503, "plant_item_code": "PUN-IT-0001", "status": "active",
         "replacement_sku_id": None, "content_version": 1, "created_by": 3},
    ],
    "sku_versions": [
        {"id": 1001, "sku_id": 101, "plant_id": 7, "version_no": 1, "construction_version_id": 41,
         "is_price_driving": True, "length_mm": 300.0, "width_mm": 200.0, "height_mm": 0, "box_type": "RSC",
         "ups": 1, "spec_bs": None, "spec_bct": 0, "spec_ect": None,
         "approved_at": "2026-09-01T00:00:00Z", "approved_by": 3, "created_by": 3},
        {"id": 1002, "sku_id": 101, "plant_id": 7, "version_no": 2, "construction_version_id": 42,
         "is_price_driving": False, "length_mm": 300.0, "width_mm": 200.0, "height_mm": None, "box_type": "RSC",
         "ups": 2, "spec_bs": 12.5, "spec_bct": None, "spec_ect": 0,
         "approved_at": None, "approved_by": None, "created_by": 3},
        {"id": 1003, "sku_id": 103, "plant_id": 7, "version_no": 1, "construction_version_id": 41,
         "is_price_driving": True, "length_mm": 250.0, "width_mm": 150.0, "height_mm": 0, "box_type": "RSC",
         "ups": 1, "spec_bs": None, "spec_bct": None, "spec_ect": None,
         "approved_at": "2026-08-01T00:00:00Z", "approved_by": 3, "created_by": 3},
    ],
    "sku_external_references": [
        {"id": 1, "sku_id": 101, "plant_id": 7, "reference_kind": "customer_item_code",
         "reference_value": "CUST-778", "status": "active", "created_by": 3},
        {"id": 2, "sku_id": 101, "plant_id": 7, "reference_kind": "alias",
         "reference_value": "Old carton", "status": "withdrawn", "created_by": 3},
    ],
    "sku_location_applicabilities": [
        {"id": 11, "sku_id": 101, "plant_id": 7, "party_id": 501, "location_id": 601, "scope": "master",
         "status": "approved", "approved_at": "2026-09-02T00:00:00Z", "approved_by": 3, "created_by": 3},
        {"id": 12, "sku_id": 101, "plant_id": 7, "party_id": 501, "location_id": 602, "scope": "batch_only",
         "status": "proposed", "approved_at": None, "approved_by": None, "created_by": 3},
    ],
    "parties": [
        {"id": 501, "customer_code": "CUST-501", "display_name": "Fixture Distillers Unit 1",
         "lifecycle_state": "customer", "status": "active", "created_by": 3},
        {"id": 502, "customer_code": None, "display_name": "Fixture Prospect",
         "lifecycle_state": "prospect", "status": "proposed", "created_by": 3},
    ],
    "party_family_memberships": [
        {"party_id": 501, "family_id": 202, "is_current": True},
        {"party_id": 501, "family_id": 909, "is_current": False},
        {"party_id": 502, "family_id": 203, "is_current": True},
        {"party_id": 777, "family_id": 910, "is_current": False},
    ],
    "customer_families": [
        {"id": 202, "group_customer_code": "FAM-202", "name": "Fixture Distillers", "status": "active"},
        {"id": 203, "group_customer_code": None, "name": "Fixture Prospects", "status": "proposed"},
        {"id": 909, "group_customer_code": "FAM-OLD", "name": "Former Family", "status": "active"},
    ],
    "customer_locations": [
        {"id": 601, "party_id": 501, "location_code": "LOC-601", "status": "active",
         "bill_to_eligible": True, "ship_to_eligible": True, "created_by": 3},
    ],
    "construction_versions": [
        {"id": 41, "construction_id": 5, "version_no": 2, "ply": 5, "flute_f1": "B", "flute_f2": "A",
         "board_gsm": 780, "approved_at": "2026-02-01T00:00:00Z", "approved_by": 3},
    ],
    "constructions": [
        {"id": 5, "construction_code": "CON-000125", "name": "5-ply BC RSC", "status": "published"},
    ],
    "plant_construction_adoptions": [
        {"construction_version_id": 41, "plant_id": 7, "status": "adopted", "adopted_by": 3},
        {"construction_version_id": 41, "plant_id": 8, "status": "adopted", "adopted_by": 3},
    ],
}
ROWS = BASE_ROWS

NONE = {"id": 1, "active": True, "plant_capabilities": {}, "group_capabilities": []}
# make_quote at PUN WITHOUT plant_access there: not SKU read scope.
MAKER = {"id": 2, "active": True,
         "plant_capabilities": {"NAG": ["make_quote", "plant_access"], "PUN": ["make_quote"]},
         "group_capabilities": []}
FULL = {"id": 3, "active": True,
        "plant_capabilities": {"NAG": ["plant_access"], "PUN": ["plant_access"]},
        "group_capabilities": ["read_party_master", "read_construction_library"]}


def get(path):
    CALLS.clear()
    with app.test_client() as client:
        response = client.get(path, headers=AUTH)
    return response, (response.get_json(silent=True) or {})


def calls_to(table):
    return [c for c in CALLS if c["table"] == table]


# ─────────────────────────────────────────────────────────── SKU-1 anonymous
with app.test_client() as client:
    check(client.get("/masters/skus").status_code == 401
          and client.get("/masters/skus/101").status_code == 401,
          "SKU-1 anonymous catalogue and detail requests are refused 401")

# ─────────────────────────────────────────────── SKU-2 no plant_access at all
CALLER = NONE
r, body = get("/masters/skus")
check(r.status_code == 403 and body.get("error_code") == "CAPABILITY_REQUIRED",
      "SKU-2 a caller without plant_access is refused 403 CAPABILITY_REQUIRED")
check("skus" not in body and not CALLS,
      "SKU-2a the denial is not an empty list, and no table is read before it")
check("plant_access" in (body.get("error") or ""),
      "SKU-2b the denial names the capability required")
r, body = get("/masters/skus/101")
check(r.status_code == 403 and body.get("error_code") == "CAPABILITY_REQUIRED" and not CALLS,
      "SKU-2c the detail route refuses the same caller before any read")

# ─────────────────────────────────────────────── SKU-3 plant_access is the scope
CALLER = MAKER
r, body = get("/masters/skus")
check(r.status_code == 200 and body["plant_scope"] == ["NAG"],
      "SKU-3 make_quote without plant_access does not widen SKU read scope")
plant_reads = calls_to("plants")
sku_reads = calls_to("skus")
check(plant_reads and ("in", "plant_code", ["NAG"]) in plant_reads[0]["filters"],
      "SKU-3a plant identity is read only for the caller's plant_access plants")
check(sku_reads and ("in", "plant_id", [7]) in sku_reads[0]["filters"],
      "SKU-3b the SKU query itself is restricted to those plant ids")
check({row["plant"]["plant_code"] for row in body["skus"]} == {"NAG"},
      "SKU-3c no SKU from an out-of-scope plant is returned")

# ───────────────────────────────── SKU-4 party detail needs read_party_master
check(body["detail_visibility"]["customer"] == "not_visible_to_caller"
      and all(row["customer"] is None and row["family"] is None for row in body["skus"]),
      "SKU-4 without read_party_master customer/Family are reported not visible, never empty")
check(not calls_to("parties") and not calls_to("party_family_memberships")
      and not calls_to("customer_families"),
      "SKU-4a and the party/Family reads are not issued at all")

# ──────────────────────────────────────────────────── SKU-5 filter validation
for path, code, label in (
        ("/masters/skus?status=retired", "INVALID_INPUT", "an unknown lifecycle status"),
        ("/masters/skus?q=50%25", "INVALID_INPUT", "a search carrying a LIKE wildcard"),
        ("/masters/skus?q=a,b", "INVALID_INPUT", "a search carrying a PostgREST separator"),
        ("/masters/skus?q=" + "A" * 61, "INVALID_INPUT", "a search longer than 60 characters"),
        ("/masters/skus?party_id=abc", "INVALID_INPUT", "a non-integer party_id"),
        ("/masters/skus?family_id=0", "INVALID_INPUT", "a non-positive family_id")):
    r, body = get(path)
    check(r.status_code == 400 and body.get("error_code") == code and not calls_to("skus"),
          f"SKU-5 {label} is refused 400 {code} before the SKU query")
r, body = get("/masters/skus?plant=PUN")
check(r.status_code == 403 and body.get("error_code") == "CAPABILITY_REQUIRED" and not CALLS,
      "SKU-5a a plant filter outside plant_access scope is a 403, not an empty result")
r, body = get("/masters/skus?family_id=202")
check(r.status_code == 403 and "read_party_master" in (body.get("error") or "") and not CALLS,
      "SKU-5b filtering by Family without read_party_master is refused and names the capability")

# ─────────────────────────────────────────────── SKU-6 filters reach the query
CALLER = FULL
r, body = get("/masters/skus?plant=NAG&status=active")
filters = calls_to("skus")[0]["filters"]
check(("eq", "status", "active") in filters and ("in", "plant_id", [7]) in filters,
      "SKU-6 status and plant filters are pushed into the SKU query")
check([row["id"] for row in body["skus"]] == [101] and body["filters"]["status"] == "active",
      "SKU-6a only the matching SKU returns, and the applied filters are echoed")
r, body = get("/masters/skus?q=IT_0")
check(("ilike", "plant_item_code", "%IT\\_0%") in calls_to("skus")[0]["filters"],
      "SKU-6b the Plant Item Code search is a database ilike with `_` escaped")
check([row["id"] for row in body["skus"]] == [103],
      "SKU-6c a literal `_` search does not match `-` as a wildcard would")
r, body = get("/masters/skus?family_id=202")
check(("eq", "family_id", 202) in calls_to("party_family_memberships")[0]["filters"]
      and ("eq", "is_current", True) in calls_to("party_family_memberships")[0]["filters"],
      "SKU-6d a Family filter resolves CURRENT memberships only")
check(sorted(row["id"] for row in body["skus"]) == [101, 102],
      "SKU-6e and returns only that Family's SKUs")
r, body = get("/masters/skus?family_id=910")
check(r.status_code == 200 and body["skus"] == [] and not calls_to("skus"),
      "SKU-6f a Family with no current members is an empty answer without a SKU query")
r, body = get("/masters/skus?party_id=502&family_id=202")
check(body["skus"] == [] and not calls_to("skus"),
      "SKU-6g contradictory customer and Family filters intersect to an empty answer")

# ────────────────────────────────────────────────────── SKU-7/8 bounded window
r, body = get("/masters/skus")
check(calls_to("skus")[0]["limit"] == 201 and body["truncated"] is False and body["limit"] == 200,
      "SKU-7 the catalogue query is bounded (limit+1) and reports no truncation when under it")
ROWS = dict(BASE_ROWS, skus=[
    {"id": 5000 + i, "plant_id": 7, "party_id": 501, "plant_item_code": f"BULK-{i:04d}",
     "status": "active", "replacement_sku_id": None, "content_version": 1} for i in range(230)])
r, body = get("/masters/skus")
check(len(body["skus"]) == 200 and body["truncated"] is True,
      "SKU-8 more matches than the window returns 200 rows and says truncated")
ROWS = BASE_ROWS

# ────────────────────────────────────────────── SKU-9 catalogue row semantics
r, body = get("/masters/skus?plant=NAG")
by_id = {row["id"]: row for row in body["skus"]}
check(by_id[101]["latest_version"]["version_no"] == 2 and by_id[101]["version_count"] == 2
      and by_id[101]["latest_version"]["approved"] is False,
      "SKU-9 the latest immutable version and its approval state summarise each SKU")
check(by_id[101]["latest_version"]["height_mm"] is None and by_id[103]["latest_version"]["height_mm"] == 0,
      "SKU-9a a missing dimension stays null and an explicit zero stays 0")
check(by_id[102]["plant_item_code"] is None and by_id[102]["latest_version"] is None,
      "SKU-9b an unassigned Plant Item Code and a SKU without versions stay null - nothing is manufactured")
check(by_id[101]["customer"]["display_name"] == "Fixture Distillers Unit 1"
      and by_id[101]["family"]["name"] == "Fixture Distillers",
      "SKU-9c with read_party_master the owner and CURRENT Family are shown, not a former Family")
check(body["detail_visibility"]["customer"] == "visible",
      "SKU-9d and customer detail is reported visible")
codes = [row["plant_item_code"] for row in body["skus"]]
check(codes[-1] is None and codes[:-1] == sorted(codes[:-1]),
      "SKU-9e rows sort by Plant Item Code with unassigned codes last")

# ───────────────────────────────────────── SKU-10 no actor attribution leaks
r, body = get("/masters/skus/101")
selected = " ".join(str(c["columns"]) for c in CALLS)
flat = r.get_data(as_text=True)
check("created_by" not in selected and "approved_by" not in selected and "adopted_by" not in selected,
      "SKU-10 created_by, approved_by and adopted_by are never selected")
check(all(k not in flat for k in ("created_by", "approved_by", "adopted_by", "approved_at")),
      "SKU-10a and no actor or approval timestamp reaches the response; approval is a boolean")

# ───────────────────────────────────────────────────────── SKU-11 not found
r, body = get("/masters/skus/424242")
check(r.status_code == 404 and body.get("error_code") == "RECORD_NOT_FOUND",
      "SKU-11 an absent or not-visible SKU is 404 RECORD_NOT_FOUND")

# ─────────────────────────────────────── SKU-12 versions and specifications
r, body = get("/masters/skus/101")
versions = body["versions"]
check([v["version_no"] for v in versions] == [1, 2] and versions[0]["approved"] is True
      and versions[1]["approved"] is False,
      "SKU-12 every immutable version is returned in order with its approval state")
spec1, spec2 = versions[0]["specification"], versions[1]["specification"]
check(spec1["height_mm"] == 0 and spec1["spec_bct"] == 0 and spec1["spec_bs"] is None
      and spec2["height_mm"] is None and spec2["spec_ect"] == 0 and spec2["ups"] == 2,
      "SKU-12a specification values keep blank-versus-zero exactly")
check(versions[0]["construction"]["construction_code"] == "CON-000125"
      and versions[0]["construction"]["version_no"] == 2 and versions[0]["construction"]["approved"] is True,
      "SKU-12b the exact Construction and Construction version identity is returned")
check(versions[1]["construction"] is None and versions[1]["construction_version_id"] == 42,
      "SKU-12c an unreadable Construction version is null with its id, never a guessed or current Construction")
check(versions[0]["plant_adoption"] == ["adopted"] and versions[1]["plant_adoption"] == [],
      "SKU-12d plant adoption is for the SKU's OWN plant only")
check(body["unrecorded_specification_fields"] == ["printing_technology", "number_of_colours"]
      and "printing_technology" not in spec1 and "number_of_colours" not in spec1,
      "SKU-12e Printing Technology and colour count are declared unrecorded, not manufactured")
check(body["detail_visibility"] == {"customer": "visible", "construction": "visible",
                                    "plant_adoption": "visible", "locations": "visible"},
      "SKU-12f detail visibility is reported per section")

# ─────────────────────────────── SKU-13 references and Location applicability
refs = body["external_references"]
check([(x["reference_kind"], x["reference_value"], x["status"]) for x in refs]
      == [("customer_item_code", "CUST-778", "active"), ("alias", "Old carton", "withdrawn")],
      "SKU-13 external references keep their kind, value and withdrawn status")
apps = {a["location_id"]: a for a in body["location_applicability"]}
check(apps[601]["scope"] == "master" and apps[601]["approved"] is True
      and apps[601]["location"]["location_code"] == "LOC-601",
      "SKU-13a an approved master applicability carries its Location identity")
check(apps[602]["scope"] == "batch_only" and apps[602]["approved"] is False and apps[602]["location"] is None,
      "SKU-13b a Location the caller cannot read is null, not invented")

# ──────────────────────────────────────────────────────── SKU-14 lineage
check(body["lineage"]["replaces"] == [{"id": 103, "plant_item_code": "NAG_IT_0003", "status": "discontinued"}]
      and body["lineage"]["replaced_by"] is None and body["lineage"]["replacement_visible"] is True,
      "SKU-14 a replacement SKU lists what it replaces")
r, body = get("/masters/skus/103")
check(body["lineage"]["replaced_by"] == {"id": 101, "plant_item_code": "NAG-IT-0001", "status": "active"},
      "SKU-14a a discontinued SKU links its replacement, never silently substitutes it")
r, body = get("/masters/skus/104")
check(body["lineage"]["replaced_by"] is None and body["lineage"]["replacement_visible"] is False,
      "SKU-14b a replacement the caller cannot read is reported not visible")

# ─────────────────────────────── SKU-15 a Maker sees the SKU, not the masters
CALLER = MAKER
r, body = get("/masters/skus/101")
check(r.status_code == 200 and body["detail_visibility"]["construction"] == "not_visible_to_caller"
      and body["detail_visibility"]["locations"] == "not_visible_to_caller"
      and body["detail_visibility"]["customer"] == "not_visible_to_caller",
      "SKU-15 without the group read capabilities each section says not visible")
check(not calls_to("construction_versions") and not calls_to("constructions")
      and not calls_to("customer_locations") and not calls_to("parties"),
      "SKU-15a and those group-gated reads are never issued")
check(all(v["construction"] is None and v["construction_version_id"] in (41, 42) for v in body["versions"])
      and body["sku"]["customer"] is None,
      "SKU-15b versions keep their Construction version identity without a guessed label")

# ─────────────────────────────────────────── SKU-16 optional reads degrade
CALLER = FULL
FAIL_TABLE = "parties"
r, body = get("/masters/skus")
check(r.status_code == 200 and body["detail_visibility"]["customer"] == "unavailable" and body["skus"]
      and all(row["customer"] is None for row in body["skus"]),
      "SKU-16 a failed party read degrades to 'unavailable', and SKUs are still served")
check("synthetic failure" not in r.get_data(as_text=True),
      "SKU-16a the raw failure never reaches the client")
FAIL_TABLE = "constructions"
r, body = get("/masters/skus/101")
check(r.status_code == 200 and body["detail_visibility"]["construction"] == "unavailable"
      and all(v["construction"] is None for v in body["versions"]),
      "SKU-16b a failed Construction read is 'unavailable', not a partial guessed label")
FAIL_TABLE = "plant_construction_adoptions"
r, body = get("/masters/skus/101")
check(body["detail_visibility"]["plant_adoption"] == "unavailable"
      and all(v["plant_adoption"] is None for v in body["versions"]),
      "SKU-16c a failed adoption read is null, never 'not adopted'")
FAIL_TABLE = "customer_locations"
r, body = get("/masters/skus/101")
check(body["detail_visibility"]["locations"] == "unavailable",
      "SKU-16d a failed Location read is 'unavailable'")

# ─────────────────────────────────────── SKU-17 required reads are errors
app.config["PROPAGATE_EXCEPTIONS"] = False
for path, table in (("/masters/skus", "skus"), ("/masters/skus/101", "skus"),
                    ("/masters/skus/101", "sku_versions")):
    FAIL_TABLE = table
    r, body = get(path)
    check(r.status_code >= 500 and "skus" not in body and "versions" not in body,
          f"SKU-17 a failed REQUIRED read ({table} on {path}) is an error, not a degraded success")
app.config["PROPAGATE_EXCEPTIONS"] = None
RAISE_API_ERROR = True
FAIL_TABLE = "skus"
r, body = get("/masters/skus")
check(r.status_code == 403 and body.get("error_code") == "CAPABILITY_REQUIRED",
      "SKU-17a a database 42501 maps to the stable CAPABILITY_REQUIRED code")
RAISE_API_ERROR = False
FAIL_TABLE = None

# ─────────────────────────────────────── SKU-18 caller authority, read-only
r, body = get("/masters/skus/101")
check(CALLS and all(c["token"] == "tok-u2-sku" for c in CALLS),
      "SKU-18 every read carries the caller's token; no privileged client is requested")
check(body["mutations"] == "none" and body["authority"] == "caller_token_rls_only",
      "SKU-18a the response declares itself read-only and caller-token scoped")
with app.test_client() as client:
    check(client.post("/masters/skus", headers=AUTH, json={}).status_code == 405
          and client.patch("/masters/skus/101", headers=AUTH, json={}).status_code == 405,
          "SKU-18b no create or edit method exists on the SKU Master routes")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("SKU Master route gate PASS")
