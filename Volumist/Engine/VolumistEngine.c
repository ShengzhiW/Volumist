#include "VolumistEngine.h"

#include <AudioToolbox/AudioServices.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <pwd.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "VolumistDriverProtocol.h"

// Drift correction: keep about this much audio buffered (scaled with the sample rate, and never
// less than the driver's largest burst plus two output buffers), and steer toward it by
// resampling at most ±0.3%. Measured drift between the driver's clock and real devices is tens
// of ppm, so the correction is far below audibility. With this gain a 1-frame error at 1024
// frames shifts the ratio by ~10 ppm; buffer-quantization ripple stays a few ppm (< 0.1 cent).
#define kBaseTargetSeconds (1024.0 / 48000.0)
#define kGainPerError 0.01
#define kMaxRatioOffset 0.003
#define kSmoothing 0.01
#define kIdleCallbacks 4

struct VEEngine {
    char socketPath[104];
    uid_t peerUID;
    VDShared *shared;
    int memoryFD;            // the unnamed shared memory, handed to the driver
    int listenFD;
    int clientFD;            // the driver's connection (server thread only)
    _Atomic int driverReply;
    _Atomic bool heartbeatPaused;
    pthread_t heartbeatThread;
    pthread_t serverThread;
    _Atomic bool stopping;
    pthread_mutex_t mutex;

    AudioObjectID device;
    AudioDeviceIOProcID ioProc;
    _Atomic uint64_t deviceRateBits;  // double bits
    _Atomic int leftChannel, rightChannel;

    // Render state: only touched by the output's IO thread (or before it starts).
    bool primed;
    double readPosition;
    double smoothedLag;
    double ratio;
    uint64_t lastWriteFrame;
    uint64_t largestBurst;   // biggest single advance of the driver's write position
    int idleCallbacks;
    _Atomic uint64_t underruns, resyncs, lagBits, ratioBits;
    _Atomic uint32_t targetFrames;

    // Rules staged between begin and commit (main thread).
    int stagedCount;
    struct { uint32_t pid; uint64_t hash; float gain; } staged[VD_MAX_RULES];

    // Last volume/mute pushed to the device, to avoid churning its sequence numbers.
    float pushedVolume;
    int pushedMute;
};

static uint64_t DoubleBits(double value) { uint64_t bits; memcpy(&bits, &value, sizeof(bits)); return bits; }
static double BitsDouble(uint64_t bits) { double value; memcpy(&value, &bits, sizeof(value)); return value; }

// MARK: - Lifecycle

static Float64 NominalRate(AudioObjectID device) {
    Float64 rate = 0;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(rate);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &rate) != noErr) return 0;
    return rate;
}

static void *Heartbeat(void *context) {
    VEEngine *engine = context;
    pthread_setname_np("Volumist engine heartbeat");
    while (!atomic_load(&engine->stopping)) {
        if (!atomic_load(&engine->heartbeatPaused)) {
            vd_store64(&engine->shared->heartbeatNanos, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        }
        pthread_mutex_lock(&engine->mutex);
        AudioObjectID device = engine->device;
        pthread_mutex_unlock(&engine->mutex);
        if (device != kAudioObjectUnknown) {
            // Follow the real device's rate (it can change while we play to it).
            Float64 rate = NominalRate(device);
            if (rate > 0) {
                atomic_store(&engine->deviceRateBits, DoubleBits(rate));
                vd_store32(&engine->shared->requestedSampleRate, (uint32_t)rate);
            }
        }
        usleep(250 * 1000);
    }
    return NULL;
}

// MARK: - Handing the memory to the driver

/// Sends the handshake with the memory's descriptor attached.
static bool SendMemory(int fd, int memoryFD) {
    VDHandshake handshake = {VD_MAGIC, VD_VERSION, sizeof(VDShared)};
    struct iovec iov = {&handshake, sizeof(handshake)};
    union { struct cmsghdr header; char space[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof(control));
    struct msghdr message = {0};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.space;
    message.msg_controllen = sizeof(control.space);
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &memoryFD, sizeof(int));
    return sendmsg(fd, &message, 0) == sizeof(handshake);
}

static void HandleConnection(VEEngine *engine, int fd) {
    // Only Core Audio's account gets the memory: nothing else can read the mix or change gains.
    uid_t uid;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0 || uid != engine->peerUID) {
        close(fd);
        return;
    }
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    struct timeval timeout = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (!SendMemory(fd, engine->memoryFD)) {
        close(fd);
        return;
    }
    VDReply reply = {0};
    if (recv(fd, &reply, sizeof(reply), MSG_WAITALL) == sizeof(reply) && reply.magic == VD_MAGIC) {
        atomic_store(&engine->driverReply, (int)reply.status);
    }
    if (reply.magic != VD_MAGIC || reply.status != VD_REPLY_ATTACHED) {
        close(fd);
        return;
    }
    // Keep the connection: when it closes (we quit or crash), the driver removes the device at once.
    if (engine->clientFD >= 0) close(engine->clientFD);
    engine->clientFD = fd;
}

