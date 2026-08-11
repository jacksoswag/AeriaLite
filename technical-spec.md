# AeriaLite technical spec

A macOS video wallpaper renderer and its companion transcoder, built to hold no decoded frame, to stop decoding in a fullscreen space, and to keep a bounded amount of video on disk. Public AppKit, AVFoundation, SwiftUI and CoreGraphics, plus three private CoreGraphics Services calls for Space membership. No external dependencies at runtime.

It covers the same catalogue as `AerialScreensaver/Aerial` and takes the opposite shape: a wallpaper with its own window and player rather than a screensaver hosted in Apple's App Extension, no overlay surface, and every cost measured in `tests/reports/`.

## Binary shape

One executable, three commands.

| Command | Does |
| --- | --- |
| `aerialite play` (also the no-argument default) | runs the renderer as a foreground-less agent until killed |
| `aerialite prep <input> [flags]` | transcodes a source clip to a profile and exits |
| `aerialite catalog` | imports Apple's macOS aerial manifest into `wallpapers.json` |

`main.swift` dispatches on `argv[1]` and calls `setvbuf(stdout, nil, _IOLBF, 0)` first, because launchd redirects stdout to a file where block buffering hides every line until the process dies.

## Source layout

| File | Holds |
| --- | --- |
| `main.swift` | argument dispatch |
| `App.swift` | `NSApplicationDelegate`, status item, popover, menu bar glyph |
| `AppState.swift` | owns catalogue, settings and walls; fetch, prefetch, conform queue |
| `Wall.swift` | one screen's window, player and visibility gate |
| `Player.swift` | passthrough playlist playback |
| `Clip.swift` | one file parsed once; keyframe-grid measurement |
| `DesktopWindow.swift` | the borderless window and its level |
| `Spaces.swift` | private CGS calls placing the window on every ordinary Space |
| `Coverage.swift` | whether our own window is on screen |
| `AppleWallpaper.swift` | culls macOS's own wallpaper agent at launch, restores it on quit |
| `Catalog.swift` | `wallpapers.json` model, ordering, filtering |
| `Settings.swift` | `config.json` model, resolution presets |
| `Library.swift` | path resolution, fetch, conform, cache eviction |
| `Migration.swift` | disk reconciliation at launch; `CatalogImport` |
| `Prep.swift` | the transcoder |
| `Paths.swift` | every disk location; the one-shot move off the old root |
| `ControlPanel.swift` | the SwiftUI panel |

## Playback

`Player` feeds an `AVSampleBufferDisplayLayer` driven by an `AVSampleBufferRenderSynchronizer`. `AVAssetReaderTrackOutput` is created with `outputSettings: nil`, so what crosses the process is compressed samples of a few tens of KB. Decode happens inside the layer's own VideoToolbox session against IOSurfaces the compositor already owns. No display link is involved.

Two values carry the timeline. `offset` is the synchroniser time at which the current reader's first sample is shown; `clipStart` is how far into the clip that reader began. Position inside the clip is `clipStart + (now - offset)`, which survives seeking.

The reader runs ahead of the picture, so a clip is opened seconds before the compositor reaches it. `Player` records one `Segment` per clip and picks by the synchroniser's clock, which keeps the readout describing what is on screen rather than what has merely been read.

Everything mutable belongs to the `feed` queue at `.userInitiated`. That QoS is load-bearing: at a background priority the queue is descheduled under contention and late samples read as stutter.

`setPlaylist` edits the queue in place. A clip still in the new list keeps playing at its own position, so reordering, renaming, favouriting and filtering never cut the picture. A clip that left the list plays out with the cursor at `-1`, and the new list governs only what follows.

