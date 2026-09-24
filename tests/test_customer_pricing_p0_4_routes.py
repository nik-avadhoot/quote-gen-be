"""
Customer Pricing History P0.4 (Excel paste + change history) routes gate.

Run:  venv/Scripts/python tests/test_customer_pricing_p0_4_routes.py

Hermetic and offline; reuses the recording-fake harness of the P0.1/P0.2 gates
(importing the P0.2 gate runs P0.1 and P0.2 first, on the same fake rows).
Proves what the ROUTES decide: a paste batch is validated against the caller's
own bounded read and sent to the database as ONE preview RPC (never one per
cell), every refusal is a per-operation issue with a stable code and no RPC,
blank-vs-zero and explicit-clear survive normalisation, identities are never
resolved by anything but exact ids, and apply forwards only the preview id +
digest. The change-history page carries server-computed before/after.

Database behaviour (binding, expiry, CAS, atomic rollback with audit) is proved
by tests/cph_p0_4_rollback_rehearsal.sql.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
import test_customer_pricing_p0_2_routes  # noqa: E402,F401  (runs the P0.1 and P0.2 gates first)
import test_customer_pricing_history_routes as h  # noqa: E402

check, call, reset, api_error = h.check, h.call, h.reset, h.api_error
RPC_CALLS, TABLE_CALLS, ROWS, TABLE_ERRORS = h.RPC_CALLS, h.TABLE_CALLS, h.ROWS, h.TABLE_ERRORS
h.PASSES = 0
del h.FAILURES[:]
print("\n-- P0.4 --")

# The fake query learns `lt` (keyset paging) for the change-history route.
_orig_execute = h.FakeQuery.execute


def _lt(self, col, val):
    self.filters.append(("lt", col, val))
    return self


def _execute(self):
    lts = [f for f in self.filters if f[0] == "lt"]
    self.filters = [f for f in self.filters if f[0] != "lt"]
    result = _orig_execute(self)
    for _, col, val in lts:
        result.data = [r for r in result.data if r.get(col) is not None and r[col] < val]
    return result


h.FakeQuery.lt = _lt
h.FakeQuery.execute = _execute

# Fixture rows on top of the P0.2 state: line 21 (scope "All RSC", term 51, BF set 61),
# line 22 ("Trays"), cycle 11 v1, round 31 with snapshotted BF 16 / 20 (override 56) / 22GY.
ROWS["customer_locations"] = [{"id": 501, "location_code": "PUNE", "status": "active"},
                              {"id": 502, "location_code": "KOLKATA", "status": "active"}]
ROWS["plants"] = [{"id": 1, "plant_code": "NAG", "name": "Nagpur", "status": "active"},
                  {"id": 2, "plant_code": "PUN", "name": "Pune", "status": "active"}]
for event in ROWS["customer_pricing_negotiation_events"]:
    event.setdefault("content_version", 1)
    event.setdefault("status", "active")
next(e for e in ROWS["customer_pricing_negotiation_events"] if e["id"] == 31)["content_version"] = 3

PREVIEW_URL = "/masters/parties/245/pricing-paste/preview"
APPLY_URL = "/masters/parties/245/pricing-paste/apply"
CHANGES_URL = "/masters/parties/245/pricing-history/changes"
UUID = "3f0c1a52-2b61-4d7e-9a57-7e3d7c2b9f10"
DIGEST = "a" * 64
STORED = {"preview_id": UUID, "digest": DIGEST, "expires_at": "2026-09-24T05:00:00Z", "operations": 4}


def preview(ops, rpc_response=STORED):
    reset("cph_store_paste_preview", rpc_response)
    return call("POST", PREVIEW_URL, {"operations": ops})


def issues_of(payload):
    return [(i["index"], i["code"]) for i in payload.get("issues", [])]


# ─────────────────────────────────────────── anonymous and unauthorised callers
for label, method, path, body in (("preview", "POST", PREVIEW_URL, {"operations": [{"op": "update_line"}]}),
                                  ("apply", "POST", APPLY_URL, {"preview_id": UUID, "digest": DIGEST}),
                                  ("changes", "GET", CHANGES_URL, None)):
    reset()
    r, _ = call(method, path, body, headers={})
    check(r.status_code == 401 and not RPC_CALLS, f"{label}: anonymous refused 401 before any RPC")
    ROWS["group_capability_grants"] = []
    reset()
    r, payload = call(method, path, body)
    check(r.status_code == 403 and payload.get("error_code") == "CAPABILITY_REQUIRED" and not RPC_CALLS
          and not any(t.startswith("customer_pricing") for _, t, _ in TABLE_CALLS),
          f"{label}: without read_party_master refused 403, no pricing read, no RPC")
    ROWS["group_capability_grants"] = list(h.READER)

# ───────────────────────────────────────────────────────────── happy batch
ops = [
    {"op": "add_round", "line_key": "n1", "event_type": "final_agreement", "event_date": "2026-09-02",
     "rate_inr": "54.5", "source_ref": "Pasted: 54.5", "client_request_id": "client-picked-is-ignored"},
    {"op": "create_line", "key": "n1", "cycle_id": 11, "customer_location_id": 501, "plant_id": 1,
     "sku_id": 987, "scope_text": "Lids"},
    {"op": "update_line", "line_id": 21, "expected_version": 1,
     "set": {"sob_state": "percentage", "sob_pct": "0", "notes": None}},
    {"op": "update_cycle", "cycle_id": 11, "expected_version": 1, "set": {"custom_label": " Sep revised "}},
    {"op": "set_bf_override", "event_id": 31, "expected_version": 3, "bf_code": "22gy", "override_rate_inr": "57.1"},
]
r, body = preview(ops)
check(r.status_code == 200 and body.get("preview_id") == UUID and body.get("digest") == DIGEST,
      "preview: a valid batch is stored and its preview id + digest returned")
check(len(RPC_CALLS) == 1 and RPC_CALLS[0][1] == "cph_store_paste_preview" and RPC_CALLS[0][0] == "tok-x",
      "preview: FIVE pasted changes are ONE database call on the caller's token (never per cell)")
sent = RPC_CALLS[0][2]
check(sent["p_party"] == 245, "preview: bound to the Customer in the path")
payload = sent["p_payload"]
check([o["op"] for o in payload] == ["update_cycle", "update_line", "create_line", "add_round", "set_bf_override"],
      "preview: operations are applied in a fixed order (records before the rounds that name them)")
check(payload[1]["set"] == {"sob_state": "percentage", "sob_pct": "0.00", "sob_allocated_boxes": None, "notes": None},
      "preview: explicit zero SOB stays 0.00; an accepted clear is an explicit null")
check("scope_text" not in payload[1]["set"],
      "preview: a field the paste left blank is ABSENT (kept), never sent as a clear")
check(payload[0]["set"] == {"custom_label": "Sep revised"}, "preview: text is trimmed, only the named field changes")
check(payload[3]["rate_inr"] == "54.50" and payload[3]["line_key"] == "n1" and payload[3]["line_id"] is None,
      "preview: INR normalised to an exact two-decimal string; the round names its new line by key")
check(re.fullmatch(r"[0-9a-f-]{36}", payload[3]["client_request_id"])
      and payload[3]["client_request_id"] != "client-picked-is-ignored",
      "preview: the round's idempotency key is generated by the server, not trusted from the client")
check(payload[4]["bf_code"] == "22GY" and payload[4]["override_rate_inr"] == "57.10"
      and payload[4]["expected_version"] == 3,
      "preview: BF grade matched exactly (case only), override exact, CAS version of the round carried")
check(body.get("normalised") == payload, "preview: the response shows exactly what was stored")
check(sum(1 for _, t, _ in TABLE_CALLS if t == "customer_pricing_lines") == 1,
      "preview: validation reads the Customer's history once (no N+1)")

# ───────────────────────────────────────────── refusals: per-operation issues
CASES = [
    ("stale Line version", [{"op": "update_line", "line_id": 21, "expected_version": 9, "set": {"notes": "x"}}],
     [(0, "STALE_VERSION")]),
    ("stale round version", [{"op": "set_bf_override", "event_id": 31, "expected_version": 2, "bf_code": "20",
                              "override_rate_inr": "1.00"}], [(0, "STALE_VERSION")]),
    ("another Customer's / unknown Line", [{"op": "update_line", "line_id": 777, "expected_version": 1,
                                           "set": {"notes": "x"}}], [(0, "RECORD_NOT_FOUND")]),
    ("unknown Location id", [{"op": "create_line", "key": "a", "cycle_id": 11, "customer_location_id": 999}],
     [(0, "UNRESOLVED_IDENTITY")]),
    ("SKU at another Plant", [{"op": "create_line", "key": "a", "cycle_id": 11, "plant_id": 2, "sku_id": 987}],
     [(0, "UNRESOLVED_IDENTITY")]),
    ("new Line duplicating an existing scope", [{"op": "create_line", "key": "a", "cycle_id": 11, "scope_text": "all rsc"}],
     [(0, "DUPLICATE_RECORD")]),
    ("two new Lines with one scope (second is the duplicate)",
     [{"op": "create_line", "key": "a", "cycle_id": 11, "scope_text": "Lids"},
      {"op": "create_line", "key": "b", "cycle_id": 11, "scope_text": " LIDS "}], [(1, "DUPLICATE_RECORD")]),
    ("scope edit colliding with another Line", [{"op": "update_line", "line_id": 22, "expected_version": 1,
                                                 "set": {"scope_text": "All RSC"}}], [(0, "DUPLICATE_RECORD")]),
    ("same round already recorded", [{"op": "add_round", "line_id": 21, "event_type": "customer_counter",
                                      "event_date": "2026-08-28", "rate_inr": "94"}], [(0, "DUPLICATE_RECORD")]),
    ("rate sent as a JSON float", [{"op": "add_round", "line_id": 22, "event_type": "avadhoot_offer",
                                    "event_date": "2026-09-01", "rate_inr": 54.5}], [(0, "INVALID_INPUT")]),
    ("three-decimal rate", [{"op": "add_round", "line_id": 22, "event_type": "avadhoot_offer",
                             "event_date": "2026-09-01", "rate_inr": "54.555"}], [(0, "INVALID_INPUT")]),
    ("impossible date", [{"op": "add_round", "line_id": 22, "event_type": "avadhoot_offer",
                          "event_date": "2026-02-30", "rate_inr": "1.00"}], [(0, "INVALID_INPUT")]),
    ("SOB above 100%", [{"op": "update_line", "line_id": 22, "expected_version": 1,
                         "set": {"sob_state": "percentage", "sob_pct": "100.01"}}], [(0, "INVALID_INPUT")]),
    ("SOB % without a state", [{"op": "update_line", "line_id": 22, "expected_version": 1, "set": {"sob_pct": "5"}}],
     [(0, "INVALID_INPUT")]),
    ("BF floor breached by a pasted base rate", [{"op": "add_round", "line_id": 21, "event_type": "avadhoot_offer",
                                                  "event_date": "2026-09-01", "rate_inr": "0.50"}], [(0, "INVALID_INPUT")]),
    ("override on the base BF", [{"op": "set_bf_override", "event_id": 31, "expected_version": 3, "bf_code": "18",
                                  "override_rate_inr": "1.00"}], [(0, "INVALID_INPUT")]),
    ("grade not in the round's snapshot", [{"op": "set_bf_override", "event_id": 31, "expected_version": 3,
                                            "bf_code": "24", "override_rate_inr": "1.00"}], [(0, "UNRESOLVED_IDENTITY")]),
    ("clearing an override that is not there", [{"op": "set_bf_override", "event_id": 31, "expected_version": 3,
                                                 "bf_code": "16", "override_rate_inr": None}], [(0, "INVALID_INPUT")]),
    ("same grade twice", [{"op": "set_bf_override", "event_id": 31, "expected_version": 3, "bf_code": "16",
                           "override_rate_inr": "1.00"},
                          {"op": "set_bf_override", "event_id": 31, "expected_version": 3, "bf_code": "16",
                           "override_rate_inr": "2.00"}], [(1, "DUPLICATE_RECORD")]),
    ("identity field is not a paste target", [{"op": "update_line", "line_id": 22, "expected_version": 1,
                                               "set": {"plant_id": 1}}], [(0, "INVALID_INPUT")]),
    ("unknown operation", [{"op": "update_mechanism", "set": {"rate_basis": "box_per_piece"}}], [(0, "INVALID_INPUT")]),
    ("round naming a new line outside the batch", [{"op": "add_round", "line_key": "zz", "event_type": "avadhoot_offer",
                                                    "event_date": "2026-09-01", "rate_inr": "1.00"}], [(0, "INVALID_INPUT")]),
]
for label, case_ops, expected in CASES:
    r, payload = preview(case_ops)
    check(r.status_code == 422 and payload.get("error_code") == "PASTE_BLOCKED"
          and issues_of(payload) == expected and not RPC_CALLS,
          f"blocked: {label} -> {expected}, nothing stored")

r, payload = preview([{"op": "add_round", "line_id": 21, "event_type": "customer_counter",
                       "event_date": "2026-08-28", "rate_inr": "94", "accept_possible_duplicate": True}])
check(r.status_code == 200 and len(RPC_CALLS) == 1,
      "duplicate round: stored only once the user explicitly accepts the possible duplicate")
r, payload = preview([{"op": "update_line", "line_id": 22, "expected_version": 1, "set": {"notes": "ok"}},
                      {"op": "update_line", "line_id": 777, "expected_version": 1, "set": {"notes": "x"}}])
check(r.status_code == 422 and issues_of(payload) == [(1, "RECORD_NOT_FOUND")] and not RPC_CALLS,
      "blocked: one bad operation blocks the whole batch; nothing is partially stored")

for n in (0, 201):
    reset()
    r, payload = call("POST", PREVIEW_URL, {"operations": [{"op": "update_line"}] * n})
    check(r.status_code == 413 and payload.get("error_code") == "PASTE_TOO_LARGE" and not RPC_CALLS
          and not any(t.startswith("customer_pricing") for _, t, _ in TABLE_CALLS), f"bounds: {n} operations refused 413 before any read or RPC")

good = [{"op": "update_line", "line_id": 22, "expected_version": 1, "set": {"notes": "ok"}}]
for sqlstate, code, status in (("PT409", "STALE_VERSION", 409), ("PT413", "PASTE_TOO_LARGE", 413),
                               ("42501", "CAPABILITY_REQUIRED", 403), ("P0002", "RECORD_NOT_FOUND", 404)):
    r, payload = preview(good, api_error(sqlstate, "raw database text"))
    check(r.status_code == status and payload.get("error_code") == code and "raw database text" not in str(payload),
          f"preview: database {sqlstate} -> {code} / {status}, no database text")

TABLE_ERRORS["customer_pricing_mechanisms"] = api_error("42P01")
RPC_CALLS.clear()
r, payload = call("POST", PREVIEW_URL, {"operations": good})
check(r.status_code == 503 and payload.get("error_code") == "MASTER_UNAVAILABLE" and not RPC_CALLS,
      "preview: an environment without the pricing migrations says MASTER_UNAVAILABLE")
TABLE_ERRORS.clear()

# ───────────────────────────────────────────────────────────────────── apply
reset("cph_apply_paste", {"applied": 5, "created_lines": {"n1": 91}, "preview_id": UUID})
r, body = call("POST", APPLY_URL, {"preview_id": UUID, "digest": DIGEST, "operations": [{"op": "ignored"}]})
check(r.status_code == 200 and body.get("applied") == 5, "apply: returns the applied count")
check(RPC_CALLS == [("tok-x", "cph_apply_paste", {"p_party": 245, "p_preview": UUID, "p_digest": DIGEST})],
      "apply: ONE RPC naming only Customer, preview id and digest - a client payload is ignored")
for label, bad in (("bad preview id", {"preview_id": "nope", "digest": DIGEST}),
                   ("bad digest", {"preview_id": UUID, "digest": "short"})):
    reset()
    r, payload = call("POST", APPLY_URL, bad)
    check(r.status_code == 400 and not RPC_CALLS, f"apply: {label} refused 400 before any RPC")
for sqlstate, code, status in (("PT410", "PREVIEW_EXPIRED", 410), ("PT412", "PREVIEW_MISMATCH", 409),
                               ("PT409", "STALE_VERSION", 409), ("23505", "DUPLICATE_RECORD", 409),
                               ("23514", "INVALID_INPUT", 400), ("P0002", "RECORD_NOT_FOUND", 404)):
    reset("cph_apply_paste", api_error(sqlstate, "raw database text"))
    r, payload = call("POST", APPLY_URL, {"preview_id": UUID, "digest": DIGEST})
    check(r.status_code == status and payload.get("error_code") == code and "raw database text" not in str(payload),
          f"apply: database {sqlstate} -> {code} / {status} (the whole batch rolled back), no database text")

# ─────────────────────────────────────────────────────────── change history
ROWS["customer_pricing_change_events"] = [
    {"id": 103, "party_id": 245, "entity_type": "line", "entity_id": 21, "operation": "update",
     "content_version": 2, "actor_app_user_id": 42, "occurred_at": "2026-09-24T04:00:00Z",
     "before_state": {"id": 21, "sob_state": "percentage", "sob_pct": 60, "notes": None, "updated_at": "a",
                      "content_version": 1},
     "after_state": {"id": 21, "sob_state": "percentage", "sob_pct": 0, "notes": None, "updated_at": "b",
                     "content_version": 2}},
    {"id": 102, "party_id": 245, "entity_type": "event_bf_rate", "entity_id": 2, "operation": "update",
     "content_version": 2, "actor_app_user_id": 43, "occurred_at": "2026-09-23T04:00:00Z",
     "before_state": {"override_rate_inr": None}, "after_state": {"override_rate_inr": 57.1}},
    {"id": 101, "party_id": 245, "entity_type": "negotiation_event", "entity_id": 31, "operation": "create",
     "content_version": 1, "actor_app_user_id": 42, "occurred_at": "2026-09-22T04:00:00Z",
     "before_state": None, "after_state": {"id": 31, "rate_inr": 54.3, "event_type": "avadhoot_offer",
                                           "notes": None, "created_by": 42}},
]
reset()
r, body = call("GET", CHANGES_URL + "?limit=2")
check(r.status_code == 200 and [c["id"] for c in body["changes"]] == [103, 102] and body["has_more"]
      and body["next_before_id"] == 102, "changes: newest first, bounded page, keyset cursor for the next page")
first = body["changes"][0]
check(first["fields"] == [{"field": "sob_pct", "before": "60.00", "after": "0.00"}],
      "changes: material before/after only (audit columns hidden); 0.00 stays a value")
check(body["changes"][1]["fields"] == [{"field": "override_rate_inr", "before": None, "after": "57.10"}],
      "changes: an override set from blank shows blank -> exact two decimals")
check(first["actor_name"] == "Maker" and body["changes"][1]["actor_name"] is None and body["actor_names_partial"],
      "changes: actor named when readable; an unreadable actor is reported missing, never guessed")
check(all(tok == "tok-x" for tok, _, _ in TABLE_CALLS), "changes: every read uses the caller's token")
reset()
r, body = call("GET", CHANGES_URL + "?limit=2&before_id=102")
check([c["id"] for c in body["changes"]] == [101] and not body["has_more"] and body["next_before_id"] is None,
      "changes: the next page continues strictly before the cursor and says when it is the last")
created = body["changes"][0]["fields"]
check({"field": "rate_inr", "before": None, "after": "54.30"} in created
      and not any(f["field"] in ("created_by", "id", "notes") for f in created),
      "changes: a create lists its recorded (non-blank) values, not audit columns")
for q in ("?limit=0", "?limit=201", "?before_id=x"):
    reset()
    r, _ = call("GET", CHANGES_URL + q)
    check(r.status_code == 400 and not any(t.startswith("customer_pricing") for _, t, _ in TABLE_CALLS),
          f"changes: {q} refused 400 before any read")
TABLE_ERRORS["customer_pricing_change_events"] = api_error("42501")
reset()
TABLE_ERRORS["customer_pricing_change_events"] = api_error("42501")
r, payload = call("GET", CHANGES_URL)
check(r.status_code == 403 and payload.get("error_code") == "CAPABILITY_REQUIRED",
      "changes: an RLS denial is an explicit 403, never an empty history")
TABLE_ERRORS.clear()

print()
print(f"{h.PASSES} passed, {len(h.FAILURES)} failed")
if h.FAILURES:
    for f in h.FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("Customer Pricing History P0.4 routes gate PASS")
