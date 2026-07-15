# System-wide text selection + X11-style dual clipboard (task #315)

Text handling is baked into the shared backend so it populates everywhere,
rather than each app reinventing it. Two layers:

## 1. `lib/hamtextbox.ad` — the selection + clipboard substrate

The one place that owns editable-text cursor math (since #303) now also owns
selection, hit-testing and clipboard access. Byte-inert for apps that don't
use selection (a box never touches the selection API keeps `_htb_selon == 0`
forever, so `htb_render` draws no highlight and `htb_selection` reports empty).

- **Click-to-position** — `htb_hit_test(x0, buf, n, click_x) -> caret_index`
  is the pixel-exact INVERSE of `htb_caret_x`: it walks the SAME proportional
  glyph advances the compositor draws with and returns the caret index nearest
  the click (left half of a glyph → caret before it, right half → after). A
  click sets the caret THERE (fixes "clicking the input doesn't move the caret
  until you type").

- **Selection model** (managed boxes) — an anchor index + the caret index; the
  selection is `[min(anchor,caret), max)`. `htb_sel_click` sets both (collapse),
  `htb_sel_drag` moves the caret keeping the anchor (extend on click-drag),
  `htb_sel_start/end/active/clear`, and `htb_sel_copy(h, prim)`. Any ordinary
  key fed to `htb_feed` collapses the selection (type/navigate clears it).

- **Highlight render** — `htb_render` draws a `#b4d0f8` band behind the selected
  glyph run (measured with the same advances) before the text.

- **File-backed clipboard** (NO new syscall) — `htb_clip_put(prim, buf, n)` and
  `htb_clip_get(prim, out, cap)` WRITE/READ a Plan 9 file: `prim=0` is the
  CLIPBOARD `/dev/snarf` (Ctrl+C/Ctrl+V), `prim=1` is the X11 PRIMARY selection
  `/dev/snarf.primary` (highlight → middle-click paste).

## 2. The compositor-owned clipboard service — `sys/src/9/port/devsnarf.ad`

Plan 9's clipboard is a FILE. Hamnix already served `/dev/snarf` (a single
64 KiB REPLACE-on-write buffer). #315 adds the X11 PRIMARY selection as a
SECOND, independent file `/dev/snarf.primary` (`primary_buf`/`primary_len`),
same read/REPLACE-write surface. A copy WRITES the file; a paste READS it; the
two buffers are independent (a Ctrl+C into the clipboard never clobbers a live
highlight's PRIMARY). Wired through `sys/src/9/port/namec.ad`
(`DEV_SNARF_PRIMARY`, `#c/snarf.primary`). `devwsys.ad` is UNTOUCHED — the
compositor already forwards window-local pointer events (`m x y buttons dz`,
button bit0=L bit1=R bit2=middle) and raw key bytes to the focused window, so
middle-click, drag-motion, and Ctrl+C/Ctrl+V (bytes 3/22 on `/keys`) need no
new input plumbing.

### Terminal ^C safety

Ctrl+C-as-copy is handled per-app (in the editor / any hamtextbox user), NOT
globally in the compositor, so the terminal's job-control `^C` (SIGINT) is
untouched — each app decides what byte 3 means for its own text region.

## 3. Reference app — `user/hameditscene.ad`

The scene-DE editor is migrated to the substrate: click-to-position caret
(`_ed_hit_offset` maps a pointer to a byte offset via `htb_hit_test` per visual
row), click-drag selection with a visible highlight band, Ctrl+A select-all,
Ctrl+C/Ctrl+V/Ctrl+X on `/dev/snarf`, auto-copy-to-PRIMARY on highlight
release, and middle-click paste of PRIMARY at the click.

## Verification

`scripts/test_hamedit_clipboard.sh` (OVMF/KVM, fresh installer image):
- Hard gate (PASS): editor loads a file, Ctrl+A select-all, Ctrl+C, then the
  shell reads the copied payload back from `/dev/snarf` — the full chain
  (selection + Ctrl+C + `htb_clip_put` + device + cross-process read).
- Screendump `armA_selectall.ppm` shows the blue selection band over the text.
- Direct device probes confirmed `/dev/snarf` and `/dev/snarf.primary` write +
  read independently.

Deferred: (a) terminal scrollback-grid selection (the terminal renders a grid,
not a single text box — the #1 follow-up); (b) automated MOUSE
click-to-position / drag-select / middle-paste confirmation (the infra is in
place and delivered by the compositor, but the DE key/mouse-injection harness
is too timing-sensitive to drive it deterministically — verified by
construction + screendump, not by an automated assertion).
