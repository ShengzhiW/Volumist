// Offline tests for the app's engine (Volumist/Engine/VolumistEngine.c): drift correction,
// continuity, idle/restart, channel layouts, rule updates and peaks. The test plays the
// driver's part by writing into the engine's shared memory at a chosen clock rate.

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../../Volumist/Engine/VolumistEngine.h"
#include "../VolumistDriverProtocol.h"

static int gFailures, gChecks;
#define CHECK(cond, ...)                                                                \
    do {                                                                                \
        gChecks++;                                                                      \
        if (cond) { printf("  ok    "); } else { printf("  FAIL  "); gFailures++; }    \
        printf(__VA_ARGS__);                                                            \
        printf("\n");                                                                   \
    } while (0)

typedef struct {
    VEEngine *engine;
    VDShared *shared;
    uint64_t writeTime;      // driver sample time
    double phase;            // sine phase for the test signal
} Sim;

static void WriteBurst(Sim *sim, int frames) {
    for (int f = 0; f < frames; f++) {
        float value = 0.5f * (float)sin(sim->phase);
        sim->phase += 2 * M_PI * 1000.0 / 48000.0;
        uint64_t index = ((sim->writeTime + f) & (VD_RING_FRAMES - 1)) * VD_CHANNELS;
        sim->shared->ring[index] = value;
        sim->shared->ring[index + 1] = -value;
    }
    sim->writeTime += frames;
    vd_store64(&sim->shared->writeFrame, sim->writeTime);
}

typedef struct {
    uint64_t underruns, resyncs;
    double averageRatio, lagMin, lagMax, maxStep, target;
    int silentCallbacks;
} Result;

/// Runs `seconds` of simulated time: the driver writes `writeFrames` bursts at 48 kHz × (1 + drift),
/// the output reads `readFrames` buffers at 48 kHz. Measures after the first `settle` seconds.
static Result Run(Sim *sim, double drift, int writeFrames, int readFrames, double seconds, double settle) {
    static float out[4096 * 2];
    AudioBufferList list = {1, {{2, (UInt32)(readFrames * 2 * sizeof(float)), out}}};
    double writerPeriod = writeFrames / (48000.0 * (1 + drift)), readerPeriod = readFrames / 48000.0;
    double tw = 0, tr = readerPeriod / 2;
    VEStats start = ve_stats(sim->engine);
    Result result = {0, 0, 0, 1e9, -1e9, 0, 0, 0};
    double ratioSum = 0, lagStart = 0, lagEnd = 0;
    long ratioCount = 0;
    float previous = NAN;
    bool settled = false;
    while (tr < seconds) {
        if (tw <= tr) {
            WriteBurst(sim, writeFrames);
            tw += writerPeriod;
            continue;
        }
        ve_render(sim->engine, &list, 48000);
        tr += readerPeriod;
        if (!settled && tr >= settle) {
            settled = true;
            start = ve_stats(sim->engine);
            lagStart = start.lagFrames;
            previous = NAN;
        }
        if (!settled) continue;
        VEStats stats = ve_stats(sim->engine);
        ratioSum += stats.ratio;
        ratioCount++;
        lagEnd = stats.lagFrames;
        result.target = stats.targetFrames;
        if (stats.lagFrames < result.lagMin) result.lagMin = stats.lagFrames;
        if (stats.lagFrames > result.lagMax) result.lagMax = stats.lagFrames;
        bool silent = true;
        for (int f = 0; f < readFrames; f++) {
            float value = out[f * 2];
            if (value != 0) silent = false;
            if (!isnan(previous)) result.maxStep = fmax(result.maxStep, fabsf(value - previous));
            previous = value;
        }
        result.silentCallbacks += silent;
    }
    VEStats end = ve_stats(sim->engine);
    result.underruns = end.underruns - start.underruns;
    result.resyncs = end.resyncs - start.resyncs;
    // Frames consumed = frames produced − growth of the buffer, so add the buffer's growth back
    // in: what's left is the clock ratio the steering matched.
    result.averageRatio = ratioCount ? ratioSum / ratioCount + (lagEnd - lagStart) / ((double)ratioCount * readFrames) : 1;
    return result;
}

