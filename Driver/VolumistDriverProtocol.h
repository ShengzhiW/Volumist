// Shared-memory protocol between Volumist.app and the Volumist audio driver.
//
// The app creates the region (VD_SHM_NAME) and keeps a heartbeat in it. The driver, inside
// coreaudiod's driver service, attaches when the region appears and publishes the "Volumist"
// device only while the heartbeat is fresh, so if the app quits or crashes the device vanishes
// and macOS falls back to the real output.
//
// Fields are plain integers so Swift can import the structs. Every cross-process access goes
// through the vd_* inline accessors, which use C11 atomic builtins.
#pragma once

#include <stdint.h>

#define VD_SHM_NAME "/app.volumist.driver.v1"  // macOS limits shm names to 31 characters
#define VD_MAGIC 0x5644584Du                   // 'VDXM'
#define VD_VERSION 1u
#define VD_DEVICE_UID "app.volumist.device"
#define VD_MAX_CLIENTS 256
#define VD_MAX_RULES 256
#define VD_CHANNELS 2
#define VD_RING_FRAMES 32768u                   // power of two; ~170 ms at 192 kHz
#define VD_HEARTBEAT_TIMEOUT_NS 1500000000ull   // device disappears 1.5 s after the app stops beating
#define VD_BUNDLE_ID_LENGTH 128

/// Gain rule published by the app. A client gets the gain of the first rule that matches, in
/// order of precedence: its own PID, its owner's PID (the app responsible for a helper process,
/// e.g. Safari for com.apple.WebKit.GPU), then its bundle ID hash.
typedef struct {
    uint32_t active;      // 0 = slot unused; the app sets it last, after the other fields
    uint32_t pid;         // 0 = don't match by PID
    uint64_t bundleHash;  // vd_hash(bundle ID); 0 = don't match by bundle
    uint32_t gainBits;    // float bits; 1.0 = unchanged
    uint32_t reserved;
} VDRule;

/// A process connected to the device, published by the driver.
typedef struct {
    uint32_t pid;         // 0 = slot unused (written last when adding, first when removing)
    uint32_t ownerPID;    // responsible process, or 0 if the driver couldn't find it
    uint32_t clientID;
    uint32_t peakBits;    // float bits: max |sample| after gain since the app last took it
    uint32_t gainBits;    // float bits: gain the driver is applying now
    uint32_t reserved;
    uint64_t bundleHash;
    char bundleID[VD_BUNDLE_ID_LENGTH];
} VDClient;

typedef struct {
    // Written once by the app when it creates the region.
    uint32_t magic;
    uint32_t version;
    uint32_t hostPID;
    uint32_t reserved0;

    // Written by the app.
    uint64_t heartbeatNanos;        // clock_gettime_nsec_np(CLOCK_UPTIME_RAW), at least every 500 ms
    uint32_t requestedSampleRate;   // Hz; 0 = no preference. The driver follows it (real output's rate)
    uint32_t requestedVolumeBits;   // float bits; applied when requestedVolumeSeq changes
    uint32_t requestedVolumeSeq;
    uint32_t requestedMute;         // applied when requestedMuteSeq changes
    uint32_t requestedMuteSeq;
    uint32_t reserved1;

    // Written by the driver.
    uint32_t driverPID;
    uint32_t attachCount;
    uint32_t deviceVisible;
    uint32_t sampleRate;            // current nominal rate, Hz
    uint32_t volumeBits;            // device volume scalar (float bits), as set by the user or app
    uint32_t mute;
    uint32_t volumeSeq;             // increments whenever the volume or mute changes
    uint32_t ioRunning;             // number of clients doing IO
    uint32_t ownerLookupWorks;      // 1 once the driver has resolved a helper's owner process
    uint32_t clientCount;
    uint32_t droppedClients;        // clients that didn't fit in the table
    uint32_t reserved2;
    uint64_t writeFrame;            // sample time just past the last mix written to the ring
    uint64_t mixCycles;
    uint64_t clientsAdded;
    uint64_t clientsRemoved;

    VDRule rules[VD_MAX_RULES];
    VDClient clients[VD_MAX_CLIENTS];
    float ring[VD_RING_FRAMES * VD_CHANNELS];  // interleaved mix, indexed by sample time
} VDShared;

// MARK: - Atomic accessors

static inline uint32_t vd_load32(const uint32_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void vd_store32(uint32_t *p, uint32_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline uint64_t vd_load64(const uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void vd_store64(uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline uint32_t vd_add32(uint32_t *p, uint32_t v) { return __atomic_add_fetch(p, v, __ATOMIC_ACQ_REL); }
static inline uint64_t vd_add64(uint64_t *p, uint64_t v) { return __atomic_add_fetch(p, v, __ATOMIC_ACQ_REL); }
static inline uint32_t vd_exchange32(uint32_t *p, uint32_t v) { return __atomic_exchange_n(p, v, __ATOMIC_ACQ_REL); }

static inline float vd_float(uint32_t bits) { union { uint32_t u; float f; } v = {bits}; return v.f; }
static inline uint32_t vd_bits(float value) { union { float f; uint32_t u; } v = {value}; return v.u; }

/// Keeps the larger of the stored and new peak.
static inline void vd_raise_peak(uint32_t *p, float peak) {
    uint32_t current = __atomic_load_n(p, __ATOMIC_RELAXED);
    while (peak > vd_float(current) &&
           !__atomic_compare_exchange_n(p, &current, vd_bits(peak), 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
    }
}

/// FNV-1a over a bundle ID; never returns 0 (which means "no bundle").
static inline uint64_t vd_hash(const char *text) {
    uint64_t hash = 1469598103934665603ull;
    for (; text && *text; text++) {
        hash ^= (unsigned char)*text;
        hash *= 1099511628211ull;
    }
    return hash ? hash : 1;
}
