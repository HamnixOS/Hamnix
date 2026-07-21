#!/usr/bin/env python3
"""scripts/render_hambrowse_png.py — turn a hambrowse host-harness dump into a
PNG that faithfully mirrors what the NATIVE browser (user/hambrowse.ad `emit()`)
paints: the window chrome (title bar + address bar + status bar + scrollbar)
plus the page content (styled segments + heading/hr rules).

This is a DEV VISUALIZER only. It never ships and is not part of the engine; it
exists so the shared parse+layout+colour engine and the chrome can be eyeballed
on the host with no QEMU. It reads the exact SEG/RULE/LAYOUT/TITLE lines the host
harness (user/hambrowse_host.ad) prints and reproduces the pixel geometry the
native front-end uses (CONTENT_X=8, CONTENT_Y=38, LINE_H=16, CELL_W=8, ...), so
the PNG is a truthful proxy for the shipped look.

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


def _load_fonts():
    base = "/usr/share/fonts/truetype/dejavu/"
    # pick a size whose monospace advance ~= CELL_W*S
    for size in range(20, 8, -1):
        f = ImageFont.truetype(base + "DejaVuSansMono.ttf", size)
        adv = f.getlength("0")
        if adv <= CELL_W * S:
            fb = ImageFont.truetype(base + "DejaVuSansMono-Bold.ttf", size)
            return f, fb, adv
    f = ImageFont.truetype(base + "DejaVuSansMono.ttf", 12)
    fb = ImageFont.truetype(base + "DejaVuSansMono-Bold.ttf", 12)
    return f, fb, f.getlength("0")


def parse_dump(text):
    width = 600
    segs = []      # (row, x, color, bold, uline, link, bg, text, italic)
    fills = []     # (top, bot, lx, rx, color, z) — element background boxes
    rules = {}     # row -> type
    title = None
    page_bg = None  # <body>/<html> page-level background (whole viewport)
    italic_idx = set()   # seg indices flagged faux-oblique by a SEGIT line
    for line in text.splitlines():
        if line.startswith("SEGIT "):
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
    # Fold the SEGIT flags in by seg index (SEG lines are dumped in index order,
    # so the Nth appended seg is engine seg N).
    segs = [s + (1 if i in italic_idx else 0,) for i, s in enumerate(segs)]
    return width, segs, rules, title, fills, page_bg


def render(text, out_path, url="about:demo", win_title="Browser",
           status="demo page", max_rows=None):
    width, segs, rules, ptitle, fills, page_bg = parse_dump(text)
    total_rows = (max(([r for (r, *_ ) in segs] + list(rules.keys())),
                      default=0) + 1)
    if max_rows:
        total_rows = min(total_rows, max_rows)
    page_h = CONTENT_Y + total_rows * LINE_H + STATUS_H
    W, H = width * S, page_h * S
    img = Image.new("RGB", (W, H), C_PAGE)
    d = ImageDraw.Draw(img)
    font, fontb, adv = _load_fonts()

    def rect(x, y, w, h, col):
        d.rectangle([x * S, y * S, (x + w) * S - 1, (y + h) * S - 1], fill=col)

    def hline(x0, y, x1, col, thick=1):
        d.rectangle([x0 * S, y * S, x1 * S - 1, (y + thick) * S - 1], fill=col)

    def glyphs(x, y, s, col, bold=False):
        fnt = fontb if bold else font
        cx = x * S
        for ch in s:
            d.text((cx, y * S), ch, font=fnt, fill=col)
            cx += CELL_W * S

    def glyphs_italic(x, y, s, col, bold=False):
        # Faux-oblique: render the run to a tile, shear it horizontally (top
        # pushed right relative to the baseline, k=0.25), then paste — mirrors
        # the per-row shear in lib/htmlpaint.ad (_blit_ttf_glyph, divisor 4).
        if not s:
            return
        fnt = fontb if bold else font
        k = 0.25
        th = LINE_H * S
        pad = int(k * th) + 1
        tw = (len(s) * CELL_W) * S + 2 * pad
        tile = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
        td = ImageDraw.Draw(tile)
        cx = pad
        for ch in s:
            td.text((cx, 0), ch, font=fnt, fill=col)
            cx += CELL_W * S
        # AFFINE maps output->input: x_in = x + k*y - k*th (baseline at tile bot).
        tile = tile.transform((tw, th), Image.AFFINE,
                              (1, k, -k * th, 0, 1, 0), resample=Image.BILINEAR)
        img.paste(tile, (x * S - pad, y * S), tile)

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

    # ---- content segments ----
    for (row, x, color, bold, uline, link, bg, txt, italic) in segs:
        if row >= total_rows:
            continue
        y = CONTENT_Y + row * LINE_H
        n = len(txt)
        if bg:
            rect(x, y, n * CELL_W, LINE_H, bg)
        if italic:
            glyphs_italic(x, y + 2, txt, color, bold=bool(bold))
        else:
            glyphs(x, y + 2, txt, color, bold=bool(bold))
        if uline:
            uw = n * CELL_W
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
