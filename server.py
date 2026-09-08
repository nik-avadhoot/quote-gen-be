"""
CFB Quotation Master — Export Server  (v2.0)
============================================
Stateless Flask API. Its only job is to fill the Excel master template
(CFB_Quotation_Master_v7.xlsx) with quote data posted by the frontend and
return the workbook as a download.

Local development:
    Terminal 1:  python server.py          →  http://localhost:3001
    Terminal 2:  npm run dev               →  http://localhost:5173

Required packages (run once):
    pip install -r requirements.txt

Environment:
    CORS_ORIGINS  Comma-separated list of allowed browser origins.
                  Defaults to the local Vite dev server when unset.

Template:
    CFB_Quotation_Master_v7.xlsx must sit in the SAME folder as this file.
"""

# ═══════════════════════════════════════════════════════════════════════════════
# IMPORTS
# All libraries this server needs. If any are missing, run:
#   pip install -r requirements.txt
# ═══════════════════════════════════════════════════════════════════════════════
import hashlib
import os
import io
import re
import secrets
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

# Resolved relative to this file, not the process's working directory, so
# local dev finds quote-gen-be/.env no matter where the server is launched
# from (e.g. `python quote-gen-be/server.py` from the repo root). Runs before
# caller_context/auth are imported, since their env lookups need this done
# first. override=False (the default) means an already-set process/Vercel
# env var always wins — .env is only the local fallback.
load_dotenv(Path(__file__).resolve().parent / ".env")

from flask import Flask, request, send_file, jsonify, g
from flask_cors import CORS
from postgrest.exceptions import APIError
import openpyxl

from caller_context import (
    TIMING_ENABLED,
    new_caller_client,
    UPSTREAM_TIMEOUT_SECONDS,
    timed,
    bootstrap_caller,
    get_supabase_anon,
    get_supabase_for_caller,
    privileged_client,
    resolve_caller,
    update_caller_email,
    verify_current_password,
)
from auth import require_auth, require_group_capability, require_role


# ═══════════════════════════════════════════════════════════════════════════════
# APP SETUP
# Must be defined BEFORE any @app.route decorators
# ═══════════════════════════════════════════════════════════════════════════════
app = Flask(__name__)

# Allowed browser origins. In production set CORS_ORIGINS to the deployed
# frontend URL(s), comma-separated. Falls back to the local Vite dev server.
DEFAULT_ORIGINS = ",".join([
    "https://quote-gen-fe.vercel.app",   # production frontend
    "http://localhost:5173",             # Vite dev server
    "http://127.0.0.1:5173",
])
CORS_ORIGINS = [
    o.strip()
    for o in os.environ.get("CORS_ORIGINS", DEFAULT_ORIGINS).split(",")
    if o.strip()
]
CORS(app, origins=CORS_ORIGINS, allow_headers=["Content-Type", "Authorization"])


# D1 - whole-request timing, so the phase numbers can be reconciled against the
# wall clock rather than assumed to account for it. Off unless QOS_TIMING is set.
if TIMING_ENABLED:
    import time as _t
    from flask import request as _rq

    @app.before_request
    def _qos_t0():
        g._qos_t0 = _t.perf_counter()

    @app.after_request
    def _qos_t1(resp):
        t0 = getattr(g, "_qos_t0", None)
        if t0 is not None:
            app.logger.warning("TIMING %-28s %8.1f ms  [%s %s -> %s]",
                               "request.total", (_t.perf_counter() - t0) * 1000,
                               _rq.method, _rq.path, resp.status_code)
        return resp


# Path to the Excel master template — must sit beside this file
TEMPLATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "CFB_Quotation_Master_v7.xlsx")


# ═══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

def num(v, default=0):
    """
    Safe numeric conversion.
    Returns `default` only when the value is truly missing (None or "").
    Returns 0 if the value exists but is not a valid number.
    """
    if v is None or v == "":
        return default
    try:
        return float(v)
    except (ValueError, TypeError):
        return default


def first_set(*vals):
    """
    Mirrors JavaScript's `??` chain: returns the first value that is not None.

    NOT the same as falsy-coalescing, and the difference is load-bearing here.
    `??` falls through on null/undefined ONLY - it does NOT skip "" or 0. A blank
    string is a real value and stops the chain; num()/_nv() then map it to the
    default. Using `or` (Python's falsy coalesce) would skip "" AND skip a
    legitimate 0, and several sectors set wastePP/convRatePP to 0.

    Exists so the chains below can mirror export/excel.js operator-for-operator.
    See the porting hazard recorded in the register against D-27.
    """
    return next((v for v in vals if v is not None), None)


def set_val(ws, addr, val):
    """Set a worksheet cell value, preserving its existing style."""
    ws[addr].value = val


def clear_row(ws, r, cols):
    """Blank out all data-input columns in a given row."""
    for col in cols:
        ws[f"{col}{r}"].value = None


# ═══════════════════════════════════════════════════════════════════════════════
# ROUTE: /health  — quick check that the server and template are ready
# ═══════════════════════════════════════════════════════════════════════════════

@app.route("/health", methods=["GET"])
def health():
    """
    Frontend calls this on load to confirm the server is running, the Excel
    template file is present, and Supabase is reachable.
    Returns: { ok: true, template: true/false, supabase: true/false }
    """
    try:
        get_supabase_anon()
        supabase_ok = True
    except Exception:
        supabase_ok = False

    return jsonify({
        "ok":       True,
        "template": os.path.exists(TEMPLATE_PATH),
        "path":     TEMPLATE_PATH,
        "supabase": supabase_ok,
    })


# ═══════════════════════════════════════════════════════════════════════════════
# ROUTE: /export  — fill the Excel master template and send it to the browser
# ═══════════════════════════════════════════════════════════════════════════════

