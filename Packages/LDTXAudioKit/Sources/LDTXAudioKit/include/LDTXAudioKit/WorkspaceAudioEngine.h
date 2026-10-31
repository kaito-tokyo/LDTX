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

typedef struct LDTXWorkspaceAudioEngine LDTXAudioKitReceiver;
typedef uint64_t LDTXAudioKitID;
typedef void (*LDTXAudioKitSampleHandler)(void *, CMSampleBufferRef);
typedef void (*LDTXAudioKitCompletion)(void *);
typedef void (*LDTXAudioKitErrorHandler)(void *, const char *, int32_t);

typedef struct {
  LDTXAudioKitID input;
  float gain;
  bool connected;
} LDTXAudioKitRoute;

typedef struct {
  uint64_t receivedFrames;
  uint64_t droppedFrames;
  uint64_t invalidTimestamps;
  uint64_t renderErrors;
  uint64_t generation;
  uint32_t inputBufferFrames;
  uint32_t outputBufferFrames;
} LDTXAudioKitStatistics;

LDTXAudioKitReceiver *LDTXAudioKitCreate(bool hardwareEnabled);
void LDTXAudioKitDestroy(LDTXAudioKitReceiver *);
void LDTXAudioKitSetErrorHandler(LDTXAudioKitReceiver *, LDTXAudioKitErrorHandler, void *);
LDTXAudioKitID LDTXAudioKitAddInput(LDTXAudioKitReceiver *, const char *, uint32_t, double, uint32_t);
bool LDTXAudioKitHasActiveInput(LDTXAudioKitReceiver *, const char *);
void LDTXAudioKitRemoveInput(LDTXAudioKitReceiver *, LDTXAudioKitID);
LDTXAudioKitID LDTXAudioKitCreateBus(LDTXAudioKitReceiver *);
void LDTXAudioKitConfigureBus(LDTXAudioKitReceiver *, LDTXAudioKitID, const LDTXAudioKitRoute *, uint32_t, float);
void LDTXAudioKitRemoveBus(LDTXAudioKitReceiver *, LDTXAudioKitID);
void LDTXAudioKitUpdateMonitorValues(LDTXAudioKitReceiver *, const LDTXAudioKitRoute *, uint32_t, float);
void LDTXAudioKitConfigureMonitor(LDTXAudioKitReceiver *, const char *, const LDTXAudioKitRoute *, uint32_t, float);
LDTXAudioKitID LDTXAudioKitSubscribe(LDTXAudioKitReceiver *, LDTXAudioKitID, bool, LDTXAudioKitSampleHandler, void *);
void LDTXAudioKitUnsubscribe(LDTXAudioKitReceiver *, LDTXAudioKitID);
float LDTXAudioKitConsumePeak(LDTXAudioKitReceiver *, LDTXAudioKitID, bool);
LDTXAudioKitStatistics LDTXAudioKitGetStatistics(LDTXAudioKitReceiver *, LDTXAudioKitID);
void LDTXAudioKitStop(LDTXAudioKitReceiver *, LDTXAudioKitCompletion, void *);
bool LDTXAudioKitSubmitPCM(LDTXAudioKitReceiver *, LDTXAudioKitID, const AudioBufferList *, const AudioTimeStamp *);
void LDTXAudioKitAdvance(LDTXAudioKitReceiver *, uint64_t);

#ifdef __cplusplus
}
#endif
