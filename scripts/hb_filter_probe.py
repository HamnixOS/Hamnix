#!/usr/bin/env python3
# scripts/hb_filter_probe.py — pixel-assert the CSS `filter` post-pass.
#
# A visual gate can false-green, so this scans the ACTUAL framebuffer of the
# rendered page (a binary P6 PPM) for each filtered box and proves:
#   (a) the box's ORIGINAL background colour is GONE  (the filter transformed it)
#   (b) the EXPECTED filtered colour is PRESENT        (it produced the right px)
# A whole-image presence/absence scan is robust to layout (no coordinate math).
# Colours are chosen distinctive so no accidental match with other content.
#
# Usage: hb_filter_probe.py PPM
# Exits 0 iff every assertion passes.
import sys


def read_ppm(path):
    data = open(path, "rb").read()
    if not data.startswith(b"P6"):
        raise ValueError("not a P6 PPM")
    idx = 2
    vals = []
    while len(vals) < 3:
        while idx < len(data) and data[idx] in b" \t\n\r":
            idx += 1
        if idx < len(data) and data[idx:idx + 1] == b"#":
            while idx < len(data) and data[idx] not in b"\n":
                idx += 1
            continue
        s = idx
        while idx < len(data) and data[idx] not in b" \t\n\r":
            idx += 1
        vals.append(int(data[s:idx]))
    w, h, _maxv = vals
    idx += 1
    return w, h, data[idx:idx + w * h * 3]


def main():
    if len(sys.argv) != 2:
        print("usage: hb_filter_probe.py PPM", file=sys.stderr)
        return 2
    w, h, pix = read_ppm(sys.argv[1])

    # count exact-colour pixels across the whole image.
    counts = {}
    for o in range(0, len(pix) - 2, 3):
        k = (pix[o], pix[o + 1], pix[o + 2])
        counts[k] = counts.get(k, 0) + 1

    def hx(t):
        return "#%02x%02x%02x" % t

    def present(hexs, thresh=20):
        t = tuple(int(hexs[i:i + 2], 16) for i in (1, 3, 5))
        return counts.get(t, 0) >= thresh

    fails = 0

    # A real UNFILTERED fill would leave ~box-area (tens of thousands) pixels of
    # the original colour; a filtered box leaves at most a handful of coincidental
    # anti-aliased text-edge blends elsewhere on the page. NOISE separates them by
    # orders of magnitude, so treat < NOISE residual as "fill removed".
    NOISE = 200

    def gone(orig, msg):
        nonlocal fails
        t = tuple(int(orig[i:i + 2], 16) for i in (1, 3, 5))
        c = counts.get(t, 0)
        if c < NOISE:
            print("[hb-filter] PASS %s (original %s gone; %d AA residual)" %
                  (msg, orig, c))
        else:
            print("[hb-filter] FAIL %s (original %s STILL a fill x%d)" %
                  (msg, orig, c))
            fails += 1

    def shows(want, msg):
        nonlocal fails
        if present(want):
            print("[hb-filter] PASS %s (filtered %s present)" % (msg, want))
        else:
            print("[hb-filter] FAIL %s (filtered %s NOT present)" % (msg, want))
            fails += 1

    # grayscale(100%) #cc4422 -> luma 105 -> #696969
    gone("#cc4422", "grayscale removes original")
    shows("#696969", "grayscale desaturates to luma")
    # brightness(150%) #4c4c4c(76) -> 114 -> #727272
    gone("#4c4c4c", "brightness removes original")
    shows("#727272", "brightness lightens")
    # invert(100%) #204060 -> #dfbf9f
    gone("#204060", "invert removes original")
    shows("#dfbf9f", "invert flips channels")
    # sepia(100%) #6688aa -> #b09d7a
    gone("#6688aa", "sepia removes original")
    shows("#b09d7a", "sepia warms tone")
    # contrast(200%) #909090(144) -> 160 -> #a0a0a0
    gone("#909090", "contrast removes original")
    shows("#a0a0a0", "contrast pushes mid-grey up")
    # saturate(200%) #a06040 -> #d15111
    gone("#a06040", "saturate removes original")
    shows("#d15111", "saturate deepens colour")
    # opacity(50%) #402010 -> lighten toward white -> #9f8f87
    gone("#402010", "opacity removes original")
    shows("#9f8f87", "opacity lightens (approx)")
    # blur(4px) #123456: uniform interior survives the box blur.
    shows("#123456", "blur preserves uniform interior")
    # the UNFILTERED control keeps its exact colour (no filter regressions).
    shows("#55dd77", "unfiltered box unchanged")

    if fails == 0:
        print("[hb-filter] ALL PASS (%dx%d)" % (w, h))
        return 0
    print("[hb-filter] %d FAILURE(S)" % fails)
    return 1


if __name__ == "__main__":
    sys.exit(main())
