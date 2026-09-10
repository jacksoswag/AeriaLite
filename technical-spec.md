# AeriaLite technical spec

AeriaLite is a macOS 26 menu agent plus a native Wallpaper Extension. The app owns catalogue,
downloads, cache policy, and controls. `WallpaperAgent` owns desktop placement and hosts the
extension process. No AppKit desktop window or renderer fallback remains.

## Binary shape

The app executable supports four commands.

| Command | Does |
| --- | --- |
| `aerialite play` | runs the menu agent and publishes playback state |
| `aerialite prep <input> [flags]` | transcodes one source clip |
| `aerialite catalog` | imports Apple's macOS aerial manifest |
| `aerialite activate-native` | registers, selects, and health-checks the extension |

`scripts/bundle.sh` also builds `AeriaLiteWallpaperExtension.appex`. It builds with stable Xcode 26,
targets macOS 26, and requires the macOS 26 SDK. The build script fails explicitly on an unsupported
SDK, verifies the SDK stamp, entry point, and nested signature, and never
substitutes the removed window renderer. It gives both bundles a unique timestamp build number so
PluginKit can distinguish rebuilds.

The extension links with `-e _NSExtensionMain`, as an Xcode app-extension target does. That symbol,
not the Swift `@main` entry point, performs the ExtensionKit check-in and runs the main run loop
before handing control to the `AppExtension` type. Entering at the Swift entry point instead
compiles, signs, registers, and launches identically, and then returns from `main` and exits 0
before `WallpaperAgent` can hold an assertion on the process, so the desktop simply never changes.
Because that failure produces no crash, no error, and no log line of its own, `bundle.sh` asserts
that `LC_MAIN` resolves to the `_NSExtensionMain` stub.

Native installation additionally requires the app and extension to be signed by the same
Apple-issued team identity. A free Xcode Personal Team can provide an Apple Development identity;
paid Developer Program membership is not required for personal testing. The installer rejects
missing or mismatched team identifiers before changing the installed app or wallpaper selection.

## Native framework boundary

macOS 26 hosts wallpapers through `WallpaperExtensionKit`, a private *Swift* framework. Its
`WallpaperExtension` protocol refines `ExtensionFoundation.AppExtension` with one requirement,
`makeWallpaper(request:host:)`, and supplies the `AppExtensionConfiguration` itself. That
configuration is the framework's own type: an extension that vends any other one is not recognised
at the `com.apple.wallpaper` extension point, whatever XPC protocol it goes on to implement. So the
boundary is a conformance, not a wire format, and `WallpaperAgent`—not this code—owns the XPC
contract, the remote `CAContext`, display and Space placement, Mission Control, and the login
screen. AeriaLite implements `Wallpaper`: a `CALayer` to composite, `update`, `snapshot`, and
`invalidate`.

The SDK ships `WallpaperExtensionKit.tbd` but no `.swiftmodule`, so there is nothing to import.
`vendor/WallpaperExtensionKit.swiftinterface` declares the subset AeriaLite uses and is compiled to
a module at build time; the client then links the SDK stub as usual. Its header records how each
declaration was recovered from the shipped binary. Two properties of the framework make this safe:
it is built with library evolution, so resilient types travel indirectly and a passed-through type
needs a name but not a layout, and a protocol's requirements are laid out in source order after its
requirements-base descriptor, so their addresses recover the order a witness table must match.
Getting that order wrong is not a build error—it is a call to the wrong method at runtime—so the
declarations are transcribed rather than guessed, and `nm -u` on the built extension is the check:
every `WallpaperExtensionKit` symbol it imports must be one the framework exports.

Aerial's public repository and `v4.1.0beta15` tag do not contain the `Aerial4WallpaperExtension`
target or its backend source, so this was derived from the shipped framework rather than from it.

The menu agent is a login item, registered by the app itself with `SMAppService` on first run,
and `install.sh` starts it with `open`.

The command file is process-global, so the agent takes an advisory lock before serving `play`: a
second agent's `shutdown()` publishes `running: false` and stops the wallpaper the first one is
driving, and `aerialite` is on PATH with `play` as its default subcommand. The lock is released by
the kernel on exit, and acquisition waits briefly so that installation's handover is not mistaken
for a second agent. The agent also republishes whenever the command file's revision is not the one
it last wrote, since publishing is otherwise driven by state changes and an overwrite leaves the
extension following stale instructions indefinitely.

