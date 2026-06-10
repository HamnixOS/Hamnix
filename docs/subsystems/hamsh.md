# hamsh — the Shell & PID 1

> **Source of truth:** `user/hamsh.ad`, `etc/rc.boot`, `etc/rc.boot.full`
> **Last verified against source:** 2026-06-10
> **Full language reference:** [../HAMSH_SPEC.md](../HAMSH_SPEC.md)

## Purpose

`hamsh` is the Hamnix shell **and PID 1**: the kernel `/init` shim execs
`/bin/hamsh /etc/rc.boot`. It is one of the two sanctioned app languages
(the other is Adder). hamsh is a self-contained Python-flavored language
with its **own** small dynamically-typed tree-walking evaluator — it
shares no grammar, type system, or evaluator with the Adder compiler, and
there is no compile step.

## Key files

| Path | Role |
|--|--|
| `user/hamsh.ad` | the whole shell: lexer, parser, evaluator, builtins, line editor, job control, service supervisor (~8200 lines) |
| `etc/rc.boot` | the boot script (plain hamsh): namespace recipe + service launches + the `linux = ns clean { ... }` template |
| `etc/rc.boot.full` | the full boot variant |

## Architecture & data structures

Per the `user/hamsh.ad` header, the design reduces to **a named channel
in a scoped namespace** — stdio, pipes, redirects and `dup` are all "bind
a Chan at an `/fd/N` name". The implementation uses module-scope arenas
(no malloc in Hamnix userland):

- **lexer** — `tok_*` arrays: a flat token stream for one line.
- **parser** — `nd_*` arrays: a recursive-descent AST node arena.
- **evaluator** — `val_*` arrays: a dynamically-typed value heap + a
  variable-binding scope stack.

Statement dispatch is deterministic from the first token of a top-level
line (HAMSH_SPEC §2): control construct (keyword: `if while for def return
break continue try ns enter spawn`), assignment (`IDENT = ...`), or
command (bare words are literal strings).

Shell features (verify in `user/hamsh.ad` / [../HAMSH_SPEC.md](../HAMSH_SPEC.md)):
line editor + Tab completion + history; builtins honor `>`/`>>`/`<`/`2>`
redirects; **job control** (`&`, `jobs`/`fg`/`bg`, Ctrl-Z → SIGTSTP/
SIGCONT); an in-init **service supervisor** (`svc start/status/restart`,
restart-on-crash, logs at `/var/log/svc/<name>.log`); native **runlevels**;
and `ns` / `enter` constructs that build and enter namespaces (the
mechanism behind `enter linux { ... }`).

## Entry points

`user/hamsh.ad` has a single `main`. Internally the pipeline is
lex → parse → eval over the arena arrays above; the `ns`/`enter`/`spawn`
constructs call the native Layer-1 `rfork`/`bind`/`mount` syscalls (see
[plan9-namespace.md](plan9-namespace.md)).

## Invariants & gotchas

- **hamsh is not Adder.** Don't conflate the two grammars/evaluators.
- **No malloc in userland** — everything is module-scope arenas; growth is
  bounded by those arena sizes.
- It is PID 1: a crash in `rc.boot` evaluation is a boot failure. The
  service supervisor's restart-on-crash covers spawned services, not the
  shell itself.
- The hamsh heartbeat / interactivity has silently regressed before across
  many commits because nothing tested it — load-bearing behavior here
  needs a CI grep/serial test (project memory).
- Boot behavior is edited in `/etc/rc.boot` (plain hamsh) — no kernel
  rebuild needed to change the namespace recipe or service set.

## Related docs

- [../HAMSH_SPEC.md](../HAMSH_SPEC.md) — the complete language + shell reference.
- [plan9-namespace.md](plan9-namespace.md) — the `rfork`/`bind`/`mount` it drives.
- [userland-de.md](userland-de.md) — the binaries it launches.
- [../distro-namespaces.md](../distro-namespaces.md) — what `enter linux { ... }` builds.
