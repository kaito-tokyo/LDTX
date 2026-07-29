// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#ifndef LDTX_FONT_RASTERIZER_H
#define LDTX_FONT_RASTERIZER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LDTXBakedGlyph {
  uint16_t x0;
  uint16_t y0;
  uint16_t x1;
  uint16_t y1;
  float x_offset;
  float y_offset;
  float x_advance;
} LDTXBakedGlyph;

/// Builds an ASCII-indexed metrics table and bakes the fixed Clock formatting
/// glyph subset into an 8-bit signed-distance atlas. The glyph boundary is
/// encoded around 128. Returns the metrics count on success and zero when the
/// font or atlas cannot represent the table.
int32_t ldtx_bake_clock_ascii_glyphs(
    const uint8_t *font_data,
    float pixel_height,
    uint8_t *atlas_pixels,
    int32_t atlas_width,
    int32_t atlas_height,
    LDTXBakedGlyph *glyphs,
    int32_t glyph_count);

#ifdef __cplusplus
}
#endif

#endif
