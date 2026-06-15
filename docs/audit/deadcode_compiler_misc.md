# Cleanliness Audit — compiler / net / init / etc / top-level misc

Read-only audit. Scope: `adder/compiler/` (the Adder compiler, both the Python
implementation and the self-hosted `*.ad` rewrite), net-related files explicitly
called out in the brief (`drivers/net/sock_compat.ad` rename check),
`init/`, top-level/root `.ad` files, `etc/` config + `services.d/` + `rc.d/`, and
any `*.ad` under directories outside
`{sys/src/9/port, kernel, arch, mm, drivers, fs, linux_abi, user, lib, scripts, tests}`.

Excluded from greps: `.claude/worktrees/` (stale per-agent worktree copies — these
carry pre-rename duplicates that do NOT exist in the live tree) and `build/`.

Tags: **SAFE-REMOVE** = zero live references, no runtime dynamic-dispatch risk.
**NEEDS-REVIEW** = looks dead/redundant but is parked-by-intent, runtime-discovered,
or a backend gap rather than dead code.

---

## 1. DEAD CODE

- [SAFE-REMOVE] adder/compiler/optimizer.py (entire 966-line module) — a standalone
  ARM-assembly peephole/constant-fold/dead-code/inline optimizer (`ARMOptimizer`,
  `optimize_assembly`, `peephole_pass`, `dead_code_pass`, `constant_fold_pass`,
  `fold_expr`, `inline_function`, module-level `optimize_assembly`/`peephole`/
  `dead_code` wrappers). — Evidence: tree-wide grep for `optimizer`/`ARMOptimizer`/
  `optimize_assembly` across all `*.py` returns ZERO importers; the only hits are
  self-references inside optimizer.py (lines 933-934, 949-950, 965-966). The real
  ARM backend is `codegen_arm64.py`, which does not import this module. — Recommend
  REMOVE the whole file; it is an orphaned, never-wired optimization pass.

- [NEEDS-REVIEW] adder/compiler/optimizer.py:664 `ARMOptimizer.inline_function` —
  defined but never called; the live inline path inside the (already-dead) module is
  `_inline_function_calls` (line 722, called at 626). — Subsumed by the whole-module
  SAFE-REMOVE above; listed for completeness.

