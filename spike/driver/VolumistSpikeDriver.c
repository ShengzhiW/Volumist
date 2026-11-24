// Volumist spike driver: a minimal AudioServerPlugIn with one stereo 48 kHz output device.
//
// It answers the spike's questions:
//   - AddDeviceClient: which process (PID, bundle ID) is each client?
//   - ProcessOutput: apply a per-process gain (from shared memory) before the mix.
//   - WriteMix: copy the mix into a shared-memory ring buffer the host app plays out.
// Structure follows Apple's "Creating an Audio Server Driver Plug-in" (NullAudio) sample.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "../shared.h"

// MARK: - Objects and constants

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream = 3,
};

#define kDeviceName CFSTR("Volumist Spike")
#define kManufacturer CFSTR("Volumist")
#define kDeviceUID CFSTR(VSPIKE_DEVICE_UID)
#define kModelUID CFSTR("VolumistSpike_Model")
#define kZeroTimeStampPeriod VSPIKE_RING_FRAMES

static os_log_t gLog;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;

// Clock (NullAudio's scheme: a free-running host-time clock at the nominal rate).
static Float64 gHostTicksPerFrame = 0;
static UInt64 gIOCount = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;

// Clients known to the device. Written under gStateMutex, read on the IO thread.
typedef struct {
    _Atomic uint32_t clientID;  // 0 = unused
    _Atomic int32_t pid;
    float currentGain;          // IO thread only
    char bundleID[128];
} Client;
static Client gClients[VSPIKE_MAX_CLIENTS];

// Shared memory with the host (NULL until attached). Never unmapped once mapped, so the
// IO thread can't touch freed memory; a re-attach maps a fresh region.
static _Atomic(VSpikeShared *) gShared = NULL;

// MARK: - Shared memory

static void MirrorClientsLocked(VSpikeShared *shared) {
    for (int i = 0; i < VSPIKE_MAX_CLIENTS; i++) {
        uint32_t id = atomic_load(&gClients[i].clientID);
        if (id == 0) {
            atomic_store(&shared->clients[i].pid, 0);
            continue;
        }
        memcpy(shared->clients[i].bundleID, gClients[i].bundleID, sizeof(gClients[i].bundleID));
        atomic_store(&shared->clients[i].clientID, id);
        atomic_store(&shared->clients[i].pid, atomic_load(&gClients[i].pid));
    }
}

