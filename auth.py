"""
Authentication / authorization decorators for Flask routes.

require_auth verifies the bearer token against Supabase Auth on every
request (via auth.get_user, not local JWT decoding — recommended by Supabase
for HS256 projects like this one) and then re-reads the caller's `profiles`
row from Postgres via the service-role client. Re-reading on every request
(rather than trusting anything baked into the JWT) is what makes deactivating
a user take effect immediately, since a Supabase access token can't otherwise
be revoked before it naturally expires.
"""
from functools import wraps

from flask import request, jsonify, g

from supabase_client import get_supabase, get_supabase_admin


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

        try:
            user_resp = get_supabase().auth.get_user(token)
        except Exception:
            return jsonify({"error": "Invalid or expired token"}), 401
        if not user_resp or not user_resp.user:
            return jsonify({"error": "Invalid or expired token"}), 401

        try:
            profile_resp = (
                get_supabase_admin()
                .table("profiles")
                .select("*")
                .eq("id", user_resp.user.id)
                .single()
                .execute()
            )
        except Exception:
            return jsonify({"error": "No profile found for this account"}), 401

        profile = profile_resp.data
        if not profile:
            return jsonify({"error": "No profile found for this account"}), 401
        if not profile.get("active", False):
            return jsonify({"error": "Account is deactivated"}), 403

        g.access_token = token
        g.current_user = {**profile, "email": user_resp.user.email}
        return f(*args, **kwargs)

    return wrapper


def require_role(*roles):
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            if g.current_user["role"] not in roles:
                return jsonify({"error": "Forbidden"}), 403
            return f(*args, **kwargs)

        return wrapper

    return decorator
