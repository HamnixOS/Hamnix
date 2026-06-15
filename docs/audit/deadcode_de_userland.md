# DE / userland dead-code + redundancy audit (`user/`, `lib/`)

READ-ONLY audit. No source deleted or edited. Generated 2026-06-15.

Scope: `user/` (esp. `user/hamUId.ad` ~30k LOC, the ham* DE apps) and
`lib/hamui.ad`. Verification was tree-wide grep including `etc/`,
`etc/services.d/`, `scripts/`, and the kernel `sys/src/9/port/` dispatch
where a user-side symbol is wired through the kernel.

Tag legend:
- **SAFE-REMOVE** — zero references from any launch site (build, menu,
  services.d, inittab, hamUId spawn, ctl-verb dispatch, autoflag selftest).
- **NEEDS-REVIEW** — reachable only from a narrow / legacy path (selftest
  autoflag, an unreferenced argv flag, or a redundant-but-enabled service);
  removing it changes behaviour or drops test coverage, so it needs a human
  decision, not a mechanical delete.

Method note / why few clean SAFE-REMOVEs: `user/hamUId.ad` dispatches huge
swaths of code from (a) `autoflag` test modes and (b) ctl-verb / CSI input
handlers, so "no direct caller" almost never means dead. The real rot here
is **live redundancy** (two mechanisms that both work and both ship), not
classically-unreferenced dead code. That is reported faithfully below.

---

## VERDICT ON THE rio / devwin SCAFFOLDING — **DEAD SCAFFOLDING**

The `#wsys/<N>/{ctl,data,event}` rio-faithful triple is wired end to end
but never exercised by any shipping launch, and its kernel bodies are
still skeleton placeholders. It is dead scaffolding.

Evidence chain:

- `sys/src/9/port/devwin.ad:1-214` — whole file. Header (lines 38-44)
  states it is "COMMIT 1, skeleton… bodies are minimal placeholders that
  return ENOSYS / EINVAL". `devwin_ctl_read` (101), `devwin_data_read`
  (131) return 0/EOF; `devwin_event_write` (209) returns `WIN_ENOSYS`.
  Only `devwin_ctl_write` / `devwin_data_write` / `devwin_event_read`
  delegate to the legacy devwsys path; the rest are stubs.
- `sys/src/9/port/namec.ad:856-858, 1574-1582, 1967-1974, 2347-2352` —
  `DEV_WIN_CTL/DATA/EVENT` kinds are routed to the `devwin_*` wrappers.
  So the kernel plumbing is real; it just has no caller.
- `lib/hamui.ad` — the ONLY user of the rio name. The `/dev/win/<leaf>`
  path is built by `_h_build_win_path` (394) and the per-Pgrp bind by
  `_h_install_rio_bind` (414). Both fire **only** when `_rio_path != 0`
  (default `0`, line 246), gated through `_h_ctl` (2240) and
  `hamui_window_on` (2284).
- `lib/hamui.ad:2254 hamui_enable_rio_path(en)` is the only switch that
  sets `_rio_path`. **Tree-wide, the single caller that passes `1` is
  `user/hamclock.ad:200`**, itself gated behind a bespoke `--rio` argv
  scan (`hamclock.ad:181-201`).
- **Nothing passes `--rio` to hamclock.** Grep of `etc/`, `scripts/`,
  `*.hamsh`, every launcher, and hamUId spawn calls finds zero
  `hamclock --rio`. hamclock is launched as plain `/bin/hamclock`
  (`user/hampanel.ad:798`). So the only path that flips the rio flag is a
  human typing `hamclock --rio` by hand — and even then the data sink is
  a skeleton stub.
- `etc/rc.de-user:55` / `etc/rc.de-hostowner:40` `bind '#w' /dev/win`
  binds the **legacy** devwsys server to `/dev/win`, NOT the devwin
  triple; these binds support the legacy `/dev/wsys/<wid>/{...}` surface
  the DE terminal already uses, so they do not make the rio triple live.

- [x] REMOVED `sys/src/9/port/devwin.ad:1-214` — entire rio-faithful
  facade — skeleton, never reached by a shipping launch. Deleted the
  whole file plus the `DEV_WIN_*` constants + dispatch/path-parse arms +
  devwin import in namec.ad. Legacy `/dev/wsys/*` path untouched.
