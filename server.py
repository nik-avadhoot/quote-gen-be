"""
CFB Quotation Master — Export Server  (v2.0)
============================================
Stateless Flask API. Its only job is to fill the Excel master template
(AvadhootPacks_Quotation_Master_v7.xlsx) with quote data posted by the frontend and
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
    AvadhootPacks_Quotation_Master_v7.xlsx must sit in the SAME folder as this file.
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
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
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
    invoke_calculation_executor,
    privileged_client,
    resolve_caller,
    update_caller_email,
    verify_current_password,
)
from auth import require_auth, require_group_capability


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
                             "AvadhootPacks_Quotation_Master_v7.xlsx")


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
    master template (AvadhootPacks_Quotation_Master_v7.xlsx), and returns the file
    as a download.
    """
    if not os.path.exists(TEMPLATE_PATH):
        return jsonify({"error": f"Template not found: {TEMPLATE_PATH}"}), 404

    data       = request.get_json(force=True)
    items      = data.get("items",   [])
    rates      = data.get("rates",   [])
    freight    = data.get("freight", {})
    fname      = data.get("filename", "AvadhootPacks_Quote.xlsx")
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
@require_group_capability("administer_users")
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


@app.route("/masters/gsm-values", methods=["GET"])
@require_auth
def list_paper_gsm_values():
    """
    The GSM Master, read as the caller.

    Any authenticated caller may read it: the values populate construction
    layer pickers in Costing and the Construction Library, and a Maker without
    Construction Library rights still has to choose a GSM. Maintenance is the
    governed add/retire/restore operations below (manage_construction_library).

    A refused or missing table (the migration not yet activated here) answers
    MASTER_UNAVAILABLE, never an empty list, so "no GSM values" is never
    presented as the truth.
    """
    try:
        rows = (get_supabase_for_caller(g.access_token)
                .table("paper_gsm_values")
                .select("id, gsm, status, content_version").execute()).data or []
    except APIError as exc:
        app.logger.error("GSM Master read refused: %s %s", exc.code, exc.message)
        return _error("MASTER_UNAVAILABLE")
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("GSM Master read timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    rows.sort(key=lambda r: (r.get("gsm") is None, r.get("gsm") or 0))
    return jsonify({
        "values": rows,
        "can_manage": "manage_construction_library" in (g.caller.get("group_capabilities") or []),
    })


@app.route("/masters/gsm-values", methods=["POST"])
@require_auth
def add_paper_gsm_value():
    """Add one GSM value through public.add_paper_gsm_value only."""
    data = request.get_json(force=True) or {}
    gsm = _int_field(data, "gsm")
    if gsm is None or gsm < 1 or gsm > 2000:
        return _invalid_input("gsm must be a whole number between 1 and 2000")
    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token), "add_paper_gsm_value", {"p_gsm": gsm})
    if err:
        return err
    return jsonify({"id": result.data}), 201


@app.route("/masters/gsm-values/<int:value_id>/status", methods=["POST"])
@require_auth
def set_paper_gsm_value_status(value_id):
    """Retire or restore a GSM value (CAS). The number itself is never edited in place."""
    data = request.get_json(force=True) or {}
    status = data.get("status")
    expected = _int_field(data, "expected_content_version")
    if status not in ("active", "retired"):
        return _invalid_input("status must be active or retired")
    if expected is None or expected < 1:
        return _invalid_input("expected_content_version is required")
    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token), "set_paper_gsm_value_status", {
            "p_id": value_id,
            "p_status": status,
            "p_expected_content_version": expected,
        })
    if err:
        return err
    return jsonify({"ok": True})


