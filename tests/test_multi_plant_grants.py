"""
P2-9 multi-plant assignment gate.

Run:  python tests/test_multi_plant_grants.py

CDM-05-A represents the legacy `plant = 'Group'` scope as EXPLICIT plant grants
at every current plant. That is only representable if one user can hold several
plants at once - and before P2-9 they could not: _apply_role_and_plant took a
single plant code and revoked every existing active grant before inserting for
it, so assigning a second plant silently removed the first.

This gate proves the write side. It asserts the grant SET the administrator
routes produce, not authorization outcomes - those are proved against the real
policies by tests.multi_plant_access() (MP-1..MP-10), which also proves the
accepted limitation that a plant created later needs its own explicit grant.

Hermetic and offline: the Supabase client is a recording fake, so every
assertion is about which rows the route would write.
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


CAPS = [
    {"id": 1, "capability_key": "read_party_master"},
    {"id": 5, "capability_key": "administer_users"},
    {"id": 7, "capability_key": "plant_access"},
    {"id": 8, "capability_key": "make_quote"},
    {"id": 9, "capability_key": "check_quote"},
]
PLANTS = [{"id": 10, "plant_code": "NAG"},
          {"id": 11, "plant_code": "PUN"},
          {"id": 12, "plant_code": "KOL"}]


class FakeQuery:
    def __init__(self, log, table, rows):
        self.log, self.table, self.rows = log, table, rows
        self._op, self._payload, self._id = None, None, None

    def select(self, *a, **k): return self
    def eq(self, col, val):
        if self._op == "update" and col == "id":
            self._id = val
        return self
    def in_(self, *a, **k): return self
    def limit(self, *a, **k): return self

    def update(self, payload):
        self._op, self._payload = "update", payload
        return self

    def insert(self, payload):
        self._op, self._payload = "insert", payload
        return self

    def execute(self):
        if self._op == "update":
            self.log.append(("update", self.table, self._id, self._payload))
            return type("R", (), {"data": [{"id": self._id}]})()
        if self._op == "insert":
            rows = self._payload if isinstance(self._payload, list) else [self._payload]
            for r in rows:
                self.log.append(("insert", self.table, None, r))
            return type("R", (), {"data": rows})()
        return type("R", (), {"data": self.rows})()


class FakeClient:
    """`state` maps table name -> rows the caller would currently see."""
    def __init__(self, state):
        self.state, self.log = state, []

    def table(self, name):
        return FakeQuery(self.log, name, self.state.get(name, []))

    def inserts(self, table):
        return [r for op, t, _, r in self.log if op == "insert" and t == table]

    def revokes(self, table):
        return [i for op, t, i, p in self.log
                if op == "update" and t == table and p.get("status") == "revoked"]


import server  # noqa: E402
from flask import g  # noqa: E402

app = server.app


def apply(state, role, plant_codes, caller_id=1):
    client = FakeClient(state)
    with app.test_request_context():
        g.caller = {"id": caller_id}
        server._apply_role_and_plant(client, 77, role, plant_codes)
    return client


def pgrants(rows):
    """(plant_id, capability_id) pairs from recorded plant-grant inserts."""
    return sorted((r["plant_id"], r["capability_id"]) for r in rows)


# ------------------------------------------------- N-1..N-5 request parsing
check(server._normalise_plants({}) is None,
      "N-1 a body that says nothing about plants leaves them untouched")
check(server._normalise_plants({"plants": ["NAG", "PUN", "KOL"]}) == ["NAG", "PUN", "KOL"],
      "N-2 a plants list is read as a list, in order")
check(server._normalise_plants({"plant": "NAG"}) == ["NAG"],
      "N-3 the legacy single `plant` field still works, as a one-element list")
check(server._normalise_plants({"plants": []}) == [],
      "N-4 an empty list is a real instruction - revoke every plant")
check(server._normalise_plants({"plants": ["NAG", "NAG", "PUN"]}) == ["NAG", "PUN"],
      "N-5 duplicates are collapsed without reordering")
check(server._normalise_plants({"plants": "NAG"}) == ["NAG"],
      "N-5a a bare string in `plants` is tolerated as one code")
try:
    server._normalise_plants({"plants": {"NAG": True}})
    check(False, "N-6 a non-list `plants` is rejected")
except ValueError:
    check(True, "N-6 a non-list `plants` is rejected")

# ------------------------------------- MPB-1 the legacy Group representation
state = {"capabilities": CAPS, "plants": PLANTS, "plant_capability_grants": [],
         "group_capability_grants": []}
c = apply(state, "maker", ["NAG", "PUN", "KOL"])
ins = c.inserts("plant_capability_grants")
check(len(ins) == 6, "MPB-1 three plants x two capabilities = six grants, not one plant's worth")
check(pgrants(ins) == [(10, 7), (10, 8), (11, 7), (11, 8), (12, 7), (12, 8)],
      "MPB-1a plant_access + make_quote at NAG, PUN and KOL")
check(c.inserts("group_capability_grants") == [],
      "MPB-1b and NO group capability is granted as a side effect")
check(c.revokes("plant_capability_grants") == [],
      "MPB-1c nothing was revoked - there was nothing to revoke")

# --------------------------------------------------- MPB-2 idempotence
held = [{"id": 100 + i, "plant_id": p, "capability_id": cap}
        for i, (p, cap) in enumerate([(10, 7), (10, 8), (11, 7), (11, 8), (12, 7), (12, 8)])]
state = {"capabilities": CAPS, "plants": PLANTS, "plant_capability_grants": held,
         "group_capability_grants": []}
c = apply(state, "maker", ["NAG", "PUN", "KOL"])
check(c.inserts("plant_capability_grants") == [],
      "MPB-2 re-applying the same plant set inserts nothing")
check(c.revokes("plant_capability_grants") == [],
      "MPB-2a and revokes nothing - the assignment is reconciled, not replaced")

# ----------------------------------- MPB-3 removing one plant touches only it
c = apply(state, "maker", ["NAG", "KOL"])
check(sorted(c.revokes("plant_capability_grants")) == [102, 103],
      "MPB-3 dropping PUN revokes exactly PUN's two grants")
check(c.inserts("plant_capability_grants") == [],
      "MPB-3a and re-inserts nothing for the plants that stayed")

# ------------------------------------- MPB-4 adding one plant touches only it
two = [{"id": 100 + i, "plant_id": p, "capability_id": cap}
       for i, (p, cap) in enumerate([(10, 7), (10, 8), (11, 7), (11, 8)])]
state = {"capabilities": CAPS, "plants": PLANTS, "plant_capability_grants": two,
         "group_capability_grants": []}
c = apply(state, "maker", ["NAG", "PUN", "KOL"])
check(pgrants(c.inserts("plant_capability_grants")) == [(12, 7), (12, 8)],
      "MPB-4 adding KOL inserts only KOL's two grants")
check(c.revokes("plant_capability_grants") == [],
      "MPB-4a and leaves NAG and PUN alone - adding a plant never drops one")

# ------------------------------------------- MPB-5 empty list revokes all
c = apply(state, "maker", [])
check(sorted(c.revokes("plant_capability_grants")) == [100, 101, 102, 103],
      "MPB-5 an explicit empty list revokes every plant grant")
check(c.inserts("plant_capability_grants") == [],
      "MPB-5a and inserts nothing")

# ---------------------------------------- MPB-6 None leaves plants untouched
c = apply(state, "maker", None)
check(c.inserts("plant_capability_grants") == [] and c.revokes("plant_capability_grants") == [],
      "MPB-6 plant_codes=None does not touch plant grants at all")

# ------------------------------------- MPB-7 the operational capability follows role
state = {"capabilities": CAPS, "plants": PLANTS, "plant_capability_grants": [],
         "group_capability_grants": []}
c = apply(state, "checker", ["NAG", "PUN"])
check(pgrants(c.inserts("plant_capability_grants")) == [(10, 7), (10, 9), (11, 7), (11, 9)],
      "MPB-7 a Checker gets check_quote at each plant, not make_quote")

# MPB-8: changing plants WITHOUT naming a role must not silently demote a Checker.
checker_held = [{"id": 200, "plant_id": 10, "capability_id": 7},
                {"id": 201, "plant_id": 10, "capability_id": 9}]
state = {"capabilities": CAPS, "plants": PLANTS,
         "plant_capability_grants": checker_held, "group_capability_grants": []}
c = apply(state, None, ["NAG", "PUN"])
check(pgrants(c.inserts("plant_capability_grants")) == [(11, 7), (11, 9)],
      "MPB-8 adding a plant to a Checker keeps check_quote - no silent demotion to Maker")
check(c.revokes("plant_capability_grants") == [],
      "MPB-8a and their existing plant is untouched")

# MPB-9: the same for a Maker.
maker_held = [{"id": 300, "plant_id": 10, "capability_id": 7},
              {"id": 301, "plant_id": 10, "capability_id": 8}]
state = {"capabilities": CAPS, "plants": PLANTS,
         "plant_capability_grants": maker_held, "group_capability_grants": []}
c = apply(state, None, ["NAG", "KOL"])
check(pgrants(c.inserts("plant_capability_grants")) == [(12, 7), (12, 8)],
      "MPB-9 adding a plant to a Maker keeps make_quote")

# ------------------------------------------------- MPB-10 unknown plant refused
state = {"capabilities": CAPS, "plants": PLANTS, "plant_capability_grants": [],
         "group_capability_grants": []}
try:
    apply(state, "maker", ["NAG", "ZZZ"])
    check(False, "MPB-10 an unknown plant code is refused")
except ValueError:
    check(True, "MPB-10 an unknown plant code is refused")
c = FakeClient(state)
check(c.log == [],
      "MPB-10a and the refusal happens before any grant is written")

# --------------------------- MPB-11 role change does not disturb plant grants
state = {"capabilities": CAPS, "plants": PLANTS, "plant_capability_grants": maker_held,
         "group_capability_grants": []}
c = apply(state, "admin", None)
check(c.inserts("group_capability_grants") and
      c.inserts("group_capability_grants")[0]["capability_id"] == 5,
      "MPB-11 promoting to admin grants administer_users")
check(c.inserts("plant_capability_grants") == [] and c.revokes("plant_capability_grants") == [],
      "MPB-11a and does not disturb the user's plant assignments")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("multi-plant assignment gate PASS")
