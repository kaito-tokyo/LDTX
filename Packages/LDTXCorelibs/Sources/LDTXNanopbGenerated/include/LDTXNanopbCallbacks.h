/* SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
 * SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <pb.h>
#include <pb_decode.h>
#include <pb_encode.h>

/* Schema-independent synchronous callbacks. Payloads remain owned by Swift. */
typedef struct {
  void *state;
  bool (*decode)(pb_istream_t *, uint32_t, void *);
  bool (*encode)(pb_ostream_t *, uint32_t, void *);
} ldtx_nanopb_context;

bool ldtx_nanopb_field_callback(pb_istream_t *, pb_ostream_t *, const pb_field_t *);
bool ldtx_nanopb_decode(pb_istream_t *, const pb_msgdesc_t *, void *);