@app.route("/masters/pricing-basis-releases", methods=["GET"])
@require_auth
def list_pricing_basis_releases():
    """Read the governed Pricing Basis catalogue as the authenticated caller.

    U3's first vertical slice is deliberately read-only.  The release and every
    supporting component are read with the caller's bearer token, so existing
    RLS remains the authority.  This route exposes no propose/approve/withdraw
    function and never uses the service-role client.

    A caller with no plant_access is refused explicitly.  RLS would otherwise
    turn that denial into an empty release list, which would falsely mean that
    no releases exist.  Supporting reads may legitimately be narrower than the
    release read (the group-wide Sector and Calculation Default masters have
    their own read capabilities), so unavailable component detail is reported
    as partial data rather than fabricated or silently omitted.
    """
    plant_caps = g.caller.get("plant_capabilities") or {}
    has_plant_access = any(
        isinstance(caps, list) and "plant_access" in caps
        for caps in plant_caps.values()
    )
    if not has_plant_access:
        return jsonify({"error": "plant_access capability is required"}), 403

    caller_token = g.access_token
    try:
        releases = (get_supabase_for_caller(caller_token)
                    .table("pricing_basis_releases")
                    .select(
                        "id, plant_id, release_name, effective_from, effective_until, "
                        "is_automatic_default, rate_set_version_id, freight_set_version_id, "
                        "sector_version_id, calculation_default_version_id, status, "
                        "self_approved, created_at, approved_at, withdrawn_at"
                    ).execute()).data or []
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("pricing-basis release read timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise

    # No supporting read can add meaning when no release is visible.  Returning
    # here also keeps the genuine empty state fast in a newly activated project.
    if not releases:
        return jsonify({
            "releases": [],
            "components_partial": False,
            "unavailable_components": [],
            "mutations": "none",
        })

    # Independent supporting reads run with one caller-scoped client each.  A
    # failed or RLS-hidden source never causes a guessed label: the response
    # carries a null component and components_partial=true instead.
    _SUPPORTING_READS = (
        ("plants", "plants", "id, plant_code, name, status"),
        ("rate_sets", "rate_sets", "id, plant_id, name, status"),
        ("rate_versions", "rate_set_versions",
         "id, rate_set_id, plant_id, version_no, status, approved_at, credit_cost_pct"),
        ("rate_entries", "rate_entries",
         "id, rate_set_version_id, plant_id, grade_code, description, price, discount, "
         "freight, interest_pct, effective_material_rate"),
        ("freight_sets", "freight_sets", "id, plant_id, name, status"),
        ("freight_versions", "freight_set_versions",
         "id, freight_set_id, plant_id, version_no, effective_from, status, approved_at"),
        ("freight_entries", "freight_entries",
         "id, freight_set_version_id, plant_id, origin_plant_id, "
         "destination_location_id, rate"),
        ("customer_locations", "customer_locations",
         "id, party_id, location_code, ship_to_eligible, status"),
        ("parties", "parties",
         "id, customer_code, display_name, lifecycle_state, status"),
        ("sectors", "sectors", "id, sector_code, name, status"),
        ("sector_versions", "sector_versions",
         "id, sector_id, version_no, waste_cbb_pct, waste_pp_pct, conv_box_rate, "
         "conv_pp_rate, margin_pct, status, approved_at"),
        ("calculation_defaults", "calculation_default_versions",
         "id, version_no, annual_interest_pct, day_count_basis, interest_fallback_pct, "
         "waste_cbb_fallback_pct, waste_pp_fallback_pct, conv_box_fallback_rate, "
         "conv_pp_fallback_rate, margin_fallback_pct, rounding_step, engine_version, "
         "rounding_rule_version, status, approved_at"),
    )

    def _read_supporting(spec):
        key, table, cols = spec
        try:
            rows = (new_caller_client(caller_token)
                    .table(table).select(cols).execute()).data or []
            return key, rows, False
        except Exception as exc:  # noqa: BLE001 - an honest partial read is usable
            app.logger.warning("pricing-basis supporting read failed (%s): %s", table, exc)
            return key, [], True

    with timed("pricing_basis.supporting_reads_parallel"):
        with ThreadPoolExecutor(max_workers=len(_SUPPORTING_READS)) as pool:
            support_results = list(pool.map(_read_supporting, _SUPPORTING_READS))

    supporting = {key: rows for key, rows, _failed in support_results}
    failed_sources = {key for key, _rows, failed in support_results if failed}

    def _by_id(key):
        return {row["id"]: row for row in supporting.get(key, [])}

    plants = _by_id("plants")
    rate_sets = _by_id("rate_sets")
    rate_versions = _by_id("rate_versions")
    rate_entries = supporting.get("rate_entries", [])
    freight_sets = _by_id("freight_sets")
    freight_versions = _by_id("freight_versions")
    freight_entries = supporting.get("freight_entries", [])
    customer_locations = _by_id("customer_locations")
    parties = _by_id("parties")
    sectors = _by_id("sectors")
    sector_versions = _by_id("sector_versions")
    calculation_defaults = _by_id("calculation_defaults")

    def _plant_identity(plant_id):
        plant = plants.get(plant_id)
        return ({
            "id": plant["id"], "plant_code": plant.get("plant_code"),
            "name": plant.get("name"), "status": plant.get("status"),
        } if plant else None)

    def _rate_entry(entry, version):
        exception = entry.get("interest_pct")
        inherited = version.get("credit_cost_pct")
        return {
            "id": entry["id"],
            "grade_code": entry.get("grade_code"),
            "description": entry.get("description"),
            "price": entry.get("price"),
            "discount": entry.get("discount"),
            "freight": entry.get("freight"),
            # Despite the legacy column name, interest_pct is the governed
            # supplier-credit exception.  It remains explicitly upstream of
            # Batch Calculate; only effective_material_rate crosses that boundary.
            "supplier_credit_pct": exception,
            "supplier_credit_source": ("entry_exception"
                                       if exception is not None else "version_default"),
            "effective_supplier_credit_pct": (exception
                                                if exception is not None else inherited),
            "effective_material_rate": entry.get("effective_material_rate"),
        }

    def _rate_version(version):
        entries = [
            _rate_entry(entry, version)
            for entry in rate_entries
            if entry.get("rate_set_version_id") == version.get("id")
        ]
        entries.sort(key=lambda entry: entry.get("grade_code") or "")
        return {
            "id": version["id"],
            "owning_plant": _plant_identity(version.get("plant_id")),
            "version_no": version.get("version_no"),
            "status": version.get("status"),
            "approved_at": version.get("approved_at"),
            "credit_cost_pct": version.get("credit_cost_pct"),
            "entries": entries,
            "entries_available": "rate_entries" not in failed_sources,
        }

    def _freight_entry(entry):
        origin = plants.get(entry.get("origin_plant_id"))
        destination = customer_locations.get(entry.get("destination_location_id"))
        party = parties.get(destination.get("party_id")) if destination else None
        try:
            explicit_zero = entry.get("rate") is not None and float(entry.get("rate")) == 0
        except (TypeError, ValueError):
            explicit_zero = False
        return {
            "id": entry["id"],
            "origin_plant": ({
                "id": origin["id"], "plant_code": origin.get("plant_code"),
                "name": origin.get("name"), "status": origin.get("status"),
            } if origin else None),
            "destination": ({
                "id": destination["id"],
                "location_code": destination.get("location_code"),
                "ship_to_eligible": destination.get("ship_to_eligible") is True,
                "status": destination.get("status"),
                "customer": ({
                    "id": party["id"], "customer_code": party.get("customer_code"),
                    "display_name": party.get("display_name"),
                    "lifecycle_state": party.get("lifecycle_state"),
                    "status": party.get("status"),
                } if party else None),
            } if destination else None),
            "rate": entry.get("rate"),
            "explicit_zero": explicit_zero,
            "destination_visible": destination is not None,
        }

    def _freight_version(version):
        entries = [
            _freight_entry(entry)
            for entry in freight_entries
            if entry.get("freight_set_version_id") == version.get("id")
        ]
        entries.sort(key=lambda entry: (
            ((entry.get("origin_plant") or {}).get("plant_code") or ""),
            ((entry.get("destination") or {}).get("location_code") or ""),
        ))
        return {
            "id": version["id"],
            "owning_plant": _plant_identity(version.get("plant_id")),
            "version_no": version.get("version_no"),
            "effective_from": version.get("effective_from"),
            "status": version.get("status"),
            "approved_at": version.get("approved_at"),
            "entries": entries,
            "entries_available": "freight_entries" not in failed_sources,
            "destination_details_partial": any(
                not entry.get("destination_visible") for entry in entries
            ),
            "missing_destinations": ([{
                "id": location["id"],
                "location_code": location.get("location_code"),
                "status": location.get("status"),
                "customer": ({
                    "id": parties[location.get("party_id")]["id"],
                    "customer_code": parties[location.get("party_id")].get("customer_code"),
                    "display_name": parties[location.get("party_id")].get("display_name"),
                    "status": parties[location.get("party_id")].get("status"),
                } if location.get("party_id") in parties else None),
            } for location in customer_locations.values()
              if location.get("status") == "active"
              and location.get("ship_to_eligible") is True
              and location.get("id") not in {
                  entry.get("destination_location_id")
                  for entry in freight_entries
                  if entry.get("freight_set_version_id") == version.get("id")
              }] if "customer_locations" not in failed_sources else []),
            "missing_destinations_available": "customer_locations" not in failed_sources,
        }

    unavailable = set(failed_sources)
    out = []
    for release in releases:
        plant = plants.get(release["plant_id"])
        rate_version = rate_versions.get(release["rate_set_version_id"])
        rate_set = rate_sets.get(rate_version.get("rate_set_id")) if rate_version else None
        freight_version = freight_versions.get(release["freight_set_version_id"])
        freight_set = (freight_sets.get(freight_version.get("freight_set_id"))
                       if freight_version else None)
        sector_version = sector_versions.get(release["sector_version_id"])
        sector = sectors.get(sector_version.get("sector_id")) if sector_version else None
        defaults = calculation_defaults.get(release["calculation_default_version_id"])

        expected = {
            "plants": plant,
            "rate_versions": rate_version,
            "rate_sets": rate_set,
            "freight_versions": freight_version,
            "freight_sets": freight_set,
            "sector_versions": sector_version,
            "sectors": sector,
            "calculation_defaults": defaults,
        }
        unavailable.update(key for key, value in expected.items() if value is None)

        rate_history = []
        if rate_version:
            rate_history = [
                _rate_version(version)
                for version in rate_versions.values()
                if version.get("rate_set_id") == rate_version.get("rate_set_id")
            ]
            rate_history.sort(key=lambda version: version.get("version_no") or 0, reverse=True)
        freight_history = []
        if freight_version:
            freight_history = [
                _freight_version(version)
                for version in freight_versions.values()
                if version.get("freight_set_id") == freight_version.get("freight_set_id")
            ]
            freight_history.sort(key=lambda version: version.get("version_no") or 0, reverse=True)

        rate_detail = _rate_version(rate_version) if rate_version else None
        freight_detail = _freight_version(freight_version) if freight_version else None
        if rate_detail and not rate_detail["entries_available"]:
            unavailable.add("rate_entries")
        if freight_detail and not freight_detail["entries_available"]:
            unavailable.add("freight_entries")
        if freight_detail and freight_detail["destination_details_partial"]:
            unavailable.add("freight_destinations")

        sector_history = []
        if sector_version:
            sector_history = [{
                "id": version["id"],
                "version_no": version.get("version_no"),
                "status": version.get("status"),
                "approved_at": version.get("approved_at"),
            } for version in sector_versions.values()
              if version.get("sector_id") == sector_version.get("sector_id")]
            sector_history.sort(key=lambda version: version.get("version_no") or 0, reverse=True)

        defaults_history = [{
            "id": version["id"],
            "version_no": version.get("version_no"),
            "status": version.get("status"),
            "approved_at": version.get("approved_at"),
        } for version in calculation_defaults.values()]
        defaults_history.sort(key=lambda version: version.get("version_no") or 0, reverse=True)

        out.append({
            "id": release["id"],
            "release_name": release.get("release_name"),
            "status": release.get("status"),
            "effective_from": release.get("effective_from"),
            "effective_until": release.get("effective_until"),
            "is_automatic_default": release.get("is_automatic_default") is True,
            "self_approved": release.get("self_approved") is True,
            "created_at": release.get("created_at"),
            "approved_at": release.get("approved_at"),
            "withdrawn_at": release.get("withdrawn_at"),
            "plant": ({
                "id": plant["id"], "plant_code": plant.get("plant_code"),
                "name": plant.get("name"), "status": plant.get("status"),
            } if plant else None),
            "components": {
                "rate": ({
                    "id": rate_version["id"], "set_name": rate_set.get("name"),
                    "set_id": rate_set.get("id"),
                    "set_status": rate_set.get("status"),
                    "owning_plant": _plant_identity(rate_version.get("plant_id")),
                    "version_no": rate_version.get("version_no"),
                    "status": rate_version.get("status"),
                    "approved": rate_version.get("approved_at") is not None,
                    "approved_at": rate_version.get("approved_at"),
                    "credit_cost_pct": rate_version.get("credit_cost_pct"),
                    "entries": rate_detail["entries"],
                    "entries_available": rate_detail["entries_available"],
                    "history": rate_history,
                } if rate_version and rate_set else None),
                "freight": ({
                    "id": freight_version["id"], "set_name": freight_set.get("name"),
                    "set_id": freight_set.get("id"),
                    "set_status": freight_set.get("status"),
                    "owning_plant": _plant_identity(freight_version.get("plant_id")),
                    "version_no": freight_version.get("version_no"),
                    "effective_from": freight_version.get("effective_from"),
                    "status": freight_version.get("status"),
                    "approved": freight_version.get("approved_at") is not None,
                    "approved_at": freight_version.get("approved_at"),
                    "entries": freight_detail["entries"],
                    "entries_available": freight_detail["entries_available"],
                    "destination_details_partial": freight_detail["destination_details_partial"],
                    "missing_destinations": freight_detail["missing_destinations"],
                    "missing_destinations_available": freight_detail["missing_destinations_available"],
                    "history": freight_history,
                } if freight_version and freight_set else None),
                "sector": ({
                    "id": sector_version["id"], "sector_code": sector.get("sector_code"),
                    "sector_id": sector.get("id"),
                    "name": sector.get("name"), "version_no": sector_version.get("version_no"),
                    "waste_cbb_pct": sector_version.get("waste_cbb_pct"),
                    "waste_pp_pct": sector_version.get("waste_pp_pct"),
                    "conv_box_rate": sector_version.get("conv_box_rate"),
                    "conv_pp_rate": sector_version.get("conv_pp_rate"),
                    "margin_pct": sector_version.get("margin_pct"),
                    "status": sector_version.get("status"),
                    "approved": sector_version.get("approved_at") is not None,
                    "approved_at": sector_version.get("approved_at"),
                    "history": sector_history,
                } if sector_version and sector else None),
                "calculation_defaults": ({
                    "id": defaults["id"], "version_no": defaults.get("version_no"),
                    "annual_interest_pct": defaults.get("annual_interest_pct"),
                    "day_count_basis": defaults.get("day_count_basis"),
                    "interest_fallback_pct": defaults.get("interest_fallback_pct"),
                    "waste_cbb_fallback_pct": defaults.get("waste_cbb_fallback_pct"),
                    "waste_pp_fallback_pct": defaults.get("waste_pp_fallback_pct"),
                    "conv_box_fallback_rate": defaults.get("conv_box_fallback_rate"),
                    "conv_pp_fallback_rate": defaults.get("conv_pp_fallback_rate"),
                    "margin_fallback_pct": defaults.get("margin_fallback_pct"),
                    "rounding_step": defaults.get("rounding_step"),
                    "engine_version": defaults.get("engine_version"),
                    "rounding_rule_version": defaults.get("rounding_rule_version"),
                    "status": defaults.get("status"),
                    "approved": defaults.get("approved_at") is not None,
                    "approved_at": defaults.get("approved_at"),
                    "history": defaults_history,
                } if defaults else None),
            },
        })

    out.sort(key=lambda r: (
        (r.get("plant") or {}).get("plant_code") or "",
        r.get("effective_from") or "",
        r.get("release_name") or "",
    ), reverse=True)
    return jsonify({
        "releases": out,
        "components_partial": bool(unavailable),
        "unavailable_components": sorted(unavailable),
        "mutations": "none",
    })


@app.route("/masters/constructions", methods=["GET"])
@require_auth
def list_constructions():
    """
    The Construction Library, read as the caller (U2, first read-only slice).

    NOT the Producing Plants pattern. Producing Plants is broadly readable;
    this master is gated on the GROUP capability `read_construction_library`,
    which S4-5 proved a Maker does not hold - FA-6: a Maker cannot "read back
    the version they just wrote". So the access-denied state is the PRIMARY
    case here, not an edge case, and it is answered explicitly:

        RLS alone would return an EMPTY LIST to a caller without the
        capability. An empty list says "no constructions exist", which is a
        different and false statement. `require_auth` has already resolved the
        caller's group capabilities into `g.caller`, at no extra query cost, so
        the check below runs first and returns 403. Genuine access denial is
        never presented as absence of data - the same rule the Customer
        Families route states.

    THREE READS, THREE DIFFERENT GATES, and that asymmetry is the design:

        constructions          has_group_cap('read_construction_library')
        construction_versions  has_group_cap('read_construction_library')
        plant_construction_adoptions
                               has_plant_cap(plant_id, 'plant_access')

    Adoption is therefore visible for the caller's OWN plants only. The 403
    above means an adoption row can never appear beside a construction the
    caller cannot see; additionally the adoptions are joined in memory to the
    versions actually returned, and any orphan is dropped rather than rendered
    as a bare construction_version_id.

    PLANT IDENTITY IS NOT INVENTED HERE. These reads obtain plant_id and
    nothing else about a plant. The frontend joins names from the separately
    loaded, already-governed `/masters/plants` response rather than this route
    claiming a relationship its own reads do not establish. An adoption whose
    plant is not in that response is shown as another plant, never as a
    fabricated name.

    ACTOR ATTRIBUTION IS WITHHELD. `created_by`, `adopted_by` and `approved_by`
    are FKs to app_users and are not selected, following the U1 external-
    references precedent: a read-only master screen discloses no operator
    identity. `approved_at` is read only to derive a boolean.

    READ-ONLY. No propose, approve, publish, adopt, withdraw or merge operation
    is exposed by this route. Those `app_private.*` operations exist and stay
    unreachable from here. No service-role client, no privileged read: every
    query below carries the caller's own token and RLS remains the authority.
    """
    if "read_construction_library" not in (g.caller.get("group_capabilities") or []):
        return jsonify({"error": "read_construction_library capability is required"}), 403

    # The two REQUIRED reads and the one OPTIONAL read are separated on purpose:
    # a failure of the optional one degrades the screen, a failure of a required
    # one is an error. They must never be conflated (see adoptions_partial).
    _REQUIRED = (
        ("constructions", "constructions",
         "id, construction_code, name, status, surviving_construction_id"),
        # The compact technical stack that DISTINGUISHES immutable versions: ply,
        # flutes, board GSM and the five layer code/GSM pairs. This is not the
        # deferred full Specification Reference - that is a separate, much wider
        # field-classification exercise and is not started here.
        ("versions", "construction_versions",
         "id, construction_id, version_no, ply, flute_f1, flute_f2, board_gsm, effective_from, "
         "layer_top_code, layer_top_gsm, layer_f1_code, layer_f1_gsm, layer_l1_code, layer_l1_gsm, "
         "layer_f2_code, layer_f2_gsm, layer_l2_code, layer_l2_gsm, approved_at"),
    )

    caller_token = g.access_token

    def _read(spec):
        key, table, cols = spec
        worker_client = new_caller_client(caller_token)
        return key, (worker_client.table(table).select(cols).execute()).data or []

    try:
        with timed("constructions.master_reads_parallel"):
            with ThreadPoolExecutor(max_workers=len(_REQUIRED)) as pool:
                results = dict(pool.map(_read, _REQUIRED))
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("constructions read timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise

    # OPTIONAL. adoptions_partial is true ONLY when this read FAILED. It is
    # false when the read succeeded, including when RLS legitimately returned
    # zero caller-visible rows - "you have no adopting plants" is an answer, not
    # a partial result. A failure of either REQUIRED read above never reaches
    # here, so it can never be reported as partial success.
    adoptions, adoptions_partial = [], False
    try:
        adoptions = (new_caller_client(caller_token)
                     .table("plant_construction_adoptions")
                     .select("id, plant_id, construction_version_id, status")
                     .execute()).data or []
    except Exception as exc:  # noqa: BLE001 - degrade, never fail the screen
        app.logger.warning("construction adoptions read failed (degrading): %s", exc)
        adoptions_partial = True

    constructions = results["constructions"]
    versions = results["versions"]

    version_ids = {v["id"] for v in versions}
    by_version = {}
    for a in adoptions:
        # Orphan drop: an adoption pointing at a version this caller cannot read
        # is not rendered as a bare identifier.
        if a["construction_version_id"] in version_ids:
            by_version.setdefault(a["construction_version_id"], []).append(
                {"plant_id": a["plant_id"], "status": a["status"]})

    by_construction = {}
    for v in versions:
        by_construction.setdefault(v["construction_id"], []).append(v)

    out = []
    for c in constructions:
        vs = sorted(by_construction.get(c["id"], []), key=lambda v: v.get("version_no") or 0)
        out.append({
            "id": c["id"],
            "construction_code": c.get("construction_code"),
            "name": c.get("name"),
            "status": c.get("status"),
            "surviving_construction_id": c.get("surviving_construction_id"),
            "versions": [{
                "id": v["id"],
                "version_no": v.get("version_no"),
                "ply": v.get("ply"),
                "flute_f1": v.get("flute_f1"),
                "flute_f2": v.get("flute_f2"),
                "board_gsm": v.get("board_gsm"),
                "effective_from": v.get("effective_from"),
                "layers": [
                    {"layer": "TOP", "code": v.get("layer_top_code"), "gsm": v.get("layer_top_gsm")},
                    {"layer": "F1", "code": v.get("layer_f1_code"), "gsm": v.get("layer_f1_gsm")},
                    {"layer": "L1", "code": v.get("layer_l1_code"), "gsm": v.get("layer_l1_gsm")},
                    {"layer": "F2", "code": v.get("layer_f2_code"), "gsm": v.get("layer_f2_gsm")},
                    {"layer": "L2", "code": v.get("layer_l2_code"), "gsm": v.get("layer_l2_gsm")},
                ],
                # Derived boolean. The timestamp and the approver are not exposed.
                "approved": v.get("approved_at") is not None,
                "adoptions": by_version.get(v["id"], []),
            } for v in vs],
        })

    out.sort(key=lambda c: c.get("construction_code") or c.get("name") or "")
    return jsonify({
        "constructions": out,
        "adoptions_partial": adoptions_partial,
        "mutations": "none",
    })


# ═══════════════════════════════════════════════════════════ U2 SKU Master
#
# Read-only catalogue and detail over the S4-2 Family C SKU tables, read as the
# caller, extended by Canonical Amendment 02: the quotation and costing fields on
# each SKU version (CDM-43) and master SKU Sets with a quantity per member
# (CDM-44). Every read carries the caller's own token; RLS
# (has_plant_cap(plant_id, 'plant_access')) stays the authority and a SKU at a
# plant the caller cannot access is simply absent.
#
# THREE DIFFERENT GATES MEET HERE, and each is answered honestly rather than by
# letting RLS turn a denial into an empty value:
#
#   skus + children + sets   plant_access (any plant)  -> 403 if none held
#   parties / Families /     read_party_master (group) -> not issued without it;
#     customer_locations                                  "not_visible_to_caller"
#   constructions /          read_construction_library -> not issued without it;
#     construction_versions    (group)                    "not_visible_to_caller"
#
# A SKU's party_id and a version's construction_version_id are NOT NULL, so an
# empty customer or construction would be a false statement. The route reports
# the visibility instead, and a failed optional read is "unavailable", never a
# guessed or current-master label.
#
# SCHEMA PENDING. Amendment 02 adds version columns and the SKU Set tables in a
# migration that is activated separately. Until it is, selecting them fails with
# an undefined-column or unknown-table error; the route then reads the S4-2
# columns alone and says so in `schema_pending`, instead of failing the screen or
# presenting fields that have no storage yet as blank values.
#
# NOT RETURNED: actor attribution (created_by / approved_by; approval is a
# derived boolean), and nothing from the production-data backlog, which has no
# storage (CDM-43).
#
# READ-ONLY. No propose, approve, publish, discontinue, set-membership or
# reference write is exposed. No service-role client is used.
# Amendment 04 D4 adds "withdrawn": a proposal that never went live (terminal).
_SKU_STATUSES = ("proposed", "active", "discontinued", "withdrawn")
_SKU_CATALOGUE_LIMIT = 200
_SKU_SEARCH_MAX = 60
_SKU_SEARCH_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._/-")
# One search box, IDENTITY ONLY.
#
# `q` matches identity factors and nothing else: the Plant Item Code, the SKU
# version's Item Name and Item Short Name, the Customer Item Code, SoftComp Code
# and legacy (retired) Plant Item Code external references, and the owning
# Customer's name. Lifecycle, plant,
# portfolio and every specification field keep their own controls and are
# deliberately NOT searched from this box.
#
# Each word must match SOMEWHERE - words narrow, they never widen - so
# "pernod 375" finds a Customer plus a code fragment on the same SKU.
_SKU_SEARCH_MAX_TERMS = 5
_SKU_SEARCH_WORKERS = 8
# Each sub-query is bounded. Reaching a bound is REPORTED, never silent.
_SKU_SEARCH_CANDIDATE_LIMIT = 400
_SKU_SEARCH_PARTY_LIMIT = 200
_SKU_SEARCH_FIELDS = ("plant_item_code", "item_name", "item_short_name",
                      "customer_item_code", "softcomp_code", "legacy_plant_item_code", "customer_name")
# Amendment 02 storage: searched only once that migration is applied.
_SKU_SEARCH_VERSION_FIELDS = ("item_name", "item_short_name")
# The reference kinds that are CODES (CDM-10, Amendment 02 B-05). A retired
# Plant Item Code finds its SKU (Product Owner, 2026-09-16), so
# `legacy_plant_item_code` is searched too. `alias` and `other` are not codes
# and are not searched from this box.
_SKU_SEARCH_REFERENCE_FIELDS = ("customer_item_code", "softcomp_code", "legacy_plant_item_code")
_SKU_COLUMNS = "id, plant_id, party_id, plant_item_code, status, replacement_sku_id, content_version"
# Amendment 03, CDM-45: the SKU's pricing portfolio. Mandatory in the database,
# read-only here, and it CREATES NO PRICING RULE - nothing in this file, the
# costing engine or any rate path reads it to decide a price.
_SKU_PORTFOLIOS = ("Transactional", "Strategic")
_SKU_COLUMNS_WITH_PORTFOLIO = _SKU_COLUMNS + ", pricing_portfolio"
_SKU_VERSION_BASE_COLUMNS = ("id, sku_id, version_no, construction_version_id, is_price_driving, approved_at, "
                             "length_mm, width_mm, height_mm, box_type, ups, spec_bs, spec_bct, spec_ect")
# Amendment 02, CDM-43: quotation and costing fields on the SKU version.
_SKU_QUOTE_FIELDS = ("item_name", "item_short_name", "item_family", "item_group", "print_quality",
                     "print_technology", "number_of_colours", "colour_detail", "cobb_value",
                     "stated_item_gsm", "item_weight_kg", "stated_cs", "stated_bs", "stated_ect",
                     "customer_spec_version")
_SKU_SPECIFICATION_KEYS = ("length_mm", "width_mm", "height_mm", "box_type", "ups", "spec_bs", "spec_bct", "spec_ect")
# Undefined column, undefined table, and PostgREST's schema-cache forms of both.
_SKU_SCHEMA_PENDING_CODES = frozenset({"42703", "42P01", "PGRST204", "PGRST205"})
_SKU_SET_ROLE_ORDER = {"box": 0, "plate": 1, "partition": 2}
_CONSTRUCTION_VERSION_COLUMNS = (
    "id, construction_id, version_no, ply, flute_f1, flute_f2, board_gsm, approved_at, "
    "layer_top_code, layer_top_gsm, layer_f1_code, layer_f1_gsm, layer_l1_code, layer_l1_gsm, "
    "layer_f2_code, layer_f2_gsm, layer_l2_code, layer_l2_gsm")
_CONSTRUCTION_LAYERS = (("top", "top"), ("flute_1", "f1"), ("back_1", "l1"), ("flute_2", "f2"), ("back_2", "l2"))


def _sku_plant_scope(caller):
    """Plant codes at which the caller holds plant_access (the skus SELECT gate)."""
    return sorted(code for code, caps in ((caller or {}).get("plant_capabilities") or {}).items()
                  if isinstance(caps, list) and "plant_access" in caps)


def _positive_int_arg(args, name):
    raw = (args.get(name) or "").strip()
    if not raw:
        return None, None
    if not raw.isdigit() or int(raw) < 1:
        return None, _invalid_input(f"{name} must be a positive integer")
    return int(raw), None


def _caller_rows(caller_token, table, cols, *filters):
    """One caller-token read. Each filter is (method, *params), e.g. ("eq", "id", 5)."""
    query = new_caller_client(caller_token).table(table).select(cols)
    for method, *params in filters:
        # "not_in_" / "not_is_" negate through PostgREST's `not` modifier.
        target = query.not_ if method.startswith("not_") else query
        query = getattr(target, method[4:] if method.startswith("not_") else method)(*params)
    return query.execute().data or []


def _sku_schema_pending(exc):
    return isinstance(exc, APIError) and str(getattr(exc, "code", "")) in _SKU_SCHEMA_PENDING_CODES


def _read_sku_versions(caller_token, *filters):
    """SKU versions with the Amendment 02 fields, or the S4-2 columns while that migration is pending.

    The version's own compare-and-swap token (Amendment 04) is read when it exists;
    until that migration is applied a row simply carries no `content_version`.
    """
    quote_cols = _SKU_VERSION_BASE_COLUMNS + ", " + ", ".join(_SKU_QUOTE_FIELDS)
    try:
        return _caller_rows(caller_token, "sku_versions", quote_cols + ", content_version", *filters), False
    except Exception as exc:
        if not _sku_schema_pending(exc):
            raise
    try:
        return _caller_rows(caller_token, "sku_versions", quote_cols, *filters), False
    except Exception as exc:
        if not _sku_schema_pending(exc):
            raise
        return _caller_rows(caller_token, "sku_versions", _SKU_VERSION_BASE_COLUMNS, *filters), True


class _SkuPortfolioPending(Exception):
    """The CDM-45 column is not activated AND the request asked to filter on it."""


def _read_skus(caller_token, *filters):
    """SKU rows with the CDM-45 portfolio, or without it while that migration is pending."""
    try:
        return _caller_rows(caller_token, "skus", _SKU_COLUMNS_WITH_PORTFOLIO, *filters), False
    except Exception as exc:
        if not _sku_schema_pending(exc):
            raise
        # Dropping the column from the SELECT is honest; dropping a FILTER the
        # caller asked for is not - it would answer a different question and
        # look like "no such portfolio". That case is refused instead.
        if any(len(f) > 1 and f[1] == "pricing_portfolio" for f in filters):
            raise _SkuPortfolioPending from exc
        return _caller_rows(caller_token, "skus", _SKU_COLUMNS, *filters), True


def _sku_portfolio(sku, pending):
    # None means "no storage yet", which is different from a stored value.
    return None if pending else sku.get("pricing_portfolio")


def _sku_quote_fields(version, pending):
    # None means "no storage yet", which is different from a stored blank.
    return None if pending else {k: version.get(k) for k in _SKU_QUOTE_FIELDS}


def _sku_party_detail(caller, caller_token, party_ids):
    """Customer and current Family for SKU owners, plus how visible they are.

    plant_access does not imply read_party_master. Without it the reads are not
    issued at all, because RLS would answer "no customer" for a SKU whose
    party_id is NOT NULL.
    """
    if "read_party_master" not in (caller.get("group_capabilities") or []):
        return {}, {}, "not_visible_to_caller"
    if not party_ids:
        return {}, {}, "visible"
    ids = sorted(party_ids)
    try:
        parties = _caller_rows(caller_token, "parties",
                               "id, customer_code, display_name, lifecycle_state, status",
                               ("in_", "id", ids))
        memberships = _caller_rows(caller_token, "party_family_memberships", "party_id, family_id",
                                   ("in_", "party_id", ids), ("eq", "is_current", True))
        family_ids = sorted({m["family_id"] for m in memberships})
        families = (_caller_rows(caller_token, "customer_families",
                                 "id, group_customer_code, name, status", ("in_", "id", family_ids))
                    if family_ids else [])
    except Exception as exc:  # noqa: BLE001 - optional detail degrades, never fails the SKU read
        app.logger.warning("SKU party detail read failed (degrading): %s", exc)
        return {}, {}, "unavailable"
    family_by_id = {f["id"]: f for f in families}
    family_by_party = {m["party_id"]: family_by_id.get(m["family_id"]) for m in memberships}
    return {p["id"]: p for p in parties}, family_by_party, "visible"


def _sku_construction_detail(caller, caller_token, cv_ids):
    """Exact Construction version identity and board layers, keyed by construction_version_id."""
    if "read_construction_library" not in (caller.get("group_capabilities") or []):
        return {}, "not_visible_to_caller"
    ids = sorted(i for i in cv_ids if i)
    if not ids:
        return {}, "visible"
    try:
        versions = _caller_rows(caller_token, "construction_versions", _CONSTRUCTION_VERSION_COLUMNS, ("in_", "id", ids))
        con_ids = sorted({v["construction_id"] for v in versions})
        cons = (_caller_rows(caller_token, "constructions", "id, construction_code, name, status", ("in_", "id", con_ids))
                if con_ids else [])
    except Exception as exc:  # noqa: BLE001
        app.logger.warning("SKU construction detail read failed (degrading): %s", exc)
        return {}, "unavailable"
    con_by_id = {c["id"]: c for c in cons}
    out = {}
    for v in versions:
        con = con_by_id.get(v.get("construction_id")) or {}
        out[v["id"]] = {
            "construction_id": v.get("construction_id"),
            "construction_code": con.get("construction_code"), "name": con.get("name"),
            "construction_status": con.get("status"), "version_no": v.get("version_no"),
            "ply": v.get("ply"), "flute_f1": v.get("flute_f1"), "flute_f2": v.get("flute_f2"),
            "board_gsm": v.get("board_gsm"), "approved": v.get("approved_at") is not None,
            "layers": {name: {"bf": v.get(f"layer_{key}_code"), "gsm": v.get(f"layer_{key}_gsm")}
                       for name, key in _CONSTRUCTION_LAYERS},
        }
    return out, "visible"


def _sku_references(caller_token, sku_ids):
    """Active external references grouped by SKU and kind."""
    if not sku_ids:
        return {}, "visible"
    try:
        refs = _caller_rows(caller_token, "sku_external_references", "id, sku_id, reference_kind, reference_value, status",
                            ("in_", "sku_id", sorted(sku_ids)), ("order", "id"))
    except Exception as exc:  # noqa: BLE001
        app.logger.warning("SKU reference read failed (degrading): %s", exc)
        return {}, "unavailable"
    out = {}
    for r in refs:
        if r.get("status") == "active":
            out.setdefault(r["sku_id"], {}).setdefault(r.get("reference_kind"), []).append(r.get("reference_value"))
    return out, "visible"


def _sku_locations(caller, caller_token, sku_ids):
    """Location applicability per SKU; Location codes only with read_party_master."""
    if not sku_ids:
        return {}, "visible"
    try:
        apps = _caller_rows(caller_token, "sku_location_applicabilities", "id, sku_id, location_id, scope, status",
                            ("in_", "sku_id", sorted(sku_ids)), ("order", "id"))
    except Exception as exc:  # noqa: BLE001
        app.logger.warning("SKU applicability read failed (degrading): %s", exc)
        return {}, "unavailable"
    codes, visibility = {}, "not_visible_to_caller"
    if "read_party_master" in (caller.get("group_capabilities") or []):
        visibility = "visible"
        loc_ids = sorted({a["location_id"] for a in apps})
        if loc_ids:
            try:
                codes = {l["id"]: l.get("location_code") for l in _caller_rows(
                    caller_token, "customer_locations", "id, location_code", ("in_", "id", loc_ids))}
            except Exception as exc:  # noqa: BLE001
                app.logger.warning("SKU location code read failed (degrading): %s", exc)
                visibility = "unavailable"
    out = {}
    for a in apps:
        out.setdefault(a["sku_id"], []).append({
            "location_id": a.get("location_id"), "location_code": codes.get(a.get("location_id")),
            "scope": a.get("scope"), "status": a.get("status")})
    return out, visibility


def _sku_sets(caller_token, sku_ids):
    """Master SKU Sets these SKUs belong to, each with every caller-visible member (CDM-44)."""
    if not sku_ids:
        return {}, "visible"
    try:
        mine = _caller_rows(caller_token, "sku_set_members", "id, set_id, sku_id, role, qty_per_set, status",
                            ("in_", "sku_id", sorted(sku_ids)))
        set_ids = sorted({m["set_id"] for m in mine})
        if not set_ids:
            return {}, "visible"
        sets = _caller_rows(caller_token, "sku_sets", "id, set_label, status, content_version", ("in_", "id", set_ids))
        members = _caller_rows(caller_token, "sku_set_members", "id, set_id, sku_id, role, qty_per_set, status",
                               ("in_", "set_id", set_ids))
        member_sku_ids = sorted({m["sku_id"] for m in members})
        member_skus = (_caller_rows(caller_token, "skus", "id, plant_item_code, status", ("in_", "id", member_sku_ids))
                       if member_sku_ids else [])
    except Exception as exc:  # noqa: BLE001
        if _sku_schema_pending(exc):
            return {}, "schema_pending"
        app.logger.warning("SKU Set read failed (degrading): %s", exc)
        return {}, "unavailable"
    set_by_id = {s["id"]: s for s in sets}
    sku_by_id = {s["id"]: s for s in member_skus}
    out = {}
    for m in mine:
        s = set_by_id.get(m["set_id"])
        if s is None:
            continue
        siblings = sorted((x for x in members if x["set_id"] == s["id"]),
                          key=lambda x: (_SKU_SET_ROLE_ORDER.get(x.get("role"), 9), x.get("id") or 0))
        out.setdefault(m["sku_id"], []).append({
            "id": s["id"], "label": s.get("set_label"), "status": s.get("status"),
            "role": m.get("role"), "qty_per_set": m.get("qty_per_set"), "member_status": m.get("status"),
            "members": [{
                "sku_id": x["sku_id"],
                "plant_item_code": (sku_by_id.get(x["sku_id"]) or {}).get("plant_item_code"),
                "sku_status": (sku_by_id.get(x["sku_id"]) or {}).get("status"),
                "sku_visible": x["sku_id"] in sku_by_id,
                "role": x.get("role"), "qty_per_set": x.get("qty_per_set"), "status": x.get("status"),
            } for x in siblings],
        })
    return out, "visible"


def _sku_plant(plant):
    return ({"id": plant["id"], "plant_code": plant.get("plant_code"), "name": plant.get("name")}
            if plant else None)


def _sku_read_error(exc, what):
    if isinstance(exc, APIError) and exc.code == "42501":
        return _error("CAPABILITY_REQUIRED")
    if _is_upstream_timeout(exc):
        app.logger.error("%s timed out upstream: %s", what, exc)
        return _error("UPSTREAM_TIMEOUT")
    return None


def _sku_search_terms(search):
    """Whitespace words, de-duplicated case-insensitively, order preserved."""
    seen, terms = set(), []
    for word in (search or "").split():
        key = word.casefold()
        if key not in seen:
            seen.add(key)
            terms.append(word)
    return terms


def _sku_like(term):
    # `_` and `%` are LIKE wildcards; escape them so a code search stays literal.
    return "%" + term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


def _sku_search_field_states(caller):
    """What the one search box can cover for THIS caller, before any read."""
    fields = {name: "searched" for name in _SKU_SEARCH_FIELDS}
    if "read_party_master" not in (caller.get("group_capabilities") or []):
        fields["customer_name"] = "not_visible_to_caller"
    return fields


def _sku_search_candidates(caller, caller_token, terms, plant_ids, scope_filters):
    """Resolve an identity search to SKU ids, entirely in the database.

    CALLER-SCOPED BY CONSTRUCTION. Every sub-query carries the caller's own
    token AND `plant_id in <the caller's plant_access plants>`, so a row at
    another plant is never loaded, let alone filtered out in memory. The
    Customer-name pass reads party identity only - never SKUs - and then
    re-enters through that same plant-scoped `skus` query.

    HONEST DEGRADATION. `fields` reports what was ACTUALLY searched:

      * `item_name` / `item_short_name` are `schema_pending` until the
        Amendment 02 migration is applied - they have no storage yet, so a SKU
        whose only match would be its name cannot be found, and the screen says
        so instead of reading as "no match";
      * `customer_name` is `not_visible_to_caller` without `read_party_master`,
        because RLS would otherwise answer "no such Customer" and silently drop
        every row a Customer-name word would have matched;
      * any other failed sub-query is `unavailable`.

    Returns (sorted ids, fields, scanned_to_limit). `scanned_to_limit` says a
    bound was reached, so more rows may match than were scanned.
    """
    fields = _sku_search_field_states(caller)

    def _sku_ids(*filters):
        rows = _caller_rows(caller_token, "skus", "id", ("in_", "plant_id", plant_ids), *scope_filters,
                            *filters, ("order", "id"), ("limit", _SKU_SEARCH_CANDIDATE_LIMIT))
        return {r["id"] for r in rows}, len(rows) >= _SKU_SEARCH_CANDIDATE_LIMIT

    def _child_sku_ids(table, *filters):
        rows = _caller_rows(caller_token, table, "sku_id", ("in_", "plant_id", plant_ids),
                            *filters, ("order", "id"), ("limit", _SKU_SEARCH_CANDIDATE_LIMIT))
        return {r["sku_id"] for r in rows}, len(rows) >= _SKU_SEARCH_CANDIDATE_LIMIT

    # A name matches the SKU's LATEST version only - the name the grid shows.
    # Versions and revisions are not part of the search window (ruled
    # 2026-09-16), so an older version's name no longer finds the SKU.
    def _latest_version_sku_ids(field, like):
        rows = _caller_rows(caller_token, "sku_versions", "id, sku_id", ("in_", "plant_id", plant_ids),
                            ("ilike", field, like), ("order", "id"), ("limit", _SKU_SEARCH_CANDIDATE_LIMIT))
        ids, more = _sku_latest_version_match(caller_token, plant_ids, rows)
        return ids, len(rows) >= _SKU_SEARCH_CANDIDATE_LIMIT or more

    def _run(item):
        term, field = item
        like = _sku_like(term)
        try:
            if field == "plant_item_code":
                return item, _sku_ids(("ilike", "plant_item_code", like))
            if field in _SKU_SEARCH_VERSION_FIELDS:
                return item, _latest_version_sku_ids(field, like)
            if field in _SKU_SEARCH_REFERENCE_FIELDS:
                return item, _child_sku_ids("sku_external_references",
                                            ("eq", "reference_kind", field), ("eq", "status", "active"),
                                            ("ilike", "reference_value", like))
            parties = _caller_rows(caller_token, "parties", "id", ("ilike", "display_name", like),
                                   ("order", "id"), ("limit", _SKU_SEARCH_PARTY_LIMIT))
            capped = len(parties) >= _SKU_SEARCH_PARTY_LIMIT
            if not parties:
                return item, (set(), capped)
            ids, more = _sku_ids(("in_", "party_id", [p["id"] for p in parties]))
            return item, (ids, capped or more)
        except Exception as exc:  # noqa: BLE001 - classified by the caller, below
            return item, exc

    work = [(t, f) for t in terms for f in _SKU_SEARCH_FIELDS if fields[f] == "searched"]
    results = {}
    if work:
        with timed("skus.identity_search_parallel"):
            with ThreadPoolExecutor(max_workers=min(len(work), _SKU_SEARCH_WORKERS)) as pool:
                results = dict(pool.map(_run, work))

    # Classify failures FIRST, so a field that has no storage, or could not be
    # read, is excluded from EVERY term rather than silently narrowing one.
    for (_term, field), outcome in results.items():
        if not isinstance(outcome, Exception):
            continue
        if _sku_schema_pending(outcome) and field in _SKU_SEARCH_VERSION_FIELDS:
            fields[field] = "schema_pending"
        elif _sku_read_error(outcome, "SKU identity search") is not None:
            raise outcome
        else:
            app.logger.warning("SKU identity search on %s failed (degrading): %s", field, outcome)
            fields[field] = "unavailable"

    scanned, per_term = False, []
    for term in terms:
        ids = set()
        for field in _SKU_SEARCH_FIELDS:
            if fields[field] != "searched":
                continue
            outcome = results.get((term, field))
            if isinstance(outcome, tuple):
                ids |= outcome[0]
                scanned = scanned or outcome[1]
        per_term.append(ids)
    matched = set.intersection(*per_term) if per_term else set()
    return sorted(matched), fields, scanned


# ── Column-header filters (Product Owner rulings, 2026-09-16) ─────────────────
#
# Each grid column can be filtered from its header, Excel-style, and every
# filter is applied IN THE DATABASE and AS THE CALLER:
#
#   * every sub-query carries the caller's own token and
#     `plant_id in <the caller's plant_access plants>`, exactly like the
#     identity box, so no other plant's or tenant's row is ever loaded;
#   * a version field matches the SKU's LATEST version only - the value the
#     grid shows - never an older one (ruled);
#   * a field whose storage is not activated is refused with
#     SCHEMA_ACTIVATION_PENDING rather than silently ignored, and a field the
#     caller may not read is refused CAPABILITY_REQUIRED before any read;
#   * every sub-query is capped, and reaching a cap is REPORTED per filter.
#
# A filter composes with the identity box by AND. The box stays identity-only.
# `f=<field>:<op>:<value>` is repeated once per filter. Values for `in` are
# separated by `|`; `between` is `min,max` with either side optional.
_SKU_FILTER_MAX = 8
_SKU_FILTER_VALUE_MAX = 60
_SKU_FILTER_VALUE_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._/-,|+")
_SKU_FILTER_LIMIT = 400
_SKU_FILTER_PARTY_LIMIT = 200
_SKU_FILTER_VERSION_LIMIT = 2000
_SKU_PRINT_TECHNOLOGIES = ("Flexo", "CMYK", "Offset", "Unprinted")
_TEXT_OPS = ("contains", "blank", "not_blank")
_NUMBER_OPS = ("between", "blank", "not_blank")


def _filter_spec(kind, ftype, ops, **extra):
    return {"kind": kind, "type": ftype, "ops": ops, **extra}


_SKU_COLUMN_FILTERS = {
    # skus row
    "plant_item_code": _filter_spec("sku", "text", _TEXT_OPS, column="plant_item_code"),
    "status": _filter_spec("sku", "enum", ("in",), column="status", values=_SKU_STATUSES),
    "pricing_portfolio": _filter_spec("sku", "enum", ("in",), column="pricing_portfolio", values=_SKU_PORTFOLIOS),
    # active external references of one kind
    "customer_item_code": _filter_spec("reference", "text", _TEXT_OPS),
    "softcomp_code": _filter_spec("reference", "text", _TEXT_OPS, pending="amendment_02"),
    # group-gated masters
    "customer": _filter_spec("customer", "text", ("contains",), capability="read_party_master"),
    "location_code": _filter_spec("location", "text", _TEXT_OPS, capability="read_party_master"),
    # the latest SKU version (S4-2 storage)
    **{name: _filter_spec("version", "number", _NUMBER_OPS, column=name)
       for name in ("length_mm", "width_mm", "height_mm", "ups")},
    # the latest SKU version (Amendment 02 storage)
    **{name: _filter_spec("version", "text", _TEXT_OPS, column=name, pending="amendment_02")
       for name in ("item_name", "item_short_name", "item_family", "item_group", "print_quality",
                    "colour_detail", "cobb_value", "stated_item_gsm", "stated_cs", "stated_bs",
                    "stated_ect", "customer_spec_version")},
    "print_technology": _filter_spec("version", "enum", ("in", "blank", "not_blank"), column="print_technology",
                                     values=_SKU_PRINT_TECHNOLOGIES, pending="amendment_02"),
    "number_of_colours": _filter_spec("version", "number", _NUMBER_OPS, column="number_of_colours",
                                      pending="amendment_02"),
    "item_weight_kg": _filter_spec("version", "number", _NUMBER_OPS, column="item_weight_kg",
                                   pending="amendment_02"),
    # the latest version's Construction version
    "ply": _filter_spec("construction", "number", _NUMBER_OPS, column="ply",
                        capability="read_construction_library"),
    **{name: _filter_spec("construction", "text", _TEXT_OPS, column=name, capability="read_construction_library")
       for name in ("flute_f1", "flute_f2", "layer_top_code", "layer_f1_code", "layer_l1_code",
                    "layer_f2_code", "layer_l2_code")},
    **{name: _filter_spec("construction", "number", _NUMBER_OPS, column=name,
                          capability="read_construction_library")
       for name in ("layer_top_gsm", "layer_f1_gsm", "layer_l1_gsm", "layer_f2_gsm", "layer_l2_gsm")},
}


class _SkuFilterPending(Exception):
    """A column filter asked for a field whose storage is not activated."""


def _parse_number(raw):
    raw = raw.strip()
    if raw == "":
        return None
    try:
        return float(raw)
    except ValueError:
        raise ValueError("not a number") from None


def _sku_parse_column_filters(raw_filters, caller):
    """Validate every `f` parameter before any read. Returns (filters, error_response)."""
    if len(raw_filters) > _SKU_FILTER_MAX:
        return None, _invalid_input(f"at most {_SKU_FILTER_MAX} column filters")
    parsed, seen = [], set()
    group_caps = caller.get("group_capabilities") or []
    for raw in raw_filters:
        parts = (raw or "").split(":", 2)
        if len(parts) < 2:
            return None, _invalid_input("f must be field:operator[:value]")
        field, op = parts[0].strip(), parts[1].strip()
        value = parts[2] if len(parts) == 3 else ""
        spec = _SKU_COLUMN_FILTERS.get(field)
        if spec is None:
            return None, _invalid_input(f"{field or 'that field'} cannot be filtered")
        if op not in spec["ops"]:
            return None, _invalid_input(f"{field} does not support {op or 'an empty operator'}")
        if field in seen:
            return None, _invalid_input(f"{field} is filtered more than once")
        seen.add(field)
        if len(value) > _SKU_FILTER_VALUE_MAX or not set(value) <= _SKU_FILTER_VALUE_CHARS:
            return None, _invalid_input("filter values are at most 60 letters, digits, spaces or . _ / - , | + characters")
        item = {"field": field, "op": op, "value": None}
        if op == "contains":
            if not value.strip():
                return None, _invalid_input(f"{field} contains needs a value")
            item["value"] = value.strip()
        elif op == "in":
            values = [v.strip() for v in value.split("|") if v.strip()]
            allowed = spec.get("values") or ()
            if not values or any(v not in allowed for v in values):
                return None, _invalid_input(f"{field} accepts only {', '.join(allowed)}")
            item["value"] = sorted(set(values), key=values.index)
        elif op == "between":
            bounds = value.split(",")
            try:
                low, high = (_parse_number(bounds[0]), _parse_number(bounds[1])) if len(bounds) == 2 else (None, None)
            except ValueError:
                return None, _invalid_input(f"{field} between needs numbers")
            if len(bounds) != 2 or (low is None and high is None) or (
                    low is not None and high is not None and low > high):
                return None, _invalid_input(f"{field} between needs min,max with at least one bound")
            item["value"] = [low, high]
        elif value.strip():
            return None, _invalid_input(f"{field} {op} takes no value")
        # Refused before any read: RLS would otherwise turn "you may not read
        # this master" into "nothing matches".
        if spec.get("capability") and spec["capability"] not in group_caps:
            return None, _error("CAPABILITY_REQUIRED",
                                f"{spec['capability']} capability is required to filter by {field}")
        parsed.append(item)
    return parsed, None


def _sku_value_filters(column, op, value):
    """The database filter tuples for one operator on one column."""
    if op == "contains":
        return [("ilike", column, _sku_like(value))]
    if op == "in":
        return [("in_", column, value)]
    if op == "between":
        low, high = value
        return ([("gte", column, low)] if low is not None else []) + (
            [("lte", column, high)] if high is not None else [])
    if op == "blank":
        return [("is_", column, "null")]
    return [("not_is_", column, "null")]


def _sku_latest_version_match(token, plant_ids, version_rows):
    """SKU ids whose LATEST version is one of `version_rows` (id, sku_id).

    Reads only the version numbers of the SKUs already matched, inside the
    caller's plants, capped. Returns (sku ids, capped)."""
    matched_versions = {r["id"] for r in version_rows}
    sku_ids = sorted({r["sku_id"] for r in version_rows})
    if not sku_ids:
        return set(), False
    rows = _caller_rows(token, "sku_versions", "id, sku_id, version_no", ("in_", "plant_id", plant_ids),
                        ("in_", "sku_id", sku_ids), ("order", "id"), ("limit", _SKU_FILTER_VERSION_LIMIT))
    latest = {}
    for r in rows:
        best = latest.get(r["sku_id"])
        if best is None or (r.get("version_no") or 0) > (best.get("version_no") or 0):
            latest[r["sku_id"]] = r
    return ({sid for sid, r in latest.items() if r["id"] in matched_versions},
            len(rows) >= _SKU_FILTER_VERSION_LIMIT)


def _sku_amendment_02_active(token, plant_ids):
    try:
        _caller_rows(token, "sku_versions", "item_name", ("in_", "plant_id", plant_ids), ("limit", 1))
        return True
    except Exception as exc:
        if _sku_schema_pending(exc):
            return False
        raise


def _sku_resolve_column_filters(token, plant_ids, filters):
    """Turn parsed filters into database constraints on the `skus` read.

    Returns (sku_filters, include_ids, exclude_ids, report):
      sku_filters  - tuples applied to the skus query itself;
      include_ids  - None, or the set of SKU ids EVERY child-table filter allows;
      exclude_ids  - SKU ids a "blank" child filter rules out;
      report       - one entry per filter: what was applied and whether a cap was reached.
    """
    sku_filters, include, exclude, report = [], None, set(), []

    def narrow(ids):
        nonlocal include
        include = set(ids) if include is None else include & set(ids)

    for item in filters:
        field, op, value = item["field"], item["op"], item["value"]
        spec = _SKU_COLUMN_FILTERS[field]
        capped = False
        kind = spec["kind"]
        if spec.get("pending") == "amendment_02" and kind == "reference" and not _sku_amendment_02_active(token, plant_ids):
            raise _SkuFilterPending(field)
        if kind == "sku":
            sku_filters += _sku_value_filters(spec["column"], op, value)
        elif kind == "reference":
            flt = [("eq", "reference_kind", field), ("eq", "status", "active")]
            if op == "contains":
                flt.append(("ilike", "reference_value", _sku_like(value)))
            rows = _caller_rows(token, "sku_external_references", "sku_id", ("in_", "plant_id", plant_ids),
                                *flt, ("order", "id"), ("limit", _SKU_FILTER_LIMIT))
            capped = len(rows) >= _SKU_FILTER_LIMIT
            ids = {r["sku_id"] for r in rows}
            if op == "blank":
                exclude |= ids
            else:
                narrow(ids)
        elif kind == "customer":
            parties = _caller_rows(token, "parties", "id", ("ilike", "display_name", _sku_like(value)),
                                   ("order", "id"), ("limit", _SKU_FILTER_PARTY_LIMIT))
            capped = len(parties) >= _SKU_FILTER_PARTY_LIMIT
            sku_filters.append(("in_", "party_id", [p["id"] for p in parties]))
        elif kind == "location":
            flt = []
            if op == "contains":
                locations = _caller_rows(token, "customer_locations", "id",
                                         ("ilike", "location_code", _sku_like(value)),
                                         ("order", "id"), ("limit", _SKU_FILTER_PARTY_LIMIT))
                capped = len(locations) >= _SKU_FILTER_PARTY_LIMIT
                flt.append(("in_", "location_id", [l["id"] for l in locations]))
            rows = _caller_rows(token, "sku_location_applicabilities", "sku_id", ("in_", "plant_id", plant_ids),
                                *flt, ("order", "id"), ("limit", _SKU_FILTER_LIMIT))
            capped = capped or len(rows) >= _SKU_FILTER_LIMIT
            ids = {r["sku_id"] for r in rows}
            if op == "blank":
                exclude |= ids
            else:
                narrow(ids)
        else:
            if kind == "version":
                try:
                    versions = _caller_rows(token, "sku_versions", "id, sku_id", ("in_", "plant_id", plant_ids),
                                            *_sku_value_filters(spec["column"], op, value),
                                            ("order", "id"), ("limit", _SKU_FILTER_LIMIT))
                except Exception as exc:
                    if spec.get("pending") and _sku_schema_pending(exc):
                        raise _SkuFilterPending(field) from exc
                    raise
                capped = len(versions) >= _SKU_FILTER_LIMIT
            else:  # construction: the Construction version first, then the SKU versions that use it
                cvs = _caller_rows(token, "construction_versions", "id",
                                   *_sku_value_filters(spec["column"], op, value),
                                   ("order", "id"), ("limit", _SKU_FILTER_LIMIT))
                capped = len(cvs) >= _SKU_FILTER_LIMIT
                versions = (_caller_rows(token, "sku_versions", "id, sku_id", ("in_", "plant_id", plant_ids),
                                         ("in_", "construction_version_id", [c["id"] for c in cvs]),
                                         ("order", "id"), ("limit", _SKU_FILTER_LIMIT)) if cvs else [])
                capped = capped or len(versions) >= _SKU_FILTER_LIMIT
            ids, more = _sku_latest_version_match(token, plant_ids, versions)
            capped = capped or more
            narrow(ids)
        report.append({"field": field, "op": op, "value": value, "state": "applied", "scan_truncated": capped})
    return sku_filters, include, exclude, report


@app.route("/masters/skus", methods=["GET"])
@require_auth
def list_skus():
    """Bounded, filterable SKU Master catalogue read as the caller (U2, CDM-43/44).

    Filters are applied in the database query, never by loading the tenant and
    filtering in memory: `plant` (a plant code the caller holds plant_access
    at), `status`, `party_id` and `family_id` (both require read_party_master),
    and `q`. The window is capped; `truncated` says when more rows matched than
    were returned. Each row carries its latest version's quote fields,
    Construction identity, references, Location applicability and SKU Sets,
    each with its own visibility.

    `q` IS ONE BOX OVER IDENTITY ONLY - Plant Item Code, Item Name, Item Short
    Name, Customer Item Code, SoftComp Code, legacy Plant Item Code and the
    owning Customer's name.
    Lifecycle, plant, portfolio and specification stay on their own controls.
    Every word must match somewhere, so words narrow the result. `search.fields`
    reports which of those seven were ACTUALLY searched, because Item Name has no
    storage until the Amendment 02 migration is applied and Customer name needs
    `read_party_master`: the box degrades visibly rather than missing rows in
    silence. `search.scan_truncated` says a per-field bound was reached. An
    Item Name or Item Short Name matches the LATEST version only.

    `f` (repeatable) filters one grid column from its header - see
    `_SKU_COLUMN_FILTERS`. Every filter is resolved in the database inside the
    caller's plants, version fields match the latest version, pending storage
    is refused SCHEMA_ACTIVATION_PENDING, and `column_filters` reports each one.
    """
    scope_codes = _sku_plant_scope(g.caller)
    if not scope_codes:
        return _error("CAPABILITY_REQUIRED", "plant_access capability is required")

    args = request.args
    status = (args.get("status") or "").strip() or None
    if status is not None and status not in _SKU_STATUSES:
        return _invalid_input("status must be proposed, active, discontinued or withdrawn")
    plant_code = (args.get("plant") or "").strip() or None
    if plant_code is not None and plant_code not in scope_codes:
        return _error("CAPABILITY_REQUIRED", "plant_access capability is required at the requested plant")
    portfolio = (args.get("portfolio") or "").strip() or None
    if portfolio is not None and portfolio not in _SKU_PORTFOLIOS:
        return _invalid_input("portfolio must be Transactional or Strategic")
    search = (args.get("q") or "").strip() or None
    if search is not None and (len(search) > _SKU_SEARCH_MAX or not set(search) <= _SKU_SEARCH_CHARS):
        return _invalid_input("q must be at most 60 letters, digits, spaces or . _ / - characters")
    terms = _sku_search_terms(search)
    if len(terms) > _SKU_SEARCH_MAX_TERMS:
        return _invalid_input(f"q must be at most {_SKU_SEARCH_MAX_TERMS} words")
    party_id, bad = _positive_int_arg(args, "party_id")
    if bad:
        return bad
    family_id, bad = _positive_int_arg(args, "family_id")
    if bad:
        return bad
    if (party_id or family_id) and "read_party_master" not in (g.caller.get("group_capabilities") or []):
        return _error("CAPABILITY_REQUIRED",
                      "read_party_master capability is required to filter by customer or family")
    column_filters, bad = _sku_parse_column_filters(args.getlist("f"), g.caller)
    if bad:
        return bad

    token = g.access_token
    try:
        plants = _caller_rows(token, "plants", "id, plant_code, name, status",
                              ("in_", "plant_code", [plant_code] if plant_code else scope_codes))
        plant_by_id = {p["id"]: p for p in plants}

        party_filter = None
        if family_id is not None:
            members = _caller_rows(token, "party_family_memberships", "party_id",
                                   ("eq", "family_id", family_id), ("eq", "is_current", True))
            party_filter = {m["party_id"] for m in members}
        if party_id is not None:
            party_filter = {party_id} if party_filter is None else party_filter & {party_id}

        skus, search_ran, search_scanned, portfolio_pending = [], False, False, False
        search_fields = _sku_search_field_states(g.caller)
        filter_report, filter_empty = [], False
        if plant_by_id and party_filter != set() and column_filters:
            column_sku_filters, include_ids, exclude_ids, filter_report = _sku_resolve_column_filters(
                token, sorted(plant_by_id), column_filters)
            filter_empty = include_ids is not None and not (include_ids - exclude_ids)
        if plant_by_id and party_filter != set() and not filter_empty:
            # Status and Customer scope bound the identity search too, so the
            # capped candidate window holds only rows the screen would show.
            scope_filters = []
            if status:
                scope_filters.append(("eq", "status", status))
            if portfolio:
                scope_filters.append(("eq", "pricing_portfolio", portfolio))
            if party_filter is not None:
                scope_filters.append(("in_", "party_id", sorted(party_filter)))
            if column_filters:
                # Column filters bound the identity search too, like status does.
                scope_filters += column_sku_filters
                if include_ids is not None:
                    scope_filters.append(("in_", "id", sorted(include_ids - exclude_ids)))
                elif exclude_ids:
                    scope_filters.append(("not_in_", "id", sorted(exclude_ids)))
            filters = [("in_", "plant_id", sorted(plant_by_id))] + scope_filters
            matched = None
            if terms:
                search_ran = True
                matched, search_fields, search_scanned = _sku_search_candidates(
                    g.caller, token, terms, sorted(plant_by_id), scope_filters)
                filters.append(("in_", "id", matched))
            if matched is None or matched:
                filters += [("order", "id"), ("limit", _SKU_CATALOGUE_LIMIT + 1)]
                skus, portfolio_pending = _read_skus(token, *filters)
        truncated = len(skus) > _SKU_CATALOGUE_LIMIT
        skus = skus[:_SKU_CATALOGUE_LIMIT]

        versions, quote_pending = (_read_sku_versions(token, ("in_", "sku_id", [s["id"] for s in skus]))
                                   if skus else ([], False))
    except _SkuPortfolioPending:
        return _error("SCHEMA_ACTIVATION_PENDING",
                      "The SKU pricing portfolio storage is not activated in this environment yet, "
                      "so the catalogue cannot be filtered by it.")
    except _SkuFilterPending as pending:
        return _error("SCHEMA_ACTIVATION_PENDING",
                      f"The storage for {pending.args[0]} is not activated in this environment yet, "
                      "so the catalogue cannot be filtered by it.")
    except Exception as exc:
        handled = _sku_read_error(exc, "SKU catalogue read")
        if handled is not None:
            return handled
        raise

    versions_by_sku = {}
    for v in versions:
        versions_by_sku.setdefault(v["sku_id"], []).append(v)
    for vs in versions_by_sku.values():
        vs.sort(key=lambda v: v.get("version_no") or 0)
    sku_ids = [s["id"] for s in skus]
    latest = {sid: vs[-1] for sid, vs in versions_by_sku.items() if vs}

    party_by_id, family_by_party, party_detail = _sku_party_detail(g.caller, token, {s["party_id"] for s in skus})
    constructions, construction_detail = _sku_construction_detail(
        g.caller, token, {v.get("construction_version_id") for v in latest.values()})
    references, reference_detail = _sku_references(token, sku_ids)
    locations, location_detail = _sku_locations(g.caller, token, sku_ids)
    sets, set_detail = _sku_sets(token, sku_ids)
    # Amendment 04: whether the governed operations exist here, so the screen can
    # show its edit controls disabled ("schema activation pending") rather than live.
    governed_pending = False
    try:
        _caller_rows(token, "sku_master_events", "operation", ("limit", 1))
    except Exception as exc:  # noqa: BLE001 - a probe; only "no such table" changes the answer
        governed_pending = _sku_schema_pending(exc)

    rows = []
    for s in skus:
        v = latest.get(s["id"])
        rows.append({
            "id": s["id"],
            "plant_item_code": s.get("plant_item_code"),
            "status": s.get("status"),
            # Recorded only. No pricing is inferred from it (CDM-45, C-04).
            "pricing_portfolio": _sku_portfolio(s, portfolio_pending),
            "replacement_sku_id": s.get("replacement_sku_id"),
            "content_version": s.get("content_version"),
            "plant": _sku_plant(plant_by_id.get(s.get("plant_id"))),
            "party_id": s.get("party_id"),
            "customer": party_by_id.get(s.get("party_id")),
            "family": family_by_party.get(s.get("party_id")),
            "version_count": len(versions_by_sku.get(s["id"], [])),
            # Values pass through untouched: null stays null, 0 stays 0.
            "latest_version": ({
                "id": v["id"],
                "version_no": v.get("version_no"),
                "approved": v.get("approved_at") is not None,
                "is_price_driving": v.get("is_price_driving"),
                "construction_version_id": v.get("construction_version_id"),
                **{k: v.get(k) for k in _SKU_SPECIFICATION_KEYS},
                "quote_fields": _sku_quote_fields(v, quote_pending),
            } if v else None),
            "construction": constructions.get((v or {}).get("construction_version_id")),
            "references": references.get(s["id"], {}) if reference_detail == "visible" else None,
            "locations": locations.get(s["id"], []) if location_detail != "unavailable" else None,
            "sets": sets.get(s["id"], []) if set_detail == "visible" else None,
        })
    rows.sort(key=lambda r: ((r["plant"] or {}).get("plant_code") or "",
                             r["plant_item_code"] is None, r["plant_item_code"] or "", r["id"]))
    return jsonify({
        "skus": rows,
        "truncated": truncated,
        "limit": _SKU_CATALOGUE_LIMIT,
        "filters": {"plant": plant_code, "status": status, "q": search, "portfolio": portfolio,
                    "party_id": party_id, "family_id": family_id},
        # What each column-header filter actually applied on THIS request.
        "column_filters": filter_report,
        # What the one identity box actually covered on THIS request.
        "search": ({"q": search, "terms": terms, "executed": search_ran, "fields": search_fields,
                    "scan_truncated": search_scanned,
                    "degraded": any(state != "searched" for state in search_fields.values())}
                   if terms else None),
        "plant_scope": scope_codes,
        "detail_visibility": {"customer": party_detail, "construction": construction_detail,
                              "references": reference_detail, "locations": location_detail, "sets": set_detail},
        "schema_pending": {"quote_fields": quote_pending, "sku_sets": set_detail == "schema_pending",
                            "pricing_portfolio": portfolio_pending, "governed_operations": governed_pending},
        "mode": "governed_read_only",
        "authority": "caller_token_rls_only",
        "mutations": "none",
    })


@app.route("/masters/skus/<int:sku_id>", methods=["GET"])
@require_auth
def get_sku(sku_id):
    """One SKU with its immutable versions and quote fields, Construction
    identity and layers, external references, Location applicability,
    replacement lineage and SKU Sets, read as the caller (U2, CDM-43/44). A SKU
    the caller cannot see is 404 - RLS makes "absent" and "not visible" the same
    answer, and neither leaks.
    """
    if not _sku_plant_scope(g.caller):
        return _error("CAPABILITY_REQUIRED", "plant_access capability is required")
    group_caps = g.caller.get("group_capabilities") or []
    token = g.access_token

    try:
        found, portfolio_pending = _read_skus(token, ("eq", "id", sku_id), ("limit", 1))
        if not found:
            return _error("RECORD_NOT_FOUND")
        sku = found[0]
        versions, quote_pending = _read_sku_versions(token, ("eq", "sku_id", sku_id), ("order", "version_no"))

        reads = {
            "plants": ("plants", "id, plant_code, name, status", (("eq", "id", sku["plant_id"]),)),
            "references": ("sku_external_references", "id, reference_kind, reference_value, status",
                           (("eq", "sku_id", sku_id), ("order", "id"))),
            "replaces": ("skus", "id, plant_item_code, status",
                         (("eq", "replacement_sku_id", sku_id), ("order", "id"))),
        }
        if sku.get("replacement_sku_id"):
            reads["replacement"] = ("skus", "id, plant_item_code, status",
                                    (("eq", "id", sku["replacement_sku_id"]),))

        def _run(item):
            key, (table, cols, filters) = item
            return key, _caller_rows(token, table, cols, *filters)

        with timed("skus.detail_reads_parallel"):
            with ThreadPoolExecutor(max_workers=len(reads)) as pool:
                results = dict(pool.map(_run, reads.items()))

        applicability_pending = False
        try:
            applicabilities = _caller_rows(
                token, "sku_location_applicabilities",
                "id, location_id, scope, status, approved_at, content_version",
                ("eq", "sku_id", sku_id), ("order", "id"))
        except Exception as exc:
            if not _sku_schema_pending(exc):
                raise
            applicability_pending = True
            applicabilities = _caller_rows(
                token, "sku_location_applicabilities", "id, location_id, scope, status, approved_at",
                ("eq", "sku_id", sku_id), ("order", "id"))
    except Exception as exc:
        handled = _sku_read_error(exc, "SKU detail read")
        if handled is not None:
            return handled
        raise

    cv_ids = sorted({v["construction_version_id"] for v in versions})
    constructions, construction_detail = _sku_construction_detail(g.caller, token, cv_ids)

    adoption_detail, adoptions_by_cv = "visible", {}
    if cv_ids:
        try:
            for a in _caller_rows(token, "plant_construction_adoptions", "construction_version_id, status",
                                  ("eq", "plant_id", sku["plant_id"]), ("in_", "construction_version_id", cv_ids)):
                adoptions_by_cv.setdefault(a["construction_version_id"], []).append(a.get("status"))
        except Exception as exc:  # noqa: BLE001
            app.logger.warning("SKU plant adoption read failed (degrading): %s", exc)
            adoption_detail = "unavailable"

    location_detail, loc_by_id, location_options, can_manage = "not_visible_to_caller", {}, [], False
    if "read_party_master" in group_caps:
        location_detail = "visible"
        try:
            location_options = _caller_rows(
                token, "customer_locations", "id, location_code, status, bill_to_eligible, ship_to_eligible",
                ("eq", "party_id", sku["party_id"]), ("order", "location_code"))
            loc_by_id = {l["id"]: l for l in location_options}
        except Exception as exc:  # noqa: BLE001
            app.logger.warning("SKU location detail read failed (degrading): %s", exc)
            location_detail = "unavailable"
            location_options = []
    else:
        plant_row = (results["plants"] or [None])[0] or {}
        plant_code = plant_row.get("plant_code")
        can_manage = "manage_sku_master" in ((g.caller.get("plant_capabilities") or {}).get(plant_code) or [])
        if can_manage and not applicability_pending:
            try:
                location_options = (get_supabase_for_caller(token)
                                    .rpc("sku_master_location_options", {"p_sku": sku_id}).execute().data or [])
            except Exception as exc:  # noqa: BLE001 - governed options degrade without widening master reads
                app.logger.warning("SKU governed Location options read failed (degrading): %s", exc)

    party_by_id, family_by_party, party_detail = _sku_party_detail(g.caller, token, {sku["party_id"]})
    sets, set_detail = _sku_sets(token, [sku_id])

    # Amendment 04 D9: the append-only history of governed operations on this SKU.
    history, history_detail = None, "visible"
    try:
        history = _caller_rows(token, "sku_master_events",
                               "id, entity, entity_id, operation, actor, occurred_at, reason, before_state, after_state",
                               ("eq", "sku_id", sku_id), ("order", "id"))
    except Exception as exc:  # noqa: BLE001 - optional detail degrades, never fails the SKU read
        if _sku_schema_pending(exc):
            history_detail = "schema_pending"
        else:
            app.logger.warning("SKU history read failed (degrading): %s", exc)
            history_detail = "unavailable"

    replacement_rows = results.get("replacement") or []
    return jsonify({
        "sku": {
            "id": sku["id"],
            "plant_item_code": sku.get("plant_item_code"),
            "status": sku.get("status"),
            "pricing_portfolio": _sku_portfolio(sku, portfolio_pending),
            "replacement_sku_id": sku.get("replacement_sku_id"),
            "content_version": sku.get("content_version"),
            "plant": _sku_plant((results["plants"] or [None])[0]),
            "party_id": sku.get("party_id"),
            "customer": party_by_id.get(sku.get("party_id")),
            "family": family_by_party.get(sku.get("party_id")),
        },
        "versions": [{
            "id": v["id"],
            "version_no": v.get("version_no"),
            "is_price_driving": v.get("is_price_driving"),
            "approved": v.get("approved_at") is not None,
            # Amendment 04 D8: the token a draft edit or approval must present.
            "content_version": v.get("content_version"),
            "specification": {k: v.get(k) for k in _SKU_SPECIFICATION_KEYS},
            "quote_fields": _sku_quote_fields(v, quote_pending),
            "construction_version_id": v.get("construction_version_id"),
            "construction": constructions.get(v.get("construction_version_id")),
            "plant_adoption": (adoptions_by_cv.get(v.get("construction_version_id"), [])
                               if adoption_detail == "visible" else None),
        } for v in versions],
        "external_references": [{
            "id": r["id"], "reference_kind": r.get("reference_kind"),
            "reference_value": r.get("reference_value"), "status": r.get("status"),
        } for r in results["references"]],
        "location_applicability": [{
            "id": a["id"], "location_id": a.get("location_id"), "scope": a.get("scope"),
            "status": a.get("status"), "approved": a.get("approved_at") is not None,
            "content_version": a.get("content_version"),
            "location": ({k: loc_by_id[a["location_id"]].get(k) for k in (
                "location_code", "status", "bill_to_eligible", "ship_to_eligible")}
                if a.get("location_id") in loc_by_id else None),
        } for a in applicabilities],
        "location_options": location_options if location_detail == "visible" or can_manage else None,
        "lineage": {
            "replaced_by": (replacement_rows[0] if replacement_rows else None),
            "replacement_visible": (not sku.get("replacement_sku_id")) or bool(replacement_rows),
            "replaces": results["replaces"],
        },
        "sets": sets.get(sku_id, []) if set_detail == "visible" else None,
        "history": history if history_detail == "visible" else None,
        "detail_visibility": {"customer": party_detail, "construction": construction_detail,
                              "plant_adoption": adoption_detail, "locations": location_detail, "sets": set_detail,
                              "history": history_detail},
        "schema_pending": {"quote_fields": quote_pending, "sku_sets": set_detail == "schema_pending",
                            "pricing_portfolio": portfolio_pending,
                            # The governed operations and their history arrive together (Amendment 04).
                            "governed_operations": history_detail == "schema_pending",
                            "location_applicability_operations": applicability_pending},
        "mode": "governed_read_only",
        "authority": "caller_token_rls_only",
        "mutations": "none",
    })



# ── SKU Master governed operations (Canonical Amendment 04, slice 1) ──────────
#
# Every write is ONE call to a `public.sku_*` invoker wrapper as the caller; the
# database decides authority (manage_sku_master, or make_quote for a proposal at
# that plant), field classes (a dimension, Construction, box type or strength change
# is a NEW SKU - PT423), the lifecycle, and compare-and-swap (PT409). No service-role
# client is used and nothing is written to a table directly: the direct path is
# closed by the migration. These routes only shape and bound the request first, so
# a malformed body is INVALID_INPUT before any database call.
#
# Until migration 20260917030403 is applied the wrappers do not exist; PostgREST
# answers PGRST202 and the route returns SCHEMA_ACTIVATION_PENDING rather than a
# generic failure.
_SKU_OP_ERRORS = {"PT423": "NEW_SKU_REQUIRED", "PGRST202": "SCHEMA_ACTIVATION_PENDING",
                  "42883": "SCHEMA_ACTIVATION_PENDING", "23514": "TRANSITION_NOT_ALLOWED",
                  "23505": "TRANSITION_NOT_ALLOWED"}
_SKU_TEXT_FIELDS = ("box_type", "item_name", "item_short_name", "item_family", "item_group", "print_quality",
                    "print_technology", "colour_detail", "cobb_value", "stated_item_gsm", "stated_cs",
                    "stated_bs", "stated_ect", "customer_spec_version")
_SKU_NUMBER_FIELDS = ("length_mm", "width_mm", "height_mm", "spec_bs", "spec_bct", "spec_ect", "item_weight_kg")
_SKU_INTEGER_FIELDS = ("construction_version_id", "ups", "number_of_colours")
_SKU_REFERENCE_KINDS = ("customer_item_code", "softcomp_code", "legacy_plant_item_code", "alias", "other")
_SKU_PRINT_TECHNOLOGIES = ("Flexo", "CMYK", "Offset", "Unprinted")
_SKU_TEXT_MAX = 200
_SKU_REASON_MAX = 500


def _sku_op_fields(data):
    """Validate a specification field set. Returns (fields, error_response)."""
    fields = data.get("fields")
    if not isinstance(fields, dict):
        return None, _invalid_input("fields must be an object")
    clean = {}
    for key, value in fields.items():
        if key in _SKU_TEXT_FIELDS:
            if value is not None and (not isinstance(value, str) or len(value) > _SKU_TEXT_MAX):
                return None, _invalid_input(f"{key} must be text of at most {_SKU_TEXT_MAX} characters, or null")
            if key == "print_technology" and value is not None and value not in _SKU_PRINT_TECHNOLOGIES:
                return None, _invalid_input("print_technology must be Flexo, CMYK, Offset or Unprinted")
            if key == "box_type" and (value is None or not value.strip()):
                return None, _invalid_input("box_type cannot be blank")
            # A blank text is a cleared value, stored as null - never an empty string.
            clean[key] = value.strip() if isinstance(value, str) and value.strip() else None
        elif key in _SKU_NUMBER_FIELDS:
            if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0):
                return None, _invalid_input(f"{key} must be a number of zero or more, or null")
            clean[key] = value
        elif key in _SKU_INTEGER_FIELDS:
            if value is None and key != "construction_version_id" and key != "ups":
                clean[key] = None
                continue
            if isinstance(value, bool) or not isinstance(value, int) or value < (1 if key != "number_of_colours" else 0):
                return None, _invalid_input(f"{key} must be a whole number")
            clean[key] = value
        else:
            return None, _invalid_input(f"{key} is not a SKU specification field")
    return clean, None


def _sku_op_expected(data):
    expected = _int_field(data, "expected_content_version")
    if expected is None or expected < 1:
        return None, _invalid_input("expected_content_version is required")
    return expected, None


def _sku_op_reason(data, required=False):
    reason = data.get("reason")
    if reason is not None and not isinstance(reason, str):
        return None, _invalid_input("reason must be text")
    reason = (reason or "").strip()
    if len(reason) > _SKU_REASON_MAX:
        return None, _invalid_input(f"reason must be at most {_SKU_REASON_MAX} characters")
    if required and not reason:
        return None, _invalid_input("a reason is required")
    return reason or None, None


def _sku_rpc(name, params):
    return _rpc_call(get_supabase_for_caller(g.access_token), name, params, error_map=_SKU_OP_ERRORS)


def _sku_op_body():
    data = request.get_json(silent=True)
    return data if isinstance(data, dict) else {}


@app.route("/masters/skus", methods=["POST"])
@require_auth
def propose_sku_route():
    """Propose a SKU with its first specification version (D1: a Maker may, for speed)."""
    data = _sku_op_body()
    plant_code = data.get("plant_code")
    if plant_code not in _sku_plant_scope(g.caller):
        return _error("CAPABILITY_REQUIRED", "plant_access capability is required at the requested plant")
    party_id = _int_field(data, "party_id")
    if party_id is None or party_id < 1:
        return _invalid_input("party_id is required")
    if data.get("pricing_portfolio") not in _SKU_PORTFOLIOS:
        return _invalid_input("pricing_portfolio must be Transactional or Strategic")
    if not isinstance(data.get("is_price_driving"), bool):
        return _invalid_input("is_price_driving must be true or false")
    fields, bad = _sku_op_fields(data)
    if bad:
        return bad
    if "construction_version_id" not in fields:
        return _invalid_input("a Construction version is required")
    try:
        plants = _caller_rows(g.access_token, "plants", "id, plant_code", ("eq", "plant_code", plant_code))
    except Exception as exc:
        handled = _sku_read_error(exc, "SKU proposal plant read")
        if handled is not None:
            return handled
        raise
    if not plants:
        return _error("RECORD_NOT_FOUND")
    result, err = _sku_rpc("sku_propose", {
        "p_plant": plants[0]["id"], "p_party": party_id, "p_pricing_portfolio": data["pricing_portfolio"],
        "p_is_price_driving": data["is_price_driving"], "p_fields": fields})
    if err:
        return err
    return jsonify({"id": result.data}), 201


@app.route("/masters/skus/<int:sku_id>/versions", methods=["POST"])
@require_auth
def create_sku_version_route(sku_id):
    """A new specification version (D2). A new-SKU field change is refused NEW_SKU_REQUIRED."""
    data = _sku_op_body()
    expected, bad = _sku_op_expected(data)
    if bad:
        return bad
    if not isinstance(data.get("is_price_driving"), bool):
        return _invalid_input("is_price_driving must be true or false")
    fields, bad = _sku_op_fields(data)
    if bad:
        return bad
    if not fields:
        return _invalid_input("a new version must change at least one field")
    result, err = _sku_rpc("sku_create_version", {
        "p_sku": sku_id, "p_expected_content_version": expected,
        "p_is_price_driving": data["is_price_driving"], "p_fields": fields})
    if err:
        return err
    return jsonify({"id": result.data}), 201


@app.route("/masters/sku-versions/<int:version_id>", methods=["PATCH"])
@require_auth
def update_sku_draft_version_route(version_id):
    """Edit an unapproved draft version in place (D2)."""
    data = _sku_op_body()
    expected, bad = _sku_op_expected(data)
    if bad:
        return bad
    price_driving = data.get("is_price_driving")
    if price_driving is not None and not isinstance(price_driving, bool):
        return _invalid_input("is_price_driving must be true, false or omitted")
    fields, bad = _sku_op_fields(data)
    if bad:
        return bad
    _, err = _sku_rpc("sku_update_draft_version", {
        "p_version": version_id, "p_expected_content_version": expected,
        "p_is_price_driving": price_driving, "p_fields": fields})
    return err or jsonify({"ok": True})


def _sku_simple_op(rpc, id_param, entity_id, extra=None):
    data = _sku_op_body()
    expected, bad = _sku_op_expected(data)
    if bad:
        return bad
    params = {id_param: entity_id, "p_expected_content_version": expected, **(extra or {})}
    _, err = _sku_rpc(rpc, params)
    return err or jsonify({"ok": True})


@app.route("/masters/sku-versions/<int:version_id>/approve", methods=["POST"])
@require_auth
def approve_sku_version_route(version_id):
    """Approve a version (manage_sku_master; the proposer may approve their own - D1)."""
    return _sku_simple_op("sku_approve_version", "p_version", version_id)


@app.route("/masters/skus/<int:sku_id>/plant-item-code", methods=["POST"])
@require_auth
def assign_sku_plant_item_code_route(sku_id):
    """Assign the permanent Plant Item Code (D3). It does not publish."""
    data = _sku_op_body()
    code = data.get("plant_item_code")
    if not isinstance(code, str) or not code.strip() or len(code.strip()) > 60:
        return _invalid_input("plant_item_code must be 1 to 60 characters")
    return _sku_simple_op("sku_assign_plant_item_code", "p_sku", sku_id, {"p_code": code.strip()})


@app.route("/masters/skus/<int:sku_id>/publish", methods=["POST"])
@require_auth
def publish_sku_route(sku_id):
    """Proposed -> Active: needs a code, an approved version and a portfolio (D3)."""
    return _sku_simple_op("sku_publish", "p_sku", sku_id)


@app.route("/masters/skus/<int:sku_id>/discontinue", methods=["POST"])
@require_auth
def discontinue_sku_route(sku_id):
    """Active -> Discontinued with a reason and an optional linked replacement (D4)."""
    data = _sku_op_body()
    reason, bad = _sku_op_reason(data, required=True)
    if bad:
        return bad
    replacement = data.get("replacement_sku_id")
    if replacement is not None:
        replacement = _int_field(data, "replacement_sku_id")
        if replacement is None or replacement < 1:
            return _invalid_input("replacement_sku_id must be a SKU id or null")
    return _sku_simple_op("sku_discontinue", "p_sku", sku_id,
                          {"p_reason": reason, "p_replacement_sku": replacement})


@app.route("/masters/skus/<int:sku_id>/reactivate", methods=["POST"])
@require_auth
def reactivate_sku_route(sku_id):
    """Discontinued -> Active; identity is kept and the replacement link is cleared (D4)."""
    reason, bad = _sku_op_reason(_sku_op_body())
    if bad:
        return bad
    return _sku_simple_op("sku_reactivate", "p_sku", sku_id, {"p_reason": reason})


@app.route("/masters/skus/<int:sku_id>/withdraw", methods=["POST"])
@require_auth
def withdraw_sku_route(sku_id):
    """Proposed -> Withdrawn, terminal (D4, CDM-31)."""
    reason, bad = _sku_op_reason(_sku_op_body())
    if bad:
        return bad
    return _sku_simple_op("sku_withdraw", "p_sku", sku_id, {"p_reason": reason})


@app.route("/masters/skus/<int:sku_id>/pricing-portfolio", methods=["POST"])
@require_auth
def set_sku_pricing_portfolio_route(sku_id):
    """Reclassify in place (CDM-45 C-03). Recorded only: it sets no price."""
    data = _sku_op_body()
    if data.get("pricing_portfolio") not in _SKU_PORTFOLIOS:
        return _invalid_input("pricing_portfolio must be Transactional or Strategic")
    reason, bad = _sku_op_reason(data)
    if bad:
        return bad
    return _sku_simple_op("sku_set_pricing_portfolio", "p_sku", sku_id,
                          {"p_pricing_portfolio": data["pricing_portfolio"], "p_reason": reason})


@app.route("/masters/skus/<int:sku_id>/references", methods=["POST"])
@require_auth
def add_sku_reference_route(sku_id):
    """Add an external reference (D5)."""
    data = _sku_op_body()
    expected, bad = _sku_op_expected(data)
    if bad:
        return bad
    kind, value = data.get("reference_kind"), data.get("reference_value")
    if kind not in _SKU_REFERENCE_KINDS:
        return _invalid_input("reference_kind is not a recognised kind")
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > 120:
        return _invalid_input("reference_value must be 1 to 120 characters")
    result, err = _sku_rpc("sku_add_reference", {
        "p_sku": sku_id, "p_expected_content_version": expected, "p_kind": kind, "p_value": value.strip()})
    if err:
        return err
    return jsonify({"id": result.data}), 201


@app.route("/masters/sku-references/<int:reference_id>/withdraw", methods=["POST"])
@require_auth
def withdraw_sku_reference_route(reference_id):
    """Withdraw a reference; the SKU's token guards it (D5, D8)."""
    reason, bad = _sku_op_reason(_sku_op_body())
    if bad:
        return bad
    return _sku_simple_op("sku_withdraw_reference", "p_reference", reference_id, {"p_reason": reason})


@app.route("/masters/skus/<int:sku_id>/location-applicabilities", methods=["POST"])
@require_auth
def propose_sku_location_applicability_route(sku_id):
    """Propose master applicability for one active Location of this SKU's Customer."""
    data = _sku_op_body()
    expected, bad = _sku_op_expected(data)
    if bad:
        return bad
    location_id = _int_field(data, "location_id")
    if location_id is None or location_id < 1:
        return _invalid_input("location_id is required")
    result, err = _sku_rpc("sku_propose_master_applicability", {
        "p_sku": sku_id, "p_expected_content_version": expected, "p_location": location_id})
    if err:
        return err
    return jsonify({"id": result.data}), 201


@app.route("/masters/sku-location-applicabilities/<int:applicability_id>/approve", methods=["POST"])
@require_auth
def approve_sku_location_applicability_route(applicability_id):
    return _sku_simple_op("sku_approve_master_applicability", "p_applicability", applicability_id)


@app.route("/masters/sku-location-applicabilities/<int:applicability_id>/withdraw", methods=["POST"])
@require_auth
def withdraw_sku_location_applicability_route(applicability_id):
    reason, bad = _sku_op_reason(_sku_op_body(), required=True)
    if bad:
        return bad
    return _sku_simple_op("sku_withdraw_master_applicability", "p_applicability", applicability_id,
                          {"p_reason": reason})


@app.route("/masters/sku-location-applicabilities/<int:applicability_id>/reactivate", methods=["POST"])
@require_auth
def reactivate_sku_location_applicability_route(applicability_id):
    reason, bad = _sku_op_reason(_sku_op_body(), required=True)
    if bad:
        return bad
    return _sku_simple_op("sku_reactivate_master_applicability", "p_applicability", applicability_id,
                          {"p_reason": reason})

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

    # D1 - these reads are independent of one another and ran strictly in
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
    # The pool is bounded to exactly the known reads in _READS (nine after
    # Family Sector classification) - not a general concurrency mechanism,
    # and not sized from anything a caller controls.
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
        # U1 external references (read-only). Same read_party_master gate as the
        # six above - `party_external_references_select` is the identical policy
        # - so this exposes nothing a caller could not already reach.
        #
        # `created_by` is deliberately NOT selected. It is an FK to app_users,
        # and the Customer Master screen has no business disclosing WHICH
        # operator recorded a reference. Read-only view only: no create, edit,
        # retire or delete operation exists for this table anywhere.
        ("external_references", "party_external_references",
         "id, party_id, ref_kind, ref_value, created_at"),
        ("family_sectors", "customer_family_sectors",
         "family_id, sector_id, created_at"),
        ("sectors", "sectors", "id, sector_code, name, status"),
    )

    # Captured HERE, not read inside the worker: `flask.g` is bound to the
    # request context and is not visible from a pool thread.
    caller_token = g.access_token

    def _read(spec):
        key, table, cols = spec
        worker_client = new_caller_client(caller_token)
        return key, (worker_client.table(table).select(cols).execute()).data or []

    try:
        with timed("families.master_reads_parallel"):
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
    external_references = results["external_references"]
    family_sectors = results["family_sectors"]
    sectors = results["sectors"]

    families.sort(key=lambda r: r.get("group_customer_code") or r.get("name") or "")
    return jsonify({
        "families": families,
        "aliases": aliases,
        "memberships": memberships,
        "parties": parties,
        "locations": locations,
        "location_versions": location_versions,
        "external_references": external_references,
        "family_sectors": family_sectors,
        "sectors": sectors,
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
    "23503": "RECORD_NOT_FOUND",      # governed identity/FK does not exist
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
    "PT422": "CALCULATION_NOT_READY", # governed input gatherer refused incomplete/ineligible state
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
    "55P03": "LOCK_UNAVAILABLE",        # another editor holds the Batch lock
}

_ERROR_STATUS = {
    "AUTH_REQUIRED": 401,
    "CAPABILITY_REQUIRED": 403,
    "RECORD_NOT_FOUND": 404,
    "STALE_VERSION": 409,
    "TRANSITION_NOT_ALLOWED": 422,
    "INVALID_EFFECTIVE_DATE": 422,
    "INVALID_INPUT": 400,
    "LOCK_UNAVAILABLE": 409,
    "CALCULATION_NOT_READY": 422,
    "SEND_NOT_READY": 422,
    "CALCULATION_EXECUTOR_UNAVAILABLE": 503,
    "CALCULATION_EXECUTION_FAILED": 500,
    "MASTER_UNAVAILABLE": 503,
    # A field whose storage migration has not been applied yet. The request is
    # well formed and the caller is entitled to it; the column simply does not
    # exist. Distinct from INVALID_INPUT (the caller asked wrongly) and from
    # MASTER_UNAVAILABLE (the whole master is absent in this environment).
    "SCHEMA_ACTIVATION_PENDING": 503,
    # Amendment 04 D2 / CDM-10: the change asked for is a new SKU, not a version.
    "NEW_SKU_REQUIRED": 422,
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
    "AUTH_REQUIRED": "Your session is no longer valid. Sign in again and retry.",
    "CAPABILITY_REQUIRED": "You do not have permission to perform this action.",
    "RECORD_NOT_FOUND": "The requested record could not be found.",
    "STALE_VERSION": "This record changed since you last read it. Reload and try again.",
    "TRANSITION_NOT_ALLOWED": "That action is not allowed for this record's current state.",
    "INVALID_EFFECTIVE_DATE": "The effective date is not valid for this change.",
    "LOCK_UNAVAILABLE": "This Batch is locked by another editor. Refresh before editing.",
    "CALCULATION_NOT_READY": "This row is not ready for governed calculation input resolution.",
    "SEND_NOT_READY": "This Batch is not ready to create an immutable draft Quote candidate.",
    "CALCULATION_EXECUTOR_UNAVAILABLE": "Governed Calculate is not available in this environment.",
    "CALCULATION_EXECUTION_FAILED": "The governed calculation executor could not produce a valid result.",
    "MASTER_UNAVAILABLE": "This master is not available in this environment.",
    "SCHEMA_ACTIVATION_PENDING": "That field's storage is not activated in this environment yet, "
                                 "so it cannot be read or filtered.",
    "NEW_SKU_REQUIRED": "A dimension, Construction, box type or strength change is a new SKU, not a new "
                        "version. Propose it as a new SKU instead.",
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


def _rpc_call(client, name, params, error_map=None):
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
        code = {**_RPC_ERROR_MAP, **(error_map or {})}.get(exc.code)
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


def _optional_nonnegative_numeric(data, key, max_value=None):
    """Preserve blank-versus-zero while refusing booleans, NaN and negatives."""
    value = data.get(key)
    if value is None or value == "":
        return None, None
    if isinstance(value, bool):
        return None, _invalid_input(f"{key} must be blank or a non-negative number")
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None, _invalid_input(f"{key} must be blank or a non-negative number")
    if not parsed.is_finite() or parsed < 0:
        return None, _invalid_input(f"{key} must be blank or a non-negative number")
    if max_value is not None and parsed > Decimal(max_value):
        return None, _invalid_input(f"{key} exceeds the supported maximum of {max_value}")
    return float(parsed), None


def _pricing_group_input(client, batch_id, data, existing):
    """Validate one complete Pricing Group commercial-terms replacement."""
    expected = _int_field(data, "expected_content_version")
    if expected is None or expected < 1:
        return None, _invalid_input("expected_content_version is required")

    label_value = data.get("label")
    if label_value is not None and not isinstance(label_value, str):
        return None, _invalid_input("label must be text or blank")
    label = (label_value or "").strip()
    if len(label) > 120:
        return None, _invalid_input("label must be 120 characters or fewer")

    freight_mode = data.get("freight_mode")
    if freight_mode not in ("master", "manual", "ex_factory"):
        return None, _invalid_input("freight_mode must be master, manual or ex_factory")
    freight_manual_value, err = _optional_nonnegative_numeric(
        data, "freight_manual_value", "99999999.9999")
    if err:
        return None, err
    if freight_mode == "manual" and freight_manual_value is None:
        return None, _invalid_input("freight_manual_value is required in manual mode")
    if freight_mode != "manual":
        freight_manual_value = None

    raw_days = data.get("payment_terms_days")
    payment_terms_days = _int_field(data, "payment_terms_days")
    if raw_days not in (None, "") and payment_terms_days not in (30, 45, 60, 90):
        return None, _invalid_input("payment_terms_days must be blank, 30, 45, 60 or 90")

    payment_text_value = data.get("payment_terms_text")
    if payment_text_value is not None and not isinstance(payment_text_value, str):
        return None, _invalid_input("payment_terms_text must be text or blank")
    payment_terms_text = (payment_text_value or "").strip()
    if len(payment_terms_text) > 500:
        return None, _invalid_input("payment_terms_text must be 500 characters or fewer")

    interest_override_pct, err = _optional_nonnegative_numeric(
        data, "interest_override_pct", "9999.999")
    if err:
        return None, err
    reason_value = data.get("interest_override_reason")
    if reason_value is not None and not isinstance(reason_value, str):
        return None, _invalid_input("interest_override_reason must be text or blank")
    reason = (reason_value or "").strip()
    if len(reason) > 500:
        return None, _invalid_input("interest_override_reason must be 500 characters or fewer")

    derived_pct = None
    if interest_override_pct is not None and payment_terms_days is not None:
        batch_rows = (client.table("batches")
                      .select("id, pricing_basis_release_id")
                      .eq("id", batch_id).limit(1).execute()).data or []
        release_id = batch_rows[0].get("pricing_basis_release_id") if batch_rows else None
        if release_id is None:
            return None, _invalid_input(
                "Select a Pricing Basis Release before recording an Interest override.")
        release_rows = (client.table("pricing_basis_releases")
                        .select("id, calculation_default_version_id")
                        .eq("id", release_id).limit(1).execute()).data or []
        defaults_id = release_rows[0].get("calculation_default_version_id") if release_rows else None
        defaults_rows = [] if defaults_id is None else (
            client.table("calculation_default_versions")
            .select("id, annual_interest_pct, day_count_basis")
            .eq("id", defaults_id).limit(1).execute()).data or []
        if not defaults_rows:
            return None, _invalid_input(
                "The selected Pricing Basis cannot supply the governed annual Interest basis.")
        annual = Decimal(str(defaults_rows[0].get("annual_interest_pct")))
        day_count = Decimal(str(defaults_rows[0].get("day_count_basis")))
        if not annual.is_finite() or not day_count.is_finite() or day_count <= 0:
            return None, _invalid_input(
                "The selected Pricing Basis has an invalid annual Interest basis.")
        derived_pct = (annual * Decimal(payment_terms_days) / day_count).quantize(
            Decimal("0.001"), rounding=ROUND_HALF_UP)

    override_decimal = None if interest_override_pct is None else Decimal(str(interest_override_pct))
    if interest_override_pct is not None and (derived_pct is None or override_decimal != derived_pct) and not reason:
        return None, _invalid_input(
            "interest_override_reason is required when the override differs from derived Interest")

    updates = {
        "label": label or None,
        "freight_mode": freight_mode,
        "freight_manual_value": freight_manual_value,
        "payment_terms_days": payment_terms_days,
        "payment_terms_text": payment_terms_text or None,
        "interest_override_pct": interest_override_pct,
        "interest_override_derived_pct": float(derived_pct) if derived_pct is not None else None,
        "interest_override_reason": (reason or None) if interest_override_pct is not None else None,
    }
    if freight_mode == "ex_factory":
        updates["freight_basis_delivery_group_id"] = None
    if (existing.get("legacy_freight_source") == "legacy_batch"
            and freight_mode in ("manual", "ex_factory")):
        # This explicit governed statement replaces, rather than competes with,
        # the temporary higher-priority Batch freight tier.
        updates["legacy_freight_value"] = None
        updates["legacy_freight_source"] = None
    return {"expected": expected, "updates": updates}, None


def _valid_date_only(value):
    """Validate a commercial date without converting it to a timezone instant."""
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return False
    try:
        parsed = datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        return False
    return parsed.strftime("%Y-%m-%d") == value


def _read_batch_pricing_basis(client, *, batch_id=None, batch_reference=None):
    """Read one RLS-visible Batch and its caller-visible Pricing Basis identity."""
    query = client.table("batches").select(
        "id, batch_reference, plant_id, status, content_version, pricing_date, "
        "pricing_basis_release_id, pricing_basis_is_deliberate"
    )
    if batch_id is not None:
        query = query.eq("id", batch_id)
    else:
        query = query.eq("batch_reference", batch_reference)
    rows = query.limit(1).execute().data or []
    if not rows:
        return None

    batch = rows[0]
    plant_rows = (client.table("plants")
                  .select("id, plant_code, name, status")
                  .eq("id", batch["plant_id"]).limit(1).execute()).data or []
    release_rows = []
    if batch.get("pricing_basis_release_id") is not None:
        release_rows = (client.table("pricing_basis_releases")
                        .select(
                            "id, plant_id, release_name, status, effective_from, effective_until, "
                            "is_automatic_default, created_at, approved_at, withdrawn_at"
                        )
                        .eq("id", batch["pricing_basis_release_id"])
                        .limit(1).execute()).data or []

    batch["plant"] = plant_rows[0] if plant_rows else None
    batch["pricing_basis_release"] = release_rows[0] if release_rows else None
    batch["details_partial"] = not plant_rows or (
        batch.get("pricing_basis_release_id") is not None and not release_rows
    )
    return batch


def _optional_caller_rows(query):
    """Read one optional workspace section without widening caller authority.

    RLS-hidden rows naturally return an empty list.  A table-level 42501 is
    retained as a caller-visible denied section instead of turning an otherwise
    readable Batch into a fabricated complete response.
    """
    try:
        return query.execute().data or [], False
    except APIError as exc:
        if exc.code == "42501":
            return [], True
        raise


def _read_quote_workspace(client, quote_reference=None, revision_id=None, batch_id=None):
    """Assemble one caller-visible Quote without weakening Family G RLS.

    A permanent Quote reference, exact revision identity, or exact Batch
    identity is the entry point. Revision identity is required for a submitted,
    pre-approval candidate reached from an inbox. Batch identity supports a
    durable Batch-to-Quote handoff even before a permanent Quote reference has
    been allocated. Every supporting read
    uses the same caller-scoped client; optional RLS/table denials are reported
    as partial evidence and are never filled from a privileged connection.
    Frozen calculation inputs/results are returned exactly as stored so the
    Quote screen cannot silently re-resolve current Batch or master data.
    """
    family_query = client.table("quote_families").select(
        "id, batch_id, quote_reference, status, created_at, created_by"
    )
    if revision_id is not None:
        revision_rows = (client.table("quote_revisions")
                         .select("id, family_id")
                         .eq("id", revision_id).limit(1).execute()).data or []
        if not revision_rows:
            return None
        family_query = family_query.eq("id", revision_rows[0]["family_id"])
    elif batch_id is not None:
        family_query = family_query.eq("batch_id", batch_id)
    else:
        family_query = family_query.eq("quote_reference", quote_reference)
    family_rows = family_query.limit(1).execute().data or []
    if not family_rows:
        return None

    family = family_rows[0]
    partial, denied = [], []

    def optional(section, query):
        rows, was_denied = _optional_caller_rows(query)
        if was_denied:
            denied.append(section)
        return rows

    def one(section, table, columns, row_id):
        if row_id is None:
            return None
        rows = optional(section, client.table(table).select(columns).eq("id", row_id).limit(1))
        if not rows and section not in denied:
            partial.append(section)
        return rows[0] if rows else None

    family["batch"] = one(
        "batch", "batches",
        "id, batch_reference, family_id, plant_id, owner_user_id, sector_id, status, "
        "pricing_date, pricing_basis_release_id, pricing_basis_is_deliberate, created_at, created_by",
        family.get("batch_id"))
    if family.get("batch"):
        family["batch"]["plant"] = one(
            "plant", "plants", "id, plant_code, name, status",
            family["batch"].get("plant_id"))
        family["batch"]["customer_family"] = one(
            "customer_family", "customer_families",
            "id, group_customer_code, name, status",
            family["batch"].get("family_id"))

    revisions = optional(
        "revisions", client.table("quote_revisions").select(
            "id, family_id, revision_no, source_revision_id, workflow_status, standing, "
            "addressee_name, addressee_details, quote_date, offer_validity_to, approved_by, "
            "approved_at, issued_by, issued_at, voided_by, voided_at, void_reason, "
            "withdraw_reason, return_note, created_at, created_by"
        ).eq("family_id", family["id"]))
    revisions.sort(key=lambda row: (row.get("revision_no") is None,
                                    row.get("revision_no") or 0,
                                    row.get("created_at") or ""))
    revision_ids = [row["id"] for row in revisions]

    def many_for(section, table, columns, foreign_key, ids):
        if not ids:
            return []
        return optional(section, client.table(table).select(columns).in_(foreign_key, ids))

    items = many_for(
        "quote_items", "quote_items",
        "id, revision_id, batch_row_lineage_id, pricing_group_id, calculation_snapshot_id",
        "revision_id", revision_ids)
    snapshot_ids = [row["calculation_snapshot_id"] for row in items]
    snapshots = many_for(
        "calculation_snapshots", "calculation_snapshots",
        "id, schema_version, engine_version, rounding_rule_version, pricing_basis_release_id, "
        "calculation_default_version_id, pricing_date, effective_waste_pct, waste_source, "
        "effective_conv_rate, conv_source, effective_margin_pct, margin_source, "
        "effective_interest_pct, interest_source, effective_freight, freight_source, "
        "freight_authority, freight_set_version_id, freight_entry_id, total_cost, final_rate, "
        "rate_per_kg, calc_moq, calculation_fingerprint, presentation_fingerprint, "
        "effective_inputs, results, calculated_by, calculated_at",
        "id", snapshot_ids)
    item_ids = [row["id"] for row in items]
    delivery_links = many_for(
        "item_delivery_groups", "quote_item_delivery_groups",
        "id, quote_item_id, delivery_group_id", "quote_item_id", item_ids)
    workflow_events = many_for(
        "workflow_events", "quote_workflow_events",
        "id, revision_id, event_type, actor_user_id, occurred_at, note",
        "revision_id", revision_ids)
    outcome_events = many_for(
        "customer_outcomes", "customer_outcome_events",
        "id, revision_id, outcome, acceptance_date, acceptance_reference, note, recorded_by, occurred_at",
        "revision_id", revision_ids)

    snapshots_by_id = {str(row["id"]): row for row in snapshots}
    links_by_item = {}
    for link in delivery_links:
        links_by_item.setdefault(str(link["quote_item_id"]), []).append(link)
    items_by_revision = {}
    for item in items:
        item["calculation_snapshot"] = snapshots_by_id.get(str(item["calculation_snapshot_id"]))
        item["delivery_groups"] = links_by_item.get(str(item["id"]), [])
        if not item["calculation_snapshot"] and "calculation_snapshots" not in denied:
            partial.append("calculation_snapshot")
        items_by_revision.setdefault(str(item["revision_id"]), []).append(item)

    actor_ids = {
        actor_id for actor_id in (
            [family.get("created_by")]
            + [value for revision in revisions for value in (
                revision.get("created_by"), revision.get("approved_by"),
                revision.get("issued_by"), revision.get("voided_by"))]
            + [snapshot.get("calculated_by") for snapshot in snapshots]
            + [event.get("actor_user_id") for event in workflow_events]
            + [event.get("recorded_by") for event in outcome_events]
        ) if actor_id is not None
    }
    actors = {}
    for actor_id in actor_ids:
        actor = one("actor_identity", "app_users", "id, display_name, status", actor_id)
        if actor:
            actors[str(actor_id)] = actor

    events_by_revision = {}
    for event in workflow_events:
        event["actor"] = actors.get(str(event.get("actor_user_id")))
        events_by_revision.setdefault(str(event["revision_id"]), []).append(event)
    outcomes_by_revision = {}
    for event in outcome_events:
        event["recorded_by_actor"] = actors.get(str(event.get("recorded_by")))
        outcomes_by_revision.setdefault(str(event["revision_id"]), []).append(event)

    for revision in revisions:
        revision["created_by_actor"] = actors.get(str(revision.get("created_by")))
        revision["approved_by_actor"] = actors.get(str(revision.get("approved_by")))
        revision["issued_by_actor"] = actors.get(str(revision.get("issued_by")))
        revision["voided_by_actor"] = actors.get(str(revision.get("voided_by")))
        revision["items"] = items_by_revision.get(str(revision["id"]), [])
        for item in revision["items"]:
            snapshot = item.get("calculation_snapshot")
            if snapshot:
                snapshot["calculated_by_actor"] = actors.get(str(snapshot.get("calculated_by")))
        revision["workflow_events"] = sorted(
            events_by_revision.get(str(revision["id"]), []),
            key=lambda event: (event.get("occurred_at") or "", event.get("id")))
        revision["customer_outcomes"] = sorted(
            outcomes_by_revision.get(str(revision["id"]), []),
            key=lambda event: (event.get("occurred_at") or "", event.get("id")))

    family["created_by_actor"] = actors.get(str(family.get("created_by")))
    family["revisions"] = revisions
    family["details_partial"] = bool(partial or denied)
    family["partial_sections"] = sorted(set(partial))
    family["denied_sections"] = sorted(set(denied))
    family["actions"] = {
        name: {"enabled": False, "reason": "backend_activation_pending"}
        for name in ("calculate", "send", "submit", "approve", "return", "withdraw",
                     "issue", "create_revision", "amend", "reprice")
    }
    return family


def _read_quote_catalogue(client, view):
    """Build a bounded, caller-visible U5 Quote catalogue.

    The catalogue never widens authority: its primary and supporting reads all
    use the same caller-scoped client and existing Family G RLS. Supporting
    denials remain explicit partial data. The 51-row read lets the UI state
    truthfully when the current view was limited to its first 50 records.
    """
    revision_query = client.table("quote_revisions").select(
        "id, family_id, revision_no, workflow_status, standing, quote_date, "
        "created_at, created_by, approved_at, approved_by, issued_at, issued_by"
    )
    if view == "inbox":
        revision_query = revision_query.eq("workflow_status", "submitted")
    revisions = (revision_query.order("created_at", desc=True).limit(51).execute()).data or []
    results_limited = len(revisions) > 50
    revisions = revisions[:50]

    partial, denied = [], []

    def optional(section, query):
        rows, was_denied = _optional_caller_rows(query)
        if was_denied:
            denied.append(section)
        return rows

    def indexed(section, table, columns, ids):
        if not ids:
            return {}
        rows = optional(section, client.table(table).select(columns).in_("id", ids))
        return {str(row["id"]): row for row in rows}

    family_ids = list({row["family_id"] for row in revisions})
    families = indexed(
        "quote_families", "quote_families",
        "id, batch_id, quote_reference, status", family_ids)
    batch_ids = list({row["batch_id"] for row in families.values()})
    batches = indexed(
        "batches", "batches",
        "id, batch_reference, family_id, plant_id, status", batch_ids)
    plant_ids = list({row["plant_id"] for row in batches.values()})
    plants = indexed("plants", "plants", "id, plant_code, name, status", plant_ids)
    customer_family_ids = list({row["family_id"] for row in batches.values()})
    customer_families = indexed(
        "customer_families", "customer_families",
        "id, group_customer_code, name, status", customer_family_ids)

    revision_ids = [row["id"] for row in revisions]
    items = optional(
        "quote_items",
        client.table("quote_items").select("id, revision_id").in_("revision_id", revision_ids)
    ) if revision_ids else []
    item_counts = {}
    for item in items:
        key = str(item["revision_id"])
        item_counts[key] = item_counts.get(key, 0) + 1

    actor_ids = list({actor_id for revision in revisions for actor_id in (
        revision.get("created_by"), revision.get("approved_by"), revision.get("issued_by")
    ) if actor_id is not None})
    actors = indexed("actor_identities", "app_users", "id, display_name, status", actor_ids)

    rows = []
    for revision in revisions:
        family = families.get(str(revision["family_id"]))
        batch = batches.get(str(family.get("batch_id"))) if family else None
        plant = plants.get(str(batch.get("plant_id"))) if batch else None
        customer_family = customer_families.get(str(batch.get("family_id"))) if batch else None
        if not family:
            partial.append("quote_family")
        elif not batch:
            partial.append("batch")
        row = dict(revision)
        row.update({
            "quote_family_id": family.get("id") if family else revision.get("family_id"),
            "quote_reference": family.get("quote_reference") if family else None,
            "family_status": family.get("status") if family else None,
            "batch_id": batch.get("id") if batch else None,
            "batch_reference": batch.get("batch_reference") if batch else None,
            "batch_status": batch.get("status") if batch else None,
            "plant": plant,
            "customer_family": customer_family,
            "created_by_actor": actors.get(str(revision.get("created_by"))),
            "approved_by_actor": actors.get(str(revision.get("approved_by"))),
            "issued_by_actor": actors.get(str(revision.get("issued_by"))),
            "item_count": item_counts.get(str(revision["id"]), 0),
        })
        rows.append(row)

    return {
        "view": view,
        "rows": rows,
        "display_limit": 50,
        "results_limited": results_limited,
        "details_partial": bool(partial or denied),
        "partial_sections": sorted(set(partial)),
        "denied_sections": sorted(set(denied)),
        "actions": {
            name: {"enabled": False, "reason": "backend_activation_pending"}
            for name in ("approve", "return", "withdraw", "issue", "create_revision")
        },
    }


def _read_batch_catalogue(client):
    """Build the bounded caller-visible U4 Batch operational catalogue.

    `batches_select` remains the authority for which rows exist in this result.
    Every supporting identity is read with the same caller-scoped client. A
    denied or RLS-hidden supporting record is therefore partial catalogue
    evidence, never a reason to substitute a privileged or inferred identity.

    The 51-row read makes the 50-row display boundary observable. Search and
    filters are deliberately described as applying to that displayed window;
    cursor pagination becomes mandatory once the boundary is reached in normal
    use (recorded in the U4 catalogue increment note).
    """
    batches = (client.table("batches").select(
        "id, batch_reference, family_id, plant_id, owner_user_id, sector_id, status, "
        "content_version, pricing_date, pricing_basis_release_id, "
        "pricing_basis_is_deliberate, created_at, created_by"
    ).order("created_at", desc=True).limit(51).execute()).data or []
    results_limited = len(batches) > 50
    batches = batches[:50]

    partial, denied = [], []

    def optional(section, query):
        rows, was_denied = _optional_caller_rows(query)
        if was_denied:
            denied.append(section)
        return rows

    def indexed(section, table, columns, ids):
        if not ids:
            return {}
        rows = optional(section, client.table(table).select(columns).in_("id", ids))
        return {str(row["id"]): row for row in rows}

    family_ids = list({row["family_id"] for row in batches})
    plant_ids = list({row["plant_id"] for row in batches})
    sector_ids = list({row["sector_id"] for row in batches if row.get("sector_id") is not None})
    release_ids = list({row["pricing_basis_release_id"] for row in batches
                        if row.get("pricing_basis_release_id") is not None})
    owner_ids = list({row["owner_user_id"] for row in batches})

    families = indexed(
        "customer_families", "customer_families",
        "id, group_customer_code, name, status", family_ids)
    plants = indexed("plants", "plants", "id, plant_code, name, status", plant_ids)
    sectors = indexed("sectors", "sectors", "id, sector_code, name, status", sector_ids)
    releases = indexed(
        "pricing_basis_releases", "pricing_basis_releases",
        "id, plant_id, release_name, status, effective_from, effective_until, "
        "is_automatic_default, approved_at, withdrawn_at", release_ids)
    owners = indexed("owner_identities", "app_users", "id, display_name, status", owner_ids)

    rows = []
    for batch in batches:
        row = dict(batch)
        row["customer_family"] = families.get(str(batch.get("family_id")))
        row["plant"] = plants.get(str(batch.get("plant_id")))
        row["sector"] = sectors.get(str(batch.get("sector_id")))
        row["pricing_basis_release"] = releases.get(
            str(batch.get("pricing_basis_release_id")))
        row["owner"] = owners.get(str(batch.get("owner_user_id")))

        if row["customer_family"] is None:
            partial.append("customer_family")
        if row["plant"] is None:
            partial.append("plant")
        if batch.get("sector_id") is not None and row["sector"] is None:
            partial.append("sector")
        if (batch.get("pricing_basis_release_id") is not None
                and row["pricing_basis_release"] is None):
            partial.append("pricing_basis_release")
        if row["owner"] is None:
            partial.append("owner_identity")
        row["details_partial"] = any((
            row["customer_family"] is None,
            row["plant"] is None,
            batch.get("sector_id") is not None and row["sector"] is None,
            batch.get("pricing_basis_release_id") is not None
            and row["pricing_basis_release"] is None,
            row["owner"] is None,
        ))
        rows.append(row)

    return {
        "rows": rows,
        "display_limit": 50,
        "results_limited": results_limited,
        "filter_scope": "displayed_newest_first_window",
        "details_partial": bool(partial or denied),
        "partial_sections": sorted(set(partial)),
        "denied_sections": sorted(set(denied)),
        "actions": {
            name: {"enabled": False, "reason": "backend_activation_pending"}
            for name in ("calculate", "send", "submit", "approve", "return", "issue")
        },
    }


def _read_batch_workspace(client, batch_id):
    """Assemble the caller-visible, read-only durable Batch workspace."""
    batch_rows = (client.table("batches").select(
        "id, batch_reference, family_id, plant_id, owner_user_id, sector_id, status, "
        "price_validity_from, price_validity_to, content_version, created_at, created_by, "
        "pricing_date, pricing_basis_release_id, pricing_basis_is_deliberate"
    ).eq("id", batch_id).limit(1).execute()).data or []
    if not batch_rows:
        return None

    batch = batch_rows[0]
    partial, denied = [], []

    def one(section, table, columns, row_id):
        if row_id is None:
            return None
        rows, was_denied = _optional_caller_rows(
            client.table(table).select(columns).eq("id", row_id).limit(1))
        if was_denied:
            denied.append(section)
        elif not rows:
            partial.append(section)
        return rows[0] if rows else None

    batch["plant"] = one("plant", "plants", "id, plant_code, name, status", batch["plant_id"])
    batch["family"] = one(
        "customer_family", "customer_families",
        "id, group_customer_code, name, status, content_version", batch["family_id"])
    batch["owner"] = one(
        "owner", "app_users", "id, display_name, status", batch["owner_user_id"])
    batch["sector"] = one(
        "sector", "sectors", "id, sector_code, name, status", batch.get("sector_id"))

    family_sectors, family_sectors_denied = _optional_caller_rows(
        client.table("customer_family_sectors").select(
            "family_id, sector_id, created_at"
        ).eq("family_id", batch["family_id"]))
    if family_sectors_denied:
        denied.append("family_sectors")
    for membership in family_sectors:
        if batch.get("sector") and membership.get("sector_id") == batch.get("sector_id"):
            membership["sector"] = batch["sector"]
        else:
            membership["sector"] = one(
                "family_sector_identity", "sectors", "id, sector_code, name, status",
                membership.get("sector_id"))
    family_sectors.sort(key=lambda membership: (
        membership.get("created_at") or "",
        membership.get("sector_id"),
    ))
    if not family_sectors and not family_sectors_denied:
        partial.append("family_sectors")
    batch["family_sectors"] = family_sectors

    profiles, profiles_denied = _optional_caller_rows(
        client.table("batch_profile_versions").select(
            "id, batch_id, version_no, waste_cbb_pct, waste_pp_pct, conv_box_rate, "
            "conv_pp_rate, margin_box_pct, margin_pp_pct, is_current, created_at, created_by"
        ).eq("batch_id", batch_id).eq("is_current", True).limit(1))
    if profiles_denied:
        denied.append("current_profile")
    elif not profiles:
        partial.append("current_profile")
    batch["current_profile"] = profiles[0] if profiles else None

    collaborators, collaborators_denied = _optional_caller_rows(
        client.table("batch_collaborators").select(
            "id, batch_id, app_user_id, status, created_at"
        ).eq("batch_id", batch_id).eq("status", "active"))
    if collaborators_denied:
        denied.append("collaborators")
    for collaborator in collaborators:
        collaborator["user"] = one(
            "collaborator_identity", "app_users", "id, display_name, status",
            collaborator.get("app_user_id"))
    batch["collaborators"] = collaborators

    locks, locks_denied = _optional_caller_rows(
        client.table("batch_edit_locks").select(
            "id, batch_id, holder_user_id, acquired_at, heartbeat_at, released_at"
        ).eq("batch_id", batch_id).limit(1))
    if locks_denied:
        denied.append("edit_lock")
    active_lock = next((lock for lock in locks if lock.get("released_at") is None), None)
    if active_lock:
        active_lock["holder"] = one(
            "lock_holder_identity", "app_users", "id, display_name, status",
            active_lock.get("holder_user_id"))
    batch["edit_lock"] = active_lock

    groups, groups_denied = _optional_caller_rows(
        client.table("pricing_groups").select(
            "id, batch_id, label, freight_mode, freight_basis_delivery_group_id, "
            "freight_manual_value, payment_terms_days, payment_terms_text, "
            "interest_override_pct, interest_override_derived_pct, interest_override_reason, "
            "interest_override_by, interest_override_at, status, content_version, "
            "legacy_freight_value, legacy_freight_source"
        ).eq("batch_id", batch_id))
    if groups_denied:
        denied.append("pricing_groups")

    deliveries, deliveries_denied = _optional_caller_rows(
        client.table("delivery_groups").select(
            "id, pricing_group_id, batch_id, label, bill_to_location_id, "
            "ship_to_location_id, route_notes, status"
        ).eq("batch_id", batch_id))
    if deliveries_denied:
        denied.append("delivery_groups")

    visible_locations = {}
    location_ids = {
        location_id for delivery in deliveries
        for location_id in (delivery.get("bill_to_location_id"), delivery.get("ship_to_location_id"))
        if location_id is not None
    }
    for location_id in location_ids:
        location = one(
            "customer_location", "customer_locations",
            "id, party_id, location_code, bill_to_eligible, ship_to_eligible, status, content_version",
            location_id)
        if location:
            visible_locations[str(location_id)] = location

    deliveries_by_group = {}
    for delivery in deliveries:
        delivery["bill_to_location"] = visible_locations.get(str(delivery.get("bill_to_location_id")))
        delivery["ship_to_location"] = visible_locations.get(str(delivery.get("ship_to_location_id")))
        deliveries_by_group.setdefault(str(delivery["pricing_group_id"]), []).append(delivery)
    for group in groups:
        group["delivery_groups"] = deliveries_by_group.get(str(group["id"]), [])
    batch["pricing_groups"] = groups

    rows, rows_denied = _optional_caller_rows(
        client.table("batch_rows").select(
            "id, lineage_id, batch_id, plant_id, pricing_group_id, sku_id, sku_version_id, "
            "proposed_construction_version_id, material_code, row_type, waste_override_pct, "
            "margin_override_pct, conv_override_rate, freight_override, sales_moq, volume, "
            "status, content_version, addon_printing, addon_stitching, addon_coating, "
            "addon_handling, addon_moq_charge, addon_packing, addon_other, addon_unloading, "
            "fluting_bcf"
        ).eq("batch_id", batch_id))
    if rows_denied:
        denied.append("batch_rows")

    for row in rows:
        row["sku"] = one(
            "row_sku", "skus",
            "id, plant_id, party_id, plant_item_code, status, replacement_sku_id, content_version",
            row.get("sku_id"))
        if row.get("sku"):
            row["customer"] = one(
                "row_customer", "parties",
                "id, customer_code, display_name, lifecycle_state, status",
                row["sku"].get("party_id"))
        else:
            row["customer"] = None

        row["sku_version"] = one(
            "row_sku_version", "sku_versions",
            "id, sku_id, plant_id, version_no, construction_version_id, is_price_driving, "
            "length_mm, width_mm, height_mm, box_type, ups, spec_bs, spec_bct, spec_ect, approved_at",
            row.get("sku_version_id"))

        effective_construction_version_id = row.get("proposed_construction_version_id")
        construction_origin = "row_proposed"
        if effective_construction_version_id is None:
            construction_origin = "sku_version"
            effective_construction_version_id = (row.get("sku_version") or {}).get(
                "construction_version_id")
        construction_version = one(
            "row_construction_version", "construction_versions",
            "id, construction_id, version_no, ply, flute_f1, flute_f2, board_gsm, "
            "effective_from, approved_at",
            effective_construction_version_id)
        construction = one(
            "row_construction", "constructions",
            "id, construction_code, name, status, surviving_construction_id",
            (construction_version or {}).get("construction_id"))
        row["effective_construction"] = {
            "version_id": effective_construction_version_id,
            "origin": construction_origin,
            "version": construction_version,
            "construction": construction,
            "details_partial": construction_version is None or construction is None,
        }

    rows.sort(key=lambda row: row.get("id") or 0)
    batch["batch_rows"] = rows

    sets, sets_denied = _optional_caller_rows(
        client.table("batch_sets").select(
            "id, batch_id, box_row_id, set_code, status, active_component_count, created_at"
        ).eq("batch_id", batch_id))
    if sets_denied:
        denied.append("batch_sets")
    memberships, memberships_denied = _optional_caller_rows(
        client.table("batch_set_memberships").select(
            "id, set_id, row_id, batch_id, role, status, created_at"
        ).eq("batch_id", batch_id))
    if memberships_denied:
        denied.append("batch_set_memberships")
    memberships_by_set = {}
    for membership in memberships:
        memberships_by_set.setdefault(str(membership["set_id"]), []).append(membership)
    for item in sets:
        item["memberships"] = sorted(
            memberships_by_set.get(str(item["id"]), []),
            key=lambda membership: membership.get("id") or 0)
    batch["batch_sets"] = sorted(sets, key=lambda item: item.get("id") or 0)

    batch["details_partial"] = bool(partial or denied)
    batch["partial_sections"] = sorted(set(partial))
    batch["denied_sections"] = sorted(set(denied))
    return batch


def _read_batch_row_options(client, batch_id):
    """Return exact caller-visible SKU/version choices for one governed Batch.

    The database remains authoritative for every write.  This read narrows the
    editor to the already-ratified U4 contract: the SKU belongs to the Batch
    Family and plant and is not withdrawn; its Construction authority is currently
    adopted at that plant.  A Proposed SKU and an unapproved Version are offered and
    labelled, as a Prospect is (Amendment 04 D-01).  No rendered label is later
    parsed back into an identity.
    """
    batches = (client.table("batches")
               .select("id, family_id, plant_id, status")
               .eq("id", batch_id).limit(1).execute()).data or []
    if not batches:
        return None
    batch = batches[0]

    memberships = (client.table("party_family_memberships")
                   .select("party_id, family_id, is_current")
                   .eq("family_id", batch["family_id"])
                   .eq("is_current", True).execute()).data or []
    family_party_ids = {membership.get("party_id") for membership in memberships}

    parties = []
    if family_party_ids:
        parties = (client.table("parties")
                   .select("id, customer_code, display_name, lifecycle_state, status")
                   .in_("id", sorted(family_party_ids))
                   .eq("status", "active").execute()).data or []
    party_by_id = {party["id"]: party for party in parties
                   if party.get("id") in family_party_ids}

    skus = (client.table("skus")
            .select("id, plant_id, party_id, plant_item_code, status, replacement_sku_id, content_version")
            .eq("plant_id", batch["plant_id"]).execute()).data or []
    # Amendment 04 D-01: a Proposed SKU is offered, as a Prospect is; only a withdrawn one is not.
    skus = [sku for sku in skus if sku.get("party_id") in party_by_id and sku.get("status") != "withdrawn"]
    sku_ids = {sku["id"] for sku in skus}

    versions = (client.table("sku_versions").select(
        "id, sku_id, plant_id, version_no, construction_version_id, is_price_driving, "
        "length_mm, width_mm, height_mm, box_type, ups, spec_bs, spec_bct, spec_ect, approved_at"
    ).eq("plant_id", batch["plant_id"]).execute()).data or []
    # Amendment 04 D-01: an unapproved version is quotable too; it is labelled, never hidden.
    versions = [{**version, "approved": version.get("approved_at") is not None} for version in versions
                if version.get("sku_id") in sku_ids]

    adoptions = (client.table("plant_construction_adoptions")
                 .select("plant_id, construction_version_id, status")
                 .eq("plant_id", batch["plant_id"])
                 .eq("status", "adopted").execute()).data or []
    adopted_version_ids = {adoption.get("construction_version_id") for adoption in adoptions}
    versions = [version for version in versions
                if version.get("construction_version_id") in adopted_version_ids]

    construction_versions = []
    if adopted_version_ids:
        construction_versions = (client.table("construction_versions").select(
            "id, construction_id, version_no, ply, flute_f1, flute_f2, board_gsm, "
            "effective_from, approved_at"
        ).in_("id", sorted(adopted_version_ids)).execute()).data or []
    construction_version_by_id = {
        version["id"]: version for version in construction_versions
        if version.get("id") in adopted_version_ids
    }
    construction_ids = {
        version.get("construction_id") for version in construction_version_by_id.values()
    }
    constructions = []
    if construction_ids:
        constructions = (client.table("constructions")
                         .select("id, construction_code, name, status, surviving_construction_id")
                         .in_("id", sorted(construction_ids)).execute()).data or []
    construction_by_id = {construction["id"]: construction for construction in constructions
                          if construction.get("id") in construction_ids}

    references = (client.table("sku_external_references")
                  .select("id, sku_id, plant_id, reference_kind, reference_value, status")
                  .eq("plant_id", batch["plant_id"])
                  .eq("status", "active").execute()).data or []
    references_by_sku = {}
    for reference in references:
        if reference.get("sku_id") in sku_ids:
            references_by_sku.setdefault(reference["sku_id"], []).append(reference)

    versions_by_sku = {}
    for version in versions:
        construction_version = construction_version_by_id.get(version["construction_version_id"])
        construction = construction_by_id.get(
            (construction_version or {}).get("construction_id"))
        decorated = dict(version)
        decorated["construction_version"] = construction_version
        decorated["construction"] = construction
        decorated["construction_details_partial"] = (
            construction_version is None or construction is None)
        versions_by_sku.setdefault(version["sku_id"], []).append(decorated)

    out = []
    for sku in skus:
        sku_versions = sorted(
            versions_by_sku.get(sku["id"], []),
            key=lambda version: version.get("version_no") or 0,
            reverse=True)
        if not sku_versions:
            continue
        out.append({
            **sku,
            "customer": party_by_id.get(sku.get("party_id")),
            "external_references": sorted(
                references_by_sku.get(sku["id"], []),
                key=lambda reference: (reference.get("reference_kind") or "",
                                       reference.get("reference_value") or "")),
            "versions": sku_versions,
        })
    out.sort(key=lambda sku: (
        (sku.get("customer") or {}).get("customer_code") or "",
        sku.get("plant_item_code") or "",
        sku.get("id") or 0,
    ))
    return {"batch": batch, "skus": out}


def _decorate_workspace_for_caller(batch):
    """Expose edit readiness without pretending the UI is an authority check."""
    caller_id = g.caller["id"]
    batch["caller_id"] = caller_id
    batch["caller_holds_lock"] = bool(
        batch.get("edit_lock")
        and batch["edit_lock"].get("holder_user_id") == caller_id
    )
    return batch


def _caller_table_write(label, operation):
    """Run one caller-token Data API write and return only stable errors."""
    try:
        return operation().execute(), None
    except APIError as exc:
        code = {
            "42501": "CAPABILITY_REQUIRED",
            "23503": "RECORD_NOT_FOUND",
            "23505": "TRANSITION_NOT_ALLOWED",
            "23514": "TRANSITION_NOT_ALLOWED",
            "55P03": "LOCK_UNAVAILABLE",
        }.get(exc.code)
        if code:
            app.logger.info("%s refused: %s %s -> %s", label, exc.code, exc.message, code)
            return None, _error(code)
        app.logger.error("unmapped Data API error from %s: %s %s", label, exc.code, exc.message)
        return None, _error("INTERNAL_ERROR")
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("%s timed out upstream: %s", label, exc)
            return None, _error("UPSTREAM_TIMEOUT")
        app.logger.error("%s failed: %s", label, exc)
        return None, _error("INTERNAL_ERROR")


def _delivery_location(client, location_id, role):
    """Validate one caller-visible active Location for its selected route role."""
    rows = (client.table("customer_locations")
            .select("id, party_id, location_code, bill_to_eligible, ship_to_eligible, status")
            .eq("id", location_id).limit(1).execute()).data or []
    if not rows:
        return None, _invalid_input(f"The selected {role} Location is unavailable to this caller.")
    location = rows[0]
    eligible_key = "bill_to_eligible" if role == "Bill-to" else "ship_to_eligible"
    if location.get("status") != "active" or location.get(eligible_key) is not True:
        return None, _invalid_input(f"The selected {role} Location is not active and eligible.")
    return location, None


def _delivery_group_input(client, data):
    """Validate the common create/edit route fields without timezone or identity inference."""
    pricing_group_id = _int_field(data, "pricing_group_id")
    bill_to_id = _int_field(data, "bill_to_location_id")
    ship_to_id = _int_field(data, "ship_to_location_id")
    if pricing_group_id is None or pricing_group_id < 1:
        return None, _invalid_input("pricing_group_id is required")
    if bill_to_id is None or bill_to_id < 1:
        return None, _invalid_input("bill_to_location_id is required")
    if ship_to_id is None or ship_to_id < 1:
        return None, _invalid_input("ship_to_location_id is required")
    label = (data.get("label") or "").strip()
    if len(label) > 120:
        return None, _invalid_input("label must be 120 characters or fewer")
    _bill_to, err = _delivery_location(client, bill_to_id, "Bill-to")
    if err:
        return None, err
    _ship_to, err = _delivery_location(client, ship_to_id, "Ship-to")
    if err:
        return None, err
    return {
        "pricing_group_id": pricing_group_id,
        "bill_to_location_id": bill_to_id,
        "ship_to_location_id": ship_to_id,
        "label": label or None,
    }, None


_BATCH_ROW_TYPES = {"box", "plate", "part_l", "part_w", "other"}
_BATCH_ROW_OVERRIDE_FIELDS = (
    "waste_override_pct", "margin_override_pct", "conv_override_rate", "freight_override",
)
_BATCH_ROW_ADDON_FIELDS = (
    "addon_printing", "addon_stitching", "addon_coating", "addon_handling",
    "addon_moq_charge", "addon_packing", "addon_other", "addon_unloading",
)
_BATCH_ROW_NUMERIC_FIELDS = (*_BATCH_ROW_OVERRIDE_FIELDS, *_BATCH_ROW_ADDON_FIELDS, "fluting_bcf")


def _batch_row_input(client, batch_id, data, existing_sku_id=None, existing_overrides=None):
    """Validate exact durable row identities without accepting display text."""
    pricing_group_id = _int_field(data, "pricing_group_id")
    sku_id = existing_sku_id if existing_sku_id is not None else _int_field(data, "sku_id")
    sku_version_id = _int_field(data, "sku_version_id")
    if pricing_group_id is None or pricing_group_id < 1:
        return None, _invalid_input("pricing_group_id is required")
    if sku_id is None or sku_id < 1:
        return None, _invalid_input("sku_id is required")
    if sku_version_id is None or sku_version_id < 1:
        return None, _invalid_input("sku_version_id is required")
    row_type = (data.get("row_type") or "").strip().lower()
    if row_type not in _BATCH_ROW_TYPES:
        return None, _invalid_input("row_type must be box, plate, part_l, part_w or other")
    material_code = data.get("material_code")
    if material_code is not None:
        material_code = str(material_code).strip() or None
        if material_code is not None and len(material_code) > 160:
            return None, _invalid_input("material_code must be 160 characters or fewer")

    options = _read_batch_row_options(client, batch_id)
    if options is None:
        return None, _error("RECORD_NOT_FOUND")
    sku = next((item for item in options["skus"] if item["id"] == sku_id), None)
    version = next((item for item in (sku or {}).get("versions", [])
                    if item["id"] == sku_version_id), None)
    if sku is None or version is None:
        return None, _invalid_input(
            "The selected SKU Version is not an approved, plant-adopted option for this Batch Family.")

    groups = (client.table("pricing_groups").select("id, batch_id, status")
              .eq("id", pricing_group_id).eq("batch_id", batch_id).limit(1).execute()).data or []
    if not groups:
        return None, _error("RECORD_NOT_FOUND")
    if groups[0].get("status") != "active":
        return None, _error("TRANSITION_NOT_ALLOWED")
    numeric_values = {}
    for key in _BATCH_ROW_NUMERIC_FIELDS:
        if key not in data and existing_overrides is not None:
            numeric_values[key] = existing_overrides.get(key)
            continue
        numeric_values[key], err = _optional_nonnegative_numeric(data, key)
        if err:
            return None, err
    if numeric_values["fluting_bcf"] is not None and numeric_values["fluting_bcf"] > 0.30:
        return None, _invalid_input("fluting_bcf must be blank or between 0 and 0.30")
    return {
        "pricing_group_id": pricing_group_id,
        "sku_id": sku_id,
        "sku_version_id": sku_version_id,
        "row_type": row_type,
        "material_code": material_code,
        **numeric_values,
    }, None


def _workspace_write_response(client, batch_id, mutation, status=200):
    """Read back the state after a write; timeout means the write outcome is unknown."""
    try:
        batch = _read_batch_workspace(client, batch_id)
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("%s read-back timed out upstream: %s", mutation, exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    if batch is None:
        return _error("RECORD_NOT_FOUND")
    return jsonify({"batch": _decorate_workspace_for_caller(batch), "mutation": mutation}), status


def _rpc_scalar_id(result):
    """Accept the scalar shapes returned by PostgREST for a bigint RPC."""
    value = getattr(result, "data", None)
    if isinstance(value, list) and len(value) == 1:
        value = value[0]
    if isinstance(value, dict) and len(value) == 1:
        value = next(iter(value.values()))
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


@app.route("/batches/create-options", methods=["GET"])
@require_auth
def get_batch_create_options():
    """Return only caller-visible identities needed to create a governed Batch."""
    if "read_party_master" not in (g.caller.get("group_capabilities") or []):
        return _error("CAPABILITY_REQUIRED")

    client = get_supabase_for_caller(g.access_token)
    families = (client.table("customer_families")
                .select("id, group_customer_code, name, status")
                .eq("status", "active").execute()).data or []
    memberships = (client.table("party_family_memberships")
                   .select("party_id, family_id, is_current")
                   .eq("is_current", True).execute()).data or []
    parties = (client.table("parties")
               .select("id, customer_code, display_name, lifecycle_state, status")
               .eq("status", "active").execute()).data or []
    plants = (client.table("plants")
              .select("id, plant_code, name, status")
              .eq("status", "active").execute()).data or []

    sectors, sectors_denied = _optional_caller_rows(
        client.table("sectors").select("id, sector_code, name, status").eq("status", "active"))
    family_sectors, family_sectors_denied = _optional_caller_rows(
        client.table("customer_family_sectors").select("family_id, sector_id, created_at"))

    maker_codes = {
        code for code, capabilities in (g.caller.get("plant_capabilities") or {}).items()
        if isinstance(capabilities, list) and "make_quote" in capabilities
    }
    plants = [plant for plant in plants if plant.get("plant_code") in maker_codes]

    party_by_id = {str(party["id"]): party for party in parties}
    members_by_family = {}
    for membership in memberships:
        party = party_by_id.get(str(membership.get("party_id")))
        if party:
            members_by_family.setdefault(str(membership.get("family_id")), []).append(party)
    for family in families:
        family["members"] = sorted(
            members_by_family.get(str(family["id"]), []),
            key=lambda party: party.get("customer_code") or party.get("display_name") or "")
        ordered_sector_memberships = sorted(
            (membership for membership in family_sectors
             if membership.get("family_id") == family.get("id")
                and membership.get("sector_id") is not None),
            key=lambda membership: (
                membership.get("created_at") or "",
                membership.get("sector_id"),
            ))
        family["sector_ids"] = [membership["sector_id"] for membership in ordered_sector_memberships]

    families.sort(key=lambda family: family.get("group_customer_code") or family.get("name") or "")
    plants.sort(key=lambda plant: plant.get("plant_code") or "")
    sectors.sort(key=lambda sector: sector.get("sector_code") or "")
    return jsonify({
        "families": families,
        "plants": plants,
        "sectors": sectors,
        "sectors_denied": sectors_denied,
        "family_sectors_denied": family_sectors_denied,
        "mutation": "create_batch_rpc_only",
    })


@app.route("/batches", methods=["POST"])
@require_auth
def create_batch_route():
    """Create and read back one governed Batch through public.create_batch."""
    data = request.get_json(force=True) or {}
    family_id = _int_field(data, "family_id")
    plant_id = _int_field(data, "plant_id")
    if family_id is None or family_id < 1:
        return _invalid_input("family_id is required")
    if plant_id is None or plant_id < 1:
        return _invalid_input("plant_id is required")
    sector_id = _int_field(data, "sector_id")
    if sector_id is None or sector_id < 1:
        return _invalid_input("sector_id is required")

    client = get_supabase_for_caller(g.access_token)
    result, err = _rpc_call(client, "create_batch", {
        "p_family": family_id,
        "p_plant": plant_id,
        "p_sector": sector_id,
    })
    if err:
        return err
    batch_id = _rpc_scalar_id(result)
    if batch_id is None:
        app.logger.error("create_batch returned an invalid scalar identity")
        return _error("INTERNAL_ERROR")
    return _workspace_write_response(client, batch_id, "create_batch", status=201)


@app.route("/batches/<int:batch_id>/lock/acquire", methods=["POST"])
@require_auth
def acquire_batch_lock_route(batch_id):
    """Acquire an available governed Batch lock and read back its exact holder."""
    client = get_supabase_for_caller(g.access_token)
    _result, err = _rpc_call(client, "acquire_batch_lock", {"p_batch": batch_id})
    if err:
        return err
    return _workspace_write_response(client, batch_id, "acquire_batch_lock")


@app.route("/batches/<int:batch_id>/lock/reclaim", methods=["POST"])
@require_auth
def reclaim_batch_lock_route(batch_id):
    """Reclaim a stale Batch lock only if its observed holder still matches."""
    data = request.get_json(silent=True) or {}
    expected_holder_id = _int_field(data, "expected_holder_id")
    if expected_holder_id is None or expected_holder_id < 1:
        return _invalid_input("expected_holder_id must be a positive integer")

    client = get_supabase_for_caller(g.access_token)
    _result, err = _rpc_call(client, "reclaim_batch_lock", {
        "p_batch": batch_id,
        "p_expected_holder": expected_holder_id,
    })
    if err:
        return err
    return _workspace_write_response(client, batch_id, "reclaim_batch_lock")


@app.route("/batches/<int:batch_id>/lock/heartbeat", methods=["POST"])
@require_auth
def heartbeat_batch_lock_route(batch_id):
    """Maintain the caller's existing Batch lock without changing Batch content."""
    client = get_supabase_for_caller(g.access_token)
    _result, err = _rpc_call(client, "heartbeat_batch_lock", {"p_batch": batch_id})
    if err:
        return err
    return jsonify({"mutation": "heartbeat_batch_lock"})


@app.route("/batches/<int:batch_id>/lock/release", methods=["POST"])
@require_auth
def release_batch_lock_route(batch_id):
    """Release the caller's Batch lock; the database operation is idempotent."""
    client = get_supabase_for_caller(g.access_token)
    _result, err = _rpc_call(client, "release_batch_lock", {"p_batch": batch_id})
    if err:
        return err
    return jsonify({"mutation": "release_batch_lock"})


@app.route("/batches/pricing-basis", methods=["GET"])
@require_auth
def get_batch_pricing_basis_by_reference():
    """Open a durable Batch by its permanent reference, entirely as the caller."""
    reference = (request.args.get("reference") or "").strip()
    if not reference:
        return _invalid_input("reference is required")
    try:
        batch = _read_batch_pricing_basis(
            get_supabase_for_caller(g.access_token), batch_reference=reference)
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("Batch Pricing Basis read timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    if batch is None:
        return _error("RECORD_NOT_FOUND")
    return jsonify({"batch": batch, "mutations": "governed_rpc_only"})


@app.route("/batches/<int:batch_id>/pricing-basis", methods=["GET"])
@require_auth
def get_batch_pricing_basis(batch_id):
    """Reopen the persisted Pricing Basis selection for one caller-visible Batch."""
    try:
        batch = _read_batch_pricing_basis(
            get_supabase_for_caller(g.access_token), batch_id=batch_id)
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("Batch Pricing Basis reopen timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    if batch is None:
        return _error("RECORD_NOT_FOUND")
    return jsonify({"batch": batch, "mutations": "governed_rpc_only"})


@app.route("/batches/<int:batch_id>/workspace", methods=["GET"])
@require_auth
def get_batch_workspace(batch_id):
    """Load caller-visible Batch structure; separate routes govern Delivery Group writes."""
    try:
        batch = _read_batch_workspace(get_supabase_for_caller(g.access_token), batch_id)
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("Batch workspace read timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    if batch is None:
        return _error("RECORD_NOT_FOUND")
    return jsonify({"batch": _decorate_workspace_for_caller(batch), "mode": "governed"})


@app.route("/batches/catalogue", methods=["GET"])
@require_auth
def get_batch_catalogue():
    """List the bounded caller-visible durable Batch operational window."""
    try:
        catalogue = _read_batch_catalogue(get_supabase_for_caller(g.access_token))
    except APIError as exc:
        if exc.code == "42501":
            return _error("CAPABILITY_REQUIRED")
        raise
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("Batch catalogue read timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    return jsonify({
        "catalogue": catalogue,
        "mode": "governed_read_only",
        "authority": "caller_token_rls_only",
    })


@app.route("/quotes/workspace", methods=["GET"])
@require_auth
def get_quote_workspace():
    """Open one immutable caller-visible Quote by reference, revision or Batch id."""
    reference = (request.args.get("reference") or "").strip()
    revision_id_raw = (request.args.get("revision_id") or "").strip()
    batch_id_raw = (request.args.get("batch_id") or "").strip()
    if sum(bool(value) for value in (reference, revision_id_raw, batch_id_raw)) != 1:
        return _invalid_input("provide exactly one of reference, revision_id or batch_id")
    revision_id = None
    if revision_id_raw:
        try:
            revision_id = int(revision_id_raw)
        except ValueError:
            return _invalid_input("revision_id must be a positive integer")
        if revision_id <= 0:
            return _invalid_input("revision_id must be a positive integer")
    batch_id = None
    if batch_id_raw:
        try:
            batch_id = int(batch_id_raw)
        except ValueError:
            return _invalid_input("batch_id must be a positive integer")
        if batch_id <= 0:
            return _invalid_input("batch_id must be a positive integer")
    try:
        quote = _read_quote_workspace(
            get_supabase_for_caller(g.access_token), reference or None, revision_id, batch_id)
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("Quote workspace read timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    if quote is None:
        return _error("RECORD_NOT_FOUND")
    return jsonify({
        "quote": quote,
        "mode": "governed_read_only",
        "authority": "caller_token_rls_only",
    })


@app.route("/quotes/catalogue", methods=["GET"])
@require_auth
def get_quote_catalogue():
    """List a bounded caller-visible approval inbox or Quote history."""
    view = (request.args.get("view") or "").strip().lower()
    if view not in ("inbox", "history"):
        return _invalid_input("view must be inbox or history")
    if view == "inbox" and not any(
            "check_quote" in capabilities
            for capabilities in (g.caller.get("plant_capabilities") or {}).values()):
        return _error("CAPABILITY_REQUIRED")
    try:
        catalogue = _read_quote_catalogue(get_supabase_for_caller(g.access_token), view)
    except APIError as exc:
        if exc.code == "42501":
            return _error("CAPABILITY_REQUIRED")
        raise
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("Quote catalogue read timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    return jsonify({
        "catalogue": catalogue,
        "mode": "governed_read_only",
        "authority": "caller_token_rls_only",
    })


@app.route("/batches/<int:batch_id>/row-options", methods=["GET"])
@require_auth
def get_batch_row_options(batch_id):
    """Load exact SKU/Version/Construction identities eligible for row addition."""
    try:
        options = _read_batch_row_options(get_supabase_for_caller(g.access_token), batch_id)
    except APIError as exc:
        if exc.code == "42501":
            return _error("CAPABILITY_REQUIRED")
        raise
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("Batch row options timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    if options is None:
        return _error("RECORD_NOT_FOUND")
    return jsonify({
        **options,
        "selection_contract": "approved_sku_version_with_plant_adopted_construction",
        "mutations": "caller_token_rls_only",
    })


@app.route("/batches/<int:batch_id>/profile", methods=["POST"])
@require_auth
def revise_batch_profile_route(batch_id):
    """Create the next immutable Batch Profile version through its governed CAS RPC."""
    data = request.get_json(force=True) or {}
    expected = _int_field(data, "expected_content_version")
    if expected is None or expected < 1:
        return _invalid_input("expected_content_version is required")
    fields = (
        "waste_cbb_pct", "waste_pp_pct", "conv_box_rate",
        "conv_pp_rate", "margin_box_pct", "margin_pp_pct",
    )
    values = {}
    for field in fields:
        values[field], err = _optional_nonnegative_numeric(data, field)
        if err:
            return err
    client = get_supabase_for_caller(g.access_token)
    _result, err = _rpc_call(client, "revise_batch_profile", {
        "p_batch": batch_id,
        "p_expected_content_version": expected,
        **{f"p_{field}": value for field, value in values.items()},
    })
    if err:
        return err
    return _workspace_write_response(client, batch_id, "revise_batch_profile")


@app.route("/batches/<int:batch_id>/sets", methods=["POST"])
@require_auth
def create_batch_set(batch_id):
    """Start a durable SET around one Box; its status remains database-derived."""
    data = request.get_json(force=True) or {}
    box_row_id = _int_field(data, "box_row_id")
    set_code = (data.get("set_code") or "").strip()
    if box_row_id is None or box_row_id < 1:
        return _invalid_input("box_row_id is required")
    if not set_code or len(set_code) > 80:
        return _invalid_input("set_code is required and must be at most 80 characters")
    client = get_supabase_for_caller(g.access_token)
    try:
        box_rows = (client.table("batch_rows").select("id, batch_id, row_type, status")
                    .eq("id", box_row_id).eq("batch_id", batch_id).limit(1).execute()).data or []
    except APIError as exc:
        if exc.code == "42501":
            return _error("CAPABILITY_REQUIRED")
        raise
    if not box_rows:
        return _error("RECORD_NOT_FOUND")
    if box_rows[0].get("row_type") != "box" or box_rows[0].get("status") != "active":
        return _invalid_input("A SET parent must be an active Box row")
    result, err = _caller_table_write("create Batch SET", lambda: client.table("batch_sets").insert({
        "batch_id": batch_id, "box_row_id": box_row_id,
        "set_code": set_code, "created_by": g.caller["id"],
    }))
    if err:
        return err
    if not (result.data or []):
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "create_batch_set", status=201)


@app.route("/batches/<int:batch_id>/sets/<int:set_id>/memberships", methods=["POST"])
@require_auth
def create_batch_set_membership(batch_id, set_id):
    """Attach one non-Box component; database triggers activate/recount the SET."""
    data = request.get_json(force=True) or {}
    row_id = _int_field(data, "row_id")
    role = (data.get("role") or "").strip()
    if row_id is None or row_id < 1:
        return _invalid_input("row_id is required")
    if role not in ("plate", "partition", "other"):
        return _invalid_input("role must be plate, partition or other")
    client = get_supabase_for_caller(g.access_token)
    try:
        sets = (client.table("batch_sets").select("id, batch_id, box_row_id")
                .eq("id", set_id).eq("batch_id", batch_id).limit(1).execute()).data or []
        rows = (client.table("batch_rows").select("id, batch_id, row_type, status")
                .eq("id", row_id).eq("batch_id", batch_id).limit(1).execute()).data or []
    except APIError as exc:
        if exc.code == "42501":
            return _error("CAPABILITY_REQUIRED")
        raise
    if not sets or not rows:
        return _error("RECORD_NOT_FOUND")
    if rows[0].get("row_type") == "box" or rows[0].get("status") != "active":
        return _invalid_input("A SET component must be an active non-Box row")
    result, err = _caller_table_write(
        "attach Batch SET component", lambda: client.table("batch_set_memberships").insert({
            "set_id": set_id, "row_id": row_id, "batch_id": batch_id,
            "role": role, "status": "active", "created_by": g.caller["id"],
        }))
    if err:
        return err
    if not (result.data or []):
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "create_batch_set_membership", status=201)


@app.route("/batches/<int:batch_id>/set-memberships/<int:membership_id>", methods=["PATCH"])
@require_auth
def update_batch_set_membership(batch_id, membership_id):
    """Remove/reactivate a component or revise its role; SET state stays derived."""
    data = request.get_json(force=True) or {}
    status = (data.get("status") or "").strip()
    role = (data.get("role") or "").strip()
    if status not in ("active", "removed"):
        return _invalid_input("status must be active or removed")
    if role not in ("plate", "partition", "other"):
        return _invalid_input("role must be plate, partition or other")
    client = get_supabase_for_caller(g.access_token)
    try:
        existing = (client.table("batch_set_memberships").select("id, batch_id")
                    .eq("id", membership_id).eq("batch_id", batch_id).limit(1).execute()).data or []
    except APIError as exc:
        if exc.code == "42501":
            return _error("CAPABILITY_REQUIRED")
        raise
    if not existing:
        return _error("RECORD_NOT_FOUND")
    result, err = _caller_table_write(
        "revise Batch SET component", lambda: client.table("batch_set_memberships")
        .update({"status": status, "role": role})
        .eq("id", membership_id).eq("batch_id", batch_id))
    if err:
        return err
    if not (result.data or []):
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "update_batch_set_membership")


@app.route("/batches/<int:batch_id>/rows", methods=["POST"])
@require_auth
def create_batch_row(batch_id):
    """Add one durable Batch row through caller-token RLS and the active lock."""
    data = request.get_json(force=True) or {}
    client = get_supabase_for_caller(g.access_token)
    values, err = _batch_row_input(client, batch_id, data)
    if err:
        return err

    batch = (client.table("batches").select("id, plant_id, status")
             .eq("id", batch_id).limit(1).execute()).data or []
    if not batch:
        return _error("RECORD_NOT_FOUND")
    if batch[0].get("status") not in ("working", "sent"):
        return _error("TRANSITION_NOT_ALLOWED")

    payload = {
        **values,
        "batch_id": batch_id,
        "plant_id": batch[0]["plant_id"],
        "status": "active",
        "created_by": g.caller["id"],
    }
    result, err = _caller_table_write(
        "create Batch row", lambda: client.table("batch_rows").insert(payload))
    if err:
        return err
    if not (result.data or []):
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "create_batch_row", status=201)


@app.route("/batches/<int:batch_id>/rows/<int:row_id>", methods=["PATCH"])
@require_auth
def update_batch_row(batch_id, row_id):
    """Revise mutable row identity fields using the row content-version CAS token."""
    data = request.get_json(force=True) or {}
    expected = _int_field(data, "expected_content_version")
    if expected is None or expected < 1:
        return _invalid_input("expected_content_version is required")

    client = get_supabase_for_caller(g.access_token)
    existing = (client.table("batch_rows")
                .select("id, batch_id, sku_id, status, content_version, waste_override_pct, "
                        "margin_override_pct, conv_override_rate, freight_override, "
                        "addon_printing, addon_stitching, addon_coating, addon_handling, "
                        "addon_moq_charge, addon_packing, addon_other, addon_unloading, fluting_bcf")
                .eq("id", row_id).eq("batch_id", batch_id).limit(1).execute()).data or []
    if not existing:
        return _error("RECORD_NOT_FOUND")
    row = existing[0]
    if row.get("status") != "active":
        return _error("TRANSITION_NOT_ALLOWED")
    if row.get("content_version") != expected:
        return _error("STALE_VERSION")

    values, err = _batch_row_input(
        client, batch_id, data, existing_sku_id=row["sku_id"], existing_overrides=row)
    if err:
        return err
    updates = {key: values[key] for key in (
        "pricing_group_id", "sku_version_id", "row_type", "material_code",
        *_BATCH_ROW_NUMERIC_FIELDS)}
    result, err = _caller_table_write(
        "update Batch row",
        lambda: client.table("batch_rows").update(updates)
        .eq("id", row_id).eq("batch_id", batch_id)
        .eq("content_version", expected))
    if err:
        return err
    if not (result.data or []):
        latest = (client.table("batch_rows").select("content_version")
                  .eq("id", row_id).eq("batch_id", batch_id).limit(1).execute()).data or []
        if latest and latest[0].get("content_version") != expected:
            return _error("STALE_VERSION")
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "update_batch_row")


@app.route("/batches/<int:batch_id>/rows/<int:row_id>/status", methods=["PATCH"])
@require_auth
def update_batch_row_status(batch_id, row_id):
    """Reversibly remove or restore one durable row with its CAS token."""
    data = request.get_json(silent=True) or {}
    expected = _int_field(data, "expected_content_version")
    status = (data.get("status") or "").strip().lower()
    if expected is None or expected < 1:
        return _invalid_input("expected_content_version is required")
    if status not in ("active", "removed"):
        return _invalid_input("status must be active or removed")

    client = get_supabase_for_caller(g.access_token)
    rows, denied = _optional_caller_rows(
        client.table("batch_rows").select("id, batch_id, status, content_version")
        .eq("id", row_id).eq("batch_id", batch_id).limit(1))
    if denied:
        return _error("CAPABILITY_REQUIRED")
    if not rows:
        return _error("RECORD_NOT_FOUND")
    row = rows[0]
    if row.get("content_version") != expected:
        return _error("STALE_VERSION")
    if row.get("status") == status:
        return _invalid_input(f"Batch row is already {status}")

    result, err = _caller_table_write(
        f"mark Batch row {status}",
        lambda: client.table("batch_rows").update({"status": status})
        .eq("id", row_id).eq("batch_id", batch_id).eq("content_version", expected))
    if err:
        return err
    if not (result.data or []):
        latest = (client.table("batch_rows").select("content_version")
                  .eq("id", row_id).eq("batch_id", batch_id).limit(1).execute()).data or []
        if latest and latest[0].get("content_version") != expected:
            return _error("STALE_VERSION")
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "update_batch_row_status")


