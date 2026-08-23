"""
Supabase clients — lazy singletons.

Reads SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY / SUPABASE_SECRET_KEY /
SUPABASE_JWKS_URL from the environment (loaded from .env in local dev via
python-dotenv).

- get_supabase()       anon/publishable-key client — respects RLS, safe for
                        anything mirroring what the browser could do itself.
- get_supabase_admin() secret-key (service role) client — bypasses RLS, only
                        for trusted backend-only operations. Never expose
                        this key or client to the frontend.

SUPABASE_JWKS_URL is read but not used yet — reserved for verifying Supabase
Auth JWTs locally once the backend has routes that need to check a user's
access token.
"""
import os

from dotenv import load_dotenv
from supabase import create_client, Client

load_dotenv()

SUPABASE_JWKS_URL = os.environ.get("SUPABASE_JWKS_URL")

_client: Client | None = None
_admin_client: Client | None = None


def get_supabase() -> Client:
    """Returns a cached anon/publishable-key Supabase client (RLS enforced)."""
    global _client
    if _client is None:
        url = os.environ.get("SUPABASE_URL")
        key = os.environ.get("SUPABASE_PUBLISHABLE_KEY")
        if not url or not key:
            raise RuntimeError(
                "SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY must be set "
                "(check quote-gen-be/.env)"
            )
        _client = create_client(url, key)
    return _client


def get_supabase_admin() -> Client:
    """Returns a cached secret-key (service role) Supabase client — bypasses RLS."""
    global _admin_client
    if _admin_client is None:
        url = os.environ.get("SUPABASE_URL")
        key = os.environ.get("SUPABASE_SECRET_KEY")
        if not url or not key:
            raise RuntimeError(
                "SUPABASE_URL and SUPABASE_SECRET_KEY must be set "
                "(check quote-gen-be/.env)"
            )
        _admin_client = create_client(url, key)
    return _admin_client
