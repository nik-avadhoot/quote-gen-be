"""
S5 / S6 HTTP probe matrix - the REST and RPC surface, exercised over real HTTP.

Run:  python tests/http_probe_matrix.py
      python tests/http_probe_matrix.py --json probe-results.json

WHY THIS FILE EXISTS. S5's closure reported "36/36 REST probes refused", which
was true and was the S4 matrix; the S5 clarification then reported "52/52" from
a probe that was never committed. A number nobody can re-derive is not evidence,
and that is the standard this programme applies to everything else. This script
is the probe, in the repository, re-runnable by anyone holding the project's
publishable key, and it prints METHOD, PATH, PERSONA, EXPECTED and OBSERVED for
every single check.

WHAT A "REFUSAL" IS, AND WHY IT IS NOT ONE THING.

  anon                 has no table privilege and no EXECUTE anywhere, so
                       PostgREST refuses before the table is touched: 401, or
                       404 for an RPC it will not route. A 400 is NOT a refusal -
                       it means the request was malformed and authorization was
                       never reached. The S5 clarification found three of its own
                       PATCH probes scoring 400 because the body named a column
                       the table does not have. Every body below names real
                       columns and fills every NOT NULL column that has no
                       default, so nothing here can be rejected for its shape.

  an authenticated     HOLDS the table privilege - `authenticated` is granted
  caller who is not    SELECT and usually INSERT/UPDATE - so the refusal comes
  authorised           from RLS instead, and RLS does not raise on reads. A
                       denied GET is 200 with an EMPTY ARRAY, and a denied PATCH
                       is 200 with zero rows changed. Expecting an error there
                       would be expecting the wrong thing; these checks read the
                       result back, which is the same discipline DS-7, PB-20 and
                       FS-18 follow in the database suites.

THE BASELINE MAKES THE ZEROES MEAN SOMETHING. An empty array proves denial only
if some caller can see a row in that table. The OWNER persona is probed first on
every S6 table and must come back non-empty; only then do the four denied
personas have to come back empty.

PERSONAS. All four are minted by this script and torn down by it. None borrows a
governed identity, and none is an administrator.

  anon           the publishable key alone, no Authorization header
  unprovisioned  a real signed-in user with a valid JWT and NO app_user row -
                 authenticated, and holding no capability at all
  wrong_plant    a Maker at PUN, probing a Batch at NAG
  inactive       a Maker at NAG with every relevant grant, deactivated, still
                 holding the token that was valid a moment earlier
  owner          the baseline: the Maker who owns the fixture Batch at NAG

FIXTURE SAFETY. Every row this script targets with a write is a row this script
created. S5's write probes are anon-only and filter on `id=eq.-1`, so they can
match nothing even in the impossible case that authorization failed. Teardown
runs in a finally block and reports any residue it could not remove.

SERVICE-ROLE USE IS FIXTURE-ONLY. The secret key creates and removes personas
and fixture rows. It is never used to make an authorization assertion, because a
role that bypasses RLS cannot prove anything about RLS.
"""
import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from dotenv import load_dotenv  # noqa: E402

load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))

URL = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
ANON_KEY = os.environ.get("SUPABASE_PUBLISHABLE_KEY") or ""
SECRET_KEY = os.environ.get("SUPABASE_SECRET_KEY") or ""

if not URL or not ANON_KEY or not SECRET_KEY:
    print("SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY and SUPABASE_SECRET_KEY must be set")
    sys.exit(2)

TAG = "p2probe"
PASSWORD = "Pr0be-" + uuid.uuid4().hex[:16] + "!"

RESULTS = []
FAILURES = []


# --------------------------------------------------------------- transport
def http(method, path, token=None, body=None, prefer=None, key=None, attempts=4):
    """One request. Returns (status, text). Never raises for an HTTP status.

    A transport failure is retried, because it is not an answer. Over a matrix
    this size a reset connection or a TLS hiccup will happen, and scoring one as
    a refusal would be the same mistake as scoring a 400 as a refusal: a check
    that passed without the server ever deciding anything.
    """
    url = URL + path
    data = json.dumps(body).encode() if body is not None else None
    last = None
    for attempt in range(attempts):
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("apikey", key or ANON_KEY)
        if token:
            req.add_header("Authorization", "Bearer " + token)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if prefer:
            req.add_header("Prefer", prefer)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception as e:  # network-level only
            last = e
            time.sleep(0.6 * (attempt + 1))
    return 0, "TRANSPORT ERROR after %d attempts: %s" % (attempts, last)


