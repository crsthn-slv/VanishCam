# VanishCam

macOS menu-bar app that makes you vanish from your webcam with a hand gesture. Works in any call app
(Zoom, Meet, Teams, FaceTime…) through the OBS Virtual Camera.

| Gesture | Effect |
|---|---|
| ✌️ V sign | **Dissolve** — you burn away into blue dust |
| 🙏 Hand seal (fingers interlaced, index fingers up) | **Substitution** — smoke puff, a log takes your place |
| Two fingers on your forehead (hold 1 s) | **Teleport** — speed lines and a flash |

All gestures are active at once; switch off the ones you don't want in the menu. Make any enabled gesture
again to reappear. Gestures misfiring? Settings → Calibrate gestures… records your own V sign and hand seal (about a minute) and stores them in `~/Library/Application Support/VanishCam/gestures.json`. The camera only runs while a call app is using the OBS Virtual Camera.

## Requirements
- macOS 14+ (Apple Silicon or Intel), Swift 5.9 toolchain
- [OBS Studio](https://obsproject.com): start its Virtual Camera once, then quit OBS. In your call app pick **OBS Virtual Camera**.

## Build
```sh
scripts/make_app.sh        # builds build/VanishCam.app and opens it
swift test -c release
```

## Background
- **Real room:** click *Recapture Background* and step out of frame for a few seconds.
- **macOS background effect** (Control Center → Video Effects → Background) also works; the app reads the selected image.

## Assets
`Assets/teleport.wav` and the log sprite `Assets/log.png` are included. The substitution sound
(`Assets/poof.mp3`) is not: drop your own file with that name in `Assets/` and rebuild.

## Credits
Inspired by [vanish_webcam](https://github.com/Nicovic17/vanish_webcam). MIT licensed.
