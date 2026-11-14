# AGENTS.md

Guide for AI coding agents (Claude Code, Codex, etc.) working on VanishCam. Humans: see [CONTRIBUTING.md](CONTRIBUTING.md).

## What this is
macOS menu-bar app. Webcam → Vision (hand gesture + person mask) → Metal effect → OBS Virtual Camera (CoreMediaIO sink). Swift 5.9, macOS 14+, no third-party dependencies.

## Layout
- `Sources/VanishCore/` — library: `Vision/` (gesture + segmentation), `Effects/` (Metal renderers, overlays), `Output/` (OBS sink, UYVY converter), `Pipeline.swift` (state machine), `SettingsStore.swift`.
- `Sources/VanishCamApp/` — SwiftUI menu-bar app (`CameraEngine.swift` owns capture + call detection).
- `Sources/vanishcam/` — CLI harness.
- `Tests/VanishCoreTests/` — tests. `Assets/` — sounds and sprites. `scripts/make_app.sh` — builds `build/VanishCam.app`.
- `NOTES.md` — known debt. Read it before changing call detection or the converter.

## Commands
```sh
swift build                 # compile
swift test -c release       # run tests (same as CI)
scripts/make_app.sh         # assemble and open build/VanishCam.app (needed to try UI/camera changes)
```
`swift build` alone does NOT update `build/VanishCam.app`. Quit the running app (`killall VanishCamApp`) before relaunching.

## Workflow rules
1. Never commit to `main`. One branch per issue: `feat/<slug>`, `fix/<slug>`, `chore/<slug>`. Open a PR with `Closes #N`.
2. Work in your own worktree when running in parallel with other agents.
3. Keep diffs small and in scope. No drive-by refactors; list them as follow-ups.
4. Run `swift build` and `swift test -c release` before pushing. A visual or camera change also needs a manual check: say in the PR what you ran and saw.
5. Conventional commit style: `feat: …`, `fix: …`, `chore: …`, `docs: …`.
6. Squash-merge only.

## Conventions
- Prefer stdlib/AppKit/Vision/Metal. Adding a dependency needs an issue and maintainer approval.
- Publish `@Published` values only on change (a redraw every tick breaks menu hover).
- Mark deliberate shortcuts with a `ponytail:` comment naming the ceiling and the upgrade path.
- Add one small test for non-trivial logic (a branch, a parser, math).
- New effect mode = new `EffectKind` case + `HandPose` case + detector rule + effect renderer + sound + toggle in `EffectToggles` + README table row. Gestures must not collide with existing poses.

## Do not
- Commit sounds/images you don't own the rights to (`Assets/poof.mp3` is gitignored for this reason; no third-party franchise assets).
- Edit or ship anything inside `/Applications/OBS.app`.
- Add telemetry, network calls, or anything that leaves the machine.
- Force-push `main`, rewrite published history, or merge your own PR without maintainer approval.
- Put secrets, tokens, or personal paths in code, logs, or PR text.

## Gotchas
- Call detection depends on the OBS extension's `stop streaming` log line and on `DeviceIsRunningSomewhere` while our sink is paused. Sending frames while idle breaks it.
- The OBS placeholder image shown for a moment when a call starts is OBS's own; we can't change it.
- Camera/Vision/Metal behaviour differs between Apple Silicon and Intel; say which you tested.
