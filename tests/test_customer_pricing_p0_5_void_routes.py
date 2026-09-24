"""
Customer Pricing History P0.5 (void a negotiation round) routes gate.

Run:  venv/Scripts/python tests/test_customer_pricing_p0_5_void_routes.py

Hermetic and offline; importing the P0.4.1 gate runs P0.1, P0.2, P0.4 and P0.4.1
first on the same recording fakes. Proves what the ROUTE decides: anonymous and
no-capability callers never reach the database, the reason / version / Customer are
validated BEFORE any RPC, exactly the event id + Customer + CAS version + trimmed
reason reach cph_void_round on the caller's token, every database refusal becomes a
stable error with no database text, and a voided round cannot be corrected, given a
BF override, or targeted by a paste.

Database behaviour (status-only change, BF snapshot kept, CAS, audit atomicity, the
freeze on voided rounds, another Customer's event as not found) is proved by
tests/cph_p0_5_void_rehearsal.sql.
"""
import os
import sys
from decimal import Decimal

sys.path.insert(0, os.path.dirname(__file__))
import test_customer_pricing_p0_4_1_routes  # noqa: E402,F401  (runs P0.1, P0.2, P0.4, P0.4.1 first)
import test_customer_pricing_p0_4_routes as p4  # noqa: E402
import test_customer_pricing_history_routes as h  # noqa: E402

check, call, reset, api_error = h.check, h.call, h.reset, h.api_error
RPC_CALLS, TABLE_CALLS, ROWS = h.RPC_CALLS, h.TABLE_CALLS, h.ROWS
h.PASSES = 0
del h.FAILURES[:]
print("\n-- P0.5 void --")

URL = "/masters/pricing-events/31/void"
GOOD = {"party_id": 245, "expected_content_version": 3, "reason": "  Entered against the wrong line  "}

# ─────────────────────────────────────────── anonymous and unauthorised callers
reset()
r, _ = call("POST", URL, GOOD, headers={})
check(r.status_code == 401 and not RPC_CALLS, "void: anonymous refused 401 before any RPC")
ROWS["group_capability_grants"] = []
reset()
r, payload = call("POST", URL, GOOD)
check(r.status_code == 403 and payload.get("error_code") == "CAPABILITY_REQUIRED" and not RPC_CALLS,
      "void: without read_party_master refused 403 before any RPC")
ROWS["group_capability_grants"] = list(h.READER)

# ───────────────────────────────────────────────────────────── happy path
reset("cph_void_round", {"id": 31, "content_version": 4, "status": "voided"})
r, body = call("POST", URL, GOOD)
check(r.status_code == 200 and body.get("status") == "voided" and body.get("content_version") == 4,
      "void: returns the voided status and the new version")
check(RPC_CALLS == [("tok-x", "cph_void_round", {"p_party": 245, "p_event": 31, "p_expected_version": 3,
                                                  "p_reason": "Entered against the wrong line"})],
      "void: ONE RPC on the caller's token with the exact event id, Customer, CAS version and trimmed reason")
check(not any(t.startswith("customer_pricing") for _, t, _ in TABLE_CALLS),
      "void: no direct table read or write - the governed function is the only path")

# ──────────────────────────────────────────── input refused BEFORE any RPC
BAD = [
    ("missing reason", {k: v for k, v in GOOD.items() if k != "reason"}),
    ("blank reason", {**GOOD, "reason": "   "}),
    ("two-character reason", {**GOOD, "reason": " ab "}),
    ("501-character reason", {**GOOD, "reason": "x" * 501}),
    ("reason that is not text", {**GOOD, "reason": 12345}),
    ("missing Customer", {k: v for k, v in GOOD.items() if k != "party_id"}),
    ("Customer that is not an id", {**GOOD, "party_id": "abc"}),
    ("missing CAS version", {k: v for k, v in GOOD.items() if k != "expected_content_version"}),
    ("zero CAS version", {**GOOD, "expected_content_version": 0}),
]
for label, body in BAD:
    reset()
    r, payload = call("POST", URL, body)
    check(r.status_code == 400 and payload.get("error_code") == "INVALID_INPUT" and not RPC_CALLS,
          f"void: {label} refused INVALID_INPUT before any RPC")
