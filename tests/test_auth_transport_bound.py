"""
Auth-transport bound gate.

Run:  python tests/test_auth_transport_bound.py

Hermetic: dummy Supabase environment, no network. create_client() only
constructs; the timeout probes read the CONSTRUCTED transport rather than
making a call, and the require_auth probes use a fake client that raises.

THE DEFECT THIS CLOSES. ClientOptions has postgrest_client_timeout and
storage_client_timeout but no auth/GoTrue field, so the Auth sub-client ran on
httpx's default Timeout(5.0) while PostgREST was bounded at
UPSTREAM_TIMEOUT_SECONDS. require_auth calls auth.get_user() on EVERY
authenticated request before any table read, so when TLS establishment to
Supabase failed intermittently that call stalled past every configured bound
and no PostgREST request was ever issued.

WHAT WOULD FAIL EACH GROUP:

  AT-1  a build that omits httpx_client passes every other test here and FAILS
        AT-1b, because auth falls back to Timeout(5.0).
  AT-2  supplying httpx_client makes BOTH sub-clients use it, so
        postgrest_client_timeout is no longer what bounds PostgREST. AT-2
        asserts the bound EMPIRICALLY instead of assuming the option still
        works - which is the whole point of checking.
  AT-3  a module-level or otherwise shared transport passes the timeout tests
        and FAILS AT-3, which is the isolation boundary the caller-context gate
        exists to protect.
  AT-4  the pre-correction code answered 401 for every exception. It passes the
        invalid-token case and FAILS every timeout case - a timeout does not
        prove a token is invalid.
  AT-5  a handler that returned 504 but still let the request through would
        pass AT-4 and FAIL AT-5.
"""
import os
import sys

os.environ["SUPABASE_URL"] = "https://test.invalid"
os.environ["SUPABASE_PUBLISHABLE_KEY"] = "test-publishable-key-not-real"
os.environ["SUPABASE_SECRET_KEY"] = "test-secret-key-not-real"

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import httpx  # noqa: E402
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


def transport_of(sub):
    for attr in ("_client", "session", "_http_client", "http_client"):
        c = getattr(sub, attr, None)
        if c is not None and hasattr(c, "timeout"):
            return c
    return None


BOUND = float(cc.UPSTREAM_TIMEOUT_SECONDS)

# ───────────────────────────── AT-1/AT-2  both transports are finite and bound
client = cc._build_caller_client("token-a")
auth_t = transport_of(client.auth)
rest_t = transport_of(client.postgrest)

check(auth_t is not None, "AT-1 the auth sub-client exposes an httpx transport")
check(auth_t.timeout.read == BOUND,
      f"AT-1b auth transport read timeout is UPSTREAM_TIMEOUT_SECONDS ({BOUND}s), not httpx's 5s default")
check(auth_t.timeout.connect == BOUND,
      "AT-1c and its CONNECT timeout is bounded too - the observed failure was TLS establishment")

check(rest_t is not None, "AT-2 the postgrest sub-client exposes an httpx transport")
check(rest_t.timeout.read == BOUND,
      f"AT-2b postgrest is STILL bounded at {BOUND}s after supplying httpx_client (verified, not assumed)")
check(rest_t.timeout.connect == BOUND,
      "AT-2c postgrest connect timeout is bounded too")
check(all(v is not None for v in
          (rest_t.timeout.read, rest_t.timeout.connect, rest_t.timeout.write, rest_t.timeout.pool)),
      "AT-2d no postgrest timeout dimension is left unbounded")

# ───────────────────────────── AT-3  transports are never shared across callers
other = cc._build_caller_client("token-b")
check(transport_of(other.auth) is not auth_t,
      "AT-3 two caller clients do NOT share an auth transport")
check(transport_of(other.postgrest) is not rest_t,
      "AT-3a nor a postgrest transport")

w1 = cc.new_caller_client("worker-token")
w2 = cc.new_caller_client("worker-token")
check(w1 is not w2, "AT-3b new_caller_client still builds a fresh client per worker")
check(transport_of(w1.auth) is not transport_of(w2.auth),
      "AT-3c and two worker clients built from the SAME token do not share a transport")
check(transport_of(w1.postgrest) is not transport_of(w2.postgrest),
      "AT-3d including their postgrest transports")
check(transport_of(w1.auth).timeout.read == BOUND
      and transport_of(w1.postgrest).timeout.read == BOUND,
      "AT-3e worker clients carry the same finite bound")