@app.route("/batches/<int:batch_id>/rows/<int:row_id>/effective-inputs", methods=["GET"])
@require_auth
def get_batch_row_effective_inputs(batch_id, row_id):
    """Read governed effective inputs and compare them with any persisted calculation.

    This invokes the existing secret-independent gatherer; it never calls the
    calculation writer and therefore cannot persist a calculation.
    """
    client = get_supabase_for_caller(g.access_token)
    try:
        rows = (client.table("batch_rows").select("id, batch_id, status, content_version")
                .eq("id", row_id).eq("batch_id", batch_id).limit(1).execute()).data or []
    except APIError as exc:
        if exc.code == "42501":
            return _error("CAPABILITY_REQUIRED")
        raise
    if not rows:
        return _error("RECORD_NOT_FOUND")

    result, err = _rpc_call(client, "calculate_inputs", {"p_batch_row_id": row_id})
    if err:
        return err
    resolution = result.data or {}
    binding = resolution.get("binding") or {}
    calculations, denied = _optional_caller_rows(
        client.table("batch_calculations").select(
            "id, batch_row_id, batch_id, calculation_fingerprint, presentation_fingerprint, "
            "engine_version, schema_version, computed_by, computed_at"
        ).eq("batch_row_id", row_id).eq("batch_id", batch_id).limit(1))
    calculation = calculations[0] if calculations else None
    if denied:
        freshness = "unknown"
    elif calculation is None:
        freshness = "not_calculated"
    elif calculation.get("calculation_fingerprint") != binding.get("calculation_fingerprint"):
        freshness = "calculation_stale"
    elif calculation.get("presentation_fingerprint") != binding.get("presentation_fingerprint"):
        freshness = "needs_send_only"
    else:
        freshness = "fresh"
    return jsonify({
        "resolution": resolution,
        "calculation": calculation,
        "calculation_details_denied": denied,
        "freshness": freshness,
        "mutation": "none",
        "governed_calculate": "available",
    })


