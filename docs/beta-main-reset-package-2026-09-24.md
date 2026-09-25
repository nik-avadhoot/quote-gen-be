# Beta main reset package (2026-09-24) — DEFERRED CUTOVER PLANNING

> **Timing correction, Product Owner 2026-09-24 (supersedes any implication of an immediate
> reset).** The main reset is a future beta-cutover activity, not current work. Until the
> sequence below is reached, do not reset main, create or link a rehearsal project, move the five
> beta-data migrations, rewrite migration history, delete Auth users or application data, or
> prepare/commit the final beta seed. The local-versus-live history mismatch is **deferred cutover
> debt**: it blocks product implementation only when a specific current change cannot be
> implemented or verified safely.
>
> Cutover sequence:
> 1. Complete and accept S1–S5.
> 2. Freeze the pending schema and migration set, including Customer Pricing History.
> 3. Finalise the minimum beta seed and identity list.
> 4. Rehearse a complete fresh build on an isolated project.
> 5. Request final destructive authorisation.
> 6. Reset and reseed main.
> 7. Begin the S6 pilot and legacy-path removal.
>
> The read-only inventory in sections 1, 2 and 4 is kept as evidence for step 2. Re-read it
> against live before use; it describes main as of 2026-09-24. Decisions D1–D8 are not open
> questions until step 3.

Product Owner ruling 2026-09-24: a complete reset of the main Supabase database
(`czettlukuenlnnrmvhqt`) before beta is acceptable; existing trial, fixture, localhost and
Vercel-facing data may be discarded. Goal: repository migrations are the source of truth, a fresh
database replays without manual patches, only deliberate beta seed data is restored, and main and
local migration histories match.

**Status: planning complete, rehearsal NOT run.** Step 4 of the ruling (prove the complete local
chain builds a fresh database) needs an isolated Postgres/Supabase target. This machine has none
(no psql, Postgres, Docker or WSL), the 2.8 MB chain cannot pass through the MCP `execute_sql`
tool, and the MCP connector is bound to main. The destructive confirmation (section 8) may only be
requested after section 3 passes.

## 1. Canonical ordered migration set

Canonical = every file in `supabase/migrations`, in version order, **minus the five beta-data
migrations in section 2**, which move to `supabase/beta_seed_history/` (kept verbatim, never
replayed). That leaves **232 migrations**, 20260823111400 → 20260924100057.

The pending tail replays in its existing local order; no file is renamed:

| Version | File | Owner | Depends on |
|---|---|---|---|
| 20260923132556 | batch_customer_handoff | S2 (applied) | Family F/G |
| 20260923150000 | customer_pricing_history_p0_1 | CPH | parties, SKUs |
| 20260923170000 | quote_revision_exact_recipient | S2 | 20260923132556, 20260917030435, S9B/S9C |
| 20260923183000 | customer_pricing_history_p0_2 | CPH | p0_1 |
| 20260924044157 | customer_pricing_history_p0_4 | CPH | p0_1, p0_2 |
| 20260924084505 | u4_stored_suite_sector_drift | S2 (applied) | U4 |
| 20260924100057 | customer_pricing_history_p0_4_1_sob_allocated_boxes | CPH | p0_4 |

Why the local order is safe:
- Exact-recipient splices `send_batch`, `issue_quote_revision`, `tests.__s9b_gates` and `tests.__s9c_gates`.
- U4 drift splices seven different stored suites.
- The CPH migrations touch only `cph_*` objects.

These three sets are disjoint, so exact-recipient remains independent of CPH, and running before U4
drift (unlike on live) changes nothing it anchors on. After a reset the live history is rebuilt
from these files with their file versions, so the "sorts behind the head" problem disappears
without renumbering.

Prerequisite: the canonical set must be committed (several files are untracked today:
Batch handoff, U4 drift, recovered beta seed, all CPH and exact-recipient files and their tests).

## 2. Beta-data migrations — classification and decision

Five migrations contain no schema. Each writes trial data under live identities (`INTO STRICT` on
app user 44 / 3535 / 3536 or party 245), so each **aborts on an empty database**:

