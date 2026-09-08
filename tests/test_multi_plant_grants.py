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
# `status` is present because a Plant Master record is only assignable while it
# is ACTIVE (CDM-05-A / P2-12). A fixture without it would let this gate pass
# against a rule the database enforces, which is worse than no fixture at all.
PLANTS = [{"id": 10, "plant_code": "NAG", "status": "active"},
          {"id": 11, "plant_code": "PUN", "status": "active"},
          {"id": 12, "plant_code": "KOL", "status": "active"},
          {"id": 13, "plant_code": "OLD", "status": "inactive"}]


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

# ═══════════════════════════════════════════════════════════════════════════
# UA-3/UA-4. The MPB-* cases below this line used to drive
# server._apply_role_and_plant, which reconciled plant grants with a sequence of
# separate PostgREST statements. That helper is GONE.
#
# Grant reconciliation is now ONE governed database operation,
# app_private.set_user_capabilities, and the properties those cases asserted are
# proved where the behaviour actually lives - in tests.user_capability_governance
# (registered in tests.run_all()):
#
#   MPB-1  several plants x their capabilities   -> UC-12
#   MPB-2  idempotence, no churn                 -> UC-14
#   MPB-3  preservation of unchanged grants      -> UC-15
#   MPB-4  revoking everything                   -> UC-16
#   attribution to the resolved caller           -> UC-13 / UC-16
#
# A route-level fake cannot prove atomicity, locking or a CAS conflict, so
# restating them here with a recording client would have been theatre. What
# REMAINS route-level, and is still tested above, is request parsing; the
# capability route's own code->id translation and its refusal of unknown or
# inactive plants are covered in test_email_and_plants.py (P-9, P-10).
# ═══════════════════════════════════════════════════════════════════════════

check(not hasattr(server, "_apply_role_and_plant"),
      "MPB-R1 the legacy multi-statement grant reconciler no longer exists")

with app.test_request_context():
    check(any(str(r) == "/admin/users/<uid>/capabilities"
              for r in app.url_map.iter_rules()),
          "MPB-R2 the governed capability route is registered")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
print("multi-plant assignment gate " + ("PASS" if not FAILURES else "FAIL"))
sys.exit(0 if not FAILURES else 1)
