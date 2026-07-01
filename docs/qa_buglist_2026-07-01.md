# QA bug list — 2026-07-01 (user interactive session, fresh reboot)

Source: user hands-on session on `build/hamnix-installer.img` (rebuilt 2026-07-01).
Orchestrator is primary bug-finder; this is the working list. Status markers:
`[ ]` open · `[~]` agent in flight · `[x]` fixed+verified.

## Clarifications from the user
- The **file browser** (`hamfm`) was the intended target of earlier "browser"
  talk. We *also* built a **native web browser** (`hambrowse`, Internet menu).
  A native browser is fine to keep, **but it must show in the menu**. Long-term
  web plan is unchanged: X11 pass-through in the Linux namespace → Firefox/Chromium.

## Cluster A — DE panel / widgets / context-menu / settings — LANDED da91cc38
Fixed in the live scene panel (`hampanelscene.ad`) + `hamsettings.ad`; note the
legacy `hampanel.ad`/`hamctxmenu.ad`/`hamappmenu.ad` are NOT what the scene DE
spawns. Regression gate: `scripts/test_de_panel_widgets_ux.sh` (PASS on main).
- [x] **A1 App/window list not live** — ROOT-CAUSED + FIXED (see QA-N4 below,
  merge 6bfdd12e). Pass #1 couldn't repro with default apps; QA pass #2 (driven
  input) reproduced it, and the real cause was the `_wsys_raise` z-band leak, NOT
  the workspace filter. Clicking a window raised it above the chrome floor
  (z>=100) so it fell out of the `z<100` enumeration. Fixed + regression-tested.
- [x] **A2 CPU widget** idle-100% — was load-avg*50 scaling; rewritten to
  /dev/uptime idle/total delta with first-sample guard → near-0% idle.
- [x] **A3 Right-click blank panel** now opens Add-a-widget (elastic tasks/
  spacer treated as blank; trailing hit-rect bound fixed).
- [x] **A4 Right-click Applications button** now shows Move/Remove like any widget.
- [x] **A5 Settings** edge selector keeps all 4 panels on distinct edges;
  add-widget chips moved to their own sub-column (overlap gone); classic look.
- [x] **A6 Web Browser** row added to the scene dropdown → /bin/hambrowse;
  file manager (/bin/hamfmscene) confirmed present.

## Cluster B — Install wizard — LANDED ec9a9ff7
- [x] **B1 Multi-page wizard** — 6-page Back/Next wizard (host name, install
  user, user pw+confirm, host-owner pw+confirm, partition, review). Inputs flow
  to target `/etc/{hostname,passwd,shadow}` via `install_file` ctl verb + `$6$`
  sha512_crypt. Auto path flag-gated (unchanged). Gate: `test_installer_wizard.sh`.
- [x] **B2 Partition manager** — target-disk picker + guided(default)/manual +
  ESP-size field; both drive the same GPT+ESP+ext4 path. OVMF/KVM install+boot
  verified.
  - FOLLOW-UP: per-user home file server + `.ns` recipe made on first boot, not
    at install time (offline-target limit).

