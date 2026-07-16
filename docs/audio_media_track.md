# Audio media track (#321) — WAV-first, MP3 deferred

USER daily-driver ask: "play some audio in OS." This track lands the tractable
first media win end-to-end, and records the scope decision for the follow-up
codec.

## What shipped (this increment)

A real audio player that decodes a file and plays it through the native HDA
sink, verified both QEMU-free (decode) and on-device (playback):

- `lib/wavdecode.ad` — PURE, dual-target RIFF/WAVE PCM decoder (chunk walk;
  8/16-bit; mono/stereo; format + PCM-payload span + duration + peak level).
- `lib/hamaudiocore.ad` + `user/hamaudioscene.ad` (+ `_host`) — the DE Audio
  Player: filename + time readout, progress bar, level meter,
  play/pause/stop/seek. The native driver reads the file, decodes it, and
  streams the PCM to `/dev/audio` (rate/channels/format via `/dev/audioctl`),
  tracking position on the 100 Hz jiffies clock.
- `tests/fixtures/sounds/test.wav` — a royalty-free (CC0) synthesized C-major
  arpeggio (22050 Hz mono s16le, ~2.4 s, ~103 KiB), generated deterministically
  by `scripts/gen_test_wav.py`. Baked into the image at
  `/usr/share/sounds/test.wav` (initramfs plant + the `hamnix-hamaudio`
  package). No third-party recording — an original public-domain work.
- Gates: `scripts/test_hamaudio_host.sh` (decode matches Python `wave`
  bit-exactly; UI PNG + input commands) and `scripts/test_hamaudio_playback.sh`
  (boots QEMU, runs `hamaudioselftest` as init, captures the intel-hda WAV
  backend, proves non-silent real PCM reached the codec).

The HDA sink itself was already present (`drivers/audio/hda.ad` +
`drivers/audio/audio_cdev.ad` → `/dev/audio` + `/dev/audioctl`, proven by
`scripts/test_audio_playback.sh`); this track adds the decoder, the player, and
the shipped clip on top of it.

## Why WAV-first (MP3 decode deferred) — the disproof

MP3 (MPEG-1/2 Layer III) decode is a genuinely large, bit-exact DSP codec:
a Huffman-coded bitstream with a bit reservoir, scalefactor decode, the
alias-reduction / IMDCT stage, and the 32-band polyphase synthesis
filterbank — easily 1500-2500 lines of careful fixed-point/float Adder that is
hard to get bit-exact and easy to ship subtly wrong (a decoder that plays
garbage is worse than none). Meanwhile the WAV path already reaches the
speaker: decode is trivial and the whole player + HDA end-to-end works and is
verified NOW. Per the project rule "real audio playing beats a decoder that
does not reach the speaker," WAV is the correct first increment. It also
exercises and hardens every non-codec piece the MP3 path will reuse (the
player UI, the streaming loop, the HDA sink, the image staging, both gates).

## MP3 follow-up plan

1. `lib/mp3.ad` (pure, dual-target, extern-free) mirroring `lib/wavdecode.ad`'s
   shape: input a byte buffer, output S16LE PCM into a caller buffer, exposing
   the same accessors (rate/channels/frame count) so `hamaudioscene` /
   `hamaudioselftest` consume it through one interface.
2. Build it in verifiable stages, each host-gated against an ffmpeg/lame
   reference PCM (checksum + sample count + SNR tolerance) the way
   `test_hamaudio_host.sh` checks WAV today:
   a. Frame sync + header parse (MPEG version/layer/bitrate/samplerate/CBR).
   b. Side-info + scalefactor + Huffman spectral decode.
   c. Requantize + reorder + alias reduction.
   d. IMDCT + windowing (long/short blocks).
   e. Polyphase synthesis filterbank → PCM.
   Start constrained (MPEG-1 Layer III, CBR, one sample rate, joint-stereo off)
   and widen once each stage matches the reference.
3. Ship a small CC0 `.mp3` fixture alongside `test.wav` once (2) decodes it to
   PCM within tolerance, and add an on-device `test_mp3_playback.sh` boot gate.

Streaming note: the current player stages up to the 256 KiB HDA DMA buffer per
play/seek (the fixture fits). A longer-clip / gapless refill loop (write the
next chunk as `LPIB` advances) is a separate, orthogonal follow-up.
