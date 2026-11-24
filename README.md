# Volumist

A per-app volume mixer that lives in the macOS menu bar, laid out like the system Sound menu.

- **Sound**: volume for the current output device (follows the volume keys).
- **Applications**: a slider and mute button for each app that's playing audio, with the current track title for Music, Spotify and TV. Settings are remembered per app.
- **Output** / **Input**: switch the default output or input device. Each list opens collapsed to the selected device. Click the section header to see the others.

Requires macOS 15+. The first time you change an app's volume, macOS asks for permission to capture audio from other apps (System Settings › Privacy & Security › Screen & System Audio Recording).

## How it works

Each adjusted app gets a Core Audio **process tap** (`CATapDescription`, muted-when-tapped) and a private aggregate device made of the tap plus the current output device. An IOProc copies the tapped audio to the output with a gain ramp (`Volumist/Audio/AppTap.swift`). If Volumist quits, the taps go away and apps play at full volume again.

Helper processes are grouped under the app the user sees (e.g. `com.apple.WebKit.GPU` → Safari) using the process's responsible PID.

## Build

```bash
xcodebuild -project Volumist.xcodeproj -scheme Volumist -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Volumist.app
```

Or open `Volumist.xcodeproj` in Xcode and run. Builds are ad-hoc signed, so macOS may ask for the audio-capture permission again after a rebuild.

### Self-test (Debug builds)

Plays a tone through `afplay`, taps it into BlackHole (nothing is audible), and reports the level at gains 1, 0.25 and 0:

```bash
open -W -n build/DerivedData/Build/Products/Debug/Volumist.app --args --self-test /path/to/tone.wav /tmp/volumist-report.txt
```
