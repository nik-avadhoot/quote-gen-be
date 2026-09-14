// S7-R: calculate-batch-row - the trusted executor, as a Supabase Edge Function.
//
// NOT DEPLOYED, AND HOLDS NO KEY IN THIS REPOSITORY. Deployment and secret
// provisioning await Product Owner authority. The function reads its signing key
// from the Edge secret configuration (QCA_KEY_ID, QCA_KEY_HEX) and answers 503
// until both exist.
//
// THE FLOW, AND WHY EACH STEP RUNS AS THE CALLER.
//   1. The platform verifies the caller's JWT before this code runs (verify_jwt
//      stays on). The same bearer token is forwarded to PostgREST on both calls,
//      so auth.uid() inside the database is the real caller and can_write_batch
//      needs no actor parameter. No service-role key is used anywhere.
//   2. public.calculate_inputs - the database checks authority and Calculate
//      eligibility, then assembles effective_inputs, the binding and the Rate
//      Master rows. The browser supplies nothing but a row id.
//   3. executor.mjs runs the bundled, byte-identical engine and signs the exact
//      results text under qca/1.
//   4. public.calculate_batch_row - the database rebuilds all fourteen fields
//      itself, verifies the MAC over the exact bytes, then parses and stores.
//
// A direct PostgREST caller can reach step 4 without this function, and gets
// 'attestation_invalid': it has no key. That is the design, not a gap.
import { execute, ExecutorRefusal } from './executor.mjs';

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

function hexToBytes(h: string): Uint8Array {
  if (!/^[0-9a-f]{64}$/.test(h)) throw new ExecutorRefusal('KEY_INVALID');
  return Uint8Array.from(h.match(/../g)!, (b) => parseInt(b, 16));
}

// The subject of an already platform-verified JWT. Read only to bind it; the
// database derives the subject again from the same token and will refuse any
// attestation bound to a different one.
function jwtSubject(token: string): string | null {
  try {
    const b64 = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(b64.padEnd(b64.length + ((4 - (b64.length % 4)) % 4), '='))).sub ?? null;
  } catch {
    return null;
  }
}

// PostgREST's refusal passes through with its own status and code. Nothing in it
// can carry key material: the database never places the key or MAC in an error.
async function passThrough(r: Response) {
  const body = await r.json().catch(() => ({}));
  return json(r.status, { error_code: body?.code ?? 'UPSTREAM_ERROR', error: body?.message ?? null });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error_code: 'METHOD_NOT_ALLOWED' });

  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.startsWith('Bearer ')) return json(401, { error_code: 'AUTH_REQUIRED' });
  const authSub = jwtSubject(auth.slice(7));
  if (!authSub) return json(401, { error_code: 'AUTH_REQUIRED' });

  const body = await req.json().catch(() => null);
  const rowId = Number(body?.batch_row_id);
  if (!Number.isSafeInteger(rowId) || rowId <= 0) return json(400, { error_code: 'BATCH_ROW_ID_REQUIRED' });

  const url = Deno.env.get('SUPABASE_URL');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  const keyId = Deno.env.get('QCA_KEY_ID');
  const keyHex = Deno.env.get('QCA_KEY_HEX');
  if (!url || !anon || !keyId || !keyHex) return json(503, { error_code: 'EXECUTOR_NOT_PROVISIONED' });

  const rpc = (name: string, args: Record<string, unknown>) =>
    fetch(`${url}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: { apikey: anon, Authorization: auth, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });

  const r1 = await rpc('calculate_inputs', { p_batch_row_id: rowId });
  if (!r1.ok) return passThrough(r1);
  const inputs = await r1.json();

  let out;
  try {
    out = await execute({ inputs, keyId, keyBytes: hexToBytes(keyHex), authSub, now: new Date() });
  } catch (e) {
    if (e instanceof ExecutorRefusal) return json(409, { error_code: e.code });
    return json(500, { error_code: 'EXECUTOR_ERROR' });
  }

  const r2 = await rpc('calculate_batch_row', {
    p_batch_row_id: rowId,
    p_expected_content_version: out.contentVersion,
    p_results_text: out.resultsText,
    p_attestation: out.attestation,
  });
  if (!r2.ok) return passThrough(r2);
  return json(200, { batch_calculation_id: await r2.json() });
});