# ───────────────────────────── AT-4/AT-5  require_auth behaviour
from flask import Flask, g, jsonify  # noqa: E402
import auth as auth_mod  # noqa: E402

app = Flask(__name__)
app.config["TESTING"] = True

REACHED = {"body": False}
MODE = {"raise": None}


class FakeAuthNS:
    def get_user(self, token):
        exc = MODE["raise"]
        if exc is not None:
            raise exc
        return type("U", (), {"user": type("X", (), {"id": "auth-uuid", "email": "u@x.invalid"})()})()


class FakeClient:
    auth = FakeAuthNS()


auth_mod.get_supabase_for_caller = lambda token: FakeClient()
auth_mod.resolve_caller = lambda token, known_auth_uid=None: {
    "id": 1, "display_name": "T", "status": "active",
    "group_capabilities": [], "plant_capabilities": {},
}


@app.route("/probe")
@auth_mod.require_auth
def probe():
    REACHED["body"] = True
    return jsonify({"caller": g.caller["id"]})


RESOLVE = {"raise": None, "returns": {"id": 1, "display_name": "T", "status": "active",
                                      "group_capabilities": [], "plant_capabilities": {}}}
SAW = {"caller": None, "token": None}


def resolver(token, known_auth_uid=None):
    if RESOLVE["raise"] is not None:
        raise RESOLVE["raise"]
    return RESOLVE["returns"]


auth_mod.resolve_caller = resolver


@app.route("/probe2")
@auth_mod.require_auth
def probe2():
    REACHED["body"] = True
    SAW["caller"] = getattr(g, "caller", None)
    SAW["token"] = getattr(g, "access_token", None)
    return jsonify({"caller": g.caller["id"]})


AUTH = {"Authorization": "Bearer tok-x"}

# A bare httpx timeout, and a wrapped one whose CAUSE is the timeout - the shape
# supabase-py actually raises. Both must be recognised.
wrapped = RuntimeError("upstream failed")
wrapped.__cause__ = httpx.ConnectTimeout("timed out establishing TLS")

for label, exc in (("bare httpx.ReadTimeout", httpx.ReadTimeout("read timed out")),
                   ("bare httpx.ConnectTimeout", httpx.ConnectTimeout("connect timed out")),
                   ("wrapped, timeout as __cause__", wrapped)):
    MODE["raise"] = exc
    REACHED["body"] = False
    with app.test_client() as c:
        r = c.get("/probe", headers=AUTH)
    body = r.get_json() or {}
    check(r.status_code == 504, f"AT-4 {label} -> 504, not 401")
    check(body.get("error_code") == "UPSTREAM_TIMEOUT",
          f"AT-4a {label} carries the stable UPSTREAM_TIMEOUT code")
    check("did not respond in time" in (body.get("error") or ""),
          f"AT-4b {label} uses the fixed authentication wording")
    check("saved" not in (body.get("error") or "").lower()
          and "outcome" not in (body.get("error") or "").lower(),
          f"AT-4c {label} does NOT reuse the write-oriented 'may have been saved' wording")
    check(REACHED["body"] is False, f"AT-5 {label} never enters the route body")

# Genuine invalid/expired token keeps its 401.
MODE["raise"] = Exception("invalid JWT: unable to parse or verify signature")
REACHED["body"] = False
with app.test_client() as c:
    r = c.get("/probe", headers=AUTH)
check(r.status_code == 401, "AT-6 a genuine invalid/expired token is still 401")
check((r.get_json() or {}).get("error") == "Invalid or expired token",
      "AT-6a with the existing message, unchanged")
check(REACHED["body"] is False, "AT-6b and it never enters the route body either")

# Success still follows the existing caller-resolution path.
MODE["raise"] = None
REACHED["body"] = False
with app.test_client() as c:
    r = c.get("/probe", headers=AUTH)
check(r.status_code == 200, "AT-7 successful verification still succeeds")
check((r.get_json() or {}).get("caller") == 1,
      "AT-7a and g.caller is populated from resolve_caller as before")
check(REACHED["body"] is True, "AT-7b the route body runs")

# No authorization is cached between requests.
calls = {"n": 0}
_prev = auth_mod.resolve_caller


def counting(token, known_auth_uid=None):
    calls["n"] += 1
    return _prev(token, known_auth_uid=known_auth_uid)


