#!/usr/bin/env python3
"""scripts/render_hambrowse_png.py — turn a hambrowse host-harness dump into a
PNG that faithfully mirrors what the NATIVE browser (user/hambrowse.ad `emit()`)
paints: the window chrome (title bar + address bar + status bar + scrollbar)
plus the page content (styled segments + heading/hr rules).

This is a DEV VISUALIZER only. It never ships and is not part of the engine; it
exists so the shared parse+layout+colour engine and the chrome can be eyeballed
on the host with no QEMU. It reads the SEG/SEGM/ROWA/RULE/LAYOUT/TITLE lines the
host harness (user/hambrowse_host.ad) prints.

TEXT is drawn at its TRUE CSS font-size with PROPORTIONAL TrueType advance: the
engine emits per-segment font metrics on SEGM lines (px font-size, line-height,
baseline y-offset, face id) and per-row text-align on ROWA lines, so a heading
renders BIG (like a real browser) and center/right rows are re-centred at the
real proportional width instead of the 8px mono estimate the engine laid out on.
The window chrome (title/address/status/Go) stays on the fixed CELL_W=8 grid.

IMPORTANT: the engine's display-list dump is laid out on an 8px CHAR GRID with no
proportional line-reflow, so this preview shows WHAT THE ENGINE LAID OUT at true
size — it is NOT a Chrome-parity render. For pixel parity use the real painter
harness (user/hambrowse_host_gfx.ad -> scripts/framediff_gfx_run.sh). Rows are
placed on CONTENT_Y=38 + row*LINE_H=16 (the engine reserves extra rows for tall
line boxes); older dumps without SEGM/ROWA fall back to face defaults.

USAGE
  hambrowse_host FILE.html 600 | \
      python3 scripts/render_hambrowse_png.py out.png [--url URL] [--title T]
  # or
  python3 scripts/render_hambrowse_png.py out.png --dump dump.txt [...]
"""
import sys
from PIL import Image, ImageDraw, ImageFont

# ---- geometry (mirror lib/htmlengine.ad + user/hambrowse.ad) --------------
TITLE_H, ADDR_H, ADDR_Y = 18, 20, 18
CONTENT_X, CONTENT_Y = 8, 38
STATUS_H, LINE_H, CELL_W, GO_W = 16, 16, 8, 30

# chrome palette (mirror emit())
C_PAGE       = "#ffffff"
C_TITLEBAR   = "#2f5b86"   # title bar
C_TITLETXT   = "#ffffff"
C_ADDRBAR    = "#e7ebf0"   # address strip
C_ADDRBORDER = "#9aa5b1"
C_ADDRFOCUS  = "#1a4fd0"
C_ADDRTXT    = "#101010"
C_GOBTN      = "#3a6ea5"
C_STATUSBAR  = "#eef1f4"
C_STATUSTXT  = "#3a4654"
C_STATUSTOP  = "#d4dae1"   # 1px separator above status bar
C_TITLESEP   = "#1f3f5e"
C_RULE_HEAD  = "#14306e"
C_RULE_HR    = "#c2cad3"
C_SCROLLTRK  = "#e4e7ec"
C_SCROLLTHUMB= "#9aa5b1"

S = 2  # supersample factor for crisp output

_FONT_DIR = "/usr/share/fonts/truetype/dejavu/"
# Proportional sans (mirrors the browser default UA sans) + monospace for
# <pre>/table faces where fixed-cell alignment must be preserved.
_FONT_FILES = {
    (False, False, False): "DejaVuSans.ttf",             # sans
    (False, True,  False): "DejaVuSans-Bold.ttf",
    (False, False, True):  "DejaVuSans-Oblique.ttf",
    (False, True,  True):  "DejaVuSans-BoldOblique.ttf",
    (True,  False, False): "DejaVuSansMono.ttf",          # mono (face==1)
    (True,  True,  False): "DejaVuSansMono-Bold.ttf",
    (True,  False, True):  "DejaVuSansMono-Oblique.ttf",
    (True,  True,  True):  "DejaVuSansMono-BoldOblique.ttf",
}
_font_cache = {}


