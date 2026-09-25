"""U5 caller-scoped, read-only governed Quote workspace gate."""
import os
import sys

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402

PASSES, FAILURES = 0, []
CALLER, DENIED = None, set()
CALLS = []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


ROWS = {
    "quote_families": [{"id": 501, "batch_id": 71, "quote_reference": "NAG/QUO/2026-27/00001",
                         "status": "active", "created_at": "2026-09-11T08:00:00Z", "created_by": 4},
                       {"id": 502, "batch_id": 72, "quote_reference": None,
                         "status": "active", "created_at": "2026-09-13T08:00:00Z", "created_by": 4}],
    "batches": [{"id": 71, "batch_reference": "NAG/BAT/2026-27/00071", "family_id": 21,
                  "plant_id": 7, "owner_user_id": 4, "sector_id": 31, "status": "sent",
                  "pricing_date": "2026-09-11", "pricing_basis_release_id": 11,
                  "pricing_basis_is_deliberate": True, "created_at": "2026-09-11T07:00:00Z",
                  "created_by": 4},
                {"id": 72, "batch_reference": "NAG/BAT/2026-27/00072", "family_id": 21,
                  "plant_id": 7, "owner_user_id": 4, "sector_id": 31, "status": "submitted",
                  "pricing_date": "2026-09-13", "pricing_basis_release_id": 11,
                  "pricing_basis_is_deliberate": False, "created_at": "2026-09-13T07:00:00Z",
                  "created_by": 4}],
    "plants": [{"id": 7, "plant_code": "NAG", "name": "Nagpur", "status": "active"}],
    "customer_families": [{"id": 21, "group_customer_code": "FAM-021", "name": "Customer Family",
                            "status": "active"}],
    "quote_revisions": [
        {"id": 601, "family_id": 501, "revision_no": 1, "source_revision_id": None,
         "workflow_status": "approved", "standing": "superseded", "addressee_name": "Buying Team",
         "addressee_details": {}, "quote_date": "2026-09-11", "offer_validity_to": "2026-10-11",
         "approved_by": 5, "approved_at": "2026-09-11T10:00:00Z", "issued_by": None,
         "issued_at": None, "voided_by": None, "voided_at": None, "void_reason": None,
         "withdraw_reason": None, "return_note": None, "created_at": "2026-09-11T08:00:00Z",
         "created_by": 4},
        {"id": 602, "family_id": 501, "revision_no": 2, "source_revision_id": 601,
         "workflow_status": "issued", "standing": "current", "addressee_name": "Buying Team",
         "addressee_details": {}, "quote_date": "2026-09-12", "offer_validity_to": "2026-10-12",
         "approved_by": 5, "approved_at": "2026-09-12T10:00:00Z", "issued_by": 4,
         "issued_at": "2026-09-12T10:30:00Z", "voided_by": None, "voided_at": None,
         "void_reason": None, "withdraw_reason": None, "return_note": "Delivery basis clarified",
         "created_at": "2026-09-12T08:00:00Z", "created_by": 4},
        {"id": 603, "family_id": 502, "revision_no": None, "source_revision_id": None,
         "workflow_status": "submitted", "standing": None, "addressee_name": "Buying Team",
         "addressee_details": {}, "quote_date": "2026-09-13", "offer_validity_to": "2026-10-13",
         "approved_by": None, "approved_at": None, "issued_by": None, "issued_at": None,
         "voided_by": None, "voided_at": None, "void_reason": None,
         "withdraw_reason": None, "return_note": None,
         "created_at": "2026-09-13T08:00:00Z", "created_by": 4},
    ],
    "quote_items": [{"id": 701, "revision_id": 602, "batch_row_lineage_id": 9301,
                     "pricing_group_id": 81, "calculation_snapshot_id": 801},
                    {"id": 702, "revision_id": 603, "batch_row_lineage_id": 9302,
                     "pricing_group_id": 82, "calculation_snapshot_id": 801}],
    "calculation_snapshots": [{
        "id": 801, "schema_version": 1,
        "engine_version": "engine/qe1-7c2ceac1972460ba", "rounding_rule_version": "qe1-rounding-v1",
        "pricing_basis_release_id": 11, "calculation_default_version_id": 41,
        "pricing_date": "2026-09-12", "effective_waste_pct": 5,
        "waste_source": "batch", "conv_source": "batch", "effective_conv_rate": 7,
        "effective_margin_pct": 8, "margin_source": "sector",
        "effective_interest_pct": 0.5, "interest_source": "derived_annual",
        "effective_freight": 0, "freight_source": "master", "freight_authority": "governed",
        "freight_set_version_id": 31, "freight_entry_id": 32, "total_cost": 39.1,
        "final_rate": 43.1, "rate_per_kg": 43.1, "calc_moq": 1000,
        "calculation_fingerprint": "calc-fp-r2", "presentation_fingerprint": "presentation-fp-r2",
        "effective_inputs": {"material_rate": 32, "material_rate_source": "governed_effective_material_rate"},
        "results": {"final_rate": 43.1}, "calculated_by": 4,
        "calculated_at": "2026-09-12T09:00:00Z",
    }],
    "quote_item_delivery_groups": [{"id": 901, "quote_item_id": 701, "delivery_group_id": 91}],
    "quote_workflow_events": [
        {"id": 1001, "revision_id": 602, "event_type": "returned", "actor_user_id": 5,
         "occurred_at": "2026-09-12T08:30:00Z", "note": "Clarify delivery basis"},
        {"id": 1002, "revision_id": 602, "event_type": "approved", "actor_user_id": 5,
         "occurred_at": "2026-09-12T10:00:00Z", "note": None},
    ],
    "customer_outcome_events": [{"id": 1101, "revision_id": 602, "outcome": "awaiting_response",
                                  "acceptance_date": None, "acceptance_reference": None, "note": None,
                                  "recorded_by": 4, "occurred_at": "2026-09-12T10:35:00Z"}],
    "app_users": [{"id": 4, "display_name": "Maker", "status": "active"},
                  {"id": 5, "display_name": "Checker", "status": "active"}],
}


