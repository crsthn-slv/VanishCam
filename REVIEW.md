# Review guidelines

Read by AI reviewers (e.g. cc-auto-review, `/code-review`). Report only real problems with a concrete failure scenario.

## Always check
- Correctness of call detection: nothing may send frames to the OBS sink while idle, or `DeviceIsRunningSomewhere` can no longer tell a call from our own output.
- Main-thread / capture-queue separation: UI state is touched only on the main actor; frames are processed on `vanishcam.app.cam`.
- Memory per frame: no per-frame allocation of large buffers on the hot path.
- Gesture rules don't overlap existing poses (V sign, hand seal, forehead two fingers).
- `@Published` is updated only on change.
- No new dependency, network call, telemetry, or file access outside `~/Library/Application Support/VanishCam`.
- Assets: no third-party copyrighted sounds or images.

## Treat as high risk (send to a human)
`Package.swift`, `scripts/`, `.github/`, `Info.plist`, entitlements, anything touching CoreMediaIO, camera permissions, or login-item registration.

## Don't report
Style nits, naming taste, missing docs on private code, items already listed in `NOTES.md`.