def _font(px, bold=False, italic=False, mono=False):
    """A TTF face at CSS pixel size `px` (in supersampled units), cached."""
    px = max(6, int(round(px)))
    key = (px, bold, italic, mono)
    f = _font_cache.get(key)
    if f is None:
        f = ImageFont.truetype(_FONT_DIR + _FONT_FILES[(mono, bold, italic)], px)
        _font_cache[key] = f
    return f


# Face id (seg_face 0..7) -> (mono?, bold?, fallback CSS px) when SEGM gives no
# explicit pxsize. Mirrors the native paint hierarchy in lib/htmlpaint.ad.
_FACE_DEFAULT = {
    0: (False, False, 16),   # body sans
    1: (True,  False, 16),   # monospace (pre/tables/code)
    2: (False, True,  32),   # h1
    3: (False, True,  24),   # h2
    4: (False, False, 19),   # h3
    5: (False, True,  16),   # h4
    6: (False, True,  13),   # h5
    7: (False, False, 11),   # h6
}


def _load_chrome_font():
    """Fixed 8px-cell mono font for the WINDOW CHROME (title/address/status/Go)
    — the chrome is a fixed-cell strip in the native front-end, so it stays on
    the CELL_W grid regardless of page-content font metrics."""
    for size in range(20, 8, -1):
        f = ImageFont.truetype(_FONT_DIR + "DejaVuSansMono.ttf", size)
        if f.getlength("0") <= CELL_W * S:
            fb = ImageFont.truetype(_FONT_DIR + "DejaVuSansMono-Bold.ttf", size)
            return f, fb
    f = ImageFont.truetype(_FONT_DIR + "DejaVuSansMono.ttf", 12)
    fb = ImageFont.truetype(_FONT_DIR + "DejaVuSansMono-Bold.ttf", 12)
    return f, fb