reset("cph_void_round", {"id": 31, "content_version": 4, "status": "voided"})
r, _ = call("POST", URL, {**GOOD, "reason": "x" * 500})
check(r.status_code == 200 and len(RPC_CALLS[0][2]["p_reason"]) == 500, "void: a 500-character reason is accepted")

# ─────────────────────────────────────────────── stable database refusals
for sqlstate, code, status, meaning in (
        ("P0002", "RECORD_NOT_FOUND", 404, "another Customer's (or a missing) event"),
        ("PT409", "STALE_VERSION", 409, "a stale CAS version"),
        ("55000", "ROUND_VOIDED", 409, "an already-voided round"),
        ("42501", "CAPABILITY_REQUIRED", 403, "a database capability refusal"),
        ("PGRST202", "MASTER_UNAVAILABLE", 503, "a backend deployed before the void migration"),
        ("42883", "MASTER_UNAVAILABLE", 503, "the function missing in the database")):
    reset("cph_void_round", api_error(sqlstate, "raw database text"))
    r, payload = call("POST", URL, GOOD)
    check(r.status_code == status and payload.get("error_code") == code and "raw database text" not in str(payload),
          f"void: {meaning} ({sqlstate}) -> {code} / {status}, no database text")

# ──────────────────────────── a voided round is frozen on every other write path
reset("cph_correct_round", api_error("55000"))
r, payload = call("PATCH", "/masters/pricing-events/31",
                  {"expected_content_version": 4, "event_type": "customer_counter", "event_date": "2026-08-31",
                   "rate_inr": "94.00"})
check(r.status_code == 409 and payload.get("error_code") == "ROUND_VOIDED",
      "correct: correcting a voided round answers ROUND_VOIDED")
reset("cph_set_bf_override", api_error("55000"))
r, payload = call("PUT", "/masters/pricing-events/31/bf-overrides",
                  {"expected_content_version": 4, "bf_code": "20", "override_rate_inr": "57.00"})
check(r.status_code == 409 and payload.get("error_code") == "ROUND_VOIDED",
      "BF override: a voided round's schedule answers ROUND_VOIDED")

event31 = next(e for e in ROWS["customer_pricing_negotiation_events"] if e["id"] == 31)
event31.update(status="voided", void_reason="Entered against the wrong line")
r, payload = p4.preview([{"op": "set_bf_override", "event_id": 31, "expected_version": event31["content_version"],
                          "bf_code": "20", "override_rate_inr": "1.00"}])
check(r.status_code == 422 and p4.issues_of(payload) == [(0, "ROUND_VOIDED")] and not RPC_CALLS,
      "paste: a BF override pasted onto a voided round is blocked, nothing stored")
reset()
r, body = call("GET", "/masters/parties/245/pricing-history")
events = {e["id"]: e for c in body["cycles"] for l in c["lines"] for e in l["events"]}
check(events[31]["status"] == "voided" and events[31]["void_reason"] == "Entered against the wrong line"
      and events[31]["rate_inr"] == f"{Decimal(str(event31['rate_inr'])):.2f}" and events[31]["event_type"] == event31["event_type"],
      "read: the voided round is still returned with its status, reason and original rate/type")
check(sum(1 for _, t, _ in TABLE_CALLS if t == "customer_pricing_negotiation_events") == 1,
      "read: void_reason comes from the same single event read (no N+1)")
event31.update(status="active", void_reason=None)

print()
print(f"{h.PASSES} passed, {len(h.FAILURES)} failed")
if h.FAILURES:
    for f in h.FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("Customer Pricing History P0.5 void routes gate PASS")