static void *Server(void *context) {
    VEEngine *engine = context;
    pthread_setname_np("Volumist engine server");
    while (!atomic_load(&engine->stopping)) {
        struct pollfd fds[2] = {{engine->listenFD, POLLIN, 0}, {engine->clientFD, POLLIN, 0}};
        int count = engine->clientFD >= 0 ? 2 : 1;
        if (poll(fds, (nfds_t)count, 250) <= 0) continue;
        if (count == 2 && (fds[1].revents & (POLLHUP | POLLERR | POLLIN))) {
            char byte;
            if (recv(engine->clientFD, &byte, 1, MSG_DONTWAIT) <= 0 && errno != EAGAIN) {
                close(engine->clientFD);  // the driver went away (Core Audio restarted)
                engine->clientFD = -1;
            }
        }
        if (fds[0].revents & POLLIN) {
            int fd = accept(engine->listenFD, NULL, NULL);
            if (fd >= 0) HandleConnection(engine, fd);
        }
    }
    return NULL;
}

static int CreateMemory(VDShared **outShared) {
    // Create, then unlink at once: the only way in is the descriptor we hand to the driver.
    char name[32];
    for (int attempt = 0; attempt < 8; attempt++) {
        snprintf(name, sizeof(name), "/avm.%d.%08x", getpid(), arc4random());
        int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd < 0) continue;
        shm_unlink(name);
        void *mapped = MAP_FAILED;
        if (ftruncate(fd, sizeof(VDShared)) == 0) {
            mapped = mmap(NULL, sizeof(VDShared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        }
        if (mapped == MAP_FAILED) {
            close(fd);
            return -1;
        }
        *outShared = mapped;
        return fd;
    }
    return -1;
}

static int Listen(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    unlink(path);  // a crashed run may have left one behind
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 4) != 0) {
        close(fd);
        return -1;
    }
    chmod(path, 0666);  // so _coreaudiod can connect; what it gets is checked in HandleConnection
    return fd;
}

VEEngine *ve_create(const char *socketPath, int peerUID) {
    VEEngine *engine = calloc(1, sizeof(VEEngine));
    if (!engine) return NULL;
    strlcpy(engine->socketPath, socketPath ? socketPath : VD_SOCKET_PATH, sizeof(engine->socketPath));
    if (peerUID < 0) {
        struct passwd *coreaudio = getpwnam("_coreaudiod");
        engine->peerUID = coreaudio ? coreaudio->pw_uid : 202;
    } else {
        engine->peerUID = (uid_t)peerUID;
    }
    pthread_mutex_init(&engine->mutex, NULL);
    engine->ratio = 1;
    engine->pushedVolume = -1;
    engine->pushedMute = -1;
    engine->clientFD = -1;
    atomic_store(&engine->driverReply, -1);
    atomic_store(&engine->leftChannel, 0);
    atomic_store(&engine->rightChannel, 1);
    atomic_store(&engine->ratioBits, DoubleBits(1));

    engine->memoryFD = CreateMemory(&engine->shared);
    if (engine->memoryFD < 0) { free(engine); return NULL; }
    memset(engine->shared, 0, sizeof(VDShared));
    engine->shared->hostPID = (uint32_t)getpid();
    engine->shared->version = VD_VERSION;
    vd_store64(&engine->shared->heartbeatNanos, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    vd_store32(&engine->shared->magic, VD_MAGIC);  // published last

    engine->listenFD = Listen(engine->socketPath);
    if (engine->listenFD < 0 ||
        pthread_create(&engine->heartbeatThread, NULL, Heartbeat, engine) != 0) {
        if (engine->listenFD >= 0) close(engine->listenFD);
        munmap(engine->shared, sizeof(VDShared));
        close(engine->memoryFD);
        free(engine);
        return NULL;
    }
    if (pthread_create(&engine->serverThread, NULL, Server, engine) != 0) {
        atomic_store(&engine->stopping, true);
        pthread_join(engine->heartbeatThread, NULL);
        close(engine->listenFD);
        unlink(engine->socketPath);
        munmap(engine->shared, sizeof(VDShared));
        close(engine->memoryFD);
        free(engine);
        return NULL;
    }
    return engine;
}

void ve_destroy(VEEngine *engine) {
    if (!engine) return;
    atomic_store(&engine->stopping, true);
    pthread_join(engine->heartbeatThread, NULL);
    pthread_join(engine->serverThread, NULL);
    ve_stop_output(engine);
    close(engine->listenFD);
    unlink(engine->socketPath);
    if (engine->clientFD >= 0) close(engine->clientFD);  // the driver removes the device now
    munmap(engine->shared, sizeof(VDShared));
    close(engine->memoryFD);
    pthread_mutex_destroy(&engine->mutex);
    free(engine);
}

int ve_driver_reply(VEEngine *engine) { return atomic_load(&engine->driverReply); }
void ve_pause_heartbeat_for_test(VEEngine *engine, bool paused) { atomic_store(&engine->heartbeatPaused, paused); }

// MARK: - Output

static OSStatus IOProc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
                       AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime; (void)outputTime;
    VEEngine *engine = context;
    ve_render(engine, output, BitsDouble(atomic_load_explicit(&engine->deviceRateBits, memory_order_relaxed)));
    return noErr;
}