Seeks snap to the keyframe grid. A passthrough reader cannot begin mid-GOP, and `AVAssetReader.timeRange` falls back to the preceding sync sample, so landing anywhere else puts the picture up to a GOP behind the readout. The grid is measured off the file rather than computed from config, because VideoToolbox treats `keyframeSeconds` as a ceiling and lands under it: asked for 1.0s it emits 0.9675s. Measurement runs on a background queue *after* the picture is up, since scanning for two sync samples in a 4K/240 master reads roughly 1,200 samples.

## The gate

`Coverage.isVisible` reads `kCGWindowIsOnscreen` for AeriaLite's own window. Two earlier approaches failed and should not be retried: `NSWindow.occlusionState` reports raw 8192 with `.visible` never set below normal window level and emits no change notification; and scanning for a layer-0 window whose bounds contain `CGDisplayBounds` never matches, because a real fullscreen window measures (0, 33, 1470, 923) against display bounds of (0, 0, 1470, 956).

The query is a synchronous IPC into WindowServer, which is also the process compositing the video, so it runs off the main thread and hops back with the boolean.

Gating is asymmetric. Becoming visible applies at once; becoming hidden waits 0.75s behind a generation counter, because a window animating to full size reports not-covering for a beat. A space change is chased at 60ms for 1.8s, since the notification arrives before window coordinates settle.

`playWhileFullscreen` selects 0 stop, 1 pause, 2 ignore. Pause keeps the decoder's last frame, the queue position and the play head.

## Spaces

`collectionBehavior` is `[.ignoresCycle]` and nothing more. Space membership comes from `CGSAddWindowsToSpaces`, given every Space of `type == 0` from `CGSCopyManagedDisplaySpaces`; fullscreen Spaces are excluded so the wallpaper never covers a fullscreen app.

Any `collectionBehavior` flag that also claims a Space drags the active one while a transition resolves. `.fullScreenNone` took a fullscreen cycle from 4 space changes to 11. `.stationary` threw the desktop rightward on an adjacent swipe, because an adjacent swipe renders both Spaces at once and a window required on both while forbidden to move has no valid position.

Registration happens at window creation and again after every `orderFront`, never on a space change. Ordering out drops the registration, so a window brought back without re-registering belongs to no Space and never shows. Re-registering *during* a transition drags the active Space, which is the same failure as the flags.

## Apple's wallpaper agent

`AppState.init` takes `com.apple.wallpaper.agent` out of the login domain before the cache pass, since a live agent rewrites what was just deleted. Its window sits under AeriaLite's, so a configured aerial holds a second decoder open behind a picture nobody can see.

Killing the processes does nothing on its own: launchd has the agent back inside two seconds. `launchctl bootout gui/<uid>/com.apple.wallpaper.agent` is what makes it stay dead for the session. The ExtensionKit extensions are separate processes that outlive the agent, so a `pkill -u <uid> -f` on `WallpaperAgent|WallpaperAerialsExtension` follows it, catching both those and the plugin processes running out of `WallpaperAgent.app`. `wallpaperexportd` is root-owned and left alone, and `idleassetsd` downloads assets rather than drawing them, so neither is touched.

Quitting bootstraps the job back and kickstarts it, because bootstrap alone registers an on-demand job that draws nothing. That path exists only because `App` puts a `DispatchSourceSignal` on SIGTERM: AppKit leaves the default action in place, so launchd stopping the agent would skip `applicationWillTerminate` entirely and leave the desktop with no wallpaper of either kind.

The menu bar's auto-reveal strip tints from the desktop picture rather than from what is on screen, so culling the agent removes any chance of that band ever matching the video.

## Threading

The main actor owns `AppState`, the catalogue and the panel. `Player` owns the `feed` queue. Cache eviction, the keyframe scan and the coverage query all run on background queues, because each does synchronous filesystem or IPC work that shows as dropped frames from the main thread.

## Transcoding

`Prep` reads with a decoding `AVAssetReaderTrackOutput` and writes HEVC Main10 through `AVAssetWriter`, which selects VideoToolbox hardware encode on Apple silicon. No audio track is added.