def parse_dump(text):
    width = 600
    segs = []      # (row, x, color, bold, uline, link, bg, text, italic)
    fills = []     # (top, bot, lx, rx, color, z) — element background boxes
    rules = {}     # row -> type
    title = None
    page_bg = None  # <body>/<html> page-level background (whole viewport)
    italic_idx = set()   # seg indices flagged faux-oblique by a SEGIT line
    metrics = {}    # seg index -> (pxsize, lineh, yoff, face) from SEGM lines
    row_align = {}  # row -> 2 (center) / 3 (right) from ROWA lines
    for line in text.splitlines():
        if line.startswith("ROWA "):
            p = line.split()
            row_align[int(p[2])] = int(p[4])
        elif line.startswith("SEGM "):
            p = line.split()
            idx = int(p[1])
            px = lh = yo = fc = 0
            for tok in p[2:]:
                if tok.startswith("px"):
                    px = int(tok[2:])
                elif tok.startswith("lh"):
                    lh = int(tok[2:])
                elif tok.startswith("yo"):
                    yo = int(tok[2:])
                elif tok.startswith("f"):
                    fc = int(tok[1:])
            metrics[idx] = (px, lh, yo, fc)
        elif line.startswith("SEGIT "):
            italic_idx.add(int(line.split()[1]))
        elif line.startswith("PAGEBG "):
            page_bg = line.split()[1]
        elif line.startswith("LAYOUT "):
            for tok in line.split():
                if tok.startswith("width="):
                    width = int(tok[6:])
        elif line.startswith("TITLE "):
            title = line[6:]
        elif line.startswith("FILL "):
            # FILL top bot lx rx #rrggbb [rad] [z] [padt] [padb] [b<col>] — an
            # element background rect. `z` is the stacking key (default 0); a
            # CONTAINER's own background is graded to a negative z so it paints
            # BEHIND the descendant fills it encloses, mirroring the z-sort in
            # lib/htmlpage.ad. `padt`/`padb` are the top/bottom PADDING-box pixel
            # extensions the engine grows onto the fill so a padded coloured panel
            # (nav bar / hero) covers its vertical padding like a real browser —
            # without them a `padding:8px` nav bar renders 16px shorter than
            # chrome/firefox. Older dumps omit the trailing fields (default 0).
            p = line.split()
            fz = int(p[7]) if len(p) > 7 else 0
            padt = int(p[8]) if len(p) > 8 else 0
            padb = int(p[9]) if len(p) > 9 else 0
            fills.append((int(p[1]), int(p[2]), int(p[3]), int(p[4]), p[5], fz,
                          padt, padb))
        elif line.startswith("RULE row "):
            p = line.split()
            rules[int(p[2])] = int(p[4])
        elif line.startswith("SEG "):
            # SEG row x #rrggbb b0 u0 [s0] l-1 bg#ffffff |text|
            # Parse the flag fields by prefix rather than fixed index so the
            # renderer tolerates optional fields (e.g. the s<strike> flag that
            # the engine emits between u<uline> and l<link>).
            head, _, rest = line.partition(" |")
            p = head.split()
            row, x = int(p[1]), int(p[2])
            color = p[3]
            bold = uline = link = 0
            bg = None
            for tok in p[4:]:
                if tok.startswith("bg"):
                    bg = None if tok[2:] == "-" else tok[2:]
                elif tok.startswith("b"):
                    bold = int(tok[1:])
                elif tok.startswith("u"):
                    uline = int(tok[1:])
                elif tok.startswith("l"):
                    link = int(tok[1:])
            text = rest[:-1] if rest.endswith("|") else rest
            segs.append((row, x, color, bold, uline, link, bg, text))
    # Fold the SEGIT flags + SEGM metrics in by seg index (SEG lines are dumped
    # in index order, so the Nth appended seg is engine seg N). Older dumps carry
    # no SEGM lines -> metrics default to (0,0,0,0) and the renderer falls back to
    # face defaults / body size, staying backward-compatible.
    segs = [s + (1 if i in italic_idx else 0,) + metrics.get(i, (0, 0, 0, 0))
            for i, s in enumerate(segs)]
    return width, segs, rules, title, fills, page_bg, row_align