_CALCULATE_EXECUTOR_ERROR_MAP = {
    "AUTH_REQUIRED": "AUTH_REQUIRED",
    "42501": "CAPABILITY_REQUIRED",
    "P0002": "RECORD_NOT_FOUND",
    "23503": "RECORD_NOT_FOUND",
    "PT409": "STALE_VERSION",
    "PT422": "CALCULATION_NOT_READY",
    "55P03": "LOCK_UNAVAILABLE",
    "EXECUTOR_NOT_PROVISIONED": "CALCULATION_EXECUTOR_UNAVAILABLE",
}


@app.route("/batches/<int:batch_id>/rows/<int:row_id>/calculate", methods=["POST"])
@require_auth
def calculate_batch_row_route(batch_id, row_id):
    """Run the trusted executor and database writer as the authenticated caller."""
    client = get_supabase_for_caller(g.access_token)
    try:
        rows = (client.table("batch_rows").select("id, batch_id, status, content_version")
                .eq("id", row_id).eq("batch_id", batch_id).limit(1).execute()).data or []
    except APIError as exc:
        if exc.code == "42501":
            return _error("CAPABILITY_REQUIRED")
        raise
    except Exception as exc:
        if _is_upstream_timeout(exc):
            return _error("UPSTREAM_TIMEOUT")
        raise
    if not rows:
        return _error("RECORD_NOT_FOUND")

    try:
        outcome = invoke_calculation_executor(g.access_token, row_id)
    except Exception as exc:
        if _is_upstream_timeout(exc):
            app.logger.error("Calculate executor timed out for Batch row %s", row_id)
            return _error("UPSTREAM_TIMEOUT")
        app.logger.error("Calculate executor transport failed for Batch row %s: %s",
                         row_id, type(exc).__name__)
        return _error("CALCULATION_EXECUTOR_UNAVAILABLE")

    if outcome.get("status") != 200:
        upstream_code = outcome.get("error_code")
        code = _CALCULATE_EXECUTOR_ERROR_MAP.get(upstream_code)
        if code is None:
            code = "CALCULATION_EXECUTION_FAILED"
            app.logger.error("Calculate executor refused Batch row %s with stable code %s",
                             row_id, upstream_code or "missing")
        else:
            app.logger.info("Calculate executor refused Batch row %s: %s -> %s",
                            row_id, upstream_code, code)
        return _error(code)

    calculation_id = outcome.get("batch_calculation_id")
    if isinstance(calculation_id, str) and calculation_id.isdigit():
        calculation_id = int(calculation_id)
    if isinstance(calculation_id, bool) or not isinstance(calculation_id, int) or calculation_id <= 0:
        app.logger.error("Calculate executor returned no valid calculation id for Batch row %s", row_id)
        return _error("CALCULATION_EXECUTION_FAILED")
    return jsonify({
        "batch_calculation_id": calculation_id,
        "batch_row_id": row_id,
        "mutation": "calculate_batch_row",
        "authority": "caller_token_trusted_executor_database_writer",
    })


