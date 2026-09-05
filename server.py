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
import os
import io
import secrets
from datetime import datetime

from flask import Flask, request, send_file, jsonify, g
from flask_cors import CORS
import openpyxl

from caller_context import (
    bootstrap_caller,
    get_supabase_anon,
    get_supabase_for_caller,
    privileged_client,
    resolve_caller,
)
from auth import require_auth, require_role


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

def _identity_or_none(access_token):
    """
    Resolve the caller's application identity using THEIR OWN token, through RLS.

    Replaces the previous service-role read of `profiles`. That read bypassed RLS,
    so identity resolution was the one place the database was not the authority.
    Returns None for an unrecognised or deactivated identity - the caller cannot
    tell which, deliberately.
    """
    try:
        return resolve_caller(access_token)
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

    # Identity is resolved with the token just issued, so RLS decides.
    profile = _identity_or_none(session.access_token)

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
        profile = _identity_or_none(session.access_token)

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
    profile = _identity_or_none(session.access_token)
    if not profile:
        return jsonify({"error": "Account is not active"}), 403

    return jsonify({
        "access_token": session.access_token,
        "refresh_token": session.refresh_token,
        "expires_at": session.expires_at,
        "profile": {**profile, "email": user.email},
    })


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
            .select("id, auth_user_id, display_name, status")
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
        "role": derive_role([c for c in gc if c], pc),
        "plant": next(iter(pc), None), "plants": sorted(pc),
    }


def _apply_role_and_plant(client, app_user_id, role, plant_code):
    """
    Express a role/plant change as capability grants.

    Every statement is an ordinary caller-context write: the grant tables' INSERT
    and UPDATE policies already require administer_users, so a caller without it
    is refused by the database rather than by a check here. Revocation sets
    status='revoked' - grants are never deleted, so the history survives.
    """
    caps = (client.table("capabilities").select("id, capability_key").execute()).data or []
    cap_id = {c["capability_key"]: c["id"] for c in caps}

    if role is not None:
        want_admin = (role == "admin")
        existing = (client.table("group_capability_grants")
                    .select("id, capability_id")
                    .eq("app_user_id", app_user_id).eq("status", "active")
                    .eq("capability_id", cap_id["administer_users"]).execute()).data or []
        if want_admin and not existing:
            client.table("group_capability_grants").insert({
                "app_user_id": app_user_id,
                "capability_id": cap_id["administer_users"],
                "granted_by": g.caller["id"],
            }).execute()
        elif not want_admin and existing:
            client.table("group_capability_grants").update({
                "status": "revoked", "revoked_at": "now()", "revoked_by": g.caller["id"],
            }).eq("id", existing[0]["id"]).execute()

    if plant_code is not None:
        plants = (client.table("plants").select("id, plant_code").execute()).data or []
        by_code = {p["plant_code"]: p["id"] for p in plants}
        if plant_code and plant_code not in by_code:
            raise ValueError("unknown plant")

        current = (client.table("plant_capability_grants")
                   .select("id, plant_id").eq("app_user_id", app_user_id)
                   .eq("status", "active").execute()).data or []
        for row in current:
            client.table("plant_capability_grants").update({
                "status": "revoked", "revoked_at": "now()", "revoked_by": g.caller["id"],
            }).eq("id", row["id"]).execute()

        if plant_code:
            wanted = ["plant_access",
                      "check_quote" if role == "checker" else "make_quote"]
            client.table("plant_capability_grants").insert([{
                "app_user_id": app_user_id,
                "plant_id": by_code[plant_code],
                "capability_id": cap_id[w],
                "granted_by": g.caller["id"],
            } for w in wanted]).execute()


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
        .select("id, auth_user_id, display_name, status")
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
    plant        = data.get("plant") or None

    if not email or not display_name:
        return jsonify({"error": "email and display_name are required"}), 400
    if role not in VALID_ROLES:
        return jsonify({"error": f"role must be one of {VALID_ROLES}"}), 400

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
        app_user_id = (
            get_supabase_for_caller(g.access_token)
            .rpc("admin_create_app_user", {
                "p_auth_user_id": uid,
                "p_display_name": display_name,
                "p_role":         role,
                "p_plant_code":   plant,
            })
            .execute()
        ).data
    except Exception:
        # Don't leave an orphaned auth account with no application identity.
        try:
            privileged_client("auth_admin_delete_user").auth.admin.delete_user(uid)
        except Exception:
            pass
        return jsonify({"error": "Could not create the application identity"}), 400

    resp = {
        "id": app_user_id, "email": email, "display_name": display_name,
        "role": role, "plant": plant, "active": True,
    }
    if generated:
        resp["temp_password"] = password
    return jsonify(resp), 201


@app.route("/admin/users/<uid>", methods=["PATCH"])
@require_auth
@require_role("admin")
def update_user(uid):
    """
    `uid` is now the application identity (app_users.id), not an Auth uuid.

    Every write runs as the caller: display_name through the column grant, status
    through a capability-checked RPC, and role/plant as ordinary grant rows whose
    INSERT/UPDATE policies already require administer_users.
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
        if app_user_id == g.caller["id"] and not data["active"]:
            return jsonify({"error": "You cannot deactivate your own account"}), 400
        try:
            client.rpc("admin_set_app_user_status", {
                "p_app_user": app_user_id,
                "p_status": "active" if data["active"] else "deactivated",
            }).execute()
        except Exception:
            return jsonify({"error": "Could not update the account status"}), 400
        touched = True

    if "role" in data or "plant" in data:
        if data.get("role") and data["role"] not in VALID_ROLES:
            return jsonify({"error": f"role must be one of {VALID_ROLES}"}), 400
        if app_user_id == g.caller["id"] and data.get("role") and data["role"] != "admin":
            return jsonify({"error": "You cannot change your own role"}), 400
        try:
            _apply_role_and_plant(client, app_user_id, data.get("role"), data.get("plant"))
        except PermissionError:
            return jsonify({"error": "Forbidden"}), 403
        except Exception:
            return jsonify({"error": "Could not update role or plant"}), 400
        touched = True

    if not touched:
        return jsonify({"error": "No fields to update"}), 400

    return jsonify(_read_one_user(client, app_user_id))


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
