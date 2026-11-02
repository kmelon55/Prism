#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

typedef struct PrismAudioDSP PrismAudioDSP;
PrismAudioDSP * _Nullable PrismAudioDSPCreate(float gain);
void PrismAudioDSPDestroy(PrismAudioDSP * _Nullable state);
void PrismAudioDSPSetGain(PrismAudioDSP * _Nonnull state, float gain);
void PrismAudioDSPArm(PrismAudioDSP * _Nonnull state);
bool PrismAudioDSPHasSignal(const PrismAudioDSP * _Nonnull state);
bool PrismAudioDSPHasFault(const PrismAudioDSP * _Nonnull state);
// Float32 stereo/mono only, as validated against the aggregate streams before starting IO.
void PrismAudioDSPRender(PrismAudioDSP * _Nullable state, const AudioBufferList * _Nullable input, AudioBufferList * _Nullable output);
OSStatus PrismAudioDSPCallback(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
