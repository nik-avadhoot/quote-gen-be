# CFB Quotation Operating System — Project Brief
**Client:** Avadhoot Packaging Solutions, Nagpur
**Version:** 2.1 | **Last updated:** August 2026

---

## 1. Project Objective

Build an internal Quotation Operating System for corrugated fibre board (CFB) packaging that replaces manual Excel-based costing. The system must:

- Allow a costing Maker to produce a fully calculated, compliant quote in minutes
- Handle individual SKU deep-dives (Costing tab) and large batches of 10–40 SKUs (Batch Entry tab)
- Manage the **SET concept** — RSC box + liner plates + partitions quoted as a single combined rate
- Export client-facing quotes as PDF and formatted Excel (via master template)
- Eventually go live for one plant team (~10–15 users) with quote history, repeat customer reference, and maker tracking

---

## 2. Current Architecture

```
quotation-app/
├── src/
│   ├── QuotationApp.jsx        ~5,365 lines — all React state, UI, event handlers
│   ├── engine/
│   │   └── costing.js          ~219 lines — pure JS engine, zero React dependency
│   └── data/
│       └── defaults.js         ~101 lines — all DEFAULT_* constants and master data
├── server.py                   Python Flask export server (port 3001)
├── CFB_Quotation_Master_v7.xlsx Master Excel template (openpyxl fills it on export)
└── package.json                Vite + React + xlsx-js-style
```

**Running the app (two terminals every session):**
```
Terminal 1: python server.py          → http://localhost:3001/health
Terminal 2: npm run dev               → http://localhost:5173
```

**App tabs:** Costing · Quote Items · Batch Entry · Construction Library · Rate Master · Freight Rates · Defaults

**Roles:** Maker (input + export) · Checker (all + review) · Admin (all + edit masters)

**Data persistence:** localStorage in browser — single PC only. Multi-PC sync planned.

---

## 3. Core Business Logic (critical — do not alter without reason)

| Calculation | Rule |
|---|---|
| **Effective Paper Rate** | `Price + Price×Credit% - Discount + Freight` (Rate Master level). GSM surcharge (+4/<100gsm, +1.5/=100gsm, +1/>200gsm) added per layer during costing only — NOT in Rate Master |
| **Paper Consumed** | `GSM/1000 × Area × TUF × (1 + Waste%)` |
| **Sheet Weight** | `Paper Consumed / (1 + Waste%)` |
| **Box Weight** | `Sheet Weight × 0.98` (2% slotting/cutting loss) |
| **Interest base** | `Mat + Conv + All Add-ons incl Unloading` — **excludes Freight** |
| **Total Cost** | `Mat + Conv + Add-ons + Interest + Freight` — Final Rate is a landed rate |
| **Final Rate** | `MROUND(Total × (1 + Margin%), 0.05)` |
| **Rate/kg** | `Final Rate / Sheet Weight` (not Box Weight) |
| **MOQ** | `PLY × 1,100 / Paper Consumed` rounded to nearest 100 |
| **BS formula** | `Σ(BF_adj × BCF × GSM/1000)` — liner BCF=1.0, flute BCF=slider (default 10%) |
| **35BF** | Always calculated as 33BF in the engine |
| **PP box type** | Uses flat-piece deckle formula `(L×Ups, W)` with trim=0 |
| **Conv rate** | Box→RSC: sector CBB rate · Plate/Part-L/Part-W: sector PP rate (default 12.5 Rs/kg) |

---

## 4. Key Architectural Decisions

| Decision | Choice | Reason |
|---|---|---|
| File structure | Single JSX + engine.js + defaults.js | Phase 1+2 refactor done. Component split (Phase 4) deferred until DB layer exists |
| Styling | All inline CSS, `C.*` color constants | No build complexity, no className conflicts |
| State management | `useState` at App level only | No Redux/Context — app isn't large enough yet |
| Database | localStorage (current) → SQLite+Node.js (go-live) | Incremental |
| Excel export | Python/openpyxl primary, xlsx-js-style fallback | openpyxl preserves template formatting |
| Logos | Embedded as base64 in JSX | No file management, no server dependency |
| Single-point finalisation | Batch Entry → Quote Items is the **only** route to finalise items. Costing tab is analysis-only | Ensures all overrides, SET calculations and row-level values are captured before export |
| Construction Library | Single source of truth: one `constructionLib` React state, one `cbb_constrlib` localStorage key. Accessed from Construction Library tab (full management) and Batch Entry overlay (selection only) | No duplicate data structures |
| SET Code auto-fill | Non-Box rows inherit SET Code from nearest preceding **confirmed** Box row's `setCode` (not `matCode`) | Handles cases where SET Code and Mat Code have diverged |
| SET Code confirmation | Unconfirmed (`setCodeAssumed===true`) blocks auto-dims, Calculate All, Deep Dive, and Send All | Prevents assumption-stacking and silent mis-attribution |
| JSX patterns | No `<>` fragments in ternaries inside table rows; no IIFEs that return raw arrays into JSX | Known Vite/esbuild crash patterns — use `&&` guards instead |
| **Costing batch context** | `costingContext = "same-batch" \| "new-batch"` — explicit two-state model. Governs which batch context the Costing workspace is affiliated with | Prevents a New-Batch Costing SKU from silently entering an existing BatchEntry batch |

