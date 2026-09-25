"""Direct-connection runner for tests/s5_quote_revision_activation_rehearsal.sql.

Exists because the Supabase MCP SQL-execution endpoint times out on the
rehearsal's heaviest block (the exact-recipient migration's S9R
gate-splicing do $mig$ block) before ever reaching or altering the
database. This runner opens a real, long-lived PostgreSQL connection
instead, with no client-side response-size/time limit of that kind.

Reads MAIN_DB_URL from quote-gen-be/.env (git-ignored) and NEVER prints,
logs, or returns it - only the project reference is reported. Opens ONE
transaction (autocommit is never enabled), sets the exact main-authorization
guard marker the rehearsal file requires, executes the mechanically
expanded rehearsal (the three \\ir directives replaced with the literal,
hash-verified migration file contents, in order - nothing omitted or
split), and always rolls back in `finally`. A clean run therefore always
"fails" with a raised exception whose message starts with
"REHEARSAL ROLLED BACK." - failures=0 in that message is the pass signal.

Usage (from quote-gen-be/):
    venv/Scripts/python.exe tests/run_s5_rehearsal.py
"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENV_PATH = ROOT / ".env"
REHEARSAL_PATH = ROOT / "tests" / "s5_quote_revision_activation_rehearsal.sql"
TARGET_PROJECT_REF = "czettlukuenlnnrmvhqt"
GUARD_MARKER = "main_rollback_authorized_20260925"
STATEMENT_TIMEOUT_MS = 5 * 60 * 1000  # 5 minutes: sufficiently long, not unbounded
LOCK_TIMEOUT_MS = 5 * 1000  # 5 seconds: refuse fast rather than block production traffic

EXPECTED_MIGRATION_HASHES = {
    "20260923170000_quote_revision_exact_recipient.sql":
        "0171812df38bf87e7b56cf1831e7eaf97508b547d308212f012b89e1d14c770a",
    "20260924173944_quote_revision_share_evidence.sql":
        "358232073c5406f76326741e6a8b95a054b8886338a8dbadd749703d0c768b48",
    "20260925090000_s5_record_customer_outcome.sql":
        "515fc60d630af8ea7c484ea890628ab5d6c9a98faec8474d55e461f6583450d9",
}


def load_env(path):
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        env[key.strip()] = value.strip()
    return env


def resolve_db_url():
    if not ENV_PATH.exists():
        raise SystemExit(f".env not found at {ENV_PATH}")
    env = load_env(ENV_PATH)
    db_url = env.get("MAIN_DB_URL")
    if not db_url:
        raise SystemExit("MAIN_DB_URL is not set in .env")
    return db_url


def verify_target(db_url):
    """Parses the host/user and confirms the project reference WITHOUT ever
    printing or returning the URL itself. A Supabase pooler connection
    (session or transaction pooler) carries the project ref in the
    username (postgres.<ref>@aws-0-...pooler.supabase.com), not the host;
    a direct connection carries it in the host (db.<ref>.supabase.co).
    Both are checked."""
    from urllib.parse import urlparse
    parsed = urlparse(db_url)
    host = parsed.hostname or ""
    user = parsed.username or ""
    if TARGET_PROJECT_REF not in host and TARGET_PROJECT_REF not in user:
        raise SystemExit(
            f"refusing: connection host/user does not reference project {TARGET_PROJECT_REF}")
    kind = "pooler (session, port 5432)" if "pooler.supabase.com" in host else "direct"
    print(f"target confirmed: project {TARGET_PROJECT_REF} via a {kind} connection "
          "(host/user verified, not printed)")


def verify_migration_hashes():
    migrations_dir = ROOT / "supabase" / "migrations"
    verified = {}
    for name, expected in EXPECTED_MIGRATION_HASHES.items():
        path = migrations_dir / name
        if not path.exists():
            raise SystemExit(f"migration file missing: {name}")
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(
                f"HASH MISMATCH {name}: expected {expected}, got {actual} - refusing to run")
        verified[name] = (path, actual)
        print(f"hash verified: {name} {actual[:16]}...")
    return verified


def expand_rehearsal(verified_migrations):
    """Mechanically replaces each \\ir line with its hash-verified file
    content, in the exact order the rehearsal file names them. Nothing is
    omitted, reordered, or rewritten."""
    if not REHEARSAL_PATH.exists():
        raise SystemExit(f"rehearsal file missing: {REHEARSAL_PATH}")
    text = REHEARSAL_PATH.read_text(encoding="utf-8")
    order = [
        "20260923170000_quote_revision_exact_recipient.sql",
        "20260924173944_quote_revision_share_evidence.sql",
        "20260925090000_s5_record_customer_outcome.sql",
    ]
    out_lines = []
    substituted = 0
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        matched_name = None
        for name in order:
            if stripped == f"\\ir ../supabase/migrations/{name}":
                matched_name = name
                break
        if matched_name:
            path, digest = verified_migrations[matched_name]
            out_lines.append(f"\n-- INLINED: {matched_name} (sha256 {digest[:16]}...)\n")
            out_lines.append(path.read_text(encoding="utf-8"))
            out_lines.append(f"\n-- END INLINE: {matched_name}\n")
            substituted += 1
        else:
            out_lines.append(line)
    if substituted != 3:
        raise SystemExit(f"expected exactly 3 \\ir substitutions, got {substituted}")
    expanded = "".join(out_lines)
    if any(l.strip().startswith("\\") for l in expanded.splitlines()):
        raise SystemExit("expanded SQL still contains a psql meta-command line - refusing to run")
    return expanded


def main():
    print("=== S5 activation rehearsal: direct-connection runner ===")
    db_url = resolve_db_url()
    verify_target(db_url)
    verified_migrations = verify_migration_hashes()
    expanded_sql = expand_rehearsal(verified_migrations)
    print(f"expanded rehearsal built: {len(expanded_sql)} chars")

    try:
        import psycopg
    except ImportError:
        raise SystemExit(
            "psycopg is not installed. This runner requires it solely for this rehearsal "
            "(pip install 'psycopg[binary]' in the venv) - it is not an application dependency.")

    conn = None
    try:
        conn = psycopg.connect(db_url, autocommit=False)
        with conn.cursor() as cur:
            # SET does not accept bind parameters in Postgres; GUARD_MARKER
            # is a fixed internal constant (not user input), so a direct
            # literal is safe here.
            cur.execute(f"SET statement_timeout = {STATEMENT_TIMEOUT_MS}")
            cur.execute(f"SET lock_timeout = {LOCK_TIMEOUT_MS}")
            cur.execute(f"SET qos.rehearsal_target = '{GUARD_MARKER}'")
            print("session configured: statement_timeout=5min lock_timeout=5s "
                  f"qos.rehearsal_target={GUARD_MARKER}")
            print("executing expanded rehearsal (one transaction, no autocommit)...")
            cur.execute(expanded_sql)
        # A clean rehearsal NEVER reaches here - it always raises via the
        # final deliberate RAISE. Reaching this line means the rehearsal's
        # own tail RAISE did not fire, which is itself a defect to report.
        print("UNEXPECTED: the rehearsal completed without raising its final exception.")
        return 1
    except Exception as exc:  # noqa: BLE001 - we must classify psycopg's own exception here
        message = str(exc)
        print("\n--- rehearsal result ---")
        print(message)
        if "REHEARSAL ROLLED BACK. failures=0" in message:
            print("\nRESULT: PASS (failures=0)")
            return 0
        if "REHEARSAL ROLLED BACK." in message:
            print("\nRESULT: FAIL (rehearsal ran to completion but reported failures)")
            return 2
        if "REHEARSAL PRECONDITIONS FAILED" in message:
            print("\nRESULT: PRECONDITIONS FAILED (nothing was run)")
            return 3
        print("\nRESULT: UNEXPECTED ERROR (did not reach the rehearsal's own final RAISE)")
        return 4
    finally:
        if conn is not None:
            try:
                conn.rollback()
            finally:
                conn.close()
            print("connection rolled back and closed.")


if __name__ == "__main__":
    sys.exit(main())