@app.route("/export", methods=["POST"])
@require_auth
def export_xlsx():
    """
    Receives the complete quote data from the frontend, fills the Excel
    master template (CFB_Quotation_Master_v7.xlsx), and returns the file
    as a download.
    """
    if not os.path.exists(TEMPLATE_PATH):
        return jsonify({"error": f"Template not found: {TEMPLATE_PATH}"}), 404

    data       = request.get_json(force=True)
    items      = data.get("items",   [])
    rates      = data.get("rates",   [])
    freight    = data.get("freight", {})
    fname      = data.get("filename", "CFB_Quote.xlsx")
    # Fix 9: read meta fields sent by the frontend
    quote_ref       = data.get("quoteRef",      "")
    maker_name      = data.get("makerName",     "")
    quote_date_str  = data.get("quoteDate",     "")
    effective_from  = data.get("effectiveFrom", "")
    effective_to    = data.get("effectiveTo",   "")

    wb     = openpyxl.load_workbook(TEMPLATE_PATH)
    ws_cbb = wb["CBB+PP"]
    ws_rm  = wb["RATE MASTER"]
    ws_def = wb["DEFAULTS"]

    # ── Update RATE MASTER ────────────────────────────────────────────────────
    for row in range(7, 30):
        code_cell = ws_rm.cell(row, 1)
        if not code_cell.value:
            continue
        code     = str(code_cell.value).strip()
        app_rate = next((r for r in rates if r.get("code") == code), None)
        if app_rate:
            ws_rm.cell(row, 3).value = num(app_rate.get("price"))
            ws_rm.cell(row, 5).value = num(app_rate.get("disc"),    1.5)
            ws_rm.cell(row, 6).value = num(app_rate.get("freight"), 0)

    # ── Update DEFAULTS freight matrix ────────────────────────────────────────
    # A4 (ruling): template reserves S14:S18 for custom delivery locations (5 rows).
    # The VLOOKUP in BK7 covers S4:S18. Rows below S18 are outside the lookup range
    # and would cause BK7 to return #N/A → IFERROR → 0.
    # Strategy:
    #   1. Update rates for locations already present in S4:S13 (standard locations).
    #   2. Write new locations (present in freight dict, absent from column S) into
    #      S14:S18 only. Raise an explicit server error if more than 5 new locations
    #      would be needed — do not silently drop or overwrite template structure.
    PLANT_COL     = {"Kolkata": 20, "Nagpur": 21, "Pune": 22}  # T=20, U=21, V=22
    LOC_COL       = 19   # Column S
    STD_ROW_RANGE = range(4, 14)   # S4:S13 — pre-printed standard locations
    CUSTOM_ROWS   = list(range(14, 19))  # S14:S18 — 5 reserved custom slots

    # Collect every delivery location the in-app freight state knows about
    all_locs = set()
    for plant_dict in freight.values():
        all_locs.update(plant_dict.keys())

    # Read existing location → row mapping from the template (S4:S18)
    existing_loc_rows = {}
    for row_idx in range(4, 19):
        cell_val = ws_def.cell(row_idx, LOC_COL).value
        if cell_val:
            existing_loc_rows[str(cell_val).strip()] = row_idx

    # Identify new locations not yet in column S
    new_locs = sorted(loc for loc in all_locs if loc not in existing_loc_rows)

    # Find which custom rows (S14:S18) are already occupied
    used_custom = {r for r in CUSTOM_ROWS if ws_def.cell(r, LOC_COL).value}
    free_custom  = [r for r in CUSTOM_ROWS if r not in used_custom]

    if len(new_locs) > len(free_custom):
        # Explicit error rather than silent drop — operator must expand the template
        overflow = new_locs[len(free_custom):]
        return jsonify({"error":
            f"Template freight-matrix overflow: {len(new_locs)} new locations need "
            f"{len(new_locs) - len(free_custom)} more reserved rows than S14:S18 provides. "
            f"Cannot write: {overflow}. Expand the DEFAULTS sheet and update PLANT_COL, "
            f"then re-export."}), 422

    # Assign new locations to free custom rows
    for loc, row_idx in zip(new_locs, free_custom):
        ws_def.cell(row_idx, LOC_COL).value = loc
        existing_loc_rows[loc] = row_idx

    # Write freight rates for every known location
    for loc, row_idx in existing_loc_rows.items():
        for plant, col_idx in PLANT_COL.items():
            plant_freight = freight.get(plant, {})
            if loc in plant_freight:
                ws_def.cell(row_idx, col_idx).value = num(plant_freight[loc])

    # ── CBB+PP header ─────────────────────────────────────────────────────────
    f0 = items[0]["spec"] if items else {}

    ws_cbb["D2"] = f0.get("client",   "")
    ws_cbb["B2"] = f0.get("delivery", "")
    ws_cbb["B3"] = f0.get("plant",    "Nagpur")
    ws_cbb["D3"] = f0.get("sector",   "")
    # Fix 9: write Quote Date (B4) from meta, fallback to today; Quote Ref to D4
    try:
        ws_cbb["B4"] = datetime.strptime(quote_date_str, "%Y-%m-%d") if quote_date_str else datetime.now()
    except ValueError:
        ws_cbb["B4"] = datetime.now()
    mat_codes = ", ".join(i["spec"].get("material_code", "") for i in items if i["spec"].get("material_code"))
    ws_cbb["D4"] = (f"{quote_ref} | {mat_codes}") if quote_ref else mat_codes

    # Rate parameters
    interest = num(f0.get("interest"),   0.5)
    margin   = num(f0.get("margin"),     8)
    waste    = num(f0.get("waste"),      5)
    conv_box = num(f0.get("convRate"),   7)

    # D-18: BJ3/BJ4 are TWO slots the template offers, not one. Every data row
    # computes IF(B7="Box",$BJ$3,$BJ$4), so BJ4 governs every Plate/Partition
    # row. Both were written with the BOX row's interest, so PP rows were costed
    # at the Box row's rate whenever the two differed.
    #
    # ⚠️ D-27 CORRECTS THIS COMMENT. It used to claim the siblings "already
    # take proper pairs — conv_box/conv_pp, waste/waste_pp, margin/margin_pp", so
    # that interest was the ONE narrowed parameter. That was FALSE for waste and
    # conv, and the false claim is what stopped the defect being found with D-18.
    #
    # They took a pair of SLOTS but filled the PP slot from f0, the BOX row.
    # useQuoteActions.js A1-02 writes a row-level override only to sp.wastePP /
    # sp.convRatePP ON THE PP ROW ITSELF; a Box row's wastePP is never assigned
    # one. So the PP slot held the profile default UNCONDITIONALLY — not merely
    # when the two disagreed. Not the wrong row sometimes: a field that never
    # carries an override.
    #
    # Only MARGIN was a genuine pair. Both exporters read the payload-level
    # marginPP, and the template gives margin a per-row column (BM6 "Margin %")
    # which waste, conv and interest deliberately do not have.
    #
    # ⚠️ THIS FILE AND quote-gen-fe/src/export/excel.js FILL THE SAME TEMPLATE
    # AND MUST NOT DRIFT (§6 rule 3). excel.js uses `_ppSpec.interest ?? f0.interest`
    # via the first PP item; this is the same lookup, and num()/_nv() share their
    # fallback semantics — default only on None/undefined/"". Change one, change
    # both, or a quote costs differently depending on whether the backend was
    # reachable.
    pp_spec = next((i["spec"] for i in items
                    if (i["spec"].get("rowType") or "Box") in ("Plate", "Part-L", "Part-W")), {})
    interest_pp = num(pp_spec.get("interest"), interest)
    # D-27: waste_pp/conv_pp derive from the SAME pp_spec, mirroring
    # export/excel.js:265,267 operator-for-operator. first_set() reproduces `??`
    # exactly — fall through on None only, never on "" — because num() and _nv()
    # both map "" to the default and `or` would additionally swallow a real 0.
    waste_pp = num(first_set(pp_spec.get("wastePP"), pp_spec.get("waste"),
                             f0.get("wastePP"), f0.get("waste")), 5)
    conv_pp  = num(first_set(pp_spec.get("convRatePP"),
                             f0.get("convRatePP")), 12.5)

    ws_cbb["BA3"] = conv_box
    ws_cbb["BA4"] = conv_pp
    ws_cbb["AY3"] = waste    / 100
    ws_cbb["AY4"] = waste_pp / 100
    ws_cbb["BJ3"] = interest    / 100
    ws_cbb["BJ4"] = interest_pp / 100

    # Freight override (blank = use VLOOKUP matrix)
    freight_override = f0.get("freightOverride", "")
    ws_cbb["BK4"] = (num(freight_override)
                     if freight_override not in ("", None) else None)

    # Box vs PP margin
    margin_pp = num(data.get("marginPP", margin), margin)
    ws_cbb["BM3"] = margin    / 100
    ws_cbb["BM4"] = margin_pp / 100

    # Add-ons defaults (row 3 = Box, row 4 = Board/PP)
    rs4 = next(
        (i["spec"] for i in items
         if not i["spec"].get("rowType") or i["spec"].get("rowType") == "Box"),
        f0
    )
    for col, key in [
        ("BB", "printing"), ("BC", "stitching"), ("BD", "coating"),
        ("BE", "handling"), ("BF", "moqCharge"), ("BG", "packing"),
        ("BH", "other"),    ("BI", "unloading"),
    ]:
        ws_cbb[f"{col}3"] = num(rs4.get(key, 0))
        ws_cbb[f"{col}4"] = 0   # Board/PP default

    # ── Data rows 7+ ──────────────────────────────────────────────────────────
    # B5-SERVER-04: Named constants for template row range.
    # DATA_START_ROW: first data row in the CBB+PP sheet (rows 1-6 are headers).
    # DATA_MAX_ROWS: maximum SKU rows the v7 template supports before stale data risk.
    DATA_START_ROW = 7
    DATA_MAX_ROWS  = 44   # template clears rows 7–50 (44 data rows); row 51+ untouched
    DATA_END_ROW   = DATA_START_ROW + DATA_MAX_ROWS   # 51 — first row NOT cleared

    if len(items) > DATA_MAX_ROWS:
        print(f"  ⚠  WARNING: Batch has {len(items)} items but template capacity is "
              f"{DATA_MAX_ROWS} rows. Rows beyond row {DATA_END_ROW - 1} will NOT be "
              f"cleared and may contain stale data from a previous export. "
              f"Consider splitting the quote into multiple exports.")

    DATA_COLS = [
        "B","C","D","E","F","G","H","I","J","K",
        "S","U","W","X","Y","Z",
        "BR","BS",                          # BR = SET Code, BS = Nos/Set (verified v7)
        # NOTE: column T = Calc GSM formula — never clear or overwrite it
        "AB","AC","AD","AE","AF","AG","AH","AI","AJ","AK","AL","AM",
        "BB","BC","BD","BE","BF","BG","BH","BI",
    ]

    for idx, item in enumerate(items):
        r        = DATA_START_ROW + idx
        s        = item["spec"]
        row_type = s.get("rowType", "Box") or "Box"
        is_rs4   = row_type == "Box"

        ws_cbb[f"B{r}"] = row_type
        ws_cbb[f"C{r}"] = s.get("material_code", "")
        ws_cbb[f"D{r}"] = s.get("product", "")
        ws_cbb[f"E{r}"] = s.get("delivery", f0.get("delivery", ""))
        ws_cbb[f"I{r}"] = s.get("boxType", "RSC")
        ws_cbb[f"J{r}"] = int(num(s.get("ply", 5)))
        ws_cbb[f"K{r}"] = int(num(s.get("ups", 1)))

        # Issue 3 fix: write effective L/W/H for ALL row types directly.
        # For PP rows, s["L"] and s["W"] already hold resolved effective values
        # (set by autoCalcPPDims in sendAllToQuoteItems). H blank for flat pieces.
        ws_cbb[f"F{r}"] = num(s.get("L")) or None
        ws_cbb[f"G{r}"] = num(s.get("W")) or None
        ws_cbb[f"H{r}"] = None if not is_rs4 else (num(s.get("H")) or None)

        # Nos/Set — column BS (verified v7). Required for SET rate accumulation in Excel.
        ws_cbb[f"BS{r}"] = int(num(s.get("qtyPerSet"), 1) or 1)
        # SET Code — column BR.
        ws_cbb[f"BR{r}"] = s.get("setCode", "") or None
        ws_cbb[f"S{r}"]  = num(s.get("board_gsm")) or None
        ws_cbb[f"U{r}"]  = num(s.get("spec_bs"))   or None
        ws_cbb[f"W{r}"]  = num(s.get("spec_bct"))  or None
        ws_cbb[f"X{r}"]  = num(s.get("spec_ect"))  or None
        ws_cbb[f"Y{r}"]  = num(s.get("spec_cobb")) or None
        ws_cbb[f"Z{r}"]  = num(s.get("reqBoxWt"))  or None
        ws_cbb[f"AB{r}"] = s.get("flute_F1") or None
        ws_cbb[f"AC{r}"] = s.get("flute_F2") or None

        layers = s.get("layers", {})
        for cell_col, layer_key, sub_key in [
            ("AD", "TOP", "code"), ("AE", "TOP", "gsm"),
            ("AF", "F1",  "code"), ("AG", "F1",  "gsm"),
            ("AH", "L1",  "code"), ("AI", "L1",  "gsm"),
            ("AJ", "F2",  "code"), ("AK", "F2",  "gsm"),
            ("AL", "L2",  "code"), ("AM", "L2",  "gsm"),
        ]:
            raw = layers.get(layer_key, {}).get(sub_key, "")
            if sub_key == "gsm":
                ws_cbb[f"{cell_col}{r}"] = num(raw) or None
            else:
                ws_cbb[f"{cell_col}{r}"] = str(raw) if raw else None

        ws_cbb[f"BB{r}"] = num(s.get("printing",  0))
        ws_cbb[f"BC{r}"] = num(s.get("stitching", 0))
        ws_cbb[f"BD{r}"] = num(s.get("coating",   0))
        ws_cbb[f"BE{r}"] = num(s.get("handling",  0))
        ws_cbb[f"BF{r}"] = num(s.get("moqCharge", 0))
        ws_cbb[f"BG{r}"] = num(s.get("packing",   0))
        ws_cbb[f"BH{r}"] = num(s.get("other",     0))
        ws_cbb[f"BI{r}"] = num(s.get("unloading", 0))

        is_pp_row      = row_type in ("Plate", "Part-L", "Part-W")
        default_margin = margin_pp if is_pp_row else margin
        item_margin    = num(s.get("margin"), default_margin)

        if abs(item_margin - default_margin) > 0.001:
            ws_cbb[f"BM{r}"] = item_margin / 100
        elif is_pp_row:
            ws_cbb[f"BM{r}"] = "=$BM$4"

    # ── Clear remaining sample rows ───────────────────────────────────────────
    for r in range(DATA_START_ROW + len(items), DATA_END_ROW):
        for col in DATA_COLS:
            cell = ws_cbb[f"{col}{r}"]
            if cell.value not in (None, 0, ""):
                cell.value = None

    # ── Save and return ───────────────────────────────────────────────────────
    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)

    return send_file(
        buf,
        download_name=fname,
        as_attachment=True,
        mimetype=(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        ),
    )


