// Spike host: stands in for Volumist.app. Creates the shared memory, sets per-process gains,
// and plays the driver's mix to a real output device. Prints what the driver reports.
//
//   spike-host [--out <deviceUID>] [--gain-all <g>] [--gain <pid> <g>]... [--seconds <n>] [--latency <frames>]

#include <CoreAudio/CoreAudio.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../shared.h"

static VSpikeShared *gShared;
static uint64_t gLatency = 2048;
static uint64_t gReadFrame = 0;
static int gPrimed = 0;
static _Atomic uint64_t gUnderruns = 0;
static _Atomic uint64_t gResyncs = 0;
static _Atomic uint32_t gOutPeakBits = 0;
static _Atomic int64_t gLag = 0;

static float Bits2F(uint32_t b) { float f; memcpy(&f, &b, 4); return f; }
static uint32_t F2Bits(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }

static void RaisePeak(_Atomic uint32_t *bits, float peak) {
    uint32_t cur = atomic_load(bits);
    while (peak > Bits2F(cur) && !atomic_compare_exchange_weak(bits, &cur, F2Bits(peak))) {}
}

static OSStatus PlayMix(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                        const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime; (void)outputTime; (void)context;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
    if (output->mNumberBuffers == 0 || output->mBuffers[0].mNumberChannels == 0) return 0;
    UInt32 channels = output->mBuffers[0].mNumberChannels;
    UInt32 frames = output->mBuffers[0].mDataByteSize / (sizeof(float) * channels);

    uint64_t write = atomic_load_explicit(&gShared->writeFrame, memory_order_acquire);
    if (!gPrimed) {
        if (write < gLatency) return 0;
        gReadFrame = write - gLatency;
        gPrimed = 1;
    }
    if (gReadFrame + frames > write || write - gReadFrame > VSPIKE_RING_FRAMES - 1024) {
        if (gReadFrame + frames > write) atomic_fetch_add(&gUnderruns, 1);
        atomic_fetch_add(&gResyncs, 1);
        gReadFrame = write >= gLatency ? write - gLatency : 0;
        return 0;
    }

    float *first = output->mBuffers[0].mData;
    float *second = output->mNumberBuffers > 1 ? output->mBuffers[1].mData : NULL;
    float peak = 0;
    for (UInt32 f = 0; f < frames; f++) {
        uint64_t index = ((gReadFrame + f) & (VSPIKE_RING_FRAMES - 1)) * VSPIKE_CHANNELS;
        float left = gShared->ring[index], right = gShared->ring[index + 1];
        if (channels >= 2) {
            first[f * channels] = left;
            first[f * channels + 1] = right;
        } else {
            first[f] = left;
            if (second) second[f] = right;
        }
        peak = fmaxf(peak, fmaxf(fabsf(left), fabsf(right)));
    }
    gReadFrame += frames;
    RaisePeak(&gOutPeakBits, peak);
    atomic_store(&gLag, (int64_t)(write - gReadFrame));
    return 0;
}

static AudioObjectID DeviceForUID(const char *uid) {
    CFStringRef cfUID = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectID device = kAudioObjectUnknown;
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(cfUID), &cfUID, &size, &device);
    CFRelease(cfUID);
    return device;
}

static void Describe(AudioObjectID device) {
    CFStringRef name = NULL;
    Float64 rate = 0;
    AudioObjectPropertyAddress a = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(name);
    AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &name);
    a.mSelector = kAudioDevicePropertyNominalSampleRate;
    size = sizeof(rate);
    AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &rate);
    char buffer[256] = "?";
    if (name) { CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8); CFRelease(name); }
    printf("output device: %s (id %u) at %.0f Hz%s\n", buffer, device, rate,
           rate == VSPIKE_SAMPLE_RATE ? "" : "  ** rate differs from the spike device: pitch will be off **");
}

/// A device with input streams (BlackHole, USB headsets) would otherwise start its input too,
/// which macOS counts as microphone use. Tell the HAL this IOProc only uses the outputs.
static void DisableInputStreams(AudioObjectID device, AudioDeviceIOProcID proc) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) != noErr || size == 0) return;
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    usage->mIOProc = (void *)proc;
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, usage) == noErr) {
        for (UInt32 i = 0; i < usage->mNumberStreams; i++) usage->mStreamIsOn[i] = 0;
        OSStatus status = AudioObjectSetPropertyData(device, &a, 0, NULL, size, usage);
        printf("input streams turned off: %u (status %d)\n", usage->mNumberStreams, (int)status);
    }
    free(usage);
}

