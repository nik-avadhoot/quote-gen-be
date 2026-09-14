#!/usr/bin/env node
// S7-R: fixtures for the trusted executor core (supabase/functions/calculate-batch-row/executor.mjs).
//
// WHAT THIS PROVES. That the JavaScript signer and the PostgreSQL verifier agree
// on the qca/1 bytes - the MAC below is the SAME golden vector the database suite
// asserts (CP-113b), computed independently on each side - and that the real,
// bundled engine produces output the closed v1 results contract accepts.
//
// WHAT IT DOES NOT PROVE. Nothing here runs the Deno Edge runtime, calls
// PostgREST, or touches a database. index.ts is not executed. The key below is the
// fixed TEST VECTOR shared with the database suite (32 bytes of 0xab); it is not,
// and must never become, a provisioned key.
import {
  ExecutorRefusal, attest, buildRates, buildSpec, execute, frame, hmacHex, isoMicros,
  macInput, sha256Hex, toResults,
} from '../supabase/functions/calculate-batch-row/executor.mjs';
import { MANIFEST } from '../supabase/functions/calculate-batch-row/_engine/manifest.js';
import { calcCosting } from '../supabase/functions/calculate-batch-row/_engine/engine/costing.js';

let failed = 0;
const ok = (cond, msg) => { console.log(`${cond ? 'ok   ' : 'not ok'}  ${msg}`); if (!cond) failed++; };
const rejects = async (fn, code, msg) => {
  try { await fn(); ok(false, `${msg} (no refusal)`); }
  catch (e) { ok(e instanceof ExecutorRefusal && e.code === code, `${msg} -> ${e.code ?? e.message}`); }
};

const TEST_KEY = new Uint8Array(32).fill(0xab);
const GOLDEN = {
  keyId: 'k1', authSub: '00000000-0000-4000-8000-000000000001', appUserId: 7, batchId: 11,
  batchRowId: 13, contentVersion: 3, releaseId: 17, engineVersion: 'engine/x',
  calculationFingerprint: 'a'.repeat(64), presentationFingerprint: 'b'.repeat(64),
  resultsSha256: 'c'.repeat(64),
  computedAt: '2026-09-10T00:00:00.000000Z', expiresAt: '2026-09-10T00:01:00.000000Z',
};

console.log('── qca/1: the JavaScript signer and the database verifier agree ──');
ok(await hmacHex(TEST_KEY, macInput(GOLDEN)) === '70828cac95d23e15a4f25c1fc63476511baf03697e8375749e8941fee26aa04b',
  'CP-113b the fourteen-field tuple yields the SAME MAC the database suite hard-codes - one byte contract, two implementations, identical bytes');
ok(await hmacHex(TEST_KEY, macInput({ ...GOLDEN, keyId: 'a', authSub: 'b~c' }))
   !== await hmacHex(TEST_KEY, macInput({ ...GOLDEN, keyId: 'a~b', authSub: 'c' })),
  'CP-113c framing collision: (a, b~c) and (a~b, c) sign differently');
ok(Array.from(frame(new TextEncoder().encode('ab'))).join(',') === '0,0,0,0,0,0,0,2,97,98',
  'frame() is an 8-byte big-endian length then the bytes - app_private.qca_frame exactly');
ok(isoMicros(new Date(Date.UTC(2026, 8, 10, 14, 11, 33, 929))) === '2026-09-10T14:11:33.929000Z',
  'computed_at renders as app_private.qca_ts does, to the microsecond');
ok(await sha256Hex('abc') === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  'SHA-256 of the results text uses the published digest of "abc"');

console.log('\n── the bundled engine, on a five-grade board ──');
const EI = {
  contract_version: 1,
  provenance: { row_type: 'box' },
  resolved: {
    waste: { value: 5, source: 'system' }, conv: { value: 7, source: 'system' },
    margin: { value: 8, source: 'system' }, interest: { value: 0.5, source: 'system' },
    freight: { value: 3.75, source: 'master' },
  },
  entered: {
    length_mm: 400, width_mm: 300, height_mm: 250, ply: 5, box_type: 'RSC', ups: 1,
    flute_f1: null, flute_f2: null,
    layers: {
      TOP: { code: 'K150', gsm: 150 }, F1: { code: 'SF100', gsm: 100 }, L1: { code: 'K120', gsm: 120 },
      F2: { code: 'SF120', gsm: 120 }, L2: { code: 'K200', gsm: 200 },
    },
    fluting_bcf: 0.1,
    add_ons: { printing: 1.25, stitching: 0, coating: 0, handling: 0, moq_charge: 0, packing: 0, other: 0, unloading: 0 },
    sales_moq: null, volume: null, spec_bs: null, spec_bct: null, spec_ect: null,
  },
};
// Five independently governed effective material rates. The differing upstream
// supplier-credit terms are deliberately absent from Calculate's input.
const RATES = [
  { rate_entry_id: 1, grade_code: 'K150', effective_material_rate: 40.6 },
  { rate_entry_id: 2, grade_code: 'SF100', effective_material_rate: 40.8 },
  { rate_entry_id: 3, grade_code: 'K120', effective_material_rate: 40.6 },
  { rate_entry_id: 4, grade_code: 'SF120', effective_material_rate: 40.0 },
  { rate_entry_id: 5, grade_code: 'K200', effective_material_rate: 41.2 },
];