static Sim NewSim(void) {
    Sim sim = {0};
    sim.engine = ve_create("/tmp/volumist.enginetest.sock", (int)getuid());
    if (!sim.engine) { fprintf(stderr, "ve_create failed\n"); exit(1); }
    sim.shared = ve_shared_for_test(sim.engine);
    return sim;
}

int main(void) {
    // A 1 kHz sine at 0.5 changes by at most 0.5·2π·1000/48000 ≈ 0.065 per sample; a click or gap
    // would jump much further.
    const double kMaxSmoothStep = 0.075;

    printf("Drift correction (10 simulated minutes each)\n");
    double drifts[] = {0, 40e-6, -40e-6, 500e-6, -2000e-6};
    for (size_t i = 0; i < sizeof(drifts) / sizeof(drifts[0]); i++) {
        Sim sim = NewSim();
        Result r = Run(&sim, drifts[i], 512, 512, 600, 30);
        double ppm = drifts[i] * 1e6;
        CHECK(r.underruns == 0 && r.resyncs == 0, "%+6.0f ppm: no dropouts or resyncs after settling", ppm);
        CHECK(fabs((r.averageRatio - 1) - drifts[i]) < 10e-6, "%+6.0f ppm: steering tracks the drift on average (ratio %.6f)", ppm, r.averageRatio);
        CHECK(r.lagMin > r.target - 600 && r.lagMax < r.target + 600, "%+6.0f ppm: buffer stays near its %.0f-frame target (%.0f–%.0f)", ppm, r.target, r.lagMin, r.lagMax);
        CHECK(r.maxStep < kMaxSmoothStep, "%+6.0f ppm: output stays smooth (largest step %.4f)", ppm, r.maxStep);
        CHECK(r.silentCallbacks == 0, "%+6.0f ppm: never silent while playing", ppm);
        ve_destroy(sim.engine);
    }

    printf("Buffer sizes\n");
    {
        Sim sim = NewSim();
        Result r = Run(&sim, 40e-6, 512, 1024, 120, 10);
        CHECK(r.underruns == 0 && r.resyncs == 0 && r.maxStep < kMaxSmoothStep, "1024-frame output buffers: no dropouts, smooth");
        ve_destroy(sim.engine);
        sim = NewSim();
        r = Run(&sim, -40e-6, 1024, 128, 120, 10);
        CHECK(r.underruns == 0 && r.resyncs == 0 && r.maxStep < kMaxSmoothStep, "128-frame output, 1024-frame driver bursts: no dropouts, smooth");
        ve_destroy(sim.engine);
    }

    printf("Pause and restart\n");
    {
        Sim sim = NewSim();
        Run(&sim, 0, 512, 512, 20, 5);
        VEStats before = ve_stats(sim.engine);
        // Driver IO stops (nothing playing): the output keeps calling with no new audio.
        static float out[512 * 2];
        AudioBufferList list = {1, {{2, sizeof(out), out}}};
        for (int i = 0; i < 200; i++) ve_render(sim.engine, &list, 48000);
        VEStats idle = ve_stats(sim.engine);
        CHECK(idle.underruns - before.underruns <= 1, "stopping playback isn't counted as dropouts (%llu)", idle.underruns - before.underruns);
        // Driver restarts IO: its sample time starts again from zero.
        sim.writeTime = 0;
        Result r = Run(&sim, 0, 512, 512, 60, 5);
        CHECK(r.underruns == 0 && r.resyncs == 0 && r.silentCallbacks == 0, "playback resumes cleanly after the driver's clock restarts");
        ve_destroy(sim.engine);
    }

    printf("Channel layouts\n");
    {
        Sim sim = NewSim();
        Run(&sim, 0, 512, 512, 5, 1);
        float left[512], right[512];
        AudioBufferList *split = malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer));
        split->mNumberBuffers = 2;
        split->mBuffers[0] = (AudioBuffer){1, sizeof(left), left};
        split->mBuffers[1] = (AudioBuffer){1, sizeof(right), right};
        WriteBurst(&sim, 512);
        WriteBurst(&sim, 512);
        ve_render(sim.engine, split, 48000);
        bool opposite = true;
        for (int f = 0; f < 512; f++) opposite &= fabsf(left[f] + right[f]) < 1e-6f;
        CHECK(opposite && fabsf(left[100]) > 0, "two mono buffers get left and right respectively");
        free(split);
        float mono[512];
        AudioBufferList single = {1, {{1, sizeof(mono), mono}}};
        WriteBurst(&sim, 512);
        ve_render(sim.engine, &single, 48000);
        bool summed = true;
        for (int f = 0; f < 512; f++) summed &= fabsf(mono[f]) < 1e-6f;  // L + R = 0 for this signal
        CHECK(summed, "a mono output gets the average of left and right");
        ve_destroy(sim.engine);
    }

    printf("Rules\n");
    {
        Sim sim = NewSim();
        VDRule *rules = sim.shared->rules;
        ve_rules_begin(sim.engine);
        ve_rules_add(sim.engine, 10, NULL, 0.5f);
        ve_rules_add(sim.engine, 0, "com.example.app", 0.3f);
        ve_rules_add(sim.engine, 0, NULL, 0.9f);  // matches nothing: ignored
        ve_rules_commit(sim.engine);
        int active = 0, pidSlot = -1;
        for (int i = 0; i < VD_MAX_RULES; i++) {
            if (vd_load32(&rules[i].active)) { active++; if (rules[i].pid == 10) pidSlot = i; }
        }
        CHECK(active == 2 && pidSlot >= 0, "commit publishes the two valid rules");
        ve_rules_begin(sim.engine);
        ve_rules_add(sim.engine, 10, NULL, 0.7f);
        ve_rules_add(sim.engine, 11, NULL, 0.2f);
        ve_rules_commit(sim.engine);
        CHECK(vd_load32(&rules[pidSlot].active) && rules[pidSlot].pid == 10 && fabsf(vd_float(rules[pidSlot].gainBits) - 0.7f) < 1e-6f,
              "a rule that stays is updated in place (same slot, still active, new gain)");
        int bundleActive = 0, pid11 = 0;
        for (int i = 0; i < VD_MAX_RULES; i++) {
            if (!vd_load32(&rules[i].active)) continue;
            if (rules[i].bundleHash == vd_hash("com.example.app")) bundleActive++;
            if (rules[i].pid == 11) pid11++;
        }
        CHECK(bundleActive == 0 && pid11 == 1, "removed rules retire and new ones appear");

        uint32_t volumeSeq = vd_load32(&sim.shared->requestedVolumeSeq);
        ve_push_volume(sim.engine, 0.4f, false);
        ve_push_volume(sim.engine, 0.4f, false);
        CHECK(vd_load32(&sim.shared->requestedVolumeSeq) == volumeSeq + 1, "pushing the same volume twice only signals once");

        VDClient *client = &sim.shared->clients[5];
        client->ownerPID = 77;
        vd_store32(&client->peakBits, vd_bits(0.25f));
        vd_store32(&client->pid, 42);
        VEPeak peaks[8];
        int n = ve_take_peaks(sim.engine, peaks, 8);
        CHECK(n == 1 && peaks[0].pid == 42 && peaks[0].ownerPID == 77 && fabsf(peaks[0].peak - 0.25f) < 1e-6f, "peaks are read with their process and owner");
        CHECK(ve_take_peaks(sim.engine, peaks, 8) == 0, "reading a peak resets it");
        ve_destroy(sim.engine);
    }

    printf("\n%d checks, %d failed\n", gChecks, gFailures);
    return gFailures ? 1 : 0;
}