| Flag | Default | Does |
| --- | --- | --- |
| `-o <path>` | `persistent/<input stem>.mp4` | where the encode is written |
| `--keep <0-1>` | profile `framesKept` | fraction of the source's frames to keep |
| `--size <WxH>` | profile `resolution`, resolved | output dimensions, forced even |
| `--bitrate <bps>` | profile `bitrate` | average target; 0 or absent matches the source's bits per pixel |
| `--keyframe <s>` | profile `keyframeSeconds` | ceiling on the gap between sync samples |
| `--max-seconds <n>` | profile `maxSeconds` | trim at the reader; 0 keeps the whole clip |

Flags override the profile they default from, which is `downloads` when `prep` is run by hand and whichever profile the fetch used when the agent shells out.

`--keep` is a fraction of the source's own rate, resolved against the clip rather than an assumed number, so a 240 master and a 30 one both mean what the flag says. At or above the source rate every frame is kept and carries its original timestamp: no uniform grid is imposed, because `minFrameDuration` is the tightest gap rather than the average, and grid-stamping one 29.97 master at its 39.2ms minimum squeezed 60s into 46s. Below it, samples are selected against a step of `240000 / fps` ticks, a timescale that divides 239.76 and every halving of it exactly.

Both keyframe caps are set, `AVVideoMaxKeyFrameIntervalKey` and `AVVideoMaxKeyFrameIntervalDurationKey`, so the sync grid holds in seconds even where the cadence clamps.

Trimming happens at the reader's `timeRange` rather than after, so nothing past `maxSeconds` is ever encoded. A `maxSeconds` of 0 keeps the whole clip.

`Library.conform` shells out to `aerialite prep` rather than calling it in-process, because a failure in the encoder cannot then take the agent with it. The subprocess runs at `.background` quality of service. Conforms are strictly serialised through one queue: three concurrent hardware encodes contend for the same media engine and the contention is visible in playback.

### Measured cost

Against a 137s Apple master, 32,865 frames at 239.76, encoded to 2940x1912:

| `framesKept` | Output rate | Frames | Wall | vs realtime |
| --- | --- | --- | --- | --- |
| 1.0 | 239.76 | 32,865 | 305s | 2.23x |
| 0.5 | 119.88 | 16,433 | 210s | 1.53x |
| 0.25 | 59.94 | 8,217 | 106s | 0.77x |

Decode is the floor at roughly 116s: every source frame must be decoded even when it is about to be discarded. Encode throughput is about 78 frames/sec at that size, and cost is linear in output pixels, not source pixels. The scaler is free, measured at 1.4% over feeding it native directly.

Storage is bitrate times duration and nothing else. Halving the framerate shrank a file 8%, not 50%, because the bitrate target bound first; with a cap set, resolution stops affecting size at all.

## Fetch and cache

A fetch lands Apple's master, writes it into the catalogue and pushes it into the playlist immediately, then conforms behind the picture. `conform` rewrites the same path and every clip is re-read from disk when it comes round, so the encoded version swaps in at a loop or track change rather than cutting into what is on screen. Forcing the swap mid-clip was built and removed: it flushed the sample queue and rewound up to a GOP.

`streamMode` selects the source. 0 plays only what is on disk and greys the rest; 1 prefers `persistent/` and fetches what is missing; 2 streams everything, falling back to that same clip's downloaded copy when observed throughput drops under 5 Mbps after the first two seconds. The fallback is always the same wallpaper: a slow link changes where a clip comes from, never which clip plays.

`Player.onClipChange` fires the moment a reader opens a new clip, which drives prefetch and eviction off the transition itself rather than a poll. The reader runs ahead of the picture, so the callback carries the opened id: reading `status.id` there would still report the previous clip.

`trimCache` evicts least-recently-used files from the streamed half only, never `persistent/`, and never the file passed as `keep`. That argument is a stem, not a filename. It also clears Apple's own wallpaper caches, since nothing there serves anything while AeriaLite owns the desktop.

