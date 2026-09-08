"""
S2 - caller context.

Normal application database operations must execute AS THE CALLER so that
Postgres RLS applies. This module provides that, and confines service-role
access to an explicit, reviewed allow-list.

Why a new module rather than a change to supabase_client.py: the existing
get_supabase() returns a module-level CACHED SINGLETON. Attaching a caller's
token to it would publish that token to every concurrent request served by the
same worker - request A could execute as request B's user. The bug is silent
and its blast radius is every row RLS protects. So caller-scoped clients are
scoped to ONE REQUEST and never to the module: memoised on `flask.g` and keyed
by the token they were built with (D1 - three separate clients per request each
paid their own TLS handshake), so two requests can never share one. That
property is asserted by tests/test_caller_context.py rather than left to
reviewer discipline.

The service-role key bypasses RLS entirely (verified: service_role holds
BYPASSRLS). It is therefore not available as an ambient import here - it is
reachable only through privileged_client(), which refuses any operation not on
PRIVILEGED_OPERATIONS.
"""
import json
import os
import threading
import time
from contextlib import contextmanager
import urllib.error
import urllib.request

from supabase import create_client, Client
from supabase.client import ClientOptions


# ---------------------------------------------------------------------------
# Privileged-operation allow-list.
#
# Each entry is an operation that genuinely cannot run as the caller, with the
# reason it cannot. Anything absent from this dict cannot obtain the
# service-role client at all.
#
# Deliberately NOT on this list:
#   - reading the caller's own identity/profile. That is a caller-context read
#     through RLS; doing it with service-role was the pre-S2 behaviour and it
#     hid every RLS defect in identity resolution.
#   - listing users for /admin/users. Admin visibility is expressed as an RLS
#     policy on app_users (administer_users capability), not as a bypass.
# ---------------------------------------------------------------------------
PRIVILEGED_OPERATIONS = {
    "auth_admin_create_user":
        "Supabase Auth admin API - creating an auth identity is not a table write "
        "and has no caller-context equivalent.",
    "auth_admin_delete_user":
        "Supabase Auth admin API - compensating delete when profile creation fails.",
    "auth_admin_update_user":
        "Supabase Auth admin API - password reset by an administrator, and an "
        "administrator-initiated login email change. The login identity lives in "
        "auth.users, not in any table, so there is no caller-context equivalent. "
        "Who may do it is still decided by the database: the capability check and "
        "the target's resolution both happen in app_private before this is called.",
    "auth_admin_sign_out":
        "Supabase Auth admin API - global sign-out on logout/deactivation. "
        "Required so deactivation takes effect before token expiry.",
    "auth_admin_list_users":
        "Supabase Auth admin API - email and last-sign-in live in Auth, not in any "
        "table, so there is no caller-context equivalent. Row VISIBILITY is still "
        "decided by RLS: the caller reads app_users first, and this only decorates "
        "rows they were already allowed to see.",
}


class PrivilegeError(RuntimeError):
    """Raised when service-role access is requested for a non-allow-listed operation."""


def _env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} must be set (check quote-gen-be/.env)")
    return value


# D2: the supabase-py default PostgREST timeout is 120 SECONDS. A single hung
# upstream request therefore parked a Flask worker for two minutes and then
# surfaced as a bare 500 ("The read operation timed out") with no usable
# feedback in the UI - measured directly, see docs. A bounded timeout turns
# that into a fast, mappable refusal. Generous enough that ordinary calls
# (measured median ~320 ms, p-max ~1.2 s) never trip it.
UPSTREAM_TIMEOUT_SECONDS = int(os.environ.get("QOS_UPSTREAM_TIMEOUT", "15"))


class UpstreamTimeout(Exception):
    """A Supabase/PostgREST call exceeded UPSTREAM_TIMEOUT_SECONDS."""


# D1 - request-path instrumentation. OFF unless QOS_TIMING is set, so it costs
# nothing in production and adds no log noise; set QOS_TIMING=1 in the
# gitignored quote-gen-be/.env to measure locally. Emits one line per phase:
#   TIMING <phase> <ms>
TIMING_ENABLED = bool(os.environ.get("QOS_TIMING"))


