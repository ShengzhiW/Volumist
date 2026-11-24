// Phase-1 test host: stands in for Volumist.app against the real driver.
//
//   vd-host --out <real device UID> [--seconds n] [--rules <file>] [--csv <file>]
//
// Creates the shared memory and keeps the heartbeat, asks the driver for the real device's
// sample rate, publishes gain rules ahead of time, plays the mix to the real device, and mirrors
// the Volumist device's volume/mute to the real device (and back). --rules is re-read every
// second; each line is either
//   app <text> <gain>      rule for every running process whose path contains <text>
//   owner <text> <gain>    rule for every process whose responsible app's path contains <text>
//                          (an app and its helpers, e.g. Safari and its WebKit GPU process)
//   bundle <id> <gain>     rule for a bundle ID

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioServices.h>
#include <dlfcn.h>
#include <libproc.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>

#include "../VolumistDriverProtocol.h"

static VDShared *gShared;
static uint64_t gLatency = 1024;
static uint64_t gReadFrame;
static int gPrimed;
static uint32_t gUnderruns, gResyncs, gOutPeakBits;
static int64_t gLag;
static volatile sig_atomic_t gStop;

// MARK: - Output

static OSStatus PlayMix(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
                        AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime; (void)outputTime; (void)context;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    if (output->mNumberBuffers == 0 || output->mBuffers[0].mNumberChannels == 0) return 0;
    UInt32 channels = output->mBuffers[0].mNumberChannels;
    UInt32 frames = output->mBuffers[0].mDataByteSize / (sizeof(float) * channels);
    uint64_t write = vd_load64(&gShared->writeFrame);
    if (!gPrimed || write < gReadFrame || gReadFrame + frames > write || write - gReadFrame > VD_RING_FRAMES / 2) {
        if (gPrimed && gReadFrame + frames > write && write >= gReadFrame) vd_add32(&gUnderruns, 1);
        if (gPrimed) vd_add32(&gResyncs, 1);
        if (write < gLatency) { gPrimed = 0; return 0; }
        gReadFrame = write - gLatency;
        gPrimed = 1;
        return 0;
    }
    float *first = output->mBuffers[0].mData;
    float *second = output->mNumberBuffers > 1 ? output->mBuffers[1].mData : NULL;
    float peak = 0;
    for (UInt32 f = 0; f < frames; f++) {
        uint64_t index = ((gReadFrame + f) & (VD_RING_FRAMES - 1)) * VD_CHANNELS;
        float left = gShared->ring[index], right = gShared->ring[index + 1];
        if (channels >= 2) { first[f * channels] = left; first[f * channels + 1] = right; }
        else { first[f] = left; if (second) second[f] = right; }
        peak = fmaxf(peak, fmaxf(fabsf(left), fabsf(right)));
    }
    gReadFrame += frames;
    vd_raise_peak(&gOutPeakBits, peak);
    __atomic_store_n(&gLag, (int64_t)(write - gReadFrame), __ATOMIC_RELAXED);
    return 0;
}

static AudioObjectID DeviceForUID(const char *uid) {
    CFStringRef cfUID = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectID device = kAudioObjectUnknown;
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(cfUID), &cfUID, &size, &device);
    CFRelease(cfUID);
    return device;
}

static void DisableInputStreams(AudioObjectID device, AudioDeviceIOProcID proc) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) != noErr || size == 0) return;
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    usage->mIOProc = (void *)proc;
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, usage) == noErr) {
        for (UInt32 i = 0; i < usage->mNumberStreams; i++) usage->mStreamIsOn[i] = 0;
        AudioObjectSetPropertyData(device, &a, 0, NULL, size, usage);
    }
    free(usage);
}

// MARK: - Real device volume

