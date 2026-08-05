# Market analysis

## Verdict

AeriaLite is a strong portfolio artifact and a weak product. The measured claims behind it, 18 MB of physical footprint and 47 MB a clip on disk, are specific, falsifiable and unusual enough to carry a resume conversation on their own. The market it would ship into is one where the incumbent is free, has 21,000 stars, and is actively maintained. Build it for the demonstration, not the adoption.

Roughly 75% confident. The uncertainty is not about the technical claim, which is measured, but about whether an open-source audience distinguishes "does the same thing more cheaply" from "does the same thing".

Naming it against the incumbent is a real bet and it cuts both ways. It wins the one sentence of attention a reader gives an unknown repo, since "lighter Aerial" is understood before the README loads. It also fixes the project as a derivative in the same sentence, invites a features comparison this deliberately loses, and leans on a name whose owner never agreed to it. Worth it while the point being made is a measurement rather than a product.

## What it actually is

A macOS video wallpaper that never materialises a decoded frame. `AVAssetReaderTrackOutput` in passthrough mode hands compressed sample buffers straight to `AVSampleBufferDisplayLayer`, so decode happens inside the compositor's own VideoToolbox session against IOSurfaces charged to no process. Everything else in the project follows from that one decision.

## Competition

| Project | Stars | Maintained | What it does |
| --- | --- | --- | --- |
| `AerialScreensaver/Aerial` | 481 | yes, pushed 08/2026 | the live Aerial: App plus App Extension, screensaver with a wallpaper mode in the 4.1 beta |
| `JohnCoates/Aerial` | 20,968 | archived at 05/2026 | the same project's `.saver` era, where the stars and the inbound links still point |
| `mczachurski/wallpapper` | 3,426 | yes, pushed 07/2026 | builds dynamic HEIC wallpapers from stills |
| `GhostNaN/mpvpaper` | 1,556 | yes, pushed 07/2026 | mpv on a Wayland background, Linux only |
| macOS built-in | n/a | Apple | aerials as wallpaper, via `idleassetsd` |

Aerial is the reference point and the problem. It is free, mature, and its catalogue work is the thing AeriaLite borrowed: the macOS 240fps manifest URL is recoverable from Aerial's source and from essentially nowhere else. A project that reads a competitor's source to find an API endpoint is not going to displace it on features, and the feature gap is wide on purpose: Aerial carries overlays, weather, time-of-day switching, live camera feeds and global shortcuts against four dependencies.

The gap AeriaLite occupies is narrower and real. Aerial is a screensaver first, hosted in Apple's App Extension and setting the wallpaper through PaperSaver rather than drawing it; the built-in path is a wallpaper but keeps a managed asset store and a decoder resident with no exposed control. Neither publishes a memory number and neither has been measured here, so the comparison AeriaLite can honestly make is that it publishes one at all.

Storage is the second axis and the more legible one. Apple's masters are 145 MB per 137-second clip and the catalogue holds 152 of them, so keeping it as shipped is about 22 GB. Conforming on arrival measures 47 MB a clip, and the streamed half is capped. That argument needs no baseline from a competitor to land.

## Users

Three plausible groups, in descending size:

- **People who want aerials as a wallpaper rather than a screensaver.** Largest group, and the least likely to care about the footprint claim. They will compare against a built-in feature that already works.
- **People running stripped or memory-constrained Macs.** Small, self-selecting, and exactly the audience the measurement is for. This owner's own machine is the archetype: SIP disabled, `mobileassetd` culled, `WallpaperAgent` killed.
- **Developers reading the source for the passthrough technique.** The most valuable group per person and the one that generates stars rather than users. The `AVSampleBufferDisplayLayer` pattern is documented by Apple but rarely demonstrated against a real memory budget.

## Willingness to pay

Effectively zero. The incumbent is free and open source, and wallpaper utilities are a category where paid apps exist but the free tier is the default expectation. Nothing here supports a price.

## Defensibility

None in the usual sense, and that is fine for a portfolio piece. The passthrough technique is public API. The catalogue is Apple's. The Space registration uses private CGS calls anyone can find. What is not trivially copied is the accumulated set of measured failures: which `collectionBehavior` flags drag the active Space, that `NSWindow.occlusionState` is dead below normal window level, that `minFrameDuration` is the tightest gap rather than the average, that VideoToolbox undershoots `keyframeSeconds`. That knowledge is the artifact, and it lives in the notes as much as the code.

## Legal and risk

The videos are Apple's, served from `sylvan.apple.com`, and AeriaLite fetches them the same way Aerial has for years without incident. That is a precedent, not a licence. The catalogue is not redistributed; only URLs are stored, and the manifest is fetched at runtime. A project that bundled the media would be a different question.

The name is the newer exposure. "AeriaLite" is built on Aerial's, which is an unregistered mark on an MIT-licensed project, so the licence grants nothing about it either way. Nobody is likely to object over a free tool that credits and links the original in its first paragraph, but the fallback if anyone does is a rename, and that is cheap now and expensive after a release has links pointing at it.

The private CGS calls (`CGSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, `CGSAddWindowsToSpaces`) are unversioned and undocumented. They cannot be shipped through the App Store and can break on any macOS release. For a personal tool distributed as source, that is an acceptable cost; for anything else it is a hard ceiling.

## Portfolio read

This is the strongest argument for the project. It demonstrates, in about 2,100 lines of Swift:

- A non-obvious systems decision (passthrough decode) with a measured result attached
- Correct diagnosis under a compositor that lies: three window-visibility approaches tried, two abandoned with the reason recorded
- Real profiling discipline, including the distinction between `phys_footprint` and RSS that most memory claims get wrong
- A pipeline decision defended by numbers: conform at 0.77x realtime keeps ahead of playback, 1.53x does not

Against the rest of this portfolio it sits beside Spectra as the second macOS-internals project, which is a coherent pair rather than a repetition: Spectra is about drawing over the desktop, AeriaLite is about drawing under it, and they share the same hard-won knowledge of window levels and Spaces.

The honest weakness for a recruiter audience is scope. It is a wallpaper. The interesting content is in how it is built, which requires the reader to open the source or the spec. The README carries the memory number in its first paragraph for exactly that reason.

## Path to market

There isn't one worth pursuing, and the recommendation is to stop looking for it. Publish the source, lead with the measurement, and let it be a demonstration. The specific moves that make that work:

1. **Keep the numbers in front.** "18 MB for a 4K video wallpaper" and "47 MB a clip against Apple's 145" are the whole pitch and they must survive every rewrite of the README.
2. **Publish the failures.** The Spaces and occlusion findings are more useful to more people than the app is, and they are what a developer audience actually links to.
3. **Do not chase feature parity with Aerial.** Multi-monitor arrangements, weather overlays, and a settings pane are how a small project becomes a large unmaintained one. The name already promises less; keep the promise.
4. **Measure Aerial before claiming to beat it, or do not claim it.** The comparison table says "not published" in the memory row because nobody has run `footprint` against Aerial's extension. One afternoon closes that, and until it does, every comparative sentence has to be about architecture and disk rather than speed.
