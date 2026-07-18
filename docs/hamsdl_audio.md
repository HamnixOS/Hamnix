# hamSDL Audio — SDL_mixer / pygame.mixer-flavored sound on the game surface

## Why

The gap analysis (Adder + hamSDL vs SDL2 / pygame) flagged the missing #2
pillar: hamSDL shipped drawing, events and timing but **no audio API**, while
both SDL2 (SDL_mixer: `Mix_LoadWAV` / `Mix_PlayChannel` / `Mix_PlayMusic`) and
pygame (`pygame.mixer`: `Sound` / `music.play`) let a game make sound. This adds
that layer to the hamSDL surface, bridging to the **already-verified** audio
stack the DE Audio Player uses — it does **not** reimplement decoding.

## Shape (mirrors the hamSDL video seam)

hamSDL splits a pure, target-agnostic core from two thin transport backends. The
audio API follows the same seam exactly:

| file | role | target |
|------|------|--------|
| `lib/hamsdl_audio.ad` | pure registry: named PCM slots, master volume, music intent, wav/mp3 **decode bridge** | both (extern-free) |
| `lib/hamsdl_audio_dev.ad` | device backend: open `/dev/audioctl`, stream PCM to `/dev/audio`, one-shot SFX + looping music, volume scaling | `x86_64-adder-user` |
| `lib/hamsdl_audio_host.ad` | host backend: **real** file read + decode, **no-op DAC** so a game's host gate runs | `x86_64-linux` |

The backends expose the **same verb names** on both targets, so a game's device
driver imports `lib.hamsdl_audio_dev` and its host harness imports
`lib.hamsdl_audio_host` — identical call sites, different sink (this is exactly
how `sdl_dev_present` / `sdl_host_present` split the video sink).

## API

```
sdl_audio_init()            -> int32   open the audio device (0 ok, -1 fail)
sdl_load_sound(name, path)  -> int32   decode a .wav/.mp3 into a named PCM slot
                                       (returns the slot index, -1 on failure)
sdl_play_sound(name)        -> int32   play a loaded sound once (0 ok, -1 unknown)
sdl_play_music(path, loop)  -> int32   stream background music; loop!=0 loops
sdl_stop_music()                       stop the music stream
sdl_audio_pump()                       call once per frame: re-stages a looping
                                       clip when it finishes
sdl_set_volume(v)                      master volume 0..128 (SDL_mixer scale)
sdl_audio_volume()          -> int32   read the master volume back
```

## Bridge to the existing audio stack

- **Decode** is delegated to the verified decoders the DE Audio Player already
  ships: `lib/wavdecode.ad` (RIFF/WAVE, 8/16-bit mono/stereo PCM) and
  `lib/mp3decode.ad` (MPEG-1 Layer III). `sdl_load_sound` sniffs the `.mp3`
  extension exactly like `user/hamaudioscene.ad` does, parses the container, and
  copies the decoded PCM span into the registry arena.
- **Playback** on device reuses the same `/dev/audio` staging sequence the DE
  player's driver uses: push `rate`/`channels`/`format` to `/dev/audioctl`,
  `reset`, write the PCM to `/dev/audio` in 4 KiB chunks, `start`. No sockets, no
  ioctls — Plan 9 ctl-file writes only.

## How a game uses it

Device driver (`user/mygame.ad`):

```
from lib.hamsdl_audio import sdl_set_volume
from lib.hamsdl_audio_dev import sdl_audio_init, sdl_load_sound, \
    sdl_play_sound, sdl_play_music, sdl_stop_music, sdl_audio_pump

def main() -> int32:
    sdl_audio_init()
    sdl_set_volume(96)
    sdl_load_sound(cast[Ptr[uint8]]("blip"),
                   cast[Ptr[char]]("/usr/share/sounds/test.wav"))
    sdl_play_music(cast[Ptr[char]]("/usr/share/sounds/theme.wav"), 1)
    # ... game loop:
    #   sdl_dev_pump(); ...update...; sdl_begin_frame(); ...draw...; sdl_dev_present()
    #   if scored: sdl_play_sound(cast[Ptr[uint8]]("blip"))
    #   sdl_audio_pump()          # keeps looping music going
    #   sdl_dev_delay(...)
    return 0
```

The host harness is byte-identical except it imports `lib.hamsdl_audio_host`.
See `user/hamsdl_audio_demo.ad` (device) and `user/hamsdl_audio_host.ad` (host).

## Scope / honest v1 limits

- **Single channel.** There is one HDA output stream, so a new `sdl_play_sound`
  or `sdl_play_music` **replaces** whatever is currently sounding — there is no
  software mixer summing two sources yet. `sdl_play_sound` preempts music. A
  future v2 can add a small software mixer (sum + clip into a scratch buffer)
  for overlapping SFX; the registry already stores every sound's raw PCM.
- **Staged-clip cap.** A single staged clip is bounded by the HDA DMA buffer
  (`HDA_CAP` = 256 KiB). A longer looping clip replays the staged head — the same
  bound the DE player has today; lifting it needs incremental re-staging.
- **Registry arena** is 512 KiB shared across up to 8 named sounds (plus the
  reserved `__music__` slot); loads past that are clamped. Fine for SFX + one
  music track, which is the SDL_mixer common case.
- **Format** is whatever the decoders accept: PCM WAV (8/16-bit, mono/stereo)
  and MPEG-1 Layer III MP3.

## Verification

- `scripts/test_hamsdl_audio_host.sh` (registered in `ci_battery_manifest.txt`):
  QEMU-free host gate. `sdl_load_sound` decodes the shipped
  `tests/fixtures/sounds/test.wav` to the exact format Python's `wave` reports
  (22050 Hz mono 16-bit, 105836 PCM bytes) and `test.mp3` to real PCM (44100 Hz);
  `sdl_play_sound` targets the loaded slot and rejects an unknown name; volume
  round-trips + clamps; `sdl_play_music` latches the loop. It also compiles the
  native device build (`user/hamsdl_audio_demo.ad`) for `x86_64-adder-user`.
- Real DAC output (guest -> `devaudio` -> HDA -> codec -> captured samples) is
  proven by the existing on-device gate `scripts/test_hamaudio_playback.sh`,
  which exercises the identical `/dev/audioctl` + `/dev/audio` staging sequence
  this backend uses.