/// Attach to the host's shared memory if it exists and isn't attached yet. Not real-time safe.
static void AttachSharedLocked(const char *reason) {
    VSpikeShared *current = atomic_load(&gShared);
    if (current != NULL) {
        // Still the same live host?
        if (kill(current->hostPID, 0) == 0 || errno == EPERM) return;
        os_log(gLog, "host pid %d gone; detaching", current->hostPID);
        atomic_store(&gShared, NULL);
    }

    int fd = shm_open(VSPIKE_SHM_NAME, O_RDWR);
    if (fd < 0) {
        os_log(gLog, "attach (%{public}s): shm_open failed errno=%d (%{public}s)", reason, errno, strerror(errno));
        return;
    }
    void *mapped = mmap(NULL, sizeof(VSpikeShared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    int mapErrno = errno;
    close(fd);
    if (mapped == MAP_FAILED) {
        os_log(gLog, "attach (%{public}s): mmap failed errno=%d (%{public}s)", reason, mapErrno, strerror(mapErrno));
        return;
    }
    VSpikeShared *shared = mapped;
    if (shared->magic != VSPIKE_MAGIC || shared->version != VSPIKE_VERSION) {
        os_log(gLog, "attach (%{public}s): bad header magic=%x version=%u", reason, shared->magic, shared->version);
        munmap(mapped, sizeof(VSpikeShared));
        return;
    }
    MirrorClientsLocked(shared);
    atomic_fetch_add(&shared->driverAttachCount, 1);
    atomic_store(&gShared, shared);
    os_log(gLog, "attach (%{public}s): attached to host pid %d", reason, shared->hostPID);
}

// MARK: - Helpers

static int FindClientIndex(UInt32 clientID) {
    for (int i = 0; i < VSPIKE_MAX_CLIENTS; i++) {
        if (atomic_load_explicit(&gClients[i].clientID, memory_order_acquire) == clientID) return i;
    }
    return -1;
}

static float GainForPID(VSpikeShared *shared, int32_t pid) {
    if (shared == NULL || pid <= 0) return 1.0f;
    for (int i = 0; i < VSPIKE_MAX_CLIENTS; i++) {
        if (atomic_load_explicit(&shared->gains[i].pid, memory_order_acquire) == pid) {
            uint32_t bits = atomic_load_explicit(&shared->gains[i].gainBits, memory_order_relaxed);
            float gain;
            memcpy(&gain, &bits, sizeof(gain));
            return gain;
        }
    }
    return 1.0f;
}

static void RaisePeak(_Atomic uint32_t *bits, float peak) {
    uint32_t current = atomic_load_explicit(bits, memory_order_relaxed);
    for (;;) {
        float value;
        memcpy(&value, &current, sizeof(value));
        if (peak <= value) return;
        uint32_t desired;
        memcpy(&desired, &peak, sizeof(desired));
        if (atomic_compare_exchange_weak_explicit(bits, &current, desired, memory_order_relaxed, memory_order_relaxed)) return;
    }
}

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = VSPIKE_SAMPLE_RATE;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = 4 * VSPIKE_CHANNELS;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4 * VSPIKE_CHANNELS;
    format.mChannelsPerFrame = VSPIKE_CHANNELS;
    format.mBitsPerChannel = 32;
    return format;
}

#define RETURN_VALUE(type, value)                                  \
    do {                                                           \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *(type *)outData = (value);                                \
        *outDataSize = sizeof(type);                               \
        return 0;                                                  \
    } while (0)

// MARK: - Forward declarations

static HRESULT Driver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG Driver_AddRef(void *inDriver);
static ULONG Driver_Release(void *inDriver);
static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
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
    Driver_QueryInterface,
    Driver_AddRef,
    Driver_Release,
    Driver_Initialize,
    Driver_CreateDevice,
    Driver_DestroyDevice,
    Driver_AddDeviceClient,
    Driver_RemoveDeviceClient,
    Driver_PerformDeviceConfigurationChange,
    Driver_AbortDeviceConfigurationChange,
    Driver_HasProperty,
    Driver_IsPropertySettable,
    Driver_GetPropertyDataSize,
    Driver_GetPropertyData,
    Driver_SetPropertyData,
    Driver_StartIO,
    Driver_StopIO,
    Driver_GetZeroTimeStamp,
    Driver_WillDoIOOperation,
    Driver_BeginIOOperation,
    Driver_DoIOOperation,
    Driver_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory and COM boilerplate

void *VolumistSpike_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
__attribute__((visibility("default"))) void *VolumistSpike_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT Driver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG Driver_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Driver_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

// MARK: - Basic operations

static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gLog = os_log_create("app.volumist.spike", "driver");
    gHost = inHost;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 hostClockFrequency = (Float64)timebase.denom / (Float64)timebase.numer * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / VSPIKE_SAMPLE_RATE;
    os_log(gLog, "initialized (pid %d)", getpid());
    pthread_mutex_lock(&gStateMutex);
    AttachSharedLocked("initialize");
    pthread_mutex_unlock(&gStateMutex);
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

static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    char bundle[128] = "";
    if (inClientInfo->mBundleID != NULL) {
        CFStringGetCString(inClientInfo->mBundleID, bundle, sizeof(bundle), kCFStringEncodingUTF8);
    }
    pthread_mutex_lock(&gStateMutex);
    AttachSharedLocked("add client");
    int slot = -1;
    for (int i = 0; i < VSPIKE_MAX_CLIENTS; i++) {
        if (atomic_load(&gClients[i].clientID) == 0) { slot = i; break; }
    }
    if (slot >= 0) {
        memcpy(gClients[slot].bundleID, bundle, sizeof(bundle));
        gClients[slot].currentGain = 1.0f;
        atomic_store(&gClients[slot].pid, inClientInfo->mProcessID);
        atomic_store_explicit(&gClients[slot].clientID, inClientInfo->mClientID, memory_order_release);
        VSpikeShared *shared = atomic_load(&gShared);
        if (shared) MirrorClientsLocked(shared);
    }
    pthread_mutex_unlock(&gStateMutex);
    os_log(gLog, "client added id=%u pid=%d bundle=%{public}s slot=%d", inClientInfo->mClientID, inClientInfo->mProcessID, bundle, slot);
    return 0;
}

static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    int slot = FindClientIndex(inClientInfo->mClientID);
    if (slot >= 0) {
        atomic_store(&gClients[slot].clientID, 0);
        atomic_store(&gClients[slot].pid, 0);
        VSpikeShared *shared = atomic_load(&gShared);
        if (shared) MirrorClientsLocked(shared);
    }
    pthread_mutex_unlock(&gStateMutex);
    os_log(gLog, "client removed id=%u pid=%d", inClientInfo->mClientID, inClientInfo->mProcessID);
    return 0;
}

static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) {
    (void)d; (void)id; (void)a; (void)i;
    return 0;
}

static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) {
    (void)d; (void)id; (void)a; (void)i;
    return 0;
}

// MARK: - Properties

static Boolean Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress) {
    UInt32 size = 0;
    return Driver_GetPropertyDataSize(inDriver, inObjectID, inClientPID, inAddress, 0, NULL, &size) == 0;
}

static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    if (!Driver_HasProperty(inDriver, inObjectID, inClientPID, inAddress)) return kAudioHardwareUnknownPropertyError;
    *outIsSettable = false;
    return 0;
}

