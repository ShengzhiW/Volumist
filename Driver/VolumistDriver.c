// Volumist audio driver (AudioServerPlugIn).
//
// One stereo output device, "Volumist", that Volumist.app makes the default output. Apps play
// into it; per client, ProcessOutput applies the gain the app published for that process, its
// owner app or its bundle ID; WriteMix copies the mix into shared memory, from which the app
// plays it to the real output device.
//
// The device is published only while the app is connected and alive (open socket, fresh heartbeat
// in shared memory), so if the app quits or crashes the device disappears and macOS switches back
// to the real output.
//
// Security: the app's shared memory has no name. The driver connects to the app's socket, checks
// through the kernel (csops) that the peer is a validly signed Volumist, and receives the memory's
// descriptor; the app only hands it to Core Audio's account. Nothing else can read the mix.
//
// Threads: the HAL calls property and lifecycle functions on its own threads and IO functions on
// a real-time thread. Non-real-time state is guarded by gMutex; the IO path uses atomics only.
// A poll thread (every 200 ms) attaches to and detaches from the app's shared memory, shows or
// hides the device, and applies the app's sample-rate, volume and mute requests. Calls into the
// host are made with gMutex released.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "VolumistDriverProtocol.h"

// MARK: - Objects and constants

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream = 3,
    kObjectID_Volume = 4,
    kObjectID_Mute = 5,
};

#define kDeviceName CFSTR("Volumist")
#define kManufacturer CFSTR("Volumist")
#define kDeviceUID CFSTR(VD_DEVICE_UID)
#define kModelUID CFSTR("app.volumist.device.model")
#define kZeroTimeStampPeriod 16384u
#define kMinDecibels -64.0f
#define kMaxGain 4.0f

// Includes the low rates Bluetooth headsets use in hands-free mode, so the driver can follow them.
static const Float64 kSupportedRates[] = {8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000};

// What the driver connects to and who it accepts. Test builds use their own socket and accept the
// test program instead of Volumist.
#ifdef VD_TESTING
#define kSocketPath "/tmp/volumist.drivertest.sock"
#define kRequiredIdentifier "DriverTests"
#else
#define kSocketPath VD_SOCKET_PATH
#define kRequiredIdentifier VD_APP_IDENTIFIER
#endif
#define kRetryAfterFailureNs 2000000000ull
#define kSupportedRateCount (sizeof(kSupportedRates) / sizeof(kSupportedRates[0]))

static os_log_t gLog;
static pthread_mutex_t gMutex = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost;
static UInt32 gRefCount;

// Clock and format (guarded by gMutex; read by the IO thread only while IO is running, during
// which the HAL doesn't change them).
static Float64 gSampleRate = 48000;
static Float64 gHostTicksPerFrame;
static Float64 gHostClockFrequency;
static UInt64 gIOCount;
static UInt64 gAnchorHostTime;
static UInt64 gNumberTimeStamps;
static bool gRateChangePending;

// Device controls (guarded by gMutex).
static Float32 gVolume = 1.0f;
static bool gMute;
static uint32_t gLastVolumeRequestSeq;
static uint32_t gLastMuteRequestSeq;

// Shared memory with the app. The IO thread loads gShared atomically; a detached mapping is kept
// in gRetired and unmapped later, once no IO can still be using it.
static _Atomic(VDShared *) gShared;
static VDShared *gRetired;
static int gSocket = -1;               // connection to the app while attached
static uint64_t gNextAttemptNanos;     // back off after a failed or rejected handover
static _Atomic bool gDeviceVisible;
static bool gOwnerLookupWorks;

typedef struct {
    _Atomic uint32_t clientID;  // 0 = unused
    _Atomic uint32_t pid;
    _Atomic uint32_t ownerPID;
    _Atomic uint64_t bundleHash;
    float currentGain;          // IO thread only (set before the client is published)
    char bundleID[VD_BUNDLE_ID_LENGTH];
} Client;
static Client gClients[VD_MAX_CLIENTS];
static uint32_t gDroppedClients;

// MARK: - Small helpers

static uint64_t NowNanos(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static bool IsSupportedRate(Float64 rate) {
    for (size_t i = 0; i < kSupportedRateCount; i++) {
        if (kSupportedRates[i] == rate) return true;
    }
    return false;
}

static AudioStreamBasicDescription StreamFormat(Float64 rate) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = 4 * VD_CHANNELS;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4 * VD_CHANNELS;
    format.mChannelsPerFrame = VD_CHANNELS;
    format.mBitsPerChannel = 32;
    return format;
}

static Float32 ScalarToDecibels(Float32 scalar) {
    if (scalar <= 0) return kMinDecibels;
    if (scalar >= 1) return 0;
    return kMinDecibels * (1.0f - scalar);
}

