# Hamnix DE — MATE 1.x parity gap analysis

**Status:** survey (2026-06-27). Read-only audit of the scene-file DE
(`docs/de_scene_file_arch.md`) against real MATE/GNOME2 1.x. Every
DONE/PARTIAL/MISSING verdict below is grounded in the actual `.ad` source
read for this doc, not in `STATUS.md` optimism. The goal is to let the
orchestrator dispatch well-scoped DE waves against the real remaining gaps.

## How to read this

- **DONE** — feature exists and the code actually does the work end-to-end.
- **PARTIAL** — a real implementation exists but is missing capabilities a
  MATE user would expect (the "gap" column says what).
- **MISSING** — no implementation; at most a menu entry pointing at a binary
  that does not exist.

### Architecture note (load-bearing for the verdicts)

The compositor / window manager is **`user/hamUId.ad`**, still live at
runlevel 5 via `services.d/hamuid.svc` (see `etc/rc.d/rc.5`). The scene
clients (`hamdesktop`, `hampanelscene`, the apps) run as *windows on top of
it*. The kernel `sys/src/9/port/devwsys.ad` owns the scene file server, the
SSD frame chrome geometry, snap-intent state, and the `ws <N>` workspace
verb; `hamUId.ad` polls those slots and does the actual WM behaviour
(workspace hide/show, Alt-Tab cycle, snap apply). So "WM features in
hamUId.ad" are LIVE, not dead legacy — the pixel-push *backbuffer* path is
what is being gutted, not the WM logic.

---

## 1. Feature matrix

### Window manager (Marco-equivalent)

| MATE feature | Status | Hamnix file | Evidence |
|---|---|---|---|
| SSD titlebar + min/max/close buttons | DONE | `user/hamUId.ad`, `sys/.../devwsys.ad` | Three 14×14 buttons hit-tested by compositor; `window_toggle_maximize`, `DWIN_HIDDEN` minimize, armed close |
| Edge-snap / half-screen tiling | DONE | `sys/.../devwsys.ad` (`WSYS_SNAP_*`, 6px edge), `user/hamsnap.ad` | Drag within 6px of edge → maximize / half-tile; `/dev/wsys/snap` preview client |
| Interactive edge/corner resize | DONE | `sys/.../devwsys.ad`, `user/hamresize.ad` | 4 edges + 8 corners; `/dev/wsys/resize` overlay client |
| WM keybindings (Alt-Tab, Alt-F4, Super+arrows) | DONE | `user/hamUId.ad`, `user/hamcycler.ad` | Registry: cycle/run/close/move/resize/half-tile/maximize; `/dev/wsys/cycler` popup |
| Virtual desktops / workspaces | DONE | `user/hampanelscene.ad`, `sys/.../devwsys.ad` | Pager click → `ws <N>`; `workspace_switch` hides off-desktop windows via `DWIN_WS[]` |
| Window-list taskbar (raise/focus/minimize) | DONE | `user/hampanelscene.ad`, `user/hamUId.ad` | Reads `/dev/wsys/windows`; click writes `raise`+`focus`; minimized shown dimmed |
| Focus-follows-mouse option | PARTIAL | `docs/de_scene_file_arch.md` §11, `user/hamUId.ad` | Click-to-focus implemented; "configurable to follow-mouse" is spec text, no setting wired |
| Window rules / per-app placement | MISSING | none | No Marco-style window-matching rules |
| Compositing effects (shadows, fade) | MISSING | none | SSD frames are flat fills; no drop shadow / alpha transitions |

### Panel & applets

