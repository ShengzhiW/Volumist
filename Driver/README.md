# Volumist driver

Phase 1 of [the driver plan](../docs/driver-architecture.md): an AudioServerPlugIn that publishes a "Volumist" output device while Volumist.app is running, applies each app's volume as its audio passes through, and hands the mix to the app through shared memory. Not wired into the app yet; `vd-host` stands in for it.

- `VolumistDriverProtocol.h`: the shared-memory layout and atomic accessors, used by both sides.
- `VolumistDriver.c`: the driver.
- `Tests/DriverTests.c`: in-process tests that load the driver and play both Core Audio's host and the app.
- `Tools/vd-host.c`: test host. Keeps the heartbeat, publishes volume rules, plays the mix to a real device, and mirrors volume and mute.

```bash
./build.sh --test       # build the driver and run the tests
./make-installer.sh     # tests, then build/Install Volumist Driver.pkg, the uninstaller, and build/vd-host
```

Installing needs an admin password and restarts Core Audio, so sound cuts out briefly. The device only appears while the app (or `vd-host`) is running.

```bash
build/vd-host --out <real output UID> --rules rules.txt --seconds 120
```

Rules file lines: `owner Safari.app/Contents/MacOS/Safari 0.3` (an app and its helper processes), `app <path text> <gain>`, or `bundle <bundle ID> <gain>`.
