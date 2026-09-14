// ═══════════════════════════════════════════════════════════════════════════
// src/engine/interestBasis.js
//
// Customer Payment-Terms Interest, derived from one approved annual rate.
// Pure JavaScript, zero React, zero I/O.
//
// Canonical Amendment 01, A-01 to A-03 (Product Owner, 2026-09-06):
//
//     effective_interest_pct = annual_interest_pct × payment_terms_days ÷ 360
//
// THIS REPLACES A STORED MAP, AND CHANGES NO NUMBER. At the approved rate of
// 6.000% per annum the derivation reproduces every previously approved value
// exactly - 30→0.5, 45→0.75, 60→1.0, 90→1.5 - because those four values were
// already a straight line at 6% on a 360-day year. A 365-day year reproduces
// none of them, which is why 360 is the convention and why passing any other
// basis THROWS rather than quietly computing something else.
//
// WHY IT THROWS INSTEAD OF FALLING BACK. A wrong day-count basis is not a
// missing input to be defaulted; it is a value nobody approved. Falling back to
// 360 would compute a number the caller did not ask for and hide the mistake,
// which is the same failure class as `0 || 5` silently discarding a legitimate
// zero. The database refuses it with a CHECK constraint; this refuses it with an
// exception, so the two layers agree.
//
// ROUNDING. To three decimals, matching numeric(7,3) - the precision the
// database actually stores - so the app's derived value and a value read back
// from a snapshot are the same number rather than two that nearly agree.
// ═══════════════════════════════════════════════════════════════════════════

/** The only approved day-count convention (A-02). */
export const APPROVED_DAY_COUNT_BASIS = 360;

/** The closed list of structured calculating Payment Terms (CDM-18, A-03). */
export const STRUCTURED_PAYMENT_TERMS = Object.freeze([30, 45, 60, 90]);

/** numeric(7,3): three decimals, and the same rounding on both sides. */
const round3 = (n) => Math.round(n * 1000) / 1000;

/**
 * Is this a Payment Terms value the model will calculate from?
 * Anything else - blank, null, 35 days, or free text like "against delivery" -
 * is descriptive only and does not calculate.
 */
export const isStructuredPaymentTerm = (days) =>
  days !== null && days !== undefined && days !== '' &&
  STRUCTURED_PAYMENT_TERMS.includes(+days);

/**
 * Derive the effective interest percentage for a credit period.
 *
 * Returns `null` when the Payment Term is not one the model calculates from -
 * the caller then falls to the versioned system fallback. `null` here means
 * "unresolved", never "zero"; the two are different states and the resolver
 * keeps them apart.
 *
 * @throws if `basis` is anything other than the approved 360.
 */
export function deriveInterestPct(annualPct, days, basis = APPROVED_DAY_COUNT_BASIS) {
  if (basis !== APPROVED_DAY_COUNT_BASIS) {
    throw new Error(
      `day-count basis ${basis} is not approved - 360 is the only permitted convention ` +
      `(Canonical Amendment 01, A-02)`);
  }
  if (!isStructuredPaymentTerm(days)) return null;
  if (annualPct === null || annualPct === undefined || annualPct === '' || isNaN(+annualPct)) {
    return null;
  }
  return round3(+annualPct * +days / basis);
}
