"""Source contract for the migration-ledger gate (QUERY L) in
tests/quote_recipient_activation_preflight.sql.

QUERY L runs read-only on the live project and compares supabase_migrations.schema_migrations
with a manifest of the local migration files embedded in the preflight. This contract keeps that
manifest honest: it regenerates the manifest from supabase/migrations and fails if the embedded
copy is stale, and it pins the gate's refusal and verdict structure. It is NOT a database claim;
the evidence is QUERY L's output on main.

Fingerprint = first 16 hex of md5 over the migration text with `--` comments removed, runs of
whitespace collapsed to one space, and ends trimmed. It mirrors the SQL expression in QUERY L, so
comment-only and whitespace-only drift between a file and the ledger is tolerated; any other
difference is not, except the three pinned string-literal drifts in KNOWN_DRIFT.

    venv/Scripts/python.exe tests/test_migration_ledger_gate_contract.py           # check
    venv/Scripts/python.exe tests/test_migration_ledger_gate_contract.py --write   # refresh manifest
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations"
PREFLIGHT_PATH = ROOT / "tests" / "quote_recipient_activation_preflight.sql"
BEGIN = "-- BEGIN LOCAL MANIFEST"
END = "-- END LOCAL MANIFEST"
RECIPIENT = "20260923170000_quote_revision_exact_recipient.sql"
RECIPIENT_MD5 = "6f1840003862b1a5e77a34c2829b1ec7"
BETA_SEED = "20260922085000_beta_seed_indorama_36512_construction_and_sku.sql"
BETA_SEED_MD5 = "165c924db17970e40abd97f2e03f3f26"  # md5(statements[1]) on main, read 2026-09-24
# version -> (live fingerprint on main, local fingerprint). Reviewed 2026-09-24: the only
# differences are string literals (two pgTAP descriptions, one error hint naming a pre-rename
# version). Pinning both sides means any further change on either side fails the gate.
KNOWN_DRIFT = {
    "20260908113153": ("f4485844c55f5f33", "0dcbbafd62f75dfc"),
    "20260909110355": ("cd3ddfbdbc1567bc", "ec291228f4885307"),
    "20260917030435": ("77b124b6c8ee5ff6", "8f7f47659c037082"),
}
REQUIRED = ["20260911080000_s9b_atomic_send", "20260911090000_s9c_quote_workflow",
            "20260917030435_u2_proposed_skus_are_quotable", "20260923132556_batch_customer_handoff",
            "20260924084505_u4_stored_suite_sector_drift"]
REFUSALS = ["live_missing_locally", "name_mismatch", "fingerprint_mismatch", "unexplained_empty_history",
            "recipient_installed", "recipient_version_taken", "recipient_file_absent", "missing_dependencies"]
PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


def fingerprint(text):
    text = re.sub(r"\s+", " ", re.sub(r"--[^\n]*", "", text.replace("\r\n", "\n"))).strip(" ")
    return hashlib.md5(text.encode("utf-8")).hexdigest()[:16]


def local_files():
    return sorted(p for p in MIG.iterdir() if p.suffix == ".sql")


def manifest_lines():
    rows = []
    for p in local_files():
        version, _, name = p.stem.partition("_")
        rows.append(f"  ('{version}', '{name}', '{fingerprint(p.read_text(encoding='utf-8'))}')")
    return ",\n".join(rows)


def split(sql):
    head, rest = sql.split(BEGIN, 1)
    marker_line, rest = rest.split("\n", 1)
    body, tail = rest.split(END, 1)
    return head + BEGIN + marker_line + "\n", body, END + tail


if "--write" in sys.argv:
    raw = PREFLIGHT_PATH.read_bytes().decode("utf-8").replace("\r\n", "\n")
    head, _, tail = split(raw)
    PREFLIGHT_PATH.write_bytes((head + manifest_lines() + "\n" + tail).encode("utf-8"))
    print(f"manifest refreshed: {len(local_files())} local migrations")
    sys.exit(0)

RAW = PREFLIGHT_PATH.read_bytes()
PREFLIGHT = RAW.decode("utf-8").replace("\r\n", "\n")  # core.autocrlf checkouts are CRLF
_, BODY, _ = split(PREFLIGHT)
GATE = PREFLIGHT.split("-- ═════ QUERY L", 1)[1].split("-- ═════ QUERY A", 1)[0]
ROWS = re.findall(r"\('(\d{14})', '([a-z0-9_]+)', '([0-9a-f]{16})'\)", BODY)
names = [p.name for p in local_files()]

check(BODY.strip("\n") == manifest_lines(),
      "LEDGER-1 the embedded manifest equals the one regenerated from supabase/migrations (run --write after any add/rename)")
check(len(ROWS) == len(names) and len({v for v, _, _ in ROWS}) == len(ROWS)
      and all(re.fullmatch(r"\d{14}_[a-z0-9_]+\.sql", n) for n in names),
      f"LEDGER-2 {len(names)} local files, one manifest row each, unique versions, canonical file names")
seed = MIG / BETA_SEED
check(seed.exists() and hashlib.md5(seed.read_bytes().replace(b"\r\n", b"\n")).hexdigest() == BETA_SEED_MD5,
      "LEDGER-3 the recovered beta seed (LF-normalised) is byte-identical to its immutable live statement")
rec = MIG / RECIPIENT
check(rec.exists() and hashlib.md5(rec.read_bytes().replace(b"\r\n", b"\n")).hexdigest() == RECIPIENT_MD5
      and ("20260923170000", "quote_revision_exact_recipient", fingerprint(rec.read_text(encoding="utf-8"))) in ROWS,
      "LEDGER-4 the reviewed exact-recipient file is unchanged and present in the manifest")
drift_sql = dict((v, (lf, mf)) for v, lf, mf in re.findall(r"\('(\d{14})', '([0-9a-f]{16})', '([0-9a-f]{16})'\)",
                                                          GATE.split("known_drift(")[1].split("),\nempty_history")[0]))
local_fp = {v: fp for v, _, fp in ROWS}
check(drift_sql == KNOWN_DRIFT and all(local_fp[v] == mf and lf != mf for v, (lf, mf) in KNOWN_DRIFT.items()),
      "LEDGER-5 exactly three pinned string-literal drifts; each local side still matches its pin and differs from live")
check(all(f"'{r[:14]}', '{r[15:]}'" in GATE.split("required(")[1].split("target(")[0] and (MIG / f"{r}.sql").exists()
          for r in REQUIRED),
      "LEDGER-6 every required applied dependency is named in the gate and present locally")
check(all(f"'{k}'" in GATE for k in REFUSALS + ["connector_version_not_after_head", "connector_once_ok", "db_push_ok",
                                              "fresh_replay", "unapplied_behind_head"]),
      "LEDGER-7 the gate reports every refusal and the three separate verdicts")
connector = GATE.split("'connector_once_ok', ")[1].split(",\n  'db_push_ok'")[0]
check(all(f"r.{k} = '[]'" in connector for k in REFUSALS) and "not r.connector_version_not_after_head" in connector,
      "LEDGER-8 connector_once_ok is the conjunction of every refusal being empty and the clock being past the head")
push = GATE.split("'db_push_ok', ")[1].split(",\n  'fresh_replay'")[0]
check(all(f"r.{k} = '[]'" in push for k in REFUSALS) and "r.unapplied_behind_head = '[]'" in push
      and "r.unapplied_local = jsonb_build_array('20260923170000:quote_revision_exact_recipient')" in push,
      "LEDGER-9 db_push_ok additionally needs nothing behind the head and the recipient as the ONLY unapplied file")
fresh = GATE.split("'fresh_replay', ")[1].split(",\n  'read_only'")[0]
check(fresh.lstrip().startswith("'unproven") and "true" not in fresh,
      "LEDGER-10 fresh replay is never reported as proven by a ledger comparison")
body_sql = re.sub(r"--[^\n]*", "", GATE.split(END, 1)[1])
check(re.sub(r"--[^\n]*", "", GATE).count("set transaction read only;") == 1
      and not re.search(r"\b(insert|update|delete|alter|drop|create|truncate|grant|revoke|setval|nextval)\b",
                        body_sql, re.I),
      "LEDGER-11 QUERY L is one read-only SELECT")
check(PREFLIGHT.index("-- ═════ QUERY L") < PREFLIGHT.index("-- ═════ QUERY A")
      and "run QUERY L" in PREFLIGHT.split("-- ═════ QUERY L")[0]
      and "NOT EQUIVALENT" in PREFLIGHT.split("-- ═════ QUERY L")[0],
      "LEDGER-12 the procedure runs QUERY L first and keeps the three activation claims distinct")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("Migration-ledger gate contract PASS")
