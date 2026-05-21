# hamsh — shell redesign spec

**Status:** design locked, ready to implement. Phase D (chan layer, `namec`,
`Mnt`/`mountrpc`, per-Pgrp namespaces, 9P over srvfd) is complete; this spec
builds directly on those primitives.

**Revised 2026-05-21:** hamsh is now a **single Python-flavored language** with
C-style `{ }` blocks — the separate Adder "expression mode" was dropped. See
§2 and §3.

**Thesis:** the shell is the linchpin that gives the whole system gravity toward
Plan 9. The kernel *has* the model; the shell is what makes that model the path
of least resistance. hamsh is the UI for Phase D.

This is a clean-sheet design derived from Hamnix's actual use cases. The
*syntax* is deliberately Python-flavored with C-style `{ }` blocks — familiar,
not novel — but the *semantics* are not inherited from bash/sh/rc, and the
shell is **not Adder**. Where a decision had options, the choice is made here —
implement the chosen one; do not re-litigate.

---

## 0. The one idea everything reduces to

**A named channel in a scoped namespace.** Stdio, pipes, redirects, dup, binds,
and mounts are all the *same* operation — *bind a `Chan` at a name in a `Pgrp`* —
wearing different syntax. Implementers should feel the VFS surface shrink, not
grow: one primitive, many skins. If a feature in this spec seems to need a new
mechanism, it's probably mis-built — check whether it's "a Chan at a name" first.

---

## 1. Use cases (the design driver — in priority order)

1. Interactive command invocation (the 90% case).
2. Pipelines.
3. Running unmodified Linux ELF binaries with exact argv/env.
4. **Namespace + 9P composition** — bind/mount/import/rfork; assembling a
   process's view of the world. *This is the differentiator no other shell
   serves; it gets the design's novelty budget.*
5. Init/rc scripting and automation.

Every rule below traces to one of these. Ergonomics for #1 and correctness for
#3 are hard constraints.

---

## 2. One language, deterministic statement dispatch

hamsh is **one language** — a clean-sheet shell with a **Python-flavored
syntax** (`def`, `if`/`elif`/`else`, `for … in`, `while`, `try`/`except`,
lists, dicts) using **C-style `{ }` blocks** instead of significant
indentation. It is **not Adder** — it shares no grammar, type system, or
evaluator with Adder. Values are **dynamically typed** and run through hamsh's
own small tree-walking evaluator (§3); there is no compile step and no separate
"expression mode."

A single grammar covers everything. What differs is the **kind of statement**,
decided **deterministically** from a top-level line's first token — never by a
heuristic:

1. a **control construct** if the first token is a statement-starting reserved
   keyword (`if while for def return break continue try ns enter spawn`);
2. else an **assignment** if the line matches
   `IDENT ( = | += | -= | … ) …` at the top level;
3. else a **command** — the first token is the command word, the rest are
   arguments, and **bare words are literal strings**.

This dispatch is the one load-bearing rule: it is what lets `ls -la /dev` run a
command with string arguments while `x = 8080` is an assignment — inside one
language. It must stay boring and predictable: **no xonsh-style auto-detection
of "is this line a subprocess or code."**

In a command statement, computed values reach the argument list only through
explicit **interpolation** — `$name` for a variable, `${ expr }` for an
expression, `` `{ … }`` for command substitution (§8). Everywhere else
(assignment right-hand sides, control-construct conditions, function bodies)
you are simply writing hamsh expressions in the one grammar.

`elif`, `else`, and `except` are reserved continuation keywords.

---

## 3. Values & variables

Variables hold **typed hamsh values**: string, int, bool, list, dict, and
**handles** (see §14). Values are **dynamically typed** and evaluated by
hamsh's own small tree-walking evaluator — no compile step, no shared
implementation with Adder. Not "everything is a string."

```
host  = "10.0.2.15"      # string
port  = 8080             # int
args  = ["-la", "/dev"]  # list
```

- Assignment: `name = expr`. Type is inferred. No `var`/`let` required.
- Interpolation in command position: `$name`.
- Expression interpolation in command position: `${ expr }`.
- **List interpolation rule (kills word-splitting):** when a list value
  interpolates into command position, **each element becomes exactly one
  argument.** No re-splitting, ever. `ls $args` → `ls` `-la` `/dev`. This makes
  the entire bash word-splitting bug class structurally impossible.

**Environment = the `/env` namespace (`#e` device).** Exported variables are
files under `/env`; children inherit them through the namespace, not through a
separate "environment" concept. `$PATH` reads `/env/PATH`. Exporting a shell
value writes its string form into `/env/NAME`.