def svc(method, path, body=None, prefer="return=representation"):
    return http(method, path, token=SECRET_KEY, body=body, prefer=prefer, key=SECRET_KEY)


def svc_json(method, path, body=None):
    status, text = svc(method, path, body)
    if status not in (200, 201, 204):
        raise RuntimeError("fixture step failed: %s %s -> %s %s" % (method, path, status, text[:400]))
    try:
        return json.loads(text) if text else []
    except ValueError:
        return []


# --------------------------------------------------------------- reporting
def record(persona, method, path, expected, status, text, ok):
    body = (text or "")[:160].replace("\n", " ")
    RESULTS.append({
        "persona": persona, "method": method, "path": path,
        "expected": expected, "observed": "%s %s" % (status, body), "pass": ok,
    })
    line = "%-13s %-6s %-58s expect %-34s got %s %s" % (
        persona, method, path[:58], expected, status, body[:60])
    if ok:
        print("ok   - " + line)
    else:
        FAILURES.append(line)
        print("FAIL - " + line)


def rows_of(text):
    try:
        v = json.loads(text)
        return v if isinstance(v, list) else None
    except ValueError:
        return None


# ------------------------------------------------------------ expectations
def expect_anon_refused(persona, method, path, body=None):
    """anon holds no privilege, so PostgREST refuses before the table.

    401/403 is the refusal. 404 is a refusal for an RPC it will not route.
    A 400 is explicitly NOT accepted: it means the request never reached
    authorization, which is the exact defect the S5 clarification caught in its
    own probe.
    """
    status, text = http(method, path, body=body, prefer="return=representation")
    ok = status in (401, 403, 404)
    note = "401/403/404"
    if status == 400:
        note += " (400 = malformed, proves nothing)"
    record(persona, method, path, note, status, text, ok)


def expect_service_role_rpc_refused(name, body):
    """
    U1-CF-C1. service_role bypasses RLS (BYPASSRLS) but that is a DIFFERENT
    control from function EXECUTE privilege - this proves the latter directly
    over real HTTP, calling the RPC with the service-role key exactly the way
    `svc()` does for fixture setup, and expects PostgREST to refuse it the
    same way it refuses anon: 401/403/404, never a successful call. A 400 is
    not accepted here either, for the same reason expect_anon_refused
    excludes it - it would mean the request never reached authorization.
    """
    path = "/rest/v1/rpc/" + name
    status, text = http("POST", path, token=SECRET_KEY, body=body, key=SECRET_KEY)
    ok = status in (401, 403, 404)
    note = "401/403/404 (service_role: EXECUTE explicitly revoked, U1-CF-C1)"
    if status == 400:
        note += " (400 = malformed, proves nothing)"
    record("service_role", "POST", path, note, status, text, ok)


def expect_empty_read(persona, token, path):
    status, text = http("GET", path, token=token)
    rows = rows_of(text)
    ok = status == 200 and rows == []
    record(persona, "GET", path, "200 []", status, text, ok)


def expect_nonempty_read(persona, token, path):
    status, text = http("GET", path, token=token)
    rows = rows_of(text)
    ok = status == 200 and isinstance(rows, list) and len(rows) > 0
    record(persona, "GET", path, "200 >=1 row", status, text, ok)


def expect_write_denied(persona, token, method, path, body=None):
    """A denied write is either 401/403 (no privilege / RLS raised on INSERT)
    or 200/204 with zero rows changed (RLS filtered the UPDATE or DELETE and
    said nothing). Both are refusals; a 200 that changed a row is not."""
    status, text = http(method, path, token=token, body=body, prefer="return=representation")
    rows = rows_of(text)
    ok = status in (401, 403, 404) or (status in (200, 204) and rows == [])
    note = "403/401 or 200 []"
    if status == 400:
        note += " (400 = malformed, proves nothing)"
    record(persona, method, path, note, status, text, ok)


def expect_rpc_denied(persona, token, name, body):
    path = "/rest/v1/rpc/" + name
    status, text = http("POST", path, token=token, body=body)
    ok = status in (401, 403, 404)
    note = "401/403/404"
    if status == 400:
        note += " (400 = malformed, proves nothing)"
    record(persona, "POST", path, note, status, text, ok)


