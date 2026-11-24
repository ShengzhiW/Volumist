# Volumist driver

The Volumist audio driver ([plan and results](../docs/driver-architecture.md)): an AudioServerPlugIn that publishes a "Volumist" output device while Volumist.app is running, applies each app's volume as its audio passes through, and hands the mix to the app through shared memory. The app sends it the memory over a socket at `/tmp/app.volumist.driver.sock`, only to Core Audio's account, and the driver checks the app's code signature before using it.

- `VolumistDriverProtocol.h`: the shared-memory layout and atomic accessors, used by both sides.
- `VolumistDriver.c`: the driver.
- `Tests/DriverTests.c`: in-process tests that load a test build of the driver (`VD_TESTING`) and play Core Audio's host, with the app's real engine (`../Volumist/Engine/VolumistEngine.c`) as the other side.
- `Tests/EngineTests.c`: offline tests of the app engine (drift correction, buffers, rules).

```bash
./build.sh --test       # build the driver and run the driver and engine tests
./make-installer.sh     # tests, then build/Install Volumist Driver.pkg and the uninstaller
```

Normally you don't need the packages: the app embeds the driver and installs or updates it from Settings › General. Installing needs an admin password and restarts Core Audio, so sound cuts out briefly. The device only appears while the app is running.
