#!/usr/bin/env python3
# scripts/gen_test_mp3.py — synthesize the royalty-free MP3 audio test clip and
# a golden reference signature for the native decoder host-test.
#
# Produces:
#   tests/fixtures/sounds/test.mp3          — CBR MPEG-1 Layer III, 128 kbps,
#                                             44100 Hz, mono, no Xing/ID3.
#   tests/fixtures/sounds/test.mp3.golden   — an ffmpeg-decoded reference
#                                             signature (rate/channels/frames/
#                                             rms/peak + sample values at fixed
#                                             indices) so scripts/
#                                             test_mp3decode_host.sh can prove
#                                             lib/mp3decode.ad decodes like
#                                             ffmpeg WITHOUT needing ffmpeg at
#                                             test time.
#
# The clip is synthesized ENTIRELY here (additive sine arpeggio with an
# envelope) — no sampled third-party recording — so it is an original work
# released into the public domain (CC0-1.0), just like the WAV fixture.
#
# Requires ffmpeg on PATH (only when (re)generating the fixture, never at test
# time).  Deterministic: same bytes every run.
#
#   python3 scripts/gen_test_mp3.py

import math
import os
import struct
import subprocess
import sys
import wave

RATE = 44100
NOTES = [(261.63, 0.35), (329.63, 0.35), (392.00, 0.35),
         (523.25, 0.35), (523.25, 0.50)]                 # C-E-G-C, held C
GOLDEN_INDICES = [1000, 5000, 10000, 20000, 40000, 60000, 80000]


def synth() -> bytes:
    s = []
    for freq, dur in NOTES:
        n = int(RATE * dur)
        for i in range(n):
            t = i / RATE
            env = min(1.0, i / (0.01 * RATE)) * min(1.0, (n - i) / (0.03 * RATE))
            v = 0.6 * math.sin(2 * math.pi * freq * t) \
                + 0.2 * math.sin(2 * math.pi * 2 * freq * t)
            s.append(int(max(-1.0, min(1.0, v * env)) * 28000))
    return struct.pack("<%dh" % len(s), *s)


def main() -> int:
    root = os.path.join(os.path.dirname(__file__), "..")
    outdir = os.path.join(root, "tests", "fixtures", "sounds")
    os.makedirs(outdir, exist_ok=True)
    mp3 = os.path.join(outdir, "test.mp3")
    golden = os.path.join(outdir, "test.mp3.golden")
    src_wav = os.path.join(outdir, ".src_mp3gen.wav")

    pcm = synth()
    with wave.open(src_wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)

    subprocess.run(["ffmpeg", "-y", "-i", src_wav, "-c:a", "libmp3lame",
                    "-b:a", "128k", "-ac", "1", "-write_xing", "0",
                    "-id3v2_version", "0", mp3],
                   check=True, stderr=subprocess.DEVNULL)
    # ffmpeg reference decode -> raw s16le mono
    ref = subprocess.run(["ffmpeg", "-y", "-i", mp3, "-f", "s16le",
                          "-acodec", "pcm_s16le", "-ac", "1", "-"],
                         check=True, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL).stdout
    sm = struct.unpack("<%dh" % (len(ref) // 2), ref)
    nframes = len(sm)
    rms = math.sqrt(sum(x * x for x in sm) / nframes) if nframes else 0.0
    peak = max(abs(x) for x in sm) if sm else 0
    os.remove(src_wav)

    with open(golden, "w") as g:
        g.write("# golden signature for tests/fixtures/sounds/test.mp3\n")
        g.write("# ffmpeg-decoded reference; see scripts/gen_test_mp3.py\n")
        g.write("RATE 44100\n")
        g.write("CHANNELS 1\n")
        g.write("NFRAMES %d\n" % nframes)
        g.write("RMS %.3f\n" % rms)
        g.write("PEAK %d\n" % peak)
        for idx in GOLDEN_INDICES:
            val = sm[idx] if idx < nframes else 0
            g.write("SAMPLE %d %d\n" % (idx, val))

    print("wrote", os.path.relpath(mp3, root),
          "(%d bytes)" % os.path.getsize(mp3))
    print("wrote", os.path.relpath(golden, root),
          "(nframes=%d rms=%.1f peak=%d)" % (nframes, rms, peak))
    return 0


if __name__ == "__main__":
    sys.exit(main())