# ------------------------------------------------------ the probed surface
S5_TABLES = [
    # payment_interest_map_entries was here until S7-6 retired it. The fixed
    # Payment Terms map is withdrawn (Canonical Amendment 01, A-03): one approved
    # annual rate is the authority and the effective percentage is derived from
    # it, so probing a second one would be probing a table that no longer exists.
    "sectors", "sector_versions", "calculation_default_versions",
    "rate_sets", "rate_set_versions",
    "rate_entries", "freight_sets", "freight_set_versions", "freight_entries",
    "pricing_basis_releases",
]

S6_TABLES = [
    "batches", "batch_collaborators", "batch_profile_versions",
    "batch_edit_locks", "pricing_groups", "delivery_groups", "batch_rows",
    "batch_sets", "batch_set_memberships", "batch_calculations",
]

# One well-formed INSERT body per table. Every NOT NULL column without a default
# is present, and no column is named that the table does not have - so a refusal
# is always an authorization refusal and never a 400 about the request's shape.
# `id` is `generated always as identity` everywhere and is deliberately absent.
INSERT_BODY = {
    "sectors": {"sector_code": "__PROBE", "name": "probe", "created_by": 1},
    "sector_versions": {"sector_id": 1, "version_no": 9901, "margin_pct": 8.0, "created_by": 1},
    "calculation_default_versions": {"version_no": 9901, "engine_version": "probe",
                                     "rounding_rule_version": "probe", "created_by": 1},
    "rate_sets": {"plant_id": 1, "name": "probe", "created_by": 1},
    "rate_set_versions": {"rate_set_id": 1, "plant_id": 1, "version_no": 9901, "created_by": 1},
    "rate_entries": {"rate_set_version_id": 1, "plant_id": 1, "grade_code": "__PROBE",
                     "price": 1.0, "created_by": 1},
    "freight_sets": {"plant_id": 1, "name": "probe", "created_by": 1},
    "freight_set_versions": {"freight_set_id": 1, "plant_id": 1, "version_no": 9901, "created_by": 1},
    "freight_entries": {"freight_set_version_id": 1, "plant_id": 1, "origin_plant_id": 1,
                        "destination_location_id": 1, "rate": 1.0, "created_by": 1},
    "pricing_basis_releases": {"plant_id": 1, "effective_from": "2026-01-01",
                               "rate_set_version_id": 1, "freight_set_version_id": 1,
                               "sector_version_id": 1, "calculation_default_version_id": 1,
                               "proposed_by": 1},
    "batches": {"batch_reference": "__PROBE", "family_id": 1, "plant_id": 1,
                "owner_user_id": 1, "created_by": 1},
    "batch_collaborators": {"batch_id": 1, "app_user_id": 1, "created_by": 1},
    "batch_profile_versions": {"batch_id": 1, "version_no": 9901, "created_by": 1},
    "batch_edit_locks": {"batch_id": 1, "holder_user_id": 1},
    "pricing_groups": {"batch_id": 1, "created_by": 1},
    "delivery_groups": {"pricing_group_id": 1, "batch_id": 1, "created_by": 1},
    "batch_rows": {"batch_id": 1, "plant_id": 1, "pricing_group_id": 1, "sku_id": 1,
                   "sku_version_id": 1, "created_by": 1},
    "batch_sets": {"batch_id": 1, "box_row_id": 1, "set_code": "__PROBE", "created_by": 1},
    "batch_set_memberships": {"set_id": 1, "row_id": 1, "batch_id": 1, "role": "plate",
                              "created_by": 1},
    "batch_calculations": {"batch_row_id": 1, "batch_id": 1, "calculation_fingerprint": "p",
                           "presentation_fingerprint": "p", "engine_version": "probe",
                           "schema_version": 1, "effective_inputs": {}, "results": {}},
}

# One well-formed PATCH body per table, naming a column the table really has.
# This is the half the S5 clarification's own probe got wrong three times.
PATCH_BODY = {
    "sectors": {"name": "probe"},
    "sector_versions": {"spec_lang": "probe"},
    "calculation_default_versions": {"engine_version": "probe"},
    "rate_sets": {"name": "probe"},
    "rate_set_versions": {"status": "draft"},
    "rate_entries": {"description": "probe"},
    "freight_sets": {"name": "probe"},
    "freight_set_versions": {"status": "draft"},
    "freight_entries": {"rate": 1.0},
    "pricing_basis_releases": {"release_name": "probe"},
    "batches": {"status": "working"},
    "batch_collaborators": {"status": "active"},
    "batch_profile_versions": {"waste_cbb_pct": 1.0},
    "batch_edit_locks": {"heartbeat_at": "2026-01-01T00:00:00Z"},
    "pricing_groups": {"label": "probe"},
    "delivery_groups": {"label": "probe"},
    "batch_rows": {"material_code": "probe"},
    "batch_sets": {"set_code": "__PROBE"},
    "batch_set_memberships": {"role": "plate"},
    "batch_calculations": {"engine_version": "probe"},
}

