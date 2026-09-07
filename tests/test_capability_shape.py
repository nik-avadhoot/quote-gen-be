"""
U1-C1 capability-shape gate.

Run:  python tests/test_capability_shape.py

Proves what `caller_context.resolve_caller()` hands every `@require_auth`
route (and, unmodified through `_identity_or_none`, what /auth/login and
/auth/refresh return to the frontend as `profile.group_capabilities` /
`profile.plant_capabilities`): the shape is correct, plant-scoping is
correct, and no capability is invented from a role label - the function
never reads or writes a `role` field when building these two, it only
DERIVES `role` from them afterwards (`_derive_role`), so a coarse label can
never leak a capability the caller does not hold.

Hermetic and offline, same fake-client convention as
tests/test_multi_plant_grants.py. Postgres/RLS is what actually enforces
"revoked/inactive rows are invisible" (the `.eq("status", "active")` calls
below are asserted directly, not just the shape of what comes back, so a
future edit that drops the filter fails this gate even though the fake
does not filter rows itself) - the corresponding end-to-end authorization
outcome is proved separately by the real policies (tests.run_all()).
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


class FakeQuery:
    """Records every .eq() predicate, unlike the other fakes in this suite -
    this file specifically needs to prove the query ASKS for status='active',
    not just that the shaping logic is correct given already-filtered rows."""
    def __init__(self, table, rows, eq_log):
        self.table, self.rows, self.eq_log = table, rows, eq_log

    def select(self, *a, **k): return self
    def eq(self, col, val):
        self.eq_log.append((self.table, col, val))
        return self
    def limit(self, *a, **k): return self
    def execute(self):
        return type("R", (), {"data": self.rows})()


class FakeClient:
    def __init__(self, state):
        self.state, self.eq_log = state, []

    def table(self, name):
        return FakeQuery(name, self.state.get(name, []), self.eq_log)


def resolve(state):
    client = FakeClient(state)
    cc.get_supabase_for_caller = lambda token: client
    return cc.resolve_caller("tok"), client


# ----------------------------------------------- CS-1 one user, group + plant
state = {
    "app_users": [{"id": 1, "auth_user_id": "u1", "display_name": "A", "status": "active"}],
    "group_capability_grants": [
        {"app_user_id": 1, "status": "active", "capabilities": {"capability_key": "read_party_master"}},
    ],
    "plant_capability_grants": [
        {"app_user_id": 1, "plant_id": 10, "status": "active",
         "capabilities": {"capability_key": "make_quote"}, "plants": {"plant_code": "NAG"}},
        {"app_user_id": 1, "plant_id": 11, "status": "active",
         "capabilities": {"capability_key": "check_quote"}, "plants": {"plant_code": "PUN"}},
    ],
}
p, c = resolve(state)
check(p is not None, "CS-1 an active caller with grants resolves")
check(p["group_capabilities"] == ["read_party_master"],
      "CS-1a group capability returned")
check(p["plant_capabilities"] == {"NAG": ["make_quote"], "PUN": ["check_quote"]},
      "CS-1b plant capability keyed by plant CODE, one entry per plant held")

# ---------------------------------------------------- CS-2 scoped to its plant
check("check_quote" not in p["plant_capabilities"]["NAG"],
      "CS-2 a capability at PUN does not appear under NAG")
check("make_quote" not in p["plant_capabilities"]["PUN"],
      "CS-2a and a capability at NAG does not appear under PUN")

# ------------------------------------------------ CS-3 different caps, two plants
state3 = dict(state, plant_capability_grants=[
    {"app_user_id": 1, "plant_id": 10, "status": "active",
     "capabilities": {"capability_key": "make_quote"}, "plants": {"plant_code": "NAG"}},
    {"app_user_id": 1, "plant_id": 10, "status": "active",
     "capabilities": {"capability_key": "check_quote"}, "plants": {"plant_code": "NAG"}},
    {"app_user_id": 1, "plant_id": 11, "status": "active",
     "capabilities": {"capability_key": "make_quote"}, "plants": {"plant_code": "PUN"}},
])
p3, _ = resolve(state3)
check(sorted(p3["plant_capabilities"]["NAG"]) == ["check_quote", "make_quote"],
      "CS-3 one user holding two capabilities at one plant sees both")
check(p3["plant_capabilities"]["PUN"] == ["make_quote"],
      "CS-3a and only one at the other plant")

# ------------------------------------------------ CS-4 the filter is requested
check(("group_capability_grants", "app_user_id", 1) in c.eq_log,
      "CS-4 the group-grant query is scoped to the caller's own id")
check(("group_capability_grants", "status", "active") in c.eq_log,
      "CS-4a and asks Postgres for status='active' - revoked rows are excluded there")
check(("plant_capability_grants", "status", "active") in c.eq_log,
      "CS-4b same filter requested for plant grants")

# --------------------------------------------- CS-5 inactive/unrecognised caller
state5 = {"app_users": [], "group_capability_grants": [], "plant_capability_grants": []}
p5, _ = resolve(state5)
check(p5 is None, "CS-5 no active app_users row resolves to None - the caller is refused")

# ----------------------------------- CS-6 no capability is invented from role
state6 = {
    "app_users": [{"id": 2, "auth_user_id": "u2", "display_name": "Admin", "status": "active"}],
    "group_capability_grants": [
        {"app_user_id": 2, "status": "active", "capabilities": {"capability_key": "administer_users"}},
    ],
    "plant_capability_grants": [],
}
p6, _ = resolve(state6)
check(p6["role"] == "admin", "CS-6 administer_users derives the admin role label")
check(p6["group_capabilities"] == ["administer_users"],
      "CS-6a but group_capabilities holds only what was actually granted"
      " - read_party_master is NOT inferred from the admin role")
check(p6["plant_capabilities"] == {},
      "CS-6b and no plant capability is invented either - none was granted")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("capability-shape gate PASS")
