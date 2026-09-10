<div align="center">

<img src="icon.png" width="120" alt="AeriaLite">

# AeriaLite

**Apple's aerial footage as a native macOS video wallpaper.**

[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#install)
[![Dependencies](https://img.shields.io/badge/dependencies-0-2ea043)](Package.swift)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

A focused alternative to [Aerial](https://github.com/AerialScreensaver/Aerial): the same Apple aerial catalogue, a small playlist UI, bounded storage, and a native macOS Wallpaper Extension backend.

The app process does not draw the desktop. It publishes playback commands to an extension hosted by `WallpaperAgent`; that extension returns a remote Core Animation context containing an `AVPlayerLayer`. There is no borderless-window renderer and no fallback path. macOS therefore owns Space placement, Mission Control, the login screen, and menu-bar tinting.

## Against Aerial

|                      | AeriaLite                                        | Aerial 4.x                                                            |
| -------------------- | ------------------------------------------------ | --------------------------------------------------------------------- |
| Primary mode         | wallpaper                                        | screensaver; wallpaper in the 4.1 beta                                |
| How it draws         | native macOS Wallpaper Extension                | native Wallpaper Extension in the 4.1 beta                            |
| Stored per clip      | 47 MB average, conformed to 1080p at 2.5 Mbps    | Apple's file as downloaded; the 4K masters run 145 MB per 137 seconds |
| Library ceiling      | a byte and count cap you set, 3 GB by default    | no published cap                                                      |
| Feature surface      | playlist, transport, cache policy                | overlays, weather, time-of-day, live cams, shortcuts                  |
| Runtime dependencies | none                                             | Sparkle, KeyboardShortcuts, PaperSaver, an OpenWeather key            |

Aerial is the better choice if you want a screensaver, overlays, or live camera feeds. AeriaLite stays intentionally narrow: wallpapers, transport, names, and explicit cache policy.

## Native wallpaper backend

macOS 26 hosts wallpapers through `WallpaperExtensionKit`, a private Swift framework, and AeriaLite conforms to its `WallpaperExtension` protocol: it hands `WallpaperAgent` a `CALayer` and lets macOS own everything around it. It is the actual wallpaper—not a desktop-level window—so the white reveal gradient shown by the old path is gone; the menu bar samples the same content macOS is presenting, and Spaces, Mission Control, and the login screen are the system's problem rather than this code's.

The SDK ships a link stub for that framework but no Swift module, so `vendor/WallpaperExtensionKit.swiftinterface` declares the subset AeriaLite uses, recovered from the shipped binary; [`technical-spec.md`](technical-spec.md) records how, and why the recovery is checkable rather than guessed. Aerial's public repository does not include its `Aerial4WallpaperExtension` target or backend source, so none of this came from there.

It builds with stable Xcode 26 and targets macOS 26. The build stops on unsupported SDKs rather than producing an unverified native extension, and it never silently installs the retired AppKit renderer.

## How it stays off your disk

Apple's masters are 145 MB for 137 seconds and there are 152 of them, so keeping the catalogue as shipped costs about 22 GB. Two things stop that.

Downloads are conformed on arrival to 1080p at a 2.5 Mbps cap, trimmed at 180 seconds. A measured 15-clip library takes 711 MB, an average of 47 MB a clip.

Streamed clips are evicted least-recently-used against a byte and count cap, so the on-disk set has a ceiling you set rather than one the catalogue sets. `Wallpapers/` is never evicted and never counted against it. A Download click moves an existing stream—or lands a new fetch—there before transcoding begins, so quitting during a long encode cannot lose it.

## Install

```bash
git clone https://github.com/jacksoswag/AeriaLite.git
cd AeriaLite && ./scripts/install.sh
```

Builds release, bundles `aerialite.app` into `~/Applications`, symlinks `aerialite` onto your PATH, and starts it. The app adds itself to Login Items on first run, so the wallpaper is up before you are; remove it there to stop that. Set `APPS` or `BIN_DIR` to put either somewhere else.

Installing selects AeriaLite for both the desktop and the idle screen macOS shows once the Mac is left alone; the latter otherwise stays on Apple's aerial and covers AeriaLite whenever you step away. System Settings > Wallpaper puts either back.

Then fill the library:

```bash
aerialite catalog
```

Requires macOS 26 and Xcode 26. The installer stages the bundle before replacing anything and
treats native registration plus a fresh extension heartbeat as mandatory. If activation fails, it
restores the prior wallpaper selection and app but leaves AeriaLite stopped. There is deliberately
no renderer fallback.

WallpaperAgent requires the containing app and extension to carry the same Apple-issued team
identity. A paid Developer Program membership is not required for personal use: signing into Xcode
with a personal Apple Account creates a free Personal Team. Create its Apple Development identity
under **Xcode > Settings > Accounts > Manage Certificates**, then choose it explicitly when building
or installing outside Xcode:

```bash
AERIALITE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install.sh
```

An ad-hoc bundle remains useful for compile and signature-structure checks, but the installer
refuses to select it: `WallpaperAgent` will not hold a wallpaper from an extension whose team
identity does not match its containing app.

## Use

The menu bar icon opens a panel: the playlist with drag reordering, a filter for All / Favorites / Downloaded, transport controls, a position slider that snaps to keyframes, and speed from .12x (an exact 0.125 rate) to 5x. Click a clip to play it, the star to favourite it, the arrow to keep it offline.

Two commands beyond the agent:

```bash
aerialite catalog
aerialite prep <input> [-o out] [--keep 0-1] [--size WxH] [--bitrate BPS] [--keyframe S] [--max-seconds N]
```

`catalog` imports Apple's aerial manifest as rows with links and nothing downloaded. `prep` is the transcoder the agent shells out to, usable on any file of your own.

## Configuration

`/Users/Shared/AeriaLite/config.json` is hand-edited and never written by the panel. `wallpapers.json` beside it is the opposite, fully owned by the UI, so nothing needs a text editor to change what plays.

```json
{
  "streams":   { "resolution": "native", "framesKept": 0.5, "maxSeconds": 0 },
  "downloads": { "resolution": "1080p", "framesKept": 0.25,
                 "bitrate": 2500000, "maxSeconds": 180 },
  "maxCache":  { "space": "3000", "videos": 2, "capAtHigh": false },
  "streamMode": 1,
  "defaultView": "Favorites",
  "defSpeed": 1
}
```

`framesKept` is a fraction of the source's own frames, so `0.5` halves a 239.76fps master to 119.88 without touching duration or speed. `resolution` is `native`, `1080p` or `4k`; native means the display's backing store, which on a scaled Retina panel is neither the point size nor the panel size. A `bitrate` of 0 or absent matches the source's own bits per pixel.

`defaultView` pins the panel to a filter on every launch, one of `All`, `Favorites`, `Downloaded`, or an array of them. Leave the key out and it reopens on whatever view you left it on, which `wallpapers.json` remembers. Either way the view is the queue: a clip filtered out goes off the screen and out of the rotation together.

`streamMode` decides where a clip comes from: `0` plays only what is on disk and greys the rest, `1` prefers downloads and fetches what is missing, and `2` refreshes streamed cache copies while retaining the same clip's durable download if the network transfer fails.

## What plays while a clip is being encoded

A stream fetch lands in the evictable cache and plays immediately. A download lands directly in `Wallpapers/`, or moves an already-cached master there, before its transcode begins. The transcode writes beside the source and atomically replaces it only after a valid output exists, so failure or interruption leaves the original playable.

Nothing waits on the encoder, which matters more than it sounds: 137 seconds of 120fps video is 16,000 frames, the same count as nine minutes of ordinary 30fps footage. Conforms run strictly one at a time, at background priority, out of process.

## Build and test

```bash
swift build -c release -Xswiftc -gnone
swift test
./tests/run-tests.sh --smk    # encodes a generated clip, checks the output profile
./tests/run-tests.sh --perf   # samples the menu app and native extension separately
```

`-gnone` is required on toolchains shipping without `dsymutil`, where a release build otherwise fails at the debug-symbol step. The smoke suite creates and inspects its fixtures with AVFoundation, so it does not require Homebrew, `ffmpeg`, or `ffprobe`. Runs land in `tests/reports/`, which is where every number above comes from.

## Layout

```
src/aerialite/       menu app, transcoder, catalogue, cache and IPC
src/wallpaper-extension/  native WallpaperAgent backend
vendor/              reconstructed WallpaperExtensionKit interface
scripts/             install.sh, bundle.sh, fetch-aerials.sh, trim.sh, to-av1.sh
tests/               run-tests.sh --smk --perf, reports/
technical-spec.md    native protocol, playback, downloads and storage
```

[`technical-spec.md`](technical-spec.md) carries the native protocol boundary, atomic download lifecycle, migration rules, and transcoder details.

## Credits

The footage is Apple's and stays Apple's; this fetches it from the same manifest the system does. [Aerial](https://github.com/AerialScreensaver/Aerial) did the catalogue work first, and its source is where the macOS 240fps manifest URL is recoverable from. The code here is MIT, see [LICENSE](LICENSE).
