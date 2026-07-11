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

(`/usr/share/applications/` — the freedesktop standard location — is
Debian-namespace territory today. The parser is a freedesktop subset so a
later change can also scan it for installed Linux apps.)

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

## Code map

- **`lib/desktopentry.ad`** — the pure, extern-free parser (one file's
  contents → parsed fields + category classification). Links into both
  the native panel and the `x86_64-linux` host test target.
- **`user/hampanelscene.ad`** — the LIVE runlevel-5 scene panel. Scans
  the dir at startup (`_load_apps`), builds the flat dropdown, launches
  the parsed `Exec`. Falls back to a built-in set if the dir is empty.
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
