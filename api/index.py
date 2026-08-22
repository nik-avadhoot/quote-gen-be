"""
Vercel serverless entry point.

The Python runtime looks for a WSGI callable named `app` in this module.
`vercel.json` rewrites every incoming path to /api/index, so Flask sees the
original URL and its own routing table takes over from there.
"""
import os
import sys

# server.py lives one level up from api/; make it importable.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from server import app  # noqa: E402  — must follow the sys.path fix above

__all__ = ["app"]