> **Scoping across namespace boundaries** (`ns` / `enter` / `spawn`) follows one
> rule: **values cross, resolution is namespace-local.** This is the part most
> likely to surprise — read §13 before implementing those constructs.

---

## 4. Words, quoting, globbing

- A bare unquoted word in command position is a **literal string**.
- Quoting (`"…"`, `'…'`) is needed only for whitespace/metacharacters. Double
  quotes interpolate `$`/`${ }`; single quotes are literal.
- **Globbing is the ONLY implicit expansion.** An unquoted command-position word
  containing glob metacharacters (`* ? [ ]`) is expanded against the *current
  namespace*. Quoted words never glob. There is no implicit splitting, no
  implicit brace/tilde soup — globbing is the single exception, justified by
  interactive ergonomics (#1).

---

## 5. Blocks & control flow

**One uniform brace-delimited block, paste-robust, REPL-friendly.** No
significant indentation (it fights interactive use and paste). No per-construct
terminator zoo (`fi`/`done`/`esac` are banned). The parser knows a block is
incomplete until the closing `}`, which is what makes both paste and the
continuation prompt work.

```
if $x > 3 {
    echo big
} else {
    echo small
}

for f in $files {
    process $f
}

def deploy(target) {
    ...
}
```

Functions: `def name(params) { body }`. Functions run in the ambient namespace
(§9) unless wrapped in `ns { }` / `enter` / `spawn`.

`{ }` serves both blocks and dict literals; the two never collide because they
occur in different positions — a `{` opening a statement body (after a control
header, `def`, or `ns`/`enter`/`spawn`) is a block; a `{` in expression
position is a dict literal. The parser disambiguates by position, exactly as
every C-family language with map literals does.

---

## 6. Pipes are channels

A pipe is a `Chan`, not a special kernel byte-buffer. **Two payload modes, chosen
by the ends, not by syntax:**

```
ls | grep ad             # external → external: BYTE channel (mandatory; talks to ELF binaries)
ps | where cpu > 50      # native → native: VALUE channel (structured records flow)
ps | to json | curl …    # value → external: serialize at the boundary
cat f | lines | len      # external → value: bytes become a list of lines
```

- **Bytes are the default** (use case #3 dominates). Structured value streams are
  an opt-in overlay between shell-native producers/consumers and **degrade to
  their text rendering the instant a byte-only program is on either end.**
- Crossing the byte/value boundary is **explicit** via converters: `to json`,
  `from csv`, `lines`, etc. Do not auto-guess.
- **CRITICAL performance rule:** "pipes are 9P" means "pipes are *Chans*." 9P
  messages go on the wire **only across a mount boundary**. A local pipe MUST be
  direct Chan reads (the `devtab`-direct path), never `Tread`/`Rread` per block.
  If `cat big | grep` marshals 9P locally, it is mis-built. Reuse the exact
  `devtab`-vs-`mountrpc` split from Phase D.
- **Do NOT build a full nushell-style table engine.** Bytes-first; structure is a
  light overlay. Data-wrangling is not a top-5 use case.

---

## 7. Stdio as named channels; redirect & dup collapse into bind

A process's standard streams are **names in its namespace**: `/fd/0`, `/fd/1`,
`/fd/2` (the `#d` fd device, mounted at `/fd`). Pipe, redirect, and dup are all
**one operation — bind a Chan at an fd-name:**

```
a | b          # bind a's /fd/1 channel as b's /fd/0
cmd > file     # bind file's channel as cmd's /fd/1
cmd 2>&1       # bind /fd/1's channel also at /fd/2
```

There is no separate pipe mechanism, redirect mechanism, and dup mechanism —
there is one bind over channels.

**Linux-ABI mapping:** the shim must map Linux integer fds 0/1/2/N onto the
`/fd/N` named channels. This is Layer-2 translation work, consistent with the
"route the Linux ABI through the chan layer" item — real shim work, not free.

---

## 8. Command substitution

```
out   = `{ cat /etc/hostname }       # captures stdout as a string
files = `{ ls *.ad } | lines         # → list of lines via explicit converter
```

`` `{ … }`` runs a command and captures its stdout as a **string** by default;
use `lines` (or another converter) for structured forms. No implicit splitting.

---

## 9. The ambient namespace & running a command directly

There is no "no namespace" — every process has one. A bare command runs in the
shell's **ambient namespace**: the one the boot recipe assembled (device-letter
binds) plus any binds/mounts done at the prompt since. The prompt *is* the
outermost namespace.

**Share-vs-copy policy (decided):**

- **External commands get a copy-on-write private copy** of the ambient
  namespace. They can read everything the shell sees, but their own
  binds/mounts are private and evaporate on exit. A command can never corrupt
  your view.
- **Composition verbs are builtins that mutate the ambient namespace in-process**
  and persist: `bind`, `mount`, `unmount`, `import`, `cd`. So `import 10.0.2.2
  /net` at the prompt sticks and every later command sees it.
- **Escape hatch:** for the rare tool whose *job* is to set up a namespace, run
  it shared explicitly (`share some-setup-tool`). Safe by default, danger
  opt-in.

This makes the model uniform at every level: **prompt = outermost scope; `ns {}`
= nested scope; a bare command = "run in the current scope."**

---

## 10. Scoped namespaces: `ns { }`

`ns { }` opens a nested scope: snapshot the mount table, run the body, restore at
the closing brace. Desugars to: `rfork(RFNAMEG)` (COW copy of the current Pgrp) →
apply the body's binds/mounts → run the body → tear the scope down.

```
ns {
    bind '#c' /dev
    mount $logsrv /var/log
    deb /bin/true        # sees only this view
}                        # namespace dissolves here
```

By default `ns { }` **overlays** — it starts from a COW copy of the current
ambient namespace and layers the block's binds on top, so `/env`, `/dev`, and
the device binds survive (see §13). For a hermetic base use `ns clean { }`
(empty base; you bind everything yourself).

The COW snapshot must be cheap (it rides the per-Pgrp mount-table copy from
Phase D, ideally copy-on-write) so entering a scope is not expensive.

`ns` is **exclusively** the scope keyword. To *view* a namespace, read the file
(§14) — there is no `ns`-subcommand for listing.

---

## 11. Namespaces as first-class values: `enter` / `spawn`

A configured namespace is a capturable value (a template — configured but not
entered):

```
sandbox = ns {
    mount $distrofs /
    bind '#c' /dev
}
```

**`enter sandbox { body }` — synchronous.** Forks a child; the child does
`rfork(RFNAMEG)`, applies a fresh COW instance of `sandbox`, runs the body; the
shell **blocks** until the body finishes and **propagates its exit status**.
Subshell-like: in-memory variables defined before the block are *readable* inside
(copied at fork), but variables set inside do NOT leak back out. The view is
discarded at the brace. (Exactly what crosses: §13.)

```
enter sandbox { apt update } && echo done
```

**`spawn sandbox { body }` — asynchronous.** Same fork + rfork + apply, but the
shell does **not** wait — it returns a **handle immediately**. The namespace
instance lives exactly as long as the spawned process.

```
svc = spawn sandbox { httpd }
kill $svc        # signal later
wait $svc        # or block on it now
```

- Default: a backgrounded job that dies if the shell dies.
- `spawn detached sandbox { … }`: uses `rfork(RFNOWAIT)` (the sever-parent path
  on the process-model list) so the service outlives the shell — i.e. a daemon.
- **Your entire init / service-supervisor falls out of `spawn` + handles.** That
  is how rc is written in this shell.

`enter` vs `spawn` differ in exactly one thing: **whether the parent calls
`wait`.** Both are thin wrappers over the namespace-instantiation primitive.

**Base namespace:** both `enter` and `spawn` apply the captured value **onto an
overlay of the current ambient namespace by default** (so the environment, `/dev`,
PATH survive). Use the `clean` form (`enter clean …` / a `sandbox = ns clean {…}`
template) for a hermetic base. See §13.

---

## 12. View vs state (the rule that keeps §11 from being a footgun)

**The namespace is the *view*; durable state lives in the file servers behind
it.** `enter`/`spawn` instantiate a fresh, cheap COW copy of the *view* and
discard it. But `apt update` writes into distrofs's *backing store*, which
persists independently of any view. So: the view is ephemeral, the install is
permanent. Assemble a view once, enter it a hundred times — each entry is a clean
cheap snapshot while accumulated state lives safely in the server. (Requires a
persistent distrofs backing — on the FS roadmap.)

---

## 13. What crosses a namespace boundary (variable scoping)

A namespace boundary (`ns {}`, `enter`, `spawn`) is about **files / Chans /
mounts**, not about the shell's in-memory values. The governing principle, stated
once:

> **Values cross the boundary; resolution is namespace-local.**

The value itself always travels (it's data in process memory, copied at the fork
that opens the block). Whether the *thing the value refers to* is reachable
depends on the target namespace. That single rule resolves all three kinds of
"variable":

| value kind | readable inside the block | write propagates back out | usable in a *different* namespace |
|---|---|---|---|
| **data** — string / int / bool / list / dict | yes (fork copy) | no (subshell rule) | yes — needs no resolution |
| **path string** — a value that *names* a resource | yes | no | only if that path is bound in the target namespace |
| **live handle** — mount handle / process handle / open Chan | the value, yes; the resource, no | no | **no — error to use outside its owning namespace** |

So, concretely:

1. **Plain data just works.** `host = "10.0.2.15"; enter s { echo $host }` prints
   the host — `$host` was copied in at fork. The common case you'd worry about
   does not break. Writes don't flow back (it's a subshell), which is the same
   rule as `enter` not leaking variables.

2. **A path string crosses but may not resolve.** `p = "/var/log/out";
   enter s { cat $p }` — the *string* crosses fine, but `cat` only succeeds if
   `/var/log` is bound in `s`. Nothing about the variable broke; the resource may
   simply be absent from that view. That is the entire point of namespaces.

3. **A live handle is namespace-local and must NOT be passed across.** A handle
   from `remote = mount $srv /n/remote` is bound to the namespace that created it.
   `enter s { unmount remote }` is meaningless — `s` never had that mount. Using
   a handle outside its owning namespace **must be a loud error, not undefined
   behavior.** If you need to act on a resource inside another namespace,
   re-resolve it there *by name*, don't carry the live handle in.

**Base-namespace decision (what an entered/captured namespace applies onto):**

- **Default = overlay.** `ns {}` / `enter` / `spawn` start from a COW copy of the
  current ambient namespace and layer the block's (or captured value's) binds on
  top. Therefore `/env` (and so `$PATH` and your exported vars), `/dev`, and the
  device binds **all survive**. This is *why* your environment doesn't vanish
  inside a block, and it's the least-surprising default.
- **`clean` = hermetic.** `ns clean { }` (and the matching `enter clean` /
  `ns clean` template) starts from an empty base — only what the block binds.
  Now `/env`, `/dev`, and PATH are gone unless you bind them yourself. Opt-in
  isolation for a genuine clean room; you accept rebuilding the basics.

**Net:** ordinary variables don't break — in-memory data crosses via the fork
copy, and the environment survives via the overlay default. The one thing that
breaks, and *should* break loudly, is handing a live handle into a foreign
namespace.

---

## 14. Handles, labels, and introspection

**Unifying principle: every resource-creating construct returns a first-class
handle value.** `ns {}` → namespace value; `spawn` → process handle; `mount` →
mount handle.

```
remote = mount $srv /n/remote      # the mount is a value
unmount remote                     # refer by handle, not a fragile path
mount $srv /n/remote as remote     # optional inline-label sugar (no variable)
```

A handle is valid **only in the namespace that created it** (§13). Using one
outside its owning namespace is an error.

Labeling is **not** a separate subsystem — it's the handle pattern applied to
mounts. It becomes *necessary* once union mounts (MBEFORE/MAFTER) land: with
several servers stacked at one path, the path is no longer a unique handle, so a
stable name is required to `unmount` the right one or to ask "where did `/net`
actually come from."

**Introspection is free because everything is a file.** Your namespace is
readable at `/proc/self/ns` (and `/proc/<pid>/ns`), labels and all. There is no
special "list mounts" command — `cat /proc/self/ns`.

---

## 15. Composition verbs (builtins)

`bind`, `mount`, `unmount`, `import`, `cd`. These run **in-process** and mutate
the **ambient** namespace (§9). `import host /net` pulls a remote machine's 9P
tree into the current namespace.

Because a `Chan` does not care whether its server is local or remote, pipelines
and namespaces span machines with no syntax change:

```
ns {
    import 10.0.2.2 /net               # machine A's network stack
    mount $logsrv /var/log             # B's log server
    server </net/tcp/0 >/var/log/out   # input from A, output to B — fully scoped
}
```

That is the CPU-server idiom and the "useful in 2026, not archaic Unix" payoff,
expressed entirely in the shell.

---

## 16. Errors via errstr

Wire error handling to the kernel's existing Plan 9 **errstr** mechanism — do not
reinvent `$?` + `set -e`.

- `$errstr` is a native variable holding the last failure string.
- Every command yields an exit status **and** an errstr.
- Build structured `try { } except { }` on top of errstr.

```
try {
    mount $srv /n/remote
} except {
    echo "mount failed: $errstr"
}
```

---

## 17. Non-goals (do NOT build these)

- **No significant-whitespace blocks** in the interactive grammar.
- **No Adder.** hamsh shares no grammar, type system, or evaluator with Adder;
  it is its own small dynamically-typed, Python-flavored language.
- **No separate expression mode / no second language.** One grammar; the
  command-vs-assignment-vs-control distinction is statement dispatch (§2).
- **No heuristic command-vs-code detection** (the xonsh trap). Statement
  dispatch is the deterministic first-token rule of §2, nothing fuzzier.
- **No full structured-table/data-wrangling engine** (not nushell). Bytes-first.
- **No 9P marshalling on local pipes.** Local = direct Chan reads only.
- **No implicit word-splitting / brace / tilde expansion.** Globbing is the sole
  implicit expansion.
- **No per-construct block terminators** (`fi`/`done`/`esac`).
- **No passing a live handle across a namespace boundary.** A handle is valid
  only in its creating namespace (§13); cross-namespace use is an error.

---

## 18. Suggested build order + acceptance tests

Each stage ships with a test before moving on. All run in QEMU.

1. **Lexer/parser: statement dispatch.** Test: a corpus of lines classifies
   deterministically as command / assignment / control by the §2 first-token
   rule; `${ }` and `` `{ }`` nest correctly. No line is ambiguous.
2. **Typed values + list interpolation.** Test: `args = ["-la","/dev"]; echo
   $args` yields exactly two argv entries; a value containing spaces is one
   argument (no splitting).
3. **Brace blocks + control flow + `def`.** Test: multi-line `if`/`for`/`while`
   parse from paste and from the continuation prompt; mismatched braces error
   cleanly.
4. **Stdio-as-/fd + pipe/redirect/dup as bind.** Test: `a | b`, `> file`, `2>&1`
   all resolve to binds at `/fd/N`; **assert a local pipe does no `mountrpc`**
   (counter stays zero — same shape as the Phase D FD_*_MARK tripwire test).
5. **Ambient namespace + COW-for-externals.** Test: an external command's `bind`
   does NOT appear in the shell's `/proc/self/ns`; a builtin `bind` at the prompt
   DOES, and a subsequent command sees it.
6. **`ns { }` scope + overlay default.** Test: a bind inside the block is gone
   after the brace; nested `ns { ns { } }` inherits then narrows; `/env` is
   present under default `ns {}` and absent under `ns clean {}`.
7. **`enter` / `spawn` + handles.** Test: `enter s { false }` returns nonzero,
   blocks to completion, and leaks no variables; `svc = spawn s { sleep }; kill
   $svc` terminates it; view tears down on process exit.
8. **Boundary scoping (§13).** Test: `x = "hi"; enter s { echo $x }` prints `hi`
   (data crosses); a variable set inside `enter` is unset in the shell afterward
   (no write-back); a mount handle created in the ambient namespace, used inside
   `enter s { }`, raises the cross-namespace-handle error; `enter clean s { }`
   has no `/env` while default `enter s { }` does.
9. **View vs state.** Test: `enter s { touch /var/x }` against a persistent
   distrofs backing — `/var/x` is visible on the next `enter s { }`, while the
   *view's* transient binds are not.
10. **mount handles + introspection.** Test: `m = mount $srv /n/r; unmount m`
    removes the right mount under a union stack; `cat /proc/self/ns` shows the
    label.
11. **errstr / try-catch.** Test: a failing `mount` is caught and `$errstr`
    carries the kernel's message.

Critical path: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Stages 9–11 can follow once the
core lands.
