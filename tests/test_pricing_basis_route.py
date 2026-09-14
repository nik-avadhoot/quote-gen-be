"""U3 caller-scoped, read-only Pricing Basis route gate.

Run: python tests/test_pricing_basis_route.py
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
ROWS = {}
FAIL_TABLE = None
CALLER = None
_PLAIN = re.compile(r"^[a-z_][a-z0-9_]*$")


def project(columns, rows):
    wanted = [c.strip() for c in str(columns or "").split(",")]
    if not wanted or not all(_PLAIN.match(c) for c in wanted):
        return rows
    return [{key: row[key] for key in wanted if key in row} for row in rows]


class FakeQuery:
    def __init__(self, token, table):
        self.token, self.table, self.columns = token, table, None

    def select(self, columns):
        self.columns = columns
        return self

    def execute(self):
        CALLS.append((self.token, self.table, self.columns))
        if self.table == FAIL_TABLE:
            raise RuntimeError(f"synthetic failure: {self.table}")
        return type("Response", (), {"data": project(self.columns, ROWS.get(self.table, []))})()


class FakeAuth:
    def get_user(self, token):
        user = type("User", (), {"id": "auth-uuid", "email": "maker@example.invalid"})()
        return type("AuthResponse", (), {"user": user})()


class FakeClient:
    def __init__(self, token):
        self.token, self.auth = token, FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name)


def fake_client(token):
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
    AssertionError("Pricing Basis reads must never request a privileged client"))

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-u3"}

with app.test_client() as client:
    response = client.get("/masters/pricing-basis-releases")
check(response.status_code == 401, "PB-UI-1 anonymous request is refused")

CALLER = {"id": 1, "active": True, "plant_capabilities": {}, "group_capabilities": []}
CALLS.clear()
with app.test_client() as client:
    response = client.get("/masters/pricing-basis-releases", headers=AUTH)
check(response.status_code == 403, "PB-UI-2 caller without plant_access receives an explicit denial")
check(not any(table == "pricing_basis_releases" for _, table, _ in CALLS),
      "PB-UI-2a denial happens before a release read")

CALLER = {"id": 2, "active": True,
          "plant_capabilities": {"NAG": ["plant_access", "make_quote"]},
          "group_capabilities": ["read_party_master"]}
ROWS = {"pricing_basis_releases": []}
CALLS.clear()
with app.test_client() as client:
    response = client.get("/masters/pricing-basis-releases", headers=AUTH)
payload = response.get_json()
check(response.status_code == 200 and payload["releases"] == [],
      "PB-UI-3 genuine caller-visible absence is an empty state")
check(payload["components_partial"] is False and len(CALLS) == 1,
      "PB-UI-3a empty state is complete and skips meaningless supporting reads")

ROWS = {
    "pricing_basis_releases": [{
        "id": 11, "plant_id": 7, "release_name": "Nagpur Standard",
        "effective_from": "2026-09-01", "effective_until": None,
        "is_automatic_default": True, "rate_set_version_id": 21,
        "freight_set_version_id": 31, "sector_version_id": 41,
        "calculation_default_version_id": 51, "status": "approved",
        "self_approved": False, "approved_at": "2026-08-29T09:30:00Z",
        "created_at": "2026-08-27T09:00:00Z", "withdrawn_at": None,
        "proposed_by": 90, "approved_by": 91,
    }],
    "plants": [{"id": 7, "plant_code": "NAG", "name": "Nagpur", "status": "active"}],
    "rate_sets": [{"id": 20, "plant_id": 7, "name": "Board Rates", "status": "active",
                   "created_by": 90}],
    "rate_set_versions": [{"id": 21, "rate_set_id": 20, "plant_id": 7, "version_no": 4,
                           "status": "approved", "approved_at": "2026-08-28T00:00:00Z",
                           "approved_by": 91, "credit_cost_pct": "1.500"},
                          {"id": 22, "rate_set_id": 20, "plant_id": 7, "version_no": 5,
                           "status": "draft", "approved_at": None, "credit_cost_pct": "1.500"},
                          {"id": 19, "rate_set_id": 20, "plant_id": 7, "version_no": 3,
                           "status": "withdrawn", "approved_at": "2026-07-01T00:00:00Z",
                           "credit_cost_pct": "1.500"}],
    "rate_entries": [{"id": 210, "rate_set_version_id": 21, "plant_id": 7,
                      "grade_code": "KRAFT-180", "description": "Kraft liner",
                      "price": "42.0000", "discount": "1.2500", "freight": "0.7500",
                      "interest_pct": None, "effective_material_rate": "42.1300"},
                     {"id": 211, "rate_set_version_id": 21, "plant_id": 7,
                      "grade_code": "FLUTE-150", "description": None,
                      "price": "38.0000", "discount": "0.5000", "freight": "0.0000",
                      "interest_pct": "0.000", "effective_material_rate": "37.5000"}],
    "freight_sets": [{"id": 30, "plant_id": 7, "name": "Freight Matrix", "status": "active"}],
    "freight_set_versions": [{"id": 31, "freight_set_id": 30, "plant_id": 7, "version_no": 3,
                              "effective_from": "2026-09-01", "status": "approved",
                              "approved_at": "2026-08-28T00:00:00Z"},
                             {"id": 32, "freight_set_id": 30, "plant_id": 7, "version_no": 4,
                              "effective_from": "2026-10-01", "status": "draft",
                              "approved_at": None}],
    "freight_entries": [{"id": 310, "freight_set_version_id": 31, "plant_id": 7,
                         "origin_plant_id": 7, "destination_location_id": 61,
                         "rate": "0.0000"}],
    "customer_locations": [{"id": 61, "party_id": 71, "location_code": "NAG-LOCAL",
                            "ship_to_eligible": True, "status": "active"}],
    "parties": [{"id": 71, "customer_code": "CUST-1", "display_name": "Customer One",
                 "lifecycle_state": "live", "status": "active"}],
    "sectors": [{"id": 40, "sector_code": "PHARMA", "name": "Pharmaceuticals", "status": "active"}],
    "sector_versions": [{"id": 41, "sector_id": 40, "version_no": 3,
                         "waste_cbb_pct": "5.000", "waste_pp_pct": "0.000",
                         "conv_box_rate": None, "conv_pp_rate": "12.5000", "margin_pct": "8.000",
                         "status": "approved", "approved_at": "2026-08-28T00:00:00Z"},
                        {"id": 42, "sector_id": 40, "version_no": 4,
                         "status": "draft", "approved_at": None},
                        {"id": 39, "sector_id": 40, "version_no": 2,
                         "status": "superseded", "approved_at": "2026-07-01T00:00:00Z"}],
    "calculation_default_versions": [{"id": 51, "version_no": 7,
                                      "annual_interest_pct": "6.000", "day_count_basis": 360,
                                      "interest_fallback_pct": "0.500",
                                      "waste_cbb_fallback_pct": "5.000",
                                      "waste_pp_fallback_pct": "5.000",
                                      "conv_box_fallback_rate": "7.0000",
                                      "conv_pp_fallback_rate": "12.5000",
                                      "margin_fallback_pct": "8.000", "rounding_step": "0.0500",
                                      "engine_version": "engine/qe1-7c2ceac1972460ba",
                                      "rounding_rule_version": "round/nearest-0.05",
                                      "status": "approved", "approved_at": "2026-08-28T00:00:00Z"},
                                     {"id": 52, "version_no": 8,
                                      "status": "draft", "approved_at": None},
                                     {"id": 49, "version_no": 6,
                                      "status": "superseded", "approved_at": "2026-07-01T00:00:00Z"}],
}
CALLS.clear()
with app.test_client() as client:
    response = client.get("/masters/pricing-basis-releases", headers=AUTH)
payload = response.get_json()
release = payload["releases"][0]
check(response.status_code == 200 and release["plant"]["plant_code"] == "NAG",
      "PB-UI-4 release identity and governed plant identity are composed")
check(release["created_at"] == "2026-08-27T09:00:00Z"
      and release["approved_at"] == "2026-08-29T09:30:00Z",
      "PB-UI-4a0 draft/proposal and approval lifecycle dates remain distinct")
check(release["components"]["rate"]["set_name"] == "Board Rates"
      and release["components"]["freight"]["version_no"] == 3,
      "PB-UI-4a exact Rate and Freight versions are named")
rate = release["components"]["rate"]
freight = release["components"]["freight"]
check(rate["set_id"] == 20 and rate["id"] == 21 and len(rate["history"]) == 3,
      "PB-UI-4b Rate Set/version identity and draft-approved-withdrawn history are exact")
check(rate["owning_plant"]["plant_code"] == "NAG"
      and freight["owning_plant"]["plant_code"] == "NAG",
      "PB-UI-4b1 Rate and Freight ownership are caller-visible and plant-specific")
check(rate["entries"][0]["grade_code"] == "FLUTE-150"
      and rate["entries"][0]["effective_material_rate"] == "37.5000"
      and rate["entries"][0]["effective_supplier_credit_pct"] == "0.000",
      "PB-UI-4c grade rates preserve governed effective rate and explicit-zero upstream exception")
check(rate["entries"][1]["supplier_credit_source"] == "version_default"
      and rate["entries"][1]["effective_supplier_credit_pct"] == "1.500",
      "PB-UI-4d upstream Rate Master derivation names inherited supplier-credit provenance")
check(freight["set_id"] == 30 and freight["id"] == 31
      and freight["entries"][0]["explicit_zero"] is True,
      "PB-UI-4e Freight Set/version identity preserves an explicit zero lane")
check(freight["entries"][0]["origin_plant"]["plant_code"] == "NAG"
      and freight["entries"][0]["destination"]["location_code"] == "NAG-LOCAL",
      "PB-UI-4f canonical origin-plant and destination Ship-to lane dimensions are composed")
check(freight["missing_destinations"] == []
      and freight["missing_destinations_available"] is True,
      "PB-UI-4f1 complete destination coverage distinguishes no missing lanes from denied data")
check(release["components"]["sector"]["waste_pp_pct"] == "0.000"
      and release["components"]["sector"]["conv_box_rate"] is None,
      "PB-UI-4g explicit zero remains distinct from inherited null")
check(release["components"]["sector"]["sector_id"] == 40
      and [version["status"] for version in release["components"]["sector"]["history"]]
      == ["draft", "approved", "superseded"],
      "PB-UI-4h Sector identity and lifecycle history are caller-visible")
check(release["components"]["calculation_defaults"]["annual_interest_pct"] == "6.000"
      and release["components"]["calculation_defaults"]["day_count_basis"] == 360,
      "PB-UI-4i independent annual-interest authority is visible")
check([version["status"] for version in
       release["components"]["calculation_defaults"]["history"]]
      == ["draft", "approved", "superseded"],
      "PB-UI-4j Calculation Default lifecycle history is caller-visible")
check(payload["components_partial"] is False and payload["mutations"] == "none",
      "PB-UI-4k complete response is explicitly read-only")
selected = " ".join(str(columns) for _, _, columns in CALLS)
check("created_by" not in selected and "approved_by" not in selected and "proposed_by" not in selected,
      "PB-UI-4l actor foreign keys are not selected")
check("created_by" not in str(payload) and "approved_by" not in str(payload) and "proposed_by" not in str(payload),
      "PB-UI-4m actor foreign keys do not reach the browser response")
check(all(token == "tok-u3" for token, _, _ in CALLS),
      "PB-UI-4n every database read carries the caller token")

FAIL_TABLE = "sector_versions"
with app.test_client() as client:
    response = client.get("/masters/pricing-basis-releases", headers=AUTH)
payload = response.get_json()
check(response.status_code == 200 and payload["components_partial"] is True,
      "PB-UI-5 a supporting-read failure becomes an honest partial state")
check(payload["releases"][0]["components"]["sector"] is None,
      "PB-UI-5a unavailable Sector detail is null, never guessed")
check("synthetic failure" not in response.get_data(as_text=True),
      "PB-UI-5b raw supporting failure text is not exposed")

FAIL_TABLE = "rate_entries"
with app.test_client() as client:
    response = client.get("/masters/pricing-basis-releases", headers=AUTH)
payload = response.get_json()
check(response.status_code == 200 and payload["components_partial"] is True,
      "PB-UI-6 denied Rate entries become an honest partial response")
check(payload["releases"][0]["components"]["rate"] is not None
      and payload["releases"][0]["components"]["rate"]["entries_available"] is False
      and payload["releases"][0]["components"]["rate"]["entries"] == [],
      "PB-UI-6a visible Rate identity survives while denied entries remain absent")

FAIL_TABLE = "customer_locations"
with app.test_client() as client:
    response = client.get("/masters/pricing-basis-releases", headers=AUTH)
payload = response.get_json()
freight = payload["releases"][0]["components"]["freight"]
check(response.status_code == 200 and payload["components_partial"] is True
      and freight["destination_details_partial"] is True,
      "PB-UI-7 denied destination detail is explicitly partial")
check(freight["entries"][0]["destination"] is None
      and freight["entries"][0]["rate"] == "0.0000",
      "PB-UI-7a governed lane rate is retained without fabricating a destination label")
check(freight["missing_destinations_available"] is False
      and freight["missing_destinations"] == [],
      "PB-UI-7b denied destination catalogue never invents missing-lane identities")

FAIL_TABLE = None

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for failure in FAILURES:
        print(f"  FAILED: {failure}")
    sys.exit(1)
print("pricing-basis route gate PASS")
