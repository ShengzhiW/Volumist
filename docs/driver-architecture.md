# Plan: per-app volume through a Volumist audio driver

Status: proposal, nothing built yet. Branch: `driver-architecture`.

## Why

Volumist currently changes an app's volume with Core Audio **process taps**: it captures the app's audio, mutes the original, and plays the capture back at the chosen volume. macOS treats any tap as recording, so it:

- needs the **System Audio Recording** permission, and
- shows the **purple recording dot** in the menu bar whenever a tap runs.

Neither can be turned off. The only way around them is to never capture: put a **virtual output device** (a Core Audio driver, `AudioServerPlugIn`) between apps and the speakers, and change each app's volume inside the driver as its audio passes through.

## Evidence: how AppVolume does it

AppVolume is installed on this Mac. Its installer put a driver at `/Library/Audio/Plug-Ins/HAL/AppVolumeAudioDevice.driver`. Inspecting the bundle (not running it) shows:

| Observed | What it tells us |
|---|---|
| Registered as an `AudioServerPlugIn` factory; Developer ID signed; no entitlements | A standard HAL driver loaded by `coreaudiod`; no special Apple approval needed |
| Written in Rust; links CoreAudio, AudioToolbox, Security | Any language works if it exports the C plug-in interface |
| Log strings: `Client ADDED pid=`, `Settings updated for PID`, `ProcessOutput`, `MixOutput` | The driver identifies each app by process ID and applies its gain per client before mixing |
| Imports `socket`/`connect`, `shm_open`/`mmap`; strings `RING_BUFFER attached shm_name=`, `creator_pid` validation | Control over a socket to its background process; audio through a shared-memory ring buffer the app creates and the driver validates |
| `removing virtual device` when its process isn't connected; the device isn't in the device list now | **The virtual device only exists while the app runs**, so macOS falls back to real speakers if the app quits or crashes |
| `Output device changed to`, `AudioOutput: render_callbacks`, `circular routing guard` | Suggests the driver plays the final mix to the real device itself, guarding against routing into its own device. **Not confirmed.** |

## Architecture

```
 apps ──► [Volumist Device]  (virtual default output, inside coreaudiod)
              │  per app:  ProcessOutput → gain[pid] → meter[pid]
              │  mixed:    WriteMix → ring buffer (shared memory)
              ▼
         Volumist.app ── reads ring buffer ──► real output device (IOProc)
              ▲
              └── control block (shared memory): gains, mutes, client list, levels
```

### 1. The driver (`VolumistDriver.driver`)

- One stereo, 32-bit float output device named "Volumist". Nominal rate follows the real output (44.1–192 kHz).
- `AddDeviceClient` / `RemoveDeviceClient` receive each client's **PID and bundle ID**; keep a fixed table of client slots, so nothing is allocated on the IO thread.
- `DoIOOperation`:
  - `ProcessOutput` (once per client, before mixing): multiply by that client's gain, ramped across the buffer like today's `TapRenderer`; record its peak level.
  - `WriteMix` (the mix): copy into the shared ring buffer for the app.
- Volume and mute controls on the device, so the volume keys and the system Sound menu work. The app mirrors them to the real device.
- **Exists only while Volumist is connected.** On disconnect, remove the device, so macOS switches back to the real output.
- Language: C++ on Apple's *Creating an Audio Server Driver Plug-in* sample (NullAudio), or the MIT-licensed libASPL wrapper. Swift is a poor fit for this real-time, C-ABI code.

### 2. Shared memory between the app and the driver

One region created by the app (for example `/volumist.v1`), attached by the driver:

- **Control block:** per-client gain and mute (atomics written by the app), and the driver's client table (PID, bundle ID, live flag) plus per-client peak levels.
- **Audio ring buffer:** the mix, single producer (driver) and single consumer (app), with read and write positions.
- **Handshake:** a version number, the app's PID and a heartbeat. The driver validates them, as AppVolume checks `creator_pid`. If the heartbeat stops, the driver removes its device.
- The driver runs as `_coreaudiod`, so the region's permissions must let it attach. Find out whether the driver's sandbox allows `shm_open` on our name (AppVolume shows it's possible).

### 3. The app

- **Output engine:** reads the ring buffer and plays it to the real device in an IOProc. Handles clock drift between the virtual device and the hardware with a small adaptive buffer or resampling.
- **Routing:** on launch, remember the real output, make "Volumist" the default, and route to the real one. Choosing an output in our menu changes where the engine plays, not the system default. On quit, restore the real device first.
- **Per-app volume:** replace `AppTap` with writes to the control block. Above 100% becomes possible (AppVolume offers 200%), with a limiter.
- **Playing detection:** read the driver's per-client peaks instead of `LevelMonitor` taps. No dot, and it works while the menu is closed.
- **App list:** keep the current process-based list, plus the driver's client table, which already gives the PID of the process actually playing.
- **Device list:** hide the "Volumist" device from our Output section.
- Now-playing titles, Settings, hiding apps and devices: unchanged.

### 4. Installing and removing

- Installing a HAL driver needs an admin password: copy it to `/Library/Audio/Plug-Ins/HAL`, then restart `coreaudiod`, which cuts all audio for about a second.
- Ship a signed installer package (`pkgbuild`/`productbuild` plus a postinstall script). Show driver status and an Install button in Settings, plus a matching uninstaller.
- Distribution needs Developer ID signing and notarization for both the app and the driver. Whether an ad-hoc-signed driver loads on macOS 27 for local development is an open question for the spike.

## Phases

**0. Spike (de-risk before committing to this).** Build the NullAudio sample as a pass-through device and answer:
1. Does an ad-hoc-signed driver load on macOS 27, or is a Developer ID needed even locally?
2. Do `AddDeviceClient` PIDs match the PIDs Volumist sees, including helper processes like `com.apple.WebKit.GPU`?
3. Can the driver attach to shared memory created by the app?
4. Which route out is better: the app playing the mix (this plan) or the driver playing it itself (what AppVolume appears to do)? Measure latency and stability.
5. Confirm there is no purple dot and no permission prompt.

*Spike results (2026-11-24),* installed with `spike/make-installer.sh`'s package, silent test (tone into the spike device, host output to BlackHole):

1. **Ad-hoc signing: yes.** A locally signed driver loads on macOS 27; "Volumist Spike" appears as a device. No Developer ID needed for development.
2. **Client PIDs: yes.** `AddDeviceClient` reports each process's PID and bundle ID (a command-line tool has no bundle ID). **Every process with an audio client registers with every device**: about 50 here, including `com.apple.WebKit.GPU` helpers. The real driver's client table must be larger than 64 slots.
3. **Shared memory: yes.** The driver, running as `_coreaudiod` in the driver-service helper, attached to the host's `shm_open` region (mode 0666).
4. **Per-app gain: works, exact.** Tone at 0.5: the mix peaked at 0.1250 with gain 0.25 and 0.5000 with gain 1.0, measured both in the driver and in what the host played out. The mix arrived at about 48,128 frames/s.
5. **No indicators: confirmed.** During 20-second runs there was no purple recording dot. The first run did show an orange microphone indicator ("Claude used microphone"). Cause: the host's IOProc was on BlackHole, which also has an input stream, and the HAL starts a device's inputs unless told otherwise. After setting `kAudioDevicePropertyIOProcStreamUsage` to turn the input streams off, Core Audio reported no process running input and no dot appeared.

Findings that change the plan:
- **Apply gains before the app's first buffer.** The host only learned the tone's PID from its once-a-second poll, so the first ~1.5 s played at full volume. The real app should publish gains keyed by bundle ID (plus responsible app) ahead of time, so the driver can resolve a new client's gain inside `AddDeviceClient`.
- **Clock drift is still unmeasured.** BlackHole runs at 44.1 kHz, so the host fell behind about 4,000 frames/s and resynced. That's a rate mismatch, not drift. Drift and latency need a 48 kHz real output (or rate conversion in the host).
- **Never start input you don't use.** When the app's output device also has an input (BlackHole, USB headsets, audio interfaces), turn its input streams off with `kAudioDevicePropertyIOProcStreamUsage`, or macOS shows the microphone indicator. The current tap-based Volumist has the same exposure: its aggregate devices include the output device's input streams.
- **The driver's `os_log` messages don't appear in `log show`.** Diagnostics should go through shared-memory counters, as this spike's do.
*Listening test (2026-11-24),* 5 minutes. Default output set to "Volumist Spike", the host playing the mix to the Audioengine 2+ (USB, 48 kHz, no inputs), Safari playing video:

- **Real app: works.** Safari's audio arrives from its `com.apple.WebKit.GPU` helper. `responsibility_get_pid_responsible_for_pid` traces it to Safari, and a gain keyed to Safari applied only to it. 30% dropped its peak from about 0.75 to 0.05 within a second, audibly quieter with no clicks; back to 100% restored it. Judged by ear: "quieter, sounds fine".
- **Dropouts: none while playing.** About 225 s of continuous playback across 4 stretches had 0 underruns. All 305 underruns happened while nothing was playing and the device's IO had stopped, so the host was starved, which is expected.
- **Latency:** the host's buffer held 1,340–2,300 frames (28–48 ms) on top of the device buffers, with a 2,048-frame target. No lip-sync complaint, but that's near the noticeable range; the real engine should aim for 512–1,024 frames.
- **Drift: small but real.** Over the longest stretch (149 s) the buffer level trended about −2 frames/s (about −40 ppm). That's within per-buffer jitter, so it's a rough figure. At that rate an uncorrected buffer would hit its limit and glitch every few minutes to tens of minutes. **Phase 2 needs drift correction**: adaptive resampling in the app, or clocking the virtual device from the real one.
- Not yet tried: the route where the driver plays to hardware itself.

**1. Driver MVP.** Virtual device, client table, per-client gain, mix into the ring buffer, heartbeat, remove the device on disconnect.

*Phase 1 status (2026-11-24): done.* The driver lives in `Driver/` (`build.sh --test` builds it and runs 43 in-process tests; `make-installer.sh` builds the packages and the `vd-host` test host). Verified on this Mac with `vd-host` standing in for the app:

- **No device until the app runs:** with nothing running there is no "Volumist" device. It appears about 0.8 s after the host starts, once the shared memory and heartbeat exist.
- **Crash safety:** after `kill -9` of the host, the device vanished in 0.4–0.6 s (the driver sees the dead PID before the 1.5 s heartbeat timeout) and Safari carried on playing through a real device. **macOS falls back to the built-in speakers**, not the previous device, so the app should restore the user's chosen output when it relaunches.
- **Gains from the first buffer:** with "Safari 30%" published before playback, Safari's audio was quiet from the first sound (log: gain 0.30 on the first report). By ear: "quiet from the start".
- **Sample rate follows the real output:** it switched to 44.1 kHz for BlackHole and stayed at 48 kHz for the Audioengine.
- **Owner lookup works inside coreaudiod's sandbox** (`ownerLookupWorks = 1`). The app still publishes rules for an app's helper processes itself (`owner` rules in `vd-host`), which covers helpers the driver reports as their own owner.
- Not yet verified on the real system: volume keys mirrored to the real device (covered by the in-process tests).
- **Security is still open:** the shared memory is created world-readable/writable (0666) so the `_coreaudiod` driver can open it, which lets any local process read the mix or change gains. Before shipping, hand the driver a file descriptor over a socket and verify the app's code signature instead of using a named region.

**2. App output engine.** Ring buffer to real device, drift handling, default-device takeover and restore, volume and mute mirroring.

*Phase 2 status (2026-11-24): working in the app.* `Volumist/Engine/VolumistEngine.c` (C, real-time) creates the shared memory and heartbeat and plays the driver's mix to the real output. It corrects drift by resampling: linear interpolation with a proportional controller on the buffered amount, ±0.3% max, and a target of about 21 ms that grows with the driver's burst size. `DriverEngine.swift` wraps it, and `MixerModel` uses it whenever the driver is installed (Settings › General › Audio Engine can choose audio capture instead).

- **Offline engine tests** (`Driver/Tests/EngineTests.c`, 37 checks, run by `Driver/build.sh --test`): drift from −2000 to +500 ppm is tracked exactly on average, with no dropouts or clicks over 10 simulated minutes per case. Also covered: 128- and 1024-frame buffers, pause/restart, split and mono outputs, in-place rule updates, peaks.
- **In the app** (`--driver-report` debug mode plus normal use): Volumist becomes the default output within 1.5 s and routes to the real device; the Volumist device is hidden from the menu. 0 dropouts, buffer on target, ratio settled at 0.99996 (≈ −40 ppm, as the spike measured). Safari's level arrives through the driver, so the waveform needs no capture.
- **Quit:** the default output goes back to the real device before the Volumist device disappears.
- **Crash:** `kill -9` makes the device vanish in about 0.7 s; on relaunch the app returns to the saved real device (it keeps an "engine active" flag to tell a crash from a clean quit).
- **By ear:** Safari's slider and mute work, and there's **no purple dot** and no permission prompt.
- Each start logs one resync while apps' streams move to the Volumist device; possibly a brief blip.
- Still to check by ear: the volume keys mirroring to the real device (the in-process tests cover the driver side).

**3. Port features.** Per-app volume and mute through the control block; levels from the driver; drop the audio-capture permission UI on this path.

*Phase 3 status:* done as part of phase 2. Per-app volume and mute are driver rules, levels come from the driver, and the capture-permission UI is skipped while the driver is in use.

**4. Installer.** Package, Settings status and install/uninstall, restarting `coreaudiod`.

*Phase 4 status (2026-11-24): done.* A build phase ("Embed Volumist Driver") compiles the driver into `Volumist.app/Contents/Resources`. Settings › General › Audio Engine shows the driver's status (not installed, installed, or update available when the bundled build differs) and installs, updates or uninstalls it through `do shell script … with administrator privileges` (`DriverInstaller.swift`). Fixed paths are shell-quoted; the copy is owned by root:wheel; the spike driver is removed; Core Audio restarts afterwards. Before a change the app gives the default output back; afterwards it rebuilds everything when Core Audio reports `kAudioHardwarePropertyServiceRestarted` (devices, listeners, taps and engine), with a timed fallback if the notification is missed.

Verified on this Mac: Uninstall then Install from Settings both worked with the password prompt. The installed driver is byte-identical to the bundled one, and the running app (same process throughout) came back to driver mode with Volumist as the default output after both Core Audio restarts.

Found while testing and fixed: **a second copy of Volumist broke the first's routing.** It replaced the shared memory, and when it exited the device vanished while the first copy still thought the driver was running. The app now exits at launch if another copy (same bundle ID, debug or installed) is already running.

**5. Hardening.** Sample-rate and device changes, Bluetooth and AirPlay, sleep and wake, crash recovery, apps that pick a specific device.

**6. Decide on taps.** Keep the tap engine as a fallback ("Use audio driver" on or off) until the driver path is proven, then remove it or keep it for users who won't install a driver.

## Risks and open questions

- **Crash safety:** if Volumist dies while "Volumist" is the default output, everything goes silent until the device disappears. The heartbeat plus removing the device must make this recover within about a second. This is the main thing to test.
- **Apps that choose their own device** (DAWs, Zoom, Teams, games) bypass the virtual device, and their volume can't be controlled. Taps could still cover them.
- **Latency:** an extra buffer hop adds a few milliseconds; check A/V sync in video.
- **Fragility:** a driver bug affects all audio, and the driver must be retested on each macOS release.
- **Other virtual-device apps** (SoundSource's ACE, Teams, Zoom, BlackHole, AppVolume's leftover driver) must coexist with ours.
- **Security:** anything that can open the shared memory could change gains or read the mix. Restrict permissions and validate the creator PID.
- **Rate and channel changes** mid-stream: driver and app must agree on the format before resuming IO.
