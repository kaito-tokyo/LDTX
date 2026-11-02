// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

const static long kLDTXAudioReceiverStopped = 0;
const static long kLDTXAudioReceiverRunning = 1;
const static long kLDTXAudioReceiverStopping = 2;

struct LDTXAudioReceiver;

typedef void (*LDTXAudioReceiverAvailabilityCallback)(void *__nonnull priv, uint32_t slot, uint64_t token);

struct LDTXAudioReceiver *__nullable LDTXAudioReceiverCreate(AudioDeviceID deviceID);
void LDTXAudioReceiverDestroy(struct LDTXAudioReceiver *__nonnull ctx);

bool LDTXAudioReceiverAddAvailabilityCallback(struct LDTXAudioReceiver *__nonnull ctx,
                                               LDTXAudioReceiverAvailabilityCallback __nonnull callback,
                                               void *__nonnull priv);

// Borrows the PCM buffer for an availability callback. The caller must use the
// matching slot and token, must not access the buffer after release, and must
// release exactly once.
const AudioBufferList *__nullable LDTXAudioReceiverBorrowBuffer(struct LDTXAudioReceiver *__nonnull ctx,
                                                                 uint32_t slot, uint64_t token,
                                                                 AudioTimeStamp *__nonnull timestamp);
void LDTXAudioReceiverReleaseBuffer(struct LDTXAudioReceiver *__nonnull ctx, uint32_t slot, uint64_t token);

bool LDTXAudioReceiverGetFormat(struct LDTXAudioReceiver *__nonnull ctx,
                                AudioStreamBasicDescription *__nonnull format);

bool LDTXAudioReceiverStart(struct LDTXAudioReceiver *__nonnull ctx);
void LDTXAudioReceiverStop(struct LDTXAudioReceiver *__nonnull ctx);

uint64_t LDTXAudioReceiverReceivedFrames(const struct LDTXAudioReceiver *__nonnull ctx);
uint64_t LDTXAudioReceiverDroppedFrames(const struct LDTXAudioReceiver *__nonnull ctx);

#ifdef __cplusplus
}
#endif
