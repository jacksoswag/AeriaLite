<div align="center">

<img src="icon.png" width="120" alt="AeriaLite">

# AeriaLite

**Apple's aerial footage as a live macOS wallpaper, for 18 MB of memory and about 1% of one core.**

[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#install)
[![Dependencies](https://img.shields.io/badge/dependencies-0-2ea043)](Package.swift)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

A lighter alternative to [Aerial](https://github.com/AerialScreensaver/Aerial), written in Swift against public AppKit, AVFoundation and SwiftUI, with nothing else linked in. The same 152 clips of Apple's 4K aerial catalogue, drawn as a wallpaper instead of a screensaver, stored at roughly a third of the bytes, with the cost measured and published rather than assumed.

The renderer never materialises a decoded frame. `AVAssetReaderTrackOutput` in passthrough mode hands *compressed* sample buffers of a few tens of KB straight to `AVSampleBufferDisplayLayer`, so decode happens inside the compositor's own VideoToolbox session against IOSurfaces charged to no process. 2,251 lines of Swift, one borderless window per screen, and no menu bar item you did not ask for.

## Measured

On an M3, playing a 2940x1912 HEVC clip:

| | |
| --- | --- |
| Memory while playing | **18 MB** `phys_footprint`, 24 MB against an un-conformed 4K/240 master |
| CPU | ~1% of one core, **0.0%** once a fullscreen space hides it |
| IOSurface pages charged to the process | none |
| Stored per clip | **47 MB** average, against the 145 MB master Apple ships |
| A real 15-clip library | 711 MB |

Memory does not move with library size, cache depth, resolution or framerate. One reader is open at a time and 18 MB is close to framework baseline, so there is no setting that improves it.

```bash
footprint -p $(pgrep -f aerialite.app)
```

## Against Aerial

|                      | AeriaLite                                        | Aerial 4.x                                                            |
| -------------------- | ------------------------------------------------ | --------------------------------------------------------------------- |
| Primary mode         | wallpaper                                        | screensaver; wallpaper in the 4.1 beta                                |
| How it draws         | one borderless window per screen, its own player | macOS's App Extension host, wallpaper set through PaperSaver          |
| Memory while playing | 18 MB `phys_footprint`, measured                 | not published                                                         |
| Stored per clip      | 47 MB average, conformed to 1080p at 2.5 Mbps    | Apple's file as downloaded; the 4K masters run 145 MB per 137 seconds |
| Library ceiling      | a byte and count cap you set, 3 GB by default    | no published cap                                                      |
| Feature surface      | playlist, transport, cache policy                | overlays, weather, time-of-day, live cams, shortcuts                  |
| Runtime dependencies | none                                             | Sparkle, KeyboardShortcuts, PaperSaver, an OpenWeather key            |

Aerial publishes no memory figure and this project has not measured one, so the memory row is a falsifiable claim about AeriaLite rather than a benchmark against Aerial. Run the command above and check it.

Aerial is the better choice if you want a screensaver, overlays, or live camera feeds. This is the better choice if you want a wallpaper whose cost you can name.

## Why not the built-in one

macOS routes video wallpapers through `idleassetsd` and a `WallpaperVideoExtension`, which keeps a managed asset store, crossfade machinery, and a decoder running whether or not anything is looking at it. None of it is configurable and all of it is resident. `WallpaperAgent` alone measures 10 MB before a single frame is drawn.

Starting AeriaLite boots `com.apple.wallpaper.agent` out of the login session, so nothing of Apple's is decoding behind a picture you cannot see. Killing it alone does nothing, since launchd has it back in under two seconds. Quitting AeriaLite bootstraps the agent back and hands the desktop over.

## How it stays off your disk

Apple's masters are 145 MB for 137 seconds and there are 152 of them, so keeping the catalogue as shipped costs about 22 GB. Two things stop that.

Downloads are conformed on arrival to 1080p at a 2.5 Mbps cap, trimmed at 180 seconds. A measured 15-clip library takes 711 MB, an average of 47 MB a clip.

Streamed clips are evicted least-recently-used against a byte and count cap, so the on-disk set has a ceiling you set rather than one the catalogue sets. `persistent/` is never evicted and never counted against it.

## Install

```bash
git clone https://github.com/jacksoswag/AeriaLite.git
cd AeriaLite && ./scripts/install.sh
```

Builds release, bundles `aerialite.app` into `~/Applications`, symlinks `aerialite` onto your PATH, and registers a login agent so the wallpaper is up before you are. Set `APPS` or `BIN_DIR` to put either somewhere else.

Then fill the library:

```bash
aerialite catalog
```

Requires a Swift toolchain. `Package.swift` targets macOS 14; everything here was built and measured on macOS 26, and nothing older has been tried.

## Use

The menu bar icon opens a panel: the playlist with drag reordering, a filter for All / Favorites / Downloaded, transport controls, a position slider that snaps to keyframes, and speed from 0.25x to 5x. Click a clip to play it, the star to favourite it, the arrow to keep it offline.

Two commands beyond the agent:

```bash
aerialite catalog
aerialite prep <input> [-o out] [--keep 0-1] [--size WxH] [--bitrate BPS] [--keyframe S] [--max-seconds N]
```

`catalog` imports Apple's aerial manifest as rows with links and nothing downloaded. `prep` is the transcoder the agent shells out to, usable on any file of your own.

## Configuration

`~/Library/Application Support/AeriaLite/config.json` is hand-edited and never written by the panel. `wallpapers.json` beside it is the opposite, fully owned by the UI, so nothing needs a text editor to change what plays.

```json
{
  "streams":   { "resolution": "native", "framesKept": 0.5, "maxSeconds": 0 },
  "downloads": { "resolution": "1080p", "framesKept": 0.25,
                 "bitrate": 2500000, "maxSeconds": 180 },
  "maxCache":  { "space": "3000", "videos": 2, "capAtHigh": false },
  "streamMode": 1,
  "playWhileFullscreen": 1,
  "defaultView": "Favorites",
  "defSpeed": 1
}
```

`framesKept` is a fraction of the source's own frames, so `0.5` halves a 239.76fps master to 119.88 without touching duration or speed. `resolution` is `native`, `1080p` or `4k`; native means the display's backing store, which on a scaled Retina panel is neither the point size nor the panel size. A `bitrate` of 0 or absent matches the source's own bits per pixel.

`defaultView` pins the panel to a filter on every launch, one of `All`, `Favorites`, `Downloaded`, or an array of them. Leave the key out and it reopens on whatever view you left it on, which `wallpapers.json` remembers. Either way the view is the queue: a clip filtered out goes off the screen and out of the rotation together.

`streamMode` decides where a clip comes from: `0` plays only what is on disk and greys the rest, `1` prefers `persistent/` and fetches what is missing, `2` streams everything and falls back to that clip's own downloaded copy when the link cannot carry it. `playWhileFullscreen` runs 0 stop, 1 pause, 2 ignore.

## What plays while a clip is being encoded

A fetch lands Apple's master in about 1.5 seconds and plays it immediately. The transcode runs behind the picture and rewrites the same path, and since every clip is re-read from disk when it comes round again, the encoded version swaps itself in at a loop or track change.

Nothing waits on the encoder, which matters more than it sounds: 137 seconds of 120fps video is 16,000 frames, the same count as nine minutes of ordinary 30fps footage. Conforms run strictly one at a time, at background priority, out of process.

## Build and test

```bash
swift build -c release -Xswiftc -gnone
./tests/run-tests.sh --smk    # encodes a generated clip, checks the output profile
./tests/run-tests.sh --perf   # plays it and samples the renderer's cost
```

`-gnone` is required on toolchains shipping without `dsymutil`, where a release build otherwise fails at the debug-symbol step. Runs land in `tests/reports/`, which is where every number above comes from.

## Layout

```
src/aerialite/       renderer, transcoder, catalogue, panel
scripts/             install.sh, bundle.sh, fetch-aerials.sh, trim.sh, to-av1.sh
tests/               run-tests.sh --smk --perf, reports/
technical-spec.md    module by module: the gate, Spaces, threading, storage
```

[`technical-spec.md`](technical-spec.md) carries the parts worth reading before changing anything: why `NSWindow.occlusionState` is unusable below normal window level, which `collectionBehavior` flags drag the active Space, and why `minFrameDuration` is the tightest gap between frames rather than the average.

## Credits

The footage is Apple's and stays Apple's; this fetches it from the same manifest the system does. [Aerial](https://github.com/AerialScreensaver/Aerial) did the catalogue work first, and its source is where the macOS 240fps manifest URL is recoverable from. The code here is MIT, see [LICENSE](LICENSE).
