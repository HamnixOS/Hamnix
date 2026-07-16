#!/usr/bin/env python3
# scripts/gen_test_wav.py — synthesize the royalty-free audio test clip.
#
# Produces tests/fixtures/sounds/test.wav: a short (~2.5 s) synthesized
# arpeggio, mono, 22050 Hz, signed-16-bit-LE PCM in a canonical 44-byte
# RIFF/WAVE container. The clip is generated ENTIRELY by this script from
# first principles (simple additive sine synthesis with an amplitude
# envelope) — there is NO sampled third-party recording involved, so the
# result is an original work released into the public domain (CC0-1.0).
#
# It is the file baked into the OS image at /usr/share/sounds/test.wav and
# the reference the decoder host-test (scripts/test_hamaudio_host.sh)
# checks lib/wavdecode.ad against. Deterministic: same bytes every run.
#
#   python3 scripts/gen_test_wav.py [out.wav]
#
# Kept intentionally tiny (a couple seconds, mono, 22050 Hz => ~110 KB) so
# it does not bloat the image.

import math
import struct
import sys
from pathlib import Path

RATE = 22050
CHANNELS = 1
BITS = 16

# A gentle rising major arpeggio (C4 E4 G4 C5) then a held C5 — a pleasant,
# unmistakably-musical, obviously-not-noise signal. Frequencies in Hz.
NOTES = [
    (261.63, 0.45),   # C4
    (329.63, 0.45),   # E4
    (392.00, 0.45),   # G4
    (523.25, 0.45),   # C5
    (523.25, 0.60),   # C5 (held)
]


def synth() -> bytes:
    samples = []
    for freq, dur in NOTES:
        n = int(RATE * dur)
        for i in range(n):
            t = i / RATE
            # Simple attack/decay envelope so notes don't click.
            env = min(1.0, i / (0.01 * RATE))                 # 10 ms attack
            rel = min(1.0, (n - i) / (0.03 * RATE))           # 30 ms release
            env *= rel
            # Fundamental + a soft octave for a little timbre.
            v = 0.60 * math.sin(2 * math.pi * freq * t)
            v += 0.20 * math.sin(2 * math.pi * 2 * freq * t)
            s = int(max(-1.0, min(1.0, v * env)) * 28000)
            samples.append(s)
    return struct.pack("<%dh" % len(samples), *samples)


def wav_bytes(pcm: bytes) -> bytes:
    byte_rate = RATE * CHANNELS * (BITS // 8)
    block_align = CHANNELS * (BITS // 8)
    hdr = b"RIFF"
    hdr += struct.pack("<I", 36 + len(pcm))
    hdr += b"WAVE"
    hdr += b"fmt "
    hdr += struct.pack("<I", 16)            # PCM fmt chunk size
    hdr += struct.pack("<H", 1)             # audio format = PCM
    hdr += struct.pack("<H", CHANNELS)
    hdr += struct.pack("<I", RATE)
    hdr += struct.pack("<I", byte_rate)
    hdr += struct.pack("<H", block_align)
    hdr += struct.pack("<H", BITS)
    hdr += b"data"
    hdr += struct.pack("<I", len(pcm))
    return hdr + pcm


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        Path(__file__).resolve().parent.parent
        / "tests" / "fixtures" / "sounds" / "test.wav")
    out.parent.mkdir(parents=True, exist_ok=True)
    data = wav_bytes(synth())
    out.write_bytes(data)
    print("wrote %s (%d bytes, %d Hz mono s16le, %.2fs)" % (
        out, len(data), RATE, (len(data) - 44) / 2 / RATE))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
