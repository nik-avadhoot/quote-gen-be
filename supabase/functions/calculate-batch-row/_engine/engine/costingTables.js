// Calculation tables consumed by the pure costing engine. Kept separate from
// the editable Rate Master so the trusted Batch engine cannot acquire paper
// price, discount, freight or supplier-credit authority by importing defaults.
export const TAKEUP={A:1.51,B:1.37,C:1.47,E:1.31};
export const TRIM={RSC:{3:[30,60],5:[35,75]},"Die-R":{3:[44,60],5:[60,85]},"Die-S":{3:[20,30],5:[20,30]},Board:{3:[10,10],5:[10,10]}};
export const DEFAULT_BOX_TRIM_DATA={
  RSC:     {d3:30,c3:60,d5:35,c5:75, deckleF:"(W+H)×Ups+Trim", cuttingF:"(L+W)×2+Trim"},
  "HRSC-R":{d3:30,c3:60,d5:35,c5:75, deckleF:"(W+H)×Ups+Trim", cuttingF:"(L+W)×2+Trim"},
  "HRSC-L":{d3:55,c3:75,d5:55,c5:75, deckleF:"(W+H)×Ups+Trim", cuttingF:"(L+W)×2+Trim"},
  "HRSC-O":{d3:15,c3:60,d5:15,c5:60, deckleF:"(W+H)×Ups+Trim", cuttingF:"(L+W)×2+Trim"},
  "Die-S": {d3:20,c3:30,d5:20,c5:30, deckleF:"(W+H)×Ups+Trim", cuttingF:"(L+W)×2+Trim"},
  "Die-R": {d3:44,c3:60,d5:60,c5:85, deckleF:"(W+H)×Ups+Trim", cuttingF:"(L+W)×2+Trim"},
  Board:   {d3:10,c3:10,d5:10,c5:10, deckleF:"L×Ups+Trim",     cuttingF:"W+Trim (flat piece)"},
  PP:      {d3:0, c3:0, d5:0, c5:0,  deckleF:"L×Ups (trim=0)", cuttingF:"W (trim=0)"},
  Custom:  {d3:0, c3:0, d5:0, c5:0,  deckleF:"User-defined",    cuttingF:"User-defined"},
};
