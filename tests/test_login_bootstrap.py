"""
P2-8 first-sign-in gate.

Run:  python tests/test_login_bootstrap.py

Covers the acceptance defect found on the running localhost app: an invited
administrator could authenticate and then be refused forever, because
/auth/login resolved the caller and gave up, and the only bootstrap function
lived in app_private where PostgREST cannot route.

Hermetic and offline, like the other two backend gates. Supabase is replaced by
a fake whose bootstrap RPC enforces the same rules the real
app_private.bootstrap_app_user() does - invitation bound to the caller's
verified email, one identity per auth account, invitation consumed once,
existing identity returned unchanged. That makes this a test of the ROUTE's
decision sequence: when it attempts a bootstrap, whose token it uses, what it
trusts afterwards, and what it refuses.

The DATABASE-side guarantees are proved separately, against the real function
and real policies, by tests.bootstrap_routing() (BR-1..BR-19). Neither file is
sufficient alone: BR proves the database refuses correctly, this proves the
route actually reaches it and honours the answer.
"""
import os
import sys
import threading

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


# --------------------------------------------------------------- fake database
# One mutable store shared by every fake client, guarded by a lock so the
# concurrency test exercises a real race rather than a simulated one.
LOCK = threading.Lock()

STATE = {
    "identities": {},        # auth_uid -> {"id", "display_name", "status"}
    "grants": {},            # app_user_id -> [capability_key]
    "invitations": {},       # email -> {"display_name", "grant_admin", "consumed"}
    "next_id": 100,
    "bootstrap_calls": [],   # tokens the bootstrap RPC was invoked with
    "service_role_used": [],
}

# token -> the authentication account it belongs to
TOKENS = {
    "tok-invited-admin": {"uid": "uid-admin", "email": "invited@example.invalid"},
    "tok-wrong-email": {"uid": "uid-other", "email": "not-the-invitee@example.invalid"},
    "tok-uninvited": {"uid": "uid-nobody", "email": "nobody@example.invalid"},
}


def reset_state(invitation_for="invited@example.invalid"):
    with LOCK:
        STATE["identities"] = {}
        STATE["grants"] = {}
        STATE["invitations"] = {}
        STATE["next_id"] = 100
        STATE["bootstrap_calls"] = []
        STATE["service_role_used"] = []
        if invitation_for:
            STATE["invitations"][invitation_for] = {
                "display_name": "Invited Admin", "grant_admin": True, "consumed": False}


def _do_bootstrap(token):
    """
    The fake stands in for app_private.bootstrap_app_user(). It mirrors the real
    function's decision order exactly, including the two behaviours the route
    depends on: an existing identity is RETURNED UNCHANGED whatever its status,
    and a consumed invitation is not claimable again.
    """
    who = TOKENS.get(token)
    if not who:
        raise RuntimeError("28000 not authenticated")
    with LOCK:
        STATE["bootstrap_calls"].append(token)
        existing = STATE["identities"].get(who["uid"])
        if existing:
            return existing["id"]          # deactivated included - no re-bootstrap
        inv = STATE["invitations"].get(who["email"])
        if not inv or inv["consumed"]:
            raise RuntimeError("42501 no pending invitation for this identity")
        new_id = STATE["next_id"]
        STATE["next_id"] += 1
        STATE["identities"][who["uid"]] = {
            "id": new_id, "display_name": inv["display_name"], "status": "active"}
        STATE["grants"][new_id] = ["administer_users"] if inv["grant_admin"] else []
        inv["consumed"] = True
        return new_id


class FakeQuery:
    def __init__(self, token, table):
        self.token, self.table = token, table

    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def in_(self, *a, **k): return self
    def limit(self, *a, **k): return self
    def update(self, payload): return self
    def insert(self, payload): return self

    def execute(self):
        who = TOKENS.get(self.token) or {}
        with LOCK:
            me = STATE["identities"].get(who.get("uid"))
            if self.table == "app_users":
                # RLS equivalent: only ACTIVE rows are visible to their owner.
                rows = ([{"id": me["id"], "auth_user_id": who["uid"],
                          "display_name": me["display_name"], "status": "active"}]
                        if me and me["status"] == "active" else [])
            elif self.table == "group_capability_grants":
                rows = ([{"app_user_id": me["id"], "status": "active",
                          "capabilities": {"capability_key": k}}
                         for k in STATE["grants"].get(me["id"], [])]
                        if me and me["status"] == "active" else [])
            else:
                rows = []
        return type("R", (), {"data": rows})()