class FakeQuery:
    def __init__(self, token, table):
        self.token, self.table = token, table
        self.columns, self.filters, self.in_filters, self.maximum = "*", [], [], None
        self.ordering = None

    def select(self, columns):
        self.columns = columns
        return self

    def eq(self, column, value):
        self.filters.append((column, value))
        return self

    def in_(self, column, values):
        self.in_filters.append((column, set(values)))
        return self

    def limit(self, maximum):
        self.maximum = maximum
        return self

    def order(self, column, desc=False):
        self.ordering = (column, desc)
        return self

    def execute(self):
        if self.table in DENIED:
            raise server.APIError({"code": "42501", "message": "denied", "details": None, "hint": None})
        CALLS.append((self.token, self.table, tuple(self.filters), tuple(self.in_filters)))
        rows = list(ROWS.get(self.table, []))
        for column, value in self.filters:
            rows = [row for row in rows if str(row.get(column)) == str(value)]
        for column, values in self.in_filters:
            rows = [row for row in rows if row.get(column) in values]
        if self.ordering:
            column, descending = self.ordering
            rows.sort(key=lambda row: row.get(column) or "", reverse=descending)
        if self.maximum is not None:
            rows = rows[:self.maximum]
        wanted = [field.strip() for field in self.columns.split(",")]
        return type("Response", (), {"data": [
            {field: row.get(field) for field in wanted} for row in rows
        ]})()


class FakeAuth:
    def get_user(self, _token):
        user = type("User", (), {"id": "auth-u5", "email": "maker@example.invalid"})()
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
    AssertionError("U5 Quote workspace must never request a privileged client"))

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-u5"}

with app.test_client() as client:
    response = client.get("/quotes/workspace?reference=NAG%2FQUO%2F2026-27%2F00001")
check(response.status_code == 401, "U5-BE-1 anonymous Quote evidence is refused")

CALLER = {"id": 4, "active": True, "plant_capabilities": {"NAG": ["plant_access", "make_quote"]},
          "group_capabilities": []}
