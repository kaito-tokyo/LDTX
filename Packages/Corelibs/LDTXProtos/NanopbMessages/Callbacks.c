/* SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
 * SPDX-License-Identifier: Apache-2.0 */
#include "LDTXNanopbMessages.h"
#include <pb_common.h>

bool ldtx_nanopb_field_callback(pb_istream_t *input, pb_ostream_t *output, const pb_field_t *field) {
  ldtx_nanopb_context *context = *(ldtx_nanopb_context **)field->pData;
  if (!context)
    return false;
  if (input && context->decode)
    return context->decode(input, field->tag, context->state);
  if (output && context->encode)
    return context->encode(output, field->tag, context->state);
  return false;
}

/* Field callbacks receive only the bounded payload, not its wire type.
 * Validate known-field wire types before decoding, using the official
 * descriptor iterator and stream APIs. The copied stream has no payload copy;
 * both passes read the same immutable input bytes. */
static bool validate_wire_types(pb_istream_t stream, const pb_msgdesc_t *descriptor, void *message) {
  pb_field_iter_t field;
  bool has_fields = pb_field_iter_begin(&field, descriptor, message);
  while (stream.bytes_left) {
    uint32_t tag;
    pb_wire_type_t wire;
    bool eof;
    if (!pb_decode_tag(&stream, &wire, &tag, &eof) || !tag)
      return false;
    if (has_fields && pb_field_iter_find(&field, tag)) {
      pb_wire_type_t expected;
      switch (PB_LTYPE(field.type)) {
      case PB_LTYPE_BOOL:
      case PB_LTYPE_VARINT:
      case PB_LTYPE_UVARINT:
      case PB_LTYPE_SVARINT:
        expected = PB_WT_VARINT;
        break;
      case PB_LTYPE_FIXED32:
        expected = PB_WT_32BIT;
        break;
      case PB_LTYPE_FIXED64:
        expected = PB_WT_64BIT;
        break;
      default:
        expected = PB_WT_STRING;
        break;
      }
      bool packed = PB_HTYPE(field.type) == PB_HTYPE_REPEATED && expected != PB_WT_STRING && wire == PB_WT_STRING;
      if (wire != expected && !packed)
        return false;
    }
    if (!pb_skip_field(&stream, wire))
      return false;
  }
  return true;
}

bool ldtx_nanopb_decode(pb_istream_t *stream, const pb_msgdesc_t *descriptor, void *message) {
  if (!validate_wire_types(*stream, descriptor, message))
    return false;
  return pb_decode(stream, descriptor, message);
}
