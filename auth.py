"""
Authentication / authorization decorators for Flask routes.

S2 conversion. Two things changed and both matter:

1. Identity is resolved THROUGH THE CALLER'S OWN TOKEN, not with the service-role
   client. The previous version verified the bearer token and then re-read the
   caller's `profiles` row with `get_supabase_admin()`, which bypasses RLS
   entirely - so every RLS defect in identity resolution was invisible, and the
   database was not actually the authority it was documented to be.

2. Authorization is capability-based (`app_users` + group/plant grants). The
   single legacy role column it replaced is gone entirely - S3(c) removed
   `public.profiles` - so capabilities are now the only model there is.
   `require_role` is kept as a thin shim over the
   derived role so existing route decorators keep working unchanged, and
   `require_group_capability` / `require_plant_capability` express the real model
   for anything new.

Deactivation still takes effect immediately: `resolve_caller` only returns an
ACTIVE application identity, so a user disabled mid-session is refused on their
very next request even though their access token is still cryptographically
valid and has not expired.

Nothing about the caller is cached between requests, and no JWT claim other than
the verified subject is trusted for authorization - `role` and `plant` come from
grant tables the user cannot write.
"""
from functools import wraps

from flask import request, jsonify, g

from caller_context import (
    get_supabase_for_caller,
    resolve_caller,
    has_group_capability,
    has_plant_capability,
)


def _extract_bearer_token():
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return None
    return header[len("Bearer "):].strip()


def require_auth(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        token = _extract_bearer_token()
        if not token:
            return jsonify({"error": "Missing Authorization header"}), 401

        # Verify the token against Supabase Auth using a per-request client.
        try:
            client = get_supabase_for_caller(token)
            user_resp = client.auth.get_user(token)
        except Exception:
            return jsonify({"error": "Invalid or expired token"}), 401
        if not user_resp or not user_resp.user:
            return jsonify({"error": "Invalid or expired token"}), 401

        # Resolve the application identity as the caller, through RLS.
        try:
            caller = resolve_caller(token)
        except Exception:
            # Never leak the database error: it can carry table and column names.
            return jsonify({"error": "Could not resolve account"}), 403
        if not caller:
            # Covers unrecognised AND deactivated identities. Deliberately one
            # message: distinguishing them tells an attacker which accounts exist.
            return jsonify({"error": "Account is not active"}), 403

        g.access_token = token
        g.caller = caller
        # Legacy-shaped view kept so existing routes and the frontend contract are
        # unchanged. `id` is now the application identity; the Auth uuid is separate.
        g.current_user = {**caller, "email": user_resp.user.email}
        return f(*args, **kwargs)

    return wrapper


def require_role(*roles):
    """
    Compatibility shim. The derived role comes from capability grants, so this
    still enforces the approved model - it just keeps the existing decorators
    readable. Prefer require_group_capability for new routes.
    """
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            if g.caller.get("role") not in roles:
                return jsonify({"error": "Forbidden"}), 403
            return f(*args, **kwargs)
        return wrapper
    return decorator


def require_group_capability(capability):
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            if not has_group_capability(g.caller, capability):
                return jsonify({"error": "Forbidden"}), 403
            return f(*args, **kwargs)
        return wrapper
    return decorator


def require_plant_capability(capability, plant_arg="plant_code"):
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            plant_code = kwargs.get(plant_arg) or (request.get_json(silent=True) or {}).get(plant_arg)
            if not plant_code or not has_plant_capability(g.caller, plant_code, capability):
                return jsonify({"error": "Forbidden"}), 403
            return f(*args, **kwargs)
        return wrapper
    return decorator