S5_RPCS = {
    "propose_pricing_basis_release": {"p_plant": 1, "p_effective_from": "2026-01-01",
                                      "p_rate_set_version_id": 1, "p_freight_set_version_id": 1,
                                      "p_sector_version_id": 1,
                                      "p_calculation_default_version_id": 1},
    "approve_pricing_basis_release": {"p_release": 1, "p_is_automatic_default": False},
    "withdraw_pricing_basis_release": {"p_release": 1},
}

S6_RPCS = {
    "create_batch": {"p_family": 1, "p_plant": 1},
    "acquire_batch_lock": {"p_batch": 1},
    "heartbeat_batch_lock": {"p_batch": 1},
    "release_batch_lock": {"p_batch": 1},
    "reclaim_batch_lock": {"p_batch": 1, "p_expected_holder": 1},
    "takeover_batch_lock": {"p_batch": 1},
    "revise_batch_profile": {"p_batch": 1, "p_expected_content_version": 1},
}

# U1 Customer Family mutations (post-U1-correction binding decisions) - the ten
# public invoker wrappers added alongside app_private.* CAS-protected
# operations. Every well-formed value here is arbitrary but correctly typed,
# same discipline as S5_RPCS/S6_RPCS above: anon must never reach
# authorization regardless of whether the ids resolve to real rows, so a
# refusal here proves nothing about which ids exist.
U1_FAMILY_B_RPCS = {
    "propose_customer_family": {"p_name": "__probe"},
    "create_minimal_prospect": {"p_display_name": "__probe", "p_family_id": None},
    "update_customer_family": {"p_family": 1, "p_expected_content_version": 1, "p_name": "__probe"},
    "approve_customer_family": {"p_family": 1, "p_expected_content_version": 1},
    "add_family_alias": {"p_family": 1, "p_alias": "__probe"},
    "update_family_alias": {"p_alias_id": 1, "p_expected_content_version": 1, "p_alias": "__probe"},
    "retire_family_alias": {"p_alias_id": 1, "p_expected_content_version": 1},
    "merge_customer_families": {"p_survivor": 1, "p_retired": 2,
                                "p_expected_survivor_version": 1, "p_expected_retired_version": 1},
    "reassign_customer_family": {"p_party": 1, "p_new_family": 1, "p_expected_content_version": 1},
    "graduate_customer_party": {"p_party": 1},
}

# U1 Slice A - Party editing (docs/u1-customer-foundation-authorization-
# packet.md, quote-gen-fe). One new public wrapper.
U1_SLICE_A_RPCS = {
    "update_customer_party": {"p_party": 1, "p_expected_content_version": 1, "p_display_name": "__probe"},
}

# Private implementations and the helper, which must not be routable at all.
UNROUTABLE = [
    ("/rest/v1/rpc/has_any_plant_cap", {"p_cap": "make_quote"}),
    ("/rest/v1/rpc/has_plant_cap", {"p_plant": 1, "p_cap": "make_quote"}),
    ("/rest/v1/rpc/can_read_batch", {"p_batch": 1}),
    ("/rest/v1/rpc/can_write_batch", {"p_batch": 1}),
    ("/rest/v1/rpc/current_app_user", {}),
]


# ------------------------------------------------------------- anon matrix
def anon_matrix(tables, rpcs, label):
    print("\n=== %s: persona anon (publishable key only) ===" % label)
    for t in tables:
        expect_anon_refused("anon", "GET", "/rest/v1/%s?select=id&limit=1" % t)
        expect_anon_refused("anon", "POST", "/rest/v1/%s" % t, INSERT_BODY[t])
        expect_anon_refused("anon", "PATCH", "/rest/v1/%s?id=eq.-1" % t, PATCH_BODY[t])
        expect_anon_refused("anon", "DELETE", "/rest/v1/%s?id=eq.-1" % t)
    for name, body in rpcs.items():
        expect_anon_refused("anon", "POST", "/rest/v1/rpc/%s" % name, body)


