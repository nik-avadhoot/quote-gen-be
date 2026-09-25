"""S5 closure correction: behavioural coverage (not source-text presence).

Exercises the ACTUAL shipped functions and Flask routes with constructed
fixtures - not a grep over the migration text. One thing stays out of reach
without a live/isolated Postgres, and is covered only by the static SQL-text
assertions in `test_s5_customer_response_and_prior_quote_contract.py`: the
plpgsql permission predicate literally executing inside
`app_private.record_customer_outcome` / `app_private.resolve_batch_prior_quote`.
No database access is available in this environment and migrations must not
be applied here, so that predicate's live behaviour is recorded as follow-up
debt rather than fabricated. Everything else tested below - route-level
input validation, the DM-105 owner-Maker action-gate mirror in
`workflow_activation.py`, the pure Python comparison/matching model, the
?against= identity check, and the prior-quote route's status branches - is
real application code, exercised for real, with real assertions on its
output.
"""
import os
import sys

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import caller_context as cc  # noqa: E402

PASSES, FAILURES = 0, []
CALLER = None
RPC_CALLS = []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


# ═══════════════════════════════════════════════════ fixture: two Batches,
# same Customer/Plant, DIFFERENT Quote-family chains (cross-Batch case), plus
# a same-chain revision pair and a mismatched-identity Batch.
PLANTS = {7: {"id": 7, "plant_code": "NAG", "name": "Nagpur", "status": "active"},
          8: {"id": 8, "plant_code": "PUN", "name": "Pune", "status": "active"}}

BATCHES = {
    71: {"id": 71, "batch_reference": "NAG/BAT/1", "family_id": 21, "customer_party_id": 501,
         "plant_id": 7, "owner_user_id": 4, "sector_id": 31, "status": "issued_locked",
         "content_version": 1, "pricing_date": "2026-09-11", "pricing_basis_release_id": 11,
         "pricing_basis_is_deliberate": True, "created_at": "2026-09-11T07:00:00Z", "created_by": 4},
    60: {"id": 60, "batch_reference": "NAG/BAT/2", "family_id": 21, "customer_party_id": 501,
         "plant_id": 7, "owner_user_id": 4, "sector_id": 31, "status": "issued_locked",
         "content_version": 1, "pricing_date": "2026-08-01", "pricing_basis_release_id": 11,
         "pricing_basis_is_deliberate": True, "created_at": "2026-08-01T07:00:00Z", "created_by": 4},
    90: {"id": 90, "batch_reference": "PUN/BAT/1", "family_id": 22, "customer_party_id": 999,
         "plant_id": 8, "owner_user_id": 4, "sector_id": 31, "status": "issued_locked",
         "content_version": 1, "pricing_date": "2026-08-01", "pricing_basis_release_id": 11,
         "pricing_basis_is_deliberate": True, "created_at": "2026-08-01T07:00:00Z", "created_by": 4},
    72: {"id": 72, "batch_reference": "NAG/BAT/3", "family_id": 21, "customer_party_id": None,
         "plant_id": 7, "owner_user_id": 4, "sector_id": 31, "status": "working",
         "content_version": 1, "pricing_date": "2026-09-20", "pricing_basis_release_id": 11,
         "pricing_basis_is_deliberate": True, "created_at": "2026-09-20T07:00:00Z", "created_by": 4},
}

QUOTE_FAMILIES = {
    601: {"id": 601, "batch_id": 71, "quote_reference": "NAG/QUO/1", "status": "active",
          "created_at": "2026-09-11T08:00:00Z", "created_by": 4},
    602: {"id": 602, "batch_id": 60, "quote_reference": "NAG/QUO/0", "status": "active",
          "created_at": "2026-08-01T08:00:00Z", "created_by": 4},
    603: {"id": 603, "batch_id": 90, "quote_reference": "PUN/QUO/0", "status": "active",
          "created_at": "2026-08-01T08:00:00Z", "created_by": 4},
}