- [x] REMOVED `lib/hamui.ad` `_rio_path`, `_h_build_win_path`,
  `_h_install_rio_bind`, `hamui_enable_rio_path`, the `sys_bind` extern,
  and the rio branch of `_h_ctl` / `hamui_window_on` — the only enabler
  was the unreachable `hamclock --rio`. `_h_ctl` now always uses the
  legacy `/dev/wsys/<wid>/draw/ctl` path. (The `version 2` v2-blit
  substrate — `hamui_set_protocol_v2`, legacy `/dev/wsys/<wid>/wctl` —
  is a SEPARATE live path and was left intact.)
- [x] REMOVED `user/hamclock.ad` `--rio` argv scan
  (`_k_argv_has_rio`) + `hamui_enable_rio_path(1)` call + import. hamclock
  keeps working on the legacy path. Build green + DE screenshot verified
  (panels + wallpaper render). `scripts/test_de_rio_blit.sh` guards the
  live v2-blit substrate (not the removed scaffolding) and stays.

---

## 1. DEAD CODE (zero references)

No classically-unreferenced top-level functions were found in the DE apps
or `lib/hamui.ad` (every public widget/draw helper has a consumer). The
30 `daemon_*_selftest` functions in `hamUId.ad` LOOK dead (no normal
caller) but are each dispatched from the `autoflag` table
(`hamUId.ad:29468-29840`), e.g. `daemon_wm_selftest` ← autoflag 2,
`daemon_mouse_selftest` ← autoflag (mouse test). They fire from test
markers and are intentionally retained — **NOT dead**, do not remove.

- [NEEDS-REVIEW] `user/hamUId.ad` in-compositor `MENU_OPEN` inline
  Applications-menu open/paint machinery (`MENU_OPEN` global 3873;
  `SUBMENU_OPEN` 4618; `menu_launch` 15040; the bar-dropdown hit/paint in
  the 15900-16930 region) — the production Applications menu is now the
  EXTERNAL `/bin/hamappmenu` client, which posts a program path to
  `/dev/wsys/appmenu/launch` that hamUId spawns directly
  (`hamUId.ad:13105,13148`) WITHOUT going through `menu_launch`. Evidence
  `MENU_OPEN` is never set to `1` anywhere outside selftest paths (every
  production assignment is `MENU_OPEN = 0`: 9947,16286,16516,21558,23921);
  the `SUBMENU_OPEN`/`menu_launch` openers at 16249/16896/16915 live
  inside `daemon_*_selftest` bodies. So the inline menu is legacy,
  exercised only by autoflag selftests. — recommend a human decide whether
  the panel selftests should be repointed at hamappmenu so this inline
  menu can be retired.

## 2. REDUNDANT MECHANISMS (the main finding)

- [NEEDS-REVIEW] **Two complete DE panels ship and both start at runlevel
  5.** `etc/services.d/hamde.svc` (`enabled: yes`, `runlevel: 5`) launches
  `/bin/hamde` — the older "DE panel as a plain hamui client"
  (Applications menubar + clock + taskbar, `user/hamde.ad`). Meanwhile
  `etc/services.d/hamuid.svc` starts hamUId, which at startup
  (`hamUId.ad:29867-29871`, autoflag 0/1) spawns the DE-pivot panel
  clients `/bin/hampanel` (top strip) + `/bin/hambottom` (bottom strip),
  and the Applications menu is `/bin/hamappmenu`. hamUId never spawns
  hamde (grep: zero `hamde` spawns in hamUId.ad). So hamde is an
  independent, supervisor-launched SECOND panel that binds wid 1
  (`hamde.ad:36-38`, no argv) and overlaps hampanel/hambottom/hamappmenu
  functionally. — recommend disabling/removing `hamde.svc` (and likely
  retiring `user/hamde.ad`) since the DE-pivot panel stack supersedes it.