class FakeAuth:
    def get_user(self, tok):
        who = TOKENS.get(tok)
        if not who:
            return type("U", (), {"user": None})()
        return type("U", (), {"user": type("X", (), {"id": who["uid"],
                                                     "email": who["email"]})()})()

    def sign_in_with_password(self, payload):
        token = payload.get("password")          # the test passes the token as password
        who = TOKENS.get(token)
        if not who:
            raise RuntimeError("invalid credentials")
        session = type("S", (), {"access_token": token, "refresh_token": "refresh-" + token,
                                 "expires_at": 9999999999})()
        user = type("U", (), {"id": who["uid"], "email": who["email"]})()
        return type("R", (), {"session": session, "user": user})()

    def refresh_session(self, refresh_token):
        token = refresh_token.replace("refresh-", "")
        return self.sign_in_with_password({"password": token})


class FakeClient:
    def __init__(self, token, kind):
        self.token, self.kind = token, kind
        self.auth = FakeAuth()

    def table(self, name):
        return FakeQuery(self.token, name)

    def rpc(self, name, params):
        if name != "bootstrap_app_user":
            raise AssertionError(f"unexpected rpc {name}")
        if self.kind != "caller":
            raise AssertionError("bootstrap must never use a non-caller client")
        token = self.token
        return type("R", (), {"execute": lambda s=None: type(
            "D", (), {"data": _do_bootstrap(token)})()})()


def fake_caller(token):
    if not token or not isinstance(token, str):
        raise ValueError("access_token is required")
    return FakeClient(token, "caller")


def fake_priv(op):
    if op not in cc.PRIVILEGED_OPERATIONS:
        raise cc.PrivilegeError(op)
    STATE["service_role_used"].append(op)
    return FakeClient("SERVICE-ROLE", "privileged")


cc.get_supabase_for_caller = fake_caller
cc.privileged_client = fake_priv
cc.get_supabase_anon = lambda: FakeClient(None, "anon")

import server  # noqa: E402
server.get_supabase_for_caller = fake_caller
server.privileged_client = fake_priv
server.get_supabase_anon = cc.get_supabase_anon

import auth as auth_mod  # noqa: E402
auth_mod.get_supabase_for_caller = fake_caller

app = server.app
app.config["TESTING"] = True


def login(token):
    with app.test_client() as c:
        return c.post("/auth/login", json={"email": "x@y.invalid", "password": token})


# ------------------------------------------- BL-1..BL-4 the invited first admin
reset_state()
r = login("tok-invited-admin")
check(r.status_code == 200,
      "BL-1 an invited first administrator can complete a real login")
body = r.get_json() or {}
check((body.get("profile") or {}).get("role") == "admin",
      "BL-2 the login response carries the bootstrapped administrator authority")
check(len(STATE["identities"]) == 1
      and next(iter(STATE["identities"].values()))["status"] == "active",
      "BL-3 the resulting identity persists and is active")
check(STATE["invitations"]["invited@example.invalid"]["consumed"] is True,
      "BL-4 the invitation is consumed")

# ------------------------------------------------------- BL-5..BL-7 idempotence
first_id = next(iter(STATE["identities"].values()))["id"]
r2 = login("tok-invited-admin")
check(r2.status_code == 200, "BL-5 logging in again still succeeds")
check(len(STATE["identities"]) == 1
      and next(iter(STATE["identities"].values()))["id"] == first_id,
      "BL-6 repeated login is idempotent - no duplicate identity")
check(len(STATE["grants"][first_id]) == 1,
      "BL-7 repeated login creates no duplicate grant")

# BL-8: the second login resolved directly and never reached the bootstrap RPC.
check(STATE["bootstrap_calls"] == ["tok-invited-admin"],
      "BL-8 normal login after bootstrap resolves directly, no further bootstrap attempt")

# ------------------------------------------------- BL-9..BL-10 refusals persist
reset_state()
r = login("tok-wrong-email")
check(r.status_code == 403,
      "BL-9 a caller whose verified email does not match the invitation is refused")
