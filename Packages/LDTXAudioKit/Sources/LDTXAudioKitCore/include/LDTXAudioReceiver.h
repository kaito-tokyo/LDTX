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

struct LDTXAudioReceiver;

struct LDTXAudioReceiverBlock {
  uint64_t generation;
  uint32_t slot;
  uint32_t frames;
  uint32_t channels;
  double sampleRate;
  AudioTimeStamp timestamp;
} LDTXAudioReceiverBlock;

typedef void (*LDTXAudioReceiverSubscriber)(void *, struct LDTXAudioReceiver *, const struct LDTXAudioReceiverBlock *);

// The subscriber callback runs on the AUHAL realtime context. It must return
// within the audio deadline and must not allocate, block, perform I/O, launch
// work, or call back into the receiver. Contract violations are undefined.
struct LDTXAudioReceiver *LDTXAudioReceiverCreate(const char *inputUID);
void LDTXAudioReceiverDestroy(struct LDTXAudioReceiver *p);

bool LDTXAudioReceiverAddSubscriber(struct LDTXAudioReceiver *, LDTXAudioReceiverSubscriber, void *);

bool LDTXAudioReceiverStart(struct LDTXAudioReceiver *);
void LDTXAudioReceiverStop(struct LDTXAudioReceiver *);

// The returned list is valid only while the block's read obligation is held.
// A subscriber must call Release exactly once after reading the block.
const AudioBufferList *LDTXAudioReceiverGetBuffer(struct LDTXAudioReceiver *, const struct LDTXAudioReceiverBlock *);
void LDTXAudioReceiverReleaseBlock(struct LDTXAudioReceiver *, const struct LDTXAudioReceiverBlock *);

uint64_t LDTXAudioReceiverReceivedFrames(const struct LDTXAudioReceiver *);
uint64_t LDTXAudioReceiverDroppedFrames(const struct LDTXAudioReceiver *);

#ifdef __cplusplus
}
#endif
