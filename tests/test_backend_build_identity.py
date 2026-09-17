"""Focused Flask gate for the backend build identity exposed by /health."""
import hashlib
import os
import sys
from pathlib import Path


BACKEND_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_DIR))
os.environ.setdefault("SUPABASE_URL", "https://backend-build-fixture.invalid")
os.environ.setdefault("SUPABASE_PUBLISHABLE_KEY", "backend-build-fixture-key")
os.environ["QOS_BACKEND_REVISION"] = "wave-a-fixture-revision"

import server  # noqa: E402


FAILURES = []
PASSES = 0


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


server.get_supabase_anon = lambda: object()
response = server.app.test_client().get("/health")
body = response.get_json() or {}
build = body.get("build") or {}
expected_hash = hashlib.sha256(Path(server.__file__).read_bytes()).hexdigest()

check(response.status_code == 200, "BI-1 /health remains available")
check(build.get("revision") == "wave-a-fixture-revision",
      "BI-2 /health reports the configured backend revision")
check(build.get("revision_source") == "QOS_BACKEND_REVISION",
      "BI-3 /health identifies the revision source")
check(build.get("artifact_sha256") == expected_hash and len(expected_hash) == 64,
      "BI-4 /health reports the loaded server artifact hash")
check(body.get("ok") is True and body.get("supabase") is True,
      "BI-5 the existing health fields retain their behavior")

saved_build = server.BACKEND_BUILD
saved_env = {key: os.environ.pop(key, None) for key in (
    "QOS_BACKEND_REVISION", "VERCEL_GIT_COMMIT_SHA", "GIT_COMMIT_SHA",
    "SOURCE_VERSION", "RENDER_GIT_COMMIT",
)}
try:
    fallback = server._backend_build_identity()
finally:
    server.BACKEND_BUILD = saved_build
    for key, value in saved_env.items():
        if value is not None:
            os.environ[key] = value

check(fallback.get("revision") == expected_hash[:12]
      and fallback.get("revision_source") == "server.py sha256",
      "BI-6 a deployment without revision metadata still has a stable build identity")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for failure in FAILURES:
        print(f"  FAILED: {failure}")
    raise SystemExit(1)
print("backend build-identity gate PASS")
