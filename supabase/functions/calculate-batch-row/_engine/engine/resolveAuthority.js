// ═══════════════════════════════════════════════════════════════════════════
// src/engine/resolveAuthority.js
//
// THE ONE CalcGate resolver (S7 / D-25). Pure JavaScript, zero React, zero I/O,
// so the goldens can execute it without a renderer.
//
// It exists because two surfaces answered the same question differently:
//
//   Costing        state/useCostingResult.js   batch ?? sector ?? literal
//   Batch Entry    state/useQuoteActions.js    row   ?? batch  ?? literal
//
// - the gate that actually produces a Quote had no Sector tier at all, so a
// Batch with a blank profile field costed one way on screen and another way at
// Send. Both now call this.
//
// WHAT IT RETURNS, AND WHY IT IS NOT JUST A NUMBER.
//
//     { value, source, sourceRef, ...inputs }
//
// CDM-22 requires Send to freeze "effective values and sources, selected
// versions". A resolver that returned only the number would make that
// impossible after the fact, and for Interest it would be worse than
// impossible: the effective percentage is now DERIVED from an approved annual
// rate, so once that rate is superseded the number cannot be re-derived from
// anything the snapshot holds unless the snapshot also holds the rate, the
// basis and the days. Those come back in the result.
//
// BLANK, ZERO AND UNRESOLVED ARE THREE STATES.
//
//   null / undefined / '' / non-numeric   →  INHERIT, advance the chain
//   0                                     →  a value the user chose, STOP
//   nothing left in the chain             →  unresolved
//
// Every tier test goes through isBlank(). Never truthiness, never `||`, never
// `+x > 0`. The blank test deliberately mirrors `nz()` in costing.js - including
// treating a non-numeric string as blank - so adopting the resolver moves no
// number that the engine was already computing.
//
// ONE TIER IS PRESENT BUT CURRENTLY INERT, AND THAT IS DELIBERATE.
//
//   sector.marginPct        sector_versions.margin_pct is NOT NULL in the
//                           database, but the browser-local Sector master
//                           (data/defaults.js) carries no margin column at all.
//                           The tier is wired so the chain matches CDM-19; it
//                           resolves blank today and therefore changes no price.
//                           It starts carrying values when U3 delivers Sectors
//                           from the database, and that will be a visible,
//                           reviewed change - not a silent one now.
// This is not a guess about the future: it is the canonical chain written down
// once, so the day the data arrives nobody has to find the call sites.
// ═══════════════════════════════════════════════════════════════════════════
import { CALC_DEFAULTS } from './calcDefaults.js';
import { deriveInterestPct } from './interestBasis.js';

/**
 * Blank means inherit. Mirrors `nz()` in costing.js exactly, so the resolver and
 * the engine agree on what "not set" means. A legitimate 0 is NOT blank.
 */
export const isBlank = (v) =>
  v === null || v === undefined || v === '' || isNaN(+v);

const hit = (value, source, sourceRef = null, extra = null) =>
  ({ value: +value, source, sourceRef, ...(extra || {}) });

const UNRESOLVED = { value: null, source: 'unresolved', sourceRef: null };

// Which profile / sector keys a field reads, by row type. `isPP` is the
// Plate/Part-L/Part-W switch the engine already makes; the PP arm is not an
// edge case, it is half the model (CDM-19).
const FIELDS = {
  waste: {
    profile: (pp) => (pp ? 'wastePP' : 'waste'),
    sector:  (pp) => (pp ? 'wastePP' : 'wasteCBB'),
    system:  (pp) => (pp ? 'wastePpFallbackPct' : 'wasteCbbFallbackPct'),
  },
  convRate: {
    profile: (pp) => (pp ? 'convRatePP' : 'convRate'),
    sector:  (pp) => (pp ? 'convPP' : 'convBox'),
    system:  (pp) => (pp ? 'convPpFallbackRate' : 'convBoxFallbackRate'),
  },
  margin: {
    // CDM-19: Batch Box/PP defaults are separate tiers; the Sector keeps ONE
    // approved target margin for both.
    profile: (pp) => (pp ? 'marginPP' : 'margin'),
    sector:  () => 'marginPct',
    system:  () => 'marginFallbackPct',
  },
};

