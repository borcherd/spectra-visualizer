# Spectra

A GPU-accelerated music visualiser for macOS. It listens to whatever your Mac is
playing and turns it into endlessly varied, randomly generated visuals, in the
spirit of the classic Winamp / Windows Media Player era.

- **Listens to system output** through a Core Audio process tap (macOS 14.2+). No virtual audio driver needed.
- **Rendered entirely on the GPU** with Metal: a feedback buffer that is warped, faded and repainted every frame, plus bloom and a finishing pass.
- **Random scenes**: every scene is generated from a seed (motion, layers, palette) and morphs into the next one in time with the beat.
- **Shows the song**: title, artist and cover art read directly from Spotify or Apple Music on your Mac. No login or API key.
- **Player controls**: play / pause, next, previous and a seek bar for Spotify or Apple Music appear along the bottom when the mouse is over the window.
- **Karaoke lyrics**: time-synced lyrics in the middle of the picture. Songs with per-word timing light up word by word (this is what keeps fast or overlapping vocals in step); songs with only per-line timing light up a line at a time. Lyrics come from [LRCLIB](https://lrclib.net), a free public database; turning karaoke on sends the song's title, artist, album and length there, and nothing else.
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
| Space | Play / pause (new scene when no player is open) |
| N / → | New random scene |
| ← | Previous scene |
| [ / ] | Previous / next song |
| K | Karaoke lyrics on / off |
| ↑ / ↓ | Show lyrics earlier / later, 0.1 s at a time |
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

## Licence

MIT. See [LICENSE](LICENSE). Spectra is not affiliated with Spotify or Apple.

## Roadmap

**v1 (this version)**: system-audio visualiser with generated scenes and a settings panel.

**v2 (in progress, branch `v2-player-karaoke`)**: a player with the visualiser built in, plus a karaoke mode.

- Done: transport controls and seek bar for Spotify / Apple Music, time-synced karaoke lyrics.
- Next candidates: search and playlists (needs the Spotify Web API and a login), playing local music files, and vocal reduction for a true karaoke track.

**v3 (planned)**: the same visuals on Mac, Windows, the web and smart TVs. The thinking so far is in [issue #1](https://github.com/borcherd/spectra-visualizer/issues/1).
