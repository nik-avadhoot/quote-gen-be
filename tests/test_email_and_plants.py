"""
P2-11/P2-12 email-management and Plant Master gate.

Run:  python tests/test_email_and_plants.py

Hermetic and offline. Supabase is replaced by recording fakes, so every
assertion is about what the ROUTES do: which client they use, what they send,
what they refuse and what they leak.

The DATABASE-side guarantees - capability checks, target resolution from the
app_users row, audit content, session-revocation authorization, active-plant
enforcement - are proved against the real functions and policies by
tests.email_management() (EM-1..EM-17) and tests.plant_master() (PM-1..PM-10).
Neither file is sufficient alone.

Only synthetic identities appear here; every address uses a reserved
.invalid TLD and no real account is referenced.
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


STATE = {
    "rpc": [],              # (token, name, params)
    "privileged": [],       # allow-listed operation names used
    "admin_updates": [],    # (uid, attributes)
    "caller_email_calls": [],
    "password_ok": True,
    "email_update_fails": False,
    "plants": [
        {"id": 10, "plant_code": "NAG", "name": "Nagpur", "status": "active"},
        {"id": 11, "plant_code": "PUN", "name": "Pune", "status": "active"},
        {"id": 12, "plant_code": "KOL", "name": "Kolkata", "status": "active"},
        {"id": 13, "plant_code": "OLD", "name": "Retired", "status": "inactive"},
    ],
}


def reset():
    STATE["rpc"].clear(); STATE["privileged"].clear()
    STATE["admin_updates"].clear(); STATE["caller_email_calls"].clear()
    STATE["password_ok"] = True
    STATE["email_update_fails"] = False


ROWS = {
    "app_users": [{"id": 7, "auth_user_id": "auth-uuid",
                   "display_name": "Tester", "status": "active"}],
    # `id` and `capability_id` are present because _apply_role_and_plant reads
    # them when reconciling a role change - a fake without them fails inside the
    # helper and disguises itself as the assertion failing.
    "group_capability_grants": [
        {"id": 501, "app_user_id": 7, "capability_id": 1, "status": "active",
         "capabilities": {"capability_key": "administer_users"}}],
    "plant_capability_grants": [],
    "capabilities": [{"id": 1, "capability_key": "administer_users"},
                     {"id": 7, "capability_key": "plant_access"},
                     {"id": 8, "capability_key": "make_quote"},
                     {"id": 9, "capability_key": "check_quote"}],
}


class FakeQuery:
    def __init__(self, token, table):
        self.token, self.table = token, table
        self._op, self._payload = None, None

    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def in_(self, *a, **k): return self
    def limit(self, *a, **k): return self
    def update(self, payload): self._op, self._payload = "update", payload; return self
    def insert(self, payload): self._op, self._payload = "insert", payload; return self

    def execute(self):
        if self._op:
            return type("R", (), {"data": [{"id": 1}]})()
        rows = STATE["plants"] if self.table == "plants" else ROWS.get(self.table, [])
        return type("R", (), {"data": rows})()


class FakeAdminAPI:
    def get_user_by_id(self, uid):
        return type("R", (), {"user": type("U", (), {
            "email": "old.address@example.invalid", "email_confirmed_at": None})()})()

    def update_user_by_id(self, uid, attrs):
        if STATE["email_update_fails"]:
            raise RuntimeError("email address already registered")
        STATE["admin_updates"].append((uid, attrs))
        return type("R", (), {"user": type("U", (), {"email": attrs.get("email")})()})()

    def create_user(self, payload):
        return type("C", (), {"user": type("X", (), {"id": "new-auth-uuid"})()})()

    def delete_user(self, uid): return True
    def sign_out(self, token, scope): return True
    def list_users(self): return []


class FakeAuth:
    def __init__(self): self.admin = FakeAdminAPI()

    def get_user(self, tok):
        return type("U", (), {"user": type("X", (), {
            "id": "auth-uuid", "email": "tester@example.invalid"})()})()

    def sign_in_with_password(self, payload):
        if not STATE["password_ok"]:
            raise RuntimeError("invalid credentials")
        return type("R", (), {"session": type("S", (), {"access_token": "t"})(),
                              "user": type("U", (), {"id": "auth-uuid"})()})()


class FakeClient:
    def __init__(self, token, kind):
        self.token, self.kind = token, kind
        self.auth = FakeAuth()

    def table(self, name): return FakeQuery(self.token, name)

    def rpc(self, name, params):
        STATE["rpc"].append((self.token, name, params))
        data = "target-auth-uuid" if name == "admin_prepare_email_change" else 3
        return type("R", (), {"execute": lambda s=None: type("D", (), {"data": data})()})()


def fake_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return FakeClient(token, "caller")


def fake_priv(op):
    if op not in cc.PRIVILEGED_OPERATIONS:
        raise cc.PrivilegeError(op)
    STATE["privileged"].append(op)
    return FakeClient("SERVICE-ROLE", "privileged")


def fake_update_caller_email(token, new_email):
    STATE["caller_email_calls"].append((token, new_email))
    if STATE["email_update_fails"]:
        raise RuntimeError("email address already registered")
    return {"pending_email": True, "current_email": "tester@example.invalid"}


def fake_verify_password(email, password):
    return STATE["password_ok"]


cc.get_supabase_for_caller = fake_caller
cc.privileged_client = fake_priv
cc.get_supabase_anon = lambda: FakeClient(None, "anon")

import server  # noqa: E402
server.get_supabase_for_caller = fake_caller
server.privileged_client = fake_priv
server.get_supabase_anon = cc.get_supabase_anon
server.update_caller_email = fake_update_caller_email
server.verify_current_password = fake_verify_password

import auth as auth_mod  # noqa: E402
auth_mod.get_supabase_for_caller = fake_caller

app = server.app
app.config["TESTING"] = True
AUTH = {"Authorization": "Bearer tok-alpha"}


def post(path, body):
    with app.test_client() as c:
        return c.post(path, json=body, headers=AUTH)


def patch(path, body):
    with app.test_client() as c:
        return c.patch(path, json=body, headers=AUTH)


# ─────────────────────────────────────────────── self-service email change
reset()
r = post("/auth/me/email", {"new_email": "new.address@example.invalid",
                            "current_password": "pw"})
check(r.status_code == 200, "E-1 a self-service email change succeeds")
check(r.get_json().get("pending_verification") is True,
      "E-2 and reports PENDING VERIFICATION rather than claiming success")
check(STATE["caller_email_calls"] and STATE["caller_email_calls"][0][0] == "tok-alpha",
      "E-3 the change is made with the CALLER's own token")
check(STATE["privileged"] == [],
      "E-4 the self-service path uses no service-role client at all")
audit = [x for x in STATE["rpc"] if x[1] == "record_email_change"]
check(len(audit) == 1 and audit[0][2]["p_actor_kind"] == "self",
      "E-5 the change is audited as a self-service change")
check(audit[0][2]["p_app_user"] == 7,
      "E-6 audited against the caller's own application identity")

reset(); STATE["password_ok"] = False
r = post("/auth/me/email", {"new_email": "new.address@example.invalid",
                            "current_password": "wrong"})
check(r.status_code == 401, "E-7 a wrong current password is refused")
check(STATE["caller_email_calls"] == [],
      "E-8 and no change is attempted - re-verification happens FIRST")

reset()
r = post("/auth/me/email", {"new_email": "new.address@example.invalid"})
check(r.status_code == 400, "E-9 the current password is required")

reset()
for bad in ["", "not-an-email", "no@domain", "a b@example.invalid"]:
    r = post("/auth/me/email", {"new_email": bad, "current_password": "pw"})
    if r.status_code != 400:
        break
check(r.status_code == 400, "E-10 an invalid email address is refused")

reset()
r = post("/auth/me/email", {"new_email": "TESTER@example.invalid",
                            "current_password": "pw"})
check(r.status_code == 400, "E-11 changing to your own address is refused (case-insensitively)")

reset(); STATE["email_update_fails"] = True
r = post("/auth/me/email", {"new_email": "taken@example.invalid",
                            "current_password": "pw"})
body = r.data.decode()
check(r.status_code == 400, "E-12 a duplicate address is refused")
check(r.get_json() == {"error": "That email address cannot be used"},
      "E-13 without revealing that another account owns it")
check("already" not in body and "registered" not in body and "exists" not in body,
      "E-13a and without leaking the underlying provider error")

# ─────────────────────────────────────────────── administrator email change
reset()
r = patch("/admin/users/42/email", {"new_email": "moved@example.invalid",
                                    "reason": "surname change"})
check(r.status_code == 200, "E-14 an administrator email change succeeds")
prep = [x for x in STATE["rpc"] if x[1] == "admin_prepare_email_change"]
check(len(prep) == 1 and prep[0][2] == {"p_app_user": 42, "p_reason": "surname change"},
      "E-15 the target is named by APPLICATION identity, never by Auth uuid")
check(prep[0][0] == "tok-alpha",
      "E-15a and the capability check runs under the caller's own token")
check(STATE["admin_updates"] and STATE["admin_updates"][0][0] == "target-auth-uuid",
      "E-16 the Auth identity acted on is the one the DATABASE resolved")
check(STATE["privileged"] == ["auth_admin_update_user"] * len(STATE["privileged"])
      and "auth_admin_update_user" in STATE["privileged"],
      "E-17 only the allow-listed Auth-admin operation is used")
rec = [x for x in STATE["rpc"] if x[1] == "record_email_change"]
check(len(rec) == 1 and rec[0][2]["p_actor_kind"] == "admin"
      and rec[0][2]["p_reason"] == "surname change",
      "E-18 the change is audited as an admin change, with the reason")
rev = [x for x in STATE["rpc"] if x[1] == "revoke_user_sessions"]
check(len(rev) == 1 and rev[0][2] == {"p_app_user": 42},
      "E-19 the affected user's sessions are revoked afterwards")
check(r.get_json().get("sessions_revoked") == 3,
      "E-19a and the count is reported back")
grant_calls = [x for x in STATE["rpc"]
               if x[1] not in ("admin_prepare_email_change", "record_email_change",
                               "revoke_user_sessions")]
check(grant_calls == [],
      "E-20 an email change touches no grant, role or plant RPC")

reset()
r = patch("/admin/users/42/email", {"new_email": "moved@example.invalid", "reason": "   "})
check(r.status_code == 400, "E-21 an administrative reason is required")
check(STATE["admin_updates"] == [], "E-21a and nothing is changed without one")

reset(); STATE["email_update_fails"] = True
r = patch("/admin/users/42/email", {"new_email": "taken@example.invalid", "reason": "x"})
check(r.get_json() == {"error": "That email address cannot be used"},
      "E-22 the admin path also refuses to disclose address ownership")

reset()
r = patch("/admin/users/not-a-number/email",
          {"new_email": "a@example.invalid", "reason": "x"})
check(r.status_code == 404, "E-23 a non-numeric application identity is refused")

# ─────────────────────────────────────────────── Plant Master
reset()
with app.test_client() as c:
    r = c.get("/masters/plants", headers=AUTH)
check(r.status_code == 200, "P-1 the Plant Master view responds")
data = r.get_json()
check([p["plant_code"] for p in data["plants"]] == ["KOL", "NAG", "OLD", "PUN"],
      "P-2 it lists every Plant Master record, ordered by code")
check(all(k in data["plants"][0] for k in ("plant_code", "name", "status")),
      "P-3 with code, name and status")
check(data["active_codes"] == ["KOL", "NAG", "PUN"],
      "P-4 and names exactly the ACTIVE codes separately")
check(data.get("maintenance") == "deferred",
      "P-5 Plant Master maintenance is explicitly reported as deferred")

reset()
r = post("/admin/users", {"email": "n@example.invalid", "display_name": "N",
                          "role": "maker", "plants": []})
check(r.status_code == 400, "P-6 a Maker with no plant is refused")
reset()
r = patch("/admin/users/42", {"role": "checker", "plants": []})
check(r.status_code == 400, "P-7 a Checker cannot be left with no plant")
reset()
r = patch("/admin/users/42", {"role": "admin", "plants": []})
check(r.status_code != 400,
      "P-8 a group-only administrator MAY hold no plant assignment")

reset()
client = FakeClient("tok-alpha", "caller")
try:
    from flask import g as flask_g
    with app.test_request_context():
        flask_g.caller = {"id": 7}
        server._apply_role_and_plant(client, 42, "maker", ["OLD"])
    check(False, "P-9 an INACTIVE plant cannot be assigned")
except ValueError:
    check(True, "P-9 an INACTIVE plant cannot be assigned")
except Exception:
    check(False, "P-9 an INACTIVE plant cannot be assigned")

try:
    with app.test_request_context():
        from flask import g as fg
        fg.caller = {"id": 7}
        server._apply_role_and_plant(FakeClient("tok-alpha", "caller"), 42, "maker", ["ZZZ"])
    check(False, "P-10 arbitrary text cannot become a plant assignment")
except ValueError:
    check(True, "P-10 arbitrary text cannot become a plant assignment")
except Exception:
    check(False, "P-10 arbitrary text cannot become a plant assignment")

check(server._normalise_plants({"plants": ["NAG", "PUN", "KOL"]}) == ["NAG", "PUN", "KOL"],
      "P-11 a multi-plant selection is carried through intact")


# ───────────────────────────── atomic multi-plant creation (failure injection)
#
# The database proves the all-or-nothing grant behaviour (TX-1..TX-13). These
# assert the ROUTE's half of the contract: one call carrying the whole set, and
# complete compensation with a truthful failure when that call fails.

STATE["rpc_fails"] = False
STATE["deleted_auth"] = []


class FailingAdminAPI(FakeAdminAPI):
    def delete_user(self, uid):
        if STATE.get("delete_fails"):
            raise RuntimeError("auth delete unavailable")
        STATE["deleted_auth"].append(uid)
        return True


class TxFakeAuth(FakeAuth):
    def __init__(self):
        super().__init__()
        self.admin = FailingAdminAPI()


class TxFakeClient(FakeClient):
    def __init__(self, token, kind):
        super().__init__(token, kind)
        self.auth = TxFakeAuth()

    def rpc(self, name, params):
        STATE["rpc"].append((self.token, name, params))
        if name == "admin_create_app_user" and STATE.get("rpc_fails"):
            raise RuntimeError("plant is not active and cannot receive assignments")
        data = "target-auth-uuid" if name == "admin_prepare_email_change" else 55
        return type("R", (), {"execute": lambda s=None: type("D", (), {"data": data})()})()


def tx_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return TxFakeClient(token, "caller")


def tx_priv(op):
    if op not in cc.PRIVILEGED_OPERATIONS:
        raise cc.PrivilegeError(op)
    STATE["privileged"].append(op)
    return TxFakeClient("SERVICE-ROLE", "privileged")


server.get_supabase_for_caller = tx_caller
server.privileged_client = tx_priv

# T-1..T-3: the happy path sends ONE call carrying all three plants
reset(); STATE["rpc_fails"] = False; STATE["delete_fails"] = False
STATE["deleted_auth"].clear()
r = post("/admin/users", {"email": "n@example.invalid", "display_name": "N",
                          "role": "maker", "plants": ["NAG", "PUN", "KOL"]})
creates = [x for x in STATE["rpc"] if x[1] == "admin_create_app_user"]
check(r.status_code == 201, "T-1 creating a Maker with NAG+PUN+KOL succeeds")
check(len(creates) == 1,
      "T-2 exactly ONE create call is made - the set is not applied in stages")
check(creates[0][2].get("p_plant_codes") == ["NAG", "PUN", "KOL"],
      "T-3 and that single call carries the WHOLE requested plant set")
check(r.get_json().get("plants") == ["NAG", "PUN", "KOL"],
      "T-4 the response reports the full set that was actually requested")
check(STATE["deleted_auth"] == [],
      "T-5 nothing is compensated on the success path")

# T-6..T-9: failure part-way through must leave nothing and admit it
reset(); STATE["rpc_fails"] = True; STATE["delete_fails"] = False
STATE["deleted_auth"].clear()
r = post("/admin/users", {"email": "n2@example.invalid", "display_name": "N2",
                          "role": "maker", "plants": ["NAG", "PUN", "KOL"]})
check(r.status_code == 400,
      "T-6 a failure applying the plant set returns a TRUTHFUL failure, not 201")
check("plants" not in (r.get_json() or {}),
      "T-6a and reports no plant access it did not grant")
check(STATE["deleted_auth"] == ["new-auth-uuid"],
      "T-7 the Auth account is deleted - no orphan survives the failure")
follow_up = [x for x in STATE["rpc"] if x[1] != "admin_create_app_user"]
check(follow_up == [],
      "T-8 no follow-up grant call is attempted after the failed creation")
check(len([x for x in STATE["rpc"] if x[1] == "admin_create_app_user"]) == 1,
      "T-9 and the creation is not retried into a partial state")

# T-10: if compensation ITSELF fails, say so rather than claim success
reset(); STATE["rpc_fails"] = True; STATE["delete_fails"] = True
STATE["deleted_auth"].clear()
r = post("/admin/users", {"email": "n3@example.invalid", "display_name": "N3",
                          "role": "maker", "plants": ["NAG", "PUN"]})
check(r.status_code == 500,
      "T-10 a failed compensation is reported as a failure, never as success")
check("Contact an administrator" in (r.get_json() or {}).get("error", ""),
      "T-10a and says the account needs manual cleanup")

STATE["rpc_fails"] = False
STATE["delete_fails"] = False
server.get_supabase_for_caller = fake_caller
server.privileged_client = fake_priv

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("email + Plant Master gate PASS")
