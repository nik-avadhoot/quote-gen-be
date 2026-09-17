// ═══════════════════════════════════════════════════════════════════════════
// src/engine/costing.js
// Core costing engine — pure JavaScript, zero React dependencies.
// Reusable from: Web App · Node.js API · ERP · Batch processor · AI agents.
//
// Key exports:
//   calcCosting(spec, rates, freight, boxTrimData) → result object
//   checkSpecCompliance(spec, result) → [{field, severity, …}]
//   suggestMargin(spec, calcMOQ) → {suggested, adjustments, risk}
//   checkMissingInfo(spec, result) → {blockers, warnings, assumptions}
//   getEffectiveRate(code, gsm, rates) → number
//   buildSpecFromRow(row, constEntry, profile) → full spec object
// ═══════════════════════════════════════════════════════════════════════════

import { DEFAULT_BOX_TRIM_DATA, TAKEUP, TRIM } from './costingTables.js';
import { CALC_DEFAULTS } from './calcDefaults.js';
import { resolveFreight } from './resolveAuthority.js';
import { constructionLayerIssues } from '../lib/constructionIdentity.js';

// DEFAULT_FREIGHT is an application MIRROR, not an approved Freight Master.
// This label is what a snapshot records for it, and it can never occupy the
// governed {freightSetVersionId, freightEntryId} reference shape.
export const LEGACY_FREIGHT_MATRIX_REF='app-mirror/default-freight';

