// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include "LDTXRecordingSharedRingC.h"

void ldtx_recording_ring_initialize(
  LDTXRecordingSharedRingHeader *header,
  uint64_t capacity,
  uint64_t protocol_version
) {
  atomic_init(&header->write_position, 0);
  atomic_init(&header->read_position, 0);
  header->capacity = capacity;
  header->protocol_version = protocol_version;
}

uint64_t ldtx_recording_ring_load_write(const LDTXRecordingSharedRingHeader *header) {
  return atomic_load_explicit(&header->write_position, memory_order_acquire);
}

uint64_t ldtx_recording_ring_load_read(const LDTXRecordingSharedRingHeader *header) {
  return atomic_load_explicit(&header->read_position, memory_order_acquire);
}

void ldtx_recording_ring_store_write(LDTXRecordingSharedRingHeader *header, uint64_t value) {
  atomic_store_explicit(&header->write_position, value, memory_order_release);
}

void ldtx_recording_ring_store_read(LDTXRecordingSharedRingHeader *header, uint64_t value) {
  atomic_store_explicit(&header->read_position, value, memory_order_release);
}