# ═══════════════════════════════════════════════════════════════════════════════
# ROUTES: /auth/*  — login / refresh / logout for the frontend.
# The frontend never talks to Supabase directly; these are its only path to
# an authenticated session.
# ═══════════════════════════════════════════════════════════════════════════════

def _identity_or_none(access_token, auth_uid=None):
    """
    Resolve the caller's application identity using THEIR OWN token, through RLS.

    Replaces the previous service-role read of `profiles`. That read bypassed RLS,
    so identity resolution was the one place the database was not the authority.
    Returns None for an unrecognised or deactivated identity - the caller cannot
    tell which, deliberately.

    `auth_uid` MUST be passed wherever it is known. Without it resolve_caller
    falls back to `.limit(2)` over every row the caller can SEE - and an
    administrator sees EVERYONE. With three or more users those two rows need
    not include the administrator's own, so `me` resolves to None and a valid
    session is refused as "Account is not active".

    That hazard is named in caller_context.resolve_caller and was fixed for the
    require_auth path by passing the verified uid; the /auth/login and
    /auth/refresh paths were left resolving blind. Both have the uid in hand
    from the Auth response, so both now pass it. Found when a third user was
    created during UA-1/UA-4 acceptance and the administrator's next token
    refresh logged them out.
    """
    try:
        return resolve_caller(access_token, known_auth_uid=auth_uid)
    except Exception:
        return None


@app.route("/auth/login", methods=["POST"])
def auth_login():
    data = request.get_json(force=True) or {}
    email = (data.get("email") or "").strip()
    password = data.get("password") or ""
    if not email or not password:
        return jsonify({"error": "Email and password are required"}), 400

    # Build the client OUTSIDE the credential try/except below. get_supabase_anon()
    # raises RuntimeError when SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY are
    # missing; caught alongside a genuine auth failure it surfaced as "Invalid
    # email or password", which sends you looking at the user record instead of
    # the deployment. A config fault must never be reportable as bad credentials.
    try:
        supabase = get_supabase_anon()
    except RuntimeError as exc:
        app.logger.error("Supabase client unavailable: %s", exc)
        return jsonify({"error": "Auth backend is not configured"}), 500

    try:
        auth_resp = supabase.auth.sign_in_with_password(
            {"email": email, "password": password}
        )
    except Exception:
        return jsonify({"error": "Invalid email or password"}), 401

    session, user = auth_resp.session, auth_resp.user
    if not session or not user:
        return jsonify({"error": "Invalid email or password"}), 401

    # Identity is resolved with the token just issued, so RLS decides. The uid is
    # passed so an administrator resolves their OWN row rather than two arbitrary
    # visible ones.
    profile = _identity_or_none(session.access_token, str(user.id))

    # FIRST SIGN-IN. Authenticating proves who you are; it does not create an
    # application identity. An invited user - including the very first
    # administrator, who by definition cannot have been created by an existing
    # administrator - authenticates successfully and resolves to nothing.
    #
    # Before this, that was a permanent 403: the invitation could only be
    # claimed by app_private.bootstrap_app_user(), which PostgREST cannot route
    # to, so the documented recovery did not exist in the running application.
    #
    # One attempt, with the caller's own token, only when they resolved to
    # nothing. The database decides entirely - see bootstrap_caller(). We
    # re-resolve afterwards and trust only that, never the RPC's own answer:
    # bootstrap returns an existing id for a DEACTIVATED user too, and that user
    # must still be refused. Re-resolving is also what makes a concurrent first
    # login safe - the caller that loses the race for the invitation resolves
    # the identity the winner just created, and uk_app_users_auth makes a second
    # identity impossible regardless.
    if not profile:
        bootstrap_caller(session.access_token)
        profile = _identity_or_none(session.access_token, str(user.id))

    # One refusal for every cause - no account, no invitation, wrong email,
    # deactivated. The caller must not be able to tell which.
    if not profile:
        return jsonify({"error": "Account is not active"}), 403

    return jsonify({
        "access_token": session.access_token,
        "refresh_token": session.refresh_token,
        "expires_at": session.expires_at,
        "profile": {**profile, "email": user.email},
    })


@app.route("/auth/refresh", methods=["POST"])
def auth_refresh():
    data = request.get_json(force=True) or {}
    refresh_token = data.get("refresh_token")
    if not refresh_token:
        return jsonify({"error": "refresh_token is required"}), 400

    try:
        auth_resp = get_supabase_anon().auth.refresh_session(refresh_token)
    except Exception:
        return jsonify({"error": "Invalid or expired refresh token"}), 401

    session, user = auth_resp.session, auth_resp.user
    if not session or not user:
        return jsonify({"error": "Invalid or expired refresh token"}), 401

    # Refresh deliberately does NOT bootstrap. It follows an identity that was
    # already established; there is no first sign-in to complete here. A session
    # that refreshes into nothing is a deactivated or removed user, and the only
    # correct answer is to refuse. Attempting a bootstrap on this path would let
    # a long-lived refresh token silently re-enter the system on any invitation
    # that happened to match, which is not a login the user just authenticated.
    profile = _identity_or_none(session.access_token, str(user.id))
    if not profile:
        return jsonify({"error": "Account is not active"}), 403

    return jsonify({
        "access_token": session.access_token,
        "refresh_token": session.refresh_token,
        "expires_at": session.expires_at,
        "profile": {**profile, "email": user.email},
    })


def _auth_ref(auth_user_id):
    """
    A short, non-reversible reference to an authentication account.

    Used anywhere an identifier would otherwise reach a log. It is enough to
    match a log line against the corresponding row in the orphan report, and
    useless for anything else: it is a truncated SHA-256 with no way back to the
    uuid, let alone to an address.
    """
    if not auth_user_id:
        return "unknown"
    return hashlib.sha256(str(auth_user_id).encode()).hexdigest()[:8]


EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$")


def _valid_email(value):
    return bool(value) and len(value) <= 254 and EMAIL_RE.match(value) is not None


@app.route("/auth/me/email", methods=["POST"])
@require_auth
def change_my_email():
    """
    Self-service login-email change.

    Email is the Supabase Auth login identity. It is not stored in `app_users`
    and is not copied there by this route - the application identity, its audit
    history, its plant grants and its capabilities are all keyed on the immutable
    app_users row and are untouched by an address change.

    The current password is re-verified immediately before the change. A valid
    access token only proves the session authenticated at some point; changing
    the login identity is precisely where that is not good enough.

    The change itself is Supabase's own `updateUser({ email })` flow, made with
    the caller's token. With Secure email change enabled the project confirms
    with both addresses and the change lands only when confirmed, so this
    reports PENDING rather than claiming success.
    """
    data = request.get_json(force=True) or {}
    new_email = (data.get("new_email") or "").strip().lower()
    password  = data.get("current_password") or ""

    if not _valid_email(new_email):
        return jsonify({"error": "Enter a valid email address"}), 400
    if not password:
        return jsonify({"error": "Your current password is required"}), 400

    current_email = (g.current_user or {}).get("email")
    if not current_email:
        return jsonify({"error": "Could not start the email change"}), 400
    if new_email == current_email.strip().lower():
        return jsonify({"error": "That is already your email address"}), 400

    if not verify_current_password(current_email, password):
        # Deliberately not "wrong password" vs "account locked" etc.
        return jsonify({"error": "Your current password is incorrect"}), 401

    try:
        result = update_caller_email(g.access_token, new_email)
    except Exception:
        # Never reveal whether the address already belongs to another account.
        # Duplicate, rate-limited and rejected-address all answer the same way.
        app.logger.warning("email change refused for app_user %s", g.caller["id"])
        return jsonify({"error": "That email address cannot be used"}), 400

    try:
        get_supabase_for_caller(g.access_token).rpc("record_email_change", {
            "p_app_user":   g.caller["id"],
            "p_actor_kind": "self",
            "p_reason":     None,
            "p_old_email":  current_email,
            "p_new_email":  new_email,
        }).execute()
    except Exception:
        app.logger.warning("email change audit failed for app_user %s", g.caller["id"])

    return jsonify({
        "pending_verification": bool(result.get("pending_email")),
        "message": ("Check your inbox - the change takes effect once the new "
                    "address is confirmed."
                    if result.get("pending_email")
                    else "Your login email has been updated."),
    })


