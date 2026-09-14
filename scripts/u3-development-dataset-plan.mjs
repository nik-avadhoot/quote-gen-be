#!/usr/bin/env node

// Read-only manifest for the authorised U3 development dataset.
//
// This file intentionally has no database client and cannot persist or delete
// anything. The separately reviewed u3_development_dataset_executor.py performs
// the authorised one-shot caller-token operation; keeping the manifest inert
// prevents it from ever becoming a silently substituted fixture.

import assert from "node:assert/strict";

const args = new Set(process.argv.slice(2));
const requestedMutation = ["--apply", "--cleanup"].find(flag => args.has(flag));
if (requestedMutation) {
  console.error(`${requestedMutation} refused: this manifest is non-persisting. `
    + "Use u3_development_dataset_executor.py with two genuine caller sessions and the exact authorization guard.");
  process.exit(2);
}

export function buildU3DatasetPlan(datasetNumber = 9301) {
  if (!Number.isInteger(datasetNumber) || datasetNumber < 9000 || datasetNumber > 9999) {
    throw new Error("datasetNumber must be an integer from 9000 to 9999");
  }
  const tag = `__U3_DEV_ONLY_${datasetNumber}__`;
  return Object.freeze({
    mode: "READ_ONLY_MANIFEST_EXECUTOR_SEPARATE",
    dataset_number: datasetNumber,
    dataset_number_policy: "PERMANENTLY_CONSUMED_ONE_SHOT_IDENTIFIER",
    permanent_label: tag,
    prerequisites: [
      "explicit Product Owner authorization naming this dataset number",
      "genuine authenticated proposer and approver personas",
      "one caller-visible Nagpur plant and authority to govern one Customer with exactly two active Ship-to destinations",
      "preflight proving this dataset number has never been used, including retired governed history",
    ],
    identities: {
      rate_set_name: `${tag} RATE SET`,
      freight_set_name: `${tag} FREIGHT SET`,
      sector_code: `U3DEV${datasetNumber}`,
      sector_name: `${tag} SECTOR`,
      calculation_default_version_nos: [9301001, 9301002, 9301003],
      pricing_basis_release_name: `${tag} PRICING BASIS RELEASE`,
    },
    governed_create_sequence: [
      "distinct callers: propose/approve one labelled Customer Family, graduate its permanent Customer identity",
      "distinct callers: propose/approve exactly two labelled Ship-to Locations and allocate their permanent codes",
      "caller Data API: insert labelled Rate Set, draft version and grade entries",
      "caller Data API: insert labelled Freight Set, draft version and explicit-zero lane",
      "caller Data API: insert labelled Sector and draft Sector version",
      "caller Data API: insert reserved-number draft Calculation Default version",
      "authorised approver Data API: approve the four master versions through existing transition guards",
      "public.propose_pricing_basis_release with the permanent development label",
      "public.approve_pricing_basis_release with automatic-default=false",
      "caller-scoped read-back proving labels, component identities and lifecycle",
    ],
    governed_retirement_sequence: [
      "public.withdraw_pricing_basis_release for each approved development Release",
      "authorised approver Data API: approved Rate/Freight versions to withdrawn",
      "authorised approver Data API: approved Sector/Calculation Default versions to superseded",
      "caller Data API: mark the labelled Rate/Freight/Sector identities inactive",
      "read-back proving no development Release remains eligible",
      "owner-level hard cleanup only under separate destructive-operation authority if physical removal is required",
    ],
    invariants: {
      changes_capabilities_rls_grants_or_user_authority: false,
      allocates_quote_or_batch_references: false,
      uses_service_role_workaround: false,
      silently_substitutes_for_live_data: false,
      engine_version: "engine/qe1-7c2ceac1972460ba",
      calculation_default_labelling: "reserved deterministic version number plus labelled Release manifest",
      governed_retirement_preserves_audit_history: true,
      dataset_number_reusable_after_retirement: false,
      rerun_rule: "choose a new unused dataset number; never repair or reuse a retired number",
    },
  });
}

const plan = buildU3DatasetPlan();

if (args.has("--self-test")) {
  assert.equal(plan.mode, "READ_ONLY_MANIFEST_EXECUTOR_SEPARATE");
  assert.match(plan.permanent_label, /^__U3_DEV_ONLY_\d{4}__$/);
  assert.equal(plan.invariants.changes_capabilities_rls_grants_or_user_authority, false);
  assert.equal(plan.invariants.allocates_quote_or_batch_references, false);
  assert.equal(plan.invariants.silently_substitutes_for_live_data, false);
  assert.equal(plan.invariants.engine_version, "engine/qe1-7c2ceac1972460ba");
  assert.equal(plan.dataset_number_policy, "PERMANENTLY_CONSUMED_ONE_SHOT_IDENTIFIER");
  assert.equal(plan.invariants.dataset_number_reusable_after_retirement, false);
  assert.ok(plan.governed_retirement_sequence.some(step => step.includes("withdraw_pricing_basis_release")));
  console.log("u3 development dataset preparation PASS (9 assertions, zero writes)");
} else {
  console.log(JSON.stringify(plan, null, 2));
}
