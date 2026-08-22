-- ═══════════════════════════════════════════════════════════════════════════
-- CFB Quotation Operating System — SQLite Schema
-- APSPL Nagpur | Version 1.0 | August 2026
--
-- Design principles:
--   • Every quote stores a complete spec snapshot — so historical quotes
--     remain accurate even if paper prices, freight or specs change later.
--   • APSPL Item Code is the join key to the operational GSheets world,
--     but is optional (blank for new/pre-spec SKUs).
--   • Quote Code is always present and unique — auto-generated for new SKUs,
--     can mirror the APSPL Item Code for running items.
--   • Price date and adjustment are stored per quote so rate delta and
--     risk premium decisions are auditable.
--   • All monetary values in Rs. Weights in kg. Dimensions in mm.
-- ═══════════════════════════════════════════════════════════════════════════

PRAGMA journal_mode = WAL;       -- safe concurrent reads (future multi-user)
PRAGMA foreign_keys = ON;


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. CUSTOMERS
--    Lightweight master — enough to link quotes and drive analytics.
--    Full customer data lives in the SPEC Master GSheet; this is the app's
--    local reference, synced on demand.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customers (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_family   TEXT NOT NULL,            -- Standard family name (from Customer Master GSheet)
  customer_alias    TEXT,                     -- Short alias used on the shop floor
  sector            TEXT,                     -- PAINTS / ALCOBEV / TEXTILE etc.
  pricing_cycle     TEXT DEFAULT 'monthly',   -- monthly / bimonthly / quarterly / annual / adhoc
  plant             TEXT DEFAULT 'Nagpur',    -- Producing plant
  delivery_location TEXT,                     -- Primary delivery location
  notes             TEXT,
  created_at        TEXT DEFAULT (datetime('now')),
  updated_at        TEXT DEFAULT (datetime('now'))
);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. QUOTES (header)
--    One row per quote session. A session may contain multiple SKUs (items).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS quotes (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  quote_ref       TEXT NOT NULL UNIQUE,       -- e.g. NAG-260807-001 (app-generated)
  customer_id     INTEGER REFERENCES customers(id) ON DELETE SET NULL,
  customer_family TEXT NOT NULL,             -- Denormalised for fast display
  sector          TEXT,
  plant           TEXT DEFAULT 'Nagpur',
  delivery        TEXT,
  maker           TEXT,                      -- Maker name (from cbb_maker localStorage)
  status          TEXT DEFAULT 'draft',      -- draft / submitted / approved / won / lost / superseded
  price_valid_from TEXT,                     -- ISO date
  price_valid_to   TEXT,                     -- ISO date
  -- Price basis for this quote (applies across all items unless overridden per item)
  price_date       TEXT,                     -- Date used to anchor paper rates (ISO date)
  pricing_cycle    TEXT,                     -- Customer's cycle at time of quoting
  -- Win/loss tracking
  outcome          TEXT,                     -- won / lost / no-decision
  outcome_reason   TEXT,                     -- free text: why won or lost
  competitor_rate  REAL,                     -- Competing rate received (Rs/pc), if known
  notes            TEXT,
  created_at       TEXT DEFAULT (datetime('now')),
  updated_at       TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_quotes_customer  ON quotes(customer_id);
CREATE INDEX IF NOT EXISTS idx_quotes_status    ON quotes(status);
CREATE INDEX IF NOT EXISTS idx_quotes_created   ON quotes(created_at);


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. QUOTE ITEMS
--    One row per SKU per quote. Stores the complete spec snapshot so the
--    quote is self-contained and historically accurate.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS quote_items (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  quote_id         INTEGER NOT NULL REFERENCES quotes(id) ON DELETE CASCADE,

  -- Identity
  quote_code       TEXT NOT NULL,    -- Unique within this quote; mirrors APSPL Item Code for running items
  apspl_item_code  TEXT,             -- NULL for new/pre-spec SKUs; join key to GSheet SPEC Master
  item_type        TEXT DEFAULT 'new',  -- 'running' | 'new'
  client_mat_code  TEXT,             -- Customer's own item/material code
  product_name     TEXT,
  set_code         TEXT,             -- SET grouping (Box + Plate + Partition)
  set_role         TEXT DEFAULT 'Box',  -- Box / Plate / Part-L / Part-W
  nos_per_set      INTEGER DEFAULT 1,
  remarks          TEXT,

  -- Dimensions (mm)
  dim_l            REAL, dim_w REAL, dim_h REAL,
  dim_type         TEXT DEFAULT 'ID',  -- ID / OD
  ups              INTEGER DEFAULT 1,
  box_type         TEXT DEFAULT 'RSC',
  ply              INTEGER DEFAULT 5,
  flute_f1         TEXT, flute_f2 TEXT,

  -- Paper construction (5 layers: TOP / F1 / L1 / F2 / L2)
  top_grade        TEXT, top_gsm REAL,
  f1_grade         TEXT,  f1_gsm REAL,
  l1_grade         TEXT,  l1_gsm REAL,
  f2_grade         TEXT,  f2_gsm REAL,
  l2_grade         TEXT,  l2_gsm REAL,

  -- Paper mill assignment per layer (from SPEC Master or user selection)
  top_mill         TEXT, f1_mill TEXT, l1_mill TEXT, f2_mill TEXT, l2_mill TEXT,

  -- Calculated board properties
  calc_gsm         REAL,
  calc_bs          REAL,   -- Bursting Strength kg/cm²
  fluting_bcf      REAL DEFAULT 0.10,

  -- Standard spec (customer requirements)
  std_board_gsm    REAL,
  std_bs           REAL,
  std_bct          REAL,
  std_ect          REAL,
  std_box_wt       REAL,  -- required box weight in grams

  -- Commercial parameters
  waste_pct        REAL,        -- Box waste %
  waste_pp_pct     REAL,        -- PP waste %
  conv_rate        REAL,        -- Conversion Rs/kg (Box)
  conv_rate_pp     REAL,        -- Conversion Rs/kg (PP)
  freight_rs_kg    REAL,        -- Freight Rs/kg applied
  freight_override INTEGER DEFAULT 0,  -- 1 if manually overridden
  margin_pct       REAL,
  interest_pct     REAL,
  payment_disc     TEXT,        -- '30' / '45' / '60' / '90' days

  -- Paper price basis for this item
  price_date       TEXT,        -- Date used for rate lookup (ISO date)
  price_adj_pct    REAL DEFAULT 0,  -- Risk premium (+) or trend discount (−) over base price
  price_adj_note   TEXT,        -- Rationale for adjustment

  -- Add-on costs (Rs/pc)
  addon_printing   REAL DEFAULT 0,
  addon_stitching  REAL DEFAULT 0,
  addon_coating    REAL DEFAULT 0,
  addon_handling   REAL DEFAULT 0,
  addon_moq_charge REAL DEFAULT 0,
  addon_packing    REAL DEFAULT 0,
  addon_other      REAL DEFAULT 0,
  addon_unloading  REAL DEFAULT 0,

  -- Costing outputs (snapshot at time of quote)
  paper_consumed_kg  REAL,   -- Paper consumed per piece (incl. waste)
  sheet_wt_kg        REAL,   -- Sheet weight per piece (excl. waste)
  est_box_wt_g       REAL,   -- Estimated box weight in grams
  mat_cost           REAL,   -- Material cost Rs/pc
  conv_cost          REAL,   -- Conversion cost Rs/pc
  freight_cost       REAL,   -- Freight cost Rs/pc
  interest_cost      REAL,
  addon_total        REAL,
  total_cost         REAL,   -- Total cost Rs/pc (excl. margin)
  margin_amt         REAL,
  final_rate         REAL,   -- Final rate Rs/pc (MROUND to 0.05)
  rate_per_kg        REAL,   -- Final rate Rs/kg (on sheet weight)
  calc_moq           INTEGER,  -- Minimum order quantity (boxes)

  -- Mill preferences per layer (Framing A: mill-agnostic construction + preference overlay)
  -- JSON: {"TOP":{"grade":"A","mill":"JK Paper"},"F1":{"grade":"B","mill":""},...}
  -- Grade: A/B/C from Mill Master. Mill: specific name (optional — grade alone valid).
  -- Empty = no preference (engine uses lowest available price at rate lookup time).
  mill_preferences    TEXT DEFAULT '{}',

  -- Volume and MOQ
  sales_moq          INTEGER,
  volume_per_month   INTEGER,  -- Nos/month

  -- Compliance flags
  bs_compliant       INTEGER,  -- 1=pass, 0=fail, NULL=not checked
  bct_compliant      INTEGER,
  ect_compliant      INTEGER,
  gsm_compliant      INTEGER,
  wt_compliant       INTEGER,

  created_at         TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_qitems_quote       ON quote_items(quote_id);
CREATE INDEX IF NOT EXISTS idx_qitems_apspl_code  ON quote_items(apspl_item_code);
CREATE INDEX IF NOT EXISTS idx_qitems_set_code    ON quote_items(set_code);
CREATE INDEX IF NOT EXISTS idx_qitems_product     ON quote_items(product_name);


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. PAPER RATE SNAPSHOTS
--    Stores the exact rate used per layer per quote item, with the source
--    (live GSheet pull vs. manual entry) and any adjustment applied.
--    This is the foundation of rate delta analysis across quotes.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS quote_item_rates (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  quote_item_id   INTEGER NOT NULL REFERENCES quote_items(id) ON DELETE CASCADE,
  layer           TEXT NOT NULL,    -- TOP / F1 / L1 / F2 / L2
  grade_code      TEXT,
  gsm             REAL,
  mill            TEXT,
  -- Raw price from source
  base_price      REAL,             -- Landed Basic Price Rs/kg from Price List
  price_date      TEXT,             -- Date of this price entry in the GSheet
  price_source    TEXT DEFAULT 'gsheet',  -- 'gsheet' | 'manual'
  -- Adjustments
  adj_pct         REAL DEFAULT 0,   -- Risk premium / trend discount %
  adj_note        TEXT,
  -- Effective rate as used in the costing engine
  credit_pct      REAL,
  discount        REAL,
  freight_rs_kg   REAL,
  gsm_surcharge   REAL,
  effective_rate  REAL,             -- Final rate fed into calcCosting
  created_at      TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_rates_item  ON quote_item_rates(quote_item_id);
CREATE INDEX IF NOT EXISTS idx_rates_mill  ON quote_item_rates(mill, grade_code);


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. QUOTE VERSIONS
--    Every time a quote is revised and resubmitted, the old version is
--    preserved here. The quotes table always holds the latest version.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS quote_versions (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  quote_id        INTEGER NOT NULL REFERENCES quotes(id) ON DELETE CASCADE,
  version_number  INTEGER NOT NULL,
  snapshot_json   TEXT NOT NULL,    -- Full JSON of the quote + all items at that version
  reason          TEXT,             -- Why was this revision made?
  maker           TEXT,
  created_at      TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_versions_quote ON quote_versions(quote_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. PRICE RATE CACHE
--    Local cache of paper prices pulled from the GSheet Price List.
--    Refreshed on demand (not a live sync). Enables offline rate lookups
--    and powers the rate-delta calculation without a live GSheet call.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS price_cache (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  mill            TEXT NOT NULL,
  grade_code      TEXT NOT NULL,
  bf              INTEGER,
  gsm_nominal     REAL,
  price_date      TEXT NOT NULL,          -- Date of this price entry (ISO date)
  basic_price     REAL NOT NULL,          -- Mill's basic price Rs/kg
  freight_cost    REAL DEFAULT 0,         -- Inward freight to plant
  other_costs     REAL DEFAULT 0,
  landed_price    REAL,                   -- basic + freight + other (auto-calc on insert)
  currency        TEXT DEFAULT 'INR',
  cached_at       TEXT DEFAULT (datetime('now')),
  UNIQUE(mill, grade_code, price_date)
);

CREATE INDEX IF NOT EXISTS idx_price_mill_grade ON price_cache(mill, grade_code);
CREATE INDEX IF NOT EXISTS idx_price_date        ON price_cache(price_date);

-- Auto-calculate landed_price on insert
CREATE TRIGGER IF NOT EXISTS trg_landed_price
  AFTER INSERT ON price_cache
  WHEN NEW.landed_price IS NULL
BEGIN
  UPDATE price_cache
  SET landed_price = NEW.basic_price + COALESCE(NEW.freight_cost,0) + COALESCE(NEW.other_costs,0)
  WHERE id = NEW.id;
END;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. INWARD QC CACHE
--    Local cache of paper quality test results pulled from the GSheet
--    Inward Paper QA Test Report. Powers the "historical actual quality range"
--    shown alongside spec compliance in the Costing tab.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS inward_qc_cache (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  our_reel_no     TEXT,
  grn_date        TEXT,
  mill            TEXT NOT NULL,
  grade_code      TEXT,
  bf_ordered      REAL,
  gsm_ordered     REAL,
  deckle_mm       REAL,
  -- Test results (averages across multiple sample points)
  avg_gsm         REAL,
  avg_bf          REAL,
  avg_bs          REAL,
  avg_rct         REAL,
  cobb            REAL,
  moisture_pct    REAL,
  -- Outcome
  accept_status   TEXT,   -- 'accepted' | 'accepted_deviation' | 'rejected'
  reason_code     INTEGER,  -- Matches Paper Planning reason codes 1-16
  notes           TEXT,
  cached_at       TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_qc_mill_grade ON inward_qc_cache(mill, grade_code);
CREATE INDEX IF NOT EXISTS idx_qc_date       ON inward_qc_cache(grn_date);


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. SPEC CACHE
--    Local cache of Running Items from the SPEC Master GSheet.
--    Refreshed on demand. Used for APSPL Item Code lookup and auto-fill
--    when a Running Item is selected in the Costing or Batch Entry tab.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS spec_cache (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  apspl_item_code  TEXT NOT NULL UNIQUE,
  item_short_name  TEXT NOT NULL,
  customer_family  TEXT,
  customer_alias   TEXT,
  item_status      TEXT,   -- Running / Underdeveloped / Discontinued
  item_family      TEXT,
  item_group       TEXT,
  sector           TEXT,
  -- STD dimensions (customer-facing)
  std_l_mm         REAL, std_w_mm REAL, std_h_mm REAL,
  ply              INTEGER,
  flute_f1         TEXT,  flute_f2 TEXT,
  box_type         TEXT,
  -- STD spec
  std_board_gsm    REAL,
  std_bs           REAL,
  std_bct          REAL,
  std_ect          REAL,
  -- Paper composition (STD — customer-facing BF/GSM)
  top_grade TEXT, top_gsm REAL, top_mill TEXT,
  f1_grade  TEXT, f1_gsm  REAL, f1_mill  TEXT,
  l1_grade  TEXT, l1_gsm  REAL, l1_mill  TEXT,
  f2_grade  TEXT, f2_gsm  REAL, f2_mill  TEXT,
  l2_grade  TEXT, l2_gsm  REAL, l2_mill  TEXT,
  -- INT (Boardline) deckle / GSM / BF — used for paper planning
  int_deckle_mm    REAL,
  int_top_gsm      REAL, int_f1_gsm REAL, int_l1_gsm REAL,
  int_f2_gsm       REAL, int_l2_gsm REAL,
  -- Mill preferences captured on SPEC sheet (Paper Mill Assignment columns)
  -- JSON same structure as quote_items.mill_preferences
  mill_preferences    TEXT DEFAULT '{}',

  -- Partition / Plate spec (if applicable)
  has_partition    INTEGER DEFAULT 0,
  has_plate        INTEGER DEFAULT 0,
  cached_at        TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_spec_name    ON spec_cache(item_short_name);
CREATE INDEX IF NOT EXISTS idx_spec_family  ON spec_cache(customer_family);
CREATE INDEX IF NOT EXISTS idx_spec_status  ON spec_cache(item_status);


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. USERS / MAKERS
--    Simple maker registry. No passwords — authentication is out of scope
--    for Phase 1. Role controls what tabs/actions are enabled in the UI.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL UNIQUE,
  role        TEXT DEFAULT 'maker',  -- maker / checker / admin
  plant       TEXT DEFAULT 'Nagpur',
  active      INTEGER DEFAULT 1,
  created_at  TEXT DEFAULT (datetime('now'))
);


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. APPROVAL LOG
--     Every status change on a quote is recorded here with who did it and why.
--     Foundation for the Maker-Checker workflow.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS approval_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  quote_id    INTEGER NOT NULL REFERENCES quotes(id) ON DELETE CASCADE,
  from_status TEXT,
  to_status   TEXT NOT NULL,
  actor       TEXT NOT NULL,   -- maker/checker name
  role        TEXT,
  note        TEXT,
  created_at  TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_approval_quote ON approval_log(quote_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- 11. CACHE REFRESH LOG
--     Tracks when each GSheet cache was last refreshed, so the UI can show
--     "Rates last updated: 3 days ago" and flag stale caches.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cache_refresh_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  cache_table   TEXT NOT NULL,   -- 'price_cache' | 'inward_qc_cache' | 'spec_cache'
  rows_fetched  INTEGER,
  status        TEXT,            -- 'success' | 'error'
  error_message TEXT,
  refreshed_at  TEXT DEFAULT (datetime('now'))
);


-- ─────────────────────────────────────────────────────────────────────────────
-- VIEWS — pre-built analytics queries
-- ─────────────────────────────────────────────────────────────────────────────

-- Latest price per mill/grade (most recent date wins)
CREATE VIEW IF NOT EXISTS v_latest_prices AS
SELECT
  mill, grade_code, bf, gsm_nominal,
  basic_price, freight_cost, landed_price,
  price_date,
  ROW_NUMBER() OVER (PARTITION BY mill, grade_code ORDER BY price_date DESC) AS rn
FROM price_cache;

-- Rate delta: compare latest price vs price on a given past date
-- Usage: SELECT * FROM v_rate_delta WHERE grade_code='20' AND past_date='2026-05-01'
CREATE VIEW IF NOT EXISTS v_rate_delta AS
SELECT
  a.mill, a.grade_code,
  a.price_date AS latest_date, a.landed_price AS latest_price,
  b.price_date AS prev_date,   b.landed_price AS prev_price,
  ROUND(a.landed_price - b.landed_price, 2) AS delta_rs,
  ROUND((a.landed_price - b.landed_price) / b.landed_price * 100, 1) AS delta_pct
FROM price_cache a
JOIN price_cache b ON a.mill = b.mill AND a.grade_code = b.grade_code
WHERE a.price_date = (SELECT MAX(price_date) FROM price_cache p WHERE p.mill=a.mill AND p.grade_code=a.grade_code);

-- Historical quality range per mill/grade
CREATE VIEW IF NOT EXISTS v_qc_summary AS
SELECT
  mill, grade_code,
  COUNT(*) AS test_count,
  ROUND(AVG(avg_gsm),1) AS mean_gsm,  ROUND(MIN(avg_gsm),1) AS min_gsm,  ROUND(MAX(avg_gsm),1) AS max_gsm,
  ROUND(AVG(avg_bs), 2) AS mean_bs,   ROUND(MIN(avg_bs), 2) AS min_bs,   ROUND(MAX(avg_bs), 2) AS max_bs,
  ROUND(AVG(avg_bf), 1) AS mean_bf,
  ROUND(AVG(avg_rct),2) AS mean_rct,
  SUM(CASE WHEN accept_status='rejected' THEN 1 ELSE 0 END) AS rejects,
  SUM(CASE WHEN accept_status='accepted_deviation' THEN 1 ELSE 0 END) AS deviations,
  MAX(grn_date) AS last_tested
FROM inward_qc_cache
GROUP BY mill, grade_code;

-- Quote summary with customer and outcome
CREATE VIEW IF NOT EXISTS v_quote_summary AS
SELECT
  q.id, q.quote_ref, q.customer_family, q.sector, q.plant, q.delivery,
  q.maker, q.status, q.outcome, q.competitor_rate,
  q.price_date, q.created_at,
  COUNT(qi.id) AS sku_count,
  ROUND(AVG(qi.margin_pct),1) AS avg_margin_pct,
  ROUND(AVG(qi.final_rate),2) AS avg_final_rate,
  SUM(qi.volume_per_month) AS total_volume_per_month
FROM quotes q
LEFT JOIN quote_items qi ON qi.quote_id = q.id
GROUP BY q.id;

-- Item-level quote history (for similar-quotation search)
CREATE VIEW IF NOT EXISTS v_item_history AS
SELECT
  qi.apspl_item_code,
  qi.product_name,
  qi.set_role,
  q.customer_family,
  q.sector,
  q.plant, q.delivery,
  qi.dim_l, qi.dim_w, qi.dim_h,
  qi.ply, qi.flute_f1, qi.flute_f2,
  qi.top_grade, qi.top_gsm, qi.f1_grade, qi.f1_gsm,
  qi.l1_grade, qi.l1_gsm, qi.f2_grade, qi.f2_gsm, qi.l2_grade, qi.l2_gsm,
  qi.calc_bs, qi.calc_gsm,
  qi.waste_pct, qi.conv_rate, qi.freight_rs_kg,
  qi.margin_pct, qi.final_rate, qi.rate_per_kg,
  qi.price_date, qi.price_adj_pct,
  q.outcome, q.competitor_rate,
  q.created_at AS quote_date,
  q.quote_ref, q.maker
FROM quote_items qi
JOIN quotes q ON q.id = qi.quote_id;
