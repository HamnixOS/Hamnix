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
    segs = []      # (row, x, color, bold, uline, link, bg, text)
    fills = []     # (top, bot, lx, rx, color) — element background boxes
    rules = {}     # row -> type
    title = None
    page_bg = None  # <body>/<html> page-level background (whole viewport)
    for line in text.splitlines():
        if line.startswith("PAGEBG "):
            page_bg = line.split()[1]
        elif line.startswith("LAYOUT "):
            for tok in line.split():
                if tok.startswith("width="):
                    width = int(tok[6:])
        elif line.startswith("TITLE "):
            title = line[6:]
        elif line.startswith("FILL "):
            # FILL top bot lx rx #rrggbb — an element background rectangle.
            p = line.split()
            fills.append((int(p[1]), int(p[2]), int(p[3]), int(p[4]), p[5]))
        elif line.startswith("RULE row "):
            p = line.split()
            rules[int(p[2])] = int(p[4])
        elif line.startswith("SEG "):
            # SEG row x #rrggbb b0 u0 l-1 bg#ffffff |text|
            head, _, rest = line.partition(" |")
            p = head.split()
            row, x = int(p[1]), int(p[2])
            color = p[3]
            bold = int(p[4][1:])
            uline = int(p[5][1:])
            link = int(p[6][1:])
            bgtok = p[7][2:]
            bg = None if bgtok == "-" else bgtok
            text = rest[:-1] if rest.endswith("|") else rest
            segs.append((row, x, color, bold, uline, link, bg, text))
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

    # ---- content background (page-level <body>/<html> bg, or white) ----
    rect(0, CONTENT_Y, width, total_rows * LINE_H, page_bg or C_PAGE)

    # ---- element backgrounds (behind the whole box, under the text) ----
    for (ftop, fbot, lx, rx, col) in fills:
        if ftop >= total_rows:
            continue
        fb = min(fbot, total_rows)
        y = CONTENT_Y + ftop * LINE_H
        h = (fb - ftop) * LINE_H
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
    for (row, x, color, bold, uline, link, bg, txt) in segs:
        if row >= total_rows:
            continue
        y = CONTENT_Y + row * LINE_H
        n = len(txt)
        if bg:
            rect(x, y, n * CELL_W, LINE_H, bg)
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
