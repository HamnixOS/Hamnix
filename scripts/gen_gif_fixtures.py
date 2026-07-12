#!/usr/bin/env python3
# scripts/gen_gif_fixtures.py — deterministic, dependency-free GIF89a writer for
# the hambrowse GIF gate. Emits small fixtures with KNOWN palette indices so the
# decoder's output can be asserted EXACTLY (palette colours are lossless):
#   * a non-interlaced 48x32 four-quadrant GIF,
#   * an interlaced 48x32 four-quadrant GIF (identical pixels, row order shuffled
#     into the 4-pass interlace layout — exercises the de-interlace path),
#   * a 48x32 GIF with a transparent top-left quadrant (Graphic Control Extension
#     transparent-colour-index),
#   * a truncated/garbage GIF that must be rejected cleanly.
#
# No PIL, no zlib — a hand-rolled GIF LZW compressor mirroring lib/gif.ad's
# decoder so the round trip is exact.
import sys


def lzw_compress(indices, min_code_size):
    clear = 1 << min_code_size
    end = clear + 1
    code_size = min_code_size + 1
    table = {bytes([i]): i for i in range(clear)}
    next_code = end + 1
    out = bytearray()
    bitbuf = 0
    bitcnt = 0

    def emit(code, size):
        nonlocal bitbuf, bitcnt
        bitbuf |= code << bitcnt
        bitcnt += size
        while bitcnt >= 8:
            out.append(bitbuf & 0xFF)
            bitbuf >>= 8
            bitcnt -= 8

    emit(clear, code_size)
    cur = b""
    for idx in indices:
        nxt = cur + bytes([idx])
        if nxt in table:
            cur = nxt
        else:
            emit(table[cur], code_size)
            if next_code < 4096:
                # GIF LZW "early change": the decoder's dictionary lags the
                # encoder's by one entry, so the code width must grow when
                # next_code reaches 2^code_size BEFORE assigning the new code.
                table[nxt] = next_code
                if next_code == (1 << code_size) and code_size < 12:
                    code_size += 1
                next_code += 1
            cur = bytes([idx])
    if cur:
        emit(table[cur], code_size)
    emit(end, code_size)
    if bitcnt > 0:
        out.append(bitbuf & 0xFF)
    return bytes(out)


def interlace_reorder(pixels, w, h):
    # pixels: row-major list of index rows. Return a flat index stream in the
    # 4-pass interlaced physical order lib/gif.ad expects to de-interlace.
    order = []
    order += list(range(0, h, 8))
    order += list(range(4, h, 8))
    order += list(range(2, h, 4))
    order += list(range(1, h, 2))
    flat = []
    for r in order:
        flat.extend(pixels[r * w:(r + 1) * w])
    return flat


def build_gif(w, h, pixels, palette, min_code_size,
              interlaced=False, transparent_index=None):
    # palette: list of (r,g,b), length must be a power of two (2..256).
    ncol = len(palette)
    assert ncol & (ncol - 1) == 0 and 2 <= ncol <= 256
    gct_bits = ncol.bit_length() - 2  # size field N where 2^(N+1)=ncol
    out = bytearray()
    out += b"GIF89a"
    # Logical Screen Descriptor.
    out += bytes([w & 0xFF, (w >> 8) & 0xFF, h & 0xFF, (h >> 8) & 0xFF])
    packed = 0x80 | (gct_bits & 7)          # GCT present, size = gct_bits
    out += bytes([packed, 0, 0])            # packed, bg index, aspect
    for (r, g, b) in palette:
        out += bytes([r, g, b])
    # Graphic Control Extension (only if transparency requested).
    if transparent_index is not None:
        out += bytes([0x21, 0xF9, 0x04, 0x01, 0x00, 0x00,
                      transparent_index & 0xFF, 0x00])
    # Image Descriptor.
    out += bytes([0x2C, 0, 0, 0, 0,
                  w & 0xFF, (w >> 8) & 0xFF, h & 0xFF, (h >> 8) & 0xFF])
    out += bytes([0x40 if interlaced else 0x00])   # interlace flag, no LCT
    # Image data.
    stream = interlace_reorder(pixels, w, h) if interlaced else list(pixels)
    out += bytes([min_code_size])
    data = lzw_compress(stream, min_code_size)
    i = 0
    while i < len(data):
        chunk = data[i:i + 255]
        out += bytes([len(chunk)]) + chunk
        i += 255
    out += bytes([0x00])   # block terminator
    out += bytes([0x3B])   # trailer
    return bytes(out)


def quadrant_pixels(w, h, tl, tr, bl, br):
    px = []
    for y in range(h):
        for x in range(w):
            if x < w // 2 and y < h // 2:
                px.append(tl)
            elif x >= w // 2 and y < h // 2:
                px.append(tr)
            elif x < w // 2 and y >= h // 2:
                px.append(bl)
            else:
                px.append(br)
    return px


def main():
    plain, inter, trans, trunc = sys.argv[1:5]
    w, h = 48, 32
    # 4-colour palette (padded to a power of two): red/green/blue/white.
    pal4 = [(220, 40, 40), (40, 200, 60), (50, 90, 220), (240, 240, 240)]
    px4 = quadrant_pixels(w, h, 0, 1, 2, 3)

    with open(plain, "wb") as f:
        f.write(build_gif(w, h, px4, pal4, 2, interlaced=False))
    with open(inter, "wb") as f:
        f.write(build_gif(w, h, px4, pal4, 2, interlaced=True))

    # transparent-TL variant: 5 used colours -> palette padded to 8, index 4 is
    # the transparent placeholder colour (17,17,17), flagged transparent.
    pal8 = pal4 + [(17, 17, 17), (0, 0, 0), (0, 0, 0), (0, 0, 0)]
    pxT = quadrant_pixels(w, h, 4, 1, 2, 3)   # TL transparent, rest opaque
    with open(trans, "wb") as f:
        f.write(build_gif(w, h, pxT, pal8, 3, interlaced=False,
                          transparent_index=4))

    # truncated: a valid header + screen descriptor, image descriptor, but the
    # LZW data is cut off mid-stream (no terminator/trailer) -> must reject.
    good = build_gif(w, h, px4, pal4, 2, interlaced=False)
    hdr_end = good.index(b"\x2c")
    with open(trunc, "wb") as f:
        f.write(good[:hdr_end + 14])   # image descriptor + min-code-size + a byte

    print("wrote GIF fixtures:", plain, inter, trans, trunc)


if __name__ == "__main__":
    main()
