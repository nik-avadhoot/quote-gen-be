"""Source contract for the exact-recipient gates splices.

Simulates, in Python, the splices the consolidated 20260925085415 migration
(applied on main 2026-09-25 as the connector-assigned version of the file
originally checked in as 20260923170000_quote_revision_exact_recipient.sql)
makes into the stored
tests.__s9b_gates / tests.__s9c_gates definitions, using the repository source
of those functions. It proves every anchor matches exactly once against the
source text and that no hand-typed recipient survives. It is NOT a database
claim: the executed proof is tests/quote_recipient_rollback_rehearsal.sql.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations"
GATES = (MIG / "20260925085415_quote_revision_exact_recipient.sql").read_text(encoding="utf-8")
S9B = (MIG / "20260911081000_s9b_atomic_send_gates.sql").read_text(encoding="utf-8")
S9C = (MIG / "20260911091000_s9c_quote_workflow_gates.sql").read_text(encoding="utf-8")
REHEARSAL = (ROOT / "tests" / "quote_recipient_rollback_rehearsal.sql").read_text(encoding="utf-8")
PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


def e_literal(text):
    return text.replace("''", "'").replace("\\n", "\n")


def constants():
    found = {}
    for name, expr in re.findall(r"(\w+_(?:old|new)) constant text :=((?:\s*(?:\|\|\s*)?E'(?:[^']|'')*')+);", GATES):
        found[name] = "".join(e_literal(piece) for piece in re.findall(r"E'((?:[^']|'')*)'", expr))
    return found


def function_body(source, name):
    start = source.index(f"create or replace function {name}(")
    return source[start:source.index("end $fn$;", start)]


C = constants()
s9b = function_body(S9B, "tests.__s9b_gates")
# The stored __s9b_gates also carries the S9(c) call spliced before its cleanup comment.
s9b = s9b.replace("  -- Owner-only fixture cleanup;",
                  "  return query select * from tests.__s9c_gates(v_rev, v_fam, p_batch, p_oclaims, p_other, p_cclaims, p_checker);\n\n"
                  "  -- Owner-only fixture cleanup;", 1)
s9c = function_body(S9C, "tests.__s9c_gates")

pairs = {"__s9b_gates": (s9b, ["b_setup", "b_auth", "b_sent", "b_clean", "b_tail"]),
         "__s9c_gates": (s9c, ["c_decl", "c_issue", "c_rev2", "c_rev3"])}
spliced = {}
for fn, (body, keys) in pairs.items():
    counts = [body.count(C.get(f"{key}_old", "\0missing")) for key in keys]
    check(all(count == 1 for count in counts),
          f"S9R-SPLICE-1 every {fn} anchor matches its source exactly once ({counts})")
    for key in keys:
        body = body.replace(C[f"{key}_old"], C[f"{key}_new"])
    spliced[fn] = body

check("'Buyer'" not in spliced["__s9c_gates"]
      and "issue_quote_revision(p_revision,null,null" in spliced["__s9c_gates"]
      and "issue_quote_revision(v_rev3,null,null" in spliced["__s9c_gates"],
      "S9R-SPLICE-2 no stored gate issues with a hand-typed recipient any more")
b = spliced["__s9b_gates"]
check(b.index("__s9r_select_recipient(p_batch)") < b.index("v_before := tests.__s9b_state();")
      < b.index("S9R-1 ") < b.index("v_rev := public.send_batch(p_batch,v_cv);") < b.index("S9R-3 ")
      < b.index("__s9r_resolver_gates(p_batch, p_oclaims)") < b.index("__s9r_cleanup(p_batch, p_other)"),
      "S9R-SPLICE-3 recipient setup precedes the CAS baseline; refusal, freeze, resolver and cleanup run in order")
labels = re.findall(r"'(S9R-\d+) ", GATES + "".join(C.values()))
numbers = sorted({int(label.split("-")[1]) for label in labels})
check(numbers == list(range(1, 17)) and "v_s9 <> 76" in REHEARSAL,
      "S9R-SPLICE-4 S9R-1..16 are contiguous and the rehearsal expects 29 + 31 + 16 passing S9 assertions")
check("qos.rehearsal_target" in REHEARSAL and "raise exception 'REHEARSAL ROLLED BACK" in REHEARSAL
      and "\\ir ../supabase/migrations/20260925085415_quote_revision_exact_recipient.sql" in REHEARSAL
      and sum(line.startswith("\\ir ") for line in REHEARSAL.splitlines()) == 1 and "PRE-7 " in REHEARSAL
      and "if exists (select 1 from app_private.attestation_keys)" in REHEARSAL
      and "setval(" in REHEARSAL,
      "S9R-SPLICE-5 the rehearsal is isolation-guarded, needs an empty keyring, applies the one migration, restores sequences and always aborts")
check(not list(MIG.glob("20260923170500_*")) and len(list(MIG.glob("*quote_revision_exact_recipient*"))) == 1,
      "S9R-SPLICE-6 exactly one exact-recipient migration exists; the gates are not a separately applied file")
order = [GATES.index(marker) for marker in (
    "create or replace function app_private.resolve_batch_quote_recipient",
    "revoke all on function app_private.resolve_batch_quote_recipient",
    "execute replace(v_def, old_insert, new_insert);",
    "create or replace function app_private.issue_quote_revision",
    "create or replace function tests.__s9r_select_recipient",
    "v_fn := 'tests.__s9b_gates(",
    "-- ═════ 5. Final revokes and verification",
    "do $verify$")]
check(order == sorted(order) and "pending PO" not in GATES and "ship together" not in GATES.lower()
      and "Batch/Plant Send authority AND current read_party_master" in GATES
      and "S9R-1 a Batch writer without current read_party_master cannot Send, and the refusal writes nothing" in GATES,
      "S9R-SPLICE-7 one atomic migration in order: resolver, send_batch, issue, gates, final revokes and verification; settled read_party_master boundary")

# Sequence scope: only application schemas can ever reach setval.
APP_SCHEMAS = "array['public', 'app_private', 'ref_private']"
MANAGED = ("auth", "storage", "realtime", "extensions", "pg_catalog", "information_schema", "pg_toast",
           "supabase_functions", "supabase_migrations", "graphql", "vault", "net", "cron", "pgsodium")
code = "\n".join(line for line in REHEARSAL.splitlines() if not line.lstrip().startswith("--"))
tail = code[code.index("do $rehearse$"):]
guard = tail.find("refused to restore a sequence outside the application schemas")
check(code.count("setval(") == 1 and code.count("relkind = 'S'") == 2 and code.count(APP_SCHEMAS) == 2
      and "c.relkind = 'S' and n.nspname = any (" + APP_SCHEMAS + ") loop" in code
      and "not in ('pg_catalog'" not in code
      and 0 <= tail.find("v_nspname = any (" + APP_SCHEMAS + ")") < guard < tail.find("continue;", guard) < tail.find("setval(")
      and not any(re.search(rf"'{schema}'", code) for schema in MANAGED),
      "S9R-SPLICE-8 sequences are captured only from public/app_private/ref_private and the one setval is behind that allowlist; no managed schema is named")
check(all(field in tail for field in ("' baseline='", "' after-suites='", "' advanced='", "' restored='"))
      and "RESIDUE-5 every captured application sequence equals its baseline" in tail
      and tail.index("perform setval(") < tail.index("RESIDUE-5 every captured") < tail.index("raise exception 'REHEARSAL ROLLED BACK")
      and code.rstrip().endswith("end $rehearse$;"),
      "S9R-SPLICE-9 each changed sequence logs baseline, after-suites, advance and restored value; RESIDUE-5 re-reads all against baseline before the unconditional abort")


# U4 compatibility branch: simulate its decision on the repository source.
def sql_constants(block):
    out = {}
    for name, expr in re.findall(r"(\w+) constant text :=\s*((?:[^;']|'(?:[^']|'')*')+);", block):
        parts = re.findall(r"E'((?:[^']|'')*)'|(\b[a-z]\w*\b)", expr)
        out[name] = "".join(e_literal(lit) if lit else out[ref] for lit, ref in parts)
    return out


DRIFT = code[code.index("do $drift$"):code.index("end $drift$;")]
D = sql_constants(DRIFT)
U4 = sql_constants((MIG / "20260924084505_u4_stored_suite_sector_drift.sql").read_text(encoding="utf-8"))
body = function_body((MIG / "20260910160244_s7r_9b_hoist_signing_out_of_authenticated_blocks.sql").read_text(encoding="utf-8"),
                     "tests.__s7r_body")
tear = function_body((MIG / "20260911050635_s7r_13_rate_master_separation_gates.sql").read_text(encoding="utf-8"),
                     "tests.__s7r_teardown")


def branch(b, t):
    shape = (b.count(D["a_old"]), b.count(D["a_u4"]), t.count(D["t_u4"]), t.count(D["t_old"]))
    return {(0, 1, 1, 1): "skipped", (1, 0, 0, 1): "ran"}.get(shape, "raise")


corrected = (body.replace(U4["s7r_old"], U4["s7r_new"]), tear.replace(U4["s7t_old"], U4["s7t_new"]))
check(D["a_u4"] == U4["s7r_new"] and D["t_u4"] == U4["s7t_new"] and D["a_old"] == U4["s7r_old"]
      and branch(body, tear) == "ran" and branch(*corrected) == "skipped"
      and branch(corrected[0], tear) == "raise" and branch(body, corrected[1]) == "raise"
      and branch(body.replace(D["a_old"], ""), tear) == "raise" and branch(body + D["a_old"], tear) == "raise",
      "S9R-SPLICE-10 the U4 branch skips on the corrected source, runs only on the historical one, and fails closed on any other shape")
check("if n_old = 0 and n_u4 = 1 and t_rel = 1 and t_del = 1 then" in DRIFT
      and DRIFT.index("'drift_compat', '\"skipped:") < DRIFT.index("elsif") < DRIFT.index("execute replace(v_body")
      and DRIFT.count("execute ") == 2 and "raise exception 'DRIFT-1 unexpected S7-R fixture shape" in DRIFT
      and "'drift_compat', '\"ran:" in DRIFT and "-- U4 compatibility branch: '" in tail
      and "DRIFT-2 the corrected stored S7-R body and teardown were never rewritten" in tail
      and "md5(pg_get_functiondef('tests.__s7r_body()'::regprocedure))" in code.split("$capture$")[1],
      "S9R-SPLICE-11 the skip branch rewrites nothing, the run records its outcome, and DRIFT-2 proves the corrected functions are byte-identical")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("Exact-recipient gates splice contract PASS")