QUOTE_REVISIONS = {
    # Same-chain pair: 9302's own source_revision_id is 9301, same family 601.
    9301: {"id": 9301, "family_id": 601, "revision_no": 1, "source_revision_id": None,
           "workflow_status": "issued", "standing": "superseded", "addressee_name": "Buyer",
           "addressee_details": {}, "quote_date": "2026-09-01", "offer_validity_to": "2026-10-01",
           "approved_by": 5, "approved_at": "2026-09-01T10:00:00Z", "issued_by": 4,
           "issued_at": "2026-09-01T10:30:00Z", "voided_by": None, "voided_at": None,
           "void_reason": None, "withdraw_reason": None, "return_note": None,
           "created_at": "2026-09-01T08:00:00Z", "created_by": 4},
    9302: {"id": 9302, "family_id": 601, "revision_no": 2, "source_revision_id": 9301,
           "workflow_status": "issued", "standing": "current", "addressee_name": "Buyer",
           "addressee_details": {}, "quote_date": "2026-09-11", "offer_validity_to": "2026-10-11",
           "approved_by": 5, "approved_at": "2026-09-11T10:00:00Z", "issued_by": 4,
           "issued_at": "2026-09-11T10:30:00Z", "voided_by": None, "voided_at": None,
           "void_reason": None, "withdraw_reason": None, "return_note": None,
           "created_at": "2026-09-11T08:00:00Z", "created_by": 4},
    # No source_revision_id at all - "no comparison target" case.
    9501: {"id": 9501, "family_id": 601, "revision_no": None, "source_revision_id": None,
           "workflow_status": "draft", "standing": None, "addressee_name": None,
           "addressee_details": {}, "quote_date": None, "offer_validity_to": None,
           "approved_by": None, "approved_at": None, "issued_by": None, "issued_at": None,
           "voided_by": None, "voided_at": None, "void_reason": None, "withdraw_reason": None,
           "return_note": None, "created_at": "2026-09-21T08:00:00Z", "created_by": 4},
    # Cross-Batch prior: different family (602), same exact Customer + Plant as Batch 71.
    9201: {"id": 9201, "family_id": 602, "revision_no": 1, "source_revision_id": None,
           "workflow_status": "issued", "standing": "superseded", "addressee_name": "Buyer",
           "addressee_details": {}, "quote_date": "2026-08-01", "offer_validity_to": "2026-09-01",
           "approved_by": 5, "approved_at": "2026-08-01T10:00:00Z", "issued_by": 4,
           "issued_at": "2026-08-01T10:30:00Z", "voided_by": None, "voided_at": None,
           "void_reason": None, "withdraw_reason": None, "return_note": None,
           "created_at": "2026-08-01T08:00:00Z", "created_by": 4},
    # Mismatched-identity revision: different Plant AND Customer (family 603).
    9401: {"id": 9401, "family_id": 603, "revision_no": 1, "source_revision_id": None,
           "workflow_status": "issued", "standing": "current", "addressee_name": "Other buyer",
           "addressee_details": {}, "quote_date": "2026-08-01", "offer_validity_to": "2026-09-01",
           "approved_by": 5, "approved_at": "2026-08-01T10:00:00Z", "issued_by": 4,
           "issued_at": "2026-08-01T10:30:00Z", "voided_by": None, "voided_at": None,
           "void_reason": None, "withdraw_reason": None, "return_note": None,
           "created_at": "2026-08-01T08:00:00Z", "created_by": 4},
}