| MATE feature | Status | Hamnix file | Evidence |
|---|---|---|---|
| Multi-edge configurable panels | DONE | `user/hampanelscene.ad`, `etc/panel.conf` | top/bottom/left/right, per-panel color/size/font/widget list; live re-read |
| Applications menu | PARTIAL | `user/hamappmenu.ad` | Static categories + real launch via `/dev/wsys/appmenu/launch`; NO search, NO favorites, `.desktop` scan is a TODO |
| Window-list applet | DONE | `user/hampanelscene.ad` | (see WM taskbar row) |
| Workspace-switcher / pager applet | DONE | `user/hampanelscene.ad` | Real `ws <N>` switching, active cell lit |
| Clock applet | DONE | `user/hampanelscene.ad`, `user/hamclock.ad` | HH:MM from `/dev/stat` btime + `/dev/time` uptime |
| Calendar popup | DONE | `user/hamcalpop.ad` | Month grid, today highlighted; **no timezone config** |
| System-monitor applet (CPU/mem) | PARTIAL | `user/hampanelscene.ad`, `user/hammonscene.ad` | Mem bar real; CPU is load-approx — kernel exposes no per-task CPU time |
| Notification area / system tray | PARTIAL | `user/hampanelscene.ad`, `user/hamtray.ad` | Bell + unread badge → history panel; NO StatusNotifier docking (apps can't embed icons) |
| Volume applet | PARTIAL | `user/hamUId.ad`, `user/hamosd.ad` | Real `/dev/audioctl`/`/dev/audio` mixer + OSD slider, BUT lives in legacy hamUId status-notifier, **not a scene panel applet** |
| Brightness applet | PARTIAL | `user/hamosd.ad`, `user/hamUId.ad` | OSD slider + `bri_step` model only; **no backlight hardware write** |
| Battery / power applet | MISSING | none | No battery readout / power applet |

### Caja (file manager)

| MATE feature | Status | Hamnix file | Evidence |
|---|---|---|---|
| Directory navigation | DONE | `lib/hamfmcore.ad`, `user/hamfmscene.ad` | Icon grid, breadcrumb, up/into, wheel+key scroll |
| Open file (launch app) | DONE | `user/hamfmscene.ad` | Double-click spawns editor/app |
| Copy / move / delete / rename | MISSING | none | No file mutation ops at all |
| Create folder | MISSING | none | — |
| Trash | MISSING | none | — |
| Properties dialog | MISSING | none | — |
| Bookmarks / places sidebar | MISSING | none | — |
| Right-click context menu | MISSING | none | FM has no context menu |
| Cut/copy/paste between windows | MISSING | none | — |

### Control center (mate-control-center capplets)

| MATE capplet | Status | Hamnix file | Evidence |
|---|---|---|---|
| Appearance / wallpaper | PARTIAL | `user/hamsettings.ad` | Solid-color swatches → PPM wallpaper only; no image wallpaper picker, no theme, no fonts |
| Panel preferences | DONE | `user/hamsettings.ad` | Edge/size/font/color/widget-list edits `panel.conf`, live-reloaded |
| Keyboard shortcuts | MISSING | none (menu entry → `/bin/hamset-keyboard` absent) | Bindings hard-coded in hamUId; not user-editable |
| Displays / resolution | MISSING | none (`/bin/hamset-display` absent) | — |
| Mouse / pointer | MISSING | none (`/bin/hamset-mouse` absent) | — |
| Power management | MISSING | none | — |
| Screensaver settings | MISSING | none | Idle timeout hard-coded in `hamscreensaver.ad` |
| Date / time / timezone | MISSING | none | — |
| Default applications | MISSING | none | — |
| Sound preferences | MISSING | none (`/bin/hamset-sound` absent) | Mixer exists; no settings UI |

### Default apps

| MATE app | Status | Hamnix file | Evidence |
|---|---|---|---|
| mate-terminal | PARTIAL | `user/hamtermscene.ad`, `user/hamterm.ad` | Real persistent hamsh, local echo, 16KB scrollback, history; NO tabs, NO copy/paste selection, NO color/font choice |
| mate-calc | PARTIAL | `user/hamcalc*.ad` | Real int +−×÷ with div-by-zero guard; NO scientific mode, NO float |
| pluma (editor) | PARTIAL | `user/hameditscene.ad`, `user/hamedit.ad` | Real open/save, caret, soft-wrap, line gutter; NO find/replace, NO syntax highlight, NO undo |
| eye-of-mate (viewer) | PARTIAL | `user/hamview.ad` | Decodes PPM + uncompressed BMP, nearest-neighbour scale; NO PNG/JPEG, NO zoom/rotate |
| mate-system-monitor | PARTIAL | `user/hammon*.ad` | Live process list + mem from `/proc`; NO CPU%, NO kill, NO graphs |
| mate-screenshot | DONE* | `user/hamshot.ad` | Captures `/dev/fb` → P6 PPM full-screen; *NO region/window mode |
| mate-screensaver / lock | PARTIAL | `user/hamscreensaver.ad`, `user/hamlock.ad` | Idle-timeout spawn + password unlock; NO blank/animation modes, NO settings |
| Notification daemon | PARTIAL | `user/hamtoast.ad`, `user/haminbox.ad`, `user/hamnotify.ad` | Real transient toast + history log; NO action buttons, NO urgency/expiry policy, NO real queued daemon |
| Session manager / logout | DONE | `user/hamsessui.ad`, `user/hamsession.ad` | Lock/logout/shutdown/reboot all wired; save+restore of open windows |
| Desktop icons | PARTIAL | `user/hamdesktop.ad` | Clickable launchers from `/etc/desktop.icons`; NO drag/reposition, NO desktop right-click menu, NO file-drop |

### Misc

| MATE feature | Status | Hamnix file | Evidence |
|---|---|---|---|
| Panel right-click "Add to Panel" / Move / Remove | DONE | `user/hampanelscene.ad`, `user/hamctxmenu.ad` | Real add/move/remove widget menu |
| Desktop right-click menu | MISSING | none | `hamdesktop.ad` wires no context menu |
| Games (mate-games equiv) | DONE | `user/ham2048.ad`, `user/hamsnake.ad` | Real playable scene games |

---

## 2. Prioritized gap list (ordered by parity-value / effort)

Ordered best-bang-first: each is a feature a MATE user immediately reaches
for and notices missing, weighed against scope.

1. **Caja file operations (copy/move/delete/rename/mkdir)** — *large parity
   value, medium effort.* The file manager navigates but cannot mutate the
   filesystem — the single biggest "this isn't a real desktop" gap. Implement
   in `lib/hamfmcore.ad` (shared model) + `user/hamfmscene.ad` (UI: context
   menu, confirm dialog, rename inline edit). Needs a small set of p9 ops
   (create/remove/rename) the kernel already exposes.

2. **Desktop + file-manager right-click context menus** — *high value, small
   effort.* MATE's whole interaction model is right-click-driven. The panel
   already proves the pattern (`hamctxmenu.ad` + `/dev/wsys/ctxmenu`); reuse
   it for the desktop (`user/hamdesktop.ad`: New Folder / Open Terminal /
   Change Wallpaper) and the file manager (`user/hamfmscene.ad`: Open / Rename
   / Delete / Properties). Pairs naturally with gap #1.

3. **Control-center capplets: Keyboard shortcuts, Display, Mouse, Date/Time**
   — *high value, medium effort (per capplet).* The Applications menu already
   points at `/bin/hamset-keyboard`, `/bin/hamset-display`, `/bin/hamset-mouse`
   which **don't exist** — clicking them does nothing. Each is a small scene
   app: write a settings app (`user/hamset-*.ad`) that reads/writes a config
   file consumed by the live system (keybinding table in hamUId, GOP mode,
   pointer accel, RTC). Keyboard-shortcuts first (bindings are currently
   hard-coded and uneditable).

4. **Editor: find/replace + undo (pluma parity)** — *medium value, medium
   effort.* `user/hameditscene.ad` is a usable editor missing the two things
   every editor user expects. Add a find bar + undo ring; syntax highlight is
   a later, larger add.

5. **Terminal: tabs + selection copy/paste** — *medium value, medium effort.*
   `user/hamtermscene.ad` is a solid single-pane terminal. Tabs (multiple
   inner shells, tab strip) and mouse-drag selection → clipboard are the
   visible MATE-terminal gaps. Requires a DE clipboard primitive (see #8).

6. **Image viewer: zoom/rotate + PNG decode** — *medium value, medium/large
   effort.* `user/hamview.ad` decodes PPM/BMP only and can't zoom. Add
   fit/100%/zoom + 90° rotate (small) and a PNG decoder (larger). Needs the
   bitmap `tiles` tier for smooth scaled blits.

7. **System monitor: CPU% + kill-process** — *medium value, medium effort.*
   `user/hammonscene.ad` is read-only and has no CPU%. CPU% needs the kernel
   to expose per-task CPU time (`/proc/<pid>/stat`-shape) — a small kernel
   add — then a kill action writing the proc ctl file. Note: kernel-side
   dependency, brief accordingly.

8. **DE clipboard primitive** — *enabler, small/medium effort.* Several gaps
   (terminal copy/paste, file-manager cut/paste, editor) want a shared
   clipboard. Add a `/dev/wsys/clipboard` (or `/dev/snarf`, Plan 9-style)
   set/get to `sys/.../devwsys.ad`. Low parity value alone, but unblocks #1,
   #4, #5.

9. **Real system tray (StatusNotifier docking)** — *medium value, large
   effort.* `user/hamtray.ad` is notification-history only; apps can't embed
   live status icons. Real tray needs a docking protocol + per-icon scene
   sub-regions. Large; defer until an app actually wants to dock.

10. **Battery/power applet + power-management capplet** — *low value on
    desktop/VM, medium effort.* Matters only on the laptop/NUC HW target.
    Defer until HW power state is readable.

11. **Brightness → real backlight write** — *low value, small effort but
    HW-gated.* `hamosd.ad` has the slider; wire it to an actual backlight
    control once the HW path exists. HW-gated, defer.

12. **Appearance: image wallpaper + themes/fonts** — *low/medium value,
    medium effort.* `hamsettings.ad` does solid-color swatches only. Add an
    image-file wallpaper picker (reuse `lib/filepick.ad`) and a theme/accent
    color setting. Pleasant polish, not blocking.

13. **App-menu search + favorites + `.desktop` scan** — *low/medium value,
    medium effort.* `hamappmenu.ad` is a static hard-coded catalogue. Scan a
    `.desktop`-shape dir, add a type-to-search box and a favorites row.

14. **Calendar timezone / date config; clock format** — *low value, small
    effort.* Pairs with the Date/Time capplet (#3).

15. **Screensaver modes + settings; screenshot region/window mode** —
    *low value, small each.* Polish on already-working apps.

---

## 3. Top 3 next-wave candidates (dispatch these first)

These three together turn the file manager from a viewer into a real Caja and
make the desktop feel like MATE, at the best value-for-effort, and they share
context (file ops + context menus + the clipboard enabler):

1. **Caja file operations** — copy / move / delete / rename / mkdir in
   `lib/hamfmcore.ad` + `user/hamfmscene.ad`. The #1 "real desktop" gap.

2. **Right-click context menus for the desktop and file manager** —
   reuse the working `user/hamctxmenu.ad` + `/dev/wsys/ctxmenu` pattern in
   `user/hamdesktop.ad` and `user/hamfmscene.ad`. Small effort, high
   interaction-model parity; the natural UI surface for wave #1.

3. **Control-center capplets (Keyboard shortcuts first, then Display /
   Mouse / Date-Time)** — implement the `/bin/hamset-*` apps the Applications
   menu already advertises but that don't exist. Each a small scene app
   writing a config consumed by the live system; start with the keyboard
   capplet since WM bindings are currently hard-coded and uneditable.

Optionally fold the small **DE clipboard primitive** (gap #8,
`sys/.../devwsys.ad`) into the same wave — it's a one-file kernel add that
unblocks file-manager cut/paste and later the terminal/editor.
