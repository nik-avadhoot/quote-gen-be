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
built per request and never cached, and that property is asserted by
tests/test_caller_context.py rather than left to reviewer discipline.

The service-role key bypasses RLS entirely (verified: service_role holds
BYPASSRLS). It is therefore not available as an ambient import here - it is
reachable only through privileged_client(), which refuses any operation not on
PRIVILEGED_OPERATIONS.
"""
import os
import threading

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
        "Supabase Auth admin API - password reset by an administrator.",
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


def get_supabase_for_caller(access_token: str) -> Client:
    """
    Build a Supabase client that executes as the CALLER.

    A new client every call - never cached, never shared, never mutated after
    construction. The caller's bearer token is fixed in the client's headers at
    construction time, so two clients built concurrently cannot observe each
    other's identity.

    PostgREST resolves the token to the `authenticated` role and to
    auth.uid()/auth.jwt(), which is what every RLS policy and app_private helper
    reads. The backend therefore adds no authorization of its own here: the
    database is the boundary.
    """
    if not access_token or not isinstance(access_token, str):
        raise ValueError("access_token is required to build a caller-context client")

    return create_client(
        _env("SUPABASE_URL"),
        _env("SUPABASE_PUBLISHABLE_KEY"),
        options=ClientOptions(
            headers={"Authorization": f"Bearer {access_token}"},
            auto_refresh_token=False,
            persist_session=False,
        ),
    )


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


# Legacy `profiles.role` is a single column; the approved model expresses the same
# thing as capabilities (CDM-05). The API keeps reporting a role so the frontend is
# unchanged, but the DATABASE is the authority and the role is derived, never stored.
def _derive_role(group_caps: list[str], plant_caps: dict) -> str:
    if "administer_users" in group_caps:
        return "admin"
    for caps in plant_caps.values():
        if "check_quote" in caps:
            return "checker"
    return "maker"


def resolve_caller(access_token: str) -> dict | None:
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

    users = (
        client.table("app_users")
        .select("id, auth_user_id, display_name, status")
        .eq("status", "active")
        .limit(2)
        .execute()
    ).data or []
    # The app_users select policy shows a caller their own row; an administrator
    # additionally sees everyone, so pick the row that is actually theirs.
    me = None
    if len(users) == 1:
        me = users[0]
    elif users:
        auth_uid = _auth_uid(client, access_token)
        me = next((u for u in users if u.get("auth_user_id") == auth_uid), None)
    if not me:
        return None

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