static void DisableInputStreams(AudioObjectID device, AudioDeviceIOProcID proc) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size == 0) return;
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return;
    usage->mIOProc = (void *)proc;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, usage) == noErr) {
        for (UInt32 i = 0; i < usage->mNumberStreams; i++) usage->mStreamIsOn[i] = 0;
        AudioObjectSetPropertyData(device, &address, 0, NULL, size, usage);
    }
    free(usage);
}

static void StopOutputLocked(VEEngine *engine) {
    if (engine->device != kAudioObjectUnknown && engine->ioProc) {
        AudioDeviceStop(engine->device, engine->ioProc);
        AudioDeviceDestroyIOProcID(engine->device, engine->ioProc);
    }
    engine->ioProc = NULL;
    engine->device = kAudioObjectUnknown;
}

void ve_stop_output(VEEngine *engine) {
    pthread_mutex_lock(&engine->mutex);
    StopOutputLocked(engine);
    pthread_mutex_unlock(&engine->mutex);
}

OSStatus ve_set_output(VEEngine *engine, AudioObjectID device) {
    pthread_mutex_lock(&engine->mutex);
    StopOutputLocked(engine);

    // Fresh render state for the new device (its IO thread isn't running yet).
    engine->primed = false;
    engine->ratio = 1;
    engine->idleCallbacks = 0;
    engine->largestBurst = 0;

    Float64 rate = NominalRate(device);
    if (rate > 0) {
        atomic_store(&engine->deviceRateBits, DoubleBits(rate));
        vd_store32(&engine->shared->requestedSampleRate, (uint32_t)rate);
    }
    UInt32 pair[2] = {1, 2};
    UInt32 size = sizeof(pair);
    AudioObjectPropertyAddress stereo = {kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &stereo, 0, NULL, &size, pair) != noErr || pair[0] == 0 || pair[1] == 0) {
        pair[0] = 1;
        pair[1] = 2;
    }
    atomic_store(&engine->leftChannel, (int)pair[0] - 1);
    atomic_store(&engine->rightChannel, (int)pair[1] - 1);

    AudioDeviceIOProcID proc = NULL;
    OSStatus status = AudioDeviceCreateIOProcID(device, IOProc, engine, &proc);
    if (status == noErr) {
        DisableInputStreams(device, proc);  // don't wake a microphone (or show its indicator)
        status = AudioDeviceStart(device, proc);
        if (status != noErr) AudioDeviceDestroyIOProcID(device, proc);
    }
    if (status == noErr) {
        engine->device = device;
        engine->ioProc = proc;
    }
    pthread_mutex_unlock(&engine->mutex);
    return status;
}

// MARK: - Render

typedef struct { float *data; int stride; int channel; UInt32 frames; } Target;