static Float32 DecibelsToScalar(Float32 decibels) {
    if (decibels <= kMinDecibels) return 0;
    if (decibels >= 0) return 1;
    return 1.0f - decibels / kMinDecibels;
}

static pid_t OwnerOf(pid_t pid) {
    typedef pid_t (*ResponsibleFn)(pid_t);
    static ResponsibleFn responsible;
    static bool looked;
    if (!looked) {
        responsible = (ResponsibleFn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        looked = true;
    }
    pid_t owner = responsible ? responsible(pid) : 0;
    return owner > 0 ? owner : 0;
}

/// The gain the app's rules give a client: by its PID, then its owner's PID, then its bundle.
static float ResolveGain(VDShared *shared, uint32_t pid, uint32_t owner, uint64_t bundleHash) {
    if (shared == NULL) return 1.0f;
    float byOwner = -1, byBundle = -1;
    for (int i = 0; i < VD_MAX_RULES; i++) {
        VDRule *rule = &shared->rules[i];
        if (!vd_load32(&rule->active)) continue;
        uint32_t rulePID = vd_load32(&rule->pid);
        float gain = vd_float(vd_load32(&rule->gainBits));
        if (!(gain >= 0)) gain = 1;  // also rejects NaN
        if (gain > kMaxGain) gain = kMaxGain;
        if (rulePID != 0 && rulePID == pid) return gain;
        if (rulePID != 0 && owner != 0 && rulePID == owner && byOwner < 0) byOwner = gain;
        uint64_t ruleHash = vd_load64(&rule->bundleHash);
        if (ruleHash != 0 && ruleHash == bundleHash && byBundle < 0) byBundle = gain;
    }
    if (byOwner >= 0) return byOwner;
    if (byBundle >= 0) return byBundle;
    return 1.0f;
}

static int FindClient(UInt32 clientID) {
    for (int i = 0; i < VD_MAX_CLIENTS; i++) {
        if (atomic_load_explicit(&gClients[i].clientID, memory_order_acquire) == clientID) return i;
    }
    return -1;
}

static void PublishClientLocked(VDShared *shared, int i) {
    VDClient *out = &shared->clients[i];
    uint32_t pid = atomic_load(&gClients[i].pid);
    if (atomic_load(&gClients[i].clientID) == 0 || pid == 0) {
        vd_store32(&out->pid, 0);
        return;
    }
    vd_store32(&out->pid, 0);
    memcpy(out->bundleID, gClients[i].bundleID, VD_BUNDLE_ID_LENGTH);
    vd_store32(&out->ownerPID, atomic_load(&gClients[i].ownerPID));
    vd_store32(&out->clientID, atomic_load(&gClients[i].clientID));
    vd_store64(&out->bundleHash, atomic_load(&gClients[i].bundleHash));
    vd_store32(&out->gainBits, vd_bits(gClients[i].currentGain));
    vd_store32(&out->peakBits, 0);
    vd_store32(&out->pid, pid);
}

static void WriteStatusLocked(VDShared *shared) {
    uint32_t count = 0;
    for (int i = 0; i < VD_MAX_CLIENTS; i++) count += atomic_load(&gClients[i].clientID) != 0;
    vd_store32(&shared->deviceVisible, atomic_load(&gDeviceVisible));
    vd_store32(&shared->sampleRate, (uint32_t)gSampleRate);
    vd_store32(&shared->volumeBits, vd_bits(gVolume));
    vd_store32(&shared->mute, gMute);
    vd_store32(&shared->ioRunning, (uint32_t)gIOCount);
    vd_store32(&shared->ownerLookupWorks, gOwnerLookupWorks);
    vd_store32(&shared->clientCount, count);
    vd_store32(&shared->droppedClients, gDroppedClients);
}

// MARK: - Host notifications (call with gMutex released)

static void NotifyDeviceListChanged(void) {
    AudioObjectPropertyAddress addresses[] = {
        {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    if (gHost) gHost->PropertiesChanged(gHost, kObjectID_PlugIn, 2, addresses);
}

static void NotifyVolumeChanged(void) {
    AudioObjectPropertyAddress addresses[] = {
        {kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    if (gHost) gHost->PropertiesChanged(gHost, kObjectID_Volume, 2, addresses);
}

static void NotifyMuteChanged(void) {
    AudioObjectPropertyAddress address = {kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (gHost) gHost->PropertiesChanged(gHost, kObjectID_Mute, 1, &address);
}

static void RequestRateChange(Float64 rate) {
    if (gHost) gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)rate, NULL);
}

// MARK: - Shared memory lifecycle

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define kCSOpsStatus 0
#define kCSOpsIdentity 11
#define kCSOpsTeamID 14
#define kCSValid 0x00000001u

/// Is `pid` a validly signed Volumist? Asks the kernel, which holds the code signature of every
/// running process, so no files need to be read.
static uint32_t CheckApp(pid_t pid) {
    uint32_t flags = 0;
    if (pid <= 0 || csops(pid, kCSOpsStatus, &flags, sizeof(flags)) != 0) return VD_REPLY_UNVERIFIABLE;
    if (!(flags & kCSValid)) return VD_REPLY_NOT_APP;
    char blob[300] = {0};  // 8-byte blob header, then the identifier
    if (csops(pid, kCSOpsIdentity, blob, sizeof(blob) - 1) != 0) return VD_REPLY_UNVERIFIABLE;
    if (strcmp(blob + 8, kRequiredIdentifier) != 0) return VD_REPLY_NOT_APP;
#ifdef VD_REQUIRED_TEAM_ID
    char team[300] = {0};
    if (csops(pid, kCSOpsTeamID, team, sizeof(team) - 1) != 0 || strcmp(team + 8, VD_REQUIRED_TEAM_ID) != 0) return VD_REPLY_NOT_APP;
#endif
    return VD_REPLY_ATTACHED;
}

#ifdef VD_TESTING
__attribute__((visibility("default"))) uint32_t VolumistDriver_TestCheckApp(pid_t pid);
__attribute__((visibility("default"))) uint32_t VolumistDriver_TestCheckApp(pid_t pid) { return CheckApp(pid); }
#endif

static bool HostIsAlive(VDShared *shared, uint64_t now) {
    pid_t pid = (pid_t)shared->hostPID;
    if (pid <= 0) return false;
    if (kill(pid, 0) != 0 && errno != EPERM) return false;
    if (gSocket >= 0) {
        // The app closes its end when it quits; a crash closes it too.
        struct pollfd fd = {gSocket, POLLIN, 0};
        if (poll(&fd, 1, 0) > 0) {
            char byte;
            if ((fd.revents & (POLLHUP | POLLERR)) || recv(gSocket, &byte, 1, MSG_DONTWAIT) == 0) return false;
        }
    }
    uint64_t beat = vd_load64(&shared->heartbeatNanos);
    return beat != 0 && (now < beat || now - beat <= VD_HEARTBEAT_TIMEOUT_NS);
}

/// Receives the handshake and the descriptor that comes with it.
static bool ReceiveMemory(int fd, VDHandshake *handshake, int *memoryFD) {
    struct iovec iov = {handshake, sizeof(*handshake)};
    union { struct cmsghdr header; char space[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof(control));
    struct msghdr message = {0};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.space;
    message.msg_controllen = sizeof(control.space);
    *memoryFD = -1;
    if (recvmsg(fd, &message, MSG_WAITALL) != sizeof(*handshake)) return false;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message); cmsg; cmsg = CMSG_NXTHDR(&message, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS && cmsg->cmsg_len == CMSG_LEN(sizeof(int))) {
            memcpy(memoryFD, CMSG_DATA(cmsg), sizeof(int));
        }
    }
    return *memoryFD >= 0;
}

static void TryAttachLocked(uint64_t now) {
    if (now < gNextAttemptNanos) return;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    struct timeval timeout = {1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, kSocketPath, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);  // app not running
        return;
    }

    pid_t peer = 0;
    socklen_t length = sizeof(peer);
    uint32_t status = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0 ? CheckApp(peer) : VD_REPLY_UNVERIFIABLE;

    VDHandshake handshake = {0};
    int memoryFD = -1;
    bool received = ReceiveMemory(fd, &handshake, &memoryFD);
    VDShared *shared = NULL;
    if (status == VD_REPLY_ATTACHED) {
        status = VD_REPLY_BAD_MEMORY;
        if (received && handshake.magic == VD_MAGIC && handshake.version == VD_VERSION && handshake.size == sizeof(VDShared)) {
            void *mapped = mmap(NULL, sizeof(VDShared), PROT_READ | PROT_WRITE, MAP_SHARED, memoryFD, 0);
            if (mapped != MAP_FAILED) {
                shared = mapped;
                if (shared->magic == VD_MAGIC && shared->version == VD_VERSION && (pid_t)shared->hostPID == peer) {
                    // Don't attach to an app that's stalled; we'd only detach again on the next poll.
                    status = HostIsAlive(shared, now) ? VD_REPLY_ATTACHED : VD_REPLY_NOT_READY;
                }
                if (status != VD_REPLY_ATTACHED) {
                    munmap(mapped, sizeof(VDShared));
                    shared = NULL;
                }
            }
        }
    }
    if (memoryFD >= 0) close(memoryFD);  // the mapping keeps the memory alive
    VDReply reply = {VD_MAGIC, status};
    send(fd, &reply, sizeof(reply), 0);
    if (status != VD_REPLY_ATTACHED) {
        if (status != VD_REPLY_NOT_READY) os_log_error(gLog, "handover refused (status %u, peer %d)", status, peer);
        close(fd);
        gNextAttemptNanos = now + (status == VD_REPLY_NOT_READY ? kRetryAfterFailureNs / 4 : kRetryAfterFailureNs);
        return;
    }

    if (gRetired && gIOCount == 0) {
        munmap(gRetired, sizeof(VDShared));
        gRetired = NULL;
    }
    gSocket = fd;
    // Requests made before we attached apply now.
    gLastVolumeRequestSeq = 0;
    gLastMuteRequestSeq = 0;
    vd_store32(&shared->driverPID, (uint32_t)getpid());
    vd_add32(&shared->attachCount, 1);
    for (int i = 0; i < VD_MAX_CLIENTS; i++) PublishClientLocked(shared, i);
    atomic_store_explicit(&gShared, shared, memory_order_release);
    os_log(gLog, "attached to app pid %d", peer);
}

static void DetachLocked(void) {
    VDShared *shared = atomic_exchange(&gShared, NULL);
    if (gSocket >= 0) {
        close(gSocket);
        gSocket = -1;
    }
    if (!shared) return;
    vd_store32(&shared->deviceVisible, 0);
    if (gRetired) munmap(gRetired, sizeof(VDShared));
    gRetired = shared;
    os_log(gLog, "detached: app gone or heartbeat stale");
}

static void Poll(void) {
    bool notifyDevices = false, notifyVolume = false, notifyMute = false;
    Float64 requestRate = 0;

    pthread_mutex_lock(&gMutex);
    uint64_t now = NowNanos();
    VDShared *shared = atomic_load(&gShared);
    if (shared && !HostIsAlive(shared, now)) {
        DetachLocked();
        shared = NULL;
    }
    if (!shared) {
        TryAttachLocked(now);
        shared = atomic_load(&gShared);
        if (shared && !HostIsAlive(shared, now)) {
            DetachLocked();
            shared = NULL;
        }
    }

    bool visible = shared != NULL;
    if (visible != atomic_load(&gDeviceVisible)) {
        atomic_store(&gDeviceVisible, visible);
        notifyDevices = true;
    }

    if (shared) {
        uint32_t rate = vd_load32(&shared->requestedSampleRate);
        if (rate != 0 && rate != (uint32_t)gSampleRate && IsSupportedRate(rate) && !gRateChangePending) {
            gRateChangePending = true;
            requestRate = rate;
        }
        uint32_t volumeSeq = vd_load32(&shared->requestedVolumeSeq);
        if (volumeSeq != gLastVolumeRequestSeq) {
            gLastVolumeRequestSeq = volumeSeq;
            float volume = vd_float(vd_load32(&shared->requestedVolumeBits));
            if (volume >= 0 && volume <= 1 && volume != gVolume) {
                gVolume = volume;
                vd_add32(&shared->volumeSeq, 1);
                notifyVolume = true;
            }
        }
        uint32_t muteSeq = vd_load32(&shared->requestedMuteSeq);
        if (muteSeq != gLastMuteRequestSeq) {
            gLastMuteRequestSeq = muteSeq;
            bool mute = vd_load32(&shared->requestedMute) != 0;
            if (mute != gMute) {
                gMute = mute;
                vd_add32(&shared->volumeSeq, 1);
                notifyMute = true;
            }
        }
        WriteStatusLocked(shared);
    }
    pthread_mutex_unlock(&gMutex);

    if (notifyDevices) NotifyDeviceListChanged();
    if (notifyVolume) NotifyVolumeChanged();
    if (notifyMute) NotifyMuteChanged();
    if (requestRate > 0) RequestRateChange(requestRate);
}

static void *PollThread(void *unused) {
    (void)unused;
    pthread_setname_np("Volumist driver poll");
    for (;;) {
        Poll();
        usleep(200 * 1000);
    }
    return NULL;
}

// MARK: - Interface declarations

static HRESULT Driver_QueryInterface(void *, REFIID, LPVOID *);
static ULONG Driver_AddRef(void *);
static ULONG Driver_Release(void *);
static OSStatus Driver_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus Driver_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus Driver_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static Boolean Driver_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
static OSStatus Driver_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus Driver_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);
static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Driver_QueryInterface, Driver_AddRef, Driver_Release,
    Driver_Initialize, Driver_CreateDevice, Driver_DestroyDevice,
    Driver_AddDeviceClient, Driver_RemoveDeviceClient,
    Driver_PerformDeviceConfigurationChange, Driver_AbortDeviceConfigurationChange,
    Driver_HasProperty, Driver_IsPropertySettable, Driver_GetPropertyDataSize, Driver_GetPropertyData, Driver_SetPropertyData,
    Driver_StartIO, Driver_StopIO, Driver_GetZeroTimeStamp,
    Driver_WillDoIOOperation, Driver_BeginIOOperation, Driver_DoIOOperation, Driver_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory and COM

__attribute__((visibility("default"))) void *VolumistDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
__attribute__((visibility("default"))) void *VolumistDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    return CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID) ? gDriverRef : NULL;
}

