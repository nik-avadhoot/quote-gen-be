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


def resolve_app_user(access_token: str) -> dict | None:
    """
    Resolve the caller's application identity THROUGH RLS.

    Returns the caller's app_users row, or None when they have no active
    identity. Because this runs as the caller, the app_users_select policy is
    what decides visibility - a deactivated user resolves to None on their very
    next request even while holding an unexpired token, without the backend
    needing to re-check anything.
    """
    client = get_supabase_for_caller(access_token)
    resp = (
        client.table("app_users")
        .select("id, display_name, status")
        .eq("status", "active")
        .limit(1)
        .execute()
    )
    rows = resp.data or []
    return rows[0] if rows else None


def caller_capabilities(access_token: str) -> dict:
    """
    Read the caller's own capability grants through RLS.

    The grant policies expose a caller their own rows, so this needs no
    privileged access. Returns {"group": [...], "plant": {plant_id: [...]}}.
    """
    client = get_supabase_for_caller(access_token)
    group_rows = (
        client.table("group_capability_grants")
        .select("capability_id, status, capabilities(capability_key)")
        .eq("status", "active")
        .execute()
    ).data or []
    plant_rows = (
        client.table("plant_capability_grants")
        .select("plant_id, status, capabilities(capability_key)")
        .eq("status", "active")
        .execute()
    ).data or []

    plants: dict = {}
    for row in plant_rows:
        key = (row.get("capabilities") or {}).get("capability_key")
        if key is not None:
            plants.setdefault(row["plant_id"], []).append(key)

    return {
        "group": sorted(
            (r.get("capabilities") or {}).get("capability_key")
            for r in group_rows
            if (r.get("capabilities") or {}).get("capability_key")
        ),
        "plant": plants,
    }
