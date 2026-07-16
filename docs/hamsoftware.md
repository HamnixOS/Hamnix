# Software (hamsoftware) — the graphical package manager

`hamsoftware` (`/bin/hamsoftware`, menu name **Software**) is the desktop
"nice version of Synaptic": a native hamUI scene application that is a **GUI
front-end over the existing native `hpm` package manager** (`user/hpm.ad`).
hpm stays the engine — `hamsoftware` never fetches, resolves or installs
anything itself. It shells out to `/bin/hpm` and pipes hpm's plain-text output
into a pure, extern-free UI core.

It is the richer sibling of `hampkgscene` ("Package Manager"): same shared core,
plus a **category sidebar**. The Software menu entry now launches `hamsoftware`;
`hampkgscene` remains as the sidebar-less variant / core exerciser.

## Panes and widgets

```
+----------------------------------------------------------------------+
|  [icon] Software                                    (header bar)      |
|  Find [ search packages...                     ]   (live filter box) |
|  [Refresh] [Install] [Remove] [Upgrade]            (action toolbar)  |
+------------+---------------------------------+---------------------- +
| All      6 | hamnix-base        [installed]  |  hambrowse            |
| Installed 3| core system base                |  State: installed     |
| Available 3| hambrowse          [upgrade]    |  Version: 0.9         |
| Upgradable1| native web browser              |  Size:    512000      |
|  (sidebar) | ... (scrollable package list)   |  Target:  #hamnix-... |
|            |                                 |  Depends: ...         |
|            |                                 |  Description: ...     |
+------------+---------------------------------+---------------------- +
|  6 packages in the index                           (status line)     |
+----------------------------------------------------------------------+
```

- **Category sidebar** (left rail) — `All`, `Installed`, `Available`,
  `Upgradable`, each with a live count. Clicking one filters the list; it
  intersects with the search text.
- **Package list** (centre, scrollable) — one row per package: bold name, short
  description, and a state badge (`installed` green / `available` grey /
  `upgrade` orange when a newer version exists). Wheel-scrolls; a click selects.
- **Search / filter box** (toolbar) — reuses the shared text-box substrate
  (`lib/hamtextbox.ad`); case-insensitive match over name + description, live.
- **Detail pane** (right) — the selected package's name, installed state,
  version, size, target root and dependency list, parsed from `hpm show`.
- **Action toolbar** — Refresh / Install / Remove / Upgrade. Install is enabled
  only for a not-installed selection, Remove only for an installed one.
- **Status line** — progress and the last line of hpm's output.

## How it talks to hpm (the seam)

The native driver (`user/hamsoftware.ad`) owns the Hamnix transport (a `wsys`
window + `/keys` + `/event` drain) and spawns `/bin/hpm` over a pipe, feeding
each output line to the pure parsers in `lib/hampkgcore.ad`:

| UI action        | hpm command(s) invoked                              |
|------------------|-----------------------------------------------------|
| initial load     | `hpm search ""` (all available) + `hpm list`        |
| Refresh          | `hpm refresh`, then reload the index                |
| row select       | `hpm show <name>`  → detail pane                    |
| Install          | `hpm install <name>`, then re-read `hpm list`       |
| Remove           | `hpm remove <name>`,  then re-read `hpm list`       |
| Upgrade          | `hpm update` (world upgrade)                        |

This is **real data**: the package list, installed badges and detail pane are
all parsed from live hpm output at runtime — nothing is hardcoded in the app.

- `hpm search ""` prints `"<name>  <version>  -  <description>"` → the model.
- `hpm list` prints `"<name>  <version>  <target>"` → sets the *installed* flag,
  and, by comparing the installed version against the available version, the
  *upgradable* flag (this is how the **Upgradable** category is computed — hpm
  has no dedicated "outdated" query, so it is derived from `list` vs `search`).
- `hpm show <name>` prints `"key: value"` lines → the detail pane.

### Privilege

`install` / `remove` / `update` are hostowner-gated inside hpm (uid 1). Run
unprivileged, hpm prints e.g. `hpm: package installation requires hostowner.`
— the button still invokes the real command and that message is surfaced
verbatim in the status line. The UI never fakes success and never re-implements
the privilege check.

## Registration

`etc/hamde/apps/packagemanager.desktop` (and the `etc/skel/Desktop` copy) launch
`/bin/hamsoftware` under `Categories=System;Administration;` with `Name=Software`,
so it appears in the DE Applications menu under **System**. The binary ships in
the `hamnix-hampkg` package (`scripts/build_packages.py`), built by
`scripts/build_user.sh`.

## Dual-target / testing

`lib/hampkgcore.ad` is extern-free, so the whole UI renders on the dev host with
no QEMU. `user/hamsoftware_host.ad` feeds the same core a fixture index and
rasterizes to PNGs via `lib/hamui_host.ad`. The gate
`scripts/test_hamsoftware_host.sh` compiles both targets and asserts, off the
scene grammar + rastered pixels: a non-blank frame; the header/search/toolbar;
all four sidebar categories with correct counts (`All 6 / Installed 3 /
Available 3 / Upgradable 1`); the sidebar hit-test selecting a category and
narrowing the list; the installed/available/upgrade badges; a list-row click
(offset past the sidebar) selecting a package; and the detail-pane fields.

Note (per `feedback_host_preview_monospace_lies`): the host preview renders
monospace and misrepresents proportional text X-positions, so the gate asserts
structure/presence, not exact caret/label pixel-X. Precise text layout is a
device / unit concern, not a host-PNG one.