@app.route("/admin/users/<uid>/email", methods=["PATCH"])
@require_auth
@require_role("admin")
def admin_change_user_email(uid):
    """
    Administrator-initiated login-email change.

    The Auth identity is RESOLVED from the selected application identity by
    `admin_prepare_email_change`, which also enforces `administer_users` and the
    administrative reason. The route never accepts an Auth uuid, so an arbitrary
    or guessed one cannot be targeted, and the capability check is the database's
    to make rather than this decorator's.

    No plant or capability grant is read or written anywhere in this route.
    """
    data = request.get_json(force=True) or {}
    new_email = (data.get("new_email") or "").strip().lower()
    reason    = (data.get("reason") or "").strip()

    try:
        app_user_id = int(uid)
    except (TypeError, ValueError):
        return jsonify({"error": "User not found"}), 404
    if not _valid_email(new_email):
        return jsonify({"error": "Enter a valid email address"}), 400
    if not reason:
        return jsonify({"error": "An administrative reason is required"}), 400

    client = get_supabase_for_caller(g.access_token)

    try:
        auth_uid = (client.rpc("admin_prepare_email_change", {
            "p_app_user": app_user_id, "p_reason": reason}).execute()).data
    except Exception:
        return jsonify({"error": "Could not change that user's email"}), 400
    if not auth_uid:
        return jsonify({"error": "User not found"}), 404

    admin_api = privileged_client("auth_admin_update_user").auth.admin
    try:
        old_email = getattr(admin_api.get_user_by_id(auth_uid).user, "email", None)
    except Exception:
        old_email = None

    try:
        admin_api.update_user_by_id(auth_uid, {"email": new_email})
    except Exception:
        # Same answer whether the address is taken, malformed or rejected.
        app.logger.warning("admin email change refused for app_user %s", app_user_id)
        return jsonify({"error": "That email address cannot be used"}), 400

    confirmed = None
    try:
        confirmed = getattr(admin_api.get_user_by_id(auth_uid).user,
                            "email_confirmed_at", None) is not None
    except Exception:
        pass

    try:
        client.rpc("record_email_change", {
            "p_app_user": app_user_id, "p_actor_kind": "admin", "p_reason": reason,
            "p_old_email": old_email, "p_new_email": new_email}).execute()
    except Exception:
        app.logger.warning("admin email change audit failed for app_user %s", app_user_id)

    revoked = 0
    try:
        revoked = (client.rpc("revoke_user_sessions",
                              {"p_app_user": app_user_id}).execute()).data or 0
    except Exception:
        app.logger.warning("session revocation failed for app_user %s", app_user_id)

    return jsonify({
        "id": app_user_id,
        "sessions_revoked": revoked,
        "pending_verification": (confirmed is False),
        "message": ("Email updated. The user's sessions were revoked and they "
                    "must sign in again."),
    })


@app.route("/admin/auth-orphans", methods=["GET"])
@require_auth
@require_group_capability("administer_users")
def list_auth_orphans():
    """
    Authentication accounts with no application identity and no open invitation.

    Creating a user spans two systems. The database half is atomic; the pair is
    not, and cannot be - there is no transaction across GoTrue and Postgres. The
    create route compensates by deleting the Auth account when the database half
    fails, but a compensating delete can itself fail, and what survives then is
    an Auth account nothing points at.

    Such an account is harmless - every route resolves through `app_users` and
    refuses anything that does not - but it should be findable rather than
    argued away, which is what this is for. An account carrying an open
    invitation is NOT an orphan: it is a pending onboarding.
    """
    client = get_supabase_for_caller(g.access_token)

    try:
        auth_users = privileged_client("auth_admin_list_users").auth.admin.list_users()
    except Exception:
        return jsonify({"error": "Could not read the authentication accounts"}), 400

    linked = {
        u.get("auth_user_id")
        for u in (client.table("app_users").select("auth_user_id").execute()).data or []
        if u.get("auth_user_id")
    }
    candidates = [u for u in auth_users if str(getattr(u, "id", "")) not in linked]
    emails = [getattr(u, "email", None) for u in candidates if getattr(u, "email", None)]

    invited = set()
    if emails:
        try:
            invited = {
                e.lower() for e in
                (client.rpc("admin_emails_with_open_invitation",
                            {"p_emails": emails}).execute()).data or []
            }
        except Exception:
            return jsonify({"error": "Could not check outstanding invitations"}), 400

    orphans = [{
        "ref":          _auth_ref(str(u.id)),   # matches the compensation log line
        "auth_user_id": str(u.id),
        "email":        getattr(u, "email", None),
        "created_at":   str(getattr(u, "created_at", "") or ""),
        "last_sign_in_at": str(getattr(u, "last_sign_in_at", "") or ""),
    } for u in candidates if (getattr(u, "email", "") or "").lower() not in invited]

    return jsonify({
        "orphans": orphans,
        "count": len(orphans),
        "recovery": ("Adopt the account with POST /admin/users/adopt to give it an "
                     "application identity, or delete it in the Supabase Auth "
                     "dashboard if it was never meant to exist."),
    })


@app.route("/admin/users/adopt", methods=["POST"])
@require_auth
@require_group_capability("administer_users")
def adopt_auth_account():
    """
    Give an EXISTING authentication account an application identity.

    Two things need this. An orphan left by a failed compensation is one. The
    other is any account that already exists in Auth and must not be recreated -
    `POST /admin/users` always mints a NEW Auth account, so it fails on a
    duplicate address and cannot be used to reconnect one.

    The account is named by ADDRESS, not by Auth uuid: the uuid is resolved here
    from the Auth listing, so a caller cannot aim this at an arbitrary uuid. The
    database then refuses anything that is not genuinely unattached -
    uk_app_users_auth makes a second identity for one account impossible - and
    the grants land in the same single atomic RPC as ordinary creation.
    """
    data = request.get_json(force=True) or {}
    email        = (data.get("email") or "").strip().lower()
    display_name = (data.get("display_name") or "").strip()
    role         = data.get("role", "maker")

    if not _valid_email(email) or not display_name:
        return jsonify({"error": "A valid email and display name are required"}), 400
    if role not in VALID_ROLES:
        return jsonify({"error": f"role must be one of {VALID_ROLES}"}), 400
    try:
        plant_codes = _normalise_plants(data) or []
    except ValueError:
        return jsonify({"error": "plants must be a list of plant codes"}), 400
    problem = _plant_requirement_error(role, plant_codes)
    if problem:
        return jsonify({"error": problem}), 400

    try:
        auth_users = privileged_client("auth_admin_list_users").auth.admin.list_users()
    except Exception:
        return jsonify({"error": "Could not read the authentication accounts"}), 400

    target = next((u for u in auth_users
                   if (getattr(u, "email", "") or "").lower() == email), None)
    if target is None:
        # Same answer whether it does not exist or already has an identity.
        return jsonify({"error": "No unattached authentication account for that address"}), 404

    try:
        app_user_id = (
            get_supabase_for_caller(g.access_token)
            .rpc("admin_create_app_user", {
                "p_auth_user_id": str(target.id),
                "p_display_name": display_name,
                "p_role":         role,
                "p_plant_codes":  plant_codes,
            })
            .execute()
        ).data
    except Exception:
        # Nothing to compensate: no Auth account was created here.
        return jsonify({"error": "Could not attach an application identity to that account"}), 400

    return jsonify({
        "id": app_user_id, "email": email, "display_name": display_name,
        "role": role, "plants": plant_codes, "active": True, "adopted": True,
    }), 201


@app.route("/masters/plants", methods=["GET"])
@require_auth
def list_plants():
    """
    The Plant Master, read as the caller.

    Read-only by design. The canonical brief seeds `plants` as a Family A table
    and approves no create, edit or deactivate operation for it, so Plant Master
    maintenance is DEFERRED rather than invented here. Retiring a plant is a
    status change that needs an approved rule first, and physical deletion is
    already refused by ON DELETE RESTRICT once a plant has been granted.
    """
    rows = (get_supabase_for_caller(g.access_token)
            .table("plants").select("id, plant_code, name, status").execute()).data or []
    rows.sort(key=lambda r: r.get("plant_code") or "")
    return jsonify({
        "plants": rows,
        "active_codes": [r["plant_code"] for r in rows if r.get("status") == "active"],
        "maintenance": "deferred",
    })


