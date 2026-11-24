# Driver spike

Phase 0 of [the driver plan](../docs/driver-architecture.md): a throwaway pass-through driver to answer whether the approach works on this Mac. Not part of the app.

- `driver/`: the "Volumist Spike" virtual output device (AudioServerPlugIn, C). Applies a per-process gain in `ProcessOutput` and writes the mix to shared memory in `WriteMix`.
- `host/spike-host.c`: stands in for Volumist. Creates the shared memory, sets gains, plays the mix to a real device, and prints what the driver reports.
- `host/spike-tone.c`: plays a sine to a chosen device, giving the spike a client with a known level.

## Build, install, remove

```bash
./build.sh
```

The easiest way to install is the double-click installers. Build them with `./make-installer.sh`, then open `build/Install Volumist Spike.pkg`; `build/Uninstall Volumist Spike.pkg` removes the driver. Both ask for an admin password and restart Core Audio, so all sound cuts out briefly.

Or from Terminal:

```bash
sudo cp -R build/VolumistSpike.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
```

Remove it the same way:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VolumistSpike.driver && sudo killall coreaudiod
```

The spike device never becomes the default output by itself.

## Tests

Silent check (host output goes to BlackHole), tone at 0.5 with gain 0.25, so the expected peak is 0.125:

```bash
./build/spike-host --out BlackHole2ch_UID --gain-all 0.25 --seconds 8 &
./build/spike-tone VolumistSpike_UID 6
```

Driver log:

```bash
log show --last 5m --predicate 'subsystem == "app.volumist.spike"' --style compact
```
