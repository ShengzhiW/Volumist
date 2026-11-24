// In-process tests for the Volumist driver. Loads a test build of the driver (VD_TESTING: its own
// socket, and it accepts this program instead of Volumist) and plays the Core Audio host (calling
// the plug-in interface, recording notifications). The app's side is the real app engine
// (VolumistEngine.c), which serves the shared memory over the socket and keeps the heartbeat.
//
//   DriverTests <path to VolumistDriver.driver>

#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "../VolumistDriverProtocol.h"
#include "../../Volumist/Engine/VolumistEngine.h"
#include <sys/socket.h>
#include <sys/un.h>

extern char **environ;

static int gFailures, gChecks;
#define CHECK(cond, ...)                                                    \
    do {                                                                    \
        gChecks++;                                                          \
        if (cond) { printf("  ok    "); } else { printf("  FAIL  "); gFailures++; } \
        printf(__VA_ARGS__);                                                \
        printf("\n");                                                       \
    } while (0)

enum { kPlugIn = kAudioObjectPlugInObject, kDevice = 2, kStream = 3, kVolume = 4, kMute = 5 };

// MARK: - Fake host

static AudioServerPlugInDriverInterface **gDriver;
static _Atomic int gDeviceListChanges, gVolumeChanges, gMuteChanges;
static _Atomic uint64_t gRequestedAction;

static OSStatus Host_PropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    (void)host;
    for (UInt32 i = 0; i < count; i++) {
        if (object == kPlugIn && addresses[i].mSelector == kAudioPlugInPropertyDeviceList) gDeviceListChanges++;
        if (object == kVolume && addresses[i].mSelector == kAudioLevelControlPropertyScalarValue) gVolumeChanges++;
        if (object == kMute && addresses[i].mSelector == kAudioBooleanControlPropertyValue) gMuteChanges++;
    }
    return 0;
}
static OSStatus Host_CopyFromStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *o) { (void)h; (void)k; *o = NULL; return kAudioHardwareUnknownPropertyError; }
static OSStatus Host_WriteToStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { (void)h; (void)k; (void)d; return 0; }
static OSStatus Host_DeleteFromStorage(AudioServerPlugInHostRef h, CFStringRef k) { (void)h; (void)k; return 0; }
static OSStatus Host_RequestDeviceConfigurationChange(AudioServerPlugInHostRef h, AudioObjectID device, UInt64 action, void *info) {
    (void)h; (void)device; (void)info;
    gRequestedAction = action;  // the test performs it, as the HAL would later
    return 0;
}

static AudioServerPlugInHostInterface gHost = {
    Host_PropertiesChanged, Host_CopyFromStorage, Host_WriteToStorage, Host_DeleteFromStorage, Host_RequestDeviceConfigurationChange,
};

// MARK: - Helpers

