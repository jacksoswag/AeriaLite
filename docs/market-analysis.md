# Market analysis

## Verdict

Kino is a strong portfolio artifact and a weak product. The measured claim behind it, 18 MB of physical footprint for a 4K video wallpaper, is specific, falsifiable and unusual enough to carry a resume conversation on its own. The market it would ship into is one where the incumbent is free, has 21,000 stars, and is actively maintained. Build it for the demonstration, not the adoption.

Roughly 75% confident. The uncertainty is not about the technical claim, which is measured, but about whether an open-source audience distinguishes "does the same thing more cheaply" from "does the same thing".

## What it actually is

A macOS video wallpaper that never materialises a decoded frame. `AVAssetReaderTrackOutput` in passthrough mode hands compressed sample buffers straight to `AVSampleBufferDisplayLayer`, so decode happens inside the compositor's own VideoToolbox session against IOSurfaces charged to no process. Everything else in the project follows from that one decision.

## Competition

| Project | Stars | Maintained | What it does |
| --- | --- | --- | --- |
| `JohnCoates/Aerial` | 20,968 | yes, pushed 05/2026 | Apple TV aerials as a screensaver, with a large settings surface |
| `mczachurski/wallpapper` | 3,426 | yes, pushed 07/2026 | builds dynamic HEIC wallpapers from stills |
| `GhostNaN/mpvpaper` | 1,556 | yes, pushed 07/2026 | mpv on a Wayland background, Linux only |
| macOS built-in | n/a | Apple | aerials as wallpaper, via `idleassetsd` |

Aerial is the reference point and the problem. It is free, mature, has 17 open issues against 1,037 forks, and its catalogue work is the thing Kino borrowed: the macOS 240fps manifest URL is recoverable from Aerial's source and from essentially nowhere else. A project that reads a competitor's source to find an API endpoint is not going to displace it on features.

The gap Kino occupies is narrower and real. Aerial is a screensaver first; the built-in path is a wallpaper but keeps a managed asset store and a decoder resident with no exposed control. Neither publishes a memory number. Kino is a wallpaper that measures itself.

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

The videos are Apple's, served from `sylvan.apple.com`, and Kino fetches them the same way Aerial has for years without incident. That is a precedent, not a licence. The catalogue is not redistributed; only URLs are stored, and the manifest is fetched at runtime. A project that bundled the media would be a different question.

The private CGS calls (`CGSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, `CGSAddWindowsToSpaces`) are unversioned and undocumented. They cannot be shipped through the App Store and can break on any macOS release. For a personal tool distributed as source, that is an acceptable cost; for anything else it is a hard ceiling.

## Portfolio read

This is the strongest argument for the project. It demonstrates, in about 2,100 lines of Swift:

- A non-obvious systems decision (passthrough decode) with a measured result attached
- Correct diagnosis under a compositor that lies: three window-visibility approaches tried, two abandoned with the reason recorded
- Real profiling discipline, including the distinction between `phys_footprint` and RSS that most memory claims get wrong
- A pipeline decision defended by numbers: conform at 0.77x realtime keeps ahead of playback, 1.53x does not

Against the rest of this portfolio it sits beside Spectra as the second macOS-internals project, which is a coherent pair rather than a repetition: Spectra is about drawing over the desktop, Kino is about drawing under it, and they share the same hard-won knowledge of window levels and Spaces.

The honest weakness for a recruiter audience is scope. It is a wallpaper. The interesting content is in how it is built, which requires the reader to open the source or the spec. The README carries the memory number in its first paragraph for exactly that reason.

## Path to market

There isn't one worth pursuing, and the recommendation is to stop looking for it. Publish the source, lead with the measurement, and let it be a demonstration. The specific moves that make that work:

1. **Keep the number in front.** "18 MB for a 4K video wallpaper" is the whole pitch and it must survive every rewrite of the README.
2. **Publish the failures.** The Spaces and occlusion findings are more useful to more people than the app is, and they are what a developer audience actually links to.
3. **Do not chase feature parity with Aerial.** Multi-monitor arrangements, weather overlays, and a settings pane are how a small project becomes a large unmaintained one.