const results = toResults(calcCosting(buildSpec(EI), buildRates(RATES), null, undefined, EI.resolved.freight.value));
const e = results.engine, d = results.row_details;
ok(JSON.stringify(Object.keys(results).sort()) === '["contract_version","engine","row_details"]',
  'results carries exactly contract_version, engine and row_details');
ok(Object.keys(e).length === 20 && Object.values(e).every(Number.isFinite), 'engine carries the 20 contract scalars, all finite');
ok(d.length === 5 && d.map((x) => x.k).join() === 'TOP,F1,L1,F2,L2' && d.every((x) => Object.keys(x).length === 8),
  'CP-117 all five layers are present - five different supplier-credit terms do not stop a board calculating');
ok(new Set(d.map((x) => x.rate)).size > 1, 'each layer carries its own effective material rate from its own governed entry');
ok(!JSON.stringify(RATES).match(/interest|credit|price|discount|freight/),
  'Calculate receives no supplier-credit term or raw Rate Master price component');
const sum = (k) => d.reduce((s, x) => s + x[k], 0);
ok(Math.abs(e.add_ons - 1.25) < 1e-4, 'identity: engine.add_ons equals the sum of entered.add_ons');
ok(Math.abs(e.fr_rate - 3.75) < 1e-4, 'identity: engine.fr_rate equals resolved.freight.value');
ok(Math.abs(e.wt - sum('wt')) < 1e-4 && Math.abs(e.mat - sum('cost')) < 1e-4, 'identity: row_details sum to engine.wt and engine.mat');

const hi = toResults(calcCosting(buildSpec({ ...EI, resolved: { ...EI.resolved, interest: { value: 1, source: 'derived_annual' } } }),
  buildRates(RATES), null, undefined, 3.75));
ok(hi.engine.int_c > e.int_c && JSON.stringify(hi.row_details) === JSON.stringify(d),
  'CP-118 customer interest moves int_c through its own input and leaves every per-layer material rate untouched');

console.log('\n── execute(): the whole signing path ──');
const BINDING = {
  auth_sub: GOLDEN.authSub, app_user_id: 7, batch_id: 11, batch_row_id: 13, content_version: 3,
  pricing_basis_release_id: 17, engine_version: MANIFEST.engine_version,
  calculation_fingerprint: 'a'.repeat(64), presentation_fingerprint: 'b'.repeat(64),
};
const now = new Date(Date.UTC(2026, 8, 10, 0, 0, 0, 0));
const out = await execute({ inputs: { effective_inputs: EI, rates: RATES, binding: BINDING }, keyId: 'k1', keyBytes: TEST_KEY, authSub: GOLDEN.authSub, now });
const parts = out.attestation.split('~');
ok(parts.length === 5 && parts[0] === 'qca/1' && /^[0-9a-f]{64}$/.test(parts[4])
   && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(parts[2]) && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(parts[3]),
  'the envelope matches the shape app_private.qca_parse accepts');
ok((Date.parse(parts[3]) - Date.parse(parts[2])) / 1000 === 60, 'lifetime is 60 seconds, inside the 120-second database ceiling');
ok(parts[4] === await hmacHex(TEST_KEY, macInput({
  keyId: 'k1', authSub: BINDING.auth_sub, appUserId: 7, batchId: 11, batchRowId: 13, contentVersion: 3,
  releaseId: 17, engineVersion: BINDING.engine_version, calculationFingerprint: BINDING.calculation_fingerprint,
  presentationFingerprint: BINDING.presentation_fingerprint, resultsSha256: await sha256Hex(out.resultsText),
  computedAt: parts[2], expiresAt: parts[3],
})), 'the MAC covers the exact results text it was issued with');
ok(out.resultsText !== JSON.stringify(JSON.parse(out.resultsText), null, 1), 'a re-formatted copy of the same JSON is different bytes, so it cannot reuse the MAC');

await rejects(() => execute({ inputs: { effective_inputs: EI, rates: RATES, binding: { ...BINDING, engine_version: 'engine/other' } }, keyId: 'k1', keyBytes: TEST_KEY, authSub: GOLDEN.authSub, now }),
  'ENGINE_VERSION_MISMATCH', 'refuses to sign for a Release naming an engine it is not running');
await rejects(() => execute({ inputs: { effective_inputs: EI, rates: RATES, binding: BINDING }, keyId: 'k1', keyBytes: TEST_KEY, authSub: '00000000-0000-4000-8000-00000000000f', now }),
  'ACTOR_MISMATCH', 'refuses to sign when the binding names a different actor than the caller');
await rejects(() => attest({ keyId: 'k1', keyBytes: new Uint8Array(16), binding: BINDING, resultsText: '{}', computedAt: parts[2], expiresAt: parts[3] }),
  'KEY_INVALID', 'refuses a key that is not 256 bits');
await rejects(() => attest({ keyId: 'K1!', keyBytes: TEST_KEY, binding: BINDING, resultsText: '{}', computedAt: parts[2], expiresAt: parts[3] }),
  'KEY_ID_INVALID', 'refuses a key id outside the keyring charset');

console.log(failed ? `\n${failed} FAILED` : '\nall executor fixtures pass');
process.exit(failed ? 1 : 0);
