"""Static contract gate: Proposed SKUs are quotable, and fixtures state a portfolio.

Run:  python tests/test_proposed_skus_quotable_contract.py

Covers two prepared migrations (Amendment 04, 2026-09-16):

  PQ-1..6  20260916210000_u2_proposed_skus_are_quotable - Calculate and Send admit a Proposed
           SKU and an unapproved version exactly as a Prospect is admitted, refuse only a
           WITHDRAWN SKU, and change nothing else (exact-anchor, count-asserted rewrites).
  PF-1..4  20260916170500_u2_test_fixtures_record_a_pricing_portfolio - every registered fixture
           that inserts a SKU states a portfolio explicitly; no default and no production path.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1] / "supabase" / "migrations"
Q = (ROOT / "20260916210000_u2_proposed_skus_are_quotable.sql").read_text(encoding="utf-8")
F = (ROOT / "20260916170500_u2_test_fixtures_record_a_pricing_portfolio.sql").read_text(encoding="utf-8")
PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


def literal(sql, name):
    m = re.search(name + r" text := \$q\$(.*?)\$q\$;", sql, re.S)
    return m.group(1) if m else ""


c_old, c_new = literal(Q, "c_old"), literal(Q, "c_new")
s_version, s_old, s_new = literal(Q, "s_old_version"), literal(Q, "s_old_status"), literal(Q, "s_new_status")
code = "\n".join(line.split("--", 1)[0] for line in Q.splitlines()).lower()

check("'sku_not_published'" in c_old and "'proposed'" in c_old and "'withdrawn'" in c_new
      and "sku_withdrawn" in c_new and "proposed" not in c_new.split("\n", 1)[1],
      "PQ-1 Calculate no longer refuses a Proposed SKU; it refuses only a withdrawn one")
check("sv.approved_at is null" in s_version and "'sku_version_unapproved'" in s_version
      and "v_def := replace(v_def, s_old_version, '');" in Q,
      "PQ-2 Send no longer refuses an unapproved SKU version")
check("not in ('active','discontinued')" in s_old and "s.status = 'withdrawn'" in s_new and "sku_withdrawn" in s_new,
      "PQ-3 Send admits Proposed SKUs and refuses only a withdrawn one")
check(Q.count("matched % times, expected 1") == 3 and "was not rewritten as intended" in Q,
      "PQ-4 every rewrite is count-asserted against the live definition and the result is proved")
check("like '%withdrawn%'" in Q and "object_not_in_prerequisite_state" in code,
      "PQ-5 it refuses to run before the withdrawn status exists (20260916200000)")
check(not re.search(r"\b(quote_revisions|quote_items|quote_families|construction_reference_invalid|pricing_basis|freight)\b",
                    c_new + s_new) and "create table" not in code and "grant " not in code,
      "PQ-6 nothing else in either function, no table and no grant changes; S9 stays narrow")

f_code = "\n".join(line.split("--", 1)[0] for line in F.splitlines()).lower()
expected = dict(re.findall(r'"([a-z_0-9]+)": (\d+)', F))
check(sum(int(v) for v in expected.values()) == 19 and len(expected) == 9,
      "PF-1 exactly the nineteen fixture inserts in the nine registered suites are rewritten")
check("pricing_portfolio)\\2values (\\3, ''transactional'')" in f_code,
      "PF-2 each fixture states 'Transactional' explicitly in its own insert")
check("default" not in re.sub(r"'[^']*'", "''", f_code) and "alter table" not in f_code,
      "PF-3 no default and no schema change - nothing classifies a SKU by itself (CDM-45)")
check("tests.% has % sku fixture inserts, expected %" in f_code
      and "still inserts a sku without a pricing portfolio" in f_code,
      "PF-4 the rewrite is count-asserted per suite and proved complete")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    for f in FAILURES:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("Proposed SKU quotability contract PASS")
