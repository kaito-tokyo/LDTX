// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct LDTXWorkspaceAudioEngine LDTXWorkspaceAudioEngine;
typedef uint64_t LDTXAudioID;
typedef void (*LDTXAudioSampleHandler)(void *, CMSampleBufferRef);
typedef void (*LDTXAudioCompletion)(void *);
typedef void (*LDTXAudioErrorHandler)(void *, const char *, int32_t);
typedef struct {
  LDTXAudioID input;
  float gain;
  bool connected;
} LDTXAudioRoute;
typedef struct {
  uint64_t receivedFrames, droppedFrames, invalidTimestamps, renderErrors, generation;
  uint32_t inputBufferFrames, outputBufferFrames;
} LDTXAudioStatistics;
// All operations except SubmitPCM serialize on the engine worker. Samples are
// borrowed for the duration of the handler; retain before asynchronous use.
LDTXWorkspaceAudioEngine *LDTXAudioCreate(bool hardwareEnabled);
void LDTXAudioDestroy(LDTXWorkspaceAudioEngine *);
void LDTXAudioSetErrorHandler(LDTXWorkspaceAudioEngine *, LDTXAudioErrorHandler, void *);
// kind: 0 physical, 1 sweep sine, 2 silence, 3 externally submitted test PCM.
LDTXAudioID LDTXAudioAddInput(LDTXWorkspaceAudioEngine *, const char *uid, uint32_t kind, double sampleRate,
                              uint32_t channels);
void LDTXAudioRemoveInput(LDTXWorkspaceAudioEngine *, LDTXAudioID);
LDTXAudioID LDTXAudioCreateBus(LDTXWorkspaceAudioEngine *);
void LDTXAudioConfigureBus(LDTXWorkspaceAudioEngine *, LDTXAudioID, const LDTXAudioRoute *, uint32_t count,
                           float masterGain);
void LDTXAudioRemoveBus(LDTXWorkspaceAudioEngine *, LDTXAudioID);
void LDTXAudioConfigureMonitor(LDTXWorkspaceAudioEngine *, const char *outputUID, const LDTXAudioRoute *,
                               uint32_t count, float masterGain);
// A bus renders in host-clock time. Session PTS mapping is a subscription concern.
LDTXAudioID LDTXAudioSubscribe(LDTXWorkspaceAudioEngine *, LDTXAudioID source, bool raw, LDTXAudioSampleHandler,
                               void *);
// Output subscriptions wait for a video boundary, then deliver whole 1024-frame
// shared-mix blocks at/after it. Source changes preserve the delivered time fence.
LDTXAudioID LDTXAudioSubscribeAtVideoBoundary(LDTXWorkspaceAudioEngine *, LDTXAudioID source, LDTXAudioSampleHandler,
                                              void *);
void LDTXAudioSetVideoBoundary(LDTXWorkspaceAudioEngine *, LDTXAudioID subscription, CMTime);
void LDTXAudioSwitchSubscriptionSource(LDTXWorkspaceAudioEngine *, LDTXAudioID subscription, LDTXAudioID source);
void LDTXAudioUnsubscribe(LDTXWorkspaceAudioEngine *, LDTXAudioID);
float LDTXAudioConsumePeak(LDTXWorkspaceAudioEngine *, LDTXAudioID source, bool raw);
LDTXAudioStatistics LDTXAudioGetStatistics(LDTXWorkspaceAudioEngine *, LDTXAudioID input);
void LDTXAudioStop(LDTXWorkspaceAudioEngine *, LDTXAudioCompletion, void *);
// Deterministic test seam. SubmitPCM has one producer per input and never waits.
bool LDTXAudioSubmitPCM(LDTXWorkspaceAudioEngine *, LDTXAudioID, const AudioBufferList *, const AudioTimeStamp *);
void LDTXAudioAdvance(LDTXWorkspaceAudioEngine *, uint64_t nowNanoseconds);
#ifdef __cplusplus
}
#endif