static const AudioObjectPropertyAddress kVolumeAddress = {kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
static const AudioObjectPropertyAddress kMuteAddress = {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};

static float RealVolume(AudioObjectID device) {
    Float32 volume = -1;
    UInt32 size = sizeof(volume);
    AudioObjectGetPropertyData(device, &kVolumeAddress, 0, NULL, &size, &volume);
    return volume;
}

static int RealMute(AudioObjectID device) {
    UInt32 mute = 0, size = sizeof(mute);
    if (AudioObjectGetPropertyData(device, &kMuteAddress, 0, NULL, &size, &mute) != noErr) return -1;
    return (int)mute;
}

// MARK: - Rules

static void SetRule(int *count, uint32_t pid, const char *bundle, float gain) {
    if (*count >= VD_MAX_RULES) return;
    VDRule *rule = &gShared->rules[(*count)++];
    vd_store32(&rule->active, 0);
    vd_store32(&rule->pid, pid);
    vd_store64(&rule->bundleHash, bundle ? vd_hash(bundle) : 0);
    vd_store32(&rule->gainBits, vd_bits(gain));
    vd_store32(&rule->active, 1);
}

static pid_t Responsible(pid_t pid) {
    typedef pid_t (*Fn)(pid_t);
    static Fn fn;
    if (!fn) fn = (Fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    pid_t owner = fn ? fn(pid) : 0;
    return owner > 0 ? owner : pid;
}

static void ApplyRules(const char *file) {
    FILE *f = fopen(file, "r");
    if (!f) return;
    int count = 0;
    char kind[16], text[256];
    float gain;
    static pid_t pids[8192];
    int npids = proc_listallpids(pids, sizeof(pids));
    while (fscanf(f, "%15s %255s %f", kind, text, &gain) == 3) {
        if (!strcmp(kind, "bundle")) {
            SetRule(&count, 0, text, gain);
        } else if (!strcmp(kind, "app") || !strcmp(kind, "owner")) {
            int byOwner = !strcmp(kind, "owner");
            for (int i = 0; i < npids; i++) {
                char path[PROC_PIDPATHINFO_MAXSIZE];
                pid_t subject = byOwner ? Responsible(pids[i]) : pids[i];
                if (pids[i] > 0 && proc_pidpath(subject, path, sizeof(path)) > 0 && strstr(path, text)) {
                    SetRule(&count, (uint32_t)pids[i], NULL, gain);
                }
            }
        }
    }
    fclose(f);
    for (int i = count; i < VD_MAX_RULES; i++) vd_store32(&gShared->rules[i].active, 0);
}

static void *Heartbeat(void *unused) {
    (void)unused;
    while (!gStop) {
        vd_store64(&gShared->heartbeatNanos, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        usleep(250 * 1000);
    }
    return NULL;
}

static void OnSignal(int sig) { (void)sig; gStop = 1; }

int main(int argc, char **argv) {
    const char *outUID = NULL, *rulesFile = NULL, *csvPath = NULL;
    int seconds = 60;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) outUID = argv[++i];
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rules") && i + 1 < argc) rulesFile = argv[++i];
        else if (!strcmp(argv[i], "--csv") && i + 1 < argc) csvPath = argv[++i];
        else if (!strcmp(argv[i], "--latency") && i + 1 < argc) gLatency = (uint64_t)atoll(argv[++i]);
        else { fprintf(stderr, "usage: %s --out <uid> [--seconds n] [--rules file] [--csv file] [--latency frames]\n", argv[0]); return 2; }
    }
    AudioObjectID device = outUID ? DeviceForUID(outUID) : kAudioObjectUnknown;
    if (device == kAudioObjectUnknown || device == DeviceForUID(VD_DEVICE_UID)) { fprintf(stderr, "pass --out <real output device UID>\n"); return 1; }
    signal(SIGINT, OnSignal);
    signal(SIGTERM, OnSignal);

    shm_unlink(VD_SHM_NAME);
    int fd = shm_open(VD_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) { perror("shm_open"); return 1; }
    fchmod(fd, 0666);  // the driver runs as _coreaudiod (see the plan's security note)
    if (ftruncate(fd, sizeof(VDShared)) != 0) { perror("ftruncate"); return 1; }
    gShared = mmap(NULL, sizeof(VDShared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    memset(gShared, 0, sizeof(VDShared));
    gShared->hostPID = (uint32_t)getpid();
    gShared->version = VD_VERSION;
    vd_store64(&gShared->heartbeatNanos, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));

    Float64 rate = 0;
    AudioObjectPropertyAddress rateAddress = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(device, &rateAddress, 0, NULL, &size, &rate);
    vd_store32(&gShared->requestedSampleRate, (uint32_t)rate);
    float realVolume = RealVolume(device);
    if (realVolume >= 0) { vd_store32(&gShared->requestedVolumeBits, vd_bits(realVolume)); vd_store32(&gShared->requestedVolumeSeq, 1); }
    int realMute = RealMute(device);
    if (realMute >= 0) { vd_store32(&gShared->requestedMute, (uint32_t)realMute); vd_store32(&gShared->requestedMuteSeq, 1); }
    if (rulesFile) ApplyRules(rulesFile);
    gShared->magic = VD_MAGIC;  // published last
    printf("host pid %d -> real output id %u at %.0f Hz, volume %.2f\n", getpid(), device, rate, realVolume);

    pthread_t beat;
    pthread_create(&beat, NULL, Heartbeat, NULL);

    AudioDeviceIOProcID proc = NULL;
    OSStatus status = AudioDeviceCreateIOProcID(device, PlayMix, NULL, &proc);
    if (status == noErr) DisableInputStreams(device, proc);
    if (status == noErr) status = AudioDeviceStart(device, proc);
    if (status != noErr) { fprintf(stderr, "could not start output: %d\n", (int)status); return 1; }

    FILE *csv = csvPath ? fopen(csvPath, "w") : NULL;
    if (csv) fprintf(csv, "second,writeFrame,lag,underruns,resyncs\n");
    uint32_t seenVolumeSeq = 0;
    uint64_t lastWrite = 0;
    for (int second = 1; second <= seconds && !gStop; second++) {
        sleep(1);
        if (rulesFile) ApplyRules(rulesFile);

        // Volumist device volume/mute changed (volume keys, Sound menu) -> real device.
        uint32_t seq = vd_load32(&gShared->volumeSeq);
        if (seq != seenVolumeSeq) {
            seenVolumeSeq = seq;
            Float32 volume = vd_float(vd_load32(&gShared->volumeBits));
            UInt32 mute = vd_load32(&gShared->mute);
            AudioObjectSetPropertyData(device, &kVolumeAddress, 0, NULL, sizeof(volume), &volume);
            AudioObjectSetPropertyData(device, &kMuteAddress, 0, NULL, sizeof(mute), &mute);
            realVolume = volume;
            printf("        mirrored volume %.2f mute %u to the real device\n", volume, mute);
        }

        uint64_t write = vd_load64(&gShared->writeFrame);
        printf("[%3ds] visible=%u attaches=%u ownerLookup=%u rate=%u io=%u clients=%u frames/s=%llu lag=%lld underruns=%u resyncs=%u outPeak=%.4f\n",
               second, vd_load32(&gShared->deviceVisible), vd_load32(&gShared->attachCount), vd_load32(&gShared->ownerLookupWorks), vd_load32(&gShared->sampleRate),
               vd_load32(&gShared->ioRunning), vd_load32(&gShared->clientCount), lastWrite && write >= lastWrite ? write - lastWrite : 0,
               (long long)__atomic_load_n(&gLag, __ATOMIC_RELAXED), vd_load32(&gUnderruns), vd_load32(&gResyncs),
               vd_float(vd_exchange32(&gOutPeakBits, 0)));
        if (csv) { fprintf(csv, "%d,%llu,%lld,%u,%u\n", second, write, (long long)gLag, gUnderruns, gResyncs); fflush(csv); }
        lastWrite = write;
        for (int i = 0; i < VD_MAX_CLIENTS; i++) {
            uint32_t pid = vd_load32(&gShared->clients[i].pid);
            if (!pid) continue;
            float peak = vd_float(vd_exchange32(&gShared->clients[i].peakBits, 0));
            if (peak <= 0) continue;
            printf("        pid=%-6u owner=%-6u %-28s gain=%.2f peak=%.4f\n", pid, vd_load32(&gShared->clients[i].ownerPID),
                   gShared->clients[i].bundleID[0] ? gShared->clients[i].bundleID : "(no bundle)",
                   vd_float(vd_load32(&gShared->clients[i].gainBits)), peak);
        }
        fflush(stdout);
    }

    gStop = 1;
    if (csv) fclose(csv);
    AudioDeviceStop(device, proc);
    AudioDeviceDestroyIOProcID(device, proc);
    shm_unlink(VD_SHM_NAME);
    printf("stopped; the Volumist device will disappear within ~1.5 s\n");
    return 0;
}