with app.test_client() as client:
    response = client.get("/quotes/workspace", headers=AUTH)
check(response.status_code == 400, "U5-BE-2 exactly one governed Quote entry identity is required")

CALLS.clear()
with app.test_client() as client:
    response = client.get("/quotes/workspace?reference=NAG%2FQUO%2F2026-27%2F00001", headers=AUTH)
payload = response.get_json()
quote = payload["quote"]
current = next(row for row in quote["revisions"] if row["standing"] == "current")
snapshot = current["items"][0]["calculation_snapshot"]
check(response.status_code == 200 and payload["authority"] == "caller_token_rls_only",
      "U5-BE-3 the governed Quote opens through the caller-token read surface")
check(quote["quote_reference"] == "NAG/QUO/2026-27/00001"
      and quote["batch"]["batch_reference"] == "NAG/BAT/2026-27/00071"
      and quote["batch"]["plant"]["plant_code"] == "NAG",
      "U5-BE-4 permanent Quote, Batch and Plant identities remain exact")
check([(row["revision_no"], row["standing"]) for row in quote["revisions"]]
      == [(1, "superseded"), (2, "current")]
      and current["source_revision_id"] == 601,
      "U5-BE-5 revision chronology and source lineage are preserved without invention")
check(snapshot["engine_version"] == "engine/qe1-7c2ceac1972460ba"
      and snapshot["calculation_fingerprint"] == "calc-fp-r2"
      and snapshot["presentation_fingerprint"] == "presentation-fp-r2"
      and snapshot["effective_freight"] == 0,
      "U5-BE-6 frozen engine, fingerprints and explicit-zero evidence survive composition")
check(snapshot["calculated_by_actor"]["display_name"] == "Maker"
      and current["approved_by_actor"]["display_name"] == "Checker"
      and current["workflow_events"][0]["event_type"] == "returned",
      "U5-BE-7 caller-visible actors and workflow events retain attribution and time order")
check(all(not action["enabled"] for key, action in quote["actions"].items()
          if key != "record_outcome")
      and all(action["reason"] != "backend_activation_pending"
              for action in quote["actions"].values()),
      "U5-BE-8 an ineligible Quote reports real state-driven action reasons")
check(set(quote["actions"]) == {
          "calculate", "send", "submit", "approve", "return", "withdraw",
          "share", "create_revision", "amend", "reprice", "record_outcome",
      },
      "U5-BE-8a the read contract names the complete accepted pending workflow")
check(quote["actions"]["record_outcome"]["enabled"] is True
      and quote["actions"]["record_outcome"]["reason"] == "available",
      "U5-BE-8c S5: the owning Maker may record a customer outcome on this issued revision")
check(current["items"][0]["pricing_group_id"] == 81
      and current["items"][0]["calculation_snapshot_id"] == 801
      and snapshot["freight_set_version_id"] == 31
      and snapshot["freight_entry_id"] == 32,
      "U5-BE-8b exact Item and governed Freight version identities remain available")
check(CALLS and all(call[0] == "tok-u5" for call in CALLS),
      "U5-BE-9 every Quote and supporting evidence read carries the genuine caller token")

CALLS.clear()
with app.test_client() as client:
    response = client.get("/quotes/workspace?batch_id=71", headers=AUTH)
batch_linked = response.get_json()["quote"]
check(response.status_code == 200
      and batch_linked["batch"]["id"] == 71
      and batch_linked["quote_reference"] == "NAG/QUO/2026-27/00001",
      "U5-BE-9a exact Batch identity resolves its caller-visible immutable Quote family")
check(CALLS and all(call[0] == "tok-u5" for call in CALLS),
      "U5-BE-9b the durable Batch-to-Quote read remains caller-token/RLS-only")

DENIED.add("calculation_snapshots")
with app.test_client() as client:
    response = client.get("/quotes/workspace?reference=NAG%2FQUO%2F2026-27%2F00001", headers=AUTH)
