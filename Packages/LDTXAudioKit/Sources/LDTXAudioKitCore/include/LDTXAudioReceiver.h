// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LDTXAudioReceiver LDTXAudioReceiver;

typedef struct {
  uint64_t generation;
  uint32_t slot;
  uint32_t frames;
  uint32_t channels;
  double sampleRate;
  AudioTimeStamp timestamp;
} LDTXAudioReceiverBlock;

typedef void (*LDTXAudioReceiverSubscriber)(void *, LDTXAudioReceiver *, const LDTXAudioReceiverBlock *);

// The subscriber callback runs on the AUHAL realtime context. It must return
// within the audio deadline and must not allocate, block, perform I/O, launch
// work, or call back into the receiver. Contract violations are undefined.
LDTXAudioReceiver *LDTXAudioReceiverCreate(const char *inputUID);
void LDTXAudioReceiverDestroy(LDTXAudioReceiver *);
bool LDTXAudioReceiverAddSubscriber(LDTXAudioReceiver *, LDTXAudioReceiverSubscriber, void *);
bool LDTXAudioReceiverStart(LDTXAudioReceiver *);
void LDTXAudioReceiverStop(LDTXAudioReceiver *);

// The returned list is valid only while the block's read obligation is held.
// A subscriber must call Release exactly once after reading the block.
const AudioBufferList *LDTXAudioReceiverGetBuffer(LDTXAudioReceiver *, const LDTXAudioReceiverBlock *);
void LDTXAudioReceiverReleaseBlock(LDTXAudioReceiver *, const LDTXAudioReceiverBlock *);

uint64_t LDTXAudioReceiverReceivedFrames(const LDTXAudioReceiver *);
uint64_t LDTXAudioReceiverDroppedFrames(const LDTXAudioReceiver *);

#ifdef __cplusplus
}
#endif
