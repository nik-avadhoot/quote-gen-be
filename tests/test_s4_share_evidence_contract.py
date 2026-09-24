"""Static contract for the unapplied S4 sharing migration and its HTTP seam."""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATION = next((ROOT / "supabase" / "migrations").glob("*_quote_revision_share_evidence.sql"))
SQL = MIGRATION.read_text(encoding="utf-8")
SERVER = (ROOT / "server.py").read_text(encoding="utf-8")

checks = {
    "one immutable share event per revision with channel/date/actor": all(token in SQL for token in
        ("create table public.quote_share_events", "uk_qse_revision unique (revision_id)",
         "channel", "shared_on", "shared_by")),
    "closed channel vocabulary is constrained in the database": "Printed/hand-delivered" in SQL and "Customer portal" in SQL,
    "event table is caller-readable but application-unwritable": all(token in SQL for token in
        ("grant select on public.quote_share_events to authenticated", "revoke insert, update, delete, truncate",
         "quote_share_events_select", "can_read_quote_revision(revision_id)")),
    "share transition and evidence are one caller-bound RPC": all(token in SQL for token in
        ("app_private.share_quote_revision", "security definer set search_path = ''",
         "insert into public.quote_share_events", "workflow_status = 'issued'")),
    "old evidence-free issue RPC is unavailable to app callers": "revoke all on function public.issue_quote_revision" in SQL,
    "route never accepts a recipient replacement": "def share_quote_revision_route" in SERVER and "p_channel" in SERVER
        and "addressee_name" not in SERVER[SERVER.index("def share_quote_revision_route"):SERVER.index("def create_quote_revision_route")],
}

failed = [label for label, ok in checks.items() if not ok]
for label, ok in checks.items():
    print(("ok   - " if ok else "FAIL - ") + label)
if failed:
    sys.exit(1)
print("S4 sharing evidence contract PASS")