def render(text, out_path, url="about:demo", win_title="Browser",
           status="demo page", max_rows=None):
    width, segs, rules, ptitle, fills, page_bg, row_align = parse_dump(text)
    total_rows = (max(([r for (r, *_ ) in segs] + list(rules.keys())),
                      default=0) + 1)
    if max_rows:
        total_rows = min(total_rows, max_rows)
    page_h = CONTENT_Y + total_rows * LINE_H + STATUS_H
    W, H = width * S, page_h * S
    img = Image.new("RGB", (W, H), C_PAGE)
    d = ImageDraw.Draw(img)
    chrome_font, chrome_fontb = _load_chrome_font()

    def rect(x, y, w, h, col):
        d.rectangle([x * S, y * S, (x + w) * S - 1, (y + h) * S - 1], fill=col)

    def hline(x0, y, x1, col, thick=1):
        d.rectangle([x0 * S, y * S, x1 * S - 1, (y + thick) * S - 1], fill=col)

    # ---- fixed-cell mono glyphs for the WINDOW CHROME only -------------------
    def glyphs(x, y, s, col, bold=False):
        fnt = chrome_fontb if bold else chrome_font
        cx = x * S
        for ch in s:
            d.text((cx, y * S), ch, font=fnt, fill=col)
            cx += CELL_W * S

    # ---- proportional, true-size page text ----------------------------------
    def text_width(s, px, bold=False, italic=False, mono=False):
        """Advance width (device px) of run `s` at CSS pixel size `px`."""
        if not s:
            return 0
        if mono:
            return len(s) * CELL_W * S
        return _font(px * S, bold, italic, mono).getlength(s)

    def page_text(x_css, row, s, col, px, bold=False, italic=False,
                  mono=False, yoff=0):
        """Draw a page-content run at its TRUE font size with proportional
        advance. `x_css` is the engine's laid-out left edge (CELL_W grid); the
        run's baseline is top-anchored into the line box that starts at the
        segment's row so a heading grows DOWN into the extra rows the engine
        reserved for it (matching real browser line boxes)."""
        if not s:
            return
        fnt = _font(px * S, bold, italic, mono)
        row_top = (CONTENT_Y + row * LINE_H) * S
        asc, desc = fnt.getmetrics()
        # Top-anchor the glyph box to the row top (engine reserves >=1 row and
        # extra rows for tall line boxes), nudged by the engine baseline yoff.
        top = row_top + yoff * S
        if mono:
            cx = x_css * S
            for ch in s:
                d.text((cx, top), ch, font=fnt, fill=col)
                cx += CELL_W * S
        else:
            d.text((x_css * S, top), s, font=fnt, fill=col)
        return asc + desc

    # ---- content background (page-level <body>/<html> bg, or white) ----
    rect(0, CONTENT_Y, width, total_rows * LINE_H, page_bg or C_PAGE)

    # ---- element backgrounds (behind the whole box, under the text) ----
    # Paint in STABLE z-index order (mirror lib/htmlpage.ad): lower z first, so a
    # container's negative-z background lands BEHIND the descendant fills (item
    # chips) it encloses, and positioned boxes' explicit z-index still wins.
    for (ftop, fbot, lx, rx, col, fz, padt, padb) in sorted(
            fills, key=lambda f: f[5]):
        if ftop >= total_rows:
            continue
        fb = min(fbot, total_rows)
        # Grow the fill by the engine-emitted vertical padding so a padded panel
        # (nav bar, hero) covers its padding box, matching real browsers.
        y = CONTENT_Y + ftop * LINE_H - padt
        h = (fb - ftop) * LINE_H + padt + padb
        if h > 0 and rx > lx:
            rect(lx, y, rx - lx, h, col)

    # ---- title bar ----
    rect(0, 0, width, TITLE_H, C_TITLEBAR)
    hline(0, TITLE_H - 1, width, C_TITLESEP)
    glyphs(6, 3, "hambrowse", C_TITLETXT, bold=True)
    if ptitle:
        # right-aligned page title in the bar
        t = ptitle[:40]
        tx = width - GO_W - len(t) * CELL_W - 6
        if tx > 90:
            glyphs(tx, 3, t, "#cdddf0")

    # ---- address bar ----
    rect(0, ADDR_Y, width, ADDR_H, C_ADDRBAR)
    go_x = width - GO_W
    box_x = 6
    box_w = go_x - 8 - box_x
    rect(box_x, ADDR_Y + 3, box_w, ADDR_H - 6, C_ADDRBORDER)
    rect(box_x + 1, ADDR_Y + 4, box_w - 2, ADDR_H - 8, "#ffffff")
    amax = (box_w - 8) // CELL_W
    glyphs(box_x + 5, ADDR_Y + 5, url[:amax], C_ADDRTXT)
    rect(go_x, ADDR_Y + 3, GO_W, ADDR_H - 6, C_GOBTN)
    glyphs(go_x + 7, ADDR_Y + 5, "Go", "#ffffff")

    # ---- proportional re-centre pass (mirror lib/htmlpage.ad _hpg_align_pass) --
    # The engine centres/right-aligns a row on the 8px CELL_W grid, but we flow
    # real proportional advances (a big <h1> is far wider than the grid guess), so
    # a grid-centred heading would overflow the window. For each center/right row
    # re-derive the row shift from the TRUE measure: gridw = mono span the engine
    # used, realw = summed proportional width; center shifts by (gridw-realw)/2,
    # right by (gridw-realw). Left/unaligned rows keep the engine's x exactly.
    row_xshift = {}
    if row_align:
        acc = {}  # row -> [gx0, gx1, realw]
        for (row, x, color, bold, uline, link, bg, txt, italic,
             pxsize, lineh, yoff, face) in segs:
            if row_align.get(row) not in (2, 3):
                continue
            f_mono, f_bold_default, f_px = _FACE_DEFAULT.get(face,
                                                             (False, False, 16))
            px = pxsize if pxsize > 0 else f_px
            rbold = bool(bold) or (f_bold_default and pxsize == 0)
            rw = text_width(txt, px, rbold, bool(italic), f_mono) / S
            gx1 = x + len(txt) * CELL_W
            a = acc.get(row)
            if a is None:
                acc[row] = [x, gx1, rw]
            else:
                a[0] = min(a[0], x); a[1] = max(a[1], gx1); a[2] += rw
        for row, (gx0, gx1, realw) in acc.items():
            gridw = gx1 - gx0
            if row_align[row] == 2:
                row_xshift[row] = (gridw - realw) / 2.0
            else:
                row_xshift[row] = gridw - realw

    # ---- content segments (TRUE font size + proportional advance) ----
    for (row, x, color, bold, uline, link, bg, txt, italic,
         pxsize, lineh, yoff, face) in segs:
        x = int(round(x + row_xshift.get(row, 0)))
        if row >= total_rows:
            continue
        y = CONTENT_Y + row * LINE_H
        # Resolve the run's CSS pixel size + face. The engine emits pxsize in
        # SEGM (0 = "use face default"); fall back to the face hierarchy so old
        # dumps (no SEGM) still render a sane size.
        f_mono, f_bold_default, f_px = _FACE_DEFAULT.get(face, (False, False, 16))
        px = pxsize if pxsize > 0 else f_px
        mono = f_mono                       # only face==1 keeps fixed-cell grid
        rbold = bool(bold) or (f_bold_default and pxsize == 0)
        # Inline background highlight sized to the run's real advance width.
        if bg:
            w_px = int(round(text_width(txt, px, rbold, bool(italic), mono) / S))
            rect(x, y, max(w_px, 1), LINE_H, bg)
        page_text(x, row, txt, color, px, bold=rbold, italic=bool(italic),
                  mono=mono, yoff=yoff)
        if uline:
            uw = int(round(text_width(txt, px, rbold, bool(italic), mono) / S))
            hline(x, y + LINE_H - 2, x + uw, color)

    # ---- rules (span the centred measure, not the full window) ----
    MEASURE_MAX = 584
    avail = width - 2 * CONTENT_X
    gutter = 0 if avail <= MEASURE_MAX else (avail - MEASURE_MAX) // 2
    left = CONTENT_X + gutter
    right = width - CONTENT_X - gutter
    for row, typ in rules.items():
        if row >= total_rows:
            continue
        y = CONTENT_Y + row * LINE_H
        col = C_RULE_HEAD if typ == 1 else C_RULE_HR
        hline(left, y + LINE_H - 2, right, col)

    # ---- status bar ----
    hline(0, page_h - STATUS_H - 1, width, C_STATUSTOP)
    rect(0, page_h - STATUS_H, width, STATUS_H, C_STATUSBAR)
    glyphs(6, page_h - STATUS_H + 2, status[:width // CELL_W], C_STATUSTXT)

    img = img.resize((width, page_h), Image.LANCZOS)
    img.save(out_path)
    return out_path


if __name__ == "__main__":
    args = sys.argv[1:]
    out = args[0]
    url, title, status, dumpf = "about:demo", None, "demo page", None
    i = 1
    while i < len(args):
        if args[i] == "--url":
            url = args[i + 1]; i += 2
        elif args[i] == "--title":
            title = args[i + 1]; i += 2
        elif args[i] == "--status":
            status = args[i + 1]; i += 2
        elif args[i] == "--dump":
            dumpf = args[i + 1]; i += 2
        else:
            i += 1
    if dumpf:
        text = open(dumpf, encoding="utf-8", errors="replace").read()
    else:
        text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    render(text, out, url=url, win_title=title or "Browser", status=status)
    print("wrote", out)