def unroutable_matrix():
    print("\n=== the private implementations and helpers must not be routable ===")
    for path, body in UNROUTABLE:
        expect_anon_refused("anon", "POST", path, body)
    # app_private is not an exposed schema; PGRST106 is the proof, and it is
    # returned before any role is assumed (S0a evidence E-1/E-2).
    status, text = http("GET", "/rest/v1/plants?select=id&limit=1", key=ANON_KEY)
    st2, tx2 = http("GET", "/rest/v1/app_users?select=id&limit=1", key=ANON_KEY)
    record("anon", "GET", "/rest/v1/plants (control)", "401/403/404", status, text,
           status in (401, 403, 404))
    record("anon", "GET", "/rest/v1/app_users (control)", "401/403/404", st2, tx2,
           st2 in (401, 403, 404))
    req = urllib.request.Request(URL + "/rest/v1/has_any_plant_cap", method="GET")
    req.add_header("apikey", ANON_KEY)
    req.add_header("Accept-Profile", "app_private")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            st3, tx3 = r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        st3, tx3 = e.code, e.read().decode("utf-8", "replace")
    record("anon", "GET", "app_private via Accept-Profile", "PGRST106 / 4xx", st3, tx3,
           st3 >= 400)


# ------------------------------------------------------------- persona set
def make_auth_user(email):
    body = {"email": email, "password": PASSWORD, "email_confirm": True}
    out = svc_json("POST", "/auth/v1/admin/users", body)
    return out["id"] if isinstance(out, dict) else out[0]["id"]


def sign_in(email):
    status, text = http("POST", "/auth/v1/token?grant_type=password",
                        body={"email": email, "password": PASSWORD})
    if status != 200:
        raise RuntimeError("sign-in failed for %s: %s %s" % (email, status, text[:300]))
    return json.loads(text)["access_token"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", help="write the full per-check record to this file")
    ap.add_argument("--anon-only", action="store_true",
                    help="run only the anon matrices; mint no personas and create no fixtures")
    args = ap.parse_args()

    print("project: %s" % URL)

    anon_matrix(S5_TABLES, S5_RPCS, "S5 surface - Family D and E")
    anon_matrix(S6_TABLES, S6_RPCS, "S6 surface - Family F")
    anon_matrix([], U1_FAMILY_B_RPCS, "U1 surface - Customer Family mutations")
    print("\n=== U1 surface - Customer Family mutations: persona service_role (U1-CF-C1) ===")
    for name, body in U1_FAMILY_B_RPCS.items():
        expect_service_role_rpc_refused(name, body)
    anon_matrix([], U1_SLICE_A_RPCS, "U1 Slice A surface - Party editing")
    print("\n=== U1 Slice A surface - Party editing: persona service_role ===")
    for name, body in U1_SLICE_A_RPCS.items():
        expect_service_role_rpc_refused(name, body)
    unroutable_matrix()

    if not args.anon_only:
        authenticated_matrix()

    print("\n%d checks, %d passed, %d FAILED" % (len(RESULTS), len(RESULTS) - len(FAILURES),
                                                 len(FAILURES)))
    for f in FAILURES:
        print("  FAILED: " + f)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"project": URL, "checks": RESULTS,
                       "total": len(RESULTS), "failed": len(FAILURES)}, fh, indent=2)
        print("wrote %s" % args.json)
    return 1 if FAILURES else 0


