#!/usr/bin/env python3
# scripts/ppm_to_png.py — convert a binary P6 PPM to PNG using ONLY the
# Python standard library (zlib), so the host GUI gates have zero external
# image-tool dependencies. Usage: python3 scripts/ppm_to_png.py in.ppm out.png
import sys, zlib, struct


def read_ppm(path):
    data = open(path, "rb").read()
    if not data.startswith(b"P6"):
        raise ValueError("not a P6 PPM")
    # parse header: P6 <w> <h> <maxval>, whitespace-separated, then 1 ws byte
    idx = 2
    vals = []
    while len(vals) < 3:
        while idx < len(data) and data[idx] in b" \t\n\r":
            idx += 1
        if idx < len(data) and data[idx:idx+1] == b"#":
            while idx < len(data) and data[idx] not in b"\n":
                idx += 1
            continue
        s = idx
        while idx < len(data) and data[idx] not in b" \t\n\r":
            idx += 1
        vals.append(int(data[s:idx]))
    w, h, maxv = vals
    idx += 1  # single whitespace after maxval
    pix = data[idx:idx + w * h * 3]
    return w, h, pix


def write_png(path, w, h, pix):
    def chunk(typ, body):
        c = typ + body
        return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        raw += pix[y * w * 3:(y + 1) * w * 3]
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: ppm_to_png.py in.ppm out.png", file=sys.stderr)
        sys.exit(2)
    w, h, pix = read_ppm(sys.argv[1])
    if len(pix) != w * h * 3:
        print("truncated PPM", file=sys.stderr)
        sys.exit(1)
    write_png(sys.argv[2], w, h, pix)
