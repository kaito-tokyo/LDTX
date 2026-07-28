// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#include "LDTXFontRasterizer.h"

#define LDTX_CLOCK_ASCII_GLYPH_COUNT 95

int32_t ldtx_bake_clock_ascii_glyphs(
    const uint8_t *font_data,
    float pixel_height,
    uint8_t *atlas_pixels,
    int32_t atlas_width,
    int32_t atlas_height,
    LDTXBakedGlyph *glyphs,
    int32_t glyph_count) {
  const int32_t first_code_point = 0x20;
  const int32_t required_glyph_count = LDTX_CLOCK_ASCII_GLYPH_COUNT;
  if (font_data == NULL || atlas_pixels == NULL || glyphs == NULL ||
      glyph_count < required_glyph_count || atlas_width <= 0 ||
      atlas_height <= 0 || pixel_height <= 0.0f) {
    return 0;
  }

  stbtt_bakedchar baked[LDTX_CLOCK_ASCII_GLYPH_COUNT];
  int result = stbtt_BakeFontBitmap(
      font_data,
      0,
      pixel_height,
      atlas_pixels,
      atlas_width,
      atlas_height,
      first_code_point,
      required_glyph_count,
      baked);
  if (result <= 0) {
    return result;
  }

  for (int32_t index = 0; index < required_glyph_count; index++) {
    glyphs[index].x0 = baked[index].x0;
    glyphs[index].y0 = baked[index].y0;
    glyphs[index].x1 = baked[index].x1;
    glyphs[index].y1 = baked[index].y1;
    glyphs[index].x_offset = baked[index].xoff;
    glyphs[index].y_offset = baked[index].yoff;
    glyphs[index].x_advance = baked[index].xadvance;
  }
  return result;
}
