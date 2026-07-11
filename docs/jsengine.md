# lib/jsengine.ad — the native JavaScript engine

A pure, `extern`-free ES5 / basic-ES6 **tree-walking interpreter** written in
Adder: lexer → recursive-descent parser → AST (flat node pools) → evaluator over
a lexical scope chain. It is the scripting spine for the native browser (a
future `document` host object binds through the dispatch seam) and a general OS
scripting engine.

Correct over fast — this is deliberately **not** a V8/JIT. It is a scoped,
winnable target: enough to run simple/interactive local page scripts and script
the OS.

## Dual-target (the whole point)

`lib/jsengine.ad` has **no** `extern def`, no syscalls, no sockets, no UI — like
`lib/htmlengine.ad`. That purity lets the SAME engine link into both Adder
targets:

| Target | Driver | Runs on | Speed |
|--------|--------|---------|-------|
| `x86_64-linux` | `user/js_host.ad` | the dev host Linux kernel | milliseconds, **no QEMU** |
| `x86_64-adder-user` | `user/js.ad` | inside Hamnix (native CPL-3) | needs a boot |

Iterate on the **host** driver (`scripts/test_jsengine_host.sh`, exact-output
assertions over a fixture suite); confirm on the **native** boot once
(`scripts/test_jsengine_native.sh`). Same recipe as
`docs/hamui_dual_target.md`.

```
# fast loop (no QEMU):
python3 -m compiler.adder compile --target=x86_64-linux user/js_host.ad -o build/host/js_host
build/host/js_host path/to/script.js

# native tool:
python3 -m compiler.adder compile --target=x86_64-adder-user user/js.ad -o build/user/js.elf
# inside Hamnix:  js script.js      (or `js` with no args -> built-in demo)
```

## Language coverage

**Works:** `var`/`let`/`const` (block scope; per-iteration `let` binding so
loop closures capture correctly); numbers (IEEE-754 `float64`), strings,
booleans, `null`, `undefined`; array & object literals; functions, closures,
recursion, named-function-expression self-reference, IIFEs; arithmetic /
logical (`&&`/`||` short-circuit) / bitwise (`& | ^ ~ << >> >>>`, int32
semantics) / comparison / ternary; string concat + coercion; `if/else`,
`while`, `do/while`, `for`, `for-in`, `break`/`continue`/`return`; `typeof`;
member access + method calls; implicit-global assignment.

**Builtins:** `console.log` (`error`/`warn`/`info` alias it); `Math.floor/ceil/
round/abs/sqrt/pow/min/max/trunc`, `Math.PI/E`; `parseInt` (radix + `0x`),
`parseFloat`, `isNaN`, `String`, `Number`, `Boolean`; `JSON.parse` /
`JSON.stringify` (nested objects/arrays, string escaping); String methods
`length`, `charAt`, `charCodeAt`, `indexOf`, `slice`, `substring`, `substr`,
`split`, `toUpperCase`, `toLowerCase`, `trim`, `repeat`, `toString`; Array
methods `push`, `pop`, `shift`, `length`, `join`, `indexOf`, `map`, `filter`,
`reduce`, `forEach`, `slice`, `reverse`; `Object.keys`; `Array.isArray`;
`NaN`/`Infinity`/`undefined` globals.

**Not covered (intentional, out of scope for now):** prototypes / classes /
`this`-bound method chains beyond direct calls; `instanceof` (returns `false`);
generators / `async`/`await` / Promises; regex; getters/setters; template
literals; destructuring / spread / default params / arrow functions (the `=>`
token lexes but arrow bodies are not parsed); `try`/`catch` (a runtime error
sets an error flag and aborts eval with a message); tagged Unicode beyond ASCII
(`\uXXXX` in JSON keeps the low byte). Numbers print with a trimmed
fixed-precision `dtoa`, not the shortest-round-trip algorithm (e.g.
`0.1 + 0.2` prints `0.3`).

## Memory

Bump-allocated over fixed BSS pools (no free) — the brief permits a bump
allocator with generous limits; the native ELF's ~15 MB BSS is in line with
other native tools (`hpm` ≈ 19 MB, `codegen_ac_driver` ≈ 14 MB). `js_init()`
resets every pool, so an embedder can run many programs. Deep/long scripts on
the **native** target are bounded by the 4 KiB native user stack (the evaluator
recurses per AST/JS-call depth); the **host** target has a normal 8 MiB stack
and runs the full suite (incl. recursive `fib(20)`). The native `js` built-in
demo is deliberately shallow.

