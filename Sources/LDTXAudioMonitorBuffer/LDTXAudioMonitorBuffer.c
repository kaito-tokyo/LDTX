// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#include "LDTXAudioMonitorBuffer.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct LDTXMonitorBuffer {
  uint32_t capacity, planeCount;
  uint32_t *strides;
  unsigned char **planes;
  _Atomic uint64_t written, read, dropped, missing;
};

LDTXMonitorBuffer *LDTXMonitorBufferCreate(uint32_t capacity, uint32_t planeCount,
                                        const uint32_t *bytesPerFrame) {
  if (!capacity || !planeCount || !bytesPerFrame) return NULL;
  LDTXMonitorBuffer *b = calloc(1, sizeof(*b));
  if (!b) return NULL;
  b->capacity = capacity;
  b->planeCount = planeCount;
  atomic_init(&b->written, 0);
  atomic_init(&b->read, 0);
  atomic_init(&b->dropped, 0);
  atomic_init(&b->missing, 0);
  b->strides = calloc(planeCount, sizeof(*b->strides));
  b->planes = calloc(planeCount, sizeof(*b->planes));
  if (!b->strides || !b->planes) goto fail;
  for (uint32_t p = 0; p < planeCount; ++p) {
    if (!bytesPerFrame[p]) goto fail;
    b->strides[p] = bytesPerFrame[p];
    b->planes[p] = calloc(capacity, bytesPerFrame[p]);
    if (!b->planes[p]) goto fail;
  }
  return b;
fail:
  LDTXMonitorBufferDestroy(b);
  return NULL;
}

void LDTXMonitorBufferDestroy(LDTXMonitorBuffer *b) {
  if (!b) return;
  if (b->planes) for (uint32_t p = 0; p < b->planeCount; ++p) free(b->planes[p]);
  free(b->planes);
  free(b->strides);
  free(b);
}

bool LDTXMonitorBufferWrite(LDTXMonitorBuffer *b, const AudioBufferList *input) {
  if (input->mNumberBuffers != b->planeCount) return false;
  uint32_t frames = input->mBuffers[0].mDataByteSize / b->strides[0];
  for (uint32_t p = 0; p < b->planeCount; ++p) {
    if (!input->mBuffers[p].mData || input->mBuffers[p].mDataByteSize != (uint64_t)frames * b->strides[p]) return false;
  }
  uint64_t w = atomic_load_explicit(&b->written, memory_order_relaxed);
  uint64_t r = atomic_load_explicit(&b->read, memory_order_acquire);
  if (frames > b->capacity - (w - r)) {
    atomic_fetch_add_explicit(&b->dropped, frames, memory_order_relaxed);
    return false;
  }
  uint32_t offset = w % b->capacity;
  uint32_t first = frames < b->capacity - offset ? frames : b->capacity - offset;
  for (uint32_t p = 0; p < b->planeCount; ++p) {
    size_t stride = b->strides[p];
    const unsigned char *src = input->mBuffers[p].mData;
    memcpy(b->planes[p] + offset * stride, src, first * stride);
    memcpy(b->planes[p], src + first * stride, (frames - first) * stride);
  }
  atomic_store_explicit(&b->written, w + frames, memory_order_release);
  return true;
}

uint32_t LDTXMonitorBufferRead(LDTXMonitorBuffer *b, AudioBufferList *output,
                             uint32_t frames, uint32_t backlogLimit, uint32_t target) {
  // A format change must rebuild the graph; never copy into a mismatched buffer.
  for (uint32_t p = 0; p < output->mNumberBuffers; ++p) {
    if (output->mBuffers[p].mData) memset(output->mBuffers[p].mData, 0, output->mBuffers[p].mDataByteSize);
  }
  if (output->mNumberBuffers != b->planeCount) return 0;
  for (uint32_t p = 0; p < b->planeCount; ++p) {
    if (!output->mBuffers[p].mData || output->mBuffers[p].mDataByteSize < (uint64_t)frames * b->strides[p]) return 0;
  }
  uint64_t r = atomic_load_explicit(&b->read, memory_order_relaxed);
  uint64_t w = atomic_load_explicit(&b->written, memory_order_acquire);
  if (w - r > backlogLimit) {
    uint64_t keep = (uint64_t)frames + target;
    if (w - r > keep) {
      atomic_fetch_add_explicit(&b->dropped, w - r - keep, memory_order_relaxed);
      r = w - keep;
    }
  }
  uint32_t count = w - r < frames ? (uint32_t)(w - r) : frames;
  uint32_t offset = r % b->capacity;
  uint32_t first = count < b->capacity - offset ? count : b->capacity - offset;
  for (uint32_t p = 0; p < b->planeCount; ++p) {
    size_t stride = b->strides[p];
    unsigned char *dst = output->mBuffers[p].mData;
    memcpy(dst, b->planes[p] + offset * stride, first * stride);
    memcpy(dst + first * stride, b->planes[p], (count - first) * stride);
  }
  atomic_store_explicit(&b->read, r + count, memory_order_release);
  atomic_fetch_add_explicit(&b->missing, frames - count, memory_order_relaxed);
  return count;
}

