"""Forward-migration contract for exact immutable Quote recipient identity."""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SQL = (ROOT / "supabase" / "migrations" /
       "20260923170000_quote_revision_exact_recipient.sql").read_text(encoding="utf-8")
PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


check("join public.parties p on p.id = b.customer_party_id" in SQL
      and "'identity_authority', 'batches.customer_party_id'" in SQL,
      "RECIPIENT-SQL-1 Send resolves the exact Party selected by the governed Batch")
check("app_private.has_group_cap('read_party_master')" in SQL
      and "app_private.current_app_user() is null" in SQL
      and "from public, anon, authenticated" in SQL,
      "RECIPIENT-SQL-2 recipient resolution is caller-authorized and not directly executable")
check("p.lifecycle_state = 'customer' and p.status = 'active'" in SQL
      and "p.lifecycle_state = 'prospect' and p.status in ('proposed', 'active')" in SQL,
      "RECIPIENT-SQL-3 active Customers and proposed/active Prospects retain the handoff boundary")
check("addressee_name, addressee_details" in SQL
      and "resolve_batch_quote_recipient(p_batch)" in SQL
      and "returning id into v_revision" in SQL,
      "RECIPIENT-SQL-4 the recipient is frozen inside the existing atomic revision insert")
issue_body = SQL.split("create or replace function app_private.issue_quote_revision", 1)[1]
check("recipient_identity_mismatch" in issue_body
      and "exact_recipient_identity_unavailable" in issue_body
      and "addressee_name=p_addressee_name" not in issue_body
      and "addressee_details=p_addressee_details" not in issue_body,
      "RECIPIENT-SQL-5 Issue validates supplied identity and never replaces the frozen recipient")
check("v_q.addressee_details->>'party_id'" in issue_body
      and "identity_authority" in issue_body,
      "RECIPIENT-SQL-6 legacy revisions without exact identity are refused explicitly")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("Exact Quote recipient migration contract PASS")
