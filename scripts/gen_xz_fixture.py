#!/usr/bin/env python3
# scripts/gen_xz_fixture.py
#
# Generates tests/test_xz_fixtures.ad — a set of `.xz`-compressed byte
# fixtures for the lib/xz/xz.ad decompressor regression. The point of
# generating (rather than hand-coding) the fixtures is fidelity: the
# compressed bytes are produced by the host `xz` binary, so the test
# proves the Adder decoder round-trips REAL xz output, not a
# hand-massaged stand-in.
#
# Each fixture is:
#   - a known payload (deterministic bytes),
#   - that payload compressed by `xz` with documented options,
#   - emitted into the .ad as two top-level Arrays (the .xz bytes and
#     the expected plaintext) plus their lengths.
#
# Driven by scripts/test_xz.sh.

import subprocess
import sys


def xz_compress(data: bytes, args: list[str]) -> bytes:
    """Compress `data` with the host `xz`, returning the .xz bytes."""
    p = subprocess.run(
        ["xz", "-z", "-c", "--format=xz"] + args,
        input=data,
        stdout=subprocess.PIPE,
        check=True,
    )
    return p.stdout


def emit_array(out, name: str, data: bytes):
    """Emit `name: Array[N, uint8]` + a fill function _init_<name>()."""
    n = len(data)
    out.append(f"{name}: Array[{max(n, 1)}, uint8]")
    out.append(f"{name}_len: uint64 = {n}")
    out.append("")
    out.append(f"def _init_{name}():")
    if n == 0:
        out.append("    return")
    else:
        for i, b in enumerate(data):
            out.append(f"    {name}[{i}] = {b}")
    out.append("")
    out.append("")


def main():
    if len(sys.argv) != 2:
        print("usage: gen_xz_fixture.py <out.ad>", file=sys.stderr)
        return 1
    out_path = sys.argv[1]

    # --- Fixture 1: small ASCII, single LZMA2 chunk -------------------
    p1 = b"Hamnix xz test 0123456789 the quick brown fox"

    # --- Fixture 2: highly repetitive — exercises match-copy heavily --
    p2 = (b"abcdefgh " * 64)

    # --- Fixture 3: a small RFC822-ish Packages stanza ----------------
    p3 = (
        b"Package: hamnix-base\n"
        b"Version: 1.0.0\n"
        b"Architecture: amd64\n"
        b"Description: XZV0_OK base metapackage\n"
        b"\n"
    )

    # --- Fixture 4: large/multi-block — a 96 KiB pseudo-random-ish
    #     but compressible payload. Use a deterministic LCG so the
    #     bytes are reproducible, mixed with long runs so xz produces
    #     several LZMA2 chunks. --format=xz with a tiny block size to
    #     force more than one xz block.
    buf = bytearray()
    seed = 0x1234_5678
    while len(buf) < 96 * 1024:
        seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF
        # A run of a repeated byte (compressible) ...
        run_len = 8 + (seed >> 8) % 40
        ch = 0x41 + (seed % 26)
        buf.extend(bytes([ch]) * run_len)
        # ... then a few "random" bytes (less compressible).
        seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF
        rnd_len = 1 + (seed >> 4) % 6
        for _ in range(rnd_len):
            seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF
            buf.append((seed >> 16) & 0xFF)
    p4 = bytes(buf[: 96 * 1024])

    fx = [
        # (name, plaintext, xz args)
        ("fx1", p1, ["-6"]),
        ("fx2", p2, ["-9"]),
        ("fx3", p3, ["-6"]),
        # Tiny block size forces multiple xz blocks for the big case.
        ("fx4", p4, ["-9", "--block-size=32768"]),
    ]

    out = []
    out.append("# tests/test_xz_fixtures.ad  --  GENERATED, do not edit.")
    out.append("#")
    out.append("# Produced by scripts/gen_xz_fixture.py: each fixture is a")
    out.append("# known payload compressed by the host `xz` binary, plus the")
    out.append("# expected plaintext. test_xz.ad imports these and asserts")
    out.append("# lib/xz/xz.ad round-trips them byte-exact.")
    out.append("")
    out.append("")

    for name, plain, args in fx:
        comp = xz_compress(plain, args)
        out.append(f"# {name}: payload {len(plain)} bytes -> "
                   f"{len(comp)} .xz bytes (xz {' '.join(args)})")
        emit_array(out, f"{name}_xz", comp)
        emit_array(out, f"{name}_plain", plain)

    out.append("def init_xz_fixtures():")
    for name, _, _ in fx:
        out.append(f"    _init_{name}_xz()")
        out.append(f"    _init_{name}_plain()")
    out.append("")

    with open(out_path, "w") as f:
        f.write("\n".join(out))

    print(f"[gen_xz_fixture] wrote {out_path}: "
          + ", ".join(f"{n}={len(p)}B" for n, p, _ in fx))
    return 0


if __name__ == "__main__":
    sys.exit(main())
