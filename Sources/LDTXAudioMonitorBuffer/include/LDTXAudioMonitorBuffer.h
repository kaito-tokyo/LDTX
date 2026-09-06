// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LDTXMonitorBuffer LDTXMonitorBuffer;
// One AUHAL producer and one converter render consumer. Layout remains fixed until both stop.
LDTXMonitorBuffer *LDTXMonitorBufferCreate(uint32_t capacity, uint32_t planeCount,
                                        const uint32_t *bytesPerFrame);
void LDTXMonitorBufferDestroy(LDTXMonitorBuffer *buffer);
bool LDTXMonitorBufferWrite(LDTXMonitorBuffer *buffer, const AudioBufferList *input);
// Copies available frames and zeroes the remainder. Excessive backlog is discarded
// by the consumer, which alone owns the read cursor.
uint32_t LDTXMonitorBufferRead(LDTXMonitorBuffer *buffer, AudioBufferList *output,
                             uint32_t frames, uint32_t backlogLimit, uint32_t target);
uint32_t LDTXMonitorBufferAvailable(const LDTXMonitorBuffer *buffer);
uint64_t LDTXMonitorBufferDropped(const LDTXMonitorBuffer *buffer);
uint64_t LDTXMonitorBufferReceived(const LDTXMonitorBuffer *buffer);
uint64_t LDTXMonitorBufferMissing(const LDTXMonitorBuffer *buffer);
// The context borrows the ring and Audio Unit. Stop and dispose connected units
// before destroying it. All render storage is allocated here, never in callbacks.
typedef struct LDTXMonitorAUContext LDTXMonitorAUContext;
LDTXMonitorAUContext *LDTXMonitorAUContextCreate(LDTXMonitorBuffer *buffer,
    AudioUnit inputUnit, uint32_t channels, uint32_t maximumFrames, uint32_t target);
void LDTXMonitorAUContextDestroy(LDTXMonitorAUContext *context);
OSStatus LDTXMonitorAUInstallCapture(LDTXMonitorAUContext *context);
OSStatus LDTXMonitorAUInstallSource(LDTXMonitorAUContext *context, AudioUnit converter);
uint64_t LDTXMonitorAURenderErrors(const LDTXMonitorAUContext *context);
#ifdef __cplusplus
}
#endif
