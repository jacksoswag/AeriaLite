# AeriaLite transition repair — verified September 12, 2026

Installed and running build: `20260912172452`. The installed app and extension match the signed build output byte for byte. Configuration is unchanged.

## Cause

The custom blend implementation remains saved in commit `6c8d618`. The old renderer used `CAMetalDisplayLink`, tied to the wallpaper layer. Fullscreen hides that layer and stops its callbacks. The watchdog treated 26 unsuccessful link restarts as a permanent fault, stopped the compositor and switched to plain video playback for the rest of the session. In the controlled reproduction, callbacks stopped at 2,776, rendered frames stopped at 2,767, and the 26th retry switched the renderer to `fallback` with reason `display-link-no-callbacks`.

## Repair

The renderer now uses a display-wide `CVDisplayLink` with callbacks coalesced onto the main queue. Playback and the existing difference blend keep rendering while the desktop is hidden, so independent wallpaper capture clients such as Glassium receive live transitions. The animation shader, timing configuration and colour calculations are unchanged.

The watchdog distinguishes clock interruptions from continuous callbacks that produce no frames. Explicit pause suspends rendering and resume gets fresh decode grace. Renderer status now records callback, GPU completion, presentation and transition counters plus fallback reasons. Decoder surfaces stay retained until GPU work completes. The bundle entry-point check also consumes the complete `otool` output, avoiding a false failure from `grep -q` and shell pipefail.

## Verification

- All 29 unit tests passed, including five new watchdog regression tests.
- Hidden desktop, before starting any capture client: 1,680 completed frames over 28 seconds, approximately 60 fps, with zero clock restarts or fallback.
- Final installed build, fullscreen: next, previous, seek, automatic end-of-clip transition, and eight-second pause/resume passed.
- Fullscreen next produced 87 GPU-completed transition frames; seek followed by automatic rotation produced 181.
- The installed Glassium native capture helper used its existing wallpaper capture path while Finder stayed fullscreen: 707 frames received, 705 changing frames, 137 frames during transitions, and 136 distinct transition frames.
- Signed build and native activation passed; `git diff --check` and shell syntax validation passed.
- Test command changes were restored, the menu app resumed, Finder exited fullscreen, and AeriaLite remains running with renderer state `metal`.

The build emits macOS deprecation warnings for CVDisplayLink. This API remains functional on the tested system and provides the visibility-independent clock verified above. Display sleep/wake and multiple physical displays were not exercised in this run.

No commit or push was made.