static HRESULT Driver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        Driver_AddRef(inDriver);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG Driver_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gMutex);
    return count;
}

static ULONG Driver_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gMutex);
    return count;
}

// MARK: - Lifecycle

static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gLog = os_log_create("app.volumist.driver", "driver");
    gHost = inHost;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gHostClockFrequency = (Float64)timebase.denom / (Float64)timebase.numer * 1000000000.0;
    gHostTicksPerFrame = gHostClockFrequency / gSampleRate;
    pthread_t thread;
    if (pthread_create(&thread, NULL, PollThread, NULL) == 0) pthread_detach(thread);
    os_log(gLog, "initialized");
    return 0;
}

static OSStatus Driver_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *info, AudioObjectID *outID) {
    (void)d; (void)desc; (void)info; (void)outID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Driver_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *info) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    char bundle[VD_BUNDLE_ID_LENGTH] = "";
    if (info->mBundleID) CFStringGetCString(info->mBundleID, bundle, sizeof(bundle), kCFStringEncodingUTF8);
    uint32_t pid = info->mProcessID > 0 ? (uint32_t)info->mProcessID : 0;
    uint32_t owner = pid ? (uint32_t)OwnerOf((pid_t)pid) : 0;
    uint64_t hash = bundle[0] ? vd_hash(bundle) : 0;

    pthread_mutex_lock(&gMutex);
    if (owner != 0 && owner != pid) gOwnerLookupWorks = true;
    int slot = -1;
    for (int i = 0; i < VD_MAX_CLIENTS; i++) {
        if (atomic_load(&gClients[i].clientID) == 0) { slot = i; break; }
    }
    if (slot < 0) {
        gDroppedClients++;
    } else {
        Client *client = &gClients[slot];
        VDShared *shared = atomic_load(&gShared);
        memcpy(client->bundleID, bundle, sizeof(bundle));
        atomic_store(&client->pid, pid);
        atomic_store(&client->ownerPID, owner == pid ? 0 : owner);
        atomic_store(&client->bundleHash, hash);
        // Start at the app's chosen gain so the first buffer is already at the right level.
        client->currentGain = ResolveGain(shared, pid, owner, hash);
        atomic_store_explicit(&client->clientID, info->mClientID, memory_order_release);
        if (shared) {
            PublishClientLocked(shared, slot);
            vd_add64(&shared->clientsAdded, 1);
        }
    }
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *info) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    int slot = FindClient(info->mClientID);
    if (slot >= 0) {
        atomic_store(&gClients[slot].clientID, 0);
        atomic_store(&gClients[slot].pid, 0);
        VDShared *shared = atomic_load(&gShared);
        if (shared) {
            PublishClientLocked(shared, slot);
            vd_add64(&shared->clientsRemoved, 1);
        }
    }
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    Float64 rate = (Float64)inChangeAction;
    pthread_mutex_lock(&gMutex);
    gRateChangePending = false;
    if (IsSupportedRate(rate)) {
        gSampleRate = rate;
        gHostTicksPerFrame = gHostClockFrequency / rate;
        VDShared *shared = atomic_load(&gShared);
        if (shared) vd_store32(&shared->sampleRate, (uint32_t)rate);
        os_log(gLog, "sample rate now %.0f", rate);
    }
    pthread_mutex_unlock(&gMutex);
    return IsSupportedRate(rate) ? 0 : kAudioHardwareIllegalOperationError;
}