partial = response.get_json()["quote"]
check(response.status_code == 200 and partial["details_partial"] is True
      and "calculation_snapshots" in partial["denied_sections"]
      and partial["revisions"][1]["items"][0]["calculation_snapshot"] is None,
      "U5-BE-10 a denied snapshot remains explicit partial evidence and is never re-resolved")
DENIED.clear()

with app.test_client() as client:
    response = client.get("/quotes/workspace?reference=NAG%2FQUO%2F2026-27%2F99999", headers=AUTH)
check(response.status_code == 404, "U5-BE-11 an invisible or absent Quote is one stable not-found result")

with app.test_client() as client:
    response = client.get("/quotes/catalogue?view=history")
check(response.status_code == 401, "U5-BE-12 anonymous Quote history is refused")

with app.test_client() as client:
    response = client.get("/quotes/catalogue?view=inbox", headers=AUTH)
check(response.status_code == 403, "U5-BE-13 Approval Inbox requires genuine check_quote capability")

CALLER = {"id": 5, "active": True,
          "plant_capabilities": {"NAG": ["plant_access", "check_quote"]},
          "group_capabilities": []}
CALLS.clear()
with app.test_client() as client:
    response = client.get("/quotes/catalogue?view=inbox", headers=AUTH)
inbox = response.get_json()["catalogue"]
check(response.status_code == 200 and len(inbox["rows"]) == 1
      and inbox["rows"][0]["id"] == 603,
      "U5-BE-14 Checker inbox contains only caller-visible submitted revisions")
check(inbox["rows"][0]["quote_reference"] is None
      and inbox["rows"][0]["revision_no"] is None
      and inbox["rows"][0]["batch_reference"] == "NAG/BAT/2026-27/00072",
      "U5-BE-15 pre-approval identity stays unnumbered and uses its exact Batch reference")
check(inbox["rows"][0]["item_count"] == 1
      and inbox["rows"][0]["created_by_actor"]["display_name"] == "Maker",
      "U5-BE-16 inbox summary preserves caller-visible item and Maker evidence")
check(inbox["actions"]["approve"]["enabled"]
      and inbox["actions"]["return"]["enabled"]
      and not inbox["actions"]["share"]["enabled"],
      "U5-BE-17 the Checker inbox activates only eligible mounted review actions")
check(CALLS and all(call[0] == "tok-u5" for call in CALLS),
      "U5-BE-18 every inbox and supporting read carries the caller token")

with app.test_client() as client:
    response = client.get("/quotes/catalogue?view=history", headers=AUTH)
history = response.get_json()["catalogue"]
check(response.status_code == 200 and [row["id"] for row in history["rows"]] == [603, 602, 601]
      and history["display_limit"] == 50 and history["results_limited"] is False,
      "U5-BE-19 Quote History is newest-first and states its bounded display contract")

with app.test_client() as client:
    response = client.get("/quotes/workspace?revision_id=603", headers=AUTH)
candidate = response.get_json()["quote"]
check(response.status_code == 200 and candidate["quote_reference"] is None
      and candidate["revisions"][0]["workflow_status"] == "submitted",
      "U5-BE-20 a pre-approval candidate opens by exact caller-visible revision identity")

with app.test_client() as client:
    response = client.get("/quotes/workspace?batch_id=72", headers=AUTH)
batch_candidate = response.get_json()["quote"]
check(response.status_code == 200 and batch_candidate["quote_reference"] is None
      and batch_candidate["revisions"][0]["id"] == 603,
      "U5-BE-20a a reopened Batch reaches its unnumbered pre-approval evidence without inventing a Quote reference")

with app.test_client() as client:
    response = client.get("/quotes/workspace?batch_id=0", headers=AUTH)
check(response.status_code == 400,
      "U5-BE-20b Batch-to-Quote entry rejects a non-positive Batch identity")

with app.test_client() as client:
    response = client.get(
        "/quotes/workspace?reference=NAG%2FQUO%2F2026-27%2F00001&revision_id=603",
        headers=AUTH)
check(response.status_code == 400,
      "U5-BE-21 evidence entry refuses ambiguous reference plus revision identity")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("U5 Quote workspace route gate PASS")
