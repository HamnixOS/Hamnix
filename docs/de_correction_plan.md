# DE correction plan (2026-06-15)

Orchestrator's plan to fix the desktop environment. Grounded in the
architecture analysis: the compositor model (per-window backbuffer +
z-ordered compositor blit) is correct, but the implementation is a
half-finished pivot with structural flaws that produce every observed
symptom (apps/menu/terminal don't render, cursor FPS collapses on any
interaction, cursor punches holes in panels, panels flicker).

## Root problems → symptoms

- **P1 — Privilege-gated draw path.** A window's backbuffer write goes
  through `/dev/wsys/<wid>/{data,wctl}`, and the `version 2` negotiation is
  hostowner-gated. A window spawned from a service/non-hostowner namespace
  (panels, menu, terminal, every app) can't write its buffer → stays blank.
  → **apps/menu/terminal don't render.** THE keystone.
- **P2 — Two coexisting render paths.** Legacy procedural `daemon_pixel`/
  `window_render_self` cascade still runs alongside the v2 backbuffer blit.
  Interactive overlays (menu, rubber-band) fall in the gap; the cursor erase
  exposes the procedural layer and the v2 re-blit lags.
  → **on-demand overlays don't paint; cursor holes the panel; panel flicker.**
- **P3 — Serial present loop, no cursor decoupling.** One loop does
  input→composite→scanout; heavy composite starves the cursor.
  → **cursor FPS collapses on any click/drag** (rubber-band throttle only
  patched one case).
- **P0 — Compositor doesn't drain injected `/dev/mouse`.** Localized by the
  consolidation agent: `/dev/mouse` writes land in the auxmouse ring (NOT
  blocked by the wid-less-ctl bug), but the compositor's read loop doesn't
  drain/apply them during a gate run (`presents` stays at the 1 Hz clock
  tick). → **can't drive clicks/drags to verify any fix; possibly part of
  the real input jank.**

## Phased corrections

**Phase 0 — input-drive unblock (verification keystone).**
Fix the compositor's `/dev/mouse` read/drain so injected absolute events
move the cursor + dispatch clicks. Without this we are blind — every later
fix needs to drive input + screendump to verify. Pin whether the compositor
reads a different source than `/dev/mouse` for real input, and why injected
events aren't drained.

**Phase 1 — privilege-free draw path (keystone for rendering).**
Make `/dev/wsys/<wid>/{data,wctl}` writable by the window's OWNER regardless
of hostowner/namespace, so any spawned window can paint. This single fix
unblocks apps/menu/terminal rendering. Verify by spawning hamclock/hamterm
from the gate and screendumping a real window.

**Phase 2 — one render path (finish the v2 pivot).**
Make EVERY surface (panels, menu, rubber-band, desktop) a client-buffer
blit. Delete the legacy `daemon_pixel`/`window_render_self` procedural
cascade. Removes the seams: panel holes, flicker, on-demand-overlay gap.
Large; stage it (one surface class at a time, screendump-verified).

**Phase 3 — cursor decouple + present loop.**
Cursor on its own fast path (independent blit / hardware cursor), never
serialized behind scene composite. Fixes FPS collapse on ALL interactions.

**Phase 4 — redundancy removal (audit §A.3–A.5).**
Kill the dual panel (`hamde.svc`), externalise the in-compositor
`APP_CALC/SYSMON/FILEMGR/EDITOR` duplicates, drop the legacy `MENU_OPEN`.

## Execution order

P0 + P1 first, in parallel (disjoint: P0 = hamUId input-read loop; P1 =
devwsys/namec write-permission). Then P2 (staged) with P3. P4 cleanup last.
Every phase verified by driving input + VIEWING the framebuffer PNG, not
markers (the gate's render check is already pixel-diff hardened, ca90bcb4).