- [NEEDS-REVIEW] **In-compositor APP_* apps duplicate the standalone ham*
  apps, and the in-compositor copies are still LIVE in the production
  menu.** `menu_app` (`hamUId.ad:4478`) maps Applications-menu entries to
  in-process app kinds: entry 1→`APP_EDITOR`, 3→`APP_CALC`,
  4→`APP_SYSMON`, 5→`APP_ABOUT`, 8→`APP_FILEMGR`; `menu_launch`
  (`hamUId.ad:15097`) dispatches `daemon_spawn_app(app,…)` for these. Each
  has a standalone external equivalent shipped and in `build_user.sh`:
  `hamcalc`, `hamsysmon`, `hamfm`, `hamedit`. Only "Terminal" (entry 0)
  was converted to the external client (`daemon_spawn_terminal` →
  `/bin/hamterm`, `hamUId.ad:15089-15098`); the MATE-mirror
  externalisation was never finished for the rest. So the in-compositor
  `APP_CALC/SYSMON/FILEMGR/EDITOR` rendering+input code (large blocks in
  hamUId.ad) duplicates the standalone apps and is the heaviest redundancy
  in the tree. — recommend finishing the externalisation (point the menu
  entries at the standalone apps) and then retiring the in-process APP_*
  bodies.

- [NEEDS-REVIEW] `user/hamUId.ad` `APP_TERM` in-daemon terminal grid —
  explicitly described as "dormant" in production: the menu Terminal entry
  now spawns external `/bin/hamterm` (see `daemon_menu_term_selftest`
  commentary at `hamUId.ad:27607-27614`: "The dormant in-daemon APP_TERM
  grid… has NO backing process"). Still reachable only via selftests
  (`daemon_spawn_app(APP_TERM,…)` at 24434, 25136, 25551, 25917, 26044,
  26100). — candidate for removal once the selftests that drive APP_TERM
  are repointed at the hamterm process path.

- [SEED / OUT-OF-SCOPE] The `/dev/mouse` writable-mouse vs `nudge` ctl-verb
  redundancy that prompted this audit lives in the KERNEL
  (`sys/src/9/port/devwsys.ad:132,3142` `nudge` verb →
  `mouse_rx_push_abs`), not in `user/`+`lib/`. No user/lib client writes
  the literal `nudge` verb (grep: the only `nudge` hits in user/ are
  unrelated window-kmode "nudge" wording). Recorded for completeness; the
  fix belongs in the devwsys audit, not this one.

## 3. ORPHAN FILES (apps that can never be launched)

Every `user/ham*.ad` is present in `scripts/build_user.sh` (49 ham*
targets, all build). No build orphan.

- [NEEDS-REVIEW] Demo apps build but are not in any launcher menu
  (`hamappmenu`/`hampanel`/services.d): `hamui_demo`, `p9srv_demo`,
  `dup_demo`, `nice_demo`, `preempt_demo`. These are intentional
  CLI-invoked demos/regression fixtures (runnable from a shell), so not
  strictly orphaned, but they are not user-reachable from the DE. — leave
  as-is unless trimming demo surface; flagged for visibility only.

## 4. DUPLICATE / COPY-PASTE WIDGET CODE

- [NEEDS-REVIEW] The in-compositor APP_* widget rendering (calc keypad,
  sysmon bars, file-grid, editor) in `hamUId.ad` is hand-rolled procedural
  drawing that re-implements what the standalone `hamcalc`/`hamsysmon`/
  `hamfm`/`hamedit` build from `lib/hamui.ad` widgets. This is the same
  redundancy as §2 viewed as duplication: the DE has two parallel widget
  stacks (procedural-in-hamUId vs lib/hamui.ad-in-apps). Consolidating on
  lib/hamui.ad (i.e. externalising the APP_* apps) removes the duplicate.
  No additional standalone-vs-standalone copy-paste was found across the
  ham* apps — they each `import` from `lib/hamui.ad` rather than copying
  widget code.

---

## Summary counts

- DEAD CODE (truly unreferenced): **0** clean. (30 `*_selftest` fns look
  dead but fire from autoflag — retained on purpose.)
- REDUNDANT MECHANISMS: **4** (rio/devwin scaffolding; dual DE panel
  hamde vs hampanel-stack; in-compositor APP_* vs standalone apps;
  dormant APP_TERM grid). +1 seed (kernel nudge, out of scope).
- ORPHAN FILES: **0** build orphans; 5 demo apps not in DE menus.
- DUPLICATE WIDGET CODE: **1** structural (procedural APP_* vs
  lib/hamui.ad apps).

SAFE-REMOVE: none mechanically safe (everything is reachable from a
service, a selftest, or a ctl/argv path). All findings are NEEDS-REVIEW —
they require a human decision to disable a service / repoint a selftest /
finish an externalisation before the redundant code can go.
