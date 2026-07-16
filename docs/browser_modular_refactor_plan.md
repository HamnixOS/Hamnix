# Browser engine → modular `lib/web/…` tree — execution blueprint

Refactor the two monoliths `lib/jsengine.ad` (9817 lines) + `lib/htmlengine.ad` (13143 lines) into a Gecko/WebKit-shaped tree so agents work disjoint modules in parallel toward full W3C conformance.

## Why it's safe (behavior-preserving)
Adder is a **single-compilation-unit** language: `merge_programs()` → `resolve_module_scopes()` merges ALL imported files into one `Program` and codegens together. **Splitting one file into ten produces byte-identical merged output.** Globals (`VarDecl`, incl. mutable `Array` BSS) export exactly like functions; `from lib.web.js.state import v_tag` makes `v_tag[h]` resolve to the shared BSS label. No separate-compile/link, no circular-import problem, no static-init-order fiasco. Failure modes are only: (a) a missed cross-file private ref → add the import; (b) a public-name collision → won't happen (names already unique). **Leading-underscore = private (mangled); an `import` promotes it public.**

## Invariant per step
After each step: `bash scripts/build_user.sh` rc=0 AND all ~40 host gates green (`scripts/test_hambrowse_*host.sh` + `test_jsengine_*host.sh`). Each step = pure move-symbols + add-imports; revert the single commit if red. Keep `lib/jsengine.ad` + `lib/htmlengine.ad` as thin **re-export shims** during transition so consumers (`user/hambrowse*.ad`, `user/js*.ad`, `browserwin.ad`, `htmlpage.ad`) don't change until cutover.

## Key facts
- **jsengine ⟂ htmlengine** at a clean 41-symbol seam: htmlengine references exactly 41 public `js_*` names and ZERO jsengine pools. → jsengine splits fully independently; the 41 `js_*` API names are the frozen seam.
- **jsengine: 0 private defs** (trivial). **htmlengine: 340 private helpers + 336 Array globals** (the mechanical cost = adding imports when a helper crosses a new boundary).
- **State-owner modules** (export raw pool globals, everyone imports): `js/state.ad` (v_*/sp_*/n_*/tk_*), `js/value.ad`, `layout/box.ad` (he_seg_*/bbox_*/bfill_*), `dom/node.ad` (dom_*), `dom/element.ad` (el_*), `web/state.ad` (src+geometry). Freeze their public names EARLY — they're a stable ABI; changes to them serialize all agents.

## Staged plan
- **Phase A — jsengine (independent, low-risk, FIRST):** A1 `js/consts.ad`; A2 `js/state.ad` (POOLS 383-707, before consumers); A3 `js/util.ad`,`js/value.ad`; A4 peel builtin leaves 1/commit (date,json,math,storage,fetch,timers,regexp,promise,string,array); A5 `lexer/parser/interp/setup.ad` (entangled core, one owner) — `lib/jsengine.ad` becomes a shim. Run the 9 `test_jsengine_*host.sh` intensively at A5.
- **Phase B — htmlengine state-owners first:** extract `layout/box.ad`, `dom/node.ad`, `dom/element.ad`, `web/state.ad` (globals + accessors only, no logic moves). De-risks everything downstream.
- **Phase C — htmlengine leaves (low-risk):** `html/entities.ad`, `css/values.ad`(colour), `css/selectors.ad`, `dom/events.ad`, `dom/canvas.ad`, `layout/paint_iface.ad`; then `css/{parser,properties,cascade}.ad`, `layout/{flex,grid,tables,lists,positioned}.ad`. flex/grid/position/domtree/dispflex gates fence these.
- **Phase D — entangled core (HIGH RISK, last, single owner):** `layout/{flow,text,replaced,engine}.ad`, `dom/{document,query,forms,serialize}.ad`, `html/{tokenizer,api}.ad`; then **`dom/bindings.ad`** (the 2500-line JS-DOM glue, 58 private helpers — the single highest-risk move; move whole, move last, dedicated domapi/dommut/domtree/innerhtml/events/qsel gate run). `lib/htmlengine.ad` becomes a shim.
- **Phase E — cutover:** repoint consumers at new paths; delete the two shims.

## Proposed tree
```
lib/web/{state.ad,
  js/{consts,state,util,value,lexer,parser,interp,setup,builtins/{string,array,object,math,json,regexp,promise,date,map_set,storage,fetch,timers}},
  html/{tokenizer,entities,api},
  css/{values,selectors,parser,properties,cascade},
  dom/{node,element,document,query,events,forms,canvas,bindings,serialize},
  layout/{box,flow,flex,grid,tables,lists,positioned,text,replaced,engine,paint_iface}}
```

## Post-split agent-ownership (the payoff — concurrent, never-same-file)
JS-builtins (`js/builtins/*`) · JS-core (`js/{lexer,parser,interp,value,setup}`) · CSS (`css/*`) · Layout-flex/grid (`layout/{flex,grid}`) · Layout-flow (`layout/{flow,text,positioned,tables,lists,replaced,engine}`) · DOM (`dom/{node,element,document,events,query,forms,canvas,serialize}`) · HTML (`html/*`) · JS-DOM binding (`dom/bindings.ad`). Interact only via `setup` registration + the public `js_*`/state-owner ABIs.

## Sequencing with the conformance campaign
Land round-1 conformance on the monoliths + merge (additive; a mechanical split absorbs it) → execute Phases A-E (gate-green each step) → fan out per-module W3C rounds against `docs/browser_w3c_conformance.md`.