static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID id, UInt64 action, void *info) {
    (void)id; (void)action; (void)info;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    gRateChangePending = false;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

// MARK: - Properties

#define RETURN_VALUE(type, value)                                                  \
    do {                                                                           \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError;  \
        *(type *)outData = (value);                                                \
        *outDataSize = sizeof(type);                                               \
        return 0;                                                                  \
    } while (0)

static UInt32 OwnedObjectCount(AudioObjectID object, AudioObjectPropertyScope scope) {
    if (object == kObjectID_PlugIn) return atomic_load(&gDeviceVisible) ? 1 : 0;
    if (object == kObjectID_Device) return scope == kAudioObjectPropertyScopeInput ? 0 : 3;  // stream, volume, mute
    return 0;
}

static Boolean Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress) {
    UInt32 size = 0;
    Float32 qualifier = 0;
    return Driver_GetPropertyDataSize(inDriver, inObjectID, inClientPID, inAddress, sizeof(qualifier), &qualifier, &size) == 0;
}

static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    if (!Driver_HasProperty(inDriver, inObjectID, inClientPID, inAddress)) return kAudioHardwareUnknownPropertyError;
    AudioObjectPropertySelector s = inAddress->mSelector;
    *outIsSettable =
        (inObjectID == kObjectID_Device && s == kAudioDevicePropertyNominalSampleRate) ||
        (inObjectID == kObjectID_Stream && (s == kAudioStreamPropertyVirtualFormat || s == kAudioStreamPropertyPhysicalFormat)) ||
        (inObjectID == kObjectID_Volume && (s == kAudioLevelControlPropertyScalarValue || s == kAudioLevelControlPropertyDecibelValue)) ||
        (inObjectID == kObjectID_Mute && s == kAudioBooleanControlPropertyValue);
    return 0;
}

