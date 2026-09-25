"""Static contract for the unapplied S5 migration and its HTTP seam.

S5 Slice A (prior Quote lookup) and Slice C (record customer response). No
live database is required: this asserts the migration text and server.py
route wiring hold the settled governance shape (D-6 exact identity, append-
only outcomes, narrow grants) before the migration is ever applied.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATION = next((ROOT / "supabase" / "migrations").glob("*_s5_record_customer_outcome.sql"))
SQL = MIGRATION.read_text(encoding="utf-8")
SERVER = (ROOT / "server.py").read_text(encoding="utf-8")
ACTIVATION = (ROOT / "workflow_activation.py").read_text(encoding="utf-8")


def _function_body(text, def_marker):
    start = text.index(def_marker)
    end = text.index("\n@app.route", start + 1)
    return text[start:end]


record_route = _function_body(SERVER, "def record_customer_outcome_route")
prior_route = _function_body(SERVER, "def get_batch_prior_quote")

checks = {
    "record_customer_outcome reuses the existing append-only table, no new status column":
        "insert into public.customer_outcome_events" in SQL
        and "create table" not in SQL.lower()
        and "update public.customer_outcome_events" not in SQL
        and "delete from public.customer_outcome_events" not in SQL,
    "actor and outcome id are database-derived, never accepted from the caller": all(
        token in SQL for token in (
            "v_actor := app_private.current_app_user()",
            "recorded_by",
        )) and "p_recorded_by" not in SQL and "p_actor" not in SQL,
    "only an issued revision may receive an outcome": "v_q.workflow_status <> 'issued'" in SQL,
    "acceptance fields are rejected on any non-accepted outcome":
        "acceptance_fields_require_accepted" in SQL,
    "maker/checker/admin authorization, refused before any write": all(
        token in SQL for token in (
            "has_plant_cap(v_batch.plant_id, 'check_quote')",
            "has_group_cap('administer_users')",
            "has_plant_cap(v_batch.plant_id, 'make_quote')",
            "raise exception 'permission denied' using errcode = '42501';",
        )),
    "record_customer_outcome grants are narrow (revoked from public/anon, app_private unexposed)": all(
        token in SQL for token in (
            "revoke all on function app_private.record_customer_outcome",
            "revoke all on function public.record_customer_outcome",
            "grant execute on function public.record_customer_outcome(bigint, text, date, text, text) to authenticated",
            "S5 record_customer_outcome grants are not narrow",
        )),
    "prior-quote resolver prefers the exact Create-Revision source over a search": all(
        token in SQL for token in (
            "pending_quote_revision_sources where batch_id = p_batch",
            "'exact_source_revision'::text",
        )),
    "prior-quote resolver matches exact customer_party_id + plant_id, never Family-level": all(
        token in SQL for token in (
            "b.customer_party_id = v_batch.customer_party_id",
            "b.plant_id = v_batch.plant_id",
            "'last_quote_customer_plant'::text",
        )),
    "prior-quote resolver excludes the caller's own not-yet-issued family": "qr.family_id <> v_own_family_id" in SQL,
    "prior-quote resolver only considers issued revisions": "qr.workflow_status = 'issued'" in SQL,
    "prior-quote resolver is gated by can_read_batch, never a bare bigint check": "app_private.can_read_batch(p_batch)" in SQL,
    "prior-quote resolver grants are narrow": all(
        token in SQL for token in (
            "revoke all on function app_private.resolve_batch_prior_quote",
            "revoke all on function public.resolve_batch_prior_quote",
            "S5 resolve_batch_prior_quote grants are not narrow",
        )),
    "outcome route validates the closed outcome vocabulary": "_CUSTOMER_OUTCOMES = (" in SERVER
        and all(word in SERVER for word in ('"awaiting_response"', '"accepted"', '"rejected"', '"expired"')),
    "outcome route rejects acceptance fields on non-accepted outcomes before calling the RPC":
        'outcome != "accepted"' in record_route,
    "outcome route is append-only at the HTTP seam too (no PATCH/PUT, no delete)":
        '"/quotes/revisions/<int:revision_id>/outcome", methods=["POST"]' in SERVER,
    "prior-quote route distinguishes no_customer_selected from no_history":
        "no_customer_selected" in prior_route and "no_history" in prior_route,
    "compare route enforces exact customer+plant identity for an explicit ?against=": all(
        token in SERVER for token in (
            "current_batch.get(\"customer_party_id\") != prior_batch.get(\"customer_party_id\")",
            "current_batch.get(\"plant_id\") != prior_batch.get(\"plant_id\")",
        )),
    "comparison keys items by frozen batch_row_lineage_id, not label": "index_items" in SERVER
        and 'item.get("batch_row_lineage_id")' in SERVER,
    "comparison never treats a missing frozen fact as zero": "_evidence(" in SERVER
        and 'return value if value is not None else "unavailable"' in SERVER,
    "comparison classifies added/removed rows explicitly": '"added"' in SERVER and '"removed"' in SERVER
        and '"matched"' in SERVER,
    "record_outcome workflow action is gated to maker/checker/admin on an issued revision": all(
        token in ACTIVATION for token in (
            '"record_outcome": _state(',
            "(maker or checker or admin) and revision_status == \"issued\"",
        )),
}

failed = [label for label, ok in checks.items() if not ok]
for label, ok in checks.items():
    print(("ok   - " if ok else "FAIL - ") + label)
if failed:
    sys.exit(1)
print("S5 customer-response / prior-quote contract PASS")
