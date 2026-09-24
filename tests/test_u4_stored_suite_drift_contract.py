"""Source contract for the U4 stored-suite Sector drift correction.

Evaluates the splice pairs declared in
supabase/migrations/20260924084505_u4_stored_suite_sector_drift.sql and applies
them, in Python, to the latest repository source of every stored function they
target. It proves coverage, exactly-once anchors, governed-Sector fixture
creation, safe teardown, preserved null-Sector refusal tests and a tests-only
blast radius. It is NOT a database claim: the executed proof is
tests/u4_stored_suite_rollback_rehearsal.sql.
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIG = ROOT / "supabase" / "migrations"
NAME = "20260924084505_u4_stored_suite_sector_drift.sql"
U4 = (MIG / NAME).read_text(encoding="utf-8")
REHEARSAL = (ROOT / "tests" / "u4_stored_suite_rollback_rehearsal.sql").read_text(encoding="utf-8")
PASSES, FAILURES = 0, []

SUITES = ["__s7r_body", "__s7r_teardown", "__s9p_body", "__s9p_teardown", "batch_locks", "batch_profile",
          "batch_set_cardinality", "family_f_security", "interest_authority"]
NEGATIVE = "    perform public.create_batch(v_fam, v_nag, null);\n"
UNTOUCHED = {  # sha256 prefix after normalising CRLF to LF
    "supabase/migrations/20260923132556_batch_customer_handoff.sql": "d999bc53cbeffda1",
    "supabase/migrations/20260923150000_customer_pricing_history_p0_1.sql": "14713058602253d5",
    "supabase/migrations/20260923170000_quote_revision_exact_recipient.sql": "0171812df38bf87e",
    "supabase/migrations/20260923183000_customer_pricing_history_p0_2.sql": "12af0a4515322933",
    "tests/cph_p0_1_rollback_rehearsal.sql": "cfcd61b96da1b1a9",
    "tests/cph_p0_2_rollback_rehearsal.sql": "712562c192af2a09",
    # re-pinned 2026-09-24 after the S2 rehearsal hardening (application-schema sequences, U4 branch)
    "tests/quote_recipient_rollback_rehearsal.sql": "4319026a7938745e",
}


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


# ── a tiny evaluator for the SQL text expressions the migration uses ──
TOKEN = re.compile(r"\s*(E'(?:[^'\\]|''|\\.)*'|'(?:[^']|'')*'|\|\||\[|\]|\(|\)|,|[A-Za-z_][A-Za-z_0-9.]*)")


def tokens(text):
    out, pos = [], 0
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m or not m.group(1):
            if text[pos:].strip() == "":
                break
            raise ValueError(f"cannot tokenise at {text[pos:pos + 40]!r}")
        out.append(m.group(1))
        pos = m.end()
    return out


def e_literal(body):
    return re.sub(r"''|\\n|\\\\", lambda m: {"''": "'", "\\n": "\n", "\\\\": "\\"}[m.group(0)], body)


class Parser:
    def __init__(self, text, env):
        self.t, self.i, self.env = tokens(text), 0, env

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def take(self, expected=None):
        tok = self.t[self.i]
        if expected is not None and tok.lower() != expected:
            raise ValueError(f"expected {expected!r}, got {tok!r}")
        self.i += 1
        return tok

    def expr(self):
        value = self.term()
        while self.peek() == "||":
            self.take()
            value += self.term()
        return value

    def term(self):
        tok = self.take()
        if tok.startswith("E'"):
            return e_literal(tok[2:-1])
        if tok.startswith("'"):
            return tok[1:-1].replace("''", "'")
        if tok.lower() == "replace":
            self.take("(")
            base = self.expr(); self.take(",")
            old = self.expr(); self.take(",")
            new = self.expr(); self.take(")")
            return base.replace(old, new)
        return self.env[tok]

    def array(self):
        self.take("array"); self.take("[")
        pairs = []
        while True:
            self.take("[")
            old = self.expr(); self.take(",")
            new = self.expr(); self.take("]")
            pairs.append((old, new))
            if self.peek() == ",":
                self.take()
                continue
            self.take("]")
            return pairs


block = U4[U4.index("do $u4$"):U4.index("end $u4$;")]
env = {}
for name, expr in re.findall(r"^\s*(\w+) constant text :=\s*(.*?);\s*$", block[:block.index("\nbegin\n")],
                             re.M | re.S):
    env[name] = Parser(expr, env).expr()
values = block[block.index("from (values") + len("from (values"):block.index(") as t(fn, pairs)")]
rows = {}
parser = Parser(values, env)
while parser.peek() is not None:
    parser.take("(")
    fn = parser.take()[1:-1]
    parser.take(",")
    rows[fn] = parser.array()
    parser.take(")")
    if parser.peek() == ",":
        parser.take()


# ── latest repository source body of each stored function ──
def latest_body(name):
    marker = f"create or replace function tests.{name}()"
    files = sorted(p for p in MIG.glob("*.sql") if p.name != NAME and marker in p.read_text(encoding="utf-8"))
    text = files[-1].read_text(encoding="utf-8")
    start = text.index(marker)
    open_tag = re.compile(r"\bas (\$\w*\$)").search(text, start)
    body_start = open_tag.end()
    return text[body_start:text.index(open_tag.group(1) + ";", body_start)], files[-1].name


sources = {name: latest_body(name) for name in SUITES}
spliced, counts_ok, count_report = {}, True, []
for fn, pairs in rows.items():
    name = fn[len("tests."):-2]
    body = sources[name][0]
    counts = [body.count(old) for old, _ in pairs]
    count_report.append(f"{name}:{counts}")
    counts_ok = counts_ok and all(count == 1 for count in counts)
    for old, new in pairs:
        body = body.replace(old, new, 1)
    spliced[name] = body

# ── the contract ──
check(sorted(fn[len("tests."):-2] for fn in rows) == sorted(SUITES)
      and all(f"'{name}'" in block for name in SUITES) and "<> 9 then" in block,
      "U4-DRIFT-1 the seven affected suites and both S7-R/S9P teardowns are covered, and the migration refuses unless all 9 are installed")
check(counts_ok, f"U4-DRIFT-2 every correction anchor matches its latest source exactly once ({', '.join(count_report)})")

creates = {name: re.findall(r"create_batch\(([^)]*)\)", body) for name, body in spliced.items()}
positive = {name: [args for args in calls if not args.endswith(", null") or name != "family_f_security"]
            for name, calls in creates.items()}
check(all(not args.endswith("null") for calls in positive.values() for args in calls)
      and sum(len(calls) for calls in positive.values()) == 8
      and all(args.endswith((", v_sec", ", v_u4_sector")) for calls in positive.values() for args in calls),
      "U4-DRIFT-3 all 8 positive fixture calls pass a governed fixture Sector (v_sec or v_u4_sector), none pass null")

order_ok = True
for name, body in spliced.items():
    for m in re.finditer(r"create_batch\(v_fam, v_(?:kol|nag), (v_sec|v_u4_sector)\)", body):
        var = m.group(1)
        prep = (r"perform tests\.__u4_attach_fixture_sector\(v_fam, v_sec\);" if var == "v_sec"
                else r"v_u4_sector := tests\.__u4_mint_fixture_sector\(v_fam, '__U4F_\w+'\);")
        preceding = [p.end() for p in re.finditer(prep, body) if p.end() < m.start()]
        between = body[preceding[-1]:m.start()] if preceding else ""
        order_ok = order_ok and bool(preceding) and "create_batch(" not in between and between.count("\n") <= 3
check(order_ok and "set local role authenticated" not in env["s7r_new"].split("\n")[0],
      "U4-DRIFT-4 each fixture attaches its Sector to its Family (as owner) immediately before that create_batch")

minted = {name: re.findall(r"__u4_mint_fixture_sector\(v_fam, '(__U4F_\w+)'\)", body) for name, body in spliced.items()}
codes = [code for found in minted.values() for code in found]
teardown_ok = len(codes) == len(set(codes)) == 6
for name, found in minted.items():
    for code in found:
        where = spliced["__s9p_teardown"] if name == "__s9p_body" else spliced[name]
        release = where.find(f"__u4_release_fixture_sector('{code}')")
        family_delete = where.find("delete from public.customer_families")
        sector_delete = where.find("delete from public.sector_versions")
        batches_delete = where.find("delete from public.batches")
        teardown_ok = teardown_ok and 0 <= batches_delete < release < family_delete and (
            name != "__s9p_body" or release < sector_delete)
for teardown, code in (("__s7r_teardown", "__S7R"), ("__s9p_teardown", "__S9P")):
    body = spliced[teardown]
    teardown_ok = teardown_ok and 0 <= body.find(f"__u4_release_fixture_sector('{code}')") < body.find(
        f"delete from public.sectors") and body.find("delete from public.batches") < body.find(
        f"__u4_release_fixture_sector('{code}')")
release_fn = U4[U4.index("function tests.__u4_release_fixture_sector"):]
release_fn = release_fn[:release_fn.index("end $fn$;")]
check(teardown_ok and release_fn.index("delete from public.customer_family_sectors")
      < release_fn.index("delete from public.sectors") and "left(p_code, 6) = '__U4F_'" in release_fn,
      "U4-DRIFT-5 every teardown unlinks the Family-Sector relationship after its Batches and before deleting the Sector or Family; only minted __U4F_ Sectors are dropped")

ffs = spliced["family_f_security"]
check(ffs.count(NEGATIVE) == 2 == sources["family_f_security"][0].count(NEGATIVE)
      and "'42501',\n    'FS-6 nor may they create a Batch" in ffs and "'42501', 'FS-17 nor may they create a Batch" in ffs
      and "(length(v_def) - length(replace(v_def, neg, ''))) / length(neg) <> 2" in block
      and all(NEGATIVE not in old for pairs in rows.values() for old, _ in pairs),
      "U4-DRIFT-6 the FS-6/FS-17 null-Sector authorization refusals are untouched and re-verified by the migration")

statements = re.sub(r"--[^\n]*", "", U4)
created = re.findall(r"create or replace function ([\w.]+)\(", statements)
headers = re.findall(r"create or replace function [\w.]+\([^)]*\)\s*returns \w+ ([^$]*?) as \$fn\$", statements)
check(created and all(fn.startswith("tests.__u4_") for fn in created)
      and not re.search(r"\b(alter|create|drop)\s+(table|policy|index|trigger|view|type|schema)\b", statements, re.I)
      and not re.search(r"\bgrant\b|\balter function\b", statements, re.I)
      and all(fn.startswith("tests.") for fn in rows)
      and set(re.findall(r"revoke all on function ([\w.]+)\(", statements)) == set(created),
      "U4-DRIFT-7 only tests-schema functions are created or replaced; no production function, table, policy or grant is touched")

shape = block[block.index("select jsonb_object_agg"):block.index("-- Prove the results")]
check(all(item in block for item in ("coalesce(p.proacl::text, 'default')", "p.prosecdef",
                                      "coalesce(p.proconfig::text, 'none')", "pg_get_userbyid(p.proowner)",
                                      "pg_get_function_result(p.oid)", "p.oid::regprocedure::text"))
      and "v_shape is distinct from" in block and "execute v_def;" in shape
      and len(headers) == len(created) == 3
      and all(header == "language plpgsql set search_path = ''" for header in headers),
      "U4-DRIFT-8 signatures, owner, ACL, security mode and search path are captured and proven unchanged; helpers are empty-search-path invokers")

check(all(hashlib.sha256((ROOT / path).read_bytes().replace(b"\r\n", b"\n")).hexdigest().startswith(prefix)
          for path, prefix in UNTOUCHED.items()),
      "U4-DRIFT-9 the exact-recipient, Batch handoff and Customer Pricing History migrations and rehearsals are byte-for-byte untouched")

mine = NAME.split("_", 1)[0]
touching = re.compile(r"create_batch|customer_family_sectors|tests\.(" + "|".join(SUITES) + r")\b")
earlier_sources = {p.name.split("_", 1)[0] for p in MIG.glob("*.sql")
                   if p.name != NAME and p.name.split("_", 1)[0] < mine and touching.search(p.read_text(encoding="utf-8"))}
later_touching = [p.name for p in MIG.glob("*.sql")
                  if p.name.split("_", 1)[0] > mine and touching.search(p.read_text(encoding="utf-8"))]
check(len(list(MIG.glob("*u4_stored_suite_sector_drift*"))) == 1
      and [p.name.split("_", 1)[0] for p in MIG.glob("*.sql")].count(mine) == 1
      and "20260915100440" in earlier_sources
      and all(latest_body(name)[1].split("_", 1)[0] < mine for name in SUITES)
      and not later_touching,
      f"U4-DRIFT-10 exactly one correction migration, after U4 and every migration defining or splicing the nine suites; no later migration touches them ({later_touching or 'none'})")

suites = re.search(r"foreach v_suite in array array\[(.*?)\] loop", REHEARSAL, re.S).group(1)
check("qos.rehearsal_target" in REHEARSAL and "raise exception 'REHEARSAL ROLLED BACK" in REHEARSAL
      and f"\\ir ../supabase/migrations/{NAME}" in REHEARSAL
      and sum(line.startswith("\\ir ") for line in REHEARSAL.splitlines()) == 1
      and "setval(" in REHEARSAL and "PRE-4 " in REHEARSAL and "NEG-1 " in REHEARSAL and "POST-2 " in REHEARSAL
      and sorted(re.findall(r"'(\w+)'", suites)) == sorted(["calculation_writer", "calculation_persistence", "batch_locks",
                                                           "batch_profile", "batch_set_cardinality",
                                                           "family_f_security", "interest_authority"]),
      "U4-DRIFT-11 the rehearsal is guarded, needs an empty keyring, applies the one migration, runs all seven suites, restores sequences and always aborts")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("U4 stored-suite drift contract PASS")