/// Where output channel `index` (counted across all buffers) lives.
static Target Locate(AudioBufferList *output, int index) {
    int base = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        int channels = (int)output->mBuffers[b].mNumberChannels;
        if (index >= base && index < base + channels && output->mBuffers[b].mData) {
            return (Target){output->mBuffers[b].mData, channels, index - base, output->mBuffers[b].mDataByteSize / (UInt32)(sizeof(float) * channels)};
        }
        base += channels;
    }
    return (Target){NULL, 0, 0, 0};
}

static void Resync(VEEngine *engine) {
    engine->primed = false;
    atomic_fetch_add_explicit(&engine->resyncs, 1, memory_order_relaxed);
}

void ve_render(VEEngine *engine, AudioBufferList *output, double outputRate) {
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
    VDShared *shared = engine->shared;
    Target left = Locate(output, atomic_load_explicit(&engine->leftChannel, memory_order_relaxed));
    Target right = Locate(output, atomic_load_explicit(&engine->rightChannel, memory_order_relaxed));
    if (!left.data) left = Locate(output, 0);
    if (!left.data) return;
    bool mono = !right.data || (right.data == left.data && right.channel == left.channel);
    UInt32 frames = left.frames;
    if (!mono && right.frames < frames) frames = right.frames;
    if (frames == 0) return;

    uint64_t write = vd_load64(&shared->writeFrame);
    bool advancing = write != engine->lastWriteFrame;
    if (advancing && write > engine->lastWriteFrame && engine->lastWriteFrame != 0) {
        uint64_t burst = write - engine->lastWriteFrame;
        if (burst > engine->largestBurst && burst < VD_RING_FRAMES / 4) engine->largestBurst = burst;
    }
    engine->lastWriteFrame = write;

    double rate = outputRate > 0 ? outputRate : 48000;
    double target = fmax(round(rate * kBaseTargetSeconds), (double)engine->largestBurst + 2.0 * frames + 128);
    atomic_store_explicit(&engine->targetFrames, (uint32_t)target, memory_order_relaxed);
    engine->idleCallbacks = advancing ? 0 : engine->idleCallbacks + 1;
    bool idle = engine->idleCallbacks >= kIdleCallbacks;  // driver IO stopped: nothing is playing

    if (!engine->primed) {
        if (!advancing || (double)write < target) return;
        engine->readPosition = (double)write - target;
        engine->smoothedLag = target;
        engine->ratio = 1;
        engine->primed = true;
    }

    double available = (double)write - engine->readPosition;
    if (available < frames * engine->ratio + 2) {
        if (!idle) atomic_fetch_add_explicit(&engine->underruns, 1, memory_order_relaxed);
        Resync(engine);
        return;
    }
    if (available > VD_RING_FRAMES / 2) {  // driver restarted or we fell far behind
        Resync(engine);
        return;
    }

    // Steer the buffered amount toward the target by resampling slightly.
    engine->smoothedLag += kSmoothing * (available - engine->smoothedLag);
    double offset = kGainPerError * (engine->smoothedLag - target) / target;
    if (offset > kMaxRatioOffset) offset = kMaxRatioOffset;
    if (offset < -kMaxRatioOffset) offset = -kMaxRatioOffset;
    engine->ratio = 1 + offset;

    const float *ring = shared->ring;
    double position = engine->readPosition;
    for (UInt32 f = 0; f < frames; f++) {
        double at = position + f * engine->ratio;
        uint64_t whole = (uint64_t)at;
        float frac = (float)(at - (double)whole);
        uint64_t i0 = (whole & (VD_RING_FRAMES - 1)) * VD_CHANNELS;
        uint64_t i1 = ((whole + 1) & (VD_RING_FRAMES - 1)) * VD_CHANNELS;
        float l = ring[i0] + (ring[i1] - ring[i0]) * frac;
        float r = ring[i0 + 1] + (ring[i1 + 1] - ring[i0 + 1]) * frac;
        if (mono) {
            left.data[f * left.stride + left.channel] = 0.5f * (l + r);
        } else {
            left.data[f * left.stride + left.channel] = l;
            right.data[f * right.stride + right.channel] = r;
        }
    }
    engine->readPosition = position + frames * engine->ratio;
    atomic_store_explicit(&engine->lagBits, DoubleBits(engine->smoothedLag), memory_order_relaxed);
    atomic_store_explicit(&engine->ratioBits, DoubleBits(engine->ratio), memory_order_relaxed);
}