def _snapshot(id_, sku_id, rate, cost, volume, margin, engine="engine/qe1-a"):
    return {
        "id": id_, "schema_version": 1, "engine_version": engine, "rounding_rule_version": "qe1-r1",
        "pricing_basis_release_id": 11, "calculation_default_version_id": 41,
        "pricing_date": "2026-09-11", "effective_waste_pct": 5, "waste_source": "batch",
        "effective_conv_rate": 7, "conv_source": "batch", "effective_margin_pct": margin,
        "margin_source": "sector", "effective_interest_pct": 0.5, "interest_source": "derived_annual",
        "effective_freight": 0, "freight_source": "master", "freight_authority": "governed",
        "freight_set_version_id": 31, "freight_entry_id": 32,
        "total_cost": cost, "final_rate": rate, "rate_per_kg": rate, "calc_moq": 1000,
        "calculation_fingerprint": f"fp-{id_}", "presentation_fingerprint": f"pfp-{id_}",
        "effective_inputs": {
            "provenance": {"sku_id": sku_id, "sku_version_id": 2, "construction_version_id": 900},
            "entered": {"volume": volume, "sales_moq": 500, "length_mm": 300, "width_mm": 200, "height_mm": 150},
        } if sku_id is not None else {"provenance": {}, "entered": {"volume": volume}},
        "results": {"final_rate": rate}, "calculated_by": 4, "calculated_at": "2026-09-11T09:00:00Z",
    }


CALCULATION_SNAPSHOTS = {
    # Same-chain pair (family 601): lineage 5501 present both revisions (matched),
    # lineage 5599 only on 9301 (removed on 9302).
    8801: _snapshot(8801, 6601, 42.0, 38.0, 12000, 8),   # 9301 lineage 5501
    8802: _snapshot(8802, 6601, 43.1, 39.1, 12000, 8.5),  # 9302 lineage 5501
    8803: _snapshot(8803, 7000, 20.0, 18.0, 3000, 6),     # 9301 lineage 5599 (removed)
    # Cross-Batch prior (family 602, revision 9201): sku 6601 (matches Batch 71's
    # current sku 6601 -> unambiguous cross-Batch match), plus a duplicated sku
    # 7742 appearing twice (ambiguous, must never be guessed).
    8901: _snapshot(8901, 6601, 41.0, 37.0, 11000, 7, engine="engine/qe1-b"),   # different engine on purpose
    8902: _snapshot(8902, 7742, 39.5, 35.0, 8000, 8),
    8903: _snapshot(8903, 7742, 39.0, 34.5, 7000, 8),
    # Batch 71's current revision (9302) ALSO carries a second item with a sku
    # that only exists on the current side (added, in the cross-Batch match).
    8804: _snapshot(8804, 6620, 51.0, 44.8, 4000, 12),
    # Mismatched-identity revision item (should never be reachable through the route).
    9001: _snapshot(9001, 6601, 10.0, 9.0, 1000, 5),
}

QUOTE_ITEMS = {
    9301: [{"id": 701, "revision_id": 9301, "batch_row_lineage_id": 5501, "pricing_group_id": 81,
            "calculation_snapshot_id": 8801},
           {"id": 702, "revision_id": 9301, "batch_row_lineage_id": 5599, "pricing_group_id": 81,
            "calculation_snapshot_id": 8803}],
    9302: [{"id": 703, "revision_id": 9302, "batch_row_lineage_id": 5501, "pricing_group_id": 81,
            "calculation_snapshot_id": 8802},
           {"id": 704, "revision_id": 9302, "batch_row_lineage_id": 5502, "pricing_group_id": 81,
            "calculation_snapshot_id": 8804}],
    9201: [{"id": 705, "revision_id": 9201, "batch_row_lineage_id": 7701, "pricing_group_id": 82,
            "calculation_snapshot_id": 8901},
           {"id": 706, "revision_id": 9201, "batch_row_lineage_id": 7702, "pricing_group_id": 82,
            "calculation_snapshot_id": 8902},
           {"id": 707, "revision_id": 9201, "batch_row_lineage_id": 7703, "pricing_group_id": 82,
            "calculation_snapshot_id": 8903}],
    9401: [{"id": 708, "revision_id": 9401, "batch_row_lineage_id": 8001, "pricing_group_id": 83,
            "calculation_snapshot_id": 9001}],
    9501: [],
}