---

## 5. Coding Standards

- **Inline styles only** — no CSS files, no Tailwind, no className attributes
- **Color constants:** `C.amber`, `C.slateM`, `C.slateL`, `C.white`, `C.cream`, `C.border`, `C.green`, `C.red`, `C.amberL`, `C.amberD`
- **Font variables:** `mono` (monospace, for numbers/codes), `sans` (UI text)
- **Hooks rule:** `useState`/`useEffect` only at top level of App component — never inside `.map()`, IIFEs, conditionals, or callbacks (causes blank-screen crashes)
- **Notifications:** `showToast(msg, type, duration)` — types: `'success'` (green), `'info'` (amber), `'error'` (red)
- **Module-level functions** (like `exportFromTemplate`) CANNOT reference React state directly. They must accept state via parameters (e.g., `meta={quoteRef, makerName, ...}`). This was a hard crash bug.
- **No `React.useState` inside render callbacks**
- **IIFE chain rule:** When an IIFE inside JSX returns an array (e.g., `return someArray`), it **must** chain `.map()` directly — `{(()=>{...return arr;})().map(...)}`. Splitting into `{(()=>{...return arr;})()}` followed by `{arr.map(...)}` renders raw JS objects as JSX children and **crashes React immediately**.
- **Conditional JSX in tables:** Use `{cond && <td>...</td>}` + `{!cond && <td>...</td>}` patterns. Avoid ternary returning `<>` fragment vs single `<td>` in table row context — causes Vite/esbuild parse failures.

---

## 6. Nomenclature (finalized — do not revert)

| Old | New | Scope |
|---|---|---|
| RS4 | Box | rowType value in app, engine, defaults, server.py, xlsx col B |
| Item Type | Set Role | Costing SET section label |
| Conv RS4 | Conv Box | Batch Profile Row 2 label |
| Constr (column header) | Paper Construction | Batch Entry grid column |

---

## 7. What Has Been Completed

### Core Engine (`costing.js`)
- `calcCosting(spec, rates, freight, boxTrimData)` — full cost build-up
- `checkSpecCompliance(spec, result)` — BS, GSM, box weight compliance
- `suggestMargin(spec, calcMOQ)` — commercial margin suggestion
- `checkMissingInfo(spec, result)` — blockers, warnings, assumptions
  - Blocker text: "Freight not specified" (when delivery blank); "Monthly volume (nos/month) not provided" (when volume blank)
- `getEffectiveRate(code, gsm, rates)` — per-grade credit%, GSM surcharge
- `buildSpecFromRow(row, constEntry, profile)` — batch entry → full spec
  - `row.boxType` is always authoritative; `customerType` and `priceContext` read from profile
  - `plant` and `delivery` default to `""` (no Nagpur fallback)
- `getBatchRowStatus` — uses `isFlatPiece` (renamed from `isBoard`) for Plate/Part rows where H is not required

### Costing Tab — Batch Context Architecture

The Costing tab operates in one of two explicitly declared batch contexts, tracked by `costingContext` state (`"same-batch"` | `"new-batch"`). This is a session-only flag (not persisted).

#### State

| State | Type | Purpose |
|---|---|---|
| `costingContext` | `"same-batch" \| "new-batch"` | Which batch context the Costing workspace is affiliated with |
| `specCommitted` | `boolean` | Whether the current spec has been sent to the active BatchEntry batch |
| `setAutoFill` | `boolean` | User setting for automatic SET Code population (not derived state) |

#### Helper functions

| Function | Purpose |
|---|---|
| `specFromProfile()` | Same-Batch New SKU — resets identity/SKU fields; restores batch-level context from `batchProfile`; retains construction/board specs from current `spec` |
| `specForNewBatch()` | New-Batch New SKU — resets identity/SKU fields; restores batch-level context from **current `spec`** (never reads `batchProfile`); retains construction/board specs from current `spec` |

#### `specFromProfile()` carry-forward table