@app.route("/batches/<int:batch_id>/send", methods=["POST"])
@require_auth
def send_batch_route(batch_id):
    """Atomically create the first immutable, unnumbered draft Quote candidate."""
    data = request.get_json(silent=True) or {}
    expected = _int_field(data, "expected_content_version")
    if expected is None or expected < 1:
        return _invalid_input("expected_content_version must be a positive integer")

    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "send_batch",
        {"p_batch": batch_id, "p_expected_content_version": expected},
        error_map={"PT422": "SEND_NOT_READY"},
    )
    if err:
        return err
    revision_id = _rpc_scalar_id(result)
    if revision_id is None:
        app.logger.error("send_batch returned no valid Quote revision id for Batch %s", batch_id)
        return _error("INTERNAL_ERROR")
    return jsonify({
        "revision_id": revision_id,
        "batch_id": batch_id,
        "quote_candidate_status": "draft",
        "mutation": "atomic_send",
        "authority": "caller_token_database_rpc",
    }), 201


@app.route("/batches/<int:batch_id>/pricing-groups", methods=["POST"])
@require_auth
def create_pricing_group(batch_id):
    """Add an empty Pricing Group for a genuinely different price schedule."""
    data = request.get_json(silent=True) or {}
    label_value = data.get("label")
    if label_value is not None and not isinstance(label_value, str):
        return _invalid_input("label must be text or blank")
    label = (label_value or "").strip()
    if len(label) > 120:
        return _invalid_input("label must be 120 characters or fewer")

    client = get_supabase_for_caller(g.access_token)
    batches = (client.table("batches").select("id, status")
               .eq("id", batch_id).limit(1).execute()).data or []
    if not batches:
        return _error("RECORD_NOT_FOUND")
    if batches[0].get("status") not in ("working", "sent"):
        return _error("TRANSITION_NOT_ALLOWED")

    result, err = _caller_table_write(
        "create Pricing Group", lambda: client.table("pricing_groups").insert({
            "batch_id": batch_id,
            "label": label or None,
            "status": "active",
            "created_by": g.caller["id"],
        }))
    if err:
        return err
    if not (result.data or []):
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "create_pricing_group", status=201)


