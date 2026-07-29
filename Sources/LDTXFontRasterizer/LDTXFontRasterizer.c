// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#include <string.h>

#include "LDTXFontRasterizer.h"

#define LDTX_CLOCK_ASCII_GLYPH_COUNT 95

static int ldtx_clock_uses_code_point(int code_point) {
  // Fixed Clock formatting only emits digits, date/time separators, a space,
  // and the AM/PM marker. Keep ASCII-indexed metrics for the Swift renderer,
  // but avoid the startup cost of producing SDFs that Clock cannot display.
  static const char *clock_glyphs = " 0123456789:/AMP";
  return strchr(clock_glyphs, code_point) != NULL;
}

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

  stbtt_fontinfo font;
  if (!stbtt_InitFont(&font, font_data, stbtt_GetFontOffsetForIndex(font_data, 0))) {
    return 0;
  }

  const int padding = 16;
  const int cell_width = 128;
  const int cell_height = 128;
  const int columns = atlas_width / cell_width;
  if (columns <= 0 || atlas_height / cell_height * columns < required_glyph_count) {
    return 0;
  }
  const float scale = stbtt_ScaleForPixelHeight(&font, pixel_height);
  for (int32_t index = 0; index < required_glyph_count; index++) {
    const int code_point = first_code_point + index;
    int width = 0, height = 0, xoff = 0, yoff = 0;
    unsigned char *sdf = NULL;
    if (ldtx_clock_uses_code_point(code_point)) {
      sdf = stbtt_GetCodepointSDF(
          &font, scale, code_point, padding, 128, 8.0f,
          &width, &height, &xoff, &yoff);
    }
    int advance = 0, left_side_bearing = 0;
    stbtt_GetCodepointHMetrics(&font, code_point, &advance, &left_side_bearing);

    const int cell_x = (index % columns) * cell_width;
    const int cell_y = (index / columns) * cell_height;
    if (sdf != NULL && width <= cell_width && height <= cell_height) {
      for (int row = 0; row < height; row++) {
        memcpy(
            atlas_pixels + (cell_y + row) * atlas_width + cell_x,
            sdf + row * width,
            (size_t)width);
      }
      glyphs[index].x0 = (uint16_t)cell_x;
      glyphs[index].y0 = (uint16_t)cell_y;
      glyphs[index].x1 = (uint16_t)(cell_x + width);
      glyphs[index].y1 = (uint16_t)(cell_y + height);
      glyphs[index].x_offset = (float)xoff;
      glyphs[index].y_offset = (float)yoff;
    }
    glyphs[index].x_advance = (float)advance * scale;
    if (sdf != NULL) {
      stbtt_FreeSDF(sdf, NULL);
    }
  }
  return required_glyph_count;
}
