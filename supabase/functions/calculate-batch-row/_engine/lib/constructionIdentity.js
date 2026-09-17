// ═══════════════════════════════════════════════════════════════════════════
// src/lib/constructionIdentity.js — D-11. THE ONE PLACE CONSTRUCTIONS ARE COMPARED.
//
// IDENTITY IS WHAT THE BOARD IS: four board specs + ply + both flutes + boxType
// + paper layers. Nine fields, lifted verbatim from the bridge's `existingFull`
// check, which was the only site that already had it right.
//
// ⚠️ FOUR CREATION PATHS PREVIOUSLY CARRIED THREE DIFFERENT PREDICATES AND ONE
// ABSENCE — each site redeclared its own `toStr` and its own field list:
//
//   bridge-send  9 fields (this set)          → silent reuse
//   app-import   5 fields: board specs + SECTOR
//   tab-import   6 fields: board specs + SECTOR + spec_cobb
//   tab-new      NONE
//
// They drifted because nothing held them together. `toStr` moved in here with the
// predicate for exactly that reason — same lesson as D-7 (eight SET Code
// comparisons, three conventions) and D-27 (two exporters answering differently).
// **Do not redeclare either at a call site.**
//
// ── SECTOR AND CLIENT ARE METADATA, NOT IDENTITY. THIS IS DELIBERATE ──────────
//
// Dropping `sector` from app-import and tab-import, and `spec_cobb` from
// tab-import, was RULED by the product owner on 2026-08-29:
//
//   "Two constructions with identical board specs in different sectors ARE the
//    same construction — that's the client-agnostic ruling applied consistently,
//    and sector becomes a tag rather than an identity field."
//
// **It will read as a regression to anyone who does not know that.** Two entries
// that used to coexist because their sectors differed are now one construction
// with two tags. That is the model, not a bug. See D-11 in the register.
//
// Pure: no React, no imports.
// ═══════════════════════════════════════════════════════════════════════════

export const toStr=v=>(v===undefined||v===null||v===""?"":String(v).trim());

const REQUIRED_3_PLY_LAYERS=["TOP","F1","L1"];
const REQUIRED_5_PLY_LAYERS=[...REQUIRED_3_PLY_LAYERS,"F2","L2"];

export const requiredConstructionLayers=x=>
  +x?.ply===5?REQUIRED_5_PLY_LAYERS:REQUIRED_3_PLY_LAYERS;

// A library row may exist as an unfinished draft, but it is not a usable
// costing construction until every structural layer has both a paper grade
// (the BF-bearing code) and a positive GSM. Keeping this predicate pure lets
// selection, matching and send-readiness share one boundary.
export const constructionLayerIssues=x=>{
  const issues=[];
  const layers=x?.layers||{};
  requiredConstructionLayers(x).forEach(key=>{
    const layer=layers[key]||{};
    if(!toStr(layer.code))issues.push({key,field:"code"});
    const gsm=Number(layer.gsm);
    if(layer.gsm===""||layer.gsm===null||layer.gsm===undefined||!Number.isFinite(gsm)||gsm<=0)
      issues.push({key,field:"gsm"});
  });
  return issues;
};

export const isUsableConstruction=x=>constructionLayerIssues(x).length===0;

// Apply one library construction to a Costing draft. Only construction and
// board-spec fields move: customer/sector metadata are search hints, never
// construction identity, and SKU identity/dimensions/commercials remain owned
// by the draft. A deep layer copy prevents later Costing edits from mutating the
// shared library entry through an aliased object.
export const applyConstructionToSpec=(spec,construction)=>({
  ...spec,
  constructionCode:construction?.code||'',
  boxType:construction?.boxType||'RSC',
  ply:+construction?.ply||5,
  flute_F1:construction?.flute_F1||'B',
  flute_F2:construction?.flute_F2||'',
  layers:JSON.parse(JSON.stringify(construction?.layers||{})),
  board_gsm:construction?.board_gsm??'',
  spec_bs:construction?.spec_bs??'',
  spec_bct:construction?.spec_bct??'',
  spec_ect:construction?.spec_ect??'',
  spec_cobb:construction?.spec_cobb??'',
});