ROWS = {
    "quote_families": list(QUOTE_FAMILIES.values()),
    "batches": list(BATCHES.values()),
    "plants": list(PLANTS.values()),
    "quote_revisions": list(QUOTE_REVISIONS.values()),
    "quote_items": [item for items in QUOTE_ITEMS.values() for item in items],
    "calculation_snapshots": list(CALCULATION_SNAPSHOTS.values()),
    "quote_item_delivery_groups": [],
    "quote_workflow_events": [],
    "customer_outcome_events": [],
    "app_users": [{"id": 4, "display_name": "Maker", "status": "active"},
                  {"id": 5, "display_name": "Checker", "status": "active"}],
}


class FakeQuery:
    def __init__(self, table):
        self.table, self.columns, self.filters, self.in_filters, self.maximum = table, "*", [], [], None

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
        return self

    def execute(self):
        rows = list(ROWS.get(self.table, []))
        for column, value in self.filters:
            rows = [row for row in rows if str(row.get(column)) == str(value)]
        for column, values in self.in_filters:
            rows = [row for row in rows if row.get(column) in values]
        if self.maximum is not None:
            rows = rows[:self.maximum]
        wanted = [field.strip() for field in self.columns.split(",")]
        return type("Response", (), {"data": [
            {field: row.get(field) for field in wanted} for row in rows
        ]})()


class FakeAuth:
    def get_user(self, _token):
        user = type("User", (), {"id": "auth-s5", "email": "maker@example.invalid"})()
        return type("AuthResponse", (), {"user": user})()


PRIOR_QUOTE_RESULTS = {
    71: [{"revision_id": 9201, "family_id": 602, "quote_reference": "NAG/QUO/0", "revision_no": 1,
          "workflow_status": "issued", "standing": "superseded", "quote_date": "2026-08-01",
          "offer_validity_to": "2026-09-01", "issued_at": "2026-08-01T10:30:00Z",
          "source_kind": "last_quote_customer_plant", "latest_outcome": None, "latest_outcome_at": None,
          "current_revision_id": 9302}],
    72: [],
}


class FakeRPCResult:
    def __init__(self, data):
        self.data = data


class FakeRPC:
    def __init__(self, client, name, params):
        self.client, self.name, self.params = client, name, params

    def execute(self):
        RPC_CALLS.append((self.name, dict(self.params)))
        if self.name == "resolve_batch_prior_quote":
            batch_id = self.params["p_batch"]
            if batch_id == 999999:
                raise server.APIError({"code": "42501", "message": "denied", "details": None, "hint": None})
            return FakeRPCResult(PRIOR_QUOTE_RESULTS.get(batch_id, []))
        if self.name == "record_customer_outcome":
            return FakeRPCResult(9999)
        raise AssertionError(f"unexpected RPC in this fixture: {self.name}")


class FakeClient:
    def __init__(self, token):
        self.token, self.auth = token, FakeAuth()

    def table(self, name):
        return FakeQuery(name)

    def rpc(self, name, params):
        return FakeRPC(self, name, params)


def fake_client(_token):
    return FakeClient(_token)


cc.get_supabase_for_caller = fake_client
cc.new_caller_client = fake_client
import server  # noqa: E402
import auth as auth_mod  # noqa: E402

server.get_supabase_for_caller = fake_client
server.new_caller_client = fake_client
auth_mod.get_supabase_for_caller = fake_client
auth_mod.resolve_caller = lambda _token, known_auth_uid=None: CALLER
server.privileged_client = lambda _operation: (_ for _ in ()).throw(
    AssertionError("S5 routes must never request a privileged client"))

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-s5"}
CALLER = {"id": 4, "active": True, "plant_capabilities": {"NAG": ["plant_access", "make_quote"]},
          "group_capabilities": []}


# ═══════════════════════════════════════════════ 1. pure comparison model

from flask import g  # noqa: E402