// MARK: - Rules

void ve_rules_begin(VEEngine *engine) { engine->stagedCount = 0; }

void ve_rules_add(VEEngine *engine, uint32_t pid, const char *bundleID, float gain) {
    if (engine->stagedCount >= VD_MAX_RULES) return;
    uint64_t hash = bundleID && bundleID[0] ? vd_hash(bundleID) : 0;
    if (pid == 0 && hash == 0) return;
    engine->staged[engine->stagedCount++] = (typeof(engine->staged[0])){pid, hash, gain};
}

void ve_rules_commit(VEEngine *engine) {
    VDRule *rules = engine->shared->rules;
    bool keep[VD_MAX_RULES] = {false};
    // 1. Rules that already exist: update the gain in place (never deactivated).
    bool placed[VD_MAX_RULES] = {false};
    for (int s = 0; s < engine->stagedCount; s++) {
        for (int i = 0; i < VD_MAX_RULES; i++) {
            if (keep[i] || !vd_load32(&rules[i].active)) continue;
            if (vd_load32(&rules[i].pid) == engine->staged[s].pid && vd_load64(&rules[i].bundleHash) == engine->staged[s].hash) {
                vd_store32(&rules[i].gainBits, vd_bits(engine->staged[s].gain));
                keep[i] = true;
                placed[s] = true;
                break;
            }
        }
    }
    // 2. New rules go into free slots, fully written before they're activated.
    for (int s = 0; s < engine->stagedCount; s++) {
        if (placed[s]) continue;
        for (int i = 0; i < VD_MAX_RULES; i++) {
            if (keep[i] || vd_load32(&rules[i].active)) continue;
            vd_store32(&rules[i].pid, engine->staged[s].pid);
            vd_store64(&rules[i].bundleHash, engine->staged[s].hash);
            vd_store32(&rules[i].gainBits, vd_bits(engine->staged[s].gain));
            vd_store32(&rules[i].active, 1);
            keep[i] = true;
            break;
        }
    }
    // 3. Only then retire rules that are gone.
    for (int i = 0; i < VD_MAX_RULES; i++) {
        if (!keep[i] && vd_load32(&rules[i].active)) vd_store32(&rules[i].active, 0);
    }
}

// MARK: - State

bool ve_device_visible(VEEngine *engine) { return vd_load32(&engine->shared->deviceVisible) != 0; }
uint32_t ve_device_volume_sequence(VEEngine *engine) { return vd_load32(&engine->shared->volumeSeq); }
float ve_device_volume(VEEngine *engine) { return vd_float(vd_load32(&engine->shared->volumeBits)); }
bool ve_device_mute(VEEngine *engine) { return vd_load32(&engine->shared->mute) != 0; }

void ve_push_volume(VEEngine *engine, float volume, bool mute) {
    VDShared *shared = engine->shared;
    if (volume != engine->pushedVolume) {
        engine->pushedVolume = volume;
        vd_store32(&shared->requestedVolumeBits, vd_bits(volume));
        vd_add32(&shared->requestedVolumeSeq, 1);
    }
    if ((int)mute != engine->pushedMute) {
        engine->pushedMute = mute;
        vd_store32(&shared->requestedMute, mute);
        vd_add32(&shared->requestedMuteSeq, 1);
    }
}

int ve_take_peaks(VEEngine *engine, VEPeak *out, int max) {
    int count = 0;
    for (int i = 0; i < VD_MAX_CLIENTS && count < max; i++) {
        VDClient *client = &engine->shared->clients[i];
        uint32_t pid = vd_load32(&client->pid);
        if (pid == 0) continue;
        float peak = vd_float(vd_exchange32(&client->peakBits, 0));
        if (peak <= 0) continue;
        out[count++] = (VEPeak){pid, vd_load32(&client->ownerPID), peak};
    }
    return count;
}

VEStats ve_stats(VEEngine *engine) {
    return (VEStats){
        atomic_load(&engine->underruns),
        atomic_load(&engine->resyncs),
        BitsDouble(atomic_load(&engine->lagBits)),
        BitsDouble(atomic_load(&engine->ratioBits)),
        atomic_load(&engine->targetFrames),
    };
}

void *ve_shared_for_test(VEEngine *engine) { return engine->shared; }