`NativeWallpaperSession` owns that layer and puts an aspect-fill `AVPlayerLayer` in it. It polls an
atomic command snapshot every 200 ms, applies playlist/transport/rate changes, and writes an atomic
status snapshot. The app regards the backend as live only while that heartbeat is newer than three
seconds.

`snapshot()` decodes a still separately, through `AVAssetImageGenerator` at the playhead, rather
than reusing the playing frame. The host asks for it wherever it cannot run the layer—Mission
Control, the wallpaper grid in System Settings, and the desktop itself while presentation is idle—
and refusing does not fall back to a capture of the layer. It leaves whatever was on screen before,
which reads exactly like an extension that never activated.

Activation writes the same selection into both slots of every store section. `Desktop` is the
wallpaper; `Idle` is what macOS 26 presents once the Mac is left alone, and it defaults to Apple's
own aerial, so filling only `Desktop` leaves an untouched Mac showing Apple's footage over a
backend still decoding underneath.

Native activation removes any old heartbeat, restarts `WallpaperAgent`, and requires a live status
that both postdates that restart and survives a further two seconds. The outgoing agent relaunches
the extension on demand while tearing down, and that short-lived process publishes a heartbeat
newer than the store rewrite, so a single sample taken from before the restart passed installation
on a session that was already dying. A failed check atomically restores the exact pre-activation
wallpaper store, unregisters the failed bundle, and restarts services on that restored state.

## Menu bar item

On macOS 26 an `NSStatusItem` is not a window this process owns. AppKit requests an `FBSScene` from
`com.apple.controlcenter.statusitems` and exports the button into it, so the item is hosted inside
ControlCenter and appears in `CGWindowListCopyWindowInfo` as a level-25 window belonging to *that*
process. `button.window` in this process is a detached host that never reports menu bar coordinates.

Two consequences shaped `App.swift`, and both cost real time to find because neither surfaces an
error to the app.

**The item is created once and never rebuilt.** Any liveness check written against the local
window's frame reads as "not in the menu bar" on every sample, because that window is never placed.
Rebuilding on that signal discards an item ControlCenter has already accepted, and
`removeStatusItem` sends `NSStatusItemClearAutosaveStateAction`, so the saved slot is erased on each
pass. A two-second retry loop written this way produced an endless accept/invalidate cycle,
visible only as paired `hosting scene` / `setting scene invalid` lines exactly 2.000s apart.

Whether an item is really placed is answered by the window list, filtered to ControlCenter rather
than to this process: a placed item appears as a level-25 window owned by ControlCenter and named
after its `autosaveName`. `NSStatusItem Preferred Position` does **not** answer it — that key is
written when an item is dragged to a chosen slot, and apps that have never been dragged are placed
and visible without one.

**Placement is a permission, and it is attributed to whoever launched the app.** ControlCenter groups
each item under the application responsible for the process that created it, persists that grouping
by bundle id in `trackedApplications` in the `group.com.apple.controlcenter` domain, and refuses to
place items belonging to a group whose `isAllowed` is false. An app first launched by a CLI tool is
therefore filed under that tool permanently: the block survives relaunches by any other parent,
ControlCenter restarts, reinstalls, and reboots. `install.sh` does not launch the app for this
reason, and `scripts/detach-menu-bar-group.py` repairs an installation already grouped this way.

Neither condition is reported to the app, which sees a live status item with a valid image and a
non-zero button size throughout. The single diagnostic is one debug line from ControlCenter, emitted
*after* it has already logged accepting and hosting the scene:

```
[com.apple.controlcenter:appStatusItems] Moving host to blocked list; (bid:<id>-<autosaveName>-<pid>)
```

Diagnosing anything here means reading that subsystem at debug level. Window geometry is a proxy and
misleads: revealing an auto-hidden menu bar to measure it restarts Dock, which changes the thing
being measured.

## Source layout