@app.route("/masters/customer-families", methods=["GET"])
@require_auth
def list_customer_families():
    """
    Customer Families, read as the caller (U1, post-S7 handover S9.4).

    Read-only by design, same as /masters/plants above. RLS gates SELECT on
    all four tables behind the group capability `read_party_master` -
    confirmed directly from `pg_policies`, not assumed - so a caller without
    it would get an empty result from every one of these four queries, not
    an error, if the route relied on RLS alone. **It does not**: `require_auth`
    already resolved the caller's `group_capabilities` through
    `caller_context.resolve_caller()` before this body runs (`g.caller`), at
    no extra query cost, so the route checks it explicitly and returns 403 -
    genuine access denial is never presented as "no families exist".

    Group-wide, not plant-scoped: `read_party_master` is a GROUP capability
    (`has_group_cap`, not `has_plant_cap`) on all four tables, so there is no
    wrong-plant case for this screen to refuse.

    U1 Customer Family mutations (post-U1-correction binding decisions) are
    now governed: propose/edit/approve a Family, add/edit/retire an alias,
    merge, reassign and graduate a Prospect all go through the
    `app_private.*` operations below via their `public` invoker wrappers -
    see `docs/u1-customer-family-mutations-packet.md` in quote-gen-fe for the
    full design record and `tests.customer_family_mutations()` for the
    DB-layer proof.
    """
    if "read_party_master" not in (g.caller.get("group_capabilities") or []):
        return jsonify({"error": "read_party_master capability is required"}), 403

    client = get_supabase_for_caller(g.access_token)

    # D1 - these six reads are independent of one another and ran strictly in
    # sequence, which measured ~2.7 s of pure round-trip time against a live
    # project holding a single family. They now run with BOUNDED parallelism.
    #
    # ONE CLIENT PER WORKER, never the shared per-request client. Sharing it was
    # tried first and fails: supabase-py speaks HTTP/2 and multiplexes every
    # request over ONE TCP connection, so concurrent threads collide inside
    # httpcore's sync h2 path with `httpx.ReadError: [WinError 10035]`, and the
    # pooled connection is left wedged so the NEXT request hangs until timeout.
    # Measured, with a stack trace. new_caller_client() therefore hands each
    # worker its own client and its own connection.
    #
    # The pool is bounded to exactly these six known reads - not a general
    # concurrency mechanism, and not sized from anything a caller controls.
    #
    # Authority is unchanged: every read carries the caller's own token, RLS
    # decides visibility exactly as on the sequential path, and the explicit
    # read_party_master check above still runs first. Failures propagate
    # deterministically - pool.map re-raises the first worker exception in
    # submission order, and `results` is only bound if EVERY read returned, so
    # a partial result set can never be serialised into a response.
    #
    # U1 Slice C addition (locations, location_versions) - additive, same
    # read_party_master gate, no RLS change. Lets the frontend show a Party's
    # Locations, including descriptive version history, without a second
    # round-trip from the browser.
    _READS = (
        ("families", "customer_families",
         "id, group_customer_code, name, status, surviving_family_id, content_version"),
        ("aliases", "customer_family_aliases",
         "id, family_id, alias, status, content_version"),
        ("memberships", "party_family_memberships",
         "id, party_id, family_id, effective_from, effective_until, is_current"),
        ("parties", "parties",
         "id, customer_code, display_name, lifecycle_state, status, content_version"),
        ("locations", "customer_locations",
         "id, party_id, location_code, bill_to_eligible, ship_to_eligible, status, content_version"),
        ("location_versions", "customer_location_versions",
         "id, location_id, version_no, location_type, address_text, contact_name, notes, status"),
    )

    # Captured HERE, not read inside the worker: `flask.g` is bound to the
    # request context and is not visible from a pool thread.
    caller_token = g.access_token

    def _read(spec):
        key, table, cols = spec
        worker_client = new_caller_client(caller_token)
        return key, (worker_client.table(table).select(cols).execute()).data or []

    try:
        with timed("families.six_reads_parallel"):
            with ThreadPoolExecutor(max_workers=len(_READS)) as pool:
                results = dict(pool.map(_read, _READS))
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("customer-families read timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise

    families = results["families"]
    aliases = results["aliases"]
    memberships = results["memberships"]
    parties = results["parties"]
    locations = results["locations"]
    location_versions = results["location_versions"]

    families.sort(key=lambda r: r.get("group_customer_code") or r.get("name") or "")
    return jsonify({
        "families": families,
        "aliases": aliases,
        "memberships": memberships,
        "parties": parties,
        "locations": locations,
        "location_versions": location_versions,
        "mutations": "governed",
    })


# ═══════════════════════════════════════════════════════════════════════════════
# ROUTES: /masters/customer-families/*  — U1 Customer Family mutations.
#
# Every route below is a thin caller-context RPC forwarder: it validates the
# request BODY SHAPE only (types, not RLS's job), calls the corresponding
# `public.*` invoker wrapper exactly once with the caller's own token, and
# maps the outcome through _rpc_call(). No route duplicates a capability or
# state-transition check - app_private.* already enforces every one of those,
# and duplicating it here would create two places that could drift (the
# D-27/S6-14 class of defect). No route uses the service-role client.
#
# Error mapping is documented in full in
# docs/u1-customer-family-mutations-packet.md §6 (quote-gen-fe). By the time
# any of these routes runs, @require_auth has already resolved an ACTIVE
# caller, so a 42501 raised here is always a capability denial (403), never
# "unauthenticated" (401) - that case is already handled by require_auth
# before the route body runs at all.
#
# U1-CF-C2 correction. The first pass forwarded `exc.message` (the raw
# Postgres exception text) to the client for every mapped SQLSTATE. That
# contradicts the binding instruction not to pass raw Postgres exception text
# to the frontend - a future RAISE naming a table or column would leak it with
# no code change on this side to catch. Every response from this file now
# carries an application-owned `error_code` and a fixed, backend-authored
# message; the SQLSTATE and the database's own message are logged server-side
# only, never returned.
# ═══════════════════════════════════════════════════════════════════════════════

_RPC_ERROR_MAP = {
    "42501": "CAPABILITY_REQUIRED",   # capability check failed inside app_private.*
    "P0002": "RECORD_NOT_FOUND",      # Family / Party / alias not found
    # D2, corrected by migration 20260908052900. A DELIBERATE stale-version
    # conflict now raises PT409, never 40001.
    #
    # Why it moved: 40001 is serialization_failure, which the Data API treats as
    # a TRANSIENT fault and retries. Our CAS conflict is deterministic, so every
    # retry re-raised it and the request never returned. Measured on one
    # governed RPC, one persona, one path, where only the SQLSTATE differed:
    #     P0002 (not found) -> HTTP 500 in 468 ms
    #     40001 (stale CAS) -> no response at all; 25-40 s, client timeout
    # ...identical through raw urllib/HTTP1.1 and supabase-py/HTTP2, so it was
    # the server, not the client; direct SQL raised that same 40001 in 49 ms.
    # postgres_logs for the `authenticator` role showed 1,025,464 x 40001 about
    # 10 ms apart, against 8 x P0002 in the same window - a retry storm, not a
    # slow response.
    "PT409": "STALE_VERSION",         # stale content_version - the CAS check failed
    # A GENUINE serialization failure is still possible and is deliberately kept
    # DISTINCT: it is raised by Postgres itself under concurrent access, it is
    # transient, and retrying it is the correct response - the opposite of a
    # stale-version conflict, where retrying unchanged can only fail again.
    # Nothing in this codebase raises 40001 on purpose any more, so reaching
    # this entry means the database really did fail to serialize.
    "40001": "SERIALIZATION_FAILURE",
    "22023": "TRANSITION_NOT_ALLOWED",  # forbidden state transition, self-merge,
                                         # merge-cycle, double-retirement, retired target
    "22007": "INVALID_EFFECTIVE_DATE",  # effective date precedes the current membership
}

_ERROR_STATUS = {
    "CAPABILITY_REQUIRED": 403,
    "RECORD_NOT_FOUND": 404,
    "STALE_VERSION": 409,
    "TRANSITION_NOT_ALLOWED": 422,
    "INVALID_EFFECTIVE_DATE": 422,
    "INVALID_INPUT": 400,
    # A genuine serialization failure is transient: the caller may safely retry
    # the SAME request unchanged. Distinct from STALE_VERSION, where retrying
    # unchanged is guaranteed to fail again.
    "SERIALIZATION_FAILURE": 409,
    # D2 - a hung upstream call is not an application fault and must not be
    # reported as one. 504 is a stable answer the frontend can act on; the
    # underlying socket/httpx text stays server-side.
    "UPSTREAM_TIMEOUT": 504,
    "INTERNAL_ERROR": 500,
}

_ERROR_MESSAGE = {
    "CAPABILITY_REQUIRED": "You do not have permission to perform this action.",
    "RECORD_NOT_FOUND": "The requested record could not be found.",
    "STALE_VERSION": "This record changed since you last read it. Reload and try again.",
    "TRANSITION_NOT_ALLOWED": "That action is not allowed for this record's current state.",
    "INVALID_EFFECTIVE_DATE": "The effective date is not valid for this change.",
    "SERIALIZATION_FAILURE": "The database could not complete that under concurrent load. "
                             "Nothing was changed — please try again.",
    # D2 CORRECTION. This must NOT claim the write did not happen. A client-side
    # timeout means the RESPONSE was lost, not that the server did nothing: the
    # transaction may well have committed before the connection gave up. Telling
    # the user "nothing was changed, try again" invites a duplicate submission on
    # an operation that already succeeded. The honest answer is that the outcome
    # is unknown and must be observed before acting.
    "UPSTREAM_TIMEOUT": "The database did not respond in time, so the outcome of this action is "
                        "UNKNOWN — it may or may not have been saved. Refresh to see the current "
                        "state before trying again.",
    "INTERNAL_ERROR": "Could not complete that action.",
}


# D2 - recognise a genuine upstream timeout without leaking its text. httpx
# raises TimeoutException subclasses; the underlying socket/ssl layer raises
# TimeoutError or socket.timeout with "The read operation timed out", which is
# the exact string observed in the browser walkthrough. Matched structurally
# first, by message only as a fallback.
_TIMEOUT_MARKERS = ("timed out", "timeout")


def _is_upstream_timeout(exc: BaseException) -> bool:
    import httpx
    seen = set()
    while exc is not None and id(exc) not in seen:
        seen.add(id(exc))
        if isinstance(exc, (httpx.TimeoutException, TimeoutError)):
            return True
        text = str(exc).lower()
        if any(m in text for m in _TIMEOUT_MARKERS):
            return True
        exc = exc.__cause__ or exc.__context__
    return False


def _error(code, message=None):
    """
    One stable JSON error shape for every route in this section:
    {"error_code": "<APPLICATION_OWNED_CONSTANT>", "error": "<fixed or route-authored text>"}.
    `message` is only ever text THIS FILE wrote (a field-required message, or
    one of the fixed _ERROR_MESSAGE strings) - never database-supplied text.
    """
    return jsonify({"error_code": code, "error": message or _ERROR_MESSAGE[code]}), _ERROR_STATUS[code]


def _invalid_input(message):
    return _error("INVALID_INPUT", message)


def _rpc_call(client, name, params):
    """
    Call a governed `public.*` RPC and translate the outcome into a stable
    HTTP error tuple, or (result, None) on success.

    The Postgres SQLSTATE decides which application-owned error_code and HTTP
    status come back; the database's own exception message is logged
    server-side only (`app.logger`) and never reaches the response body, for
    both mapped and unmapped codes alike.
    """
    try:
        return client.rpc(name, params).execute(), None
    except APIError as exc:
        code = _RPC_ERROR_MAP.get(exc.code)
        if code is not None:
            app.logger.info("RPC %s refused: %s %s -> %s", name, exc.code, exc.message, code)
            return None, _error(code)
        app.logger.error("unmapped RPC error from %s: %s %s", name, exc.code, exc.message)
        return None, _error("INTERNAL_ERROR")
    except Exception as exc:
        # D2 - a hung upstream call used to land here and be reported as a bare
        # 500 INTERNAL_ERROR after the 120-second supabase-py default. The
        # timeout is now bounded (UPSTREAM_TIMEOUT_SECONDS) and answered with a
        # stable, retryable 504 that says nothing was changed - which is true,
        # because every governed mutation is a single atomic RPC that either
        # committed or did not. The raw socket text is logged, never returned.
        if _is_upstream_timeout(exc):
            app.logger.error("RPC %s timed out after %ss: %s",
                             name, UPSTREAM_TIMEOUT_SECONDS, exc)
            return None, _error("UPSTREAM_TIMEOUT")
        app.logger.error("RPC call to %s failed: %s", name, exc)
        return None, _error("INTERNAL_ERROR")


def _int_field(data, key):
    """Strict integer extraction — a bool is not an int, a float string is not either."""
    v = data.get(key)
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, str) and v.strip().lstrip("-").isdigit():
        return int(v.strip())
    return None


@app.route("/masters/customer-families", methods=["POST"])
@require_auth
def propose_customer_family():
    """Propose a new Family. manage_customer_master OR make_quote at any active plant."""
    data = request.get_json(force=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return _invalid_input("name is required")

    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "propose_customer_family", {"p_name": name})
    if err:
        return err
    return jsonify({"id": result.data}), 201


