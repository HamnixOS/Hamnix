# Data-driven DE Applications menu

The Hamnix desktop Applications menu is populated from **`.desktop`
files**, not a hardcoded table. Adding an app to the menu is dropping a
file — no code edit, no rebuild of the panel.

## Where the files live

Primary directory: **`/etc/hamde/apps/`** — one `*.desktop` file per app.

The source-of-truth copies live in the tree at `etc/hamde/apps/` and are
staged into every ship vehicle:

- the cpio initramfs (`scripts/build_initramfs.py`)
- the ext4 rootfs image (`scripts/build_rootfs_img.py`)
- the `hamnix-desktop-config` package (`scripts/build_packages.py`)

Secondary directory: **`/n/linux/usr/share/applications/`** — the
freedesktop standard location inside the **Debian/Linux namespace**. The
scene panel also scans this and surfaces the installed Linux apps in a
distinct **"Linux"** menu section (see below).

## File format

A strict, small INI-like subset of the freedesktop Desktop Entry spec.
Only the `[Desktop Entry]` group is read; other groups (e.g.
`[Desktop Action …]`) are ignored.

```ini
[Desktop Entry]
Type=Application          # must be Application (or absent) to appear
Name=2048                 # display label (required)
Exec=/bin/ham2048scene    # command; FIRST token is the program spawned
Icon=ham2048              # optional hint (stored, not required)
Categories=Game;          # freedesktop category list -> one menu section
NoDisplay=false           # NoDisplay=true hides the entry
```

- **`Name`** and **`Exec`** are required; an entry missing either is
  dropped.
- **`Exec`** is split on whitespace; the first token is the program the
  menu spawns. Field codes (`%f %F %u %U %i %c %k`) and extra argv tokens
  are ignored by the launcher (the shipped native apps take no args).
- **`NoDisplay=true`** or a non-`Application` `Type` hides the entry.
- Blank lines and `#` comments are skipped; trailing CR (CRLF files) is
  tolerated.

## Categories → menu sections

`Categories=` is classified to exactly one canonical menu section, in a
fixed priority order so a multi-category app lands deterministically:

| priority | freedesktop token | menu section |
|----------|-------------------|--------------|
| 1 | `Game`        | Games       |
| 2 | `Settings`    | Settings    |
| 3 | `Network`     | Internet    |
| 4 | `System`      | System      |
| 5 | `Utility` / `Accessories` | Accessories |
| — | (none matched) | Other      |

The cascading v2 menu (`hamappmenu`) renders one submenu per section; the
flat scene panel (`hampanelscene`) renders a single list sorted by
`(section, Name)` so apps cluster by section.

## Linux-namespace apps (the "Linux" section)

Installed Debian/Linux apps drop their `.desktop` files at the freedesktop
standard `/usr/share/applications/` **inside the Linux namespace**. The
scene panel exposes them without leaving Plan 9 shape:

1. **Read-bind of `#distro` at `/n/linux`.** `/etc/rc.d/rc.5` sets up the
   panel's namespace with `bind '#distro' /n/linux` — the SAME `#distro`
   file-server primitive `enter linux { bind '#distro' / }` uses, but bound
   under the conventional `/n/` foreign-namespace prefix. This is a
   per-process namespace BIND (Plan 9 shape), not a global Unix mount; the
   panel only ever reads it. The Debian rootfs is then readable at
   `/n/linux/...` (e.g. `/n/linux/usr/share/applications`, `/n/linux/bin`).
   *(Readonly note: `#distro` is exposed for READ; the panel never writes
   it. A general kernel-enforced MRDONLY mount flag does not exist yet — on
   read-only-backed media (the cpio/squashfs dev-boot distro root) the
   backing store refuses writes; a writable ext4-backed `#distro` does not.
   Hardening the bind to reject writes regardless of backing is a
   follow-up.)*