check(len(STATE["identities"]) == 0,
      "BL-9a the wrong-email attempt created no identity")

reset_state(invitation_for=None)
r = login("tok-uninvited")
check(r.status_code == 403, "BL-10 an uninvited authenticated user is refused")
check(len(STATE["identities"]) == 0,
      "BL-10a the uninvited attempt created no identity")

# --------------------------------------------- BL-11 a deactivated user is stuck
reset_state()
login("tok-invited-admin")
uid = next(iter(STATE["identities"]))
STATE["identities"][uid]["status"] = "deactivated"
grants_before = dict(STATE["grants"])
r = login("tok-invited-admin")
check(r.status_code == 403,
      "BL-11 an INACTIVE existing user cannot log back in")
check(len(STATE["identities"]) == 1 and STATE["identities"][uid]["status"] == "deactivated",
      "BL-11a re-bootstrap neither reactivates the identity nor creates a second")
check(STATE["grants"] == grants_before,
      "BL-11b re-bootstrap grants a deactivated identity nothing further")

# ------------------------------------------------- BL-12 concurrent first logins
reset_state()
results = []


def _concurrent():
    results.append(login("tok-invited-admin").status_code)


threads = [threading.Thread(target=_concurrent) for _ in range(8)]
for t in threads:
    t.start()
for t in threads:
    t.join()
check(len(results) == 8 and all(s == 200 for s in results),
      "BL-12 all 8 concurrent first logins succeed")
check(len(STATE["identities"]) == 1,
      "BL-12a concurrent first logins produce exactly ONE identity")
check(sum(len(v) for v in STATE["grants"].values()) == 1,
      "BL-12b concurrent first logins produce exactly ONE grant set")

# ------------------------------------- BL-13 bootstrap never uses service-role
reset_state()
login("tok-invited-admin")
check(STATE["service_role_used"] == [],
      "BL-13 the bootstrap path uses no service-role client at all")
check(STATE["bootstrap_calls"] == ["tok-invited-admin"],
      "BL-13a bootstrap ran under the CALLER's own token")

# --------------------------------------------- BL-14 refresh must not bootstrap
reset_state()
with app.test_client() as c:
    r = c.post("/auth/refresh", json={"refresh_token": "refresh-tok-invited-admin"})
check(r.status_code == 403,
      "BL-14 refresh into no identity is refused, not bootstrapped")
check(STATE["bootstrap_calls"] == [],
      "BL-14a refresh never attempts a bootstrap")
check(len(STATE["identities"]) == 0,
      "BL-14b refresh created no identity")

# BL-15: once an identity exists, refresh follows it normally.
reset_state()
login("tok-invited-admin")
STATE["bootstrap_calls"].clear()
with app.test_client() as c:
    r = c.post("/auth/refresh", json={"refresh_token": "refresh-tok-invited-admin"})
check(r.status_code == 200, "BL-15 refresh follows an established identity")
check(STATE["bootstrap_calls"] == [],
      "BL-15a refresh still attempts no bootstrap once the identity exists")

# ------------------------------------------ BL-16 the refusal leaks nothing
reset_state(invitation_for=None)
r = login("tok-uninvited")
raw = r.data.decode()
check(r.get_json() == {"error": "Account is not active"},
      "BL-16 the refusal is exactly the same safe message, with no detail")
check(not any(s in raw for s in ("42501", "28000", "invitation", "app_users",
                                 "bootstrap", "uid-", "pending", "app_private")),
      "BL-16a the refusal exposes no identifier, table name or database error")

# BL-17: the refusal is byte-identical whether the cause is a missing invitation,
# a wrong email, or a deactivated account - the caller cannot tell them apart.
reset_state(invitation_for=None)
no_invite = login("tok-uninvited").data
reset_state()
wrong_email = login("tok-wrong-email").data
reset_state()
login("tok-invited-admin")
STATE["identities"][next(iter(STATE["identities"]))]["status"] = "deactivated"
deactivated = login("tok-invited-admin").data
check(no_invite == wrong_email == deactivated,
      "BL-17 no-invitation, wrong-email and deactivated are indistinguishable")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("first-sign-in gate PASS")