@app.route("/batches/<int:batch_id>/pricing-groups/<int:pricing_group_id>/status", methods=["PATCH"])
@require_auth
def update_pricing_group_status(batch_id, pricing_group_id):
    """Reversibly remove or restore one Pricing Group with its CAS token."""
    data = request.get_json(silent=True) or {}
    expected = _int_field(data, "expected_content_version")
    status = (data.get("status") or "").strip().lower()
    if expected is None or expected < 1:
        return _invalid_input("expected_content_version is required")
    if status not in ("active", "removed"):
        return _invalid_input("status must be active or removed")

    client = get_supabase_for_caller(g.access_token)
    groups, denied = _optional_caller_rows(
        client.table("pricing_groups").select("id, batch_id, status, content_version")
        .eq("id", pricing_group_id).eq("batch_id", batch_id).limit(1))
    if denied:
        return _error("CAPABILITY_REQUIRED")
    if not groups:
        return _error("RECORD_NOT_FOUND")
    group = groups[0]
    if group.get("content_version") != expected:
        return _error("STALE_VERSION")
    if group.get("status") == status:
        return _invalid_input(f"Pricing Group is already {status}")

    result, err = _caller_table_write(
        f"mark Pricing Group {status}",
        lambda: client.table("pricing_groups").update({"status": status})
        .eq("id", pricing_group_id).eq("batch_id", batch_id)
        .eq("content_version", expected))
    if err:
        return err
    if not (result.data or []):
        latest = (client.table("pricing_groups").select("content_version")
                  .eq("id", pricing_group_id).eq("batch_id", batch_id)
                  .limit(1).execute()).data or []
        if latest and latest[0].get("content_version") != expected:
            return _error("STALE_VERSION")
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "update_pricing_group_status")