@app.route("/masters/customer-families/prospects", methods=["POST"])
@require_auth
def create_minimal_prospect():
    """
    Atomic minimal Prospect creation (CDM-06) - one governed DB operation:
    reuses family_id if given, else silently proposes a new Family named
    after the Prospect, inserts the Party and its current membership.
    """
    data = request.get_json(force=True) or {}
    display_name = (data.get("display_name") or "").strip()
    if not display_name:
        return _invalid_input("display_name is required")
    family_id = None
    if data.get("family_id") is not None:
        family_id = _int_field(data, "family_id")
        if family_id is None:
            return _invalid_input("family_id must be an integer")

    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "create_minimal_prospect",
        {"p_display_name": display_name, "p_family_id": family_id})
    if err:
        return err
    row = (result.data or [{}])[0]
    return jsonify({"party_id": row.get("party_id"), "family_id": row.get("family_id")}), 201


@app.route("/masters/customer-families/<int:family_id>", methods=["PATCH"])
@require_auth
def update_customer_family_name(family_id):
    """Rename a Family. manage_customer_master. CAS via expected_content_version."""
    data = request.get_json(force=True) or {}
    name = (data.get("name") or "").strip()
    expected = _int_field(data, "expected_content_version")
    if not name:
        return _invalid_input("name is required")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "update_customer_family",
        {"p_family": family_id, "p_expected_content_version": expected, "p_name": name})
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/customer-families/<int:family_id>/approve", methods=["POST"])
@require_auth
def approve_customer_family(family_id):
    """Approve a proposed Family (proposed -> active). manage_customer_master."""
    data = request.get_json(force=True) or {}
    expected = _int_field(data, "expected_content_version")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "approve_customer_family",
        {"p_family": family_id, "p_expected_content_version": expected})
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/customer-families/<int:family_id>/aliases", methods=["POST"])
@require_auth
def add_family_alias(family_id):
    """Add an alias to a Family. manage_customer_master."""
    data = request.get_json(force=True) or {}
    alias = (data.get("alias") or "").strip()
    if not alias:
        return _invalid_input("alias is required")

    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "add_family_alias", {"p_family": family_id, "p_alias": alias})
    if err:
        return err
    return jsonify({"id": result.data}), 201


@app.route("/masters/customer-family-aliases/<int:alias_id>", methods=["PATCH"])
@require_auth
def update_family_alias(alias_id):
    """Rename an alias. manage_customer_master. CAS via expected_content_version."""
    data = request.get_json(force=True) or {}
    alias = (data.get("alias") or "").strip()
    expected = _int_field(data, "expected_content_version")
    if not alias:
        return _invalid_input("alias is required")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "update_family_alias",
        {"p_alias_id": alias_id, "p_expected_content_version": expected, "p_alias": alias})
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/customer-family-aliases/<int:alias_id>/retire", methods=["POST"])
@require_auth
def retire_family_alias(alias_id):
    """Retire an alias. manage_customer_master. CAS via expected_content_version."""
    data = request.get_json(force=True) or {}
    expected = _int_field(data, "expected_content_version")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "retire_family_alias",
        {"p_alias_id": alias_id, "p_expected_content_version": expected})
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/customer-families/merge", methods=["POST"])
@require_auth
def merge_customer_families():
    """
    Merge two Families. manage_customer_master. Dual-sided CAS - both
    survivor and retired versions are required and validated before either
    row changes. Irreversible: no un-merge operation exists.
    """
    data = request.get_json(force=True) or {}
    survivor_id = _int_field(data, "survivor_id")
    retired_id = _int_field(data, "retired_id")
    expected_survivor = _int_field(data, "expected_survivor_version")
    expected_retired = _int_field(data, "expected_retired_version")
    if survivor_id is None or retired_id is None:
        return _invalid_input("survivor_id and retired_id are required")
    if expected_survivor is None or expected_retired is None:
        return _invalid_input("expected_survivor_version and expected_retired_version are required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "merge_customer_families", {
            "p_survivor": survivor_id, "p_retired": retired_id,
            "p_expected_survivor_version": expected_survivor,
            "p_expected_retired_version": expected_retired,
        })
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/customer-families/reassign", methods=["POST"])
@require_auth
def reassign_customer_family():
    """
    Reassign a Party to a different Family, with effective dating.
    manage_customer_master. CAS on the Party protects against both a
    concurrent reassignment and a concurrent unrelated edit to the Party.
    """
    data = request.get_json(force=True) or {}
    party_id = _int_field(data, "party_id")
    new_family_id = _int_field(data, "new_family_id")
    expected = _int_field(data, "expected_content_version")
    effective_date = data.get("effective_date")
    if party_id is None or new_family_id is None:
        return _invalid_input("party_id and new_family_id are required")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    params = {
        "p_party": party_id, "p_new_family": new_family_id,
        "p_expected_content_version": expected,
    }
    if effective_date:
        params["p_effective"] = effective_date

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "reassign_customer_family", params)
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/customer-families/graduate", methods=["POST"])
@require_auth
def graduate_customer_party():
    """
    Graduate a Prospect to a Customer, minting the permanent Customer Code.
    manage_customer_master. Idempotent - a repeat call returns the same code
    unchanged rather than conflicting, so no CAS is needed here.
    """
    data = request.get_json(force=True) or {}
    party_id = _int_field(data, "party_id")
    if party_id is None:
        return _invalid_input("party_id is required")

    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "graduate_customer_party", {"p_party": party_id})
    if err:
        return err
    return jsonify({"customer_code": result.data})


# ═══════════════════════════════════════════════════════════════════════════════
# ROUTE: /masters/parties/<id>  — U1 Slice A Party editing (display_name only).
#
# Authorised by docs/u1-customer-foundation-authorization-packet.md (quote-gen-fe),
# Slice A. Same thin caller-context RPC forwarder shape as every route above -
# validates body SHAPE only, calls public.update_customer_party exactly once
# with the caller's own token, maps the outcome through _rpc_call(). No new
# error code: 42501/P0002/40001/22023 already cover every condition this
# function raises.
# ═══════════════════════════════════════════════════════════════════════════════
@app.route("/masters/parties/<int:party_id>", methods=["PATCH"])
@require_auth
def update_customer_party(party_id):
    """Rename a Party's display_name. manage_customer_master. CAS via expected_content_version."""
    data = request.get_json(force=True) or {}
    display_name = (data.get("display_name") or "").strip()
    expected = _int_field(data, "expected_content_version")
    if not display_name:
        return _invalid_input("display_name is required")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "update_customer_party",
        {"p_party": party_id, "p_expected_content_version": expected, "p_display_name": display_name})
    if err:
        return err
    return jsonify({"ok": True})


# ═══════════════════════════════════════════════════════════════════════════════
# ROUTES: /masters/parties/<id>/locations, /masters/customer-locations/*
# — U1 Slice C Customer Location proposal/version/approval/retirement.
#
# Authorised by docs/u1-customer-foundation-authorization-packet.md
# (quote-gen-fe), Slice C. Same thin caller-context RPC forwarder shape as
# every route above. No eligibility-change route exists here - post-proposal
# eligibility change is Product-Owner-blocked, not built (see the packet).
# No new error code: 42501/P0002/40001/22023 already cover every condition.
# ═══════════════════════════════════════════════════════════════════════════════
@app.route("/masters/parties/<int:party_id>/locations", methods=["POST"])
@require_auth
def propose_customer_location(party_id):
    """Propose a Customer Location. manage_customer_master OR make_quote at any active plant."""
    data = request.get_json(force=True) or {}
    bill_to = bool(data.get("bill_to_eligible"))
    ship_to = bool(data.get("ship_to_eligible"))
    if not (bill_to or ship_to):
        return _invalid_input("a Location must be Bill-to, Ship-to or both")

    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "propose_customer_location", {
            "p_party": party_id,
            "p_location_type": data.get("location_type"),
            "p_address_text": data.get("address_text"),
            "p_contact_name": data.get("contact_name"),
            "p_notes": data.get("notes"),
            "p_bill_to_eligible": bill_to,
            "p_ship_to_eligible": ship_to,
        })
    if err:
        return err
    return jsonify({"id": result.data}), 201


@app.route("/masters/customer-locations/<int:location_id>", methods=["PATCH"])
@require_auth
def update_customer_location(location_id):
    """Edit a Location's descriptive detail (new version). manage_customer_master. CAS."""
    data = request.get_json(force=True) or {}
    expected = _int_field(data, "expected_content_version")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "update_customer_location", {
            "p_location": location_id,
            "p_expected_content_version": expected,
            "p_address_text": data.get("address_text"),
            "p_contact_name": data.get("contact_name"),
            "p_notes": data.get("notes"),
        })
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/customer-locations/<int:location_id>/approve", methods=["POST"])
@require_auth
def approve_customer_location(location_id):
    """Approve a proposed Location (proposed -> active). manage_customer_master."""
    data = request.get_json(force=True) or {}
    expected = _int_field(data, "expected_content_version")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "approve_customer_location",
        {"p_location": location_id, "p_expected_content_version": expected})
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/customer-locations/<int:location_id>/retire", methods=["POST"])
@require_auth
def retire_customer_location(location_id):
    """Retire an active Location (active -> inactive). manage_customer_master."""
    data = request.get_json(force=True) or {}
    expected = _int_field(data, "expected_content_version")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "retire_customer_location",
        {"p_location": location_id, "p_expected_content_version": expected})
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/customer-locations/<int:location_id>/assign-code", methods=["POST"])
@require_auth
def assign_customer_location_code(location_id):
    """
    Mint the permanent Location Code. manage_customer_master. Idempotent - a
    repeat call returns the same code unchanged, so no CAS is needed here.
    Refuses P0002 if the owning Party is not yet graduated (no Customer Code
    to nest beneath) - a distinct, explicit action, not auto-called from
    approve (see the packet's reasoning).
    """
    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "assign_customer_location_code", {"p_location": location_id})
    if err:
        return err
    return jsonify({"location_code": result.data})


@app.route("/auth/logout", methods=["POST"])
@require_auth
def auth_logout():
    # Best-effort — revoke every refresh token for this session. The frontend
    # clears its own stored tokens regardless of whether this succeeds.
    try:
        privileged_client("auth_admin_sign_out").auth.admin.sign_out(
            g.access_token, "global")
    except Exception:
        pass
    return jsonify({"ok": True})


