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
- [~] **A1 App/window list not live.** Wiring verified intact + kernel
  self-test `test_de_multiwin_taskbar` passes; NOT reproducible in current code.
  Hit-testing hardened. **NEEDS LIVE VERIFY** — if still seen, prime suspect is
  the kernel workspace filter (`wsys_win_ws[w]==wsys_cur_ws`) hiding windows
  after a pager switch (flagged, not blindly changed).
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
    `VAR=value` RHS parses as arithmetic. Worked around; fix in the parser.
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
- [ ] **QA-N1** (rendering) — stray single glyphs along the far-LEFT screen edge,
  partially occluded by the terminal window. Looks like desktop-icon label text
  compositing ABOVE windows (z-order) or not cleared on repaint. Investigate the
  desktop-icon vs window z-order / damage-rect in the scene compositor.
- [ ] **QA-N2** (low-confidence) — cursor position changed between two
  screendumps with NO input injected (center → bottom-right). Possible spurious
  cursor motion or non-deterministic rest position. Re-observe.
- [ ] **QA-N3** (method) — input-driven QA (open Applications menu to eyeball A6
  browser entry; close-all-then-open for the exact A1 repro; right-click for
  A3/A4) needs a working abs-pointer path: adding `usb-tablet` broke OVMF boot
  order (fell to PXE) and it's unverified whether tablet events reach the DE
  cursor at all (DE may only read PS/2 aux). Pin `bootindex=0` + confirm the DE
  HID input path before the next input-driven pass.

## Notes
- Perf theme continues the long-standing DE input-latency track (see memory
  `project_de_perf_pivot`, `project_de_interactive_broken_2026-06-15`).