| Version | Content | Decision |
|---|---|---|
| 20260918040738 seed_nagpur_limited_beta_masters | 19 Sectors, calc defaults, NAG Rate Set (17 grades), Freight Set (1 lane), PBR, 4 beta Constructions — PO-approved "current defaults" | **Replace**: same values re-seeded after reset by the governed beta seed (section 5) |
| 20260918090810 restore_nagpur_beta_freight_lane | re-inserted the lane deleted by a test cleanup | **Omit**: covered by the replacement seed |
| 20260918091350 grant_snehal_nag_make_quote | capability grant for user 3536 | **Replace**: section 5 access step |
| 20260918094026 open_all_capabilities_to_beta_users | all capabilities for 3535/3536 | **Replace**: section 5 access step |
| 20260922085000 beta_seed_indorama_36512_construction_and_sku | trial SKU 36512 + CON-000061 for the tester-created Indo Rama prospect | **Omit**: disposable trial seed; testers recreate through the app |

The 20260922085000 file was recovered byte-for-byte from live history on 2026-09-24. It moves to
the archive with the others, so no migration history is fabricated. The same holds for all five:
after the reset they are not in the live ledger, and the archive records what was once applied.

All early bootstrap migrations with data inserts are replay-safe and stay canonical:
- **S1a:** inserts group, capabilities and plants NAG/PUN/KOL.
- **p2_2 and p2_9 invitations:** insert nothing on an empty database.
- **GSM values, U4 family sectors and rate-entry updates:** idempotent on an empty database.

**Governance conflict to acknowledge:** `quote-gen-be/AGENTS.md` says applied migrations are never
edited, renamed or deleted. Moving these five out of `migrations/` is a one-time exception enabled
only by the reset (they cease to be applied history). It needs explicit PO acknowledgement.

## 3. Rehearsal (required before section 8)

Fidelity requirement: same platform, Postgres 17, and the same extensions:
`pgtap`, `pgcrypto`, `btree_gist`, `uuid-ossp`, `supabase_vault`, `pg_stat_statements`.

Options, recommended first:
1. **Disposable Supabase project** (free plan, same region) — run the exact reset command
   against it. Highest fidelity; it also rehearses the command itself.
2. Docker Desktop + Supabase CLI local stack (`supabase db reset`). Reusable for future replay
   checks, but it is a system installation.
3. Rehearse on main as phase 1 of the real reset. Data loss is already acceptable, but a failure
   leaves main broken until fixed.

Pass criteria:
- `db reset` completes with no manual patch.
- `migration list` shows local = remote (232 = 232).
- `select * from tests.run_all()` reports 0 not-ok.
- The section 5 seed runs clean.
- QUERY B of the recipient preflight shows every `*_ok=true`.

Known risk the rehearsal must clear:
- 28 applied files differ from live only by comments/whitespace, and 3 by string literals, so a
  fresh replay builds function bodies from the local text.
- Later verbatim-anchor splices and the suites executed at apply time (s6_18, s7r_10, u2_*,
  20260917182138, u5 gates) have only ever run against the live text and live data.

## 4. What a main reset removes (live inventory, read-only, 2026-09-24)

| Area | Removed | Count / detail |
|---|---|---|
| App data | all rows in public/app_private/ref_private/tests | 60 tables, 38 non-empty; e.g. 7 app_users, 5 parties, 6 families, 19 sectors, 17 rate entries, 1 freight lane, 1 PBR, 5 constructions, 1 SKU, 1 batch, 117 capability grants, 92 reference sequences |
| Schema objects | all user-created objects (functions, policies, triggers, grants) | rebuilt by replay |
| Migration history | `supabase_migrations.schema_migrations` | 232 rows, rebuilt with file versions |
| Auth | `auth.users` 7 / identities 6 / sessions 13 / refresh tokens 38 | **not removed by `db reset`**; handled by decision D2 |
| Storage | buckets 0, objects 0 | nothing |
| Secrets / keyring | vault secrets 0, `app_private.attestation_keys` 0 | nothing to lose; keyring must be provisioned (section 5) |
| Cron | pg_cron not installed | nothing |
| Edge Functions | `calculate-batch-row` v1 ACTIVE | **untouched** by a DB reset |
| Roles | cluster-level roles | untouched (documented `db reset --linked` behaviour) |

Database size is 28 MB, on Postgres 17.6.

The 7 auth users are:
- 44 NikunjRL (admin)
- 45 ClaudeCode (service identity)
- 3535 Sonali
- 3536 Snehal
- three fixture/deactivated accounts: 1375, 1574 and 3440

## 5. Minimum governed beta seed (post-reset)

Run in this order. Every write goes through the governed RPCs, as the named actor — never
table-first, except where Wave B already did so under the actor's role.

1. **Administrator.** Provision the invitation for `nikunj@avadhootpacks.in` (admin) with
   `app_private.provision_pending_invitation`, then the PO signs in once; greenfield
   provisioning creates the admin app user.