2. **Scan → "Linux" section.** `hampanelscene._load_apps()` scans
   `/n/linux/usr/share/applications/*.desktop` with the SAME tolerant
   `lib/desktopentry.ad` parser, forcing every entry into the distinct
   `DE_CAT_LINUX` category (code 6, sorts LAST → its own section). Full
   freedesktop files are tolerated: extra keys (`Version`, `GenericName`,
   `Keywords`, `MimeType`, `StartupWMClass`, …), localized `Name[xx]`/
   `Comment[xx]` keys (the C-locale `Name` wins), `Terminal=`, and a
   trailing `[Desktop Action …]` group are all handled. Each entry's menu
   label carries a light ` (linux)` namespace tag (informative, not a
   capability warning).

3. **Launch inside `enter linux`.** Selecting a Linux row routes through
   `_launch_linux()`, which spawns `/bin/hamsh /etc/rc.de-wayland <Exec>`
   — the exact launcher that already renders weston-terminal / Xwayland /
   Qt clients as real windows on the native Wayland server. hamsh stamps
   `HAMNIX_DE_PROG=<Exec>`; the recipe captures the `linux` ns template,
   drops privilege, sets the Wayland env, and runs
   `enter linux { $HAMNIX_DE_PROG }`. Launch is DETACHED (the panel never
   `wait4`s). GUI Linux apps render through the Wayland passthrough; only
   Firefox/Chromium-class browsers are parked (their SW-WebRender thread
   needs a GL/EGL stack). CLI (`Terminal=true`) apps run headless.

A default debootstrap minbase ships no `.desktop` files, so
`scripts/build_rootfs_img.py` plants one demonstrable entry
(`usr/share/applications/hamnix-linux-demo.desktop`, a `busybox top`
process viewer) into the distro tree so the "Linux" section is always
populated and the discover→bind→launch path is exercised on a stock image.

## Code map

- **`lib/desktopentry.ad`** — the pure, extern-free parser (one file's
  contents → parsed fields + category classification). Links into both
  the native panel and the `x86_64-linux` host test target.
- **`user/hampanelscene.ad`** — the LIVE runlevel-5 scene panel. Scans
  BOTH `/etc/hamde/apps` (native) and `/n/linux/usr/share/applications`
  (Linux ns, forced into the `DE_CAT_LINUX` section) at startup via the
  shared `_scan_apps_dir` helper (`_load_apps`), builds the flat dropdown,
  and launches the parsed `Exec` — native apps directly, Linux apps via
  `_launch_linux` → `enter linux`. Falls back to a built-in native set if
  the native dir is empty; the Linux section is additive.
- **`user/hamappmenu.ad`** — the v2 cascading menu. Scans the dir
  (`_seed_catalogue` → `_dd_scan`), grouping apps into category flyouts,
  then appends the Run/Lock/Log Out session verbs. Legacy-table fallback.
- **`user/hamde.ad`** — the hamui-toolkit panel. Registers one menu item
  per `.desktop` file; the event loop maps the clicked item to its
  `Exec`. Fallback set retained.

## Tests

- `scripts/test_desktopentry_host.sh` — fast, QEMU-free host unit gate:
  compiles the parser + harness for `x86_64-linux`, feeds in-memory
  fixtures, asserts Name/prog/category/reject behaviour.
- `scripts/test_de_appmenu_datadriven.sh` — structural gate: every
  consumer imports the parser + scans the dir + compiles native; each
  shipped `.desktop` maps to a built binary; the dir is staged into all
  three images.
- `scripts/test_de_scene_render.sh` (KVM/OVMF) — boots the DE, opens the
  Applications menu, and asserts the dropdown exposes app rows
  (`Terminal`/`Files`), which now come from the `.desktop` catalogue.

## Adding an app

Drop `etc/hamde/apps/<app>.desktop` with a `Name`, an `Exec` pointing at
a built binary, and a `Categories` line. Rebuild the image. Done — the
app appears in the menu and launches. No panel code changes.