static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    AudioObjectPropertySelector s = inAddress->mSelector;
    switch (s) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
        *outDataSize = sizeof(AudioClassID);
        return inObjectID <= kObjectID_Mute ? 0 : kAudioHardwareBadObjectError;
    case kAudioObjectPropertyOwner:
        *outDataSize = sizeof(AudioObjectID);
        return inObjectID <= kObjectID_Mute ? 0 : kAudioHardwareBadObjectError;
    case kAudioObjectPropertyOwnedObjects:
        *outDataSize = OwnedObjectCount(inObjectID, inAddress->mScope) * sizeof(AudioObjectID);
        return inObjectID <= kObjectID_Mute ? 0 : kAudioHardwareBadObjectError;
    }
    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (s) {
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle: *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioPlugInPropertyDeviceList: *outDataSize = OwnedObjectCount(kObjectID_PlugIn, 0) * sizeof(AudioObjectID); return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return 0;
        }
        return kAudioHardwareUnknownPropertyError;
    case kObjectID_Device:
        switch (s) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod: *outDataSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyRelatedDevices: *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioDevicePropertyStreams:
            *outDataSize = inAddress->mScope == kAudioObjectPropertyScopeInput ? 0 : sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyControlList: *outDataSize = 2 * sizeof(AudioObjectID); return 0;
        case kAudioDevicePropertyNominalSampleRate: *outDataSize = sizeof(Float64); return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = kSupportedRateCount * sizeof(AudioValueRange); return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo: *outDataSize = 2 * sizeof(UInt32); return 0;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + VD_CHANNELS * sizeof(AudioChannelDescription));
            return 0;
        }
        return kAudioHardwareUnknownPropertyError;
    case kObjectID_Stream:
        switch (s) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency: *outDataSize = sizeof(UInt32); return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: *outDataSize = kSupportedRateCount * sizeof(AudioStreamRangedDescription); return 0;
        }
        return kAudioHardwareUnknownPropertyError;
    case kObjectID_Volume:
        switch (s) {
        case kAudioControlPropertyScope: *outDataSize = sizeof(AudioObjectPropertyScope); return 0;
        case kAudioControlPropertyElement: *outDataSize = sizeof(AudioObjectPropertyElement); return 0;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: *outDataSize = sizeof(Float32); return 0;
        case kAudioLevelControlPropertyDecibelRange: *outDataSize = sizeof(AudioValueRange); return 0;
        }
        return kAudioHardwareUnknownPropertyError;
    case kObjectID_Mute:
        switch (s) {
        case kAudioControlPropertyScope: *outDataSize = sizeof(AudioObjectPropertyScope); return 0;
        case kAudioControlPropertyElement: *outDataSize = sizeof(AudioObjectPropertyElement); return 0;
        case kAudioBooleanControlPropertyValue: *outDataSize = sizeof(UInt32); return 0;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientPID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    AudioObjectPropertySelector s = inAddress->mSelector;

    // Properties every object has.
    if (inObjectID <= kObjectID_Mute) {
        switch (s) {
        case kAudioObjectPropertyBaseClass: {
            AudioClassID base = inObjectID == kObjectID_Volume ? kAudioLevelControlClassID
                              : inObjectID == kObjectID_Mute ? kAudioBooleanControlClassID
                              : kAudioObjectClassID;
            RETURN_VALUE(AudioClassID, base);
        }
        case kAudioObjectPropertyClass: {
            AudioClassID classes[] = {0, kAudioPlugInClassID, kAudioDeviceClassID, kAudioStreamClassID, kAudioVolumeControlClassID, kAudioMuteControlClassID};
            RETURN_VALUE(AudioClassID, classes[inObjectID]);
        }
        case kAudioObjectPropertyOwner:
            RETURN_VALUE(AudioObjectID, inObjectID == kObjectID_PlugIn ? kAudioObjectUnknown
                                      : inObjectID == kObjectID_Device ? kObjectID_PlugIn
                                      : kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: {
            UInt32 count = OwnedObjectCount(inObjectID, inAddress->mScope);
            AudioObjectID owned[3] = {inObjectID == kObjectID_PlugIn ? kObjectID_Device : kObjectID_Stream, kObjectID_Volume, kObjectID_Mute};
            UInt32 fit = inDataSize / sizeof(AudioObjectID);
            if (fit < count) count = fit;
            memcpy(outData, owned, count * sizeof(AudioObjectID));
            *outDataSize = count * sizeof(AudioObjectID);
            return 0;
        }
        }
    }

    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (s) {
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, kManufacturer);
        case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
        case kAudioPlugInPropertyDeviceList:
            if (!atomic_load(&gDeviceVisible) || inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
            RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)inQualifierData;
            bool match = atomic_load(&gDeviceVisible) && uid && CFEqual(uid, kDeviceUID);
            RETURN_VALUE(AudioObjectID, match ? kObjectID_Device : kAudioObjectUnknown);
        }
        }
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Device:
        switch (s) {
        case kAudioObjectPropertyName: RETURN_VALUE(CFStringRef, kDeviceName);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, kManufacturer);
        case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, kDeviceUID);
        case kAudioDevicePropertyModelUID: RETURN_VALUE(CFStringRef, kModelUID);
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gMutex);
            UInt32 running = gIOCount > 0;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kZeroTimeStampPeriod);
        case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeInput || inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
            RETURN_VALUE(AudioObjectID, kObjectID_Stream);
        case kAudioObjectPropertyControlList: {
            if (inDataSize < 2 * sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            ((AudioObjectID *)outData)[0] = kObjectID_Volume;
            ((AudioObjectID *)outData)[1] = kObjectID_Mute;
            *outDataSize = 2 * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioDevicePropertyNominalSampleRate: {
            pthread_mutex_lock(&gMutex);
            Float64 rate = gSampleRate;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(Float64, rate);
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 count = inDataSize / sizeof(AudioValueRange);
            if (count > kSupportedRateCount) count = kSupportedRateCount;
            for (UInt32 i = 0; i < count; i++) ((AudioValueRange *)outData)[i] = (AudioValueRange){kSupportedRates[i], kSupportedRates[i]};
            *outDataSize = count * sizeof(AudioValueRange);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + VD_CHANNELS * sizeof(AudioChannelDescription));
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = VD_CHANNELS;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = size;
            return 0;
        }
        }
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Stream:
        switch (s) {
        case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, 0);  // output
        case kAudioStreamPropertyTerminalType: RETURN_VALUE(UInt32, kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            pthread_mutex_lock(&gMutex);
            AudioStreamBasicDescription format = StreamFormat(gSampleRate);
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(AudioStreamBasicDescription, format);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 count = inDataSize / sizeof(AudioStreamRangedDescription);
            if (count > kSupportedRateCount) count = kSupportedRateCount;
            for (UInt32 i = 0; i < count; i++) {
                ((AudioStreamRangedDescription *)outData)[i] = (AudioStreamRangedDescription){StreamFormat(kSupportedRates[i]), {kSupportedRates[i], kSupportedRates[i]}};
            }
            *outDataSize = count * sizeof(AudioStreamRangedDescription);
            return 0;
        }
        }
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Volume:
        switch (s) {
        case kAudioControlPropertyScope: RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioLevelControlPropertyScalarValue: {
            pthread_mutex_lock(&gMutex);
            Float32 volume = gVolume;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(Float32, volume);
        }
        case kAudioLevelControlPropertyDecibelValue: {
            pthread_mutex_lock(&gMutex);
            Float32 volume = gVolume;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(Float32, ScalarToDecibels(volume));
        }
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange range = {kMinDecibels, 0};
            RETURN_VALUE(AudioValueRange, range);
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            *(Float32 *)outData = ScalarToDecibels(*(Float32 *)outData);
            *outDataSize = sizeof(Float32);
            return 0;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            *(Float32 *)outData = DecibelsToScalar(*(Float32 *)outData);
            *outDataSize = sizeof(Float32);
            return 0;
        }
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Mute:
        switch (s) {
        case kAudioControlPropertyScope: RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioBooleanControlPropertyValue: {
            pthread_mutex_lock(&gMutex);
            UInt32 mute = gMute;
            pthread_mutex_unlock(&gMutex);
            RETURN_VALUE(UInt32, mute);
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    AudioObjectPropertySelector s = inAddress->mSelector;

    // Sample rate, set on the device or through a stream format.
    Float64 rate = 0;
    if (inObjectID == kObjectID_Device && s == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        rate = *(const Float64 *)inData;
    } else if (inObjectID == kObjectID_Stream && (s == kAudioStreamPropertyVirtualFormat || s == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *format = inData;
        AudioStreamBasicDescription expected = StreamFormat(format->mSampleRate);
        if (format->mFormatID != expected.mFormatID || format->mChannelsPerFrame != expected.mChannelsPerFrame ||
            format->mBitsPerChannel != expected.mBitsPerChannel || (format->mFormatFlags & kAudioFormatFlagIsFloat) == 0) {
            return kAudioDeviceUnsupportedFormatError;
        }
        rate = format->mSampleRate;
    }
    if (rate != 0) {
        if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
        pthread_mutex_lock(&gMutex);
        bool change = rate != gSampleRate && !gRateChangePending;
        if (change) gRateChangePending = true;
        pthread_mutex_unlock(&gMutex);
        if (change) RequestRateChange(rate);
        return 0;
    }

    if (inObjectID == kObjectID_Volume && (s == kAudioLevelControlPropertyScalarValue || s == kAudioLevelControlPropertyDecibelValue)) {
        if (inDataSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value = *(const Float32 *)inData;
        Float32 volume = s == kAudioLevelControlPropertyScalarValue ? value : DecibelsToScalar(value);
        if (volume < 0) volume = 0;
        if (volume > 1) volume = 1;
        pthread_mutex_lock(&gMutex);
        bool changed = volume != gVolume;
        gVolume = volume;
        VDShared *shared = atomic_load(&gShared);
        if (changed && shared) {
            vd_store32(&shared->volumeBits, vd_bits(volume));
            vd_add32(&shared->volumeSeq, 1);
        }
        pthread_mutex_unlock(&gMutex);
        if (changed) NotifyVolumeChanged();
        return 0;
    }

    if (inObjectID == kObjectID_Mute && s == kAudioBooleanControlPropertyValue) {
        if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        bool mute = *(const UInt32 *)inData != 0;
        pthread_mutex_lock(&gMutex);
        bool changed = mute != gMute;
        gMute = mute;
        VDShared *shared = atomic_load(&gShared);
        if (changed && shared) {
            vd_store32(&shared->mute, mute);
            vd_add32(&shared->volumeSeq, 1);
        }
        pthread_mutex_unlock(&gMutex);
        if (changed) NotifyMuteChanged();
        return 0;
    }

    return Driver_HasProperty(inDriver, inObjectID, inClientPID, inAddress) ? kAudioHardwareUnsupportedOperationError : kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus Driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
    }
    gIOCount++;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus Driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerPeriod);
    if (next <= now) gNumberTimeStamps++;
    *outSampleTime = (Float64)(gNumberTimeStamps * kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    return 0;
}

static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (outWillDo) *outWillDo = inOperationID == kAudioServerPlugInIOOperationProcessOutput || inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return 0;
}

static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 o, UInt32 f, const AudioServerPlugInIOCycleInfo *i) {
    (void)d; (void)id; (void)c; (void)o; (void)f; (void)i;
    return 0;
}