export const bfNum=c=>{const n=parseInt(String(c||""));return n===35?33:n||0;};
export const gsmS=g=>{const v=+g||0;if(v>0&&v<100)return 4;if(v===100)return 1.5;if(v>200)return 1;return 0;};
export const tuFor=f=>TAKEUP[f]||1;
export const getTrim=(bt,ply,trimData)=>{ const t=(trimData||TRIM)[bt]||(trimData||TRIM).RSC||{3:[30,60],5:[35,75]}; return t[+ply===5?5:3]||[t.d5||35,t.c5||75]; };
export const getTrimD=(bt,ply,trimData)=>{ const td=trimData||DEFAULT_BOX_TRIM_DATA; const t=td[bt]||(bt==='PP'?{d3:0,c3:0,d5:0,c5:0}:td.RSC); if(!t)return getTrim(bt,ply); return ply===5?[t.d5,t.c5]:[t.d3,t.c3]; };
export const getEffectiveRate=(code,gsm,rates)=>{
  if(!code)return 0;
  const e=rates.find(r=>r.code===code);
  if(!e||e.effectiveRate==null||e.effectiveRate===''||isNaN(+e.effectiveRate))return 0;
  return +e.effectiveRate+gsmS(gsm);
};
export const getFreightRate=(plant,delivery,matrix,override)=>{
  if(override&&+override>0)return +override;
  return matrix?.[plant]?.[delivery]||0;
};
export const calcCosting=(spec,rates,freight,boxTrimData,resolvedFreightRate)=>{
  const{L,W,H,ply=5,boxType="RSC",layers={},flute_F1,flute_F2,ups=1,
    waste=5,convRate=7,wastePP=5,convRatePP=12.5,freightOverride,plant,delivery,margin=8,interest,
    printing=0,stitching=0,coating=0,handling=0,moqCharge=0,packing=0,other=0,unloading=0,
    flutingBCF=0.10,setCode,rowType}=spec;
  const isBoard=boxType==="Board"||boxType==="PP"; // PP = plates/partitions: flat piece formula
  if(!+L||!+W||(!isBoard&&!+H))return null;
  // A partial paper stack is not a cheaper construction; it is no construction.
  // Fail before arithmetic so omitted BF/grade or GSM can never become zero-cost
  // layers in a seemingly usable result, including through non-UI callers.
  if(constructionLayerIssues(spec).length)return null;
  // PP-aware rates: Plate/Partition rows use P&P waste and conv rates.
  // NOTE: must use a proper "is this actually unset" check, not `||` — several
  // sectors (Textile, Cooler, Petrol, Edible-Oil, Footwear, Elec-LED, Beauty,
  // Chemical) legitimately have wastePP/convRatePP = 0, and `0 || 5` silently
  // discards that 0 and substitutes the fallback, over-costing Paper Consumed.
  const nz=(v,d)=>(v===''||v==null||isNaN(+v))?d:+v;
  const isPP=rowType==="Plate"||rowType==="Part-L"||rowType==="Part-W";
  const effWaste=isPP?nz(wastePP,5):nz(waste,5);
  const effConv=isPP?nz(convRatePP,12.5):nz(convRate,7); // A1-04: fallback 10.5→12.5 to match INIT_SPEC/profile/buildSpecFromRow defaults
  // S7 / E-1 + E-2. Interest joins waste and conversion in the nz() treatment,
  // for the same reason and with one extra: `+interest||0` at the line below
  // could not tell a BLANK apart from an EXPLICIT ZERO, because `+""` is 0 and
  // `0||0` is 0. Blank must inherit the versioned fallback; an explicit 0 must
  // charge no interest and survive. The destructuring default of 1.5 that used
  // to sit on `interest` is gone with it — CDM-18 gives one fallback and it is
  // 0.5, so a fourth answer hard-coded here was an answer nobody approved.
  const effInterest=nz(interest,CALC_DEFAULTS.interestFallbackPct);
  const[dkl,cut]=getTrimD(boxType,+ply,boxTrimData);
  // Deckle formulas by box type (authoritative — verified against Excel CBB+PP col P):
  //   Board/PP : L × Ups + DklTrim
  //   HRSC-L/R : (W/2 + H) × Ups + DklTrim  ← half-slotted: one side open, so W/2 not W
  //   HRSC-O   : H × Ups + DklTrim           ← open-top: only height contributes to deckle
  //   RSC/Die  : (W + H) × Ups + DklTrim
  const isHRSC_LR = boxType==="HRSC-L"||boxType==="HRSC-R";
  const isHRSC_O  = boxType==="HRSC-O";
  const deckle = isBoard    ? (+L*+ups+dkl)
               : isHRSC_LR ? ((+W/2 + +H)*+ups+dkl)
               : isHRSC_O  ? (+H*+ups+dkl)
               :              ((+W + +H)*+ups+dkl);   // RSC, Die-R, Die-S, Custom
  const cutting=isBoard?(+W+cut):(+L+ +W)*2+cut;
  const area=deckle*cutting/1e6/+ups;
  let wt=0,wtSheet=0,mat=0;const rowDetails=[];
  [["TOP",false,null],["F1",true,flute_F1],["L1",false,null],["F2",true,flute_F2],["L2",false,null]]
  .forEach(([k,isF,fl])=>{
    const ly=layers[k]||{};
    if(!ly.code||!ly.gsm){rowDetails.push({k,wt:0,cost:0,rate:0});return;}
    const tu=isF?tuFor(fl):1;
    const wc=(+ly.gsm/1000)*area*tu*(1+effWaste/100); // Paper Consumed (incl waste — PP-aware)
    const ws=(+ly.gsm/1000)*area*tu;                   // Sheet Weight (actual box)
    const r=getEffectiveRate(ly.code,ly.gsm,rates);
    wt+=wc;wtSheet+=ws;mat+=wc*r;
    rowDetails.push({k,wt:wc,ws,cost:wc*r,rate:r,code:ly.code,gsm:ly.gsm,tu});
  });
  // S8(a). `resolvedFreightRate` is a PRE-RESOLVED NUMBER, never a context:
  // calcCosting cannot resolve freight, so it cannot double-resolve it or
  // disagree with the boundary that did. `undefined` is the legacy path,
  // unchanged and bit-identical - flag-off parity is structural, not emulated.
  const frRate=resolvedFreightRate===undefined
    ?getFreightRate(plant,delivery,freight,freightOverride)
    :+resolvedFreightRate;
  // wt=Paper Consumed (waste incl), wtSheet=actual box weight (no waste)
  const conv=wt*effConv;    // Conversion on Paper Consumed (PP-aware — was always using Box convRate)
  const fr=wtSheet*frRate;          // Freight on Sheet Weight (goods shipped)
  const addOns=(+printing||0)+(+stitching||0)+(+coating||0)+(+handling||0)+(+moqCharge||0)+(+packing||0)+(+other||0)+(+unloading||0);
  const sub=mat+conv+addOns;          // v6.1: NO freight in Total Cost
  const intC=sub*effInterest/100;      // Interest on mat+conv+addons only (E-2: blank != zero)
  const total=sub+intC+fr;            // Total Cost INCL freight — landed rate basis
  const marginAmt=total*(+margin||0)/100;
  const finalRate=Math.round((total+marginAmt)*20)/20;
  const moqKg=+ply*1100;
  const calcMOQ=wt>0?Math.round(moqKg/wt/100)*100:0;
  const estimatedBoxWt=+(wtSheet*0.98).toFixed(4); // Sheet Wt excl waste -2% (RSC convention)
  const ratePerKg=wtSheet>0?finalRate/wtSheet:0;          // Rate/kg on Sheet Weight — BM7=BL7/AV7
  // BS formula (ref: GSM-BS_Calc.xlsx): BS = Σ(BF_adj × BCF × GSM / 1000)
  // Liner BCF=1; Flute BCF=flutingBCF (user slider, 0–0.30, default 0.10)
  const flBCF=(flutingBCF!=null&&flutingBCF!==''&&!isNaN(+flutingBCF))?+flutingBCF:0.10;
  const calcBS=[["TOP",false],["F1",true],["L1",false],["F2",true],["L2",false]]
    .reduce((s,[k,isFlute])=>{const l=layers[k]||{};if(!l.code||!l.gsm)return s;
      return s+bfNum(l.code)*(isFlute?flBCF:1)*+l.gsm/1000;},0);
  const calcGSM=[["TOP",""],["F1",flute_F1],["L1",""],["F2",flute_F2],["L2",""]]
    .reduce((s,[k,fl])=>{const l=layers[k]||{};if(!l.gsm)return s;
      return s+(k==="F1"||k==="F2"?+l.gsm*(tuFor(fl)||1):+l.gsm);},0);
  return{deckle,cutting,area,wt,wtSheet,mat,conv,fr,addOns,intC,total,finalRate,marginAmt,moqKg,estimatedBoxWt,
    calcMOQ,calcBS:+calcBS.toFixed(2),calcGSM:Math.round(calcGSM),ratePerKg:+ratePerKg.toFixed(2),
    frRate,rowDetails};
};

