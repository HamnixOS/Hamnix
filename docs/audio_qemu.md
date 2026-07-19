# Hearing Hamnix audio under QEMU

If you boot Hamnix and hear **no sound**, the first thing to check is your QEMU
command line — not the Hamnix audio stack. A boot line like

```
qemu-system-x86_64 ... -vga std -display gtk -serial stdio
```

has **no audio device at all**. Hamnix's native Intel HDA driver
(`drivers/audio/hda.ad`) discovers its controller by **PCI class `0x0403`**
(Intel HD Audio / "Azalia"). With no such device on the bus, `hda_init()`
prints

```
[hda] no HDA controller (class 0403) found
```

and skips — the DE and the audio player still run, but there is physically
nothing to make sound with. You must add BOTH an emulated HDA controller AND a
host audio backend.

## What codec Hamnix actually supports

Only **Intel HD Audio (HDA / Azalia)**, matched by PCI class `0x0403` — this
covers QEMU's `intel-hda` (`8086:2668`) and `ich9-intel-hda` (`8086:293e`), and
real Intel/AMD HDA silicon. The driver walks the codec widget tree over
CORB/RIRB to a DAC + output-pin path and drives real stream DMA (BDL + RUN bit).

**NOT supported:** there is no native AC97 (`-device AC97`) driver and no
virtio-sound (`-device virtio-sound-pci`) driver. Do **not** use `-device AC97`
— Hamnix will not bind it and you will still get silence. The device MUST be an
HDA controller.

## The correct boot command

Pair an `intel-hda` controller + an `hda-output` codec with a **host** audio
backend via `-audiodev`:

```
qemu-system-x86_64 ... \
    -audiodev pipewire,id=snd0 \
    -device intel-hda \
    -device hda-output,audiodev=snd0
```

The `-device hda-output` codec is what the driver enumerates and unmutes; its
`audiodev=snd0` binds it to the host sink. Use `hda-duplex` instead of
`hda-output` if you also want microphone **capture** (`/dev/audioin`) to reach a
host source:

```
    -device intel-hda \
    -device hda-duplex,audiodev=snd0
```

### Choosing the host backend

`-audiodev <backend>,id=snd0` — pick the one your host actually routes to
speakers. Check what your QEMU build offers with `qemu-system-x86_64 -audiodev
help`. In observed order of reliability on Linux:

| backend    | flag                              | when to use |
|------------|-----------------------------------|-------------|
| `alsa`     | `-audiodev alsa,id=snd0`          | Most universal; works even when the session's PipeWire/PulseAudio routing is broken. Needs a real ALSA playback card (`/proc/asound/cards`). |
| `pipewire` | `-audiodev pipewire,id=snd0`      | Native PipeWire socket (`$XDG_RUNTIME_DIR/pipewire-0`). |
| `pa`       | `-audiodev pa,id=snd0`            | PulseAudio (or pipewire-pulse) socket. |
| `sdl`      | `-audiodev sdl,id=snd0`           | SDL2 audio, if built in. |
| `wav`      | `-audiodev wav,id=snd0,path=out.wav` | **Capture to a file** instead of speakers — used by the CI gates below to prove non-silent PCM headlessly. |
| `none`     | `-audiodev none,id=snd0`          | Enumerates the device (DE/driver work) but is silent. |

On the dev box, **`alsa` emitted to the default card when `pipewire` did not** —
if you hear nothing with one backend, try `alsa` before assuming a Hamnix bug.

### Just use the installer runner

`scripts/run_installer.sh` already auto-detects a working backend (alsa →
pipewire → pa → none) and appends
`-audiodev <backend>,id=snd0 -device intel-hda -device hda-output,audiodev=snd0`
for you. Override with `HDA_AUDIODEV=alsa|pipewire|pa|sdl|none`, capture to a
file with `HDA_AUDIODEV=wav,path=/tmp/out.wav`, or disable with `NO_AUDIO=1`.
Prefer this over a hand-written qemu line — the missing-audio-device report came
from a hand-written line, not from the runner.

## What is verifiable, and how

The playback path is `/dev/audio` write (PCM staged into the DMA buffer) →
`/dev/audioctl` `start` → `hda_start()` programs the BDL, powers/formats the
DAC, tags the stream, unmutes the pin, and sets the stream **RUN** bit → the
controller's DMA engine cycles the buffer to the codec.

Two independent things are checked by CI, both headless:

1. **Stream running / samples submitted** — the driver polls the controller's
   Link-Position-In-Buffer (`SD_LPIB`) counter after `start`; a non-zero,
   advancing LPIB proves the DMA engine actually consumed the buffer and pushed
   samples toward the codec. Logged as `[audio] DMA engine consumed the buffer
   (LPIB advanced)`.
2. **Non-silent output** — the gates boot with `-audiodev wav,...` so QEMU
   captures the codec output to a host WAV, then FAIL if that WAV is
   all-zero/silent (peak `|sample|` must clear a threshold).

Gates:

- `scripts/test_hda_audio.sh` — square-wave tone → intel-hda → wav, asserts
  controller bring-up, DAC/pin path, `[audio] PASS`, and a non-silent WAV.
- `scripts/test_hda_mp3.sh` — decoded MP3 PCM through the same sink.
- `scripts/test_hda_capture.sh` — `hda-duplex` capture ring.
- `scripts/test_hda_volume.sh` — DE master volume scales the captured WAV.

**What still needs a human:** whether sound actually comes out of your physical
speakers depends on host mixer levels, the chosen `-audiodev` backend, and your
session's audio routing — none of which can be asserted headlessly. The CI gates
prove Hamnix drives the codec and delivers non-silent PCM to QEMU; a human with
working speakers confirms the last hop. If the gates are green but you hear
nothing, the problem is the QEMU device/backend pairing or your host mixer, not
the Hamnix stack.