static UInt32 DeviceListCount(void) {
    AudioObjectPropertyAddress a = {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID ids[4];
    UInt32 size = 0;
    (*gDriver)->GetPropertyData(gDriver, kPlugIn, getpid(), &a, 0, NULL, sizeof(ids), &size, ids);
    return size / sizeof(AudioObjectID);
}

static OSStatus GetData(AudioObjectID object, AudioObjectPropertySelector selector, UInt32 size, void *out) {
    AudioObjectPropertyAddress a = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 outSize = 0;
    return (*gDriver)->GetPropertyData(gDriver, object, getpid(), &a, 0, NULL, size, &outSize, out);
}

static OSStatus SetData(AudioObjectID object, AudioObjectPropertySelector selector, UInt32 size, const void *data) {
    AudioObjectPropertyAddress a = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return (*gDriver)->SetPropertyData(gDriver, object, getpid(), &a, 0, NULL, size, data);
}

static OSStatus AddClient(UInt32 clientID, pid_t pid, const char *bundle) {
    CFStringRef bundleID = bundle ? CFStringCreateWithCString(NULL, bundle, kCFStringEncodingUTF8) : NULL;
    AudioServerPlugInClientInfo info = {clientID, pid, true, bundleID};
    OSStatus status = (*gDriver)->AddDeviceClient(gDriver, kDevice, &info);
    if (bundleID) CFRelease(bundleID);
    return status;
}

static void RemoveClient(UInt32 clientID, pid_t pid) {
    AudioServerPlugInClientInfo info = {clientID, pid, true, NULL};
    (*gDriver)->RemoveDeviceClient(gDriver, kDevice, &info);
}

/// Runs one ProcessOutput cycle on a buffer of constant `level`; returns the last sample.
static float ProcessOutput(UInt32 clientID, float level, float *firstSample) {
    enum { kFrames = 512 };
    static float buffer[kFrames * VD_CHANNELS];
    for (int i = 0; i < kFrames * VD_CHANNELS; i++) buffer[i] = level;
    AudioServerPlugInIOCycleInfo cycle = {0};
    (*gDriver)->DoIOOperation(gDriver, kDevice, kStream, clientID, kAudioServerPlugInIOOperationProcessOutput, kFrames, &cycle, buffer, NULL);
    if (firstSample) *firstSample = buffer[0];
    return buffer[kFrames * VD_CHANNELS - 1];
}

static int ClientSlot(VDShared *shared, uint32_t pid, uint32_t clientID) {
    for (int i = 0; i < VD_MAX_CLIENTS; i++) {
        if (vd_load32(&shared->clients[i].pid) == pid && vd_load32(&shared->clients[i].clientID) == clientID) return i;
    }
    return -1;
}

static int WaitFor(int (*condition)(void), int timeoutMs) {
    for (int waited = 0; waited < timeoutMs; waited += 20) {
        if (condition()) return 1;
        usleep(20 * 1000);
    }
    return condition();
}

// MARK: - The app (the real engine)

#define kTestSocket "/tmp/volumist.drivertest.sock"
static VEEngine *gEngine;
static VDShared *gShared;

static void SetRule(int index, uint32_t pid, const char *bundle, float gain) {
    VDRule *rule = &gShared->rules[index];
    vd_store32(&rule->active, 0);
    vd_store32(&rule->pid, pid);
    vd_store64(&rule->bundleHash, bundle ? vd_hash(bundle) : 0);
    vd_store32(&rule->gainBits, vd_bits(gain));
    vd_store32(&rule->active, 1);
}

static int DeviceVisible(void) { return DeviceListCount() == 1; }
static int DeviceHidden(void) { return DeviceListCount() == 0; }
static int Replied(void) { return ve_driver_reply(gEngine) >= 0; }
static int RateRequested(void) { return gRequestedAction != 0; }
static int VolumeIs07(void) { Float32 v = 0; GetData(kVolume, kAudioLevelControlPropertyScalarValue, sizeof(v), &v); return fabsf(v - 0.7f) < 1e-6f; }
static int MuteIsOn(void) { UInt32 m = 0; GetData(kMute, kAudioBooleanControlPropertyValue, sizeof(m), &m); return m == 1; }

static int Near(float a, float b) { return fabsf(a - b) < 1e-5f; }

// MARK: - Tests

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <VolumistDriver.driver>\n", argv[0]); return 2; }
    char binary[1024];
    snprintf(binary, sizeof(binary), "%s/Contents/MacOS/VolumistDriver", argv[1]);
    void *handle = dlopen(binary, RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    void *(*create)(CFAllocatorRef, CFUUIDRef) = (void *(*)(CFAllocatorRef, CFUUIDRef))dlsym(handle, "VolumistDriver_Create");
    if (!create) { fprintf(stderr, "factory not exported\n"); return 1; }
    gDriver = create(NULL, kAudioServerPlugInTypeUUID);
    uint32_t (*checkApp)(pid_t) = (uint32_t (*)(pid_t))dlsym(handle, "VolumistDriver_TestCheckApp");

    printf("Lifecycle\n");
    CHECK(gDriver != NULL, "factory returns the driver for the AudioServerPlugIn type");
    CHECK(create(NULL, kAudioServerPlugInDriverInterfaceUUID) == NULL, "factory refuses other types");
    CHECK((*gDriver)->Initialize(gDriver, &gHost) == 0, "Initialize succeeds");
    usleep(300 * 1000);
    CHECK(DeviceListCount() == 0, "no device while the app isn't running");

    printf("Who may connect\n");
    CHECK(checkApp != NULL && checkApp(getpid()) == VD_REPLY_ATTACHED, "driver accepts a validly signed app with the right identifier");
    CHECK(checkApp != NULL && checkApp(1) == VD_REPLY_NOT_APP, "driver rejects another program (launchd)");
    {
        // An engine that only serves Core Audio's account must not hand the memory to us.
        VEEngine *strict = ve_create("/tmp/volumist.uidtest.sock", 202);
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, "/tmp/volumist.uidtest.sock", sizeof(address.sun_path));
        int connected = connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0;
        struct timeval timeout = {2, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        char buffer[64];
        union { struct cmsghdr header; char space[CMSG_SPACE(sizeof(int))]; } control;
        struct iovec iov = {buffer, sizeof(buffer)};
        struct msghdr message = {0};
        message.msg_iov = &iov;
        message.msg_iovlen = 1;
        message.msg_control = control.space;
        message.msg_controllen = sizeof(control.space);
        ssize_t got = connected ? recvmsg(fd, &message, 0) : -1;
        CHECK(connected && got == 0 && message.msg_controllen == 0, "engine closes connections from other accounts without sending the memory");
        close(fd);
        ve_destroy(strict);
    }

    printf("App appears\n");
    gEngine = ve_create(kTestSocket, (int)getuid());
    CHECK(gEngine != NULL, "app engine starts and listens");
    gShared = ve_shared_for_test(gEngine);
    SetRule(0, 0, "com.example.player", 0.25f);  // published before the player connects
    CHECK(WaitFor(DeviceVisible, 1000), "device appears once the driver has received the app's memory");
    CHECK(WaitFor(Replied, 500) && ve_driver_reply(gEngine) == VD_REPLY_ATTACHED, "driver tells the app it attached");
    CHECK(gDeviceListChanges >= 1, "host notified that the device list changed (%d)", (int)gDeviceListChanges);
    CHECK(vd_load32(&gShared->deviceVisible) == 1 && vd_load32(&gShared->attachCount) == 1, "driver reports itself attached and visible");
    CHECK(vd_load32(&gShared->driverPID) == (uint32_t)getpid(), "driver reports its PID");
    CFStringRef name = NULL;
    GetData(kDevice, kAudioObjectPropertyName, sizeof(name), &name);
    CHECK(name && CFEqual(name, CFSTR("Volumist")), "device is named Volumist");

    printf("Gain rules\n");
    pid_t me = getpid();
    CHECK(AddClient(7, me, "com.example.player") == 0, "client added");
    (*gDriver)->StartIO(gDriver, kDevice, 7);
    float first = 0, last = ProcessOutput(7, 0.5f, &first);
    CHECK(Near(first, 0.125f) && Near(last, 0.125f), "bundle rule applies from the first sample: 0.5 -> %.4f ... %.4f", first, last);
    int slot = ClientSlot(gShared, (uint32_t)me, 7);
    CHECK(slot >= 0, "client published to the app (slot %d)", slot);
    if (slot >= 0) {
        CHECK(strcmp(gShared->clients[slot].bundleID, "com.example.player") == 0, "client bundle ID published");
        CHECK(Near(vd_float(vd_exchange32(&gShared->clients[slot].peakBits, 0)), 0.125f), "peak level published");
    }
    SetRule(1, (uint32_t)me, NULL, 0.5f);
    ProcessOutput(7, 0.5f, &first);
    last = ProcessOutput(7, 0.5f, NULL);
    CHECK(Near(last, 0.25f), "PID rule beats bundle rule: 0.5 -> %.4f", last);
    vd_store32(&gShared->rules[1].active, 0);
    ProcessOutput(7, 0.5f, NULL);
    last = ProcessOutput(7, 0.5f, NULL);
    CHECK(Near(last, 0.125f), "removing the PID rule falls back to the bundle rule: %.4f", last);
    SetRule(2, 0, "com.example.loud", 9.0f);
    AddClient(8, me, "com.example.loud");
    ProcessOutput(8, 0.1f, NULL);
    CHECK(Near(ProcessOutput(8, 0.1f, NULL), 0.4f), "gain is capped at 4x");
    AddClient(9, me, "com.example.unknown");
    CHECK(Near(ProcessOutput(9, 0.5f, NULL), 0.5f), "no matching rule leaves audio unchanged");

    // Owner rule: a child process's responsible process is ours (or whatever launched us).
    pid_t child = 0;
    char *sleepArgs[] = {"/bin/sleep", "5", NULL};
    posix_spawn(&child, "/bin/sleep", NULL, NULL, sleepArgs, environ);
    AddClient(10, child, "com.apple.WebKit.GPU");
    int childSlot = ClientSlot(gShared, (uint32_t)child, 10);
    uint32_t owner = childSlot >= 0 ? vd_load32(&gShared->clients[childSlot].ownerPID) : 0;
    CHECK(owner != 0 && owner != (uint32_t)child, "helper's owner process resolved (child %d -> owner %u)", child, owner);
    if (owner) {
        SetRule(3, owner, NULL, 0.1f);
        RemoveClient(10, child);
        AddClient(11, child, "com.apple.WebKit.GPU");
        float firstOwned = 0;
        ProcessOutput(11, 0.5f, &firstOwned);
        CHECK(Near(firstOwned, 0.05f), "owner rule applies to the helper from its first sample: %.4f", firstOwned);
        vd_store32(&gShared->rules[3].active, 0);
    }
    kill(child, SIGTERM);
    waitpid(child, NULL, 0);
    usleep(300 * 1000);
    CHECK(vd_load32(&gShared->ownerLookupWorks) == 1, "driver reports that owner lookup works");

    printf("Mix ring\n");
    {
        enum { kFrames = 256 };
        float buffer[kFrames * VD_CHANNELS];
        for (int i = 0; i < kFrames * VD_CHANNELS; i++) buffer[i] = (float)i / 1000.0f;
        AudioServerPlugInIOCycleInfo cycle = {0};
        cycle.mOutputTime.mSampleTime = VD_RING_FRAMES - 100;  // wraps around the end of the ring
        (*gDriver)->DoIOOperation(gDriver, kDevice, kStream, 0, kAudioServerPlugInIOOperationWriteMix, kFrames, &cycle, buffer, NULL);
        int ok = 1;
        for (int f = 0; f < kFrames; f++) {
            uint64_t index = ((uint64_t)(VD_RING_FRAMES - 100 + f) & (VD_RING_FRAMES - 1)) * VD_CHANNELS;
            ok &= gShared->ring[index] == buffer[f * 2] && gShared->ring[index + 1] == buffer[f * 2 + 1];
        }
        CHECK(ok, "mix copied into the ring, wrapping at the end");
        CHECK(vd_load64(&gShared->writeFrame) == VD_RING_FRAMES - 100 + kFrames, "write position advanced to %llu", vd_load64(&gShared->writeFrame));
    }

    printf("Sample rate\n");
    vd_store32(&gShared->requestedSampleRate, 96000);
    CHECK(WaitFor(RateRequested, 1000) && gRequestedAction == 96000, "app's 96 kHz request becomes a configuration change (%llu)", (uint64_t)gRequestedAction);
    (*gDriver)->StopIO(gDriver, kDevice, 7);
    CHECK((*gDriver)->PerformDeviceConfigurationChange(gDriver, kDevice, gRequestedAction, NULL) == 0, "driver performs the change");
    Float64 rate = 0;
    GetData(kDevice, kAudioDevicePropertyNominalSampleRate, sizeof(rate), &rate);
    AudioStreamBasicDescription format = {0};
    GetData(kStream, kAudioStreamPropertyVirtualFormat, sizeof(format), &format);
    CHECK(rate == 96000 && format.mSampleRate == 96000, "device and stream now at %.0f / %.0f Hz", rate, format.mSampleRate);
    CHECK(vd_load32(&gShared->sampleRate) == 96000, "driver reports 96 kHz to the app");
    gRequestedAction = 0;
    Float64 unsupported = 12000;
    CHECK(SetData(kDevice, kAudioDevicePropertyNominalSampleRate, sizeof(unsupported), &unsupported) != 0, "unsupported rate rejected");
    Float64 headset = 24000;
    CHECK(SetData(kDevice, kAudioDevicePropertyNominalSampleRate, sizeof(headset), &headset) == 0 && gRequestedAction == 24000,
          "Bluetooth headset rate (24 kHz) accepted");
    gRequestedAction = 0;
    (*gDriver)->AbortDeviceConfigurationChange(gDriver, kDevice, 24000, NULL);

    printf("Volume and mute\n");
    uint32_t seq = vd_load32(&gShared->volumeSeq);
    Float32 volume = 0.3f;
    SetData(kVolume, kAudioLevelControlPropertyScalarValue, sizeof(volume), &volume);
    CHECK(Near(vd_float(vd_load32(&gShared->volumeBits)), 0.3f) && vd_load32(&gShared->volumeSeq) == seq + 1, "volume set through Core Audio reaches the app");
    CHECK(gVolumeChanges >= 1, "host notified of the volume change");
    Float32 decibels = 0;
    GetData(kVolume, kAudioLevelControlPropertyDecibelValue, sizeof(decibels), &decibels);
    CHECK(decibels < 0 && decibels > -64, "volume also readable in dB (%.1f)", decibels);
    vd_store32(&gShared->requestedVolumeBits, vd_bits(0.7f));
    vd_add32(&gShared->requestedVolumeSeq, 1);
    CHECK(WaitFor(VolumeIs07, 1000), "volume pushed by the app (real device changed) shows on the device");
    UInt32 mute = 1;
    SetData(kMute, kAudioBooleanControlPropertyValue, sizeof(mute), &mute);
    CHECK(vd_load32(&gShared->mute) == 1 && gMuteChanges >= 1, "mute set through Core Audio reaches the app");
    mute = 0;
    SetData(kMute, kAudioBooleanControlPropertyValue, sizeof(mute), &mute);
    vd_store32(&gShared->requestedMute, 1);
    vd_add32(&gShared->requestedMuteSeq, 1);
    CHECK(WaitFor(MuteIsOn, 1000), "mute pushed by the app shows on the device");

    printf("Client table\n");
    for (UInt32 id = 100; id < 400; id++) AddClient(id, me, "com.example.many");
    usleep(300 * 1000);
    uint32_t dropped = vd_load32(&gShared->droppedClients);
    CHECK(vd_load32(&gShared->clientCount) == VD_MAX_CLIENTS && dropped > 0, "table fills to %d clients and counts %u dropped", VD_MAX_CLIENTS, dropped);
    for (UInt32 id = 100; id < 400; id++) RemoveClient(id, me);
    usleep(300 * 1000);
    CHECK(vd_load32(&gShared->clientCount) < 10, "removed clients free their slots (%u left)", vd_load32(&gShared->clientCount));

    printf("App goes away\n");
    int before = gDeviceListChanges;
    ve_pause_heartbeat_for_test(gEngine, true);  // as if the app hung
    CHECK(!DeviceHidden(), "device still present right after the heartbeat stops");
    CHECK(WaitFor(DeviceHidden, 2500), "device disappears within ~1.5 s of the last heartbeat");
    CHECK(gDeviceListChanges > before, "host notified that the device is gone");
    // Detached: no shared memory, so no rules apply. The real HAL stops IO once the device is gone,
    // but a cycle already in flight must still be safe and leave audio unchanged.
    CHECK(Near(ProcessOutput(7, 0.5f, NULL), 0.5f), "an IO cycle after detaching is safe and applies no rules");
    ve_pause_heartbeat_for_test(gEngine, false);
    CHECK(WaitFor(DeviceVisible, 3500), "device returns when the heartbeat resumes (the driver reconnects)");
    CHECK(vd_load32(&gShared->attachCount) == 2, "driver re-attached once, without churning while the app was stalled (attach count %u)", vd_load32(&gShared->attachCount));

    // A dead app PID hides the device even if the heartbeat looks fresh.
    pid_t gone = 0;
    char *trueArgs[] = {"/usr/bin/true", NULL};
    posix_spawn(&gone, "/usr/bin/true", NULL, NULL, trueArgs, environ);
    waitpid(gone, NULL, 0);
    uint32_t realHost = gShared->hostPID;
    gShared->hostPID = (uint32_t)gone;
    CHECK(WaitFor(DeviceHidden, 1500), "device disappears when the app's process is gone");
    gShared->hostPID = realHost;
    CHECK(WaitFor(DeviceVisible, 3500), "device returns once the app is alive again");

    printf("App quits\n");
    ve_destroy(gEngine);
    CHECK(WaitFor(DeviceHidden, 600), "device disappears at once when the app closes its connection");
    printf("\n%d checks, %d failed\n", gChecks, gFailures);
    return gFailures ? 1 : 0;
}
