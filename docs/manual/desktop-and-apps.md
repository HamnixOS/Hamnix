# Desktop & Apps

Hamnix boots to a MATE/GNOME2-style desktop: a panel across the top, an
Applications menu in the corner, virtual workspaces, and a set of built-in apps.
This page tours the desktop and then describes every app with its real controls.

## The desktop

### The Applications menu

Top-left of the panel is the **Applications** menu. Open it and you get a single
column with:

- A **search box** at the top — start typing to filter the whole app list live.
  Press Enter to launch the first match, or Escape to dismiss.
- A **Recent** section listing apps you've launched lately.
- Apps grouped under **category headers** (Accessories, Graphics, Internet,
  Office, Games, System, Settings, …). Categories with a **">" chevron** open a
  **hover fly-out** to the right when you point at them.

The menu is built from the app definitions in `/etc/hamde/apps/*.desktop`, so it
reflects exactly what's installed.

### The panel

The panel carries a live **clock**; click it to pop up a small **calendar**.
**Right-click the panel** for its menu, which includes **"Add to Panel…"** (a
searchable chooser to drop applets or launchers onto the panel) and
**Properties**. A **workspace switcher (pager)** sits on the panel showing your
four workspaces as clickable cells.

### Workspaces

There are **four virtual workspaces**. Switch between them with:

- **Ctrl+Alt+Left / Ctrl+Alt+Right** — move to the adjacent workspace (wraps
  around).
- **Ctrl+Alt+Shift+Left / Right** — move the focused window to the adjacent
  workspace and follow it there.
- Or just **click a cell** in the panel's workspace switcher.

### The desktop backdrop

**Right-click the desktop** background for a menu with **Open Terminal**, **New
Folder**, **Open File Manager**, and **Change Background**.

### Global shortcuts worth knowing

- **Ctrl+Alt+T** — open a Terminal.
- **Ctrl+Alt+Left / Right** — switch workspace.
- **Alt+Tab** — cycle between windows.
- **Alt+F4** — close the focused window.

> If a shortcut ever doesn't respond on your build, every one of these actions
> also has a menu path (the Applications menu, the panel, or the desktop
> right-click menu), so you're never stuck.

## The apps

Launch any of these from the Applications menu. Windows can be moved, resized,
and closed like any desktop.

### Web Browser (`hambrowse`)

A native graphical web browser — it has its own HTML/CSS engine and font
rendering, no external browser involved.

- **Address bar** with **Back** and **Forward** buttons and a **Go** button.
  Click the address bar to type a URL, then press Enter or click Go. A bare host
  name becomes `http://…`; Escape cancels an edit.
- Loads **`http://`** and **`https://`** pages over the network, as well as
  **local files** (a path, or a `file://` URL). Running `hambrowse` with no
  argument shows a built-in demo page.
- Renders real pages: headings, paragraphs, lists, tables, links, bold/italic,
  inline and linked CSS (text and background colors), and **images** — PNG,
  JPEG, GIF, and SVG are all decoded on-device. Simple forms and some
  JavaScript work too.
- **Scrolling / navigation keys** (when the address bar isn't focused): `j` or
  Down scroll down, `k` or Up scroll up, Space or `f` page down, `b` page up,
  `g` jump to top, `G` jump to bottom. The mouse wheel scrolls; clicking a link
  follows it. Back/forward keep a real session history.
- There is currently **no bookmarks** feature.

### Files (`hamfmscene`)

A Caja-style file manager.

- **Double-click a folder** to open it; double-click a file to open it in the
  right app for its type.
- **Right-click a file or folder** for a context menu (Rename, Delete, and clip
  operations). **Right-click empty space** for a shorter menu with **New
  Folder** and **New File** and Paste.
- New Folder and Rename open an **inline text prompt**; Delete asks for
  confirmation first.

### Editor (`hameditscene`)

A plain-text editor.

- Opens the file you pass it (or start empty). Arrow keys move the caret; type
  to edit.
- **Ctrl+S** saves back to the file. If it was opened without a path, Ctrl+S
  opens a **Save-As** file chooser.
- **Ctrl+O** opens a file; **Ctrl+W** brings up the file chooser too. A status
  line reports things like "saved N bytes" (and surfaces write failures
  honestly).

### Notes (`hamnotesscene`)

A quick multi-note scratchpad.

- **Ctrl+N** starts a new note; **Ctrl+S** saves the current one; the **`<` and
  `>`** toolbar buttons switch between your notes.
- Notes are stored in your home directory, so they **survive a reboot**, and
  edits autosave so nothing is lost between explicit saves.

### Calculator (`hamcalcscene`)

An on-screen calculator. Click the buttons, or use the keyboard: digits,
operators, `=`, `.`, `%`, sign change, `C` to clear, and Backspace.

### Calendar (`hamcalscene`)

More than a wall calendar:

- A **month grid** (6×7) with **today highlighted** and a **selected day** you
  can move. **Arrow keys** move the selection — Left/Right by a day, Up/Down by
  a week — and crossing a month boundary flips the visible month.
- A **relative-time readout** for the selected day: "today", "N days ago", or
  **"in N days"**.
- A built-in **stopwatch** with **Start / Stop / Reset**.

### 2048 (`ham2048scene`)

The slide-the-tiles puzzle. Move with the **arrow keys or WASD**; press **`n`**
for a new game. You can also click the on-screen buttons.

### System Monitor (`hammonscene`)

A live view of system resources: **uptime** (H:MM:SS), a **memory** meter
showing used/total (from `/proc/meminfo`), and a **process list** — one row per
task with its pid, state, and name (from `/proc/tasks`).

### Log Viewer (`hamlogscene`)

Browses the kernel log (`/proc/kmsg`, the same source as `dmesg`). Scroll with
the mouse wheel or by clicking, and it supports a **follow / tail** mode that
periodically re-reads the ring and jumps to the newest lines.

### Screenshot (`hamshot`)

Captures the screen and saves a **timestamped PNG** into your **Pictures**
folder (`~/Pictures/screenshot-<time>.png`), then posts a desktop notification
that the shot was saved.

### Terminal (`hamtermscene`)

Opens a window running the `hamsh` shell. See
[Terminal, Shell & Users](terminal-and-users.md) for what you can do there. The
fastest way to get one is **Ctrl+Alt+T**.

### Control Center (`hamctl`)

The settings hub. Its panels:

- **Appearance** — pick a wallpaper color or image; your choice is remembered.
- **Date & Time** — shows the current time and lets you set a UTC hour offset
  (your time zone); remembered.
- **Display** — shows the framebuffer resolution and pitch; lets you set a
  scale.
- **Mouse** — pointer **speed**, **primary button** (left/right swap), and
  **natural scroll**. Changes take effect **immediately** (no reboot).
- **Keyboard** — shows the layout and lets you set key **repeat delay** and
  **rate**.
- **Sound** — honestly reports that there's no audio device yet; volume/mute
  preferences are recorded but not yet applied.
- **Network** — shows your address, mask, gateway, and DNS, and lets you pick a
  **DNS server** (8.8.8.8 or 1.1.1.1), applied live to the resolver.
- **About** — hostname, Hamnix version, kernel, uptime, memory, CPU count, and
  process count.
- **Power / Session** — Lock, Log Out, Shut Down, and Reboot.

> Control Center currently stores its preferences under `/tmp/hamnix-*.conf` and
> re-applies them at login, so a couple of settings are re-applied rather than
> stored permanently on disk.

### Install Hamnix (`haminstallui`)

Only present on the live image. It installs Hamnix to a disk — see
[Installing Hamnix](installation.md).
