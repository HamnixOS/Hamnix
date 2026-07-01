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

## Cluster C — Identity
- [ ] **C1 `whoami` on the elevated shell says "nobody"** — should say **`live`**
  (the live image's username). Elevated-shell identity not propagated.

## Cluster D — Performance
- [ ] **D1 First-terminal input lag.** On the *first* terminal: 1st char quick,
  2nd char ~0.2s late, command (`pwd`) ~0.5s to run. **Closing and reopening a
  terminal makes it fast** — cold-start warm-up issue, not steady state.
- [ ] **D2 Entering the Linux namespace still takes a couple seconds.**
- [ ] **D3 `newshell hostowner` still takes ~30s–60s** (identity is *correct* —
  `whoami` → `hostowner`; this is purely startup latency).

## Notes
- Perf theme continues the long-standing DE input-latency track (see memory
  `project_de_perf_pivot`, `project_de_interactive_broken_2026-06-15`).
