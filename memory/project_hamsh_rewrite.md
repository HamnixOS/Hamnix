---
name: project-hamsh-rewrite
description: "hamsh clean-sheet rewrite LANDED 2026-05-22. Single Python-flavored language, own evaluator. Init/rc-in-hamsh shipped (341af32) — hamsh is PID 1."
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

**Status 2026-05-22:** §18 stages 1–11 landed and matured. `/init` execs hamsh with `/etc/rc.boot`; hamsh is PID 1; boot namespace recipe + service launch are declarative hamsh rc. `user/init.S`/`init2.ad` deleted.

**Design** (spec at `docs/HAMSH_SPEC.md`, design-locked):
- Single Python-flavored language, C-style `{ }` blocks, own dynamic tree-walking evaluator. NO grammar/type/semantics shared with Adder.
- First-token deterministic dispatch (command vs assignment vs control). Not xonsh-style heuristics.
- Interpolation: `$name`, `${ expr }`, `` `{ } ``
- Python keywords: `def`, `try`/`except`, `if`/`elif`/`else`
- Typed values + list interpolation (no word-splitting)
- pipes/redirects/dup → `Chan` bound at `/fd/N`
- `/fd` (`#d`), `/env` (`#e`) devices
- `ns {}` COW `rfork(RFNAMEG)` scoped namespaces
- `enter`/`spawn` = namespaces-as-values
- `try`/`except` on errstr; no significant whitespace; no 9P marshalling on local pipes

**Pending direction (user 2026-05-22):**
- Interactive line editor (Left/Right/Delete/Home/End + Up/Down history) — approved HAMSH_SPEC amendment
- Linux runtime namespace as `ns {}` value; retire hard-coded `distrorun` in favor of `ns`/`bind`/`mount`/`enter` — see [[feedback-distro-namespace]]
- Document hamsh syntax; rename `hamnix-vmlinux` kernel image

## Related
[[project-plan9-pivot]], [[feedback-sweeping-agents]], [[feedback-distro-namespace]]