| Field group | Action |
|---|---|
| `client`, `sector`, `plant`, `delivery`, `interest`, `paymentDisc`, `margin`, `customerType`, `priceContext` | Restored from `batchProfile` |
| `waste`, `convRate`, `wastePP`, `convRatePP` | Set to `""` (blank-means-inherit from sector/batch default) |
| `ply`, `flute_F1/F2`, `layers`, `boxType`, `spec_bs/bct/ect`, `board_gsm`, `spec_cobb` | Retained from current `spec` |
| `material_code`, `product`, `L/W/H`, `setCode`, add-ons, `volume`, `salesMOQ`, etc. | Reset to INIT_SPEC |

#### `specForNewBatch()` carry-forward table

Identical to `specFromProfile()` in semantics, but sources batch-level context from **current `spec`** instead of `batchProfile`. Guarantees zero dependency on the parked BatchEntry batch.

| Field group | Action |
|---|---|
| `client`, `sector`, `plant`, `delivery`, `interest`, `paymentDisc`, `margin`, `customerType`, `priceContext` | Carried from `spec.*` |
| `waste`, `convRate`, `wastePP`, `convRatePP` | Carried from `spec.*` as-is (preserves blank-as-inherit) |
| `ply`, `flute_F1/F2`, `layers`, `boxType`, `spec_bs/bct/ect`, `board_gsm`, `spec_cobb` | Retained from current `spec` |
| `material_code`, `product`, `L/W/H`, `setCode`, add-ons, `volume`, `salesMOQ`, etc. | Reset to INIT_SPEC |

#### `_hasCommittedBatch`

```js
const _hasCommittedBatch = batchRows.length > 0 && costingContext === "same-batch";
```

`false` in new-batch context — Costing uses sector master for waste/conv defaults rather than parked `batchProfile`.

#### Same-Batch context (`costingContext === "same-batch"`)

- **Start New SKU** → calls `specFromProfile()` — restores batch identity from `batchProfile`, retains construction
- **Send to Batch Entry** → appends row to `batchRows` normally; G1 identity guards operate
- **Context badge** → amber `🔗 Batch active · N rows` (when `batchRows.length > 0`)
- **Established by:** page load default, `loadBatchRowIntoCosting`, Unlink, BatchEntry `+ New Batch`

#### New-Batch / Scratchpad context (`costingContext === "new-batch"`)

- **Entry point:** Costing → `+ New Batch` button — resets spec to `{...INIT_SPEC, plant:"", delivery:""}` (no construction, no batchProfile data), sets `costingContext="new-batch"`
- **Start New SKU** → calls `specForNewBatch()` — retains construction from current scratchpad spec, reads nothing from `batchProfile`
- **Subsequent scratchpad SKUs** retain construction as working intelligence; `costingContext` stays `"new-batch"`
- **Send to Batch Entry (hard gate):** if `costingContext==="new-batch" && batchRows.length>0` → **unconditional hard block** before any validation, before any write. No field-value comparison. User must use BatchEntry → `+ New Batch` first.
- **First send when BatchEntry is empty:** allowed — establishes the new batch; `costingContext` switches to `"same-batch"` automatically
- **Context badge** → blue `✦ Scratchpad · N rows parked in Batch Entry` (when `batchRows.length > 0`)
- **`_hasCommittedBatch`** → `false` — waste/conv resolve from sector master, not parked `batchProfile`
- **BatchEntry `↓ Profile` guard:** blocked when `costingContext==="new-batch" && batchRows.length>0` — prevents Context B spec from overwriting Batch A's `batchProfile`

#### Context transitions

| Action | `costingContext` result |
|---|---|
| Page load | `"same-batch"` (default) |
| Costing `+ New Batch` | `"new-batch"` |
| Start New SKU | **unchanged** — preserves current context |
| `sendCostingToBatch` succeeds (new-batch + empty BatchEntry) | `"same-batch"` |
| `loadBatchRowIntoCosting` (Deep Dive / REVIEW) | `"same-batch"` |
| Unlink | `"same-batch"` |
| BatchEntry `+ New Batch` | `"same-batch"` |

#### Unlink semantics (locked)

Unlink = exit REVIEW and return to Same-Batch start mode. Identical semantics to Start New SKU:
- Calls `setSpec(specFromProfile())` — restores batch context from `batchProfile`
- Resets `activeBatchRowId`, `specCommitted`
- Sets `costingContext="same-batch"`
- Row-level commercial overrides (waste, conv, margin, interest, freightOverride) are NOT retained — same as OldBatch→NewSKU