@app.route("/auth/me", methods=["PATCH"])
@require_auth
def auth_update_me():
    """
    Self-service profile edit — a user updating their own display_name/plant.
    Deliberately does not accept role or active: those stay admin-only via
    /admin/users/<uid>, even for a user editing their own row.
    """
    data = request.get_json(force=True) or {}
    updates = {}
    if "display_name" in data:
        display_name = (data["display_name"] or "").strip()
        if not display_name:
            return jsonify({"error": "Display name cannot be empty"}), 400
        updates["display_name"] = display_name

    # CANONICAL CHANGE (CDM-05): plant is no longer a self-editable column. It is a
    # capability grant, so only an administrator can change it. Reported explicitly
    # rather than silently ignored.
    if "plant" in data:
        return jsonify({
            "error": "Plant is assigned by an administrator and cannot be self-edited"
        }), 403

    if not updates:
        return jsonify({"error": "No fields to update"}), 400

    # Runs as the caller. The column grant allows display_name and nothing else, so
    # even a crafted request cannot reach status or auth_user_id.
    result = (
        get_supabase_for_caller(g.access_token)
        .table("app_users")
        .update(updates)
        .eq("id", g.caller["id"])
        .execute()
    )
    if not result.data:
        return jsonify({"error": "Could not update profile"}), 400
    return jsonify({**g.caller, **updates, "email": g.current_user["email"]})


@app.route("/auth/change-password", methods=["POST"])
@require_auth
def auth_change_password():
    """
    Self-service password change — any logged-in user, for their own account.
    Requires the current password (re-verified via sign_in_with_password) so
    a leftover valid access token on a shared machine can't be used to lock
    the real owner out.
    """
    data             = request.get_json(force=True) or {}
    current_password = data.get("current_password") or ""
    new_password     = data.get("new_password") or ""

    if not current_password or not new_password:
        return jsonify({"error": "current_password and new_password are required"}), 400
    if len(new_password) < 8:
        return jsonify({"error": "New password must be at least 8 characters"}), 400

    try:
        get_supabase_anon().auth.sign_in_with_password({
            "email": g.current_user["email"],
            "password": current_password,
        })
    except Exception:
        return jsonify({"error": "Current password is incorrect"}), 401

    try:
        privileged_client("auth_admin_update_user").auth.admin.update_user_by_id(
            g.caller["auth_user_id"], {"password": new_password}
        )
    except Exception as e:
        return jsonify({"error": f"Could not update password: {e}"}), 400

    return jsonify({"ok": True})


# ═══════════════════════════════════════════════════════════════════════════════
# ROUTES: /admin/users*  — Admin-only user management.
# ═══════════════════════════════════════════════════════════════════════════════

VALID_ROLES = ("maker", "checker", "admin")

# Legacy `profiles.role` was one column. The approved model expresses the same thing
# as capability grants (CDM-05), so the API still reports a role but DERIVES it.
def derive_role(group_caps, plant_caps):
    if "administer_users" in (group_caps or []):
        return "admin"
    for caps in (plant_caps or {}).values():
        if "check_quote" in caps:
            return "checker"
    return "maker"


def _read_one_user(client, app_user_id):
    """Re-read one identity as the caller, shaped like the legacy profile row."""
    rows = (client.table("app_users")
            .select("id, auth_user_id, display_name, status, content_version")
            .eq("id", app_user_id).limit(1).execute()).data or []
    if not rows:
        return {}
    u = rows[0]
    gc = [ (r.get("capabilities") or {}).get("capability_key")
           for r in (client.table("group_capability_grants")
                     .select("capabilities(capability_key)")
                     .eq("app_user_id", app_user_id).eq("status", "active")
                     .execute()).data or [] ]
    pc = {}
    for r in (client.table("plant_capability_grants")
              .select("capabilities(capability_key), plants(plant_code)")
              .eq("app_user_id", app_user_id).eq("status", "active")
              .execute()).data or []:
        code = (r.get("plants") or {}).get("plant_code")
        key  = (r.get("capabilities") or {}).get("capability_key")
        if code:
            pc.setdefault(code, [])
            if key:
                pc[code].append(key)
    return {
        "id": u["id"], "display_name": u["display_name"],
        "active": u["status"] == "active", "status": u["status"],
        # UA-5 - the caller needs the NEW version to act again without a reload.
        "content_version": u.get("content_version"),
        "role": derive_role([c for c in gc if c], pc),
        "plant": next(iter(pc), None), "plants": sorted(pc),
        "group_capabilities": sorted(c for c in gc if c),
        "plant_capabilities": {k: sorted(v) for k, v in sorted(pc.items())},
    }


def _normalise_plants(data):
    """
    Read the requested plant assignment from a request body.

    Returns None when the body says nothing about plants (leave them alone), or
    a de-duplicated, order-preserving list of plant codes - possibly empty,
    which means "revoke every plant assignment".

    `plants` is the real field. `plant` is kept as a single-value alias because
    the legacy `profiles.plant` column was one column and the frontend still
    sends it; it is NOT the model. A user may hold any number of plants, and
    collapsing that to one field is what CDM-05-A forbids.
    """
    if "plants" in data:
        raw = data.get("plants") or []
        if isinstance(raw, str):
            raw = [raw]
        if not isinstance(raw, list):
            raise ValueError("plants must be a list of plant codes")
        codes = [str(c).strip() for c in raw if str(c).strip()]
    elif "plant" in data:
        one = (data.get("plant") or "").strip()
        codes = [one] if one else []
    else:
        return None
    seen, out = set(), []
    for c in codes:
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out


def _plant_requirement_error(role, plant_codes):
    """
    Operating access needs a plant; group-only administration does not.

    A Maker or Checker whose authority is plant-scoped and who holds no plant
    can sign in and do nothing, which reads as a broken account rather than a
    deliberate one. An administrator may legitimately hold no plant at all -
    `administer_users` is group-scoped - and only needs one if they are also
    given plant-level work. Returns a message, or None when the selection is
    acceptable.
    """
    if plant_codes is None:            # the request said nothing about plants
        return None
    if role in ("maker", "checker") and not plant_codes:
        return "A Maker or Checker needs at least one plant"
    return None


@app.route("/admin/users", methods=["GET"])
@require_auth
@require_role("admin")
def list_users():
    """
    Administrator visibility is an RLS POLICY, not a service-role bypass.

    The app_users select policy already exposes every row to a caller holding
    administer_users, so this reads as the caller. Emails and sign-in times are
    not in the database at all - they live in Supabase Auth - so that one lookup
    uses the allow-listed Auth-admin client.
    """
    client = get_supabase_for_caller(g.access_token)

    users = (
        client.table("app_users")
        .select("id, auth_user_id, display_name, status, content_version")
        .execute()
    ).data or []
    if not users:
        return jsonify({"users": []})

    ids = [u["id"] for u in users]
    group_rows = (
        client.table("group_capability_grants")
        .select("app_user_id, capabilities(capability_key)")
        .in_("app_user_id", ids).eq("status", "active").execute()
    ).data or []
    plant_rows = (
        client.table("plant_capability_grants")
        .select("app_user_id, capabilities(capability_key), plants(plant_code)")
        .in_("app_user_id", ids).eq("status", "active").execute()
    ).data or []

    group_by_user, plant_by_user = {}, {}
    for r in group_rows:
        key = (r.get("capabilities") or {}).get("capability_key")
        if key:
            group_by_user.setdefault(r["app_user_id"], []).append(key)
    for r in plant_rows:
        key  = (r.get("capabilities") or {}).get("capability_key")
        code = (r.get("plants") or {}).get("plant_code")
        if code:
            plant_by_user.setdefault(r["app_user_id"], {}).setdefault(code, [])
            if key:
                plant_by_user[r["app_user_id"]][code].append(key)

    auth_by_id = {}
    try:
        for u in privileged_client("auth_admin_list_users").auth.admin.list_users():
            auth_by_id[str(u.id)] = u
    except Exception:
        auth_by_id = {}

    result = []
    for u in users:
        gc = sorted(set(group_by_user.get(u["id"], [])))
        pc = plant_by_user.get(u["id"], {})
        au = auth_by_id.get(str(u.get("auth_user_id")))
        result.append({
            "id":           u["id"],
            "display_name": u["display_name"],
            "active":       u["status"] == "active",
            "status":       u["status"],
            # UA-1 read contract. `role` is a DERIVED PRESENTATION LABEL and
            # nothing more - the capability sets below are the authority, and
            # the frontend renders the label read-only. `content_version` is
            # required for the capability editor's CAS.
            "content_version":     u.get("content_version"),
            "group_capabilities":  gc,
            "plant_capabilities":  {code: sorted(keys) for code, keys in pc.items()},
            "role":         derive_role(gc, pc),
            "plant":        next(iter(pc), None),
            "plants":       sorted(pc),
            "email":        au.email if au else None,
            "last_sign_in_at": (au.last_sign_in_at.isoformat()
                                if au and au.last_sign_in_at else None),
        })
    return jsonify({"users": result})


