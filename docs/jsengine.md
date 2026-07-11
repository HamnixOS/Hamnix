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
booleans, `null`, `undefined`; array & object literals (incl. `{x}` shorthand);
functions, closures, recursion, named-function-expression self-reference, IIFEs;
arithmetic / logical (`&&`/`||` short-circuit) / bitwise (`& | ^ ~ << >> >>>`,
int32 semantics) / comparison / ternary; string concat + coercion; `if/else`,
`while`, `do/while`, `for`, `for-in`, `break`/`continue`/`return`; `typeof`;
member access + method calls; implicit-global assignment.

**ES6+ (added this pass, host-verified):**
- **Arrow functions** — `x => x+1`, `(a,b) => {…}`, concise expression bodies,
  and **lexical `this`** capture (`xs.map(x => x + this.base)` works).
- **Default & rest params** — `f(a, b = 10)`, `f(first, ...rest)`.
- **Template literals** — `` `hi ${name}` ``, nested templates, arbitrary
  interpolated expressions, escapes, multiline.
- **`try`/`catch`/`finally` + `throw`** — throw any value; `finally` runs on
  normal / `return` / exception paths and can override the pending completion.
  `Error`/`TypeError`/`RangeError`/`SyntaxError`/`ReferenceError` objects
  (`name`+`message`, rendered `"Name: message"`). Common runtime faults (prop
  access on null/undefined, calling a non-function, `const` reassignment) now
  throw **catchable** exceptions.
- **Classes** — `constructor`, methods, `static` methods, class expressions,
  `extends`, `super(...)` and `super.method(...)`, multi-level super chains, a
  real prototype chain, and implicit derived constructors that forward args.
- **`instanceof`** — walks the prototype chain (user classes and Errors).
- **Spread / rest** — `[...a]`, `f(...args)`, `{...o}` (array/string/object).
- **Destructuring** in `var`/`let`/`const` — array patterns (holes, defaults,
  `...rest`), object patterns (shorthand, `{a: b}` rename, defaults, `...rest`),
  and nested patterns.