@contextmanager
def timed(phase: str):
    """Measure one phase of the request path. A no-op unless QOS_TIMING is set."""
    if not TIMING_ENABLED:
        yield
        return
    import logging
    start = time.perf_counter()
    try:
        yield
    finally:
        logging.getLogger("qos.timing").warning(
            "TIMING %-28s %8.1f ms", phase, (time.perf_counter() - start) * 1000)


def _build_caller_client(access_token: str) -> Client:
    return create_client(
        _env("SUPABASE_URL"),
        _env("SUPABASE_PUBLISHABLE_KEY"),
        options=ClientOptions(
            headers={"Authorization": f"Bearer {access_token}"},
            auto_refresh_token=False,
            persist_session=False,
            postgrest_client_timeout=UPSTREAM_TIMEOUT_SECONDS,
            storage_client_timeout=UPSTREAM_TIMEOUT_SECONDS,
        ),
    )


def get_supabase_for_caller(access_token: str) -> Client:
    """
    Return a Supabase client that executes as the CALLER.

    ONE client per REQUEST, memoised on `flask.g` and keyed by the token it was
    built with. Never a module-level cache and never shared between requests, so
    the original invariant holds: two callers cannot observe each other's
    identity, because two requests never touch the same `g`. Outside a request
    context (scripts, tests) this builds a fresh client exactly as before.

    D1: this path used to build a NEW client on every call - three per request
    for a single screen (require_auth, resolve_caller, the route body), each one
    paying a fresh TLS handshake (measured 568-1179 ms cold vs ~300 ms on a warm
    connection). Reusing one client per request removes two handshakes without
    weakening the boundary.

    The caller's bearer token is fixed in the client's headers at construction
    time. PostgREST resolves it to the `authenticated` role and to
    auth.uid()/auth.jwt(), which is what every RLS policy and app_private helper
    reads. The backend adds no authorization of its own here: the database is
    the boundary.
    """
    if not access_token or not isinstance(access_token, str):
        raise ValueError("access_token is required to build a caller-context client")

    try:
        from flask import g, has_request_context
    except Exception:
        return _build_caller_client(access_token)

    if not has_request_context():
        return _build_caller_client(access_token)

    cached = getattr(g, "_qos_caller_client", None)
    if cached is not None and getattr(g, "_qos_caller_token", None) == access_token:
        return cached

    client = _build_caller_client(access_token)
    g._qos_caller_client = client
    g._qos_caller_token = access_token
    return client


def privileged_client(operation: str) -> Client:
    """
    Return a service-role client for one named, allow-listed operation.

    `operation` must be a key of PRIVILEGED_OPERATIONS. The name is required at
    the call site so that every bypass of RLS is greppable and reviewable, and
    so that adding one is a visible diff rather than an import.
    """
    if operation not in PRIVILEGED_OPERATIONS:
        raise PrivilegeError(
            f"'{operation}' is not an allow-listed privileged operation. "
            f"Normal database work must use get_supabase_for_caller(). "
            f"Allow-listed: {sorted(PRIVILEGED_OPERATIONS)}"
        )
    # Not cached: a cached service-role client is a long-lived RLS-bypassing
    # handle sitting in module scope, which is exactly what S2 removes.
    return create_client(
        _env("SUPABASE_URL"),
        _env("SUPABASE_SECRET_KEY"),
        options=ClientOptions(auto_refresh_token=False, persist_session=False),
    )


def get_supabase_anon() -> Client:
    """
    A fresh, unauthenticated client for the Auth endpoints that must run without
    a caller token: login, refresh, and current-password verification.

    Also never cached. supabase_client.get_supabase() returns a shared singleton
    and routes call sign_in_with_password on it, which mutates session state
    every concurrent request can observe. Use this instead.
    """
    return create_client(
        _env("SUPABASE_URL"),
        _env("SUPABASE_PUBLISHABLE_KEY"),
        options=ClientOptions(auto_refresh_token=False, persist_session=False),
    )


# The legacy `profiles.role` column WAS a single column. It no longer exists -
# S3(c) removed the table - and the approved model expresses the same thing as
# capabilities (CDM-05). The API keeps reporting a role so the frontend contract
# is unchanged, but the DATABASE is the authority and the role is DERIVED from
# grants on every request, never stored.
def _derive_role(group_caps: list[str], plant_caps: dict) -> str:
    if "administer_users" in group_caps:
        return "admin"
    for caps in plant_caps.values():
        if "check_quote" in caps:
            return "checker"
    return "maker"