/**
 * Resolve one inheritable field.
 *
 * @param {'waste'|'convRate'|'margin'} field
 * @param {object} ctx
 *   rowOverride  the row's override for this field (blank = inherit)
 *   batchProfile the Batch Profile version
 *   sector       the Sector version
 *   calcDefaults the approved Calculation Defaults version
 *   isPP         Plate / Part-L / Part-W row
 */
export function resolveField(field, ctx = {}) {
  const spec = FIELDS[field];
  if (!spec) throw new Error(`resolveField: unknown field "${field}"`);

  const { rowOverride, batchProfile, sector, isPP = false } = ctx;
  const defaults = ctx.calcDefaults || CALC_DEFAULTS;

  if (!isBlank(rowOverride)) return hit(rowOverride, 'row');

  const pKey = spec.profile(isPP);
  if (batchProfile && !isBlank(batchProfile[pKey])) {
    return hit(batchProfile[pKey], 'batch', batchProfile.versionId ?? null);
  }

  const sKey = spec.sector(isPP);
  if (sector && !isBlank(sector[sKey])) {
    return hit(sector[sKey], 'sector', sector.versionId ?? sector.code ?? null);
  }

  const dKey = spec.system(isPP);
  if (defaults && !isBlank(defaults[dKey])) {
    return hit(defaults[dKey], 'system', defaults.versionLabel ?? null);
  }

  return { ...UNRESOLVED };
}

// Resolve the six Batch Profile commercial defaults once for consumers that
// render or persist both Box and PP values. Keeping this beside resolveField
// prevents Batch Builder placeholders and Send from reintroducing literal
// fallbacks that skip the selected Sector tier.
export function resolveBatchCommercialDefaults(batchProfile, sector, calcDefaults) {
  const value=(field,isPP)=>resolveField(field,{
    rowOverride:'',batchProfile,sector,calcDefaults,isPP,
  }).value;
  return {
    waste:value('waste',false),convRate:value('convRate',false),margin:value('margin',false),
    wastePP:value('waste',true),convRatePP:value('convRate',true),marginPP:value('margin',true),
  };
}

/**
 * Resolve customer Payment-Terms Interest (CDM-18, Amendment 01 A-01 to A-04).
 *
 *   explicit Pricing Group override
 *     → derived from the approved annual rate
 *       → versioned system fallback
 *
 * The derived tier is the one that replaced a stored map. It returns the three
 * inputs alongside the value because a derived number is not self-evidencing.
 */
export function resolveInterest(ctx = {}) {
  const { pricingGroup } = ctx;
  const defaults = ctx.calcDefaults || CALC_DEFAULTS;
  const days = pricingGroup ? pricingGroup.paymentTermsDays : null;

  // Tier 1 - the retained commercial escape hatch. An explicit 0 lands here and
  // means "no interest charged", which is a decision, not a blank.
  if (pricingGroup && !isBlank(pricingGroup.interestOverridePct)) {
    return hit(pricingGroup.interestOverridePct, 'pricing_group', pricingGroup.id ?? null, {
      paymentTermsDays: isBlank(days) ? null : +days,
      annualInterestPct: defaults.annualInterestPct,
      dayCountBasis: defaults.dayCountBasis,
      overrideReason: pricingGroup.interestOverrideReason ?? null,
    });
  }

  // Tier 2 - the derivation. Null when the term is not one the model calculates
  // from; null is "unresolved", never zero.
  const derived = deriveInterestPct(
    defaults.annualInterestPct, days, defaults.dayCountBasis);
  if (derived !== null) {
    return hit(derived, 'derived_annual', defaults.versionLabel ?? null, {
      paymentTermsDays: +days,
      annualInterestPct: defaults.annualInterestPct,
      dayCountBasis: defaults.dayCountBasis,
    });
  }

  // Tier 3 - the INDEPENDENT fallback. 0.5, and never 1.5. It is not the top of
  // the withdrawn map and is not derived from the annual rate.
  if (!isBlank(defaults.interestFallbackPct)) {
    return hit(defaults.interestFallbackPct, 'system', defaults.versionLabel ?? null, {
      paymentTermsDays: isBlank(days) ? null : +days,
      annualInterestPct: defaults.annualInterestPct,
      dayCountBasis: defaults.dayCountBasis,
    });
  }

  return { ...UNRESOLVED };
}

/**
 * Every inheritable value for one row, in one call, with provenance for each.
 * This is the shape Send freezes (CDM-22) and the shape both surfaces consume,
 * so Costing and Batch Entry cannot drift apart again.
 */