#### Costing Tab — other completed features
- **Role: Analysis / Deep-dive / Scenario-building workspace only.** Items are NOT added to Quote Items directly from Costing.
- Full spec form: dimensions grid `"62px 62px 62px 1fr 56px"` for L/W/H/Ups/Dim
- 5-layer paper construction, SET Config, commercial parameters
- Output: Key Numbers, Spec Compliance, BCF slider, Cost Breakdown
- Margin suggestion with commercial intelligence
- **Board Specifications — 2×(3×3) matrix layout:**
  - LEFT matrix: GSM · BS · BCT (each row: 52px label | 62px limit dropdown | 1fr value input)
  - RIGHT matrix: ECT · Cobb · Req Box Wt (Req Wt spans limit+value cols, separated by hairline)
  - Weight remarks strip below both matrices (flex-wrap, conditional on data present)
  - Cobb ≤125 → amber warning + "confirm Coating" note
  - Tolerance colour coding: Min=blue, Avg±5%=amber, Max=red
  - ✅/⚠ target compare with ±1.5% tolerance
- **Freight Override indicator:** When active, label shows amber `↑` glyph inline (no text wrap). Input border turns amber. Label has `whiteSpace:"nowrap"`.
- **Bottom action area:**
  - If a Batch Row is linked (loaded via 🔍): shows green **"↑ Push Changes to Batch Row"** button + Reset
  - If no Batch Row linked: shows blue routing notice ("Costing = Analyse & Experiment") with link to Batch Entry + Reset
  - The `addItem()` function still exists in code but has no UI trigger — Costing is finalisation-free

### Quote Items Tab
- Quote Ref + Maker Name + Quote Date + Price Valid From–To
- SET grouping with combined SET Rate
- PDF export (letterhead), Excel export (Python server + SheetJS fallback)
- Empty state directs user to Batch Entry (not Costing)

### Batch Entry Tab

**Workflow:** Batch Entry → Calculate All → Send All to Quote Items (the only route to Quote Items)

- **Batch Profile — compact 3-section card + action column:**
  - **Customer card** (3×4 grid): Client · Sector / Plant · Delivery / CustType · PriceCtx
  - **Commercials card**: `"24px 1fr 1fr 1fr"` grid — Conv Box · Conv PP · Waste% Box · Waste% PP · Mgn% Box · Mgn% PP
  - **Terms card**: Freight / Payment Term · Interest (payment→interest linked)
  - **Actions column**: `[↓ Import Profile from Costing]` + `[+ Import Construction from Costing]` above `[+ New Batch]`
  - **`↓ Import Profile` guard:** blocked when `costingContext==="new-batch" && batchRows.length>0` — prevents scratchpad spec from overwriting active batch profile

- **`+ New Batch` (BatchEntry):** Destructive. Clears `batchProfile`, `batchRows`, `batchResults`, `items`. Also resets Costing spec to `{...INIT_SPEC, plant:"", delivery:""}` and sets `costingContext="same-batch"`. Both Costing and BatchEntry reset together.

- **Construction Library access from Batch Entry:**
  - Old permanent 300px left panel: **removed**
  - Replaced by: **📚 Construction Library (N active)** toolbar button → opens 380px right-side slide-over overlay
  - Each row's "Paper Construction" column is a **button** (not a dropdown) that opens the overlay targeted at that row
  - Overlay is **selection-only** — create/edit happens in the Construction Library tab
  - Overlay has: text search, sector/client dropdowns, **STD spec range filters** (GSM ≥/≤, BS ≥, BCT ≥, ECT ≥, Cobb ≤) behind a toggle button, card list with one-click apply
  - "⬡ Full Library" button and footer link navigate to Construction Library tab

- **SKU Grid — frozen columns:**
  - First 5 columns frozen (sticky): St | # | Mat Code | SKU/Product | SET Role
  - Amber separator + `boxShadow:"2px 0 6px rgba(0,0,0,.18)"` on BOTH header `<th>` and every body `<td>` of col 5 (SET Role)
  - **Status cell (col 1) is clickable** — doubles as expand/collapse toggle for sub-row. Shows status icon + tiny `▾/▴` chevron. Amber background tint + bottom border when expanded. Right-side `▾` button in actions column still works.

- **SKU Grid column order** (left→right):
  Status | # | Mat Code | SKU | SET Role | SET Code | Nos/Set | Box Type | Paper Construction | L | W | H | Ups | Std GSM | Std BS | Std BCT | Std ECT | Std Cobb | Std Box Wt | Sales MOQ | Vol/mo | Waste% | Conv Rs/kg | Margin% | Remarks | Sheet Wt | Final Rate (₹) | Rate/SET (₹) | MOQ | Rate/kg (₹) | Calc GSM | Calc BS | Est Box Wt | All Spec OK

