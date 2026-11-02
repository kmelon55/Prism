#include "PrismAudioDSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct PrismAudioDSP {
    _Atomic(float) gain;
    atomic_bool armed;
    atomic_bool signal;
    atomic_bool fault;
    float currentGain; // audio thread only
};

static float bounded(float value) { return isfinite(value) ? fmaxf(0, fminf(1, value)) : 0; }
PrismAudioDSP *PrismAudioDSPCreate(float gain) {
    PrismAudioDSP *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    atomic_init(&state->gain, bounded(gain));
    atomic_init(&state->armed, false);
    atomic_init(&state->signal, false);
    atomic_init(&state->fault, false);
    if (!atomic_is_lock_free(&state->gain)) { free(state); return NULL; }
    return state;
}
void PrismAudioDSPDestroy(PrismAudioDSP *state) { free(state); }
void PrismAudioDSPSetGain(PrismAudioDSP *state, float gain) { atomic_store_explicit(&state->gain, bounded(gain), memory_order_relaxed); }
void PrismAudioDSPArm(PrismAudioDSP *state) { atomic_store_explicit(&state->armed, true, memory_order_release); }
bool PrismAudioDSPHasSignal(const PrismAudioDSP *state) { return atomic_load_explicit(&state->signal, memory_order_relaxed); }
bool PrismAudioDSPHasFault(const PrismAudioDSP *state) { return atomic_load_explicit(&state->fault, memory_order_relaxed); }

static bool layout(const AudioBufferList *list, unsigned *channels, unsigned *frames) {
    *channels = 0; *frames = UINT32_MAX;
    if (!list || list->mNumberBuffers == 0 || list->mNumberBuffers > 2) return false;
    for (unsigned b = 0; b < list->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        if (!buffer->mData || buffer->mNumberChannels == 0 || buffer->mNumberChannels > 2 ||
            buffer->mDataByteSize % (sizeof(float) * buffer->mNumberChannels) != 0) return false;
        *channels += buffer->mNumberChannels;
        unsigned n = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
        if (n < *frames) *frames = n;
    }
    return *channels == 1 || *channels == 2;
}
static float sample(const AudioBufferList *list, unsigned channel, unsigned frame) {
    for (unsigned b = 0; b < list->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        if (channel < buffer->mNumberChannels) return ((const float *)buffer->mData)[frame * buffer->mNumberChannels + channel];
        channel -= buffer->mNumberChannels;
    }
    return 0;
}
static void put(AudioBufferList *list, unsigned channel, unsigned frame, float value) {
    for (unsigned b = 0; b < list->mNumberBuffers; ++b) {
        AudioBuffer *buffer = &list->mBuffers[b];
        if (channel < buffer->mNumberChannels) { ((float *)buffer->mData)[frame * buffer->mNumberChannels + channel] = value; return; }
        channel -= buffer->mNumberChannels;
    }
}
void PrismAudioDSPRender(PrismAudioDSP *state, const AudioBufferList *input, AudioBufferList *output) {
    // No allocation, locks, ARC, logging, dispatch or Objective-C on the real-time thread.
    if (!state || !output) return;
    for (unsigned b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    if (!input || input->mNumberBuffers == 0) return;
    unsigned inChannels, outChannels, inFrames, outFrames;
    if (!layout(input, &inChannels, &inFrames) || !layout(output, &outChannels, &outFrames)) {
        atomic_store_explicit(&state->fault, true, memory_order_relaxed); return;
    }
    unsigned frames = inFrames < outFrames ? inFrames : outFrames;
    float target = atomic_load_explicit(&state->gain, memory_order_relaxed);
    bool armed = atomic_load_explicit(&state->armed, memory_order_acquire);
    bool sawSignal = false;
    for (unsigned f = 0; f < frames; ++f) {
        float left = sample(input, 0, f), right = inChannels == 2 ? sample(input, 1, f) : left;
        if (!isfinite(left) || !isfinite(right)) { left = right = 0; }
        if (fabsf(left) > 0.000001f || fabsf(right) > 0.000001f) sawSignal = true;
        if (!armed) continue; // Keep normal app playback until permission and nonzero capture are proven.
        float difference = target - state->currentGain;
        state->currentGain += fmaxf(-1.0f / 256, fminf(1.0f / 256, difference));
        if (outChannels == 1) put(output, 0, f, (left + right) * 0.5f * state->currentGain);
        else { put(output, 0, f, left * state->currentGain); put(output, 1, f, right * state->currentGain); }
    }
    if (sawSignal) atomic_store_explicit(&state->signal, true, memory_order_relaxed);
}
OSStatus PrismAudioDSPCallback(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    PrismAudioDSPRender(context, input, output);
    return noErr;
}