@app.route("/batches/<int:batch_id>/delivery-groups", methods=["POST"])
@require_auth
def create_delivery_group(batch_id):
    """Add one route under an existing Pricing Group through caller-token RLS."""
    data = request.get_json(force=True) or {}
    client = get_supabase_for_caller(g.access_token)
    values, err = _delivery_group_input(client, data)
    if err:
        return err
    group_rows = (client.table("pricing_groups").select("id, batch_id, status")
                  .eq("id", values["pricing_group_id"])
                  .eq("batch_id", batch_id).limit(1).execute()).data or []
    if not group_rows:
        return _error("RECORD_NOT_FOUND")
    if group_rows[0].get("status") != "active":
        return _error("TRANSITION_NOT_ALLOWED")

    payload = {**values, "batch_id": batch_id, "status": "active", "created_by": g.caller["id"]}
    result, err = _caller_table_write(
        "create Delivery Group", lambda: client.table("delivery_groups").insert(payload))
    if err:
        return err
    if not (result.data or []):
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "create_delivery_group", status=201)


@app.route("/batches/<int:batch_id>/delivery-groups/<int:delivery_group_id>", methods=["PATCH"])
@require_auth
def update_delivery_group(batch_id, delivery_group_id):
    """Complete or revise one caller-visible route while the Batch lock is held."""
    data = request.get_json(force=True) or {}
    client = get_supabase_for_caller(g.access_token)
    values, err = _delivery_group_input(client, data)
    if err:
        return err
    existing = (client.table("delivery_groups").select("id, batch_id, pricing_group_id, status")
                .eq("id", delivery_group_id).eq("batch_id", batch_id)
                .eq("pricing_group_id", values["pricing_group_id"]).limit(1).execute()).data or []
    if not existing:
        return _error("RECORD_NOT_FOUND")
    if existing[0].get("status") != "active":
        return _error("TRANSITION_NOT_ALLOWED")

    updates = {key: values[key] for key in (
        "label", "bill_to_location_id", "ship_to_location_id")}
    result, err = _caller_table_write(
        "update Delivery Group",
        lambda: client.table("delivery_groups").update(updates)
        .eq("id", delivery_group_id).eq("batch_id", batch_id)
        .eq("pricing_group_id", values["pricing_group_id"]))
    if err:
        return err
    if not (result.data or []):
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "update_delivery_group")