- **Rate/SET (₹) column display:**
  - When `nosPerSet > 1`: flex `space-between` — `×N` tag on **left** (small, dim), `₹rate` on **right** (bold). Reads as: multiplier → result. `whiteSpace:"nowrap"` prevents wrapping.
  - When `nosPerSet = 1`: single right-aligned rate value. No height impact.

- **SET Code cell (compact layout):**
  - SET checkbox is positioned **inside the left edge of the SET Code input** using `position:"absolute"`. Input has `paddingLeft:18px` to prevent text overlap. No separate checkbox row above the input — no row height increase.
  - Placeholder text: "Part of Set?"
  - `setAutoFill` is a **user setting** (not derived state). `setCode` is the downstream source of truth.

- **SET Code behaviour:**
  - **Main Box:** SET Code = Mat Code, silent auto-fill, no confirmation needed. Auto-syncs as Mat Code is typed (as long as they remain equal).
  - **Non-Box rows (Plate/Part-L/Part-W/Other):** SET Code inherited from nearest preceding **confirmed** Box row's `setCode` (not `matCode`). Guard: only inherit if parent Box `setCodeAssumed===false`. Marked `⚠ assumed` with Confirm (✓) and Clear (✕) micro-buttons.
  - **Confirmation gates (all require confirmed SET Code before proceeding):**
    - `autoCalcPPDims`: blocked if `setCodeAssumed===true` OR if SET Code is empty (standalone row)
    - `calculateAll`: blocks entire batch; toast lists offending rows by number + Mat Code
    - `loadBatchRowIntoCosting` (🔍 Deep Dive): blocks per-row with specific message
    - `sendAllToQuoteItems`: blocks entire batch; toast lists offending rows
  - **Cleared SET Code (✕ pressed):** SET Code → blank; `setCodeAssumed→false`; SET Role dropdown → disabled/greyed showing "— N/A —"; auto-dims disabled (row is standalone)
  - **Confirm (✓ pressed):** clears assumed flag; triggers Glass SKU auto-fill if applicable (see below)

- **SET Role dropdown:**
  - Active and editable when SET Code is non-empty
  - **Disabled + shows "— N/A —"** when SET Code is blank (standalone row). Grey styling signals inactive state.

- **Glass SKU Type (ALCOBEV sector only):**
  - Appears in **expandable sub-row (`▾`)** — not main grid
  - **Main Box sub-row:** Glass SKU Type selector (dropdown from `partitionsMaster`). Stores `glassSKUType` on the Box row. Shows L-wise / W-wise nos preview once selected. No auto-fill to Part rows at this point — propagation happens on Part row SET Code confirmation.
  - **Part-L / Part-W sub-row:** Read-only display of parent Box's `glassSKUType`. Shows current `nosPerSet` with "inherited from Main Box" label.
  - **On Part row SET Code confirmation (✓):** app looks up parent Box's `glassSKUType` → finds partitions master entry → auto-fills `nosPerSet` (Part-L → `lwise`, Part-W → `wwise`). Shows success toast with SKU type and nos.
  - **If parent Box has no `glassSKUType` yet:** shows warning toast: *"Glass SKU Type not yet set on the parent Box — set it first to auto-fill Nos/Set"*
  - **Main grid Nos/Set cell:** shows small `🍶 SKUType` badge (max 8 chars, truncated) below the number input for ALCOBEV Part rows that have `glassSKUType` set.

- **`addBatchRow()` SET Code logic:**
  - Box: `setCode = matCode`, `setCodeAssumed = false`
  - Non-Box: walks backwards through `prev`, filters for `r.itemType==="Box" && r.matCode && !r.setCodeAssumed`, takes first match, sets `setCode = boxes[0].setCode || boxes[0].matCode`, `setCodeAssumed = true`
  - If no confirmed parent Box found: `setCode = ""`, `setCodeAssumed = false`

- **`addBatchRow()` initial `boxType`:** `itemType==="Box"?"RSC":"PP"`
- **`itemType` onChange:** `"Plate"|"Part-L"|"Part-W"` → `boxType="PP"`, `"Box"` → `boxType="RSC"`, `"Other"` → leave as-is
- **`autoCalcPPDims()`:** requires `rowSetCode` non-empty AND `!row.setCodeAssumed`. Parent Box must also have `!r.setCodeAssumed`. No ungrouped fallback any more — blank SET Code = standalone = no auto-dims.
- `loadBatchRowIntoCosting()` mirrors `calcBatchRow()` overlay logic for add-ons, interest, freight overrides. Sets `costingContext="same-batch"`.

### Construction Library Tab

**Role: Master database and management workspace for all construction profiles.**