def authenticated_matrix():
    """The three denied authenticated personas, against a real fixture Batch."""
    created = {"auth": [], "app_users": [], "batch": None, "family": None}
    emails = {k: "%s-%s-%s@example.invalid" % (TAG, k, uuid.uuid4().hex[:8])
              for k in ("owner", "wrong", "dead", "unprov", "checker")}
    try:
        plants = {p["plant_code"]: p["id"] for p in
                  svc_json("GET", "/rest/v1/plants?select=id,plant_code")}
        caps = {c["capability_key"]: c["id"] for c in
                svc_json("GET", "/rest/v1/capabilities?select=id,capability_key")}

        # --- personas. `unprov` deliberately gets NO app_user row.
        tokens, app_ids = {}, {}
        for k in ("owner", "wrong", "dead", "unprov", "checker"):
            auth_id = make_auth_user(emails[k])
            created["auth"].append(auth_id)
            tokens[k] = sign_in(emails[k])
            if k == "unprov":
                continue
            row = svc_json("POST", "/rest/v1/app_users",
                           {"auth_user_id": auth_id, "display_name": "__%s_%s" % (TAG, k),
                            "status": "active"})[0]
            app_ids[k] = row["id"]
            created["app_users"].append(row["id"])

        def grant(who, plant, keys):
            svc_json("POST", "/rest/v1/plant_capability_grants",
                     [{"app_user_id": app_ids[who], "plant_id": plants[plant],
                       "capability_id": caps[c], "granted_by": app_ids["owner"]} for c in keys])

        grant("owner", "NAG", ["plant_access", "make_quote"])
        grant("wrong", "PUN", ["plant_access", "make_quote"])
        grant("dead", "NAG", ["plant_access", "make_quote"])
        # a second AUTHORISED reclaimer, so the race below is decided by the
        # conditional statement and not by anyone lacking authority
        grant("checker", "NAG", ["plant_access", "check_quote"])

        fam = svc_json("POST", "/rest/v1/customer_families",
                       {"name": "__%s family" % TAG, "status": "active",
                        "created_by": app_ids["owner"]})[0]
        created["family"] = fam["id"]

        # the fixture Batch, created by the OWNER through the real RPC
        status, text = http("POST", "/rest/v1/rpc/create_batch", token=tokens["owner"],
                            body={"p_family": fam["id"], "p_plant": plants["NAG"]})
        if status != 200:
            raise RuntimeError("fixture batch not created: %s %s" % (status, text[:300]))
        batch_id = json.loads(text)
        created["batch"] = batch_id
        print("\nfixture Batch id=%s at NAG, owned by the owner persona" % batch_id)

        # deactivate the `dead` persona AFTER its grants are in place, so the only
        # thing separating it from a capable caller is its status
        # ck_app_users_deactivated pairs the status with its timestamp, so both
        # move together - the constraint refuses a deactivation with no date
        svc_json("PATCH", "/rest/v1/app_users?id=eq.%s" % app_ids["dead"],
                 {"status": "deactivated", "deactivated_at": "2026-09-06T00:00:00Z"})

        # ---------------------------------------------------- the baseline
        print("\n=== S6 surface: persona owner (the baseline every zero is measured against) ===")
        expect_nonempty_read("owner", tokens["owner"],
                             "/rest/v1/batches?select=id&id=eq.%s" % batch_id)
        for t in ("pricing_groups", "delivery_groups", "batch_profile_versions",
                  "batch_edit_locks"):
            expect_nonempty_read("owner", tokens["owner"],
                                 "/rest/v1/%s?select=id&batch_id=eq.%s" % (t, batch_id))

        # ------------------------------------------- the denied personas
        for persona, key in (("unprovisioned", "unprov"), ("wrong_plant", "wrong"),
                             ("inactive", "dead")):
            print("\n=== S6 surface: persona %s ===" % persona)
            tok = tokens[key]
            expect_empty_read(persona, tok, "/rest/v1/batches?select=id&id=eq.%s" % batch_id)
            for t in ("pricing_groups", "delivery_groups", "batch_profile_versions",
                      "batch_edit_locks", "batch_collaborators", "batch_rows",
                      "batch_sets", "batch_set_memberships", "batch_calculations"):
                expect_empty_read(persona, tok,
                                  "/rest/v1/%s?select=id&batch_id=eq.%s" % (t, batch_id))

            # writes against rows that really exist, so an empty result is denial
            expect_write_denied(persona, tok, "PATCH",
                                "/rest/v1/batches?id=eq.%s" % batch_id, {"status": "working"})
            expect_write_denied(persona, tok, "PATCH",
                                "/rest/v1/pricing_groups?batch_id=eq.%s" % batch_id,
                                {"label": "probe"})
            expect_write_denied(persona, tok, "POST", "/rest/v1/pricing_groups",
                                {"batch_id": batch_id, "created_by": 1})
            expect_write_denied(persona, tok, "POST", "/rest/v1/batch_collaborators",
                                {"batch_id": batch_id, "app_user_id": 1, "created_by": 1})
            expect_write_denied(persona, tok, "DELETE",
                                "/rest/v1/batch_rows?batch_id=eq.%s" % batch_id)

            for name, body in S6_RPCS.items():
                b = dict(body)
                for k2 in ("p_batch",):
                    if k2 in b:
                        b[k2] = batch_id
                if name == "create_batch":
                    b = {"p_family": fam["id"], "p_plant": plants["NAG"]}
                expect_rpc_denied(persona, tok, name, b)

        # ------------------------------- the genuine two-session lock race
        # BL-10 replays reclaim SEQUENTIALLY inside one transaction, which proves
        # the conditional statement is not idempotent. It does not prove what
        # §9.1 asks for - "concurrent contenders" - because one database session
        # cannot race itself. Two HTTP clients can.
        print("\n=== the reclaim race, two real sessions, fired together ===")
        svc_json("PATCH", "/rest/v1/batch_edit_locks?batch_id=eq.%s" % batch_id,
                 {"heartbeat_at": "2020-01-01T00:00:00Z"})
        expected_holder = app_ids["owner"]
        barrier = threading.Barrier(2)
        out = {}

        def contend(name, tok):
            barrier.wait()
            out[name] = http("POST", "/rest/v1/rpc/reclaim_batch_lock", token=tok,
                             body={"p_batch": batch_id,
                                   "p_expected_holder": expected_holder}, attempts=1)

        threads = [threading.Thread(target=contend, args=("owner", tokens["owner"])),
                   threading.Thread(target=contend, args=("checker", tokens["checker"]))]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        winners = [k for k, (st, _) in out.items() if st == 200]
        losers = [k for k, (st, _) in out.items() if st != 200]
        record("race", "POST", "/rest/v1/rpc/reclaim_batch_lock x2 concurrent",
               "exactly 1 winner", "%s won / %s lost" % (winners or "none", losers or "none"),
               json.dumps({k: v[0] for k, v in out.items()}), len(winners) == 1)

        loser_body = out[losers[0]][1] if losers else ""
        record("race", "POST", "/rest/v1/rpc/reclaim_batch_lock (loser)",
               "55P03 lock_not_available", out[losers[0]][0] if losers else "-",
               loser_body, "55P03" in loser_body)

        held = svc_json("GET", "/rest/v1/batch_edit_locks?select=holder_user_id&batch_id=eq.%s"
                        % batch_id)
        held_by = held[0]["holder_user_id"] if held else None
        want = app_ids[winners[0]] if len(winners) == 1 else None
        record("race", "GET", "/rest/v1/batch_edit_locks (after the race)",
               "held by the winner", held_by, "winner=%s" % (winners or "none"),
               want is not None and held_by == want)

    finally:
        print("\n=== teardown ===")
        residue = []
        b = created.get("batch")
        if b:
            for path in ("batch_set_memberships?batch_id=eq.%s" % b,
                         "batch_sets?batch_id=eq.%s" % b,
                         "batch_calculations?batch_id=eq.%s" % b,
                         "batch_rows?batch_id=eq.%s" % b,
                         "delivery_groups?batch_id=eq.%s" % b,
                         "pricing_groups?batch_id=eq.%s" % b,
                         "batch_profile_versions?batch_id=eq.%s" % b,
                         "batch_collaborators?batch_id=eq.%s" % b,
                         "batch_edit_locks?batch_id=eq.%s" % b,
                         "batches?id=eq.%s" % b):
                st, tx = svc("DELETE", "/rest/v1/" + path)
                if st not in (200, 204):
                    residue.append("%s -> %s %s" % (path, st, tx[:120]))
        for uid in created["app_users"]:
            svc("DELETE", "/rest/v1/plant_capability_grants?app_user_id=eq.%s" % uid)
            svc("DELETE", "/rest/v1/group_capability_grants?app_user_id=eq.%s" % uid)
        if created.get("family"):
            svc("DELETE", "/rest/v1/customer_families?id=eq.%s" % created["family"])
        for uid in created["app_users"]:
            st, tx = svc("DELETE", "/rest/v1/app_users?id=eq.%s" % uid)
            if st not in (200, 204):
                residue.append("app_users/%s -> %s %s" % (uid, st, tx[:120]))
        for aid in created["auth"]:
            st, tx = svc("DELETE", "/auth/v1/admin/users/%s" % aid)
            if st not in (200, 204):
                residue.append("auth.users/%s -> %s %s" % (aid, st, tx[:120]))
        if residue:
            print("RESIDUE NOT REMOVED - clean this up before trusting the next run:")
            for r in residue:
                print("  " + r)
        else:
            print("clean: every persona, grant and fixture row created by this run was removed")


if __name__ == "__main__":
    sys.exit(main())