@app.route("/batches/<int:batch_id>/delivery-groups/<int:delivery_group_id>/status", methods=["PATCH"])
@require_auth
def update_delivery_group_status(batch_id, delivery_group_id):
    """Reversibly remove or restore one presentation route under the active lock."""
    data = request.get_json(silent=True) or {}
    pricing_group_id = _int_field(data, "pricing_group_id")
    status = (data.get("status") or "").strip().lower()
    if pricing_group_id is None or pricing_group_id < 1:
        return _invalid_input("pricing_group_id is required")
    if status not in ("active", "removed"):
        return _invalid_input("status must be active or removed")

    client = get_supabase_for_caller(g.access_token)
    groups = (client.table("pricing_groups").select("id, batch_id, status")
              .eq("id", pricing_group_id).eq("batch_id", batch_id)
              .limit(1).execute()).data or []
    if not groups:
        return _error("RECORD_NOT_FOUND")
    if groups[0].get("status") != "active":
        return _error("TRANSITION_NOT_ALLOWED")

    routes, denied = _optional_caller_rows(
        client.table("delivery_groups").select(
            "id, batch_id, pricing_group_id, status")
        .eq("id", delivery_group_id).eq("batch_id", batch_id)
        .eq("pricing_group_id", pricing_group_id).limit(1))
    if denied:
        return _error("CAPABILITY_REQUIRED")
    if not routes:
        return _error("RECORD_NOT_FOUND")
    route = routes[0]
    if route.get("status") == status:
        return _invalid_input(f"Delivery Group is already {status}")

    result, err = _caller_table_write(
        f"mark Delivery Group {status}",
        lambda: client.table("delivery_groups").update({"status": status})
        .eq("id", delivery_group_id).eq("batch_id", batch_id)
        .eq("pricing_group_id", pricing_group_id).eq("status", route.get("status")))
    if err:
        return err
    if not (result.data or []):
        return _error("CAPABILITY_REQUIRED")
    # Deliberately do not clear freight_basis_delivery_group_id.  A removed
    # selected route remains an explicit unresolved choice until restored or
    # replaced, which prevents a silent freight fallback (CDM-17).
    return _workspace_write_response(client, batch_id, "update_delivery_group_status")


@app.route("/batches/<int:batch_id>/pricing-groups/<int:pricing_group_id>", methods=["PATCH"])
@require_auth
def update_pricing_group(batch_id, pricing_group_id):
    """Replace one active Pricing Group's governed commercial terms with CAS."""
    data = request.get_json(force=True) or {}
    client = get_supabase_for_caller(g.access_token)
    groups = (client.table("pricing_groups").select(
        "id, batch_id, status, content_version, legacy_freight_source"
    ).eq("id", pricing_group_id).eq("batch_id", batch_id).limit(1).execute()).data or []
    if not groups:
        return _error("RECORD_NOT_FOUND")
    existing = groups[0]
    if existing.get("status") != "active":
        return _error("TRANSITION_NOT_ALLOWED")

    validated, err = _pricing_group_input(client, batch_id, data, existing)
    if err:
        return err
    expected, updates = validated["expected"], validated["updates"]
    if existing.get("content_version") != expected:
        return _error("STALE_VERSION")

    result, err = _caller_table_write(
        "update Pricing Group commercial terms",
        lambda: client.table("pricing_groups").update(updates)
        .eq("id", pricing_group_id).eq("batch_id", batch_id)
        .eq("content_version", expected))
    if err:
        return err
    if not (result.data or []):
        latest = (client.table("pricing_groups").select("content_version")
                  .eq("id", pricing_group_id).eq("batch_id", batch_id)
                  .limit(1).execute()).data or []
        if latest and latest[0].get("content_version") != expected:
            return _error("STALE_VERSION")
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "update_pricing_group")


@app.route("/batches/<int:batch_id>/pricing-groups/<int:pricing_group_id>/freight-basis", methods=["PATCH"])
@require_auth
def set_pricing_group_freight_basis(batch_id, pricing_group_id):
    """Select the one Delivery Group whose Ship-to drives master freight."""
    data = request.get_json(force=True) or {}
    expected = _int_field(data, "expected_content_version")
    delivery_group_id = _int_field(data, "delivery_group_id")
    if expected is None or expected < 1:
        return _invalid_input("expected_content_version is required")
    if delivery_group_id is None or delivery_group_id < 1:
        return _invalid_input("delivery_group_id is required")

    client = get_supabase_for_caller(g.access_token)
    groups = (client.table("pricing_groups").select("id, batch_id, status, content_version")
              .eq("id", pricing_group_id).eq("batch_id", batch_id).limit(1).execute()).data or []
    if not groups:
        return _error("RECORD_NOT_FOUND")
    if groups[0].get("status") != "active":
        return _error("TRANSITION_NOT_ALLOWED")
    if groups[0].get("content_version") != expected:
        return _error("STALE_VERSION")
    routes = (client.table("delivery_groups")
              .select("id, pricing_group_id, batch_id, ship_to_location_id, status")
              .eq("id", delivery_group_id).eq("pricing_group_id", pricing_group_id)
              .eq("batch_id", batch_id).limit(1).execute()).data or []
    if not routes:
        return _error("RECORD_NOT_FOUND")
    if routes[0].get("status") != "active" or routes[0].get("ship_to_location_id") is None:
        return _invalid_input("The freight-basis route must be active and have a Ship-to Location.")

    result, err = _caller_table_write(
        "set Pricing Group freight basis",
        lambda: client.table("pricing_groups")
        .update({"freight_basis_delivery_group_id": delivery_group_id})
        .eq("id", pricing_group_id).eq("batch_id", batch_id)
        .eq("content_version", expected))
    if err:
        return err
    if not (result.data or []):
        # The lock may have moved after the read, or another write may have won.
        latest = (client.table("pricing_groups").select("content_version")
                  .eq("id", pricing_group_id).eq("batch_id", batch_id)
                  .limit(1).execute()).data or []
        if latest and latest[0].get("content_version") != expected:
            return _error("STALE_VERSION")
        return _error("CAPABILITY_REQUIRED")
    return _workspace_write_response(client, batch_id, "set_pricing_group_freight_basis")


@app.route("/batches/<int:batch_id>/pricing-basis", methods=["POST"])
@require_auth
def set_batch_pricing_basis_route(batch_id):
    """Persist Pricing Date/Release through public.set_batch_pricing_basis only."""
    data = request.get_json(force=True) or {}
    expected = _int_field(data, "expected_content_version")
    pricing_date = data.get("pricing_date")
    if expected is None or expected < 1:
        return _invalid_input("expected_content_version is required")
    if not _valid_date_only(pricing_date):
        return _invalid_input("pricing_date must be a valid date in YYYY-MM-DD format")
    if "release_id" not in data:
        return _invalid_input("release_id is required; use null to request the automatic default")
    release_id = None if data.get("release_id") is None else _int_field(data, "release_id")
    if data.get("release_id") is not None and (release_id is None or release_id < 1):
        return _invalid_input("release_id must be a positive integer or null")

    client = get_supabase_for_caller(g.access_token)
    _result, err = _rpc_call(client, "set_batch_pricing_basis", {
        "p_batch": batch_id,
        "p_expected_content_version": expected,
        "p_pricing_date": pricing_date,
        "p_release": release_id,
    })
    if err:
        return err

    # Read after the atomic RPC: the response proves the durable values that
    # reopening the Batch will return. No direct table update exists here.
    try:
        batch = _read_batch_pricing_basis(client, batch_id=batch_id)
    except Exception as exc:
        if _is_upstream_timeout(exc):
            # The RPC may already have committed. UPSTREAM_TIMEOUT deliberately
            # instructs the caller to reopen before trying another write.
            app.logger.error("Batch Pricing Basis read-back timed out upstream: %s", exc)
            return _error("UPSTREAM_TIMEOUT")
        raise
    if batch is None:
        return _error("RECORD_NOT_FOUND")
    return jsonify({"batch": batch, "mutation": "set_batch_pricing_basis"})


@app.route("/masters/customer-families", methods=["POST"])
@require_auth
def propose_customer_family():
    """Propose a new Family. manage_customer_master OR make_quote at any active plant."""
    data = request.get_json(force=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return _invalid_input("name is required")
    sector_id = _int_field(data, "sector_id")
    if sector_id is None or sector_id < 1:
        return _invalid_input("sector_id is required")

    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "propose_customer_family", {"p_name": name, "p_sector": sector_id})
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
    sector_id = None
    if data.get("sector_id") is not None:
        sector_id = _int_field(data, "sector_id")
        if sector_id is None or sector_id < 1:
            return _invalid_input("sector_id must be a positive integer")
    if family_id is None and sector_id is None:
        return _invalid_input("sector_id is required when proposing a new Family")

    result, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "create_minimal_prospect",
        {"p_display_name": display_name, "p_family_id": family_id, "p_sector": sector_id})
    if err:
        return err
    row = (result.data or [{}])[0]
    return jsonify({"party_id": row.get("party_id"), "family_id": row.get("family_id")}), 201


@app.route("/masters/customer-families/<int:family_id>/sectors", methods=["POST"])
@require_auth
def add_customer_family_sector(family_id):
    """Attach another active Sector through the governed CAS operation."""
    data = request.get_json(force=True) or {}
    sector_id = _int_field(data, "sector_id")
    expected = _int_field(data, "expected_content_version")
    if sector_id is None or sector_id < 1:
        return _invalid_input("sector_id is required")
    if expected is None or expected < 1:
        return _invalid_input("expected_content_version is required")

    _, err = _rpc_call(
        get_supabase_for_caller(g.access_token),
        "add_customer_family_sector", {
            "p_family": family_id,
            "p_sector": sector_id,
            "p_expected_content_version": expected,
        })
    if err:
        return err
    return jsonify({"ok": True})


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
@require_group_capability("administer_users")
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
@require_group_capability("administer_users")
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
@require_group_capability("administer_users")
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