- **Single source of truth:** `constructionLib` React state, persisted to `cbb_constrlib` localStorage. Same data used by Construction Library tab, Batch Entry overlay, and Costing tab.
- **Left sidebar (240px):** Stats strip (Total / Active / Archived / Sectors), text search, Status filter (active/archived/all), Sector dropdown, Client dropdown, Spec range filters (GSM ≥/≤, BS ≥, BCT ≥, ECT ≥, Cobb ≤)
- **Right panel:** Scrollable library entries. Each card shows: code badge, auto-name, sector/client/spec tags, traceability badge ("↳ N batch rows" if referenced in current batch). Expand → full editor (identity, tagging, construction, paper layers, std specs).
- **Toolbar:**
  - `+ New Construction` — creates blank entry, auto-expands it, clears filters
  - `↓ Import from Costing` — pulls current Costing spec. **Duplicate check runs first** (see below).
- **Duplicate check on Import from Costing:**
  - Exact match on all 5 STDs (`board_gsm`, `spec_bs`, `spec_bct`, `spec_ect`, `spec_cobb`) + `sector`
  - Blank fields match blank fields; numeric tolerance is **not** applied (Phase 2)
  - If duplicate found with different client: `window.confirm` offers to merge incoming client into existing entry's `client` field. Existing entry is expanded for review. Import blocked.
  - If duplicate found with same/no client: `window.alert` pointing to existing entry. Import blocked.
  - Always blocks duplicate creation — client identity alone is not a valid reason for a new construction.
- **Expand/edit:** two-column layout — left: Identity/Classification/Std Specs/Traceability; right: Construction (Ply/Box Type/Flutes) + Paper Layers
- **Expand key:** `String(index)` (not `c.code`) — survives empty or duplicate codes

### Excel Export (xlsx-js-style fallback) — column addresses verified against v7 CBB+PP

| Field | Column |
|---|---|
| Conv RS4 / Box | BA3 |
| Conv Board/PP | BA4 |
| Waste% RS4 (decimal) | AY3 |
| Waste% Board/PP (decimal) | AY4 |
| Interest% (decimal) | BJ3 / BJ4 |
| Box Margin% | BM3 |
| PP Margin% | BM4 |
| Freight override (when set) | BK3 |
| Add-ons header row 3 (Printing…Unloading) | BB3–BI3 |
| Add-ons header row 4 (defaults zero) | BB4–BI4 |
| Per-row add-ons | BB{r}–BI{r} |
| Per-row margin override | BM{r} |
| F1 Flute / F2 Flute | AB{r} / AC{r} |
| TOP BF+GSM | AD{r} / AE{r} |
| F1/L1/F2/L2 BF+GSM | AF/AG / AH/AI / AJ/AK / AL/AM{r} |
| SET Code | BR{r} |
| Nos/Set | BS{r} |
| CLEAR_COLS | AB–AM, BB–BI, BM |
| **Column T** | **Formula column (Calc GSM) — NEVER overwrite** |

`meta.marginPP` passed from Quote Items export button for BM4.

### Rate Master Tab
- **Compact 2-strip layout**
  - Strip 1 (single nowrap row): `GY Premium [16–24BF] [28–35BF] [Apply GY] | Freight [16–20BF→] [22–28BF→] [35BF+→] | Disc [val] [All] | Credit% [val] [All]`
  - Row 2: footnote + Rate Date (right-aligned)
  - Strip 2 (admin only): `+ New Grade | Code | Description | Price | Disc | Freight | Add Grade`
- Rate table: Grade · Description · Paper Price · Credit% (editable per grade) · Discount · Freight · Eff Rate
- Per-grade Credit% overrides global `CREDIT_PCT`; engine respects it via `e.interest`

### Export (server.py)
- `exportFromTemplate` uses `meta={}` parameter for state variables (`quoteRef`, `makerName`, etc.)
- Health check: `GET http://localhost:3001/health` → `{"ok":true,"template":true}`
- Named constants: `DATA_START_ROW`, `DATA_MAX_ROWS`, `DATA_END_ROW` — runtime warning when batch exceeds template capacity

### Safety / UX Features
- **Backup/Restore:** header buttons download/restore all localStorage keys as a single JSON snapshot
- **Auto-save:** batch rows auto-saved to `cbb_batch_autosave` on every change. Restore banner appears on load if unsaved work < **7 days** old.
- **Quote Items persistence:** `cbb_quoteitems` localStorage
- **Export guard:** requires `quoteRef` and `makerName` before export; SET completeness check warns if any SET has a Box but no Plate/Partition
- **Dimension validation:** 1–2500mm range; red border on invalid inputs

---

## 8. Known Bugs Fixed (session history)