def resolve_caller(access_token: str, known_auth_uid: str | None = None) -> dict | None:
    """
    Resolve the caller's application identity and authority THROUGH RLS.

    Returns None when the token maps to no ACTIVE application user. That covers
    an unrecognised identity and a deactivated one holding a still-valid token:
    both are refused on the very next request, because `status = 'active'` is
    part of what the caller is allowed to see and of every capability helper.

    Nothing here is cached. Every field comes from this request's own token.

    The returned shape stays legacy-compatible (`id`, `display_name`, `role`,
    `plant`, `active`) so the frontend contract is unchanged, but `role` and
    `plant` are DERIVED from capability grants rather than read from a column.
    """
    client = get_supabase_for_caller(access_token)

    # D1: when require_auth has already verified the token it also knows the
    # caller's Auth uuid, so ask for that row directly instead of fetching a
    # window of visible rows and picking from it. An administrator sees
    # everyone, so the old .limit(2) could genuinely miss their own row once a
    # third user existed and then resolve to None.
    #
    # NOTE - deliberately still THREE reads, not one embedded read. Collapsing
    # app_users + both grant tables into a single PostgREST resource-embedding
    # query does work and is measurably faster, but it moves the
    # status='active' filter for grants out of the database and into Python.
    # tests/test_capability_shape.py asserts that those queries ASK the database
    # for active rows precisely so a later edit cannot do that, and that gate is
    # right: the database, not this file, decides which grants count. The
    # cheaper shape is left for a separate, reviewed change.
    query = client.table("app_users").select("id, auth_user_id, display_name, status")
    query = query.eq("status", "active")
    if known_auth_uid:
        query = query.eq("auth_user_id", known_auth_uid)
    else:
        query = query.limit(2)
    users = (query.execute()).data or []

    # The app_users select policy shows a caller their own row; an administrator
    # additionally sees everyone, so pick the row that is actually theirs.
    me = None
    if known_auth_uid:
        me = next((u for u in users if u.get("auth_user_id") == known_auth_uid), None)
    elif len(users) == 1:
        me = users[0]
    elif users:
        # Standalone callers (scripts, tests) still resolve correctly; the extra
        # auth.get_user() round-trip only happens when the uuid was not supplied.
        uid = _auth_uid(client, access_token)
        me = next((u for u in users if u.get("auth_user_id") == uid), None)
    if not me:
        return None

    # These two reads are independent, and running them concurrently on the
    # shared per-request client was tried and REVERTED for the same reason as
    # the six reads in server.list_customer_families(): supabase-py speaks
    # HTTP/2 over a single multiplexed connection, and httpcore's sync h2 path
    # fails under concurrent use from threads (WinError 10035) and then leaves
    # the connection wedged. Sequential, on the one already-warm client.
    # Both still filter status='active' in the QUERY, not in Python.
    group_rows = (
        client.table("group_capability_grants")
        .select("app_user_id, status, capabilities(capability_key)")
        .eq("app_user_id", me["id"]).eq("status", "active").execute()
    ).data or []
    plant_rows = (
        client.table("plant_capability_grants")
        .select("app_user_id, plant_id, status, capabilities(capability_key), plants(plant_code)")
        .eq("app_user_id", me["id"]).eq("status", "active").execute()
    ).data or []

    group_caps = sorted({
        (r.get("capabilities") or {}).get("capability_key")
        for r in group_rows if (r.get("capabilities") or {}).get("capability_key")
    })
    plant_caps: dict = {}
    plant_codes: dict = {}
    for r in plant_rows:
        key = (r.get("capabilities") or {}).get("capability_key")
        if key:
            plant_caps.setdefault(r["plant_id"], []).append(key)
        code = (r.get("plants") or {}).get("plant_code")
        if code:
            plant_codes[r["plant_id"]] = code

    return {
        "id": me["id"],                       # app identity (bigint), not an auth uuid
        "auth_user_id": me.get("auth_user_id"),
        "display_name": me["display_name"],
        "active": True,                       # non-active never resolves at all
        "role": _derive_role(group_caps, plant_caps),
        "plant": next(iter(plant_codes.values()), None),
        "plants": sorted(plant_codes.values()),
        "group_capabilities": group_caps,
        "plant_capabilities": {plant_codes.get(k, str(k)): sorted(v)
                               for k, v in plant_caps.items()},
    }