// Normalise BOTH sides the same way. The original compared `+c.ply` against
// `(+spec.ply||5)` — applying the default to the incoming side only, so an entry
// with no ply produced NaN and could never match anything, not even itself.
// Symmetric defaults make the predicate REFLEXIVE, which the entry-vs-entry
// comparison at the tab depends on. That is a deliberate, minor loosening.
//
// KNOWN BLIND SPOT, unchanged from the original and NOT fixed here: `layers` is
// compared as JSON, so it is key-order sensitive. Every entry is built by the
// creation paths in this repo, which emit the same key order, so it holds in
// practice. Making it order-independent is an identity model, and this is not one.
const norm=x=>({
  board_gsm:toStr(x?.board_gsm),
  spec_bs:  toStr(x?.spec_bs),
  spec_bct: toStr(x?.spec_bct),
  spec_ect: toStr(x?.spec_ect),
  ply:      +x?.ply||5,
  flute_F1: toStr(x?.flute_F1),
  flute_F2: toStr(x?.flute_F2),
  boxType:  toStr(x?.boxType||"RSC"),
  layers:   JSON.stringify(x?.layers||{}),
});

export const sameConstruction=(a,b)=>{
  const A=norm(a),B=norm(b);
  return A.board_gsm===B.board_gsm&&A.spec_bs===B.spec_bs&&
         A.spec_bct===B.spec_bct&&A.spec_ect===B.spec_ect&&
         A.ply===B.ply&&A.flute_F1===B.flute_F1&&A.flute_F2===B.flute_F2&&
         A.boxType===B.boxType&&A.layers===B.layers;
};

const hasBoardSpecIdentity=x=>{
  const n=norm(x);
  return !!(n.board_gsm||n.spec_bs||n.spec_bct||n.spec_ect);
};

const sameStandardConstruction=(a,b)=>{
  const A=norm(a),B=norm(b);
  return A.board_gsm===B.board_gsm&&A.spec_bs===B.spec_bs&&
    A.spec_bct===B.spec_bct&&A.spec_ect===B.spec_ect&&A.ply===B.ply&&
    A.flute_F1===B.flute_F1&&A.flute_F2===B.flute_F2&&A.boxType===B.boxType;
};

// Suggestion/reuse is stricter than duplicate detection. Unfinished library
// drafts stay editable in the full library, but can never be selected as a
// costing answer. A standards-only match also needs a real standard on both
// sides; otherwise two sets of blanks would be called a match.
export const findUsableConstructionMatch=(lib,spec)=>(lib||[])
  .find(c=>isUsableConstruction(c)&&sameConstruction(c,spec));

export const findUsableStandardConstructionMatch=(lib,spec)=>{
  if(!hasBoardSpecIdentity(spec))return undefined;
  return (lib||[]).find(c=>isUsableConstruction(c)&&hasBoardSpecIdentity(c)&&
    sameStandardConstruction(c,spec));
};

// Does this entry say anything about what the board IS? A row created by
// "+ New Construction" is blank apart from inherited sector/client, and blank
// rows must never match each other — otherwise every fresh draft is flagged
// against every other fresh draft.
//
// ply and boxType are excluded from this test ON PURPOSE: they carry defaults
// (5, "RSC"), so a blank row already "has" them and they say nothing.
export const hasIdentity=(x)=>{
  const n=norm(x);
  return !!(n.board_gsm||n.spec_bs||n.spec_bct||n.spec_ect||
            n.flute_F1||n.flute_F2||(n.layers!=="{}"&&/[1-9]/.test(n.layers)));
};

// The blocking check used by the three paths that HAVE a commit point.
// `excludeCode` skips the entry being edited so it cannot match itself.
export const findDuplicate=(lib,spec,excludeCode)=>
  (lib||[]).find(c=>c.code!==excludeCode&&sameConstruction(c,spec));