static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 o, UInt32 f, const AudioServerPlugInIOCycleInfo *i) {
    (void)d; (void)id; (void)c; (void)o; (void)f; (void)i;
    return 0;
}

static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inStreamObjectID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    float *samples = ioMainBuffer;
    VDShared *shared = atomic_load_explicit(&gShared, memory_order_acquire);

    if (inOperationID == kAudioServerPlugInIOOperationProcessOutput) {
        int slot = FindClient(inClientID);
        if (slot < 0 || inIOBufferFrameSize == 0) return 0;
        Client *client = &gClients[slot];
        float target = ResolveGain(shared,
                                   atomic_load_explicit(&client->pid, memory_order_relaxed),
                                   atomic_load_explicit(&client->ownerPID, memory_order_relaxed),
                                   atomic_load_explicit(&client->bundleHash, memory_order_relaxed));
        float gain = client->currentGain;
        float step = (target - gain) / (float)inIOBufferFrameSize;
        float peak = 0;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; frame++) {
            gain += step;
            for (UInt32 ch = 0; ch < VD_CHANNELS; ch++) {
                float value = samples[frame * VD_CHANNELS + ch] * gain;
                samples[frame * VD_CHANNELS + ch] = value;
                float magnitude = fabsf(value);
                if (magnitude > peak) peak = magnitude;
            }
        }
        client->currentGain = target;
        if (shared) {
            vd_raise_peak(&shared->clients[slot].peakBits, peak);
            __atomic_store_n(&shared->clients[slot].gainBits, vd_bits(target), __ATOMIC_RELAXED);
        }
        return 0;
    }

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && shared) {
        uint64_t start = (uint64_t)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; frame++) {
            uint64_t index = ((start + frame) & (VD_RING_FRAMES - 1)) * VD_CHANNELS;
            for (UInt32 ch = 0; ch < VD_CHANNELS; ch++) shared->ring[index + ch] = samples[frame * VD_CHANNELS + ch];
        }
        vd_store64(&shared->writeFrame, start + inIOBufferFrameSize);
        __atomic_add_fetch(&shared->mixCycles, 1, __ATOMIC_RELAXED);
    }
    return 0;
}
