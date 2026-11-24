// Plays a sine tone to the device with the given UID, so the spike has a client with a known level.
//
//   spike-tone <deviceUID> <seconds> [amplitude=0.5] [frequency=440]

#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static double gPhase = 0, gStep = 0;
static float gAmplitude = 0.5f;

static OSStatus Render(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
                       AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime; (void)outputTime; (void)context;
    if (output->mNumberBuffers == 0) return 0;
    UInt32 channels = output->mBuffers[0].mNumberChannels;
    UInt32 frames = output->mBuffers[0].mDataByteSize / (sizeof(float) * (channels ? channels : 1));
    for (UInt32 f = 0; f < frames; f++) {
        float value = gAmplitude * (float)sin(gPhase);
        gPhase += gStep;
        if (gPhase > 2 * M_PI) gPhase -= 2 * M_PI;
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            float *data = output->mBuffers[b].mData;
            UInt32 ch = output->mBuffers[b].mNumberChannels;
            for (UInt32 c = 0; c < ch; c++) data[f * ch + c] = value;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <deviceUID> <seconds> [amplitude] [frequency]\n", argv[0]); return 2; }
    int seconds = atoi(argv[2]);
    if (argc > 3) gAmplitude = (float)atof(argv[3]);
    double frequency = argc > 4 ? atof(argv[4]) : 440;

    CFStringRef uid = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    AudioObjectID device = kAudioObjectUnknown;
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &size, &device);
    CFRelease(uid);
    if (device == kAudioObjectUnknown) { fprintf(stderr, "device %s not found\n", argv[1]); return 1; }

    Float64 rate = 48000;
    a.mSelector = kAudioDevicePropertyNominalSampleRate;
    size = sizeof(rate);
    AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &rate);
    gStep = 2 * M_PI * frequency / rate;

    AudioDeviceIOProcID proc = NULL;
    OSStatus status = AudioDeviceCreateIOProcID(device, Render, NULL, &proc);
    if (status == noErr) status = AudioDeviceStart(device, proc);
    if (status != noErr) { fprintf(stderr, "could not start: %d\n", (int)status); return 1; }
    printf("tone pid %d: %.0f Hz at amplitude %.2f for %d s\n", getpid(), frequency, gAmplitude, seconds);
    fflush(stdout);
    sleep((unsigned)seconds);
    AudioDeviceStop(device, proc);
    AudioDeviceDestroyIOProcID(device, proc);
    return 0;
}