2. **Service identity.** Invite `ClaudeCode`, sign in, and grant it the same capabilities
   (needed as the seed actor for later SR DEV operations).
3. **Party master.** Nagpur Distillers Private Limited:
   - customer `G0080-001`, active;
   - family `Nagpur Distillers`, group code `G0080`;
   - bill-to `G0080-001-02` (Gurugram) and ship-to `G0080-001-03` (Nagpur);
   - family-sector link as live.
4. **Commercial masters.** Wave B content unchanged (19 Sectors, calc defaults, NAG Rate Set,
   Freight Set with the single G0080-001-03 lane at 2.0000/kg, PBR "Nagpur Limited Beta
   2026-09-17", 4 beta Constructions). The script is adapted from 20260918040738 with one
   change: the ship-to is looked up by `customer_code`/`location_code`, not party id 245.
5. **Users/access.** Invite Sonali (`sales.01@avadhootpacks.in`) and Snehal
   (`marketing@avadhootpacks.in`). After they sign in, set capabilities through
   `set_user_capabilities`: every capability, as ruled 2026-09-18.
6. **Attestation.** Provision one keyring key through the approved secret surface: an Edge
   Function secret plus the `attestation_keys` row. Calculate is blocked without it (0 today).

Not seeded:
- the four trial prospects (Slice D, Vidarbha, Solar Explosives, Indo Rama);
- SKU 36512 and CON-000055..58/61 (trial);
- the batch and its locks.

## 6. Rollback / recovery

- **Before the reset:**
  - Take a logical backup with the CLI: `db dump --linked` for schema, `--data-only`, and
    `--role-only`, plus a separate `--data-only --schema auth` dump.
  - Store it outside the repo. It contains personal data and password hashes.
  - Confirm in the dashboard whether the plan's daily backups/PITR are available.
- **Primary recovery is roll-forward.** The data is disposable, so a failed replay is fixed in the
  repo and `db reset --linked` is re-run from scratch; it is idempotent.
- **Forensic restore:** replay the dump with psql (not installed here; install at need) or the
  dashboard restore.
- **Freeze during the window:**
  - no other session applies, renames or rehearses migrations;
  - testers told the app is down;
  - Vercel frontend left up but unused.

## 7. Estimated window

| Step | Time |
|---|---|
| Backup | 5 min |
| Reset and replay | ~10 min |
| Verification (`migration list`, `run_all`, QUERY B) | 10 min |
| Admin sign-in and seed steps 1–4 | 20 min |
| User invites, sign-ins and grants | 15–20 min |
| Attestation key | 15 min |

About 1.5 h. **Book a 2 h window**, after a clean rehearsal.

## 8. Destructive-action confirmation (to be issued only after section 3 passes)

Commands run from `quote-gen-be/` (CLI via `npx supabase`; `login`/`link` need the user's own
credentials and are done by the user):

```
npx supabase link --project-ref czettlukuenlnnrmvhqt
npx supabase db dump --linked -f ../backups/main-2026XXXX-schema.sql
npx supabase db dump --linked --data-only -f ../backups/main-2026XXXX-data.sql
npx supabase db dump --linked --data-only --schema auth -f ../backups/main-2026XXXX-auth.sql
npx supabase db reset --linked            # drops user entities, replays 232 migrations
npx supabase migration list --linked      # expect 232 local = 232 remote
```

Then run the auth clean-up per D2, `select * from tests.run_all()`, and the seed scripts in
section 5 order. The exact seed SQL files are authored after decisions D2–D5 and are run first in
the rehearsal.

## Decisions still with the Product Owner

- **D1 Rehearsal target:** disposable project (recommended), local Docker, or rehearse on main.
- **D2 Auth accounts:** keep the 4 real accounts and delete the 3 fixtures (recommended: no
  password resets), or delete all 7 and re-invite.
- **D3 Commercial masters:** restore Wave B values unchanged (recommended).
- **D4 Parties:** seed only Nagpur Distillers (recommended); the other four prospects and Indo
  Rama/SKU 36512 are omitted as trial data.
- **D5 CPH migrations:** include p0_1–p0_4_1 in the canonical chain (recommended: schema only,
  feature-flag gated; excluding them would recreate the ordering problem later). Needs the CPH
  owner to confirm p0_4_1 is final.
- **D6 Attestation key:** provision during the window (recommended) or defer Calculate.
- **D7 Governance exception:** acknowledge moving the five beta-data migrations out of
  `migrations/`.
- **D8 Commit:** authorise committing the canonical chain on a branch before the reset.