def bootstrap_caller(access_token: str) -> bool:
    """
    Give an authenticated caller with no application identity ONE chance to claim
    a pending invitation, using their own token.

    This is the first-sign-in path. It exists because authentication and
    authorization are separate: Supabase Auth will happily issue a token to an
    invited administrator who has no `app_users` row yet, and every route then
    refuses them. Without this the invitation is unreachable from the running
    application - which is exactly the defect this fixes.

    Everything that decides anything happens in the database. This function
    supplies no identity, no email and no role: `public.bootstrap_app_user()` is
    an unprivileged SECURITY INVOKER shim, and the SECURITY DEFINER
    implementation in `app_private` reads auth.uid() and the verified `email`
    claim from the caller's own token, matches them against the invitation, and
    refuses everything else. So the backend cannot widen who gets in, and a
    forged or edited request body changes nothing.

    NOT the service-role client - deliberately. Bootstrapping with service-role
    would mean the backend, not the database, deciding who becomes a user, and
    it would bypass every RLS policy on the way. The caller's own token is the
    whole point.

    Returns True if the RPC completed, False on any refusal. The caller must
    re-resolve either way and treat "still unresolved" as a refusal: a True here
    means the database accepted the call, not that the caller is now active.
    """
    if not access_token or not isinstance(access_token, str):
        return False
    try:
        get_supabase_for_caller(access_token).rpc("bootstrap_app_user", {}).execute()
        return True
    except Exception:
        # Uninvited, wrong email, already-consumed invitation, deactivated
        # account, a concurrent caller that won the race - all indistinguishable
        # here on purpose. The route returns one refusal for every case.
        return False


def verify_current_password(email: str, password: str) -> bool:
    """
    Re-verify that whoever holds this session also knows the current password.

    A valid access token proves the session was authenticated at some point, not
    that the person at the keyboard is the account holder now. Changing the
    login identity is exactly the operation where that difference matters, so
    the current password is re-checked immediately before it.

    Done with a throwaway anonymous client, so nothing is stored, cached or
    attached to the caller's session. The password is used once and discarded;
    it is never written to a table, a log or an audit row.
    """
    if not email or not password:
        return False
    try:
        resp = get_supabase_anon().auth.sign_in_with_password(
            {"email": email, "password": password})
        return bool(resp and resp.session)
    except Exception:
        return False


def update_caller_email(access_token: str, new_email: str) -> dict:
    """
    Ask Supabase Auth to change the CALLER's own login email.

    This is the documented `updateUser({ email })` operation, called at its REST
    endpoint with the caller's own bearer token. It is deliberately not an admin
    call: the change is made by the user, as the user, and Supabase runs its own
    verification flow. With "Secure email change" enabled the project sends a
    confirmation to both the old and the new address and the change only lands
    once confirmed - which is why the route reports a PENDING state rather than
    claiming success.

    supabase-py's auth.update_user() operates on a session the client object
    holds internally; a caller-context client carries the token as a header and
    has no such session, so the REST endpoint is called directly rather than
    faking one.
    """
    if not access_token or not new_email:
        raise ValueError("access_token and new_email are required")

    req = urllib.request.Request(
        _env("SUPABASE_URL").rstrip("/") + "/auth/v1/user",
        data=json.dumps({"email": new_email}).encode(),
        headers={
            "apikey": _env("SUPABASE_PUBLISHABLE_KEY"),
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
        },
        method="PUT",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read().decode() or "{}")

    # GoTrue reports an unconfirmed change as new_email / email_change.
    pending = body.get("new_email") or body.get("email_change") or None
    return {"pending_email": bool(pending), "current_email": body.get("email")}


def _auth_uid(client: Client, access_token: str):
    try:
        resp = client.auth.get_user(access_token)
        return resp.user.id if resp and resp.user else None
    except Exception:
        return None


def has_group_capability(caller: dict, capability: str) -> bool:
    return capability in (caller or {}).get("group_capabilities", [])


def has_plant_capability(caller: dict, plant_code: str, capability: str) -> bool:
    return capability in (caller or {}).get("plant_capabilities", {}).get(plant_code, [])
