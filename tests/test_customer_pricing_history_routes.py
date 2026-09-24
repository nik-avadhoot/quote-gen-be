"""
Customer Pricing History P0.1 routes gate.

Run:  python tests/test_customer_pricing_history_routes.py

Hermetic and offline, same recording-fake convention as
tests/test_sector_master_routes.py. This proves what the ROUTES decide:
caller-token reads, the read_party_master fast refusal, the one-shot read shape
(chronology, exact two-decimal money strings, blank vs zero), which RPC is
called with which parameters, input refusal BEFORE any RPC, and stable error
codes without database text.

What it cannot prove - RLS, CAS, atomic audit and grants at the database layer -
is covered by tests.cph_p0_1_catalogue() and the self-rolling-back rehearsal in
tests/cph_p0_1_rollback_rehearsal.sql (run once the migration is authorised).
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


RPC_CALLS, TABLE_CALLS, RPC_RESPONSES, TABLE_ERRORS = [], [], {}, {}


def api_error(code, message="raw database text"):
    return APIError({"code": code, "message": message, "hint": None, "details": None})


class FakeQuery:
    def __init__(self, token, table, rows):
        self.token, self.table, self.rows, self.filters = token, table, rows, []

    def select(self, *a, **k): return self
    def order(self, *a, **k): return self
    def limit(self, *a, **k): return self

    def eq(self, col, val):
        self.filters.append(("eq", col, val))
        return self

    def in_(self, col, vals):
        self.filters.append(("in", col, list(vals)))
        return self

    def execute(self):
        TABLE_CALLS.append((self.token, self.table, tuple(map(str, self.filters))))
        if self.table in TABLE_ERRORS:
            raise TABLE_ERRORS[self.table]
        rows = list(self.rows)
        for kind, col, val in self.filters:
            if kind == "eq":
                rows = [r for r in rows if col not in r or r[col] == val]
            else:
                rows = [r for r in rows if col not in r or r[col] in val]
        return type("R", (), {"data": rows})()


class FakeRPC:
    def __init__(self, token, name, params):
        self.token, self.name, self.params = token, name, params

    def execute(self):
        RPC_CALLS.append((self.token, self.name, self.params))
        outcome = RPC_RESPONSES.get(self.name, {"id": 1, "content_version": 1})
        if isinstance(outcome, Exception):
            raise outcome
        return type("R", (), {"data": outcome})()


class FakeAuth:
    def get_user(self, tok):
        return type("U", (), {"user": type("X", (), {"id": "auth-uuid", "email": "u@x.invalid"})()})()


class FakeClient:
    def __init__(self, token):
        self.token = token
        self.auth = FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name, ROWS.get(name, []))

    def rpc(self, name, params):
        return FakeRPC(self.token, name, params)


READER = [{"app_user_id": 42, "status": "active", "capabilities": {"capability_key": "read_party_master"}}]

# Events deliberately arrive OUT of chronological order, with two on one date,
# so the route's own ordering is what the assertions observe. Money arrives the
# way PostgREST sends numeric - as JSON numbers that have lost trailing zeros.
ROWS = {
    "app_users": [{"id": 42, "auth_user_id": "auth-uuid", "display_name": "Maker", "status": "active"}],
    "group_capability_grants": list(READER),
    "plant_capability_grants": [],
    "parties": [{"id": 245, "customer_code": "C245", "display_name": "Nagpur Distillers",
                 "lifecycle_state": "customer", "status": "active"}],
    "customer_pricing_mechanisms": [{"id": 7, "party_id": 245, "review_frequency": "monthly",
                                     "period_label_style": "financial_year", "rate_basis": "box_per_piece",
                                     "weight_basis": None, "tax_treatment": "excluding_gst", "notes": None,
                                     "content_version": 3}],
    "customer_pricing_cycles": [{"id": 11, "party_id": 245, "mechanism_id": 7, "review_frequency": "monthly",
                                 "period_start": "2026-09-01", "period_end": "2026-09-30", "custom_label": None,
                                 "initiated_on": "2026-08-25", "status": "open", "content_version": 1}],
    "customer_pricing_lines": [{"id": 21, "cycle_id": 11, "party_id": 245, "customer_location_id": None,
                                "plant_id": None, "sku_id": None, "scope_text": "All RSC",
                                "sob_state": "percentage", "sob_pct": 0, "status": "active", "content_version": 1},
                               {"id": 22, "cycle_id": 11, "party_id": 245, "customer_location_id": None,
                                "plant_id": None, "sku_id": None, "scope_text": "Trays",
                                "sob_state": "undefined", "sob_pct": None, "status": "active",
                                "content_version": 1}],
    "customer_pricing_negotiation_events": [
        {"id": 35, "line_id": 21, "event_type": "final_agreement", "event_date": "2026-08-30",
         "sequence_no": 5, "rate_inr": 95.5, "tax_treatment": "excluding_gst", "gst_pct": None},
        {"id": 34, "line_id": 21, "event_type": "customer_counter", "event_date": "2026-08-28",
         "sequence_no": 4, "rate_inr": 94, "tax_treatment": "excluding_gst", "gst_pct": None},
        {"id": 31, "line_id": 21, "event_type": "avadhoot_offer", "event_date": "2026-08-25",
         "sequence_no": 1, "rate_inr": 100, "tax_treatment": "excluding_gst", "gst_pct": None},
        {"id": 33, "line_id": 21, "event_type": "avadhoot_offer", "event_date": "2026-08-28",
         "sequence_no": 3, "rate_inr": 0, "tax_treatment": "including_gst", "gst_pct": 18},
        {"id": 32, "line_id": 21, "event_type": "customer_counter", "event_date": "2026-08-27",
         "sequence_no": 2, "rate_inr": 90.5, "tax_treatment": "excluding_gst", "gst_pct": None},
    ],
    "customer_locations": [], "plants": [], "customer_pricing_change_events": [],
}


def fake_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return FakeClient(token)


cc.get_supabase_for_caller = fake_caller
import server  # noqa: E402
import auth as auth_mod  # noqa: E402
server.get_supabase_for_caller = fake_caller
auth_mod.get_supabase_for_caller = fake_caller
app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-x"}


def reset(rpc_name=None, response=None):
    RPC_CALLS.clear(); TABLE_CALLS.clear(); RPC_RESPONSES.clear(); TABLE_ERRORS.clear()
    if rpc_name is not None:
        RPC_RESPONSES[rpc_name] = response


def call(method, path, body=None, headers=AUTH):
    with app.test_client() as c:
        r = c.open(path, method=method, json=body, headers=headers)
    return r, (r.get_json(silent=True) or {})


GOOD_EVENT = {"event_type": "customer_counter", "event_date": "2026-08-31", "rate_inr": "94.00",
              "client_request_id": "0b7f4d0e-5a1e-4c1a-9d7e-2f0f8a8a1234"}
ROUTES = [
    ("read", "GET", "/masters/parties/245/pricing-history", None),
    ("mechanism", "PUT", "/masters/parties/245/pricing-mechanism",
     {"expected_content_version": 3, "review_frequency": "monthly"}),
    ("create cycle", "POST", "/masters/parties/245/pricing-cycles",
     {"period_start": "2026-10-01", "period_end": "2026-10-31", "initiated_on": "2026-09-25"}),
    ("update cycle", "PATCH", "/masters/pricing-cycles/11",
     {"expected_content_version": 1, "period_start": "2026-09-01", "period_end": "2026-09-30",
      "initiated_on": "2026-08-25"}),
    ("create line", "POST", "/masters/pricing-cycles/11/lines", {"scope_text": "Lids"}),
    ("update line", "PATCH", "/masters/pricing-lines/21", {"expected_content_version": 1}),
    ("add event", "POST", "/masters/pricing-lines/21/events", GOOD_EVENT),
    ("correct event", "PATCH", "/masters/pricing-events/31",
     {**GOOD_EVENT, "expected_content_version": 1}),
]

# ─────────────────────────────────────────── anonymous and unauthorised callers
for label, method, path, body in ROUTES:
    reset()
    r, _ = call(method, path, body, headers={})
    check(r.status_code == 401 and not RPC_CALLS, f"{label}: anonymous refused 401 before any RPC")

ROWS["group_capability_grants"] = []
for label, method, path, body in ROUTES:
    reset()
    r, payload = call(method, path, body)
    check(r.status_code == 403 and payload.get("error_code") == "CAPABILITY_REQUIRED" and not RPC_CALLS,
          f"{label}: authenticated WITHOUT read_party_master refused 403 before any RPC")
check(not any(t.startswith("customer_pricing") for _, t, _ in TABLE_CALLS),
      "read: an unauthorised caller triggers no pricing-table read at all")
ROWS["group_capability_grants"] = list(READER)

# ───────────────────────────────────────────────────────────────────── read
reset()
r, body = call("GET", "/masters/parties/245/pricing-history")
check(r.status_code == 200, "read: a read_party_master holder can read")
check(all(tok == "tok-x" for tok, _, _ in TABLE_CALLS), "read: every read carries the CALLER's token")
line = body["cycles"][0]["lines"][0]
check([e["id"] for e in line["events"]] == [31, 32, 33, 34, 35],
      "read: rounds come back by event date then stable sequence, not transport order")
check([e["rate_inr"] for e in line["events"]] == ["100.00", "90.50", "0.00", "94.00", "95.50"],
      "read: every INR value is an exact two-decimal string; explicit zero stays 0.00")
check(line["events"][2]["gst_pct"] == "18.00" and line["events"][0]["gst_pct"] is None,
      "read: a GST-inclusive round keeps its GST %; an ex-GST round carries none")
check(line["sob_state"] == "percentage" and line["sob_pct"] == "0.00",
      "read: SOB percentage 0% stays a deliberate 0.00")
other = body["cycles"][0]["lines"][1]
check(other["sob_state"] == "undefined" and other["sob_pct"] is None and other["events"] == [],
      "read: SOB left undefined is not a zero, and a line without rounds has an empty list")
check(body["mechanism"]["content_version"] == 3, "read: the mechanism carries its CAS token")
check(body["money_format"] == "decimal_string_2dp", "read: the payload declares its money format")
event_reads = [f for _, t, f in TABLE_CALLS if t == "customer_pricing_negotiation_events"]
check(len(event_reads) == 1 and "21" in event_reads[0][0] and "22" in event_reads[0][0],
      "read: all rounds for all lines are fetched in ONE batched read (no N+1)")

reset()
r, payload = call("GET", "/masters/parties/999/pricing-history")
check(r.status_code == 404 and payload.get("error_code") == "RECORD_NOT_FOUND",
      "read: an unknown or RLS-hidden Customer is RECORD_NOT_FOUND")

reset()
TABLE_ERRORS["customer_pricing_mechanisms"] = api_error("PGRST205", "Could not find the table")
r, payload = call("GET", "/masters/parties/245/pricing-history")
check(r.status_code == 503 and payload.get("error_code") == "MASTER_UNAVAILABLE"
      and "Could not find" not in str(payload),
      "read: an environment without the migration answers MASTER_UNAVAILABLE, not a crash")

# ──────────────────────────────────────────────────────────── mutations: RPCs
reset("cph_save_mechanism", {"id": 7, "content_version": 1})
r, body = call("PUT", "/masters/parties/245/pricing-mechanism",
               {"expected_content_version": None, "review_frequency": "quarterly",
                "rate_basis": "box_per_kg", "weight_basis": "paper_consumed", "notes": "  kg  "})
tok, name, params = RPC_CALLS[0]
check(r.status_code == 200 and name == "cph_save_mechanism" and tok == "tok-x",
      "mechanism: forwarded to the governed RPC on the caller's token")
check(params["p_expected_version"] is None and params["p_party"] == 245 and params["p_notes"] == "kg",
      "mechanism: a null expected version means create; notes are trimmed")

reset("cph_add_round", {"id": 36, "sequence_no": 6, "content_version": 1})
r, body = call("POST", "/masters/pricing-lines/21/events",
               {**GOOD_EVENT, "rate_inr": "0", "tax_treatment": "including_gst", "gst_pct": "18",
                "source_type": "whatsapp"})
_, name, params = RPC_CALLS[0]
check(r.status_code == 201 and name == "cph_add_round", "add event: 201 through cph_add_round (P0.2 superset of cph_add_event)")
check(params["p_rate_inr"] == "0.00" and params["p_gst_pct"] == "18.00",
      "add event: an explicit zero rate is sent as \"0.00\", never dropped as blank")
check(params["p_client_request_id"] == GOOD_EVENT["client_request_id"],
      "add event: the idempotency key reaches the database")
check(not any(isinstance(v, float) for v in params.values()),
      "add event: no money crosses into the RPC as a float")

reset("cph_add_round", {"id": 37, "sequence_no": 7, "content_version": 1})
r, _ = call("POST", "/masters/pricing-lines/21/events", {**GOOD_EVENT, "gst_pct": "18"})
_, _, params = RPC_CALLS[0]
check(r.status_code == 201 and params["p_tax_treatment"] is None and params["p_gst_pct"] == "18.00",
      "add event: a blank tax treatment is forwarded as NULL so the mechanism's own treatment applies")
reset("cph_add_round", {"id": 38, "sequence_no": 8, "content_version": 1})
r, _ = call("POST", "/masters/pricing-lines/21/events", {**GOOD_EVENT, "tax_treatment": "excluding_gst"})
_, _, params = RPC_CALLS[0]
check(r.status_code == 201 and params["p_tax_treatment"] == "excluding_gst" and params["p_gst_pct"] is None,
      "add event: an explicit per-round override to excluding GST is honoured")

reset("cph_update_cycle", {"id": 11, "content_version": 2})
r, _ = call("PATCH", "/masters/pricing-cycles/11",
            {"expected_content_version": 1, "period_start": "2026-09-01", "period_end": "2026-09-30",
             "initiated_on": "2026-08-26", "custom_label": "Sep revision", "status": "closed", "notes": "n"})
_, name, params = RPC_CALLS[0]
check(r.status_code == 200 and name == "cph_update_cycle" and params["p_expected_version"] == 1
      and params["p_custom_label"] == "Sep revision" and params["p_status"] == "closed"
      and params["p_initiated_on"] == "2026-08-26",
      "update cycle: dates, initiation, label, status and notes forwarded with the CAS version")

reset("cph_create_line", {"id": 23, "content_version": 1})
r, _ = call("POST", "/masters/pricing-cycles/11/lines",
            {"scope_text": "Lids", "sob_state": "percentage", "sob_pct": "0", "plant_id": 3})
_, name, params = RPC_CALLS[0]
check(r.status_code == 201 and params["p_sob_state"] == "percentage" and params["p_sob_pct"] == "0.00"
      and params["p_plant"] == 3, "create line: SOB percentage 0% is forwarded as 0.00")

# ──────────────────────────────────────────── input refused BEFORE any RPC
BAD = [
    ("rate as float", "POST", "/masters/pricing-lines/21/events", {**GOOD_EVENT, "rate_inr": 94.5}),
    ("three decimals", "POST", "/masters/pricing-lines/21/events", {**GOOD_EVENT, "rate_inr": "94.555"}),
    ("negative rate", "POST", "/masters/pricing-lines/21/events", {**GOOD_EVENT, "rate_inr": "-1"}),
    ("blank rate", "POST", "/masters/pricing-lines/21/events", {**GOOD_EVENT, "rate_inr": ""}),
    ("unknown event type", "POST", "/masters/pricing-lines/21/events", {**GOOD_EVENT, "event_type": "counter"}),
    ("bad date", "POST", "/masters/pricing-lines/21/events", {**GOOD_EVENT, "event_date": "31/08/2026"}),
    ("missing idempotency key", "POST", "/masters/pricing-lines/21/events",
     {k: v for k, v in GOOD_EVENT.items() if k != "client_request_id"}),
    ("GST-inclusive without %", "POST", "/masters/pricing-lines/21/events",
     {**GOOD_EVENT, "tax_treatment": "including_gst"}),
    ("GST % on explicit ex-GST rate", "POST", "/masters/pricing-lines/21/events",
     {**GOOD_EVENT, "tax_treatment": "excluding_gst", "gst_pct": "18"}),
    ("unknown cycle status", "PATCH", "/masters/pricing-cycles/11",
     {"expected_content_version": 1, "period_start": "2026-09-01", "period_end": "2026-09-30",
      "initiated_on": "2026-08-25", "status": "archived"}),
    ("SOB percentage without %", "POST", "/masters/pricing-cycles/11/lines", {"sob_state": "percentage"}),
    ("SOB above 100", "POST", "/masters/pricing-cycles/11/lines", {"sob_state": "percentage", "sob_pct": "100.01"}),
    ("SOB % while undefined", "POST", "/masters/pricing-cycles/11/lines", {"sob_state": "undefined", "sob_pct": "0"}),
    ("inverted period", "POST", "/masters/parties/245/pricing-cycles",
     {"period_start": "2026-10-31", "period_end": "2026-10-01", "initiated_on": "2026-09-25"}),
    ("update without CAS", "PATCH", "/masters/pricing-lines/21", {"sob_state": "undefined"}),
    ("correction without CAS", "PATCH", "/masters/pricing-events/31", GOOD_EVENT),
    ("unknown rate basis", "PUT", "/masters/parties/245/pricing-mechanism",
     {"review_frequency": "monthly", "rate_basis": "per_tonne"}),
    ("unknown frequency", "PUT", "/masters/parties/245/pricing-mechanism", {"review_frequency": "weekly"}),
]
for label, method, path, body in BAD:
    reset()
    r, payload = call(method, path, body)
    check(r.status_code == 400 and payload.get("error_code") == "INVALID_INPUT" and not RPC_CALLS,
          f"input: {label} refused INVALID_INPUT before any RPC")

# ─────────────────────────────────────────────── stable database refusals
REFUSALS = [
    ("PT409", 409, "STALE_VERSION", "a stale CAS"),
    ("42501", 403, "CAPABILITY_REQUIRED", "a database capability refusal"),
    ("P0002", 404, "RECORD_NOT_FOUND", "a missing record"),
    ("23505", 409, "DUPLICATE_RECORD", "a duplicate period/scope/round"),
    ("23514", 400, "INVALID_INPUT", "a check-constraint refusal"),
    ("23503", 404, "RECORD_NOT_FOUND", "another Customer's Location"),
    ("22023", 422, "TRANSITION_NOT_ALLOWED", "no mechanism yet / merged Customer"),
]
for sqlstate, status, code, why in REFUSALS:
    reset("cph_correct_round", api_error(sqlstate))
    r, payload = call("PATCH", "/masters/pricing-events/31", {**GOOD_EVENT, "expected_content_version": 1})
    check(r.status_code == status and payload.get("error_code") == code,
          f"refusal: {why} ({sqlstate}) maps to {code} / {status}")
    check("raw database text" not in str(payload), f"refusal: {why} does not leak database text")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("Customer Pricing History routes gate PASS")