- **Regular expressions** — regex literals `/pat/flags` (with correct
  `/`-vs-divide disambiguation) and the `RegExp(src, flags)` constructor. The
  matcher is a **backtracking bytecode VM** (correct over fast; supports
  backreferences that an NFA simulation cannot): literals, `.`, char classes
  `[a-z]`/`[^…]`, anchors `^ $`, quantifiers `* + ? {n} {n,} {n,m}` (greedy +
  lazy `?`), capturing + non-capturing `(?:…)` groups, alternation `|`,
  backreferences `\1`..`\9`, escapes `\d \w \s \b` and negations `\D \W \S \B`,
  `\xHH`/`\uHHHH`/control escapes. Flags `g` (global + `lastIndex`), `i`
  (ignore-case), `m` (multiline `^`/`$`). API: `re.test`, `re.exec` (capture
  groups + `.index` + `.input`, `lastIndex` for `/g`), and String `match`,
  `matchAll`, `replace` (`$1`/`$&`/`$$`/`` $` ``/`$'` and a replacer **function**),
  `replaceAll`, `split` (splices captured groups), `search`. Regexes render as
  `/src/flags`. Verified byte-for-byte against Node 20 in `tests/fixtures/js/regex.js`.

**Builtins:** `console.log` (`error`/`warn`/`info` alias it); `Math.floor/ceil/
round/abs/sqrt/pow/min/max/trunc`, `Math.PI/E`; `parseInt` (radix + `0x`),
`parseFloat`, `isNaN`, `String`, `Number`, `Boolean`; `JSON.parse` /
`JSON.stringify` (nested objects/arrays, string escaping); String methods
`length`, `charAt`, `charCodeAt`, `indexOf`, `slice`, `substring`, `substr`,
`split`, `toUpperCase`, `toLowerCase`, `trim`, `repeat`, `toString`, `match`,
`matchAll`, `replace`, `replaceAll`, `search`; Array
methods `push`, `pop`, `shift`, `length`, `join`, `indexOf`, `map`, `filter`,
`reduce`, `forEach`, `slice`, `reverse`; `Object.keys/assign/values`;
`Array.isArray/of`, `Array(...)`; the `Error` constructor family;
`NaN`/`Infinity`/`undefined` globals.

**Not covered (intentional, out of scope for now):** regex lookahead
`(?=…)`/`(?!…)`, lookbehind, named groups `(?<name>…)`, the sticky `y` and
dotAll `s` flags, and Unicode-property classes (the engine is byte-oriented) —
deferred as they would balloon the diff; generators / `async`/`await` / Promises;
getters/setters; computed method/property names; destructuring in function
parameters and in plain assignment (only declarations); `arguments` object;
tagged Unicode beyond ASCII (`\uXXXX` in JSON keeps the low byte). Numbers print
with a trimmed fixed-precision `dtoa`, not the shortest-round-trip algorithm
(e.g. `0.1 + 0.2` prints `0.3`).

## Memory

Bump-allocated over fixed BSS pools (no free) — the brief permits a bump
allocator with generous limits; the native ELF's ~15 MB BSS is in line with
other native tools (`hpm` ≈ 19 MB, `codegen_ac_driver` ≈ 14 MB). `js_init()`
resets every pool, so an embedder can run many programs. Deep/long scripts on
the **native** target are bounded by the 4 KiB native user stack (the evaluator
recurses per AST/JS-call depth); the **host** target has a normal 8 MiB stack
and runs the full suite (incl. recursive `fib(20)`). The native `js` built-in
demo is deliberately shallow.

## Native blocker (kernel FPU/SSE context-switch save/restore)

The engine is fully proven QEMU-free on the **host** target. The **native**
tool (`user/js.ad`) compiles, loads, and runs — but its float64 results are
**corrupted** today, and the cause is in the kernel, not the engine:

- JS numbers are IEEE-754 `float64`, so evaluating *any* script executes SSE
  (`movsd`/`mulsd`/`addsd`/`cvttsd2si`, `.rodata` FP constant pool). The
  generated assembly is byte-identical to the working host target.
- **Hamnix does not FXSAVE/XSAVE the FPU/SSE (xmm) register file across context
  switches** (`arch/x86/kernel/cpuregs_asm.S:110` — *"Hamnix does not
  FXSAVE/XSAVE the FPU/vector file across context switches today (SSE state
  already isn't preserved)"*). Until now no native userspace used float64, so
  nothing exposed it; the JS engine is the **first** native float64 consumer.
- Symptom (diagnosed 2026-07-10, `-smp 1`, quiet BSP): the tool prints an early
  `JS-BOOT` marker (exec + integer paths fine), but a `2.0*3.0+1.0` probe
  returns `1` instead of `7` — xmm state clobbered by preemption between the FP
  ops.

**The fix is a kernel change (out of scope for this engine, high-risk to do
blind):** add per-task FPU/SSE context-switch save/restore — an `fxsave`/
`fxrstor` (or `xsave`/`xrstor`) of a per-task 512-byte area in the switch path
(`arch/x86/kernel/sched_asm.S`), plus xmm-clobber discipline on the IRQ/syscall
entry paths. A **secondary** latent gap surfaced too: APs arm `CR4.OSXSAVE`+
`XCR0` (for VEX/AVX) but never set `CR4.OSFXSR`/`OSXMMEXCPT` (bit 9/10) that
*legacy* SSE needs (`arch/x86/kernel/smp.ad` step 2d; the BSP sets them in
`arch/x86/boot/header.S`), so once FPU save/restore lands, legacy-SSE float64
user tasks scheduled onto an AP under `-smp>=2` would `#UD` until the APs also
set OSFXSR/OSXMMEXCPT.

`scripts/test_jsengine_native.sh` is written and correct; it is deliberately
**not** wired into `ci_battery_manifest.txt` (a gate that cannot pass is a
false-red). It goes live unchanged once the kernel gains FPU context switching.

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
  `console.log` output of 12 fixtures in `tests/fixtures/js/`
  (`arithmetic`, `closures`, `arrays_objects`, `json`, `strings`,
  `controlflow`, `fib`, `templates`, `arrows`, `exceptions`, `classes`,
  `spread_destructure`) plus a spine IIFE-fib check.
- `scripts/test_jsengine_native.sh` — boots Hamnix and runs `js` in-guest,
  asserting the exact `JS-OK hamnix sum=15 sq=1,4,9,16,25` demo line (values
  not present in the typed command, so no console-leak false-green). Kills only
  its own `$QEMU_PID`. **BLOCKED / not in CI** — see "Native blocker" above; it
  goes live once the kernel gains FPU/SSE context-switch save/restore.

## Files

| File | Role |
|------|------|
| `lib/jsengine.ad` | the PURE engine (lexer + parser + evaluator + builtins + API) |
| `user/js_host.ad` | host driver (`x86_64-linux`): read a `.js`, eval, print |
| `user/js.ad` | native tool (`x86_64-adder-user`): `js FILE.js` or built-in demo |
| `tests/fixtures/js/*.js` + `expected/*.txt` | host gate oracles |
| `scripts/test_jsengine_host.sh` | fast host gate |
| `scripts/test_jsengine_native.sh` | native boot gate |
