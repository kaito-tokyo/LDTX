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
void LDTXAudioReceiverDestroy(struct LDTXAudioReceiver *__nonnull p);

bool LDTXAudioReceiverAddAvailabilityCallback(struct LDTXAudioReceiver *__nonnull p,
                                               LDTXAudioReceiverAvailabilityCallback __nonnull callback,
                                               void *__nonnull priv);

bool LDTXAudioReceiverStart(struct LDTXAudioReceiver *__nonnull);
void LDTXAudioReceiverStop(struct LDTXAudioReceiver *__nonnull);

uint64_t LDTXAudioReceiverReceivedFrames(const struct LDTXAudioReceiver *);
uint64_t LDTXAudioReceiverDroppedFrames(const struct LDTXAudioReceiver *);

#ifdef __cplusplus
}
#endif
