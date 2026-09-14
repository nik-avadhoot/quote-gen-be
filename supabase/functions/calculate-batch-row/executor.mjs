// S7-R trusted executor - the part of the calculate-batch-row Edge Function that
// runs the governed engine and signs its output. Runtime-agnostic: the Deno
// function (index.ts) and the Node fixtures (scripts/executor-fixtures.mjs) import
// this same module, so what the tests exercise is what the function runs.
//
// WHAT IT DOES, AND WHAT IT DELIBERATELY DOES NOT.
//   * It runs calcCosting - the bundled, byte-identical engine - over inputs the
//     DATABASE assembled (calculate_inputs). It never accepts inputs from the
//     browser, so there is nothing for a caller to describe.
//   * It signs the exact UTF-8 bytes of the results text under qca/1, binding the
//     actor, the row, its version, the Release, the engine, both fingerprints and
//     the computation time. The database rebuilds every one of those itself.
//   * It never asserts an actor on anyone's behalf. It refuses to sign when the
//     database-issued binding names a different Auth subject than the caller.
//   * It receives only governed effective material rates. Supplier-credit
//     terms and raw Rate Master price components never cross this boundary.
//   * The key is used and discarded. It is never logged, returned or placed in
//     an error.
import { calcCosting } from './_engine/engine/costing.js';
import { MANIFEST } from './_engine/manifest.js';

// Well inside the database's 120-second ceiling on attestation lifetime.
export const ATTESTATION_LIFETIME_SECONDS = 60;

const KEYID_RE = /^[a-z0-9][a-z0-9_-]{0,62}$/;
const LAYERS = ['TOP', 'F1', 'L1', 'F2', 'L2'];
const ROW_TYPE = { box: 'Box', plate: 'Plate', part_l: 'Part-L', part_w: 'Part-W', other: 'Other' };

// results.engine key -> calcCosting return key. The contract is snake_case; the
// engine is camelCase; this table is the single place the two meet.
const ENGINE_KEYS = [
  ['deckle', 'deckle'], ['cutting', 'cutting'], ['area', 'area'], ['wt', 'wt'],
  ['wt_sheet', 'wtSheet'], ['mat', 'mat'], ['conv', 'conv'], ['fr', 'fr'],
  ['add_ons', 'addOns'], ['int_c', 'intC'], ['total', 'total'], ['final_rate', 'finalRate'],
  ['margin_amt', 'marginAmt'], ['moq_kg', 'moqKg'], ['estimated_box_wt', 'estimatedBoxWt'],
  ['calc_moq', 'calcMOQ'], ['calc_bs', 'calcBS'], ['calc_gsm', 'calcGSM'],
  ['rate_per_kg', 'ratePerKg'], ['fr_rate', 'frRate'],
];

export class ExecutorRefusal extends Error {
  constructor(code) { super(code); this.code = code; }
}

const enc = new TextEncoder();
const hex = (buf) => Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
const finite = (v) => typeof v === 'number' && Number.isFinite(v);

// ── engine inputs, from the database-assembled effective_inputs ─────────────
export function buildSpec(ei) {
  const e = ei.entered, r = ei.resolved, a = e.add_ons;
  const layers = {};
  for (const k of LAYERS) {
    const l = e.layers?.[k] ?? {};
    layers[k] = { code: l.code ?? '', gsm: l.gsm ?? '' };
  }
  return {
    L: e.length_mm, W: e.width_mm, H: e.height_mm ?? '', ply: e.ply, boxType: e.box_type, ups: e.ups,
    layers, flute_F1: e.flute_f1 ?? null, flute_F2: e.flute_f2 ?? null,
    // The database already resolved the Box|PP arm, so both arms carry its one answer.
    waste: r.waste.value, wastePP: r.waste.value,
    convRate: r.conv.value, convRatePP: r.conv.value,
    margin: r.margin.value,
    // Customer payment-term interest: its own resolved chain, never supplier credit.
    interest: r.interest.value,
    printing: a.printing, stitching: a.stitching, coating: a.coating, handling: a.handling,
    moqCharge: a.moq_charge, packing: a.packing, other: a.other, unloading: a.unloading,
    flutingBCF: e.fluting_bcf,
    rowType: ROW_TYPE[ei.provenance?.row_type] ?? 'Box',
  };
}

// Governed effective material rates, reshaped to the engine's field names.
// There is deliberately no price component or supplier-credit term to select,
// default or recalculate here.
export function buildRates(rates) {
  return (rates ?? []).map((x) => ({
    code: x.grade_code, effectiveRate: x.effective_material_rate,
  }));
}

