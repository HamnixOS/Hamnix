# Video media track (#322) — "watch a video in the OS"

## Scope decision: Motion-JPEG, not H.264

The USER wants to WATCH A VIDEO — a moving picture — not a specific codec. Full
H.264/MP4 decode is a multi-week DSP + entropy-coding effort that shows no frame
until it is nearly complete. Mirroring how the audio track chose WAV over MP3,
this track decodes **baseline JPEG per frame** by reusing the existing
`lib/jpeg.ad` decoder (from the browser `<img>` work), so real moving pictures
play NOW.

- **Codec:** baseline sequential JFIF/JPEG (`lib/jpeg.ad`, unchanged) — one
  frame per JPEG.
- **Container:** a deliberately trivial length-prefixed carrier, **"HMJV"**
  (`lib/mjpegdemux.ad`). RIFF/AVI or ISO-BMFF demux adds real index/chunk
  parsing for ZERO codec benefit; the codec is the hard part, so the carrier is
  minimal. **Follow-up:** AVI-Motion-JPEG demux (so third-party MJPEG AVIs open).

### HMJV byte layout (little-endian)

```
0   magic "HMJV" (4)   |  4  version u16=1  |  6  flags u16=0
8   width  u16 (<=256) | 10  height u16 (<=256) | 12 fps u16 | 14 frame_count u16
16  reserved u32=0
20  frames…  each: u32 jpeg_len, then jpeg_len bytes of baseline JFIF
```

Frames are capped at 256×256 by the kernel named-image store
(`WSYS_IMG_MAX_W/H`). The shipped clip is 256×192, 10 fps, 30 frames (~3 s).

## Pieces

- `scripts/gen_test_video.py` — synthesizes the royalty-free (CC0) test clip
  `tests/fixtures/videos/test.hmjv` (a bouncing ball + scrolling colour sweep +
  a large frame counter, encoded as baseline JPEG via PIL). No third-party
  footage; deterministic.
- `lib/mjpegdemux.ad` — pure, dual-target HMJV demux (frame index only).
- `lib/hamvideocore.ad` — pure, dual-target UI core (state / layout / scene
  builder referencing the named "frame" image / input handlers).
- `user/hamvideoscene.ad` — native driver: window + per-tick JPEG decode + 'I'-
  verb frame upload + jiffies-paced playback + play/pause/stop/seek.
- `user/hamvideoscene_host.ad` — host render + decode harness (PPM/PNG).
- `user/hamvideoselftest.ad` — on-device headless decode self-test /init.

## Kernel fix: 'I'-verb streaming reassembly (`sys/src/9/port/devwsys.ad`)

The present path could NOT actually blit a full-resolution frame: native
`sys_write` routes through a fixed 4 KiB syscall bounce (`UA_BOUNCE_SZ`), so a
single userland write of an N-byte draw/ctl payload arrives at
`devwsys_draw_ctl_write` as ceil(N/4096) chunks — yet `_wsys_blit_parse`
requires the WHOLE 'I' verb in one buffer and rejects a short payload with
EINVAL. Any image >~1020 px (incl. the existing hamimgscene 32×32 = 4111 bytes)
silently failed on-device (host-only tested — the "merged ≠ working" trap).

Fix (mirrors `devblk`'s `install_file` streaming): when an 'I' verb's declared
total exceeds the arriving chunk, reassemble the chunks into a kmalloc'd
staging buffer keyed by wid, then parse+store ONCE on completion (no torn
frames). Strictly additive — the oversized case previously hard-failed. This
also repairs the hamimgscene demo on-device.

## A/V status

Round 1 ships **silent video** (moving pictures is the win). The HMJV `flags`
word + reserved field leave room for an interleaved WAV/PCM audio track; the
follow-up streams it through the #321 `/dev/audio` HDA sink and paces video
frames on the audio clock for A/V sync.

## Verification

- Host (QEMU-free, deterministic): `scripts/test_hamvideo_host.sh` — demuxes +
  decodes EVERY frame, checks count/geometry/fps + non-blank against a Python
  (struct + PIL) reference, renders the player UI + a mid-playback frame to PNG,
  and asserts the decoded frame rasterized into the video rect.
- On-device: `scripts/test_hamvideo_playback.sh` — boots the installer image,
  launches the real player, screendumps a mid-playback frame (the animated clip
  visible in the window is the proof), and runs the headless decode self-test.
  SKIPs cleanly without /dev/kvm + OVMF + the built installer image.
