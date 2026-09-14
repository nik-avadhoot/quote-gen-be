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
    timed,
    get_supabase_for_caller,
    resolve_caller,
    has_group_capability,
    has_plant_capability,
    is_upstream_timeout,
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
        #
        # A TIMEOUT IS NOT AN INVALID TOKEN. This used to answer 401 for every
        # exception, which said "your token is bad" when the truth was "we could
        # not reach Auth to ask". The token may be perfectly valid. The two are
        # now separated: a transport timeout is the upstream's failure and is
        # reported as 504 UPSTREAM_TIMEOUT; everything else keeps its 401.
        #
        # The bound itself lives in caller_context._new_caller_transport(): the
        # Auth sub-client had no configurable timeout and ran on httpx's default
        # 5s, so this is what makes the refusal ARRIVE rather than merely be
        # caught. Catching a timeout does not enforce one.
        try:
            with timed("auth.verify_token"):
                client = get_supabase_for_caller(token)
                user_resp = client.auth.get_user(token)
        except Exception as exc:
            if is_upstream_timeout(exc):
                # Fixed, non-sensitive wording, and deliberately NOT the
                # write-oriented UPSTREAM_TIMEOUT text used by the mutation
                # routes: nothing was being saved here. This is verification of
                # a read request, so "the outcome may have been saved" would be
                # both wrong and alarming.
                return jsonify({
                    "error_code": "UPSTREAM_TIMEOUT",
                    "error": "Authentication verification did not respond in time. "
                             "Please try again.",
                }), 504
            return jsonify({"error": "Invalid or expired token"}), 401
        if not user_resp or not user_resp.user:
            return jsonify({"error": "Invalid or expired token"}), 401

        # Resolve the application identity as the caller, through RLS.
        # The Auth uuid was just verified above, so hand it over rather than
        # making resolve_caller re-fetch it (D1: that was a second full
        # auth.get_user() round-trip on every administrator request).
        #
        # SAME DISTINCTION AS ABOVE, ON THE DATABASE SIDE. resolve_caller reads
        # app_users and the grant tables through PostgREST, so it can time out
        # too. That used to fall into the generic handler and answer 403
        # "Could not resolve account" - which asserts something about the
        # ACCOUNT when the truth is that the database did not answer. The
        # account may be perfectly fine. A timeout is the upstream's failure and
        # is reported as such; every other database error keeps its sanitized
        # 403, and the separate "not active" 403 below still means exactly what
        # it says: resolution COMPLETED and returned no active caller.
        try:
            with timed("auth.resolve_caller"):
                caller = resolve_caller(token, known_auth_uid=user_resp.user.id)
        except Exception as exc:
            if is_upstream_timeout(exc):
                # Read-oriented wording again: require_auth verifies, it does
                # not write, so nothing here may have been saved.
                return jsonify({
                    "error_code": "UPSTREAM_TIMEOUT",
                    "error": "Account verification did not respond in time. "
                             "Please try again.",
                }), 504
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
    Compatibility shim, now with NO CALLERS. Do not add one.

    It was never wrong in effect - the derived role is computed from capability
    grants, so `role == "admin"` and `administer_users` currently coincide - but
    it made a PRESENTATION LABEL the thing a route consults. A change to
    derive_role would then silently regate every route wearing this decorator,
    and the label is deliberately lossy: it cannot express nine of the thirteen
    capabilities at all. Every administration route now states the capability it
    actually requires, through require_group_capability.

    Kept only so an out-of-tree caller does not break on import. Anything new
    must use require_group_capability / require_plant_capability.
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