@app.route("/admin/users", methods=["POST"])
@require_auth
@require_role("admin")
def create_user():
    data = request.get_json(force=True) or {}
    email        = (data.get("email") or "").strip()
    display_name = (data.get("display_name") or "").strip()
    role         = data.get("role", "maker")

    if not email or not display_name:
        return jsonify({"error": "email and display_name are required"}), 400
    if role not in VALID_ROLES:
        return jsonify({"error": f"role must be one of {VALID_ROLES}"}), 400
    try:
        plant_codes = _normalise_plants(data) or []
    except ValueError:
        return jsonify({"error": "plants must be a list of plant codes"}), 400
    problem = _plant_requirement_error(role, plant_codes)
    if problem:
        return jsonify({"error": problem}), 400
    # The create RPC takes one plant code, because it is the minimal
    # capability-checked entry point and widening its signature is a database
    # change. Any further plants are applied immediately afterwards through the
    # same grant policies the PATCH route uses - so a user can be created
    # holding several plants without the RPC growing a list parameter.
    plant = plant_codes[0] if plant_codes else None

    generated = not data.get("password")
    password  = data.get("password") or secrets.token_urlsafe(9)

    try:
        created = privileged_client("auth_admin_create_user").auth.admin.create_user({
            "email": email,
            "password": password,
            "email_confirm": True,
        })
    except Exception:
        return jsonify({"error": "Could not create the authentication account"}), 400

    uid = created.user.id
    try:
        # app_users has no INSERT policy for any role: identity creation is not an
        # ordinary table write. This RPC runs as the caller and checks
        # administer_users itself, so the capability - not the service key - is
        # what authorises it. It also creates the role/plant capability grants.
        # The WHOLE plant set goes in one RPC, which PostgREST runs in a single
        # transaction - so either every grant commits or none does. The previous
        # version created the identity with the first plant and added the rest
        # afterwards, which could leave a real, active user holding part of the
        # requested access while this route still answered 201. There is now no
        # interval in which a partially granted identity exists.
        app_user_id = (
            get_supabase_for_caller(g.access_token)
            .rpc("admin_create_app_user", {
                "p_auth_user_id": uid,
                "p_display_name": display_name,
                "p_role":         role,
                "p_plant_codes":  plant_codes,
            })
            .execute()
        ).data
        if not app_user_id:
            raise RuntimeError("no application identity returned")
    except Exception:
        # Compensate COMPLETELY: the database rolled itself back, so the only
        # thing that can survive is the auth account, and it must not. If even
        # the compensation fails we say so rather than reporting a success we
        # cannot stand behind.
        try:
            privileged_client("auth_admin_delete_user").auth.admin.delete_user(uid)
        except Exception:
            # Redacted deliberately. An ordinary application log is the wrong
            # place for a raw Auth uuid or an address - logs are copied, shipped
            # and read by people who have no business with either. What is
            # logged is a NON-REVERSIBLE short fingerprint, which is enough to
            # correlate this line with the matching row in
            # GET /admin/auth-orphans (which reports the same `ref`) without the
            # log itself carrying an identifier.
            app.logger.error(
                "ORPHANED AUTH ACCOUNT ref=%s after a failed creation - visible at "
                "GET /admin/auth-orphans, recoverable with POST /admin/users/adopt",
                _auth_ref(uid))
            return jsonify({"error": "Could not create the user, and cleanup failed. "
                                     "Contact an administrator before retrying."}), 500
        return jsonify({"error": "Could not create the application identity"}), 400

    resp = {
        "id": app_user_id, "email": email, "display_name": display_name,
        "role": role, "plant": plant, "plants": plant_codes, "active": True,
    }
    if generated:
        resp["temp_password"] = password
    return jsonify(resp), 201


@app.route("/admin/users/<uid>", methods=["PATCH"])
@require_auth
@require_group_capability("administer_users")
def update_user(uid):
    """
    `uid` is the application identity (app_users.id), not an Auth uuid.

    Both writes run as the caller: display_name through the column grant, and
    status through the capability-checked, VERSIONED RPC.

    UA-5. The status change now carries `expected_content_version` and goes
    through _rpc_call, so the SQLSTATE decides the answer instead of every
    outcome collapsing into one 400:

        PT409 -> 409 STALE_VERSION          someone else changed this user
        22023 -> 422 TRANSITION_NOT_ALLOWED the last active administrator
        42501 -> 403 CAPABILITY_REQUIRED    not an administrator any more
        P0002 -> 404 RECORD_NOT_FOUND       no such user

    require_group_capability, not require_role: a derived label must not gate a
    route. The two are equivalent today - derive_role reads `admin` from
    administer_users - which is exactly why the difference has to be written
    down before a change to the derivation silently regates this.
    """
    data   = request.get_json(force=True) or {}
    client = get_supabase_for_caller(g.access_token)
    try:
        app_user_id = int(uid)
    except (TypeError, ValueError):
        return jsonify({"error": "User not found"}), 404

    touched = False

    if "display_name" in data:
        name = (data["display_name"] or "").strip()
        if not name:
            return jsonify({"error": "Display name cannot be empty"}), 400
        r = client.table("app_users").update({"display_name": name}).eq("id", app_user_id).execute()
        if not r.data:
            return jsonify({"error": "User not found"}), 404
        touched = True

    if "active" in data:
        # Checked here as well as in the database so the refusal can say what it
        # actually is. The database refuses it too (42501) and remains the
        # authority; this only makes the message specific.
        if app_user_id == g.caller["id"] and not data["active"]:
            return _error("TRANSITION_NOT_ALLOWED",
                          "You cannot deactivate your own account.")
        expected = _int_field(data, "expected_content_version")
        if expected is None:
            return _invalid_input("expected_content_version is required")
        _, err = _rpc_call(client, "admin_set_app_user_status", {
            "p_app_user": app_user_id,
            "p_expected_content_version": expected,
            "p_status": "active" if data["active"] else "deactivated",
        })
        if err:
            return err
        touched = True

    # UA-4. The legacy role/plant mutation branch is GONE, not bridged. It could
    # express only administer_users and one operational capability per plant, so
    # translating a partial request into a complete desired set would have
    # silently revoked the nine capabilities it cannot represent. Capability
    # changes now go to POST /admin/users/<id>/capabilities, which is the single
    # permission authority. An editable role must never rewrite grants.
    if "role" in data or "plant" in data or "plants" in data:
        return _error("TRANSITION_NOT_ALLOWED",
                      "Role and plant assignment are no longer edited here. "
                      "Use POST /admin/users/<id>/capabilities, which replaces the "
                      "complete capability set in one governed operation.")

    if not touched:
        return jsonify({"error": "No fields to update"}), 400

    return jsonify(_read_one_user(client, app_user_id))


# ═══════════════════════════════════════════════════════════════════════════
# ROUTE: /admin/users/<id>/capabilities  - UA-3, the single permission authority.
#
# Replaces the COMPLETE capability set in one governed database operation. It is
# the only application path that mutates grants: `authenticated` no longer holds
# INSERT/UPDATE on the grant tables, so a direct write is refused by the database
# rather than by a check here.
#
# require_group_capability, not require_role: a derived label must not gate a
# route. The database re-checks administer_users itself regardless.
# ═══════════════════════════════════════════════════════════════════════════
@app.route("/admin/users/<uid>/capabilities", methods=["POST"])
@require_auth
@require_group_capability("administer_users")
def set_user_capabilities_route(uid):
    data = request.get_json(force=True) or {}
    try:
        app_user_id = int(uid)
    except (TypeError, ValueError):
        return _error("RECORD_NOT_FOUND")

    expected = _int_field(data, "expected_content_version")
    if expected is None:
        return _invalid_input("expected_content_version is required")

    group_caps = data.get("group_capabilities")
    plant_caps = data.get("plant_capabilities")
    if not isinstance(group_caps, list) or not all(isinstance(k, str) for k in group_caps):
        return _invalid_input("group_capabilities must be a list of capability keys")
    if not isinstance(plant_caps, dict):
        return _invalid_input("plant_capabilities must be an object keyed by plant code")

    client = get_supabase_for_caller(g.access_token)

    # Codes at the HTTP boundary, immutable ids in the database contract. The
    # function re-validates each id as an active plant INSIDE its transaction,
    # so this lookup is a convenience, not the authority.
    plants = (client.table("plants").select("id, plant_code, status").execute()).data or []
    by_code = {p["plant_code"]: p["id"] for p in plants if p.get("status") == "active"}

    resolved, seen = {}, {}
    for code, caps in plant_caps.items():
        if not isinstance(code, str) or not isinstance(caps, list) \
           or not all(isinstance(c, str) for c in caps):
            return _invalid_input("each plant_capabilities value must be a list of capability keys")
        folded = code.strip().casefold()
        if folded in seen:
            return _invalid_input("plant codes must be distinct")
        seen[folded] = code
        if code not in by_code:
            return _error("TRANSITION_NOT_ALLOWED", "Unknown or inactive plant code.")
        resolved[str(by_code[code])] = caps

    result, err = _rpc_call(client, "set_user_capabilities", {
        "p_app_user": app_user_id,
        "p_expected_content_version": expected,
        "p_group_caps": group_caps,
        "p_plant_caps": resolved,
    })
    if err:
        return err

    # The operation returns plant capabilities keyed by plant id; the client
    # speaks codes, so translate back on the way out.
    payload = result.data or {}
    by_id = {str(p["id"]): p["plant_code"] for p in plants}
    payload["plant_capabilities"] = {
        by_id.get(pid, pid): keys
        for pid, keys in (payload.get("plant_capabilities") or {}).items()
    }
    return jsonify(payload)


@app.route("/admin/users/<uid>/reset-password", methods=["POST"])
@require_auth
@require_role("admin")
def reset_password(uid):
    data = request.get_json(force=True) or {}
    generated = not data.get("password")
    password  = data.get("password") or secrets.token_urlsafe(9)

    # `uid` is the application identity; the Auth account it maps to is read as
    # the caller, so an administrator cannot reset a password for a row RLS would
    # not show them.
    try:
        app_user_id = int(uid)
    except (TypeError, ValueError):
        return jsonify({"error": "User not found"}), 404

    rows = (get_supabase_for_caller(g.access_token)
            .table("app_users").select("auth_user_id")
            .eq("id", app_user_id).limit(1).execute()).data or []
    if not rows or not rows[0].get("auth_user_id"):
        return jsonify({"error": "User not found"}), 404

    try:
        privileged_client("auth_admin_update_user").auth.admin.update_user_by_id(
            rows[0]["auth_user_id"], {"password": password})
    except Exception:
        return jsonify({"error": "Could not reset password"}), 400

    resp = {"ok": True}
    if generated:
        resp["temp_password"] = password
    return jsonify(resp)


# ═══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    # Local development entry point only. On Vercel the app is served as a
    # WSGI application via api/index.py and this block never runs.
    print("\n" + "=" * 55)
    print("  CFB Quotation Master — Export Server  v2.0")
    print("=" * 55)
    print(f"  Template       : {TEMPLATE_PATH}")
    print(f"  Template found : {os.path.exists(TEMPLATE_PATH)}")
    print(f"  CORS origins   : {', '.join(CORS_ORIGINS)}")
    print(f"  Listening on   : http://localhost:3001")
    print("=" * 55 + "\n")

    app.run(port=3001, debug=False)