| Bug | Fix |
|---|---|
| `useState` inside `.map()` → blank screen | Moved freightBands state to App top level |
| `exportFromTemplate` references `quoteRef` at module scope → ReferenceError | Added `meta={}` parameter |
| `server.py` crash: `NameError: first_spec is not defined` | Changed to `f0` |
| `server.py` RS4 → Box not fully updated | Fixed in 2 remaining places |
| Batch grid column order mismatch | Reordered: SET Role→SET Code→Nos/Set→Box Type→Paper Construction→L/W/H/Ups→specs |
| Sector dropdown text invisible (dark bg) | Batch Profile bar changed to light theme |
| Export columns wrong | Corrected against v7 xlsx template — all col refs verified |
| App blank on Batch Entry tab click | Construction Library IIFE returned raw array into JSX. Fixed: `.map()` must chain directly |
| App blank from start (all tabs) | Same orphaned IIFE pattern — reverted and rebuilt from clean base |
| Commercials fields overlapping | `numField` changed to `width:"100%"`, `boxSizing:"border-box"` |
| Construction Library expand/collapse broken | Switched from `c.code` key to `String(ci)` index key |
| `getBatchRowStatus` crashed for Plate rows (no H) | Renamed `isBoard` → `isFlatPiece` |
| `loadBatchRowIntoCosting` missing add-on/freight overlays | Added same overlay logic as `calcBatchRow` |
| `itemType` onChange set Plate→RS4 instead of PP | Fixed: Plate/Part-L/Part-W → PP; Box → RSC |
| `addBatchRow` defaulted Plate to Board boxType | Fixed: Plate/Part → PP default; Box → RSC |
| `buildSpecFromRow` ignored row.boxType for trim | row.boxType now authoritative |
| SET Code auto-fill pulled `matCode` instead of `setCode` from parent Box | Fixed: `boxes[0].setCode \|\| boxes[0].matCode`; guard `!r.setCodeAssumed` added |
| Unconfirmed SET Code allowed Calculate All / Deep Dive / Send All to proceed silently | Gates added to all three functions; toast lists offending rows by number + Mat Code |
| `autoCalcPPDims` inherited dims from wrong SET group | Parent Box search restricted to same confirmed SET Code; no ungrouped fallback |
| Construction Library duplicate client entries for same physical construction | Exact-match duplicate check (5 STDs + Sector) on Import from Costing; client-merge offered instead |
| Rate/SET column expanded row height | Replaced stacked `<div>×N pcs</div>` with inline `<span>×N</span>`; `whiteSpace:nowrap` on `<td>` |
| Frozen column separator shadow missing on body rows (visible only in header) | `boxShadow` propagated to body `<td>` cells for SET Role column |
| New-Batch Costing SKU silently entering existing BatchEntry batch | `costingContext` state + hard pre-condition gate in `sendCostingToBatch`; G1 guards are no longer the only defence |
| `buildSpecFromRow` Nagpur fallback in plant/delivery | Removed — plant/delivery now blank when profile has blank values |
| `specFromProfile()` / `specForNewBatch()` INIT_SPEC had Nagpur defaults for plant/delivery | Lazy `useState` initialiser overrides INIT_SPEC plant/delivery with blanks on load |
| Unlink was retaining row-level commercial overrides (not-approved modification) | Reverted to `setSpec(specFromProfile())` — Unlink semantics identical to OldBatch→NewSKU |

---

## 9. JSX Safety Patterns (learned the hard way)

| Pattern | Status | Notes |
|---|---|---|
| `{cond ? <th>A</th> : <><th>B</th><th>C</th></>}` in `<tr>` | ❌ Crash | Vite/esbuild fails on ternary with `<>` fragment vs single element in table |
| `{cond && <th>A</th>}` + `{!cond && <th>B</th>}` | ✅ Safe | Use separate `&&` guards instead |
| `{(()=>{ return arr; })().map(...)}` | ✅ Safe | IIFE returns array, map chains immediately |
| `{(()=>{ return arr; })()}` + `{arr.map(...)}` | ❌ Crash | Returns raw JS objects into JSX — React crashes |
| Helper function defined inside IIFE returning JSX | ❌ Risky | Esbuild inconsistency; inline `.map()` is safer |
| `<>` fragment as JSX children in table row | ❌ Risky | Prefer `React.Fragment` with explicit key or restructure |
| Extra `</div>` added by automated div-balance counter | ❌ Crash | Counter picks up `</div>` inside template literals — always verify manually around line count boundaries |

---

## 10. Pending / Roadmap