static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    AudioObjectPropertySelector s = inAddress->mSelector;
    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (s) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass: *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle: *outDataSize = sizeof(CFStringRef); return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return 0;
        }
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Device:
        switch (s) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass: *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioObjectID); return 0;
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
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 0 : sizeof(AudioObjectID);
            return 0;
        case kAudioObjectPropertyControlList: *outDataSize = 0; return 0;
        case kAudioDevicePropertyNominalSampleRate: *outDataSize = sizeof(Float64); return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo: *outDataSize = 2 * sizeof(UInt32); return 0;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + VSPIKE_CHANNELS * sizeof(AudioChannelDescription));
            return 0;
        }
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Stream:
        switch (s) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass: *outDataSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return 0;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency: *outDataSize = sizeof(UInt32); return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: *outDataSize = sizeof(AudioStreamRangedDescription); return 0;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientPID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    AudioObjectPropertySelector s = inAddress->mSelector;
    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (s) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, kManufacturer);
        case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
            RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)inQualifierData;
            RETURN_VALUE(AudioObjectID, CFEqual(uid, kDeviceUID) ? kObjectID_Device : kAudioObjectUnknown);
        }
        }
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Device:
        switch (s) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName: RETURN_VALUE(CFStringRef, kDeviceName);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, kManufacturer);
        case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, kDeviceUID);
        case kAudioDevicePropertyModelUID: RETURN_VALUE(CFStringRef, kModelUID);
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOCount > 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kZeroTimeStampPeriod);
        case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeInput || inDataSize < sizeof(AudioObjectID)) {
                *outDataSize = 0;
                return 0;
            }
            RETURN_VALUE(AudioObjectID, kObjectID_Stream);
        case kAudioObjectPropertyControlList: *outDataSize = 0; return 0;
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, VSPIKE_SAMPLE_RATE);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = {VSPIKE_SAMPLE_RATE, VSPIKE_SAMPLE_RATE};
            RETURN_VALUE(AudioValueRange, range);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + VSPIKE_CHANNELS * sizeof(AudioChannelDescription));
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = VSPIKE_CHANNELS;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = size;
            return 0;
        }
        }
        return kAudioHardwareUnknownPropertyError;

    case kObjectID_Stream:
        switch (s) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return 0;
        case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, 0);  // 0 = output
        case kAudioStreamPropertyTerminalType: RETURN_VALUE(UInt32, kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: RETURN_VALUE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription ranged = {StreamFormat(), {VSPIKE_SAMPLE_RATE, VSPIKE_SAMPLE_RATE}};
            RETURN_VALUE(AudioStreamRangedDescription, ranged);
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver; (void)inObjectID; (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize; (void)inData;
    // The spike's format is fixed. Accept writes of the current values so clients don't error out.
    if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate && inDataSize == sizeof(Float64) &&
        *(const Float64 *)inData == VSPIKE_SAMPLE_RATE) return 0;
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: - IO

static OSStatus Driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    AttachSharedLocked("start io");
    if (gIOCount == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
    }
    gIOCount++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 nextHostTime = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerPeriod);
    if (nextHostTime <= now) gNumberTimeStamps++;
    *outSampleTime = (Float64)(gNumberTimeStamps * kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    return 0;
}

static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean willDo = inOperationID == kAudioServerPlugInIOOperationProcessOutput || inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = willDo;
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
    UInt32 count = inIOBufferFrameSize * VSPIKE_CHANNELS;
    VSpikeShared *shared = atomic_load_explicit(&gShared, memory_order_acquire);

    if (inOperationID == kAudioServerPlugInIOOperationProcessOutput) {
        int slot = FindClientIndex(inClientID);
        if (slot < 0) return 0;
        int32_t pid = atomic_load_explicit(&gClients[slot].pid, memory_order_relaxed);
        float target = GainForPID(shared, pid);
        float gain = gClients[slot].currentGain;
        float step = (target - gain) / (float)(inIOBufferFrameSize ? inIOBufferFrameSize : 1);
        float peak = 0;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; frame++) {
            gain += step;
            for (UInt32 ch = 0; ch < VSPIKE_CHANNELS; ch++) {
                float value = samples[frame * VSPIKE_CHANNELS + ch] * gain;
                samples[frame * VSPIKE_CHANNELS + ch] = value;
                float magnitude = fabsf(value);
                if (magnitude > peak) peak = magnitude;
            }
        }
        gClients[slot].currentGain = target;
        if (shared) RaisePeak(&shared->clients[slot].peakBits, peak);
        return 0;
    }

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && shared) {
        uint64_t start = (uint64_t)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; frame++) {
            uint64_t index = ((start + frame) & (VSPIKE_RING_FRAMES - 1)) * VSPIKE_CHANNELS;
            for (UInt32 ch = 0; ch < VSPIKE_CHANNELS; ch++) {
                shared->ring[index + ch] = samples[frame * VSPIKE_CHANNELS + ch];
            }
        }
        atomic_store_explicit(&shared->writeFrame, start + inIOBufferFrameSize, memory_order_release);
        atomic_fetch_add_explicit(&shared->mixCycles, 1, memory_order_relaxed);
        (void)count;
    }
    return 0;
}