with app.test_request_context(headers=AUTH):
    g.caller = CALLER
    current = server._read_quote_workspace(FakeClient("t"), revision_id=9302)
    cross_family = server._read_quote_workspace(FakeClient("t"), revision_id=9201)
current_9302 = next(row for row in current["revisions"] if row["id"] == 9302)
current_9501 = next(row for row in current["revisions"] if row["id"] == 9501)
prior_9301 = next(row for row in current["revisions"] if row["id"] == 9301)
prior_9201 = next(row for row in cross_family["revisions"] if row["id"] == 9201)

same_chain = server._build_revision_comparison(current_9302, prior_9301)
check(same_chain["same_chain"] is True, "BEHAV-1 same-Batch-chain comparison is flagged same_chain")
by_lineage = {row["batch_row_lineage_id"]: row for row in same_chain["rows"]}
check(by_lineage[5501]["status"] == "matched" and by_lineage[5501]["match_basis"] == "lineage",
      "BEHAV-2 same-chain rows match by frozen batch_row_lineage_id")
check(by_lineage[5501]["previous_rate"] == 42.0 and by_lineage[5501]["current_rate"] == 43.1,
      "BEHAV-3 quoted rate leads the comparison (D-5) with real previous/current values")
check(abs(by_lineage[5501]["rate_movement"] - 1.1) < 1e-9,
      "BEHAV-4 rate movement is a real numeric delta, not a placeholder")
check(by_lineage[5599]["status"] == "removed", "BEHAV-5 a lineage present only in the prior revision is 'removed'")
check(by_lineage[5502]["status"] == "added", "BEHAV-6 a lineage present only in the current revision is 'added'")
check(all(row["quote_line_total"] == "not_applicable_no_frozen_order_quantity" for row in same_chain["rows"]),
      "BEHAV-7 no fabricated Quote line total is ever produced")
check(same_chain["line_total_note"] and "no genuine frozen customer order" in same_chain["line_total_note"],
      "BEHAV-8 the schema's line-total limitation is disclosed in the payload")
check(by_lineage[5501]["previous_monthly_volume"] == 12000 and by_lineage[5501]["current_monthly_volume"] == 12000,
      "BEHAV-9 monthly volume is labelled and carried as monthly_volume, not renamed to a quantity")
check(by_lineage[5501]["previous_cost_before_margin_per_pc"] == 38.0
      and by_lineage[5501]["current_cost_before_margin_per_pc"] == 39.1,
      "BEHAV-10 total_cost is surfaced as cost_before_margin_per_pc, never as a line total")
check(by_lineage[5501]["descriptive_identity"] == "descriptive_identity_unavailable_only_frozen_id",
      "BEHAV-11 no current-master lookup backfills a descriptive product name")

cross = server._build_revision_comparison(current_9302, prior_9201)
check(cross["same_chain"] is False, "BEHAV-12 a different Quote-family chain is flagged NOT same_chain")
by_sku = {}
for row in cross["rows"]:
    by_sku.setdefault(row["sku_id"], []).append(row)
check(len(by_sku[6601]) == 1 and by_sku[6601][0]["status"] == "matched"
      and by_sku[6601][0]["match_basis"] == "sku_identity",
      "BEHAV-13 cross-Batch rows match by unambiguous frozen SKU identity, not lineage")
check(by_sku[6601][0]["previous_rate"] == 41.0 and by_sku[6601][0]["current_rate"] == 43.1,
      "BEHAV-14 cross-Batch matched row carries the real frozen rates from both sides")
check(7742 in cross["ambiguous_sku_ids"],
      "BEHAV-15 a SKU duplicated on one side is reported as ambiguous, not silently paired")
check(all(row["status"] in ("added", "removed") and row["match_basis"] == "ambiguous_sku_duplicate"
          for row in by_sku[7742]) and len(by_sku[7742]) == 2,
      "BEHAV-16 every duplicate-SKU occurrence is its own added/removed row - never guessed")