| Priority | Item | Notes |
|---|---|---|
| 🔴 High | Node.js API + SQLite quote storage | Go-live blocker |
| 🔴 High | Quote history + repeat customer panel | Requires DB layer first |
| 🟡 Med | Google Sheets integration | Live paper prices, freight, grade masters |
| 🟡 Med | Maker performance dashboard | Quotes per maker per month |
| 🟡 Med | Sector-level default SET Role = NA | Non-SET sectors (majority ~80-85% of business) should default SET Role to N/A. Data model ready (sector defaults table exists). Deferred. |
| 🟡 Med | STD filter tolerance (fuzzy match) | Duplicate check currently uses exact match. Phase 2: introduce ±1% tolerance for numeric STD fields. |
| 🟡 Med | Glass SKU Type propagation offer | After selecting Glass SKU on Main Box, offer to propagate to other Part rows in same SET that have confirmed SET Code but no SKU type yet. Currently per-row only. |
| 🟡 Med | Std column group (collapsible, teal accent) | Deferred — ternary+fragment in `<tr>` is crash-prone; needs safer approach |
| 🟢 Low | Phase 4 component split | After DB layer |
| 🟢 Low | Construction Library scroll isolation | Now resolved by full-tab layout; re-evaluate if needed |

**Post-beta technical debt logged:**
- R-1: Add-ons injection block duplicated at three call sites (should-fix)
- R-2: PP-type item predicate inlined across six locations (should-fix)
- R-3: waste/conv resolution reimplemented in `calcBatchRow` rather than calling the existing resolver
- R-4: SheetJS fallback duplicating server.py template logic
- R-5: batchProfile fallback constants duplicated from defaults.js
- R-6: Full JSX component split (deferred post-beta)

---

## 11. localStorage Keys

| Key | Content |
|---|---|
| `cbb_rates` | Rate Master (grades, prices, disc, freight, interest) |
| `cbb_freight` | Freight matrix (plants × locations) |
| `cbb_sectors` | Sector defaults (19 sectors) |
| `cbb_boxtrim` | Box type trim table |
| `cbb_partitions` | Partitions Master |
| `cbb_constrlib` | Construction Library — **single source of truth** for all construction profiles |
| `cbb_template` | Loaded master xlsx template (base64) |
| `cbb_maker` | Last-used maker name |
| `cbb_rate_date` | Rate Master last-updated date |
| `cbb_batchprofile` | Batch Profile persisted state (merged over DEFAULTS on load) |
| `cbb_batch_autosave` | Auto-saved batch rows + profile (7-day window; restore banner on load) |
| `cbb_quoteitems` | Persisted Quote Items across sessions |
| `cbb_pinned_addons` | Up to 2 add-on keys pinned as main grid columns in Batch Entry |

---

## 12. Workflow Architecture (as implemented)

```
COSTING TAB
  ├── SAME-BATCH CONTEXT (default)
  │   ├── Start New SKU → specFromProfile() → batch identity from batchProfile
  │   ├── Send to Batch Entry → appends to active batch (G1 guards)
  │   └── Deep Dive (🔍) ↔ Unlink cycle for reviewing existing rows
  │
  └── NEW-BATCH / SCRATCHPAD CONTEXT (Costing → + New Batch)
      ├── Clean workspace — no batchProfile data, no construction inherited
      ├── Start New SKU → specForNewBatch() → no batchProfile reads
      ├── Old batch in BatchEntry remains completely untouched
      └── Send to Batch Entry → HARD BLOCKED if batchRows.length > 0
          └── User must use BatchEntry → + New Batch first

CONSTRUCTION LIBRARY TAB
  └── Create / Edit / Browse / Filter all constructions
  └── Import from Costing (with duplicate check)
  └── Same data ↔ Batch Entry overlay ↔ Costing

BATCH ENTRY TAB
  └── Batch Profile (client, sector, commercials, terms)
  └── Add rows (Box / Plate / Part-L / Part-W)
  └── SET Code: auto-assumed → must confirm → gates all downstream
  └── Paper Construction: overlay button per row → slide-over → select → apply
  └── Calculate All (blocked if any unconfirmed SET Codes)
  └── Deep Dive 🔍 → loads row into Costing (blocked if unconfirmed)
  └── Send All to Quote Items (blocked if any unconfirmed SET Codes)
  └── + New Batch → clears all BatchEntry data + resets Costing spec

QUOTE ITEMS TAB
  └── Final quotation items (only source: Batch Entry → Send All)
  └── SET grouping + combined SET Rate display
  └── Export: PDF / Excel (master template via server.py)
```

---

**Current Status:** App stable at ~5,365 lines. All major architectural upgrades complete: Same-Batch/New-Batch Costing context boundary, SinglePointQuoteFinalization, Construction Library as independent tab, Batch Entry slide-over overlay, SET Code confirmation gates, Glass SKU auto-fill chain, duplicate check on import, Rate/SET inline display, frozen column shadow fix. Next priority: Node.js + SQLite quote storage API (go-live blocker).