// ── engine output, to the closed v1 results contract ────────────────────────
export function toResults(res) {
  if (!res) throw new ExecutorRefusal('ENGINE_NO_RESULT');
  const engine = {};
  for (const [key, src] of ENGINE_KEYS) {
    if (!finite(res[src])) throw new ExecutorRefusal('ENGINE_NON_FINITE');
    engine[key] = res[src];
  }
  if (!Array.isArray(res.rowDetails) || res.rowDetails.length !== 5) throw new ExecutorRefusal('ENGINE_ROW_DETAILS');
  const row_details = res.rowDetails.map((d, i) => {
    if (d.k !== LAYERS[i]) throw new ExecutorRefusal('ENGINE_ROW_DETAILS');
    const out = d.code
      ? { k: d.k, wt: d.wt, ws: d.ws, cost: d.cost, rate: d.rate, code: d.code, gsm: d.gsm, tu: d.tu }
      : { k: d.k, wt: d.wt, cost: d.cost, rate: d.rate };
    for (const [key, v] of Object.entries(out)) {
      if (key !== 'k' && key !== 'code' && !finite(v)) throw new ExecutorRefusal('ENGINE_NON_FINITE');
    }
    return out;
  });
  return { contract_version: 1, engine, row_details };
}

// ── qca/1 ───────────────────────────────────────────────────────────────────
// frame(b) = 8-byte big-endian length || b. Identical to app_private.qca_frame.
export function frame(bytes) {
  const out = new Uint8Array(8 + bytes.length);
  new DataView(out.buffer).setBigUint64(0, BigInt(bytes.length), false);
  out.set(bytes, 8);
  return out;
}

// The fourteen fields, in contract order. Identical to app_private.qca_mac_input.
export function macInput(f) {
  const parts = [
    'qca/1', f.keyId, f.authSub, String(f.appUserId), String(f.batchId), String(f.batchRowId),
    String(f.contentVersion), String(f.releaseId), f.engineVersion.normalize('NFC'),
    f.calculationFingerprint, f.presentationFingerprint, f.resultsSha256, f.computedAt, f.expiresAt,
  ].map((p) => frame(enc.encode(p)));
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

// YYYY-MM-DDTHH:MM:SS.ffffffZ, as app_private.qca_ts renders it. JavaScript
// clocks are millisecond-resolution, so the last three digits are always 000.
export const isoMicros = (d) => d.toISOString().replace(/\.(\d{3})Z$/, '.$1000Z');

export async function sha256Hex(text) {
  return hex(await crypto.subtle.digest('SHA-256', enc.encode(text)));
}

export async function hmacHex(keyBytes, data) {
  const key = await crypto.subtle.importKey('raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', key, data));
}

export async function attest({ keyId, keyBytes, binding, resultsText, computedAt, expiresAt }) {
  if (!KEYID_RE.test(keyId ?? '')) throw new ExecutorRefusal('KEY_ID_INVALID');
  if (!(keyBytes instanceof Uint8Array) || keyBytes.length !== 32) throw new ExecutorRefusal('KEY_INVALID');
  const mac = await hmacHex(keyBytes, macInput({
    keyId,
    authSub: binding.auth_sub,
    appUserId: binding.app_user_id,
    batchId: binding.batch_id,
    batchRowId: binding.batch_row_id,
    contentVersion: binding.content_version,
    releaseId: binding.pricing_basis_release_id,
    engineVersion: binding.engine_version,
    calculationFingerprint: binding.calculation_fingerprint,
    presentationFingerprint: binding.presentation_fingerprint,
    resultsSha256: await sha256Hex(resultsText),
    computedAt,
    expiresAt,
  }));
  return `qca/1~${keyId}~${computedAt}~${expiresAt}~${mac}`;
}

// One trusted calculation. `inputs` is exactly what public.calculate_inputs
// returned to THIS caller; `authSub` is the subject of the caller's verified JWT.
export async function execute({ inputs, keyId, keyBytes, authSub, now = new Date() }) {
  const b = inputs?.binding, ei = inputs?.effective_inputs;
  if (!b || !ei) throw new ExecutorRefusal('INPUTS_MALFORMED');
  if (b.engine_version !== MANIFEST.engine_version) throw new ExecutorRefusal('ENGINE_VERSION_MISMATCH');
  if (b.auth_sub !== authSub) throw new ExecutorRefusal('ACTOR_MISMATCH');

  const res = calcCosting(buildSpec(ei), buildRates(inputs.rates), null, undefined, ei.resolved.freight.value);
  const resultsText = JSON.stringify(toResults(res));
  const computedAt = isoMicros(now);
  const expiresAt = isoMicros(new Date(now.getTime() + ATTESTATION_LIFETIME_SECONDS * 1000));
  const attestation = await attest({ keyId, keyBytes, binding: b, resultsText, computedAt, expiresAt });
  return { resultsText, attestation, contentVersion: b.content_version };
}
