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

/// Bakes Unicode scalars U+0020 through U+007E into an 8-bit coverage atlas.
/// Returns a positive atlas row on success and a non-positive value when the
/// atlas cannot hold every glyph.
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