check(by_sku[6620][0]["status"] == "added" and by_sku[6620][0]["match_basis"] == "sku_identity",
      "BEHAV-17 a SKU present only on the current side is added, even across Batches")
check(cross["mixed_engine"] is True,
      "BEHAV-18 different engine_version between the two sides is flagged mixed_engine")


# ═══════════════════════════════════════════ 2. /compare route (?against=)

with app.test_client() as client:
    response = client.get("/quotes/revisions/9302/compare", headers=AUTH)
data = response.get_json()
check(response.status_code == 200 and data["comparison"]["prior_revision_id"] == 9301
      and data["comparison"]["same_chain"] is True,
      "BEHAV-21 the default /compare (no ?against=) uses the revision's own source_revision_id")

with app.test_client() as client:
    response = client.get("/quotes/revisions/9302/compare?against=9201", headers=AUTH)
data = response.get_json()
check(response.status_code == 200 and data["comparison"]["prior_revision_id"] == 9201
      and data["comparison"]["same_chain"] is False,
      "BEHAV-22 an explicit ?against= for the exact same Customer/Plant is honoured")

with app.test_client() as client:
    response = client.get("/quotes/revisions/9302/compare?against=9401", headers=AUTH)
check(response.status_code == 404,
      "BEHAV-23 ?against= is REFUSED when Customer/Plant do not match exactly (wrong Plant+Customer)")

with app.test_client() as client:
    response = client.get("/quotes/revisions/9501/compare", headers=AUTH)
data = response.get_json()
check(response.status_code == 200 and data["comparison"] is None
      and data["reason"] == "no_source_revision",
      "BEHAV-24 a revision with no source_revision_id and no ?against= reports no_source_revision, not an error")


# ═══════════════════════════════════════ 3. prior-quote route status branches

with app.test_client() as client:
    response = client.get("/quotes/batches/71/prior-quote", headers=AUTH)
data = response.get_json()
check(response.status_code == 200 and data["status"] == "found"
      and data["prior_quote"]["revision_id"] == 9201 and data["prior_quote"]["current_revision_id"] == 9302,
      "BEHAV-25 prior-quote 'found' carries both the prior AND the current revision identity")

with app.test_client() as client:
    response = client.get("/quotes/batches/72/prior-quote", headers=AUTH)
data = response.get_json()
check(response.status_code == 200 and data["status"] == "no_customer_selected",
      "BEHAV-26 a Batch with no customer_party_id reports no_customer_selected, not no_history")

BATCHES[73] = {**BATCHES[71], "id": 73, "customer_party_id": 502}
ROWS["batches"] = list(BATCHES.values())
PRIOR_QUOTE_RESULTS[73] = []
with app.test_client() as client:
    response = client.get("/quotes/batches/73/prior-quote", headers=AUTH)
data = response.get_json()
check(response.status_code == 200 and data["status"] == "no_history",
      "BEHAV-27 a Batch WITH a customer but no RPC match reports no_history, distinct from no_customer_selected")

with app.test_client() as client:
    response = client.get("/quotes/batches/999999/prior-quote", headers=AUTH)
check(response.status_code == 403,
      "BEHAV-28 a permission-denied RPC (42501) is refused, never silently empty")


# ═══════════════════════════════ 4. record_customer_outcome route: refusal
# paths never reach the RPC at all (proves "refusal writes nothing" for
# every input the ROUTE itself is responsible for validating).

RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/9302/outcome", headers=AUTH,
                            json={"outcome": "definitely_not_a_real_outcome"})
check(response.status_code == 400 and not RPC_CALLS,
      "BEHAV-29 an invalid outcome vocabulary value is refused before any RPC call")

RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/9302/outcome", headers=AUTH,
                            json={"outcome": "rejected", "acceptance_date": "2026-09-20"})
check(response.status_code == 400 and not RPC_CALLS,
      "BEHAV-30 acceptance_date on a non-accepted outcome is refused before any RPC call")

RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/9302/outcome", headers=AUTH,
                            json={"outcome": "accepted", "note": "x" * 2001})
check(response.status_code == 400 and not RPC_CALLS,
      "BEHAV-31 an oversized note is refused before any RPC call")

RPC_CALLS.clear()
with app.test_client() as client:
    response = client.post("/quotes/revisions/9302/outcome", headers=AUTH,
                            json={"outcome": "accepted", "acceptance_date": "2026-09-20",
                                  "acceptance_reference": "PO-1"})
check(response.status_code == 201 and RPC_CALLS
      and RPC_CALLS[-1][1]["p_outcome"] == "accepted"
      and RPC_CALLS[-1][1]["p_acceptance_date"] == "2026-09-20",
      "BEHAV-32 valid accepted-with-evidence input reaches the RPC with the exact fields transported")

with app.test_client() as client:
    response = client.post("/quotes/revisions/9302/outcome", json={"outcome": "accepted"})
check(response.status_code == 401,
      "BEHAV-33 an anonymous caller is refused the outcome route entirely (no auth header)")


# ═══════════════════════ 5. DM-105 owner-Maker-only signal (Python action gate)

owner_batch = {"id": 71, "owner_user_id": 4, "plant": {"plant_code": "NAG"}, "status": "issued_locked"}
issued_revision = {"workflow_status": "issued", "standing": "current"}
maker_caller = {"id": 4, "plant_capabilities": {"NAG": ["make_quote"]}, "group_capabilities": []}
collaborator_caller = {"id": 9, "plant_capabilities": {"NAG": ["make_quote"]}, "group_capabilities": []}
checker_caller = {"id": 55, "plant_capabilities": {"NAG": ["check_quote"]}, "group_capabilities": []}
admin_caller = {"id": 66, "plant_capabilities": {}, "group_capabilities": ["administer_users"]}

owner_actions = server.quote_revision_actions(maker_caller, owner_batch, issued_revision, is_collaborator=False)
collaborator_actions = server.quote_revision_actions(collaborator_caller, owner_batch, issued_revision, is_collaborator=True)
checker_actions = server.quote_revision_actions(checker_caller, owner_batch, issued_revision, is_collaborator=False)
admin_actions = server.quote_revision_actions(admin_caller, owner_batch, issued_revision, is_collaborator=False)

check(owner_actions["record_outcome"]["enabled"] is True,
      "BEHAV-34 DM-105: the Batch-owning Maker CAN record an outcome")
check(collaborator_actions["record_outcome"]["enabled"] is False,
      "BEHAV-35 DM-105: an active collaborator with make_quote (NOT the owner) CANNOT record an outcome")
check(checker_actions["record_outcome"]["enabled"] is True,
      "BEHAV-36 DM-105: an authorised Checker CAN record an outcome")
check(admin_actions["record_outcome"]["enabled"] is True,
      "BEHAV-37 DM-105: Admin correction authority CAN record an outcome")

wrong_plant_maker = {"id": 4, "plant_capabilities": {"PUN": ["make_quote"]}, "group_capabilities": []}
check(server.quote_revision_actions(wrong_plant_maker, owner_batch, issued_revision,
                                     is_collaborator=False)["record_outcome"]["enabled"] is False,
      "BEHAV-38 a Maker capability at the WRONG Plant cannot record an outcome")
check(server.quote_revision_actions(None, owner_batch, issued_revision,
                                     is_collaborator=False)["record_outcome"]["enabled"] is False,
      "BEHAV-39 a missing/anonymous caller cannot record an outcome")
check(server.quote_revision_actions(maker_caller, owner_batch, {"workflow_status": "draft"},
                                     is_collaborator=False)["record_outcome"]["enabled"] is False,
      "BEHAV-40 a not-yet-issued revision cannot receive a customer outcome")


print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for label in FAILURES:
        print(f"  - {label}")
    sys.exit(1)
print("S5 behavioural coverage PASS")
