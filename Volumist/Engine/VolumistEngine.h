// The app side of the Volumist driver: creates the shared memory (unnamed) and heartbeat that make
// the "Volumist" device appear, hands the memory to the driver over a socket, publishes per-app
// gain rules, and plays the driver's mix to the real output device with drift correction. C
// because the render path is real-time.
#pragma once

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct VEEngine VEEngine;

typedef struct {
    uint64_t underruns;   // render callbacks that found too little audio (outside idle periods)
    uint64_t resyncs;     // times the read position was reset
    double lagFrames;     // smoothed frames buffered between the driver and the output
    double ratio;         // current resampling ratio (1 = none)
    uint32_t targetFrames;
} VEStats;

typedef struct {
    uint32_t pid;
    uint32_t ownerPID;
    float peak;           // max |sample| after gain since the last call
} VEPeak;

/// Creates the shared memory, starts the heartbeat, and listens on `socketPath` (the driver's path
/// if NULL). The memory is only handed to peers running as `peerUID`; pass -1 for Core Audio's
/// _coreaudiod account (what the real driver runs as).
VEEngine *ve_create(const char *socketPath, int peerUID);
/// Stops output and removes the shared memory; the Volumist device disappears.
void ve_destroy(VEEngine *engine);

/// Plays the mix to `device` (replacing any previous output) and asks the driver to run at the
/// device's sample rate. Input streams on the device are left off.
OSStatus ve_set_output(VEEngine *engine, AudioObjectID device);
void ve_stop_output(VEEngine *engine);

/// Gain rules: call begin, add each rule, then commit. Commit updates the shared table in place
/// so a rule that stays never disappears, even briefly.
void ve_rules_begin(VEEngine *engine);
void ve_rules_add(VEEngine *engine, uint32_t pid, const char *bundleID, float gain);
void ve_rules_commit(VEEngine *engine);

bool ve_device_visible(VEEngine *engine);

/// The driver's last answer to the handover (VD_REPLY_*), or -1 if no driver has connected yet.
int ve_driver_reply(VEEngine *engine);

/// The Volumist device's own volume/mute (volume keys, Sound menu). `sequence` changes when either does.
uint32_t ve_device_volume_sequence(VEEngine *engine);
float ve_device_volume(VEEngine *engine);
bool ve_device_mute(VEEngine *engine);
/// Shows the real device's volume/mute on the Volumist device.
void ve_push_volume(VEEngine *engine, float volume, bool mute);

/// Per-client peaks since the last call; returns how many were written to `out`.
int ve_take_peaks(VEEngine *engine, VEPeak *out, int max);
VEStats ve_stats(VEEngine *engine);

/// Renders one output buffer from the ring (what the IOProc calls). Exposed for tests.
void ve_render(VEEngine *engine, AudioBufferList *output, double outputRate);
/// Test hooks: the shared memory, so a test can play the driver's part; pausing the heartbeat.
void *ve_shared_for_test(VEEngine *engine);
void ve_pause_heartbeat_for_test(VEEngine *engine, bool paused);
