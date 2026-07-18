#!/usr/bin/env python3
# scripts/hb_button_probe.py — scan a rendered PPM (P6) for the default <button>
# push-button face: the button-grey fill (0xe0e3e7) painted behind the label and
# the 1px border stroke (~0x969696 / 150,150,150) around it. Emits summary lines
#   FACE  <count> <minx> <maxx> <miny> <maxy>
#   BORDER <count> <minx> <maxx>
#   DIMS  <w> <h>
# so a gate can assert the button renders a visible, bordered box and where it
# sits. Pure stdlib (no PIL).
import sys

def load(p):
    f = open(p, 'rb')
    assert f.readline().strip() == b'P6', "not a P6 ppm"
    w, h = map(int, f.readline().split())
    f.readline()  # maxval
    return w, h, f.read()

def near(a, b, tol):
    return abs(a - b) <= tol

def main():
    w, h, d = load(sys.argv[1])
    face = []
    border = []
    for y in range(h):
        base = y * w * 3
        for x in range(w):
            i = base + x * 3
            r, g, b = d[i], d[i + 1], d[i + 2]
            # button-grey face 0xe0e3e7 = (224,227,231)
            if near(r, 224, 4) and near(g, 227, 4) and near(b, 231, 4):
                face.append((x, y))
            # 1px border stroke ~ (150,150,150), grey and roughly neutral
            elif near(r, 150, 12) and near(g, 150, 12) and near(b, 150, 12):
                border.append((x, y))
    print("DIMS", w, h)
    if face:
        xs = [p[0] for p in face]; ys = [p[1] for p in face]
        print("FACE", len(face), min(xs), max(xs), min(ys), max(ys))
    else:
        print("FACE 0")
    if border:
        xs = [p[0] for p in border]
        print("BORDER", len(border), min(xs), max(xs))
    else:
        print("BORDER 0")

if __name__ == "__main__":
    main()