static void SetGain(int32_t pid, float gain) {
    for (int i = 0; i < VSPIKE_MAX_CLIENTS; i++) {
        if (atomic_load(&gShared->gains[i].pid) == pid) { atomic_store(&gShared->gains[i].gainBits, F2Bits(gain)); return; }
    }
    for (int i = 0; i < VSPIKE_MAX_CLIENTS; i++) {
        if (atomic_load(&gShared->gains[i].pid) == 0) {
            atomic_store(&gShared->gains[i].gainBits, F2Bits(gain));
            atomic_store_explicit(&gShared->gains[i].pid, pid, memory_order_release);
            return;
        }
    }
}

int main(int argc, char **argv) {
    const char *outUID = NULL;
    float gainAll = -1;
    int seconds = 15;
    int32_t gainPIDs[16]; float gainValues[16]; int gainCount = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) outUID = argv[++i];
        else if (!strcmp(argv[i], "--gain-all") && i + 1 < argc) gainAll = (float)atof(argv[++i]);
        else if (!strcmp(argv[i], "--gain") && i + 2 < argc && gainCount < 16) { gainPIDs[gainCount] = atoi(argv[++i]); gainValues[gainCount++] = (float)atof(argv[++i]); }
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--latency") && i + 1 < argc) gLatency = (uint64_t)atoll(argv[++i]);
        else { fprintf(stderr, "usage: %s [--out uid] [--gain-all g] [--gain pid g] [--seconds n] [--latency frames]\n", argv[0]); return 2; }
    }

    shm_unlink(VSPIKE_SHM_NAME);
    int fd = shm_open(VSPIKE_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) { perror("shm_open"); return 1; }
    fchmod(fd, 0666);  // the driver runs as _coreaudiod
    if (ftruncate(fd, sizeof(VSpikeShared)) != 0) { perror("ftruncate"); return 1; }
    gShared = mmap(NULL, sizeof(VSpikeShared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (gShared == MAP_FAILED) { perror("mmap"); return 1; }
    memset(gShared, 0, sizeof(VSpikeShared));
    gShared->hostPID = getpid();
    gShared->version = VSPIKE_VERSION;
    gShared->magic = VSPIKE_MAGIC;
    printf("host pid %d, shared memory %s (%zu KB)\n", getpid(), VSPIKE_SHM_NAME, sizeof(VSpikeShared) / 1024);

    AudioObjectID device = kAudioObjectUnknown;
    if (outUID) {
        device = DeviceForUID(outUID);
    } else {
        AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 size = sizeof(device);
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &device);
    }
    if (device == kAudioObjectUnknown || device == DeviceForUID(VSPIKE_DEVICE_UID)) {
        fprintf(stderr, "no usable output device (pass --out <uid> of a real device)\n");
        return 1;
    }
    Describe(device);
    printf("spike device present: %s\n", DeviceForUID(VSPIKE_DEVICE_UID) != kAudioObjectUnknown ? "yes" : "NO");

    AudioDeviceIOProcID proc = NULL;
    OSStatus status = AudioDeviceCreateIOProcID(device, PlayMix, NULL, &proc);
    if (status == noErr) DisableInputStreams(device, proc);
    if (status == noErr) status = AudioDeviceStart(device, proc);
    if (status != noErr) { fprintf(stderr, "could not start output: %d\n", (int)status); return 1; }

    uint64_t lastWrite = 0;
    for (int second = 1; second <= seconds; second++) {
        sleep(1);
        atomic_fetch_add(&gShared->hostHeartbeat, 1);
        for (int i = 0; i < gainCount; i++) SetGain(gainPIDs[i], gainValues[i]);
        uint64_t write = atomic_load(&gShared->writeFrame);
        printf("[%2ds] attaches=%llu mixCycles=%llu frames/s=%llu lag=%lld underruns=%llu resyncs=%llu outPeak=%.4f\n",
               second, atomic_load(&gShared->driverAttachCount), atomic_load(&gShared->mixCycles),
               lastWrite ? write - lastWrite : 0, atomic_load(&gLag), atomic_load(&gUnderruns), atomic_load(&gResyncs),
               Bits2F(atomic_exchange(&gOutPeakBits, 0)));
        lastWrite = write;
        for (int i = 0; i < VSPIKE_MAX_CLIENTS; i++) {
            int32_t pid = atomic_load(&gShared->clients[i].pid);
            if (pid <= 0) continue;
            if (gainAll >= 0) SetGain(pid, gainAll);
            printf("        client pid=%-6d bundle=%-40s peak=%.4f\n", pid,
                   gShared->clients[i].bundleID[0] ? gShared->clients[i].bundleID : "(none)",
                   Bits2F(atomic_exchange(&gShared->clients[i].peakBits, 0)));
        }
        fflush(stdout);
    }

    AudioDeviceStop(device, proc);
    AudioDeviceDestroyIOProcID(device, proc);
    shm_unlink(VSPIKE_SHM_NAME);
    return 0;
}
