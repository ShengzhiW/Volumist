// Shared memory between the spike driver (inside coreaudiod) and the spike host app.
// The host creates it; the driver attaches. All cross-process fields are C11 atomics.
#pragma once

#include <stdatomic.h>
#include <stdint.h>

#define VSPIKE_SHM_NAME "/volumist.spike.v1"
#define VSPIKE_MAGIC 0x564D5350u  // 'VMSP'
#define VSPIKE_VERSION 1u
#define VSPIKE_MAX_CLIENTS 64
#define VSPIKE_CHANNELS 2
#define VSPIKE_RING_FRAMES 16384  // power of two
#define VSPIKE_SAMPLE_RATE 48000.0
#define VSPIKE_DEVICE_UID "VolumistSpike_UID"

/// One audio client of the virtual device, published by the driver.
typedef struct {
    _Atomic int32_t pid;          // 0 = slot unused
    _Atomic uint32_t clientID;
    _Atomic uint32_t peakBits;    // max |sample| after gain since the host last read it (float bits)
    char bundleID[128];           // written before pid is published
} VSpikeClient;

/// A per-process gain, written by the host.
typedef struct {
    _Atomic int32_t pid;          // 0 = slot unused
    _Atomic uint32_t gainBits;    // float bits
} VSpikeGain;

typedef struct {
    uint32_t magic;
    uint32_t version;
    int32_t hostPID;
    _Atomic uint64_t hostHeartbeat;     // host increments about once a second

    _Atomic uint64_t driverAttachCount; // driver increments each time it attaches
    _Atomic uint64_t writeFrame;        // driver: sample time just past the last mix written
    _Atomic uint64_t mixCycles;         // driver: WriteMix calls

    VSpikeClient clients[VSPIKE_MAX_CLIENTS];
    VSpikeGain gains[VSPIKE_MAX_CLIENTS];

    float ring[VSPIKE_RING_FRAMES * VSPIKE_CHANNELS];  // interleaved stereo mix
} VSpikeShared;
