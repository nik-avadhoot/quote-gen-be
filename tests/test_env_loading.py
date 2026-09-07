"""
server.py (the process entrypoint) must load quote-gen-be/.env relative to
its own file, not relative to the process's working directory - and it must
do so before importing caller_context, auth, or any other module that reads
SUPABASE_* at call time. supabase_client.py carries the identical fix for the
same reason, though nothing in the live request path currently imports it.

Run:  python tests/test_env_loading.py

Regression for: localhost /health reporting supabase: false and login
returning 500 "Auth backend is not configured" whenever the Flask process was
launched from a directory other than quote-gen-be itself. Root cause:
load_dotenv() with no path only searches upward from the CWD, so launching
via `quote-gen-be/venv/Scripts/python.exe quote-gen-be/server.py` from the
repo root (exactly what .claude/launch.json does) silently found nothing, and
caller_context.py - what /health and /auth/login actually call - has no
load_dotenv() call of its own, so it depended entirely on whatever the
process happened to inherit.

Hermetic: never reads the real quote-gen-be/.env for its VALUES - each case
runs `server.py` (and its real local dependencies caller_context.py/auth.py,
copied verbatim since they contain no secrets) as a subprocess against a
private temp directory holding its own throwaway .env. This modifies nothing
in the repository and cannot leak a real credential, which EL-6 asserts
explicitly.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

FAILURES, PASSES = [], 0

BACKEND_DIR = Path(__file__).resolve().parent.parent
LOCAL_MODULES = ["server.py", "caller_context.py", "auth.py"]


def check(cond, label):
    global PASSES
    if cond:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


def make_repo_copy(tmp_root, name, env_contents):
    """
    A stand-in for quote-gen-be holding real (secret-free) application code -
    server.py plus the local modules it imports - so importing `server` here
    exercises the real fix, not a simplified fixture, while never touching
    the real quote-gen-be/.env.
    """
    repo_copy = tmp_root / name
    repo_copy.mkdir(parents=True)
    for module in LOCAL_MODULES:
        (repo_copy / module).write_text(
            (BACKEND_DIR / module).read_text(encoding="utf-8"), encoding="utf-8")
    (repo_copy / ".env").write_text(env_contents, encoding="utf-8")
    return repo_copy


def import_server_and_check_health(cwd, sys_path_entry, env):
    """
    Imports `server` (never runs it as __main__, so app.run() never fires)
    and hits /health through Flask's own test client - the same code path a
    real request takes. Prints only booleans/known-fixture-safe values.
    """
    script = f"""
import sys
sys.path.insert(0, {str(sys_path_entry)!r})
import server  # noqa: E402
r = server.app.test_client().get("/health")
data = r.get_json() or {{}}
print("HEALTH_SUPABASE=" + str(data.get("supabase")))
print("RESOLVED_URL_MATCHES_OVERRIDE=" +
      str(server.os.environ.get("SUPABASE_URL") == "https://deployment-env-wins.invalid"))
