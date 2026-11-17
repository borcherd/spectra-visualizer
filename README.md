# Spectra

A GPU-accelerated music visualiser for macOS. It listens to whatever your Mac is
playing and turns it into endlessly varied, randomly generated visuals, in the
spirit of the classic Winamp / Windows Media Player era.

- **Listens to system output** through a Core Audio process tap (macOS 14.2+). No virtual audio driver needed.
- **Rendered entirely on the GPU** with Metal: a feedback buffer that is warped, faded and repainted every frame, plus bloom and a finishing pass.
- **Random scenes**: every scene is generated from a seed (motion, layers, palette) and morphs into the next one in time with the beat.
- **Customisable**: palette, kaleidoscope, trails, glow, motion, which layers are allowed, classic EQ bars, film grain, frame-rate cap and more. Scenes can be locked or saved as favourites.

## Build and run

Requires macOS 14.2 or later and Xcode (or the Swift toolchain).

```bash
./build.sh run
```

This builds `build/Spectra.app` and launches it. The first launch asks for
permission to capture system audio; nothing is recorded or sent anywhere.

## Controls

| Key | Action |
| --- | --- |
| Space / → | New random scene |
| ← | Previous scene |
| L | Lock the current scene |
| D | Save the scene as a favourite |
| S | Show / hide the settings panel |
| F or double-click | Full screen |

## Testing visuals without the app

The binary can render scenes off screen against a built-in demo groove and
write a contact sheet, which is how the shaders are checked:

```bash
.build/release/Spectra --snapshot build/snapshots/sheet.png --scenes 12 --cols 4 --size 480x270 --seed 1
```

## Roadmap

**v1 (this version)**: system-audio visualiser with generated scenes and a settings panel.

**v2 (planned, not started)**: a full music player with the visualiser built in, plus a karaoke mode:

- Local library playback (and possibly a streaming service's playback API).
- Time-synced lyrics fetched from a lyrics API and drawn over the visuals.
- Optional vocal removal for a true karaoke track.