/* ═══ S8(a) — THE FREIGHT OUTCOME BOUNDARY ═════════════════════════════════
   The ONLY caller of resolveFreight. Freight resolves exactly once, here, and
   travels as a value alongside the result it produced - so the blocker reads
   the same object the calculation used and no consumer recomputes anything.
   There is no module-global "last resolution" state; there is nothing to go
   stale.

   WHY A WRAPPER AND NOT A FATTER RESULT. When freight is unresolved there is
   no result at all - arithmetic must not run on a null - but the REASON still
   has to reach the UI. Hanging the reason off the result cannot work, because
   the result is exactly what is missing. So the pair is returned:

       { result: CostingResult|null, freightResolution: FreightResolution|null }

   Neither field can be mistaken for the other. The wrapper carries no costing
   fields, it is frozen, and both live call sites destructure it on the same
   line it is created - its lifetime is one expression and it never enters
   state. `calcCosting` keeps its own name, arity and return type, so nothing
   that calls the old name can receive a wrapper.

   FLAG OFF IS THE LEGACY FUNCTION, NOT AN EMULATION OF IT. When authorityV2 is
   false this does not call the resolver at all: it calls the unchanged
   calcCosting path with no fifth argument and returns freightResolution:null.
   Bit-identical parity is then structural - the same code computing the same
   number, including the legacy treatment of an explicit zero, which the legacy
   `if(override&&+override>0)` DISCARDS. The new explicit-zero semantics arrive
   only with the flag. Emulating legacy behaviour from a v2 resolution would be
   a second answer, which is the defect this slice exists to remove.        */