export function resolveRowAuthority(ctx = {}) {
  const { isPP = false } = ctx;
  const shared = {
    batchProfile: ctx.batchProfile,
    sector: ctx.sector,
    calcDefaults: ctx.calcDefaults,
    isPP,
  };
  return {
    waste:    resolveField('waste',    { ...shared, rowOverride: ctx.rowWaste }),
    convRate: resolveField('convRate', { ...shared, rowOverride: ctx.rowConv }),
    margin:   resolveField('margin',   { ...shared, rowOverride: ctx.rowMargin }),
    interest: resolveInterest({ pricingGroup: ctx.pricingGroup, calcDefaults: ctx.calcDefaults }),
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// S8(a) — FREIGHT AUTHORITY (CDM-17)
//
// The one chain of the five that terminates in BLOCK rather than a fallback.
// Two live defects made that impossible (engine/costing.js:30-33, pre-S8):
//
//   `if(override&&+override>0)`   an explicit ZERO override was discarded
//   `matrix?.[p]?.[d] || 0`       a MISSING pair returned 0, so "no rate on
//                                 file" and "the rate is zero" were one value
//
// THE AUTHORIZED CHAIN. Two tiers are explicitly TEMPORARY and say so in their
// own provenance, because the app cannot yet reach the governed sources:
//
//   canonical row override           'row'            governed
//     legacy Batch Profile override  'legacy_batch'   TEMPORARY  → removed U4
//       Pricing Group  manual        'pricing_group'  governed   (terminates)
//                      ex_factory    'pricing_group'  governed   (terminates, 0)
//                      master        delegates to the tier below via its BASIS
//         approved Freight Master    'master'         governed
//           legacy plant×dest matrix 'legacy_matrix'  TEMPORARY  → removed U3
//             unresolved             'unresolved'     → blocks
//
// WHY row BEATS legacy_batch. Neither has a live writer today (WAVE 3 removed
// every per-row freight producer), so the order moves no number now. It decides
// what happens at U4, when the row override gains one: the tier the Maker can
// see and edit must beat the batch-level value they did not touch.
//
// WHY 'master' AND 'legacy_matrix' ARE NOT THE SAME TIER. DEFAULT_FREIGHT is an
// application mirror keyed by plant NAME. The governed master is freight_entries
// keyed by (freight_set_version_id, origin_plant_id, destination_location_id),
// reached through the Pricing Group's freight-basis Delivery Group. Returning
// 'master' for the mirror would let a snapshot record a temporary label as an
// approved Freight Set version. `authority` is the field that makes that
// mistake impossible for a downstream writer to make by omission.
//
// THE BASIS IS NEVER SUBSTITUTED. In `master` mode the destination is the basis
// Delivery Group's ship-to Location, resolved UPSTREAM and handed in as
// approvedMasterRate. There is no code path here in which the Batch Profile's
// legacy destination stands in for it: `legacyDestination` is read by the
// legacy_matrix tier and by nothing else.
// ═══════════════════════════════════════════════════════════════════════════

/** Provenance shape for the governed approved-master tier. BOTH ids must be
 *  present: incomplete governed provenance is treated as UNAVAILABLE and takes
 *  the authorized compatibility path, because half a reference is not a
 *  reference and must never be snapshotted as one. */
const isCompleteMasterRef = (ref) =>
  !!ref && !isBlank(ref.freightSetVersionId) && !isBlank(ref.freightEntryId);

const freightHit = (value, source, authority, sourceRef, extra = null) => ({
  value: +value, source, authority, sourceRef,
  mode: null, degradedFrom: null, reason: null, ...(extra || {}),
});

/**
 * Resolve the single freight value entering calculation (CDM-17).
 *
 * Pure: plain data in, plain data out. No callbacks, no environment, no I/O.
 * `authorityV2` is a plain boolean injected by the application boundary - this
 * module must stay importable into plain Node or the goldens cannot run it.
 *
 * @returns {{value:number|null, source:string, authority:'governed'|'temporary'|null,
 *            sourceRef:(string|number|{freightSetVersionId:number,freightEntryId:number}|null),
 *            mode:string|null, degradedFrom:string|null, reason:string|null}}
 */
export function resolveFreight(ctx = {}) {
  const {
    rowOverride, rowRef = null,
    legacyBatchOverride, legacyBatchRef = null,
    pricingGroup = null,
    approvedMasterRate, approvedMasterRef = null, approvedMasterUnavailable = null,
    legacyMatrix = null, legacyMatrixRef = null,
    originPlant, legacyDestination,
  } = ctx;

  // ── 1. canonical row override (governed) ────────────────────────────────
  if (!isBlank(rowOverride)) return freightHit(rowOverride, 'row', 'governed', rowRef);

  // ── 2. legacy Batch Profile override (TEMPORARY, removed at U4) ──────────
  if (!isBlank(legacyBatchOverride))
    return freightHit(legacyBatchOverride, 'legacy_batch', 'temporary', legacyBatchRef);

  // ── 3. Pricing Group. manual and ex_factory TERMINATE here; master
  //       delegates downward through its governed basis. ───────────────────
  let degradedFrom = approvedMasterUnavailable;
  if (pricingGroup) {
    const pgRef = pricingGroup.id ?? null;
    if (pricingGroup.mode === 'ex_factory')
      return freightHit(0, 'pricing_group', 'governed', pgRef, { mode: 'ex_factory' });
    if (pricingGroup.mode === 'manual') {
      // ck_pg_manual_value forbids this in the database; defended anyway,
      // because an unenforced client object is not the database.
      if (isBlank(pricingGroup.manualValue))
        return { value: null, source: 'unresolved', authority: null, sourceRef: null,
                 mode: 'manual', degradedFrom: null, reason: 'manual_value_missing' };
      return freightHit(pricingGroup.manualValue, 'pricing_group', 'governed', pgRef,
        { mode: 'manual' });
    }
    if (pricingGroup.mode === 'master' && isBlank(pricingGroup.basisDeliveryGroupId))
      degradedFrom = degradedFrom || 'basis_missing';
  } else {
    degradedFrom = degradedFrom || 'no_pricing_group';
  }

  // ── 4. approved Freight Master (governed). Incomplete provenance is
  //       UNAVAILABLE, never a governed hit with half a reference. ─────────
  if (!isBlank(approvedMasterRate)) {
    if (isCompleteMasterRef(approvedMasterRef))
      return freightHit(approvedMasterRate, 'master', 'governed', {
        freightSetVersionId: approvedMasterRef.freightSetVersionId,
        freightEntryId: approvedMasterRef.freightEntryId,
      }, { mode: pricingGroup?.mode ?? 'master' });
    degradedFrom = 'no_approved_pair';
  } else {
    degradedFrom = degradedFrom || 'no_approved_pair';
  }

  // ── 5. legacy plant x destination matrix (TEMPORARY, removed at U3).
  //       The `||0` is gone: a miss is `undefined` and falls through. ───────
  const legacyRate = legacyMatrix?.[originPlant]?.[legacyDestination];
  if (!isBlank(legacyRate))
    return freightHit(legacyRate, 'legacy_matrix', 'temporary', legacyMatrixRef, { degradedFrom });

  // ── 6. unresolved. Blocks. Never 0, never undefined, never NaN. ─────────
  return { value: null, source: 'unresolved', authority: null, sourceRef: null,
           mode: pricingGroup?.mode ?? null, degradedFrom,
           reason: legacyMatrix ? 'no_legacy_pair' : 'no_approved_pair' };
}

/**
 * Normalise what a Batch Profile freight input produced into what the profile
 * STORES. Producer-side companion to resolveFreight, and pure so the rule has a
 * callable surface the goldens can hold to account.
 *
 * Blank is the ONLY inheritance signal. Every other entry is a value the user
 * deliberately typed and is stored as a number - including 0, and including a
 * number that happens to equal today's matrix rate.
 *
 * WHAT THIS REPLACED, AND WHY IT MATTERED. The handler used to compute
 * `isManual = v!=='' && +v!==_matrixFr` and store '' when the typed value
 * equalled the matrix. The number stayed right and the AUTHORITY was lost:
 * an override of 2 and an inherited 2 became the same stored state, so a later
 * change to the Freight Master moved the value the user had deliberately
 * pinned. Equal numbers from different tiers are not interchangeable - which is
 * exactly what S8(a) made visible, and therefore no longer dismissable.
 */
export const normalizeFreightOverrideInput = (raw) =>
  (raw === '' || raw === null || raw === undefined) ? '' : +raw;
