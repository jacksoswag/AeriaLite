# AeriaLite

Apple's aerial footage as a macOS wallpaper, for **18 MB** of memory and about 1% of one core.

A lighter alternative to [Aerial](https://github.com/AerialScreensaver/Aerial). Same 152 clips of 4K SDR at 239.76fps, drawn as a wallpaper rather than a screensaver, stored at roughly a third the bytes, with the cost measured and published rather than assumed.

Playing 2940x1912 HEVC costs 18 MB of physical footprint, dropping to 0.0% CPU when a fullscreen space hides it. The renderer reads *compressed* samples and hands them straight to the compositor, so the decoded picture lives in IOSurfaces that belong to WindowServer and are charged to no process.

## Against Aerial

|  | AeriaLite | Aerial 4.x |
| --- | --- | --- |
| Primary mode | wallpaper | screensaver; wallpaper in the 4.1 beta |
| How it draws | one borderless window per screen, its own player | macOS's App Extension host, wallpaper set through PaperSaver |
| Memory while playing | 18 MB `phys_footprint`, measured | not published |
| Stored per clip | 47 MB average, conformed to 1080p at 2.5 Mbps | Apple's file as downloaded; the 4K masters run 145 MB per 137 seconds |
| Library ceiling | a byte and count cap you set, 3 GB by default | no published cap |
| Feature surface | playlist, transport, cache policy | overlays, weather, time-of-day, live cams, shortcuts |
| Runtime dependencies | none | Sparkle, KeyboardShortcuts, PaperSaver, an OpenWeather key |

Aerial publishes no memory figure and this project has not measured one, so the memory row is a falsifiable claim about AeriaLite rather than a benchmark against Aerial. Run `footprint -p $(pgrep aerialite)` and check it.

Aerial is the better choice if you want a screensaver, overlays, or live camera feeds. This is the better choice if you want a wallpaper whose cost you can name.

## Why not the built-in one

macOS routes video wallpapers through `idleassetsd` and a `WallpaperVideoExtension`, which keeps a managed asset store, crossfade machinery, and a decoder running whether or not anything is looking at it. None of it is configurable and all of it is resident. WallpaperAgent alone measures 10 MB before a single frame is drawn.

AeriaLite is one borderless `NSWindow` per screen hosting an `AVSampleBufferDisplayLayer`, using public AppKit and AVFoundation plus one private call to place the window on every Space.

Starting it boots `com.apple.wallpaper.agent` out of the login session, so nothing of Apple's is decoding behind a picture you cannot see. Killing it alone does nothing, since launchd has it back in under two seconds. Quitting AeriaLite bootstraps the agent back and hands the desktop over.

## How it stays small

`AVAssetReaderTrackOutput` with `outputSettings: nil` is the whole trick. Passthrough yields sample buffers of a few tens of KB rather than 24 MB frames, and decode happens inside the display layer's own VideoToolbox session. The file stays on disk and is read through the unified buffer cache, where pages are purgeable and belong to nobody.

Memory does not move with library size, cache depth, resolution or framerate. One reader is open at a time, and the 18 MB is close to framework baseline.

## How it stays off your disk

Apple's masters are 145 MB for 137 seconds and there are 152 of them, so keeping the catalogue as shipped costs about 22 GB. Two things stop that.

Downloads are conformed on arrival to 1080p at a 2.5 Mbps cap, trimmed at 180 seconds. A measured 15-clip library takes 711 MB, an average of 47 MB a clip.

Streamed clips are evicted least-recently-used against a byte and count cap, so the on-disk set has a ceiling you set rather than one the catalogue sets. `persistent/` is never evicted and never counted against it.

## Install

```bash
./scripts/install.sh
```

Builds release, bundles `aerialite.app` into `~/Applications`, symlinks `aerialite` onto your PATH, and registers a login agent so the wallpaper is up before you are.

Requires macOS 15+ and a Swift toolchain. No dependencies.

## Use

The menu bar icon opens a panel: the playlist with drag reordering, a filter for All / Favorites / Downloaded, transport controls, a position slider that snaps to keyframes, and speed from 0.25x to 5x. Click a clip to play it, the star to favourite it, the arrow to keep it offline.

Two commands beyond the agent:

```bash
aerialite catalog
aerialite prep <input> [-o out] [--keep 0-1] [--size WxH] [--bitrate BPS] [--keyframe S] [--max-seconds N]
```

`catalog` imports Apple's aerial manifest as rows with links and nothing downloaded. `prep` is the transcoder the agent shells out to, usable on any file of your own.

## Configuration

`~/Library/Application Support/AeriaLite/config.json` is hand-edited and never written by the panel. `wallpapers.json` beside it is the opposite: fully owned by the UI, so nothing needs a text editor to change what plays.

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

## Layout

```
src/aerialite/  renderer, transcoder, catalogue, panel
tests/          run-tests.sh --smk --perf, reports/
scripts/        build.sh, bundle.sh, install.sh
docs/           technical-spec.md
```