export const calcCostingOutcome=(spec,rates,freight,boxTrimData,opts={})=>{
  if(!opts.authorityV2)
    return Object.freeze({result:calcCosting(spec,rates,freight,boxTrimData),
                          freightResolution:null});

  const freightResolution=resolveFreight({
    rowOverride:opts.rowOverride, rowRef:opts.rowRef??null,
    legacyBatchOverride:spec?.freightOverride, legacyBatchRef:opts.legacyBatchRef??null,
    pricingGroup:opts.pricingGroup??null,
    approvedMasterRate:opts.approvedMasterRate,
    approvedMasterRef:opts.approvedMasterRef??null,
    approvedMasterUnavailable:opts.approvedMasterUnavailable??null,
    legacyMatrix:freight??null, legacyMatrixRef:LEGACY_FREIGHT_MATRIX_REF,
    originPlant:spec?.plant, legacyDestination:spec?.delivery,
  });

  // Unresolved: return BEFORE any arithmetic. `+null` (0) and `wtSheet*undefined`
  // (NaN) are unreachable by construction, not by inspection.
  if(freightResolution.value===null)
    return Object.freeze({result:null,freightResolution});

  return Object.freeze({
    result:calcCosting(spec,rates,freight,boxTrimData,freightResolution.value),
    freightResolution});
};

/* ═══ S8(a) — FREIGHT MESSAGES ═════════════════════════════════════════════
   Reason-specific, and honest about which tier answered. A value that came
   from the temporary legacy matrix never says "approved Master".            */
const freightRoute=spec=>`${spec?.plant||"?"} → ${spec?.delivery||"?"}`;

export const freightBlockerText=(spec,fr)=>{
  if(fr.reason==="manual_value_missing")
    return "Freight unresolved — Pricing Group is set to manual with no value";
  switch(fr.degradedFrom){
    case "basis_missing":
      return "Freight unresolved — Pricing Group is in master mode with no freight-basis Delivery Group selected";
    case "basis_ship_to_missing":
      return "Freight unresolved — the freight-basis Delivery Group has no Ship-to Location";
    case "no_approved_pair":
      return "Freight unresolved — no approved Freight Master rate for the freight basis, and no legacy rate on file";
    default:
      return `Freight unresolved — no override, and no freight rate on file for ${freightRoute(spec)}`;
  }
};

export const freightAssumptionText=(spec,fr)=>{
  switch(fr.source){
    case "row":
      return "Freight from the row override";
    case "legacy_batch":
      return "Freight from the Batch Profile override (temporary — not yet governed Pricing Group freight)";
    case "pricing_group":
      return fr.mode==="ex_factory"
        ?"Ex-factory — no freight charged"
        :"Freight from Pricing Group (manual)";
    case "master":
      return `Freight from the approved Freight Master (Freight Set version ${fr.sourceRef?.freightSetVersionId})`;
    case "legacy_matrix":
      return `Freight from the temporary legacy matrix (${freightRoute(spec)}) — approved Freight Master not yet available`;
    default:
      return "Freight from plant×location matrix";
  }
};

/* ═══ MISSING INFO ENGINE ═══════════════════════════════════════════════════ */
export const checkMissingInfo=(spec,result,freightResolution)=>{
  const B=[],W=[],A=[];
  const needsH=spec.boxType!=="Board"&&spec.boxType!=="PP";
  if(!spec.L||!spec.W||(needsH&&!+spec.H))
    B.push(needsH?"Box dimensions (L×W×H) not entered":"Board dimensions (L×W) not entered — H not required for flat Board pieces");
  const layerIssues=constructionLayerIssues(spec);
  if(layerIssues.length){
    const affected=[...new Set(layerIssues.map(issue=>issue.key))].join(", ");
    B.push(`Paper construction incomplete — grade/BF and positive GSM required for ${affected}`);
  }
  if(!spec.delivery)                 B.push("Freight not specified");
  if(!spec.volume||+spec.volume===0) B.push("Monthly volume (nos/month) not provided");
  if(!spec.sector)                   W.push("Sector not selected — sector defaults not applied");
  if(!spec.flute_F1)                 W.push("Flute type not specified");
  if(!spec.spec_bs&&!spec.spec_bct&&!spec.spec_ect)
                                     W.push("No strength spec (BS/BCT/ECT) — costing on calculated values only");
  if(!spec.board_gsm)                W.push("Std Board GSM not provided — cannot verify Calc GSM");
  if(spec.salesMOQ&&result?.calcMOQ&&+spec.salesMOQ<result.calcMOQ)
                                     W.push(`Proposed MOQ (${(+spec.salesMOQ).toLocaleString()} boxes) is below minimum production run (${result.calcMOQ.toLocaleString()} boxes = ${result.moqKg.toLocaleString()} kg)`);
  if(spec.isRepeat) A.push("Repeat customer — previous delivery terms assumed");
  // S8(a). The freight line used to be one assumption for three different
  // situations: an inherited rate, an explicit zero, and NO RATE ON FILE. It
  // now reads the resolution the calculation actually used - it does NOT
  // recompute freight, and there is no second answer to disagree with.
  // Omitted (flag off, or any other caller) keeps the pre-S8 line exactly.
  if(freightResolution==null){
    if(!spec.freightOverride) A.push("Freight from plant×location matrix");
  }else if(freightResolution.source==="unresolved"){
    B.push(freightBlockerText(spec,freightResolution));
  }else{
    A.push(freightAssumptionText(spec,freightResolution));
  }
  return{blockers:B,warnings:W,assumptions:A};
};

