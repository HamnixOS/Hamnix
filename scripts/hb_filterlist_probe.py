#!/usr/bin/env python3
# scripts/hb_filterlist_probe.py — pixel-assert CSS `filter` FUNCTION LISTS
# (chaining) + the hue-rotate() function on the rendered framebuffer (a P6 PPM).
#
# A visual gate can false-green, so this scans the ACTUAL framebuffer for each
# box and proves: (a) the box's ORIGINAL colour is GONE and (b) the EXPECTED
# CHAINED / hue-rotated colour is PRESENT. A whole-image presence/absence scan is
# robust to layout (no coordinate math). Colours are distinctive.
#
# Usage: hb_filterlist_probe.py PPM  — exits 0 iff every assertion passes.
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
        print("usage: hb_filterlist_probe.py PPM", file=sys.stderr)
        return 2
    w, h, pix = read_ppm(sys.argv[1])

    counts = {}
    for o in range(0, len(pix) - 2, 3):
        k = (pix[o], pix[o + 1], pix[o + 2])
        counts[k] = counts.get(k, 0) + 1

    def present(hexs, thresh=20):
        t = tuple(int(hexs[i:i + 2], 16) for i in (1, 3, 5))
        return counts.get(t, 0) >= thresh

    fails = 0
    NOISE = 200

    def gone(orig, msg):
        nonlocal fails
        t = tuple(int(orig[i:i + 2], 16) for i in (1, 3, 5))
        c = counts.get(t, 0)
        if c < NOISE:
            print("[hb-fl] PASS %s (original %s gone; %d AA residual)" % (msg, orig, c))
        else:
            print("[hb-fl] FAIL %s (original %s STILL a fill x%d)" % (msg, orig, c))
            fails += 1

    def shows(want, msg):
        nonlocal fails
        if present(want):
            print("[hb-fl] PASS %s (%s present)" % (msg, want))
        else:
            print("[hb-fl] FAIL %s (%s NOT present)" % (msg, want))
            fails += 1

    def absent(bad, msg):
        nonlocal fails
        if not present(bad, thresh=NOISE):
            print("[hb-fl] PASS %s (%s not a fill)" % (msg, bad))
        else:
            print("[hb-fl] FAIL %s (%s IS a fill — chain step missing)" % (msg, bad))
            fails += 1

    # CHAIN 1: grayscale(100%) brightness(150%) on #cc4422.
    #   grayscale -> luma #696969 ; then brightness x1.5 -> #9d9d9d (BRIGHTER grey).
    gone("#cc4422", "chain grayscale+brightness removes original")
    shows("#9d9d9d", "chain settles to brightened grey (BOTH functions ran)")
    # CHAIN 2: sepia(100%) invert(100%) on #6688aa.
    #   sepia -> #b09d7a ; then invert -> #4f6285.
    gone("#6688aa", "chain sepia+invert removes original")
    absent("#b09d7a", "chain does NOT stop at sepia (invert also ran)")
    shows("#4f6285", "chain settles to inverted-sepia")
    # hue-rotate(120deg) on pure red #cc0000 -> ~green (#005a00 in the int matrix).
    gone("#cc0000", "hue-rotate removes original red")
    shows("#005a00", "hue-rotate(120deg) rotates red toward green")
    # SINGLE grayscale(100%) control (legacy path) -> #696969, byte-identical.
    shows("#696969", "single-function grayscale unchanged (legacy path)")
    # unfiltered control keeps its exact colour.
    shows("#55dd77", "unfiltered box unchanged")

    if fails == 0:
        print("[hb-fl] ALL PASS (%dx%d)" % (w, h))
        return 0
    print("[hb-fl] %d FAILURE(S)" % fails)
    return 1


if __name__ == "__main__":
    sys.exit(main())