Downloads and streams are stored by slug, but files predating the slug carry the display name verbatim; both spellings resolve to the same clip so a download replaces rather than duplicates.

## Native resolution

The encode targets the framebuffer the compositor scans out, which on a scaled Retina display is neither the point size nor the panel size: `frame * backingScaleFactor` gives 2940x1912 where the panel is 2560x1664 and points are 1470x956. Against Apple's 3840x2160 masters that keeps 68% of each frame rather than the 51% the panel would.

Sides are forced even, because 4:2:0 chroma requires it.

## Storage

The library lives under `~/Library/Application Support/AeriaLite/`, and the transient half sits in `~/Library/Caches/AeriaLite/`.

| Path | Holds |
| --- | --- |
| `config.json` | hand-edited settings, never written by the panel |
| `wallpapers.json` | the catalogue and the view it was left on, fully owned by the panel |
| `Wallpapers/` | decoded downloads, never evicted |
| `Caches/AeriaLite/` | every fetched master, streamed or offline alike |

Every master lands in the cache regardless of how it was asked for, and what happens next is the only difference between a download and a stream: a download is decoded into `Wallpapers/` and its master deleted, while a streamed clip is decoded in place and stays evictable. Living in `Wallpapers/` is therefore the whole of what makes a clip read as downloaded, so `Entry` records nothing about it and `Library.isDownloaded` is a path prefix test. The cache being a standard `Library/Caches` location is what keeps it out of Time Machine.

The whole root is bounded. Downloads land conformed at 1080p under a 2.5 Mbps cap and trimmed at 180 seconds, which measures 47 MB a clip against Apple's 145 MB masters, and the cache is evicted least-recently-used against `maxCache`. A 15-clip library measured 711 MB; the same 15 masters would be 2.2 GB and the full 152-clip catalogue about 22 GB.

`Migration.flatten` empties the `Wallpapers/persistent/` subfolder that downloads used to sit in, moving its files up into `Wallpapers/` and repointing the rows that addressed them. One-shot, and it can go once no install predates the change.

The filter is restored at launch from `wallpapers.json`, and `defaultView` in `config.json` overrides it when set, naming one filter or an array of them and matched case-insensitively. It overrides without recording, so removing the key returns to the remembered view. `AppState.select` is the only writer: persisting from the `filters` observer instead also catches the launch assignment, because a property with a default is already initialised by the time `init` runs, and `defaultView` would overwrite the view it stands in for.

`Catalog` decodes field by field for the same reason `Entry` and `Settings` do. The synthesised initialiser treats a defaulted property as a required key, so a `wallpapers.json` written before `view` existed would fail to parse and take the whole library with it.

A malformed `config.json` falls back to defaults rather than being rewritten over the top of someone's work. `Entry.source.path` is the whole availability test: nothing is inferred from a folder, so a hand-pointed file anywhere works exactly like a downloaded one, and renaming an entry cannot break playback because the filename never moves.

## Catalogue

`aerialite catalog` reads Apple's macOS aerial manifest, which carries 152 assets with exactly one URL key each, `url-4K-SDR-240FPS`. It lives on a content-addressed `itunes-assets` path that is not guessable from the tvOS URL shape; `resources-17` through `resources-20` do not exist. The tvOS manifests under `sylvan.apple.com/Aerials/` are a separate catalogue at 29.97fps with five URL keys, and no 1080p 240fps variant exists in any of them.

Apple ships several clips per place, so bare labels collide; the import numbers them in shot order.

## Build

```bash
swift build -c release -Xswiftc -gnone
```

`-gnone` is required: this toolchain has no `dsymutil`, and a release build without it fails at the debug-symbol step.

```bash
./tests/run-tests.sh --smk    # encodes a generated clip, checks the output profile
./tests/run-tests.sh --perf   # plays it and samples the renderer's cost
```