| Path | Holds |
| --- | --- |
| `src/aerialite/App.swift` | menu agent, popover, signal-safe shutdown |
| `src/aerialite/AppState.swift` | catalogue, transfers, conform queue, IPC commands |
| `src/aerialite/NativeActivation.swift` | registration, wallpaper selection, health check |
| `src/aerialite/NativeIPC.swift` | command/status wire format and atomic files |
| `src/aerialite/SingleInstance.swift` | advisory lock keeping one agent on the command file |
| `src/wallpaper-extension/main.swift` | `WallpaperExtension` conformance and video sessions |
| `vendor/WallpaperExtensionKit.swiftinterface` | reconstructed declarations for the private framework |
| `src/aerialite/Library.swift` | resolution, fetch, promotion, conform, eviction |
| `src/aerialite/Migration.swift` | interrupted-work cleanup and storage reconciliation |
| `src/aerialite/CatalogNames.swift` | stable shot-id-to-title curation |
| `src/aerialite/Prep.swift` | HEVC transcoder |

## Download lifecycle

`Wallpapers/` is durable; `Cache/` is evictable. This directory boundary—not a transient catalogue
path—is the download state.

A streamed fetch stages its `URLSession` temporary file inside `Cache/`. A Download action either
moves that cache file into `Wallpapers/` or downloads directly there. In both cases the durable
file exists before transcoding begins. The transcoder writes a hidden sibling and atomically
replaces the source only after a successful exit. A crash therefore leaves either the original or
the complete replacement, never a half-written target. Launch removes abandoned hidden siblings.

HTTP status alone is insufficient: a staged response must be an AVFoundation-playable asset with
at least one video track before it can replace an existing file. Display name, immutable entry ID,
and immutable storage key are separate, so renaming during a transfer cannot orphan its result.

Cache eviction counts both the protected current file and every candidate against byte and count
limits. It removes only `.mp4` files inside `Cache/`, oldest access/modification date first, and
updates accounting only after deletion succeeds. Hidden fetch/encode staging files are excluded
until committed, so eviction cannot race a transfer. It cannot reach `Wallpapers/` or hand-selected
files outside AeriaLite's root.

## Migration and storage

All shared state is under `/Users/Shared/AeriaLite/` so the sandboxed extension and menu app see the
same files.

| Path | Holds |
| --- | --- |
| `config.json` | hand-edited settings |
| `wallpapers.json` | catalogue, names, order, favorites, remembered filter |
| `Wallpapers/` | durable downloaded/conformed videos; never evicted |
| `Cache/` | streamed and prefetched videos; bounded and evictable |
| `Backups/` | five newest pre-activation wallpaper Index backups |
| `playback-command.json` | app-to-extension snapshot |
| `playback-status.json` | extension-to-app snapshot and heartbeat |

Startup recursively merges the previous Application Support and cache roots without overwriting
an existing destination file. A cross-volume move copies first, verifies the byte count, and only
then removes the source. A collision leaves the older source available for manual recovery.
Legacy `Wallpapers/persistent/` downloads are flattened atomically, and catalogue paths into old
evictable caches are forgotten while durable or hand-selected paths remain.

## Transcoding

`Prep` uses `AVAssetReader` and `AVAssetWriter` with VideoToolbox HEVC. `framesKept` is a fraction of
the source cadence, `maxSeconds` trims at the reader, and output dimensions are even for 4:2:0.
Conforms run one at a time in background subprocesses so an encoder failure cannot take down the
menu agent or native wallpaper session.

## Catalogue names

Apple repeats accessibility labels and sometimes leaves them blank. `CatalogNames` keys curated
titles by stable shot ID. Titles are two to four words and omit filler articles/conjunctions where
possible. Re-import improves display names without changing favorites, order, storage names, or
download paths.

## Verification

`swift test` covers invalid-video rejection, atomic replacement, interrupted nested migration,
stable identity across rename/JSON round trips, cache byte/count behavior, and title constraints.
`tests/run-tests.sh --smk` creates a deterministic H.264 fixture with AVFoundation, transcodes it,
and independently verifies the HEVC tag, dimensions, cadence, frame count, and absence of audio.
It has no Homebrew, `ffmpeg`, or `ffprobe` dependency and returns nonzero on any failed assertion.
`--perf` requires an installed, active native extension and samples the menu and extension
processes separately.