"""
    return subprocess.run(
        [sys.executable, "-c", script],
        cwd=str(cwd), env=env, capture_output=True, text=True, timeout=30,
    )


with tempfile.TemporaryDirectory() as tmp:
    tmp_root = Path(tmp)
    clean_env = {k: v for k, v in os.environ.items() if not k.startswith("SUPABASE_")}
    fixture_env_contents = (
        "SUPABASE_URL=https://fixture-from-dotenv.invalid\n"
        "SUPABASE_PUBLISHABLE_KEY=fixture-publishable-key\n"
    )

    # ------------------------------------------------------------------ EL-1
    # Case 1: launched the way the server.py docstring itself documents -
    # `python server.py` with CWD *inside* quote-gen-be.
    repo1 = make_repo_copy(tmp_root, "case1_inside", fixture_env_contents)
    r1 = import_server_and_check_health(cwd=repo1, sys_path_entry=repo1, env=clean_env)
    check(r1.returncode == 0, "EL-1 importing server.py with CWD = quote-gen-be succeeds")
    check("HEALTH_SUPABASE=True" in r1.stdout,
          "EL-1a /health reports supabase:true when launched from inside quote-gen-be")

    # ------------------------------------------------------------------ EL-2
    # Case 2: launched the way .claude/launch.json actually does it -
    # `quote-gen-be/venv/Scripts/python.exe quote-gen-be/server.py` with CWD
    # = the parent project directory. This is the exact failure mode
    # reported (localhost login 500 "Auth backend is not configured").
    repo2 = make_repo_copy(tmp_root, "case2_parent", fixture_env_contents)
    r2 = import_server_and_check_health(cwd=repo2.parent, sys_path_entry=repo2, env=clean_env)
    check(r2.returncode == 0, "EL-2 importing server.py with CWD = the parent "
          "project directory succeeds")
    check("HEALTH_SUPABASE=True" in r2.stdout,
          "EL-2a /health reports supabase:true when launched from the parent "
          "directory (the reported regression)")

    # ------------------------------------------------------------------ EL-3
    # A pre-existing process/deployment env var must NOT be overwritten by
    # .env's value - .env is only a local fallback. Checked from the parent
    # CWD, since that is the launch style that matters in deployment.
    repo3 = make_repo_copy(
        tmp_root, "case3_precedence",
        "SUPABASE_URL=https://should-be-ignored.invalid\n"
        "SUPABASE_PUBLISHABLE_KEY=fixture-publishable-key\n",
    )
    precedence_env = dict(clean_env)
    precedence_env["SUPABASE_URL"] = "https://deployment-env-wins.invalid"
    r3 = import_server_and_check_health(cwd=repo3.parent, sys_path_entry=repo3, env=precedence_env)
    check(r3.returncode == 0, "EL-3 importing server.py with a pre-set "
          "SUPABASE_URL succeeds")
    check("HEALTH_SUPABASE=True" in r3.stdout,
          "EL-3a /health still reports supabase:true with a pre-set SUPABASE_URL")
    check("RESOLVED_URL_MATCHES_OVERRIDE=True" in r3.stdout,
          "EL-3b an already-defined environment variable takes precedence over .env")

    # ------------------------------------------------------------------ EL-4
    # supabase_client.py carries the identical module-relative fix (item 1 of
    # the original defect report), even though nothing currently imports it
    # in the live request path - verified directly, independent of server.py.
    (repo1 / "supabase_client.py").write_text(
        (BACKEND_DIR / "supabase_client.py").read_text(encoding="utf-8"), encoding="utf-8")
    sc_script = f"""
import sys
sys.path.insert(0, {str(repo1)!r})
import supabase_client  # noqa: E402
print("SC_RESOLVED=" + (supabase_client.os.environ.get("SUPABASE_URL") or ""))
"""
    r4 = subprocess.run([sys.executable, "-c", sc_script], cwd=str(repo1.parent),
                         env=clean_env, capture_output=True, text=True, timeout=30)
    check(r4.returncode == 0 and
          "SC_RESOLVED=https://fixture-from-dotenv.invalid" in r4.stdout,
          "EL-4 supabase_client.py also resolves its own .env via a module-relative "
          "path, independent of CWD")

    # ------------------------------------------------------------------ EL-5
    # Existing tests are untouched by this change: caller_context/auth read
    # os.environ, so anything that pre-sets SUPABASE_* (as test_login_bootstrap
    # and friends do) before importing server must still see its own value,
    # never a real or fixture .env value.
    override_only_env = dict(clean_env)
    override_only_env["SUPABASE_URL"] = "https://existing-test-fixture.invalid"
    override_only_env["SUPABASE_PUBLISHABLE_KEY"] = "existing-test-fixture-key"
    r5 = import_server_and_check_health(cwd=repo1.parent, sys_path_entry=repo1,
                                         env=override_only_env)
    check(r5.returncode == 0, "EL-5 importing server.py with test-style "
          "pre-set env vars succeeds")
    check("HEALTH_SUPABASE=True" in r5.stdout,
          "EL-5a a test-style pre-set SUPABASE_URL/KEY pair still resolves to a "
          "working client (existing tests unaffected)")

    # ------------------------------------------------------------------ EL-6
    # No value from the real quote-gen-be/.env ever appears in this test's
    # own output or any subprocess it launched.
    combined_output = "".join(
        r.stdout + r.stderr for r in (r1, r2, r3, r4, r5))
    real_env_path = BACKEND_DIR / ".env"
    real_env_text = real_env_path.read_text(encoding="utf-8") if real_env_path.exists() else ""
    real_values = [
        line.split("=", 1)[1].strip()
        for line in real_env_text.splitlines()
        if "=" in line and line.split("=", 1)[1].strip()
    ]
    check(bool(real_values), "EL-6 sanity: the real .env has values to check "
          "against (test is not vacuously passing)")
    check(all(v not in combined_output for v in real_values),
          "EL-6a no value from the real quote-gen-be/.env appears anywhere in test output")

print()
print(f"{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("env-loading gate PASS")
