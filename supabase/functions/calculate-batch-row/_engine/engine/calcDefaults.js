// ═══════════════════════════════════════════════════════════════════════════
// src/engine/calcDefaults.js
//
// The application's mirror of ONE approved `calculation_default_versions` row
// (Family D, S5-1). Pure data, no side effects, no React.
//
// WHY THIS FILE EXISTS AT ALL. The frontend has no Supabase client - every call
// goes through the Flask backend, and the backend exposes no route for any
// commercial master. So the resolver cannot read the versioned defaults from the
// database yet. It reads them from here instead, and here is a single named
// object rather than literals scattered across five call sites.
//
// It is a MIRROR, not a second authority. Every value below reproduces the
// column default the database already carries, so establishing this object moves
// no number (the A-21 discipline). When U3 delivers the Commercial Masters
// screens, this object is replaced by the resolved Pricing Basis Release and
// `versionLabel` becomes a real `calculation_default_version_id`. Until then it
// is the honest statement of what the app is actually using.
//
// ═══════════════════════════════════════════════════════════════════════════
export const CALC_DEFAULTS = {
  // Provenance. A real id once the Pricing Basis Release is resolvable.
  versionLabel: 'app-mirror/amendment-01',

  // ── customer credit-period interest (CDM-18, Amendment 01 A-01/A-02) ──
  // The single approved annual authority. The effective percentage is DERIVED;
  // there is no stored per-term map any more.
  annualInterestPct: 6.0,
  // 360 and only 360 (A-02). Carried so a snapshot records the basis it was
  // derived under, not so it can be configured.
  dayCountBasis: 360,
  // Independent fallback for an unresolved structured Payment Term. 0.5, and
  // never 1.5 - it is not the top of the old map and is not derived from the
  // annual rate.
  interestFallbackPct: 0.5,

  // ── CDM-19 system fallbacks, the last tier of each inheritance chain ──
  wasteCbbFallbackPct: 5,
  wastePpFallbackPct: 5,
  convBoxFallbackRate: 7,    // Rs/kg, NOT a percentage
  convPpFallbackRate: 12.5,  // Rs/kg
  marginFallbackPct: 8,

  // ── engine constants that Send has to freeze with the rest (CDM-22) ──
  roundingStep: 0.05,
};