auth_mod.resolve_caller = counting
with app.test_client() as c:
    c.get("/probe", headers=AUTH)
    c.get("/probe", headers=AUTH)
check(calls["n"] == 2, "AT-8 authorization is re-resolved every request, never cached across them")

# ═══════════════ AT-9..AT-13  resolve_caller: the same distinction, DB side
#
# resolve_caller reads app_users and the grant tables through PostgREST, so it
# can time out too. Before this correction every exception there answered 403
# "Could not resolve account", which asserts something about the ACCOUNT when
# the database simply did not answer.
#
# A handler that mapped ALL resolution errors to 504 would pass AT-9 and FAIL
# AT-11. One that mapped none would pass AT-11 and FAIL AT-9. AT-12 pins the
# remaining 403, which must keep meaning "resolution COMPLETED and returned no
# active caller" - a different fact from both.

MODE["raise"] = None            # auth verification succeeds throughout
auth_mod.resolve_caller = resolver
rwrapped = RuntimeError("postgrest read failed")
rwrapped.__cause__ = httpx.ReadTimeout("read timed out")

for label, exc in (("direct httpx.ReadTimeout", httpx.ReadTimeout("read timed out")),
                   ("direct httpx.ConnectTimeout", httpx.ConnectTimeout("connect timed out")),
                   ("wrapped, timeout as __cause__", rwrapped)):
    RESOLVE["raise"] = exc
    REACHED["body"] = False
    SAW["caller"] = SAW["token"] = None
    with app.test_client() as c:
        r = c.get("/probe2", headers=AUTH)
    body = r.get_json() or {}
    check(r.status_code == 504, f"AT-9 resolve_caller {label} -> 504, not 403")
    check(body.get("error_code") == "UPSTREAM_TIMEOUT",
          f"AT-9a resolve_caller {label} carries the stable UPSTREAM_TIMEOUT code")
    check("did not respond in time" in (body.get("error") or ""),
          f"AT-9b resolve_caller {label} uses fixed read-oriented wording")
    check("saved" not in (body.get("error") or "").lower()
          and "outcome" not in (body.get("error") or "").lower(),
          f"AT-9c resolve_caller {label} does not reuse write-oriented wording")
    check("Could not resolve account" not in (body.get("error") or ""),
          f"AT-9d resolve_caller {label} no longer asserts anything about the account")
    check(REACHED["body"] is False, f"AT-10 resolve_caller {label} never enters the route body")
    check(SAW["caller"] is None and SAW["token"] is None,
          f"AT-10a resolve_caller {label} populates neither g.caller nor g.access_token")

# An ORDINARY database error keeps its sanitized 403 and leaks nothing.
RESOLVE["raise"] = Exception('relation "app_users" does not exist')
REACHED["body"] = False
with app.test_client() as c:
    r = c.get("/probe2", headers=AUTH)
body = r.get_json() or {}
check(r.status_code == 403, "AT-11 an ordinary resolution error is still 403")
check(body.get("error") == "Could not resolve account",
      "AT-11a with the existing sanitized message, unchanged")
check("app_users" not in str(body),
      "AT-11b and the database error text is still not leaked")
check(REACHED["body"] is False, "AT-11c and it never enters the route body")

# Resolution COMPLETES and returns no caller - a different fact, same 403.
RESOLVE["raise"] = None
RESOLVE["returns"] = None
REACHED["body"] = False
with app.test_client() as c:
    r = c.get("/probe2", headers=AUTH)
body = r.get_json() or {}
check(r.status_code == 403, "AT-12 completed resolution returning no caller is still 403")
check(body.get("error") == "Account is not active",
      "AT-12a and still says the account is not active - which now only means that")
check(REACHED["body"] is False, "AT-12b and it never enters the route body")

# Success is unchanged.
RESOLVE["returns"] = {"id": 7, "display_name": "T", "status": "active",
                      "group_capabilities": [], "plant_capabilities": {}}
REACHED["body"] = False
with app.test_client() as c:
    r = c.get("/probe2", headers=AUTH)
check(r.status_code == 200, "AT-13 successful resolution still succeeds")
check((r.get_json() or {}).get("caller") == 7, "AT-13a and g.caller carries the resolved identity")
check(SAW["token"] == "tok-x", "AT-13b and g.access_token is the caller's own token")
check(REACHED["body"] is True, "AT-13c and the route body runs")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  failed: {f}")
    sys.exit(1)
print("auth-transport bound gate PASS")