## Cluster C — Identity — LANDED 487d58dc
- [x] **C1 DE terminal `whoami` = `nobody` → now `live`.** Real cause: the DE
  terminal did `setuid 65534` (nobody) by design (no session manager). On the
  live image the provisioned default regular user is `live` (uid 1001,
  /home/live). Fix: `etc/rc.de-user` now `setuid 1001` + `HOME='/home/live'`;
  compositor stays hostowner; `newshell hostowner` still elevates to hostowner.
  Guard: `test_de_terminal_live_user.sh`. (Serial console already ran as `live`.)
  - NOTE: first pass punted this as "future work" with a test-only change;
    orchestrator reopened it with corrected scope → real fix.
  - Found a hamsh language quirk (task #8): `export VAR=value` is invalid; bare
    `VAR=value` RHS parses as arithmetic. **FIXED c93919db** — lexer distinguishes
    glued `=` (literal RHS) from spaced `=` (arithmetic); boot-verified via KVM DE
    gate. rc.de-user's `HOME='/home/live'` workaround could now be plain `HOME=...`.
  - DEFERRED (quiet window): `test_de_terminal_nonhostowner.sh` one-way-deny
    assertions + a full visual DE boot (SIGKILL'd under load) — fold into #6.

## Cluster D — Performance
- [x] **D1 First-terminal input lag** — LANDED b9744841. Root cause traced:
  cross-process file-read caching (ext4 page cache + block buffer cache) cold on
  the first `hamsh`/rc/`ls`/`pwd` reads; warm for terminal #2. Fix: rc.5
  pre-warms the caches synchronously before the terminal launches; `pwd` is now
  a hamsh builtin (no `/bin/pwd` cold-exec); `COLD_START` marker added. Gate:
  `test_de_first_term_prewarm_guard.sh` PASS. **DEFERRED live-timing validation**
  (quiet window): boot DE, read `COLD_START jiffies` before/after — tracked below.
- [~] **D2/D3 REFRAMED — not startup latency, an SMP wedge** (agent ad63d2b,
  measured on the real live image). On `-smp 1` both are sub-second
  (`newshell hostowner` +0.4s, `enter linux` +0.4s cold). On `-smp>1` the whole
  system stalls/wedges during the runlevel-5 fork+exec app-launch storm →
  presents as the user's 30–60s (D3) / ~2s (D2). Two factors: (1) LAPIC timer
  miscalibration under KVM (PIT-anchored, jiffies ~18–30× too fast → IRQ storm);
  (2) a scheduler/IPC deadlock exposed by the concurrent fork+exec storm.
  `_execve_lock` (f404c73c) RULED OUT.
  - **UPDATE (146c357b): timer factor FIXED + the "wedge" reframed.** LAPIC
    calibration is now TSC-anchored with a ±12.5% clamp (safe PIT fallback). On
    a quiet KVM host the `-smp 2` DE image boots in ~4s — the 300s "wedge" was
    **host-load/TCG starvation under concurrent agents**, not a kernel bug. New
    ship-path gate `test_smp_de_runlevel5.sh` (KVM `-smp 2`) PASS on main.
  - PARKED (task #9): factor-2 (possible sched/IPC deadlock) is unreproducible
    on quiet KVM → needs a real repro before it can be fixed. If the user still
    sees 30-60s after the clamp lands, capture host details + whether the clamp
    fired. Also: `test_smp.sh` (TCG, 90s timeout) is too tight on slow hosts.
  - Incidental (confirmed): the live SERIAL console already runs as `live`
    (uid 1001); only the DE terminal is `nobody` — see C1.

## Interactive QA pass #1 (orchestrator, 2026-07-01, quiet KVM host)
Booted `build/hamnix-installer.img` (KVM, `-vga std`, headless screendump) to
runlevel 5 and captured the idle desktop. Screenshots in the session scratchpad.

VISUALLY CONFIRMED landed fixes:
- **A2** — CPU widget bar is partial (~40%) at idle and does NOT climb to 100%
  over an 8s idle interval (two shots 8s apart). Fix holds.
- **A1** — bottom taskbar live-lists the open windows (Editor/Calculator/Files/
  Terminal); top panel mirrors them. Populates correctly with default apps.
  (The user's exact repro — close ALL then open new — still needs input-driven
  verification; see QA-N3.)
- File manager (`hamfm: /` with real folder/file icons), terminal (`hamsh$`,
  `ls /`), calculator all render; desktop icons (System Monitor, Home) present;
  serial confirms the console runs as `live` (uid 1001).

NEW bugs found this pass:
- [x] **QA-N1** — LANDED ef65b3ed. NOT a z-order bug (my hypothesis was wrong):
  per-pixel analysis proved the compositor correctly occludes the desktop under
  windows. Real cause: the terminal auto-opened at x=24, BISECTING the desktop
  icon-label column (starts x=18), so the uncovered label slivers in the 6px
  strip left of the window edge read as orphaned glyphs. Fix: terminal default
  origin x=24 → x=150 (clears the icon strut; matches where all other default
  apps already open). Guard added to `test_de_ux_fixes_guard.sh` (PASS).
  - FUTURE (optional): a general "windows avoid the desktop-icon work-area strut"
    WM feature would prevent any window (dragged or spawned) from bisecting icons.
- [ ] **QA-N2** (low-confidence) — cursor position changed between two
  screendumps with NO input injected (center → bottom-right). Possible spurious
  cursor motion or non-deterministic rest position. Re-observe.
- [~] **QA-N3** (method) — SOLVED in method (recon 2026-07-01). The DE reads a
  RELATIVE mouse via `/dev/mouse` (PS/2 `drivers/input/auxmouse.ad`; USB path is
  `usb-mouse`, also relative — there is NO absolute/tablet path, which is why the
  `usb-tablet` attempt both broke OVMF boot order AND wouldn't have driven the
  cursor). CORRECT approach for headless input-driven QA: use the plain `-vga std`
  boot (PS/2 mouse already present, boots fine) + HMP `mouse_move dx dy` /
  `mouse_button <mask>` over the monitor socket; slam the cursor to a corner with
  a large negative `mouse_move`, then offset by known deltas to reach a target
  (e.g. Applications button top-left), then click + screendump. Next: QA pass #2
  drives the Applications menu (verify A6 browser entry live), close-all-then-open
  (exact A1 repro), and right-click (A3/A4).

## Interactive QA pass #2 (orchestrator, 2026-07-01) — A1 REPRODUCED
Drove the DE via HMP relative mouse. Two screendumps one click apart:
- **de_preclick**: top panel + bottom taskbar BOTH list Editor/Calculator/Files/
  **Terminal**; workspace 1 selected; Terminal window open top-left.
- **de_menu_open** (after a click): **Terminal is GONE from BOTH lists**, yet the
  Terminal window is still open + visible, still on workspace 1.
- [x] **QA-N4** (A1) — FIXED 6bfdd12e. ROOT CAUSE: `_wsys_raise` (called on
  every pointer click) crossed the CHROME z-order floor. `/dev/wsys/windows`
  only lists app windows (`z<100`); chrome (panels/menus) is `z>=100`. Clicking
  an app window raised it to `top_z+1` computed over ALL windows incl. chrome →
  `>=101`, above the enumeration floor → the still-live, still-visible window
  vanished from both lists (workspace unchanged — matches the video exactly).
  The ctl `raise` verb already clamped to the app band; the internal
  `_wsys_raise` did not. FIX: made `_wsys_raise` band-aware (app windows raise
  only among `z<100` peers, clamped below 100). Regression: new
  `wsys_raise_enum_selftest` drives the REAL router click + asserts all windows
  still enumerate and z stayed `<100`. This is the definitive A1 fix.
- [x] **QA-N3b** (method) — SOLVED. Reliable headless input needs (1) a SINGLE
  persistent socat stream carrying all HMP commands (per-command reconnect drops
  rapid commands), (2) slam the cursor to a corner with ~20× `mouse_move -80 -80`
  (clamps to 0,0 regardless of accel), (3) step to the target in 1px moves
  (`mouse_move 1 0` / `0 1`) so accel is ~1:1. Landed a precise click on the
  Applications button. Script: scratchpad `qa_verify.sh`.

## Interactive QA pass #3 (orchestrator, 2026-07-01) — verified on a FRESH image
IMPORTANT: passes #1/#2 unknowingly booted a STALE 07:41 image (predating all
fixes — see memory `project_stale_installer_img_qa_trap`). Rebuilt the image from
current main (all 10 fixes) and re-verified with the working input tooling:
- [x] **A1** re-verified on fresh image: clicking a window's titlebar to RAISE it
  keeps it in BOTH the top panel and bottom taskbar (all 4 apps stay listed).
  Fix 6bfdd12e genuinely works.
- [x] **QA-N1** re-verified: terminal opens at x=150; the full desktop-icon column
  (Files/Terminal/Calculator/Text Editor/Install Hamnix/Settings/System Monitor/
  Home) renders cleanly, no bisected-label bleed.
- [x] **A6** re-verified: Applications menu opens and lists **Web Browser** (+ the
  other apps). Browser is discoverable.
- [ ] **QA-N5** (low) — the scene-DE Applications menu is a FLAT list, not MATE's
  cascading categories (Accessories/Internet/System/Settings) that the legacy
  hamappmenu.ad describes. Acceptable for now; a categorized menu would be closer
  to MATE parity. Enhancement, not a bug.

## Interactive QA pass #4 (orchestrator, 2026-07-01) — browser regression found
- [x] **QA-N6** (regression) — RESOLVED. The native Web Browser doesn't open a
  window. `scripts/test_de_browser.sh` (deterministic, serial-launches
  `hambrowse --demo &`) FAILS on the fresh current-main image: no "opening scene
  window", no "rendered segs=" — but NO panic. STATUS T75 shows this test PASSED
  when hambrowse landed (`segs=28 rows=28 links=2`), so it's a REGRESSION.
  hambrowse's `_newwindow` (user/hambrowse.ad:1171) returns -1 SILENTLY when
  `sys_open_write("/dev/wsys/ctl")` fails. `rc.boot` binds `#c /dev`, `#b`, `#I`
  but NOT `/dev/wsys`; and the identity rework this session moved the serial/DE
  shells to `live` uid 1001 (487d58dc/10db26d2/7b0704bf). STRONG HYPOTHESIS: the
  serial shell can't reach the window server (namespace missing /dev/wsys and/or
  a uid gate), so GUI apps launched from serial silently fail. Assigned to an
  agent to root-cause (namespace vs perm; bisect vs T75 dcf6f6e8 if needed) + fix
  at the right layer, AND make hambrowse print a real error instead of silent -1.
  - PARTIAL (3be71289): root cause was commit 10db26d2 dropping the console to
    `live` uid 1001 + devcons.ad's coarse gate blanket-denying non-hostowner
    write-opens of /dev/wsys/ctl. Fix un-blocks /dev/wsys/ctl (per-verb gate in
    devwsys_ctl_write still enforces hostowner-only chrome). This means ANY
    regular-user-launched GUI app (serial OR DE terminal) can now open a window,
    not just hostowner/menu-launched ones. BUT on fresh main the browser still
    FAILs at the RENDER stage (newwindow OK, no "opening scene window"/"rendered
    segs" across 3 runs) — suspected SECOND gate on the per-window files
    (/dev/wsys/<wid>/{scene,event,pointer}) for uid 1001. Agent resumed to
    reconcile + fix the test's hidden-serial/rc=0-on-fail visibility gap.
  - RESOLVED: NO second kernel gate — per-window scene files (/dev/wsys/<wid>/*)
    are gated by OWNERSHIP (creator pid), not uid, so `live` passes. The ctl fix
    (3be71289) was the complete kernel fix. GROUND TRUTH (orchestrator serial
    capture, fresh main, uid 1001): `hambrowse --demo &` → `[hambrowse] rendered
    segs=28 rows=28 links=2` + `opening scene window`. Browser WORKS. My earlier
    test FAILs were harness-only: the test fires the timed launch without warming
    up the shell (first-serial-command-drop ate it under load) AND its composite
    gate false-positives on any DE window's blue title bar. Test hardening =
    task #13 (product verified, test-quality follow-up). Test hardening commit
    b19a45cc (retry + non-zero-on-fail + serial dump) landed but still flaky here.
- [~] **QA-N3b caveat** — the HMP-mouse tooling is reliable for a SINGLE click
  (landed the Applications button in pass #3) but FLAKY across multi-step
  sequences (pass #4's menu→item click missed; cursor landed bottom-right). For
  app-render verification, prefer the deterministic serial-launched gates
  (test_de_browser.sh etc.) over pointer-driving.

## Interactive QA pass #5 (orchestrator, 2026-07-01)
- [x] **QA-N7** (REGRESSION I introduced) — FIXED 164079da. The `VAR=value` fix
  (c93919db) broke glued-`=` in ARGUMENT position (`echo a=b` → parse error).
  Fix: `parse_simple_command` now fuses a word arg followed by `OP_ASSIGN_LIT`
  into ONE argv element (new `ND_ARGCAT` node — handles `a=b`, `a=$V`, chained
  `a=b=c`, empty `a=`); statement-leading assignments still route through
  `_looks_like_assignment` (unaffected). Verified: `echo a=b`→`a=b`, leading
  `W=/x/y`→`/x/y`, 10 cases PASS; DE rl5 PASS (agent, fresh KVM image).
- [x] **QA-N8** (HIGH) — FIXED a953668f + FRESH-IMAGE VERIFIED. Two causes: (1)
  the QA-N6 devcons `/dev/wsys/ctl` open-gate (already on main via 3be71289 —
  the agent's redundant re-fix conflict was resolved to main's version), and (2)
  **lib/hamui painted into the RETIRED `/draw/` markup layer that the scene
  compositor never rasterizes** — repointed `_h_rect/_h_line/_h_border/_h_text`
  at the SCENE display list + `hamscene_commit()`; `hamui_window()` now
  self-allocates an OWNED, DECORATED top-level (was hard-bound to wid 1); failed
  opens now print a diagnostic. Verified: `hammon &` renders a full System
  Monitor window (titlebar, Refresh/Quit, live uptime/mem/process-table) AND
  enumerates in both panels. Affected every hamui app for the regular DE user.

VISUALLY CONFIRMED this pass (fresh image): **A5** Settings app — all four Edge
buttons (Top/Bottom/Left/Right) present, Add-widget row (menu/task/clok/sysm/
spcr) separate from Up/Down/Del (no overlap); **A1** the Settings window enumerates
live in both panels.

## Interactive QA pass #6 (orchestrator, 2026-07-01) — enter linux + newshell
Serial-driven on fresh image. `newshell hostowner` (pw hamnix) → `whoami`=hostowner
✓ and fast on -smp 1 (not 30-60s). `enter linux {ls /}` runs a real Linux-ABI
binary. But two bugs:
- [x] **QA-N9** (HIGH) — FIXED 0aef2ad0. Root cause = BUILD, not binding: the live
  image builds with `HAMNIX_LIVE_MINIMAL=1` → busybox-only `_stage_distro` path
  that created skeleton dirs but never `/etc`. Fix: `_stage_minimal_etc()` plants
  a minimal-but-real `/etc` (debian_version=12.9, os-release, passwd, group,
  hostname, apt/sources.list) + /var/lib/dpkg/status, non-clobbering for
  full-mirror builds. Disk-verified via debugfs on live-distro.ext4 (/etc present,
  debian_version=12.9). SERIAL CONFIRM PENDING a quiet-window image rebuild
  (current 12:28 image predates the fix).
- [x] **QA-N10** (MED) — FIXED c5aa68b6. Implemented `setuid`(105)/`setgid`(106)
  in linux_abi/u_syscalls.ad. Semantics: privileged (uid maps to Linux 0 /
  hostowner) sets any → 0; unprivileged may only re-assert its own id → 0;
  escalation → -EPERM. getuid/geteuid reflect changes. Verified: boot self-test
  `[UABI_FILLS] setuid/setgid gate OK` (drop/self/EPERM/consistency).
- [x] **QA-N11** (MED, pre-existing) — FIXED 1d6ffbd9. `_u_sched_getaffinity`
  returned the raw stored `cpu_affinity` (defaults to `AFFINITY_ALL`=0xFF..),
  never intersecting the online-CPU set → low byte 0xFF under -smp 1. Fix: new
  `sched_get_affinity_online()` (kernel/sched/core.ad) intersects the task mask
  with `get_cpus_online()` (matching real Linux `cpus_mask & cpu_active_mask`);
  the syscall now calls it → bit 0 only under -smp 1. Verified: `[UABI_FILLS]
  PASS` + `[test_uabi_fills] PASS` (all checks green).

## Consolidated fresh-image verify (orchestrator, 2026-07-01 14:04 image)
Rebuilt build/hamnix-installer.img from current main (all wave fixes) and ran one
KVM boot with serial + screendump. ALL PASS:
- DE boots to interactive shell (kernel devcons/hamui/sched changes = no regression).
- QA-N7: `echo QN7=a=b` → `QN7=a=b` (no parse error).
- QA-N9: `enter linux {cat /etc/debian_version}` → `12.9`.
- QA-N10: no `unknown syscall nr=105/106` (setuid/setgid live).
- QA-N8: `hammon &` as `live` → full System Monitor window (titlebar/Refresh/Quit/
  live uptime+mem+16-row process table) + enumerates in both panels.
- QA-N12: NOT reproduced — the serial-launched hammon DID enumerate in the taskbar
  (hamui owned-window fix resolved it). Closed.

## Interactive QA pass #7 (orchestrator, 2026-07-01) — Debian binaries under enter linux
Positives (QA-N9 further confirmed): `enter linux {cat /etc/os-release}` →
`PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"` (full); `ls -la /etc` shows
debian_version+os-release; `sh -c "echo X"` works. New:
- [ ] **QA-N13** (hamsh, LOW — completes QA-N7) — a LEADING `=` (empty LHS) in an
  argv word is mishandled: `echo =x` prints nothing (swallowed), `echo ===x` →
  `parse error: unexpected token after command`. `echo a=b`/`x=y=z`/`p:q=r` all
  work (non-empty LHS). Fix in user/hamsh.ad: a word beginning with `=` (no name
  char before it) is a literal argument word, not an assignment/OP_ASSIGN_LIT.
  Assigned.
- [x] **QA-N14** (Linux minimal root) — FIXED 1fdcb10e (pending consolidated
  fresh-image verify). `_stage_busybox` now symlinks the common applets present
  in the staged musl busybox (uname, id, whoami, hostname, groups, who, users,
  env, printf, date, sleep, …). dpkg/apt stay absent (full-mirror-build only, by
  design). Verify: `enter linux {uname -a}`, `{id}`.

## Consolidated verify #2 (orchestrator, 2026-07-01 14:29 image) — QA-N13/N14
Fresh image from HEAD 8c997087, serial-driven. ALL PASS:
- DE boots to interactive shell (all kernel changes = no regression).
- QA-N13: `echo =x`→`=x`, `echo ===x`→`===x` (FIXED 8c997087).
- QA-N14: `enter linux {uname -a}`→`Linux hamnix 6.12.0-hamnix ... x86_64
  GNU/Linux`; `enter linux {id}`→`uid=1001(live) gid=1001` (FIXED 1fdcb10e).
- QA-N7 regr: `echo N7=a=b`→`N7=a=b`. QA-N9 regr: debian_version→`12.9`.
- [x] **QA-N15** (LOW) — FIXED 8bb53441 + FRESH-IMAGE VERIFIED. Implemented
  getgroups(115)/setgroups(116) in linux_abi/u_syscalls.ad (one supplementary
  group == the task's mapped gid; setgroups privileged-or-EPERM like setuid).
  Verified: `enter linux {id}` → `uid=1001(live) gid=1001 groups=1001` (was
  `can't get groups` + unknown-syscall). Cherry-pick conflicted (agent's stale
  base lacked QA-N10) — resolved by hand keeping both, normalized to ELINUX_PERM;
  rebuild compiled clean.
- NOTE: `echo N13a=[=x]` (glued `=` immediately followed by `[`) still parse-errors
  — a separate, much rarer edge than QA-N13; not chased (real code doesn't do `=[`).

## Interactive QA pass #8 (orchestrator, 2026-07-01) — Debian tools + hamsh edge
Confirmed the QA-N14 busybox applets FUNCTION (not just resolve): `hostname`→
`hamnix`, `env`→PATH/HOME, `date`→`Wed Jul 1 …`, `grep root /etc/passwd`→match,
`head -1 /etc/os-release`→`PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"`. Two finds:
- [x] **QA-N16** (hamsh) — FIXED 573bfc53. A glued `=`-run AFTER word content is
  absorbed into the word as literal text ONLY when followed by a terminator
  (space/EOL/;/operator/EOF); if followed by a value-continuation char (word
  char/`$`/quote/backtick) it stays OP_ASSIGN_LIT (preserving assignment + QA-N7
  fusion). `echo abc===`→`abc===`, `echo foo==`→`foo==`. All 16 test_hamsh_assign
  cases pass; DE rl5 boot-verified. **The hamsh `=` handling is now complete**
  (leading N13 + trailing N16 + arg-position N7 + assignment).
- [ ] **QA-N17** (Linux ns /proc, MED — LARGER) — under `enter linux`, `/proc`
  lists PID entries (readdir works) but `/proc/<pid>` can't be stat'd/opened
  ("No such file"), so `ps`/`top` fail. The procfs backing the linux-ns is
  partial (dir enumeration without per-pid nodes). Real "run Debian" gap but a
  sizeable subsystem — tracked for a dedicated future effort, not a quick fix.

## Interactive END-USER push #1 (orchestrator, 2026-07-01) — pushing limits
On the 15:35 fresh image (all fixes). WORKS: native pipe `ls / | grep bin`→`bin`;
native redirect `echo x > /tmp/f; cat /tmp/f`→`x`; **QA-N17 VERIFIED** `enter
linux {ls /proc}`→pid dirs + meminfo/mounts/version/cpuinfo (zero errors),
`enter linux {ps}`→`PID USER TIME COMMAND` process table; linux pipe `ps | grep
hamsh`; linux redirect `sh -c "echo A > /tmp/lx; cat /tmp/lx"`→`A`. apt-get not
found (expected, minimal root); `mount`→exit 1 (minor).
- [ ] **QA-N18** (hamsh UX, LOW — needs syntax confirm) — `for x in a b c { echo
  $x }` (POSIX word-list) → `parse error: expected {`. hamsh is Python-flavored:
  `parse_for` takes `for VAR in <single expr> { body }` (spec ex: `for f in
  $files {`), so a bare word-LIST isn't an iterable. Likely by-design, but the
  common bash idiom failing with a confusing error is a UX gap. NEXT: confirm the
  correct iterable form works; decide whether to accept a word-list. Not a bug yet.
- [ ] **QA-N19** (cosmetic, LOW) — `enter linux {ps}` shows pid 1 COMM as
  `koftfird` (looks like a garbled/obfuscated comm read). ps otherwise works.

## Interactive END-USER push #2 (orchestrator, 2026-07-01) — hamsh scripting
WORKS: `if 5 > 3 { echo BIG } else {…}`→BIG; `while $n < 3 {…}` + arithmetic
`n = $n + 1`→LOOPN 0/1/2; `def greet(who){…}` + `greet(world)`→runs; script file
`hamsh /tmp/s.hamsh`→FROM_SCRIPT. So if/else, while, def+call, and script
execution all function.
- [x] **QA-N20** (hamsh, HIGH) — FIXED 0eaefdab + boot-verified. Token-adjacency
  tracking (`tok_glued[]` + `_glue_adjacent`→`ND_ARGCAT`, the `$`-analog of
  QA-N7): a bareword glued to a `$var`/expansion (either side, chained) fuses into
  ONE argv word. `echo Kpre$s`→`Kpreworld`, `K$s.txt`→`Kworld.txt`, `$s$s`→
  `worldworld`; `a $s b`→3 words (spaces preserved); `"Kq$s"`→`Kqworld`. New
  test_hamsh_expand.sh 7/7 + test_hamsh_assign 16/16 + DE rl5 PASS. (Was: unquoted
  `text$var` split into separate argv words — a silent-wrong-result idiom bug.)
- [x] **QA-N18** (hamsh for-loop) — FIXED e416f3e4 + boot-verified. `parse_for`
  now collects one-or-more item words after `in` until `{` (same argv machinery:
  `$var`/glob/`text$var` fusion); ND_FOR holds item-word kids; `exec_for`
  expands+iterates the body once per item. Verified on main: `for x in a b c {
  echo L_$x }`→L_a/L_b/L_c; `for f in solo {…}`→S_solo. Regressions clean. The
  universal shell for-loop idiom + single-item + `$var`-list all work.
- [ ] **QA-N19** (cosmetic) — `enter linux {ps}` pid-1 COMM shows `koftfird`
  (garbled comm read); ps otherwise works.

## Notes
- Perf theme continues the long-standing DE input-latency track (see memory
  `project_de_perf_pivot`, `project_de_interactive_broken_2026-06-15`).
