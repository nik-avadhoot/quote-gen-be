# Backend working instructions

The parent [`../AGENTS.md`](../AGENTS.md) governs review posture and completion. This file adds only
backend-specific boundaries; do not copy the parent rules here.

## Repository scope

This repository contains the Flask API, Supabase caller-context and governed route layer, database
migrations and database tests, the undeployed `calculate-batch-row` Edge Function source, and the
Excel-template exporter. It is not a stateless export-only service.

## Guardrails

- Run every database/API operation as the authenticated caller unless a narrowly documented admin
  operation requires the privileged client. Never expose a secret/service-role key to the frontend.
- Preserve tenant/plant authorization, quotation authority, audit history, optimistic concurrency,
  and immutable revision boundaries.
- Applied migrations are immutable history. Add a new corrective migration; never edit, rename, or
  delete an applied migration.
- The Edge Function and bundled engine are active unfinished S9 material. Do not deploy, delete, or
  alter their activation status without explicit scope.
- `server.py` and the frontend costing engine contain mirrored export/calculation behavior. A change
  to either requires a deliberate mirror review and focused regression evidence.
- Blank, zero, and unresolved values are semantically distinct. Avoid truthiness fallbacks where
  zero is valid.
- Do not inspect `.env` contents or secret-management surfaces during ordinary work.
- Tests under `tests/test_*.py` are executable standalone checks even when `pytest` is unavailable.
  Choose the checks that can detect regressions in the affected route or boundary.

## Current S9 boundary

Migrations and automated database verification are recorded complete, but the production
attestation secret, Edge deployment, authenticated runtime proof, genuine browser/persistent
journey, end-to-end Maker/Checker/Admin proof, and Product Owner validation remain incomplete.
S9 is not technically or Product Owner closed. See
[`../quote-gen-fe/docs/current-state.md`](../quote-gen-fe/docs/current-state.md).
