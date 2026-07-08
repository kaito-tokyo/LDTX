// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

constant uint selfieInputWidth = 256;
constant uint selfieInputHeight = 144;
constant uint selfieInputPlaneCount = selfieInputWidth * selfieInputHeight;
constant uint selfieInputColorRangeVideo = 0;

static inline float clamp01(float value) {
    return clamp(value, 0.0f, 1.0f);
}

static inline float lumaUnit(uint y, bool isVideoRange) {
    if (isVideoRange) {
        return clamp01((float(y) - 16.0f) / 219.0f);
    }
    return float(y) / 255.0f;
}

static inline float3 rgbFromYUV(uint y, uint u, uint v, bool isVideoRange) {
    const float luma = lumaUnit(y, isVideoRange);
    const float chromaScale = isVideoRange ? 224.0f : 255.0f;
    const float cb = (float(u) - 128.0f) / chromaScale;
    const float cr = (float(v) - 128.0f) / chromaScale;
    return clamp(float3(
        luma + 1.5748f * cr,
        luma - 0.1873f * cb - 0.4681f * cr,
        luma + 1.8556f * cb
    ), 0.0f, 1.0f);
}

static inline void fillSelfieInputChannel(
    texture2d<uint, access::read> lumaTexture,
    texture2d<uint, access::read> chromaTexture,
    device half *input,
    uint colorRange,
    uint channel,
    uint2 outputCoordinate
) {
    if (outputCoordinate.x >= selfieInputWidth || outputCoordinate.y >= selfieInputHeight) {
        return;
    }

    const uint sourceWidth = lumaTexture.get_width();
    const uint sourceHeight = lumaTexture.get_height();
    const uint chromaWidth = chromaTexture.get_width();
    const uint chromaHeight = chromaTexture.get_height();
    const uint sourceX = min(outputCoordinate.x * sourceWidth / selfieInputWidth, sourceWidth - 1);
    const uint sourceY = min(outputCoordinate.y * sourceHeight / selfieInputHeight, sourceHeight - 1);
    const uint chromaX = min(sourceX / 2, chromaWidth - 1);
    const uint chromaY = min(sourceY / 2, chromaHeight - 1);
    const uint y = lumaTexture.read(uint2(sourceX, sourceY)).r;
    const uint2 uv = chromaTexture.read(uint2(chromaX, chromaY)).rg;
    const float3 rgb = rgbFromYUV(y, uv.x, uv.y, colorRange == selfieInputColorRangeVideo);
    const uint inputIndex = outputCoordinate.y * selfieInputWidth + outputCoordinate.x;
    input[channel * selfieInputPlaneCount + inputIndex] = half(rgb[channel]);
}

kernel void fillSelfieInputRedKernel(
    texture2d<uint, access::read> lumaTexture [[texture(0)]],
    texture2d<uint, access::read> chromaTexture [[texture(1)]],
    device half *input [[buffer(0)]],
    constant uint &colorRange [[buffer(1)]],
    uint2 outputCoordinate [[thread_position_in_grid]]
) {
    fillSelfieInputChannel(lumaTexture, chromaTexture, input, colorRange, 0, outputCoordinate);
}

kernel void fillSelfieInputGreenKernel(
    texture2d<uint, access::read> lumaTexture [[texture(0)]],
    texture2d<uint, access::read> chromaTexture [[texture(1)]],
    device half *input [[buffer(0)]],
    constant uint &colorRange [[buffer(1)]],
    uint2 outputCoordinate [[thread_position_in_grid]]
) {
    fillSelfieInputChannel(lumaTexture, chromaTexture, input, colorRange, 1, outputCoordinate);
}

kernel void fillSelfieInputBlueKernel(
    texture2d<uint, access::read> lumaTexture [[texture(0)]],
    texture2d<uint, access::read> chromaTexture [[texture(1)]],
    device half *input [[buffer(0)]],
    constant uint &colorRange [[buffer(1)]],
    uint2 outputCoordinate [[thread_position_in_grid]]
) {
    fillSelfieInputChannel(lumaTexture, chromaTexture, input, colorRange, 2, outputCoordinate);
}
