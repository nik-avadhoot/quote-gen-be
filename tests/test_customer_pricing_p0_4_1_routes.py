"""
Customer Pricing History P0.4.1 (SOB allocated box quantity) routes gate.

Run:  venv/Scripts/python tests/test_customer_pricing_p0_4_1_routes.py

Hermetic and offline; importing the P0.4 gate runs P0.1, P0.2 and P0.4 first on
the same recording fakes. Proves what the ROUTES decide about SOB:
percentage and allocated boxes are mutually exclusive, blank / 0.00% / 0 boxes
stay distinct, box quantities cross the boundary as exact decimal strings and
anything fractional, negative, float, boolean, separated or out of range is
refused before any RPC, paste carries the whole SOB triple in the ONE preview
call, and the change log reports mode and quantity honestly.

Database behaviour (check constraints, CAS, audit, atomic paste apply) is proved
by tests/cph_p0_4_1_rollback_rehearsal.sql.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import test_customer_pricing_p0_4_routes as p4  # noqa: E402  (runs P0.1, P0.2 and P0.4 first)
import test_customer_pricing_history_routes as h  # noqa: E402

check, call, reset = h.check, h.call, h.reset
RPC_CALLS, TABLE_CALLS, ROWS = h.RPC_CALLS, h.TABLE_CALLS, h.ROWS
h.PASSES = 0
del h.FAILURES[:]
print("\n-- P0.4.1 --")

LINE21 = next(l for l in ROWS["customer_pricing_lines"] if l["id"] == 21)
LINE22 = next(l for l in ROWS["customer_pricing_lines"] if l["id"] == 22)

# ─────────────────────────────────────────────────────────────────── read
LINE21.update(sob_state="allocated_quantity", sob_pct=None, sob_allocated_boxes=25000)
LINE22.update(sob_state="allocated_quantity", sob_pct=None, sob_allocated_boxes=0)
reset()
r, body = call("GET", "/masters/parties/245/pricing-history")
lines = {l["id"]: l for c in body["cycles"] for l in c["lines"]}
check(r.status_code == 200 and lines[21]["sob_allocated_boxes"] == "25000" and lines[21]["sob_pct"] is None,
      "read: allocated boxes cross the boundary as an exact decimal string, % absent")
check(lines[22]["sob_allocated_boxes"] == "0" and lines[22]["sob_state"] == "allocated_quantity",
      "read: an explicit 0 boxes stays \"0\", never blank")
import inspect  # noqa: E402
import server  # noqa: E402
check(sum(1 for _, t, _ in TABLE_CALLS if t == "customer_pricing_lines") == 1
      and "sob_pct, sob_allocated_boxes, notes" in inspect.getsource(server),
      "read: boxes come from the same single line select (no second read)")
LINE21.update(sob_state="percentage", sob_pct=0, sob_allocated_boxes=None)
LINE22.update(sob_state="undefined", sob_pct=None, sob_allocated_boxes=None)

# ─────────────────────────────────────────────────── create / update forwarding
for label, sent, want in (
    ("25,000 boxes as a string", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "25000"},
     ("allocated_quantity", None, "25000")),
    ("0 boxes as a JSON integer", {"sob_state": "allocated_quantity", "sob_allocated_boxes": 0},
     ("allocated_quantity", None, "0")),
    ("the bound itself", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "999999999"},
     ("allocated_quantity", None, "999999999")),
    ("0.00% stays a percentage", {"sob_state": "percentage", "sob_pct": "0"}, ("percentage", "0.00", None)),
    ("blank SOB", {}, ("not_captured", None, None)),
    ("blank box value on a non-quantity state", {"sob_state": "undefined", "sob_allocated_boxes": ""},
     ("undefined", None, None)),
):
    reset("cph_create_line", {"id": 23, "content_version": 1})
    r, _ = call("POST", "/masters/pricing-cycles/11/lines", {"scope_text": "Lids", **sent})
    params = RPC_CALLS[0][2] if RPC_CALLS else {}
    check(r.status_code == 201 and (params.get("p_sob_state"), params.get("p_sob_pct"),
                                    params.get("p_sob_allocated_boxes")) == want,
          f"create line: {label} -> {want}")

reset("cph_update_line", {"id": 21, "content_version": 2})
r, _ = call("PATCH", "/masters/pricing-lines/21",
            {"expected_content_version": 1, "scope_text": "All RSC", "sob_state": "allocated_quantity",
             "sob_allocated_boxes": "25000"})
_, name, params = RPC_CALLS[0]
check(r.status_code == 200 and name == "cph_update_line" and params["p_line"] == 21
      and params["p_expected_version"] == 1 and params["p_sob_allocated_boxes"] == "25000"
      and params["p_sob_pct"] is None and params["p_plant"] is None and params["p_sku"] is None,
      "update line: one CAS-guarded RPC; the box quantity never supplies a Plant/SKU/Location")

# ──────────────────────────────────────────── refused BEFORE any RPC
BAD = [
    ("allocated quantity without boxes", {"sob_state": "allocated_quantity"}),
    ("allocated quantity with a blank", {"sob_state": "allocated_quantity", "sob_allocated_boxes": " "}),
    ("boxes while percentage", {"sob_state": "percentage", "sob_pct": "40", "sob_allocated_boxes": "10"}),
    ("% while allocated quantity", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "10", "sob_pct": "40"}),
    ("0 boxes while undefined", {"sob_state": "undefined", "sob_allocated_boxes": "0"}),
    ("boxes without a state", {"sob_allocated_boxes": "10"}),
    ("fractional boxes", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "12.5"}),
    ("trailing .0", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "12.0"}),
    ("negative boxes", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "-1"}),
    ("negative integer", {"sob_state": "allocated_quantity", "sob_allocated_boxes": -1}),
    ("JSON float", {"sob_state": "allocated_quantity", "sob_allocated_boxes": 12.0}),
    ("boolean", {"sob_state": "allocated_quantity", "sob_allocated_boxes": True}),
    ("exponent", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "1e3"}),
    ("thousands separator (display text, not a value)", {"sob_state": "allocated_quantity",
                                                         "sob_allocated_boxes": "25,000"}),
    ("unit text", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "25000 boxes"}),
    ("one above the bound", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "1000000000"}),
    ("unsafe JS integer as a string", {"sob_state": "allocated_quantity",
                                       "sob_allocated_boxes": "9007199254740993"}),
    ("unsafe JS integer as a number", {"sob_state": "allocated_quantity",
                                       "sob_allocated_boxes": 9007199254740993}),
    ("a very long digit string", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "9" * 5000}),
    ("the retired P0.1 state name", {"sob_state": "defined", "sob_pct": "40"}),
]
for label, sent in BAD:
    reset()
    r, payload = call("POST", "/masters/pricing-cycles/11/lines", {"scope_text": "Lids", **sent})
    check(r.status_code == 400 and payload.get("error_code") == "INVALID_INPUT" and not RPC_CALLS
          and "9007199254740992" not in str(payload),
          f"input: {label} refused INVALID_INPUT before any RPC (no rounding)")

# ───────────────────────────────────────────────────────────────── paste
ops = [
    {"op": "update_line", "line_id": 21, "expected_version": 1,
     "set": {"sob_state": "allocated_quantity", "sob_allocated_boxes": "0"}},
    {"op": "update_line", "line_id": 22, "expected_version": 1,
     "set": {"sob_state": "percentage", "sob_pct": "0"}},
    {"op": "create_line", "key": "n1", "cycle_id": 11, "scope_text": "Lids",
     "sob_state": "allocated_quantity", "sob_allocated_boxes": "25000"},
]
r, body = p4.preview(ops)
check(r.status_code == 200 and len(RPC_CALLS) == 1 and RPC_CALLS[0][1] == "cph_store_paste_preview",
      "paste: three SOB changes are ONE preview RPC (never per cell)")
payload = RPC_CALLS[0][2]["p_payload"]
by_target = {(o["op"], o.get("line_id") or o.get("key")): o for o in payload}
check(by_target[("update_line", 21)]["set"] == {"sob_state": "allocated_quantity", "sob_pct": None,
                                                "sob_allocated_boxes": "0"},
      "paste: explicit 0 boxes survives as quantity zero, and the % is explicitly cleared")
check(by_target[("update_line", 22)]["set"] == {"sob_state": "percentage", "sob_pct": "0.00",
                                                "sob_allocated_boxes": None},
      "paste: 0% stays percentage zero, and any box value is explicitly cleared")
new = by_target[("create_line", "n1")]
check(new["sob_allocated_boxes"] == "25000" and new["sob_pct"] is None
      and new["customer_location_id"] is None and new["plant_id"] is None and new["sku_id"] is None,
      "paste: a pasted quantity on a new line invents no Location, Plant or SKU")

r, body = p4.preview([{"op": "update_line", "line_id": 21, "expected_version": 1, "set": {"notes": "n"}}])
check(r.status_code == 200 and "sob_state" not in RPC_CALLS[0][2]["p_payload"][0]["set"]
      and "sob_allocated_boxes" not in RPC_CALLS[0][2]["p_payload"][0]["set"],
      "paste: a SOB left blank is ABSENT from the change - it erases neither value")

r, body = p4.preview([{"op": "update_line", "line_id": 21, "expected_version": 1,
                       "set": {"sob_state": "not_captured", "sob_pct": None, "sob_allocated_boxes": None}}])
check(r.status_code == 200 and RPC_CALLS[0][2]["p_payload"][0]["set"] == {
    "sob_state": "not_captured", "sob_pct": None, "sob_allocated_boxes": None},
      "paste: an accepted Clear returns SOB to the chosen explicit state with both values empty")

PASTE_BAD = [
    ("boxes without a state", {"sob_allocated_boxes": "10"}),
    ("fractional boxes", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "10.5"}),
    ("negative boxes", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "-3"}),
    ("boxes on a percentage", {"sob_state": "percentage", "sob_pct": "40", "sob_allocated_boxes": "10"}),
    ("% on an allocated quantity", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "10", "sob_pct": "4"}),
    ("allocated quantity with nothing", {"sob_state": "allocated_quantity"}),
    ("out of range", {"sob_state": "allocated_quantity", "sob_allocated_boxes": "1000000000"}),
]
for label, sob in PASTE_BAD:
    r, payload = p4.preview([{"op": "update_line", "line_id": 22, "expected_version": 1, "set": sob}])
    check(r.status_code == 422 and p4.issues_of(payload) == [(0, "INVALID_INPUT")] and not RPC_CALLS,
          f"paste blocked: {label}, nothing stored")

# ─────────────────────────────────────────────────────────── change history
ROWS["customer_pricing_change_events"] = [
    {"id": 201, "party_id": 245, "entity_type": "line", "entity_id": 21, "operation": "update",
     "content_version": 3, "actor_app_user_id": 42, "occurred_at": "2026-09-24T06:00:00Z",
     "before_state": {"id": 21, "sob_state": "percentage", "sob_pct": 40, "sob_allocated_boxes": None,
                      "content_version": 2},
     "after_state": {"id": 21, "sob_state": "allocated_quantity", "sob_pct": None, "sob_allocated_boxes": 25000,
                     "content_version": 3}},
    {"id": 200, "party_id": 245, "entity_type": "line", "entity_id": 22, "operation": "update",
     "content_version": 2, "actor_app_user_id": 42, "occurred_at": "2026-09-24T05:00:00Z",
     "before_state": {"id": 22, "sob_state": "allocated_quantity", "sob_allocated_boxes": 25000},
     "after_state": {"id": 22, "sob_state": "allocated_quantity", "sob_allocated_boxes": 0}},
]
reset()
r, body = call("GET", p4.CHANGES_URL + "?limit=5")
first, second = body["changes"][0]["fields"], body["changes"][1]["fields"]
check(first == [{"field": "sob_allocated_boxes", "before": None, "after": "25000"},
                {"field": "sob_pct", "before": "40.00", "after": None},
                {"field": "sob_state", "before": "percentage", "after": "allocated_quantity"}],
      "changes: SOB mode and both values show material before/after (boxes as exact strings)")
check(second == [{"field": "sob_allocated_boxes", "before": "25000", "after": "0"}],
      "changes: 25000 -> 0 boxes is a real change to a deliberate zero, not a clear")
check(sum(1 for _, t, _ in TABLE_CALLS if t == "customer_pricing_change_events") == 1,
      "changes: one bounded read (no N+1)")

print()
print(f"{h.PASSES} passed, {len(h.FAILURES)} failed")
if h.FAILURES:
    for f in h.FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("Customer Pricing History P0.4.1 routes gate PASS")
