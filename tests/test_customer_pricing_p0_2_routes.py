"""
Customer Pricing History P0.2 (commercial mechanisms) routes gate.

Run:  python tests/test_customer_pricing_p0_2_routes.py

Hermetic and offline; reuses the recording-fake harness of
tests/test_customer_pricing_history_routes.py. Proves what the ROUTES decide:
the one-shot read now carries Stable Terms, BF sets, measures and each
round's own snapshot (with exact reconciliation and derived BF rates), every
new mutation forwards exact decimal strings to the right governed RPC on the
caller token, bad shapes are refused before any RPC, and an overlapping
version maps to a stable OVERLAPPING_VERSION code without database text.

Database behaviour (overlap refusal, snapshots, immutability, CAS, audit) is
proved by tests/cph_p0_2_rollback_rehearsal.sql.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import test_customer_pricing_history_routes as h  # noqa: E402  (runs the P0.1 gate first)

check, call, reset, api_error = h.check, h.call, h.reset, h.api_error
RPC_CALLS, TABLE_CALLS, ROWS = h.RPC_CALLS, h.TABLE_CALLS, h.ROWS
h.PASSES = 0
del h.FAILURES[:]
print("\n-- P0.2 --")

ROWS["customer_pricing_lines"][0].update({"term_version_id": 51, "bf_delta_set_id": 61, "prior_line_id": None})
event = next(e for e in ROWS["customer_pricing_negotiation_events"] if e["id"] == 31)
event.update({"component_kraft_inr": 45, "component_conversion_inr": 8, "component_freight_inr": 1.25,
              "rate_inr": 54.26, "base_bf_code": "18", "bf_delta_set_id": 61, "term_version_id": 51,
              "snap_conversion_inr_per_kg": 8, "snap_freight_inr_per_kg": 1.25,
              "snap_wastage_treatment": "added_pct", "snap_wastage_pct": 3.5})
ROWS["customer_pricing_event_bf_rates"] = [
    {"id": 1, "event_id": 31, "bf_code": "22GY", "delta_inr": 3.25, "override_rate_inr": None},
    {"id": 2, "event_id": 31, "bf_code": "20", "delta_inr": 1.5, "override_rate_inr": 56},
    {"id": 3, "event_id": 31, "bf_code": "16", "delta_inr": -1, "override_rate_inr": None},
]
ROWS["customer_pricing_line_measures"] = [
    {"id": 1, "line_id": 21, "measure": "paper_consumed_kg", "source": "costing_snapshot", "value": 0.452,
     "status": "active", "content_version": 1},
    {"id": 2, "line_id": 21, "measure": "paper_consumed_kg", "source": "customer_confirmed", "value": 0.46,
     "status": "active", "content_version": 1},
]
ROWS["customer_pricing_term_versions"] = [
    {"id": 51, "party_id": 245, "customer_location_id": None, "plant_id": None, "version_no": 1,
     "status": "active", "effective_from": "2026-04-01", "effective_to": None, "wastage_treatment": "added_pct",
     "wastage_pct": 0, "freight_treatment": "ex_factory_separate", "conversion_inr_per_kg": 8,
     "freight_inr_per_kg": None, "content_version": 1},
]
ROWS["customer_pricing_bf_delta_sets"] = [
    {"id": 61, "party_id": 245, "version_no": 1, "status": "active", "effective_from": "2026-04-01",
     "effective_to": None, "base_bf_code": "18", "content_version": 1},
]
ROWS["customer_pricing_bf_deltas"] = [
    {"id": 1, "set_id": 61, "bf_code": "22GY", "delta_inr": 3.25},
    {"id": 2, "set_id": 61, "bf_code": "16", "delta_inr": -1},
]
ROWS["skus"] = [{"id": 987, "plant_id": 1, "plant_item_code": "NAG-1", "status": "active"}]

# ─────────────────────────────────────────────────────────────── read
reset()
r, body = call("GET", "/masters/parties/245/pricing-history")
check(r.status_code == 200, "read: 200 with the P0.2 sections")
ev = next(e for e in body["cycles"][0]["lines"][0]["events"] if e["id"] == 31)
check(ev["component_kraft_inr"] == "45.00" and ev["component_freight_inr"] == "1.25"
      and ev["component_total_inr"] == "54.25" and ev["reconciliation_diff_inr"] == "0.01",
      "read: components, component total and reconciliation difference are exact 2dp strings")
check(ev["rate_inr"] == "54.26", "read: the recorded total is kept, not replaced by the component sum")
check(ev["snap_conversion_inr_per_kg"] == "8.00" and ev["snap_wastage_pct"] == "3.50",
      "read: the round carries its own frozen Stable Term snapshot")
sched = ev["bf_schedule"]
check([row["bf_code"] for row in sched] == ["18", "16", "20", "22GY"],
      "read: BF schedule starts at the base BF, then grades in numeric order")
check(sched[0]["is_base"] and sched[0]["derived_rate_inr"] == "54.26" and sched[0]["delta_inr"] is None,
      "read: the base BF row is the round's own rate with no delta")
row16 = next(x for x in sched if x["bf_code"] == "16")
check(row16["delta_inr"] == "-1.00" and row16["derived_rate_inr"] == "53.26" and not row16["is_override"],
      "read: derived = base + signed (negative) delta, exact")
row20 = next(x for x in sched if x["bf_code"] == "20")
check(row20["derived_rate_inr"] == "55.76" and row20["override_rate_inr"] == "56.00"
      and row20["effective_rate_inr"] == "56.00" and row20["is_override"],
      "read: an override is labelled and kept BESIDE the derived rate")
measures = body["cycles"][0]["lines"][0]["measures"]
check(sorted((m["source"], m["value"]) for m in measures)
      == [("costing_snapshot", "0.4520"), ("customer_confirmed", "0.4600")],
      "read: Costing and Customer-confirmed weights both returned, 4-decimal strings")
term = body["term_versions"][0]
check(term["wastage_pct"] == "0.00" and term["conversion_inr_per_kg"] == "8.00" and term["freight_inr_per_kg"] is None,
      "read: term explicit zero stays 0.00 and blank stays null")
check([d["bf_code"] for d in body["bf_delta_sets"][0]["deltas"]] == ["16", "22GY"]
      and body["bf_delta_sets"][0]["deltas"][0]["delta_inr"] == "-1.00",
      "read: BF set deltas returned signed and sorted")
check(body["skus"][0]["id"] == 987, "read: the Customer's own SKUs are offered for line scope")
reads = [t for _, t, _ in TABLE_CALLS]
check(reads.count("customer_pricing_event_bf_rates") == 1 and reads.count("customer_pricing_line_measures") == 1,
      "read: BF snapshots and measures are fetched in ONE batched read each (no N+1)")
check(all(tok == "tok-x" for tok, _, _ in TABLE_CALLS), "read: every P0.2 read uses the caller token")

# ─────────────────────────────────────────────────────────── mutations
TERM = {"effective_from": "2026-10-01", "close_prior": True, "rate_basis": "kraft_paper_per_kg",
        "weight_basis": "paper_consumed", "wastage_treatment": "added_pct", "wastage_pct": "3.5",
        "freight_treatment": "ex_factory_separate", "conversion_inr_per_kg": "9", "freight_inr_per_kg": "0"}
reset("cph_create_term_version", {"id": 52, "version_no": 2, "content_version": 1, "closed_prior_id": 51})
r, body = call("POST", "/masters/parties/245/pricing-terms", TERM)
tok, name, params = RPC_CALLS[0]
check(r.status_code == 201 and name == "cph_create_term_version" and tok == "tok-x",
      "term: created through the governed RPC on the caller token")
check(params["p_conversion_inr_per_kg"] == "9.00" and params["p_freight_inr_per_kg"] == "0.00"
      and params["p_wastage_pct"] == "3.50" and params["p_close_prior"] is True
      and params["p_location"] is None and params["p_plant"] is None,
      "term: exact strings, explicit zero freight kept, explicit close_prior, whole-Customer scope")

reset("cph_correct_term_version", {"id": 52, "content_version": 2})
r, _ = call("PATCH", "/masters/pricing-terms/52", {**TERM, "expected_content_version": 1, "status": "withdrawn"})
_, name, params = RPC_CALLS[0]
check(r.status_code == 200 and params["p_expected_version"] == 1 and params["p_status"] == "withdrawn",
      "term: correction/withdrawal forwards the CAS version")

reset("cph_create_bf_delta_set", {"id": 62, "version_no": 2, "content_version": 1})
r, _ = call("POST", "/masters/parties/245/pricing-bf-sets",
            {"effective_from": "2026-10-01", "close_prior": True, "base_bf_code": "18",
             "deltas": [{"bf_code": "20", "delta_inr": "2"}, {"bf_code": "16", "delta_inr": "-1.25"},
                        {"bf_code": "22gy", "delta_inr": "0"}]})
_, name, params = RPC_CALLS[0]
check(r.status_code == 201 and params["p_base_bf_code"] == "18"
      and params["p_deltas"] == [{"bf_code": "20", "delta_inr": "2.00"}, {"bf_code": "16", "delta_inr": "-1.25"},
                                 {"bf_code": "22GY", "delta_inr": "0.00"}],
      "BF set: signed exact deltas, upper-cased codes, explicit 0.00 delta kept")

reset("cph_set_line_references", {"id": 21, "content_version": 3})
r, _ = call("PUT", "/masters/pricing-lines/21/references",
            {"expected_content_version": 2, "term_version_id": 52, "bf_delta_set_id": None})
_, name, params = RPC_CALLS[0]
check(r.status_code == 200 and params == {"p_line": 21, "p_expected_version": 2, "p_term": 52, "p_bf_set": None},
      "references: term and BF set set together under the line's CAS")

reset("cph_set_line_measure", {"id": 3, "content_version": 1})
r, _ = call("PUT", "/masters/pricing-lines/21/measures",
            {"measure": "sheet_weight_kg", "source": "customer_confirmed", "value": "0.41",
             "expected_content_version": None})
_, name, params = RPC_CALLS[0]
check(r.status_code == 200 and params["p_value"] == "0.4100" and params["p_expected_version"] is None
      and params["p_source"] == "customer_confirmed",
      "measure: value sent as an exact 4-decimal string beside other sources")
reset("cph_set_line_measure", {"id": 2, "content_version": 2})
r, _ = call("PUT", "/masters/pricing-lines/21/measures",
            {"measure": "paper_consumed_kg", "source": "customer_confirmed", "value": "",
             "expected_content_version": 1})
_, _, params = RPC_CALLS[0]
check(r.status_code == 200 and params["p_value"] is None and params["p_expected_version"] == 1,
      "measure: a blank value withdraws that source's value (never becomes zero)")

reset("cph_set_bf_override", {"id": 31, "content_version": 3})
r, _ = call("PUT", "/masters/pricing-events/31/bf-overrides",
            {"expected_content_version": 2, "bf_code": "20", "override_rate_inr": "56"})
_, name, params = RPC_CALLS[0]
check(r.status_code == 200 and params["p_override_rate_inr"] == "56.00" and params["p_bf_code"] == "20",
      "override: exact override under the round's CAS")
reset("cph_set_bf_override", {"id": 31, "content_version": 4})
r, _ = call("PUT", "/masters/pricing-events/31/bf-overrides",
            {"expected_content_version": 3, "bf_code": "20", "override_rate_inr": None})
check(r.status_code == 200 and RPC_CALLS[0][2]["p_override_rate_inr"] is None,
      "override: null clears it back to the derived rate")

reset("cph_start_next_cycle", {"id": 12, "content_version": 1, "lines": 2})
r, body = call("POST", "/masters/pricing-cycles/11/next",
               {"period_start": "2026-10-01", "period_end": "2026-10-31", "initiated_on": "2026-09-24"})
_, name, params = RPC_CALLS[0]
check(r.status_code == 201 and name == "cph_start_next_cycle" and params["p_prior_cycle"] == 11
      and set(params) == {"p_prior_cycle", "p_period_start", "p_period_end", "p_initiated_on", "p_custom_label"},
      "next cycle: structure-only request; no rate or offer can be carried forward through it")

reset("cph_add_round", {"id": 40, "sequence_no": 6, "content_version": 1})
r, _ = call("POST", "/masters/pricing-lines/21/events",
            {**h.GOOD_EVENT, "rate_inr": "54.26", "kraft_inr": "45", "conversion_inr": "8", "freight_inr": "0"})
_, _, params = RPC_CALLS[0]
check(r.status_code == 201 and params["p_kraft_inr"] == "45.00" and params["p_freight_inr"] == "0.00"
      and params["p_conversion_inr"] == "8.00",
      "round: component breakup forwarded exactly; explicit 0.00 freight kept")

# ───────────────────────────────────────────── refused before any RPC
BAD = [
    ("term without start", "POST", "/masters/parties/245/pricing-terms", {"wastage_treatment": "not_captured"}),
    ("term end before start", "POST", "/masters/parties/245/pricing-terms",
     {"effective_from": "2026-10-01", "effective_to": "2026-09-30"}),
    ("wastage added without %", "POST", "/masters/parties/245/pricing-terms",
     {"effective_from": "2026-10-01", "wastage_treatment": "added_pct"}),
    ("wastage % while included", "POST", "/masters/parties/245/pricing-terms",
     {"effective_from": "2026-10-01", "wastage_treatment": "included_in_weight", "wastage_pct": "3"}),
    ("unknown freight treatment", "POST", "/masters/parties/245/pricing-terms",
     {"effective_from": "2026-10-01", "freight_treatment": "fob"}),
    ("float conversion", "POST", "/masters/parties/245/pricing-terms",
     {"effective_from": "2026-10-01", "conversion_inr_per_kg": 8.5}),
    ("term correction without CAS", "PATCH", "/masters/pricing-terms/52", {"effective_from": "2026-10-01"}),
    ("BF base in its own schedule", "POST", "/masters/parties/245/pricing-bf-sets",
     {"effective_from": "2026-10-01", "base_bf_code": "18", "deltas": [{"bf_code": "18", "delta_inr": "1"}]}),
    ("BF duplicate grade", "POST", "/masters/parties/245/pricing-bf-sets",
     {"effective_from": "2026-10-01", "base_bf_code": "18",
      "deltas": [{"bf_code": "20", "delta_inr": "1"}, {"bf_code": "20", "delta_inr": "2"}]}),
    ("BF three-decimal delta", "POST", "/masters/parties/245/pricing-bf-sets",
     {"effective_from": "2026-10-01", "base_bf_code": "18", "deltas": [{"bf_code": "20", "delta_inr": "1.555"}]}),
    ("BF blank delta", "POST", "/masters/parties/245/pricing-bf-sets",
     {"effective_from": "2026-10-01", "base_bf_code": "18", "deltas": [{"bf_code": "20", "delta_inr": ""}]}),
    ("BF invented grade code", "POST", "/masters/parties/245/pricing-bf-sets",
     {"effective_from": "2026-10-01", "base_bf_code": "eighteen", "deltas": [{"bf_code": "20", "delta_inr": "1"}]}),
    ("BF empty schedule", "POST", "/masters/parties/245/pricing-bf-sets",
     {"effective_from": "2026-10-01", "base_bf_code": "18", "deltas": []}),
    ("references without CAS", "PUT", "/masters/pricing-lines/21/references", {"term_version_id": 52}),
    ("zero weight", "PUT", "/masters/pricing-lines/21/measures",
     {"measure": "box_weight_kg", "source": "manual", "value": "0"}),
    ("five-decimal area", "PUT", "/masters/pricing-lines/21/measures",
     {"measure": "area_sqm", "source": "manual", "value": "0.12345"}),
    ("unknown measure source", "PUT", "/masters/pricing-lines/21/measures",
     {"measure": "area_sqm", "source": "guess", "value": "0.12"}),
    ("override without CAS", "PUT", "/masters/pricing-events/31/bf-overrides", {"bf_code": "20", "override_rate_inr": "1"}),
    ("negative component", "POST", "/masters/pricing-lines/21/events", {**h.GOOD_EVENT, "kraft_inr": "-1"}),
    ("next cycle without dates", "POST", "/masters/pricing-cycles/11/next", {"initiated_on": "2026-09-24"}),
    ("next cycle inverted", "POST", "/masters/pricing-cycles/11/next",
     {"period_start": "2026-10-31", "period_end": "2026-10-01", "initiated_on": "2026-09-24"}),
]
for label, method, path, body in BAD:
    reset()
    r, payload = call(method, path, body)
    check(r.status_code == 400 and payload.get("error_code") == "INVALID_INPUT" and not RPC_CALLS,
          f"input: {label} refused INVALID_INPUT before any RPC")

# ───────────────────────────────────────────── stable database refusals
for sqlstate, status, code in (("23P01", 409, "OVERLAPPING_VERSION"), ("PT409", 409, "STALE_VERSION"),
                               ("42501", 403, "CAPABILITY_REQUIRED"), ("22023", 422, "TRANSITION_NOT_ALLOWED")):
    reset("cph_create_term_version", api_error(sqlstate))
    r, payload = call("POST", "/masters/parties/245/pricing-terms", TERM)
    check(r.status_code == status and payload.get("error_code") == code and "raw database text" not in str(payload),
          f"refusal: {sqlstate} maps to {code} / {status} without database text")

# BF floor: the database refuses a round / base-rate correction that would make
# any snapshotted derived BF rate negative (23514); the route reports the stable
# INVALID_INPUT without the database's own wording.
for rpc, method, path, body in (
        ("cph_add_round", "POST", "/masters/pricing-lines/21/events", {**h.GOOD_EVENT, "rate_inr": "0.99"}),
        ("cph_correct_round", "PATCH", "/masters/pricing-events/31",
         {**h.GOOD_EVENT, "rate_inr": "0.90", "expected_content_version": 3})):
    reset(rpc, api_error("23514", "a BF in this round's schedule would have a negative derived rate"))
    r, payload = call(method, path, body)
    check(r.status_code == 400 and payload.get("error_code") == "INVALID_INPUT"
          and "negative derived rate" not in str(payload) and len(RPC_CALLS) == 1,
          f"BF floor: {rpc} refusal maps to INVALID_INPUT / 400 without database text")

ROWS["group_capability_grants"] = []
for method, path in (("POST", "/masters/parties/245/pricing-terms"), ("POST", "/masters/parties/245/pricing-bf-sets"),
                     ("PUT", "/masters/pricing-lines/21/references"), ("PUT", "/masters/pricing-lines/21/measures"),
                     ("PUT", "/masters/pricing-events/31/bf-overrides"), ("POST", "/masters/pricing-cycles/11/next")):
    reset()
    r, payload = call(method, path, {})
    check(r.status_code == 403 and not RPC_CALLS, f"auth: {method} {path} refused without read_party_master")
ROWS["group_capability_grants"] = list(h.READER)

print()
print(f"{h.PASSES} passed, {len(h.FAILURES)} failed")
if h.FAILURES:
    for f in h.FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("Customer Pricing History P0.2 routes gate PASS")