/* ═══ SPEC COMPLIANCE CHECKER (>5% both directions) ════════════════════════ */
export const checkSpecCompliance=(spec,result)=>{
  if(!result)return[];
  const T=0.05,items=[];
  if(spec.spec_bs&&result.calcBS){
    const std=+spec.spec_bs,calc=result.calcBS,pct=(calc-std)/std*100;
    if(Math.abs(pct)>T*100)
      items.push({field:"Bursting Strength",unit:"kg/cm²",std,calc,pct:+pct.toFixed(1),
        type:pct>0?"over":"under",severity:pct<0?"high":"medium"});
  }
  if(spec.board_gsm&&result.calcGSM){
    const std=+spec.board_gsm,calc=result.calcGSM,pct=(calc-std)/std*100;
    if(Math.abs(pct)>T*100)
      items.push({field:"Board GSM",unit:"g/m²",std,calc,pct:+pct.toFixed(1),
        type:pct>0?"over":"under",severity:pct<0?"medium":"low"});
  }
  return items;
};
export const estimateOverspecSaving=(spec,result,rates)=>{
  if(!result||result.calcBS<=0)return null;
  const cands=[{k:"F1",fl:spec.flute_F1},{k:"F2",fl:spec.flute_F2}]
    .filter(c=>spec.layers[c.k]?.code&&+spec.layers[c.k]?.gsm>0)
    .sort((a,b)=>+spec.layers[b.k].gsm-+spec.layers[a.k].gsm);
  if(!cands.length)return null;
  const{k,fl}=cands[0],ly=spec.layers[k],cur=+ly.gsm;
  const red=cur>=150?cur-30:cur>=120?cur-20:null;
  if(!red||red<100)return null;
  const w=(cur-red)/1000*result.area*tuFor(fl);
  const rate=getEffectiveRate(ly.code,cur,rates);
  return{layer:k,fromGSM:cur,toGSM:red,saving:+(w*rate).toFixed(2),note:`Reduce ${k}: ${cur}→${red} GSM`};
};

/* ═══ MARGIN SUGGESTION ENGINE ══════════════════════════════════════════════ */
export const suggestMargin=(spec,calcMOQ)=>{
  let m=8;const adj=[];
  const ct=spec.customerType||"existing",vl=+spec.volume||0,pc=spec.priceContext||"unknown";
  // A4-ENG-01: Removed dead code block (lines 161-163 in original) — the convoluted
  // object-lookup &&-chain that ran first and was immediately overwritten by the
  // custD/custT block below. Removing it has zero effect on output.
  const custD={strategic:-2,new:1,existing:0,spot:2}[ct]||0;
  const custT={strategic:"Strategic account (−2%)",new:"New customer (+1%)",spot:"Spot order (+2%)"}[ct];
  m=8+custD; if(custT)adj.push(custT);
  // vl is now in Nos/month; calcMOQ is in boxes
  const moq=calcMOQ||0;
  const volD=vl>0&&moq>0&&vl>moq*2?{d:-1,t:"High volume >2× MOQ/mo (−1%)"}
    :vl>0&&moq>0&&vl>=moq?null
    :vl>0&&moq>0&&vl<moq?{d:1,t:"Volume < 1 MOQ run/mo (+1%)"}
    :vl>0&&!moq?null
    :{d:0.5,t:"Volume not provided (+0.5%)"};
  if(volD){m+=volD.d;adj.push(volD.t);}
  const priceD={sensitive:{d:-2,t:"Street price known (−2%)"},unknown:{d:0},premium:{d:2,t:"Premium buyer (+2%)"},tender:{d:-1.5,t:"Tender/bid (−1.5%)"}}[pc]||{d:0};
  if(priceD.d){m+=priceD.d;adj.push(priceD.t);}
  const suggested=Math.max(5,Math.min(18,Math.round(m*2)/2));
  const risk=suggested<7?"⚠️ Low margin — checker review required":suggested>14?"⚠️ High margin — confirm with sales":"";
  return{suggested,adjustments:adj,risk};
};