uint32_t LDTXMonitorBufferAvailable(const LDTXMonitorBuffer *b) {
  uint64_t r = atomic_load_explicit(&b->read, memory_order_acquire);
  uint64_t w = atomic_load_explicit(&b->written, memory_order_acquire);
  uint64_t count = w - r;
  return (uint32_t)(count < b->capacity ? count : b->capacity);
}

uint64_t LDTXMonitorBufferDropped(const LDTXMonitorBuffer *b) {
  return atomic_load_explicit(&b->dropped, memory_order_relaxed);
}

uint64_t LDTXMonitorBufferReceived(const LDTXMonitorBuffer *b) {
  return atomic_load_explicit(&b->written, memory_order_relaxed);
}

uint64_t LDTXMonitorBufferMissing(const LDTXMonitorBuffer *b) {
  return atomic_load_explicit(&b->missing, memory_order_relaxed);
}

struct LDTXMonitorAUContext {
  LDTXMonitorBuffer *ring;
  AudioUnit input;
  AudioBufferList *capture;
  float **source;
  uint32_t channels, maximumFrames, target;
  _Atomic uint64_t errors;
};

LDTXMonitorAUContext *LDTXMonitorAUContextCreate(LDTXMonitorBuffer *ring,
    AudioUnit input, uint32_t channels, uint32_t maximumFrames, uint32_t target) {
  if (!ring || !channels || !maximumFrames) return NULL;
  LDTXMonitorAUContext *c = calloc(1, sizeof(*c));
  if (!c) return NULL;
  c->ring = ring; c->input = input; c->channels = channels;
  c->maximumFrames = maximumFrames; c->target = target;
  atomic_init(&c->errors, 0);
  c->capture = calloc(1, offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer));
  if (!c->capture) goto fail;
  c->capture->mNumberBuffers = channels;
  for (uint32_t p = 0; p < channels; ++p) {
    c->capture->mBuffers[p].mNumberChannels = 1;
    c->capture->mBuffers[p].mData = calloc(maximumFrames, sizeof(float));
    if (!c->capture->mBuffers[p].mData) goto fail;
  }
  c->source = calloc(channels, sizeof(float *));
  if (!c->source) goto fail;
  for (uint32_t p = 0; p < channels; ++p) {
    c->source[p] = calloc(maximumFrames, sizeof(float));
    if (!c->source[p]) goto fail;
  }
  return c;
fail:
  LDTXMonitorAUContextDestroy(c);
  return NULL;
}

void LDTXMonitorAUContextDestroy(LDTXMonitorAUContext *c) {
  if (!c) return;
  if (c->capture) {
    for (uint32_t p = 0; p < c->channels; ++p) free(c->capture->mBuffers[p].mData);
    free(c->capture);
  }
  if (c->source) {
    for (uint32_t p = 0; p < c->channels; ++p) free(c->source[p]);
    free(c->source);
  }
  free(c);
}

static OSStatus captureAU(void *context, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *unused) {
  LDTXMonitorAUContext *c = context;
  if (frames > c->maximumFrames) {
    atomic_fetch_add_explicit(&c->errors, 1, memory_order_relaxed);
    return kAudioUnitErr_TooManyFramesToProcess;
  }
  for (uint32_t p = 0; p < c->channels; ++p)
    c->capture->mBuffers[p].mDataByteSize = frames * sizeof(float);
  OSStatus status = AudioUnitRender(c->input, flags, time, 1, frames, c->capture);
  if (status == noErr) LDTXMonitorBufferWrite(c->ring, c->capture);
  else atomic_fetch_add_explicit(&c->errors, 1, memory_order_relaxed);
  return status;
}

static OSStatus sourceAU(void *context, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *output) {
  LDTXMonitorAUContext *c = context;
  if (!output || frames > c->maximumFrames || output->mNumberBuffers != c->channels) {
    atomic_fetch_add_explicit(&c->errors, 1, memory_order_relaxed);
    return kAudioUnitErr_TooManyFramesToProcess;
  }
  for (uint32_t p = 0; p < c->channels; ++p) {
    if (!output->mBuffers[p].mData) {
      output->mBuffers[p].mData = c->source[p];
      output->mBuffers[p].mDataByteSize = frames * sizeof(float);
    }
  }
  uint32_t copied = LDTXMonitorBufferRead(c->ring, output, frames,
      c->target * 2, c->target);
  if (!copied) *flags |= kAudioUnitRenderAction_OutputIsSilence;
  return noErr;
}

OSStatus LDTXMonitorAUInstallCapture(LDTXMonitorAUContext *c) {
  AURenderCallbackStruct callback = { captureAU, c };
  return AudioUnitSetProperty(c->input, kAudioOutputUnitProperty_SetInputCallback,
      kAudioUnitScope_Global, 0, &callback, sizeof(callback));
}

OSStatus LDTXMonitorAUInstallSource(LDTXMonitorAUContext *c, AudioUnit converter) {
  AURenderCallbackStruct callback = { sourceAU, c };
  return AudioUnitSetProperty(converter, kAudioUnitProperty_SetRenderCallback,
      kAudioUnitScope_Input, 0, &callback, sizeof(callback));
}

uint64_t LDTXMonitorAURenderErrors(const LDTXMonitorAUContext *c) {
  return atomic_load_explicit(&c->errors, memory_order_relaxed);
}
