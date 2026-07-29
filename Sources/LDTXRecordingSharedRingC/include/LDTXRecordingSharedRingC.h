// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#ifndef LDTX_RECORDING_SHARED_RING_C_H
#define LDTX_RECORDING_SHARED_RING_C_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
  _Atomic uint64_t write_position;
  _Atomic uint64_t read_position;
  uint64_t capacity;
  uint64_t protocol_version;
  uint8_t reserved[32];
} LDTXRecordingSharedRingHeader;

void ldtx_recording_ring_initialize(
  LDTXRecordingSharedRingHeader *header,
  uint64_t capacity,
  uint64_t protocol_version
);
uint64_t ldtx_recording_ring_load_write(const LDTXRecordingSharedRingHeader *header);
uint64_t ldtx_recording_ring_load_read(const LDTXRecordingSharedRingHeader *header);
void ldtx_recording_ring_store_write(LDTXRecordingSharedRingHeader *header, uint64_t value);
void ldtx_recording_ring_store_read(LDTXRecordingSharedRingHeader *header, uint64_t value);

#endif