export const buildSpecFromRow=(row,constEntry,prof)=>{
  if(!constEntry)return null;
  const isPartType=row.itemType==="Plate"||row.itemType==="Part-L"||row.itemType==="Part-W";
  return{
    client:prof.client||"",product:row.product||"",material_code:row.matCode||"",
    sector:prof.sector||"",L:row.L||"",W:row.W||"",H:row.H||"",dimType:"ID",
    // boxType priority: 1) row.boxType (user-set in grid — the authoritative override,
    // e.g. a Solar-Panel Plate manually set to "Board" for 10mm trim),
    // 2) isPartType default → "PP" (0mm trim) for all Plate/Part rows,
    // 3) construction library boxType for Box rows, 4) RSC fallback.
    boxType:row.boxType||(isPartType?"PP":(constEntry.boxType||"RSC")),
    ply:constEntry.ply||5,ups:row.ups||1,
    // Row-owned descriptive SKU metadata. Preserve 0 colours distinctly from blank;
    // neither field participates in calculation until an approved mechanism consumes it.
    printing_technology:row.printing_technology??"",
    number_of_colours:row.number_of_colours??"",
    flute_F1:constEntry.flute_F1||"B",flute_F2:constEntry.flute_F2||"A",
    layers:constEntry.layers||{TOP:{code:"",gsm:""},F1:{code:"",gsm:""},L1:{code:"",gsm:""},F2:{code:"",gsm:""},L2:{code:"",gsm:""}},
    board_gsm:constEntry.board_gsm||row.board_gsm||"",
    spec_bs:constEntry.spec_bs||row.spec_bs||"",
    spec_bct:row.spec_bct||constEntry.spec_bct||"",
    spec_ect:row.spec_ect||constEntry.spec_ect||"",
    plant:prof.plant||"",delivery:prof.delivery||"",
    waste:constEntry.waste??prof.waste??5,
    convRate:constEntry.convRate??prof.convRate??7,
    wastePP:constEntry.wastePP??prof.wastePP??5,
    convRatePP:constEntry.convRatePP??prof.convRatePP??12.5,
    freightOverride:prof.freightOverride||"",
    margin:(row.marginOverride!==""&&row.marginOverride!=null)?+row.marginOverride
          :isPartType?(prof.marginPP??prof.margin??8)  // PP rows use marginPP from profile
          :(prof.margin??8),                            // Box rows use margin
    interest:prof.interest??0.5,
    printing:0,packing:0,stitching:0,handling:0,coating:0,moqCharge:0,other:0,unloading:0,
    salesMOQ:row.salesMOQ||"",volume:row.volume||"",
    rowType:row.itemType||"Box",setCode:row.setCode||"",qtyPerSet:row.nosPerSet||1,
    // D-1 RETURN LEG: was hardcoded skuType:"", which blanked the Glass SKU on
    // every Deep Dive. The loss was asymmetric and so went unnoticed: pushing
    // back falls back to row.glassSKUType and survives, but sending as a NEW row
    // has no row to fall back on and wrote blank. Costing named it skuType, the
    // grid names it glassSKUType — same value, D-1's mapping.
    flutingBCF:0.10,skuType:row.glassSKUType||"",
    paymentDisc:prof.paymentDisc||"30",
    customerType:prof.customerType||"existing",
    priceContext:prof.priceContext||"unknown",
    isRepeat:false,reqBoxWt:row.reqBoxWt||"",
  };
};