## Embedder API (what the browser track calls)

```adder
from lib.jsengine import js_init, js_eval, js_out_len, js_error, js_error_msg

def js_init()                                    # reset pools; install builtins
def js_eval(src: Ptr[uint8], slen: uint64) -> Ptr[uint8]  # run; ptr to NUL-term console output
def js_out_len() -> uint64                       # length of that output
def js_error() -> int32                          # nonzero on parse/runtime error
def js_error_msg() -> Ptr[uint8]                 # the error message
```

### Host-object binding seam (for a future `document`)

Register native functions/objects BEFORE `js_eval`, then route their calls
through one dispatch function. Host natives MUST use ids `>= js_host_base()`
(1000).

```adder
# value constructors (return int32 value handles)
def js_number(x: float64) -> int32
def js_new_string(p: Ptr[uint8], n: uint64) -> int32
def js_new_object_v() -> int32
def js_new_array_v() -> int32
def js_new_native_fn(native_id: int32) -> int32

# object / global wiring
def js_set_prop(objv: int32, name: Ptr[uint8], n: uint64, val: int32)
def js_get_prop(objv: int32, name: Ptr[uint8], n: uint64) -> int32
def js_array_push(arrv: int32, val: int32)
def js_global_set(name: Ptr[uint8], n: uint64, val: int32)

# value inspection (inside your dispatcher)
def js_type_of(val: int32) -> int32              # TAG_UNDEF..TAG_OBJ
def js_to_number(val: int32) -> float64
def js_to_bool(val: int32) -> int32
def js_to_display(val: int32) -> Ptr[uint8]      # NUL-term string form (shared scratch)
def js_is_array(val: int32) -> int32
def js_array_len(val: int32) -> int32
def js_array_get(val: int32, i: int32) -> int32

# the dispatch hook
def js_set_host_dispatch(fn: Fn[int32, int32])   # fn(native_id) -> value handle
def js_arg_count() -> int32                      # args available to the current host call
def js_arg(i: int32) -> int32
def js_host_base() -> int32                      # 1000
```

**Example — bind `document.title` getter:**

```adder
DOC_TITLE: int32 = 1000                          # >= js_host_base()

def my_dispatch(native_id: int32) -> int32:
    if native_id == DOC_TITLE:
        return js_new_string(cast[Ptr[uint8]]("Hello"), 5)
    return js_undefined()

# setup, once, before js_eval:
js_init()
js_set_host_dispatch(my_dispatch)
doc: int32 = js_new_object_v()
js_set_prop(doc, cast[Ptr[uint8]]("getTitle"), 8, js_new_native_fn(DOC_TITLE))
js_global_set(cast[Ptr[uint8]]("document"), 8, doc)
js_eval(src, len)                                # page script can call document.getTitle()
```

The actual DOM wiring is left to the browser/CSS track; the engine exposes the
seam and stays DOM-agnostic.

## Gates

- `scripts/test_jsengine_host.sh` — Tier-1, no QEMU. Compiles the host driver
  (and the native tool as a no-regress arm) and asserts the **exact**
  `console.log` output of 7 fixtures in `tests/fixtures/js/`
  (`arithmetic`, `closures`, `arrays_objects`, `json`, `strings`,
  `controlflow`, `fib`) plus a spine IIFE-fib check.
- `scripts/test_jsengine_native.sh` — boots Hamnix and runs `js` in-guest,
  asserting the exact `JS-OK hamnix sum=15 sq=1,4,9,16,25` demo line (values
  not present in the typed command, so no console-leak false-green). Kills only
  its own `$QEMU_PID`.

## Files

| File | Role |
|------|------|
| `lib/jsengine.ad` | the PURE engine (lexer + parser + evaluator + builtins + API) |
| `user/js_host.ad` | host driver (`x86_64-linux`): read a `.js`, eval, print |
| `user/js.ad` | native tool (`x86_64-adder-user`): `js FILE.js` or built-in demo |
| `tests/fixtures/js/*.js` + `expected/*.txt` | host gate oracles |
| `scripts/test_jsengine_host.sh` | fast host gate |
| `scripts/test_jsengine_native.sh` | native boot gate |
