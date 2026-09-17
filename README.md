# CFB Quotation Master — backend

Flask API and Supabase repository for the CFB Quotation Operating System. It provides authenticated
application routes, caller-scoped Supabase access, database migrations/tests, the retained
`calculate-batch-row` Edge Function source, and Excel-template export.

Frontend repository: [`../quote-gen-fe`](../quote-gen-fe). Start with
[`AGENTS.md`](AGENTS.md) and the shared
[`../quote-gen-fe/docs/current-state.md`](../quote-gen-fe/docs/current-state.md).

## Local development

```powershell
python -m venv venv
.\venv\Scripts\Activate.ps1
pip install -r requirements.txt
python server.py
```

The API normally runs at `http://localhost:3001`. `GET /health` reports service, template, and
Supabase-configuration availability together with `build.revision`, `build.revision_source`, and a
deterministic `build.artifact_sha256`. Deployments should set `QOS_BACKEND_REVISION`; otherwise the
service uses the platform commit identifier when available and a server artifact hash as its safe
fallback. Restart deliberately before route verification, then record the identity returned by the
running process.

## Repository map

- `server.py`: Flask application, route orchestration, and Excel exporter.
- `auth.py`, `caller_context.py`, `supabase_client.py`: authentication, capability enforcement, and
  caller/privileged Supabase clients.
- `supabase/migrations/`: immutable ordered schema, function, grant, and database-test history.
- `supabase/functions/calculate-batch-row/`: retained S9 Edge Function and generated engine bundle.
- `tests/test_*.py`: focused executable backend checks.
- `scripts/`: Edge engine bundling/executor fixtures and scoped dataset helpers.
- `AvadhootPacks_Quotation_Master_v7.xlsx`: source workbook template used by `/export` (renamed from `CFB_Quotation_Master_v7.xlsx`).
- `docs/CFB_QOS_Project_Brief_v3.md`: August 2026 source business document; its architecture snapshot
  is historical.

## API families

The current Flask app includes:

- health and Excel export;
- login, refresh, logout, profile/password/email, and user administration;
- caller-scoped Producing Plant, Customer Family, Customer Location, Construction, and Pricing Basis
  reads/mutations;
- governed Batch creation, locks, workspace, rows, sets, pricing/delivery groups, Calculate, and
  Atomic Send routes;
- Quote catalogue/workspace reads.

Route presence does not prove deployed activation or end-to-end verification. Inspect `server.py`
and its focused tests for the exact current contract.

## Environment boundary

The backend reads configuration such as `CORS_ORIGINS`, `SUPABASE_URL`, a publishable/anonymous key,
the backend-only privileged key, and optional timing/timeout settings. Values belong in approved
local/deployment secret-management surfaces, never in documentation or Git. Do not expose a
privileged key to the frontend.

The Edge Function expects its own attestation configuration. Production attestation material has
not been provisioned; do not invent, inspect, or commit it during ordinary development.

## S9 status

The S9 migrations and recorded automated database verification are complete. Production secret
provisioning, Edge Function deployment/activation, authenticated Calculate/Send/workflow proof,
runtime Maker/Checker/Admin proof, the genuine browser and persistent journey, and Product Owner
validation remain incomplete. S9 is not technically or Product Owner closed.

## Verification

Run the standalone test file(s) that exercise the changed route or authority boundary, for example:

```powershell
python tests/test_batch_calculate_send_routes.py
python tests/test_quote_workspace_route.py
python tests/test_auth_transport_bound.py
```

For Edge engine work, use the repository bundling and executor-fixture scripts and verify generated
bundle fidelity. Database changes require the directly related database suite and security/grant
checks. Documentation-only changes need no application regression suite.

## Non-negotiable boundaries

- Run application data access as the authenticated caller unless a documented admin-only operation
  requires the privileged client.
- Never edit, rename, or delete an applied migration.
- Preserve tenant/plant isolation, capability checks, optimistic concurrency, calculation authority,
  Quote/audit history, and immutable revisions.
- Keep frontend and backend calculation/export mirrors aligned; valid zeroes must not become
  fallbacks.
- Do not deploy or change live Supabase unless the task explicitly authorises it.