- [NEEDS-REVIEW] init/main.ad:3771 `fat_write_smoke_test()` — call site is
  commented-out and replaced by `printk0("fat: write smoke PARKED ...")` at 3772.
  The symbol is still imported (main.ad:557) and run by the per-class smoke harnesses
  (tests/*_smoke.ad:534). — Evidence: explicit PARK note at main.ad:3747-3771
  ("HEARTBEAT REGRESSION (PARKED 2026-06-14)") with a documented root-cause theory
  (brd/.rodata RW page-table layout after a kernel-image size shift) and an intent to
  un-park once the brd page-table layer is fixed. — Recommend KEEP (intentional,
  documented, reversible); do NOT delete the import or the test body. Matches the
  brief's fat_write_smoke_test guidance exactly.

---

## 2. REDUNDANT MECHANISMS

No genuine duplicate mechanisms found in init/etc. Specifically checked and CLEARED:

- etc/rc.d/rc.5 vs etc/services.d/hamuid.svc — NOT redundant. rc.5's header documents
  that the old imperative `spawn guishell { hamUId daemon }` was REMOVED in favor of
  the declarative hamuid.svc; rc.5 now only sources an operator hook + a detached
  visual-regression gate. Single source of truth confirmed.

- etc/rc.boot.full hamUI bring-up — NOT redundant. rc.boot.full only calls `init 5`
  (declarative runlevel entry) + `svc start sshd`; no imperative DE spawn duplicating
  services.d. (rc.boot.full:85-110.)

- nudge / `/dev/mouse` mouse injection — the brief's template duplicate does NOT exist
  here. The `nudge`/`nudge_report` ctl verbs (sys/src/9/port/devwsys.ad:132-133,
  2377-2385; used by rc.d/rc.5 + scripts/test_de_cursor_nudge.sh) inject INTO the same
  auxmouse ring that `/dev/mouse` reads (`mouse_rx_push_abs`) — they are one path, not
  two. (devwsys.ad is out of this agent's scope; noted only to close the brief's lead.)

- sshd autostart — NOT redundant. Exactly one definition: legacy `/etc/svc/sshd.hamsh`
  (`ns: linux`, needs the Linux namespace), started by `svc start sshd` in
  rc.boot.full. There is NO competing `etc/services.d/sshd.svc`.

- drivers/net/sock_compat.ad (F10-11 rename of socket.ad) — NO stale pre-rename
  duplicate in the live tree. `find -name socket.ad` hits ONLY `.claude/worktrees/*`
  (other agents' frozen copies), never `drivers/net/socket.ad` in main. sock_compat.ad
  is live: imported by drivers/net/ipv6.ad:38 and fs/procfs.ad:80. Rename is clean.
  (Distinct from linux_abi/api_socket.ad, the Linux-ABI shim — intentional two-layer
  split, not a duplicate.)

---

## 3. ORPHAN FILES

None found in scope.

- etc/services.d/*.svc (hamde, hamuid, hamnotify-welcome, hellosvc) — discovered at
  runtime by directory scan (`svc_load_all_defs()` → `_ext_listdir("/etc/services.d")`,
  user/hamsh.ad:6476-6525), NOT by literal cross-reference. Low/zero grep counts are
  EXPECTED and do NOT mean orphan. All four are live. KEEP.

- etc/install_multipkg.hamsh, etc/install.hamsh, etc/install_nvme.hamsh — distinct live
  installer fixtures, each driven by its own test (test_install_multipkg.sh, test_hpm.sh
  / installer_full, test_installer_nvme*.sh). Not orphans.

- etc/rc.de-hostowner, etc/rc.de-user — live; both referenced by user/hamsh.ad (DE
  terminal spawn rewrite, ~3970-3981, 8557-8558), user/hamUId.ad (12976, 14783-14794),
  devwsys.ad:291. KEEP.

- etc/svc/sshd.hamsh — live legacy svc path (see §2). KEEP.

- init/p9_smoke.ad — live; called at boot (init/main.ad:5542). init/main.elf,
  main.elf.iso, main.s are gitignored BUILD ARTIFACTS, not tracked orphans.

- adder/compiler self-hosted `.ad` tree (adder_cc_driver.ad, codegen_ac_driver.ad,
  fused_driver_main.ad, hamnix_ac_smoke_input.ad, *_selftest.ad, codegen.ad, lexer.ad,
  parser.ad, elf_emit.ad) — ALL referenced by real build/test scripts
  (scripts/build_user.sh, concat_compiler_source.py, test_hamnix_ac.sh, etc.). Not
  orphans.

- examples/hpm-source/.../greet.ad — live source-package fixture (test_hpm_rollback.sh,
  build_source_pkg_fixture.py, make_initramfs.sh).

- etc standard config (host.conf, networks, protocols, hpm/channels, issue.net,
  lsb-release, debian_version, etc.) — read by NAME at runtime by libc-shape lookups /
  banners; canonical Unix files, not orphans.

---

## 4. DUPLICATE / COPY-PASTE

- [NEEDS-REVIEW] adder/compiler/codegen_x86.py vs adder/compiler/codegen_arm64.py —
  ~36 identically-named methods (`get_type_size`, `get_expr_type`, `gen_expr`,
  `gen_stmt`, `gen_program`, `gen_function`, `gen_if`/`gen_while`/`gen_do_while`/
  `gen_for`, `gen_assignment`, `gen_binary`, `gen_unary`, `gen_call`, `gen_identifier`,
  `gen_index_load`/`gen_index_address`, +~20 more). Much of the AST-walking control flow
  (type sizing, expression dispatch, statement structure) is arch-independent and is
  copy-pasted between the two backends. — Recommend EXTRACT a shared
  `CodegenBase`/mixin for the arch-independent walk, leaving only the actual instruction
  emitters per backend. NEEDS-REVIEW: this is a refactor, not a delete, and the two
  files may have already-diverged subtle differences that must be diffed method-by-method
  before merging. Cross-checked by the compiler sub-audit.

---

## 5. BACKEND COMPLETENESS GAPS (not dead code — incompleteness; flagged for awareness)

The Python x86 codegen parses several AST node types the parser emits but has no codegen
handler for; they fall through to "expression not yet supported". These are MISSING
features, not dead code, and removing the parser support would be wrong. Listed so they
are not mistaken for dead AST handlers:

- [NEEDS-REVIEW] codegen_x86.py — `SliceExpr` (parser.py:462,472), `ListComprehension`
  (parser.py:633), `LambdaExpr` (parser.py:717), `FStringLiteral` (parser.py:540),
  `FloatLiteral` (imported at codegen_x86.py:45, raises unsupported at ~2739; arm64
  raises at ~858). — These are language features not yet lowered for x86. KEEP; track as
  backend work, not cleanup.

---

## Summary

- SAFE-REMOVE: **1** (the whole `adder/compiler/optimizer.py` module; the dead
  `inline_function` method is inside it).
- NEEDS-REVIEW: dual codegen duplication (1 refactor), parked fat_write_smoke_test (1),
  five x86 backend completeness gaps.
- Redundant mechanisms / orphan files: **none** confirmed in init/etc (several strong
  leads from the brief checked and explicitly cleared — sock_compat rename clean, no
  sshd .svc/.hamsh dup, no imperative DE spawn duplicating services.d).
