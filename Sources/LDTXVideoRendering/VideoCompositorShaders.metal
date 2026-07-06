// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

static inline half3 yuvFullToRGB(half y, half2 uv) {
    half cb = uv.x - 0.5h;
    half cr = uv.y - 0.5h;
    half r = y + 1.5748h * cr;
    half g = y - 0.1873h * cb - 0.4681h * cr;
    half b = y + 1.8556h * cb;
    return clamp(half3(r, g, b), half3(0.0h), half3(1.0h));
}

kernel void clearLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    outputLuma.write(uint4(0u, 0u, 0u, 255u), gid);
}

kernel void clearChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    outputChroma.write(uint4(128u, 128u, 0u, 255u), gid);
}

kernel void previewNV12ToBGRAKernel(
    texture2d<half, access::sample> sourceLuma [[texture(0)]],
    texture2d<half, access::sample> sourceChroma [[texture(1)]],
    texture2d<half, access::write> outputBGRA [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputBGRA.get_width() || gid.y >= outputBGRA.get_height()) {
        return;
    }

    float2 outputSize = float2(outputBGRA.get_width(), outputBGRA.get_height());
    float2 sourceSize = float2(sourceLuma.get_width(), sourceLuma.get_height());
    float scale = min(outputSize.x / sourceSize.x, outputSize.y / sourceSize.y);
    float2 scaledSize = sourceSize * scale;
    float2 origin = (outputSize - scaledSize) * 0.5f;
    float2 sourcePixel = (float2(gid) + 0.5f - origin) / scale;

    if (sourcePixel.x < 0.0f ||
        sourcePixel.y < 0.0f ||
        sourcePixel.x >= sourceSize.x ||
        sourcePixel.y >= sourceSize.y) {
        outputBGRA.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
        return;
    }

    float2 uv = (sourcePixel + 0.5f) / sourceSize;
    half luma = sourceLuma.sample(linearSampler, uv).r;
    half2 chroma = sourceChroma.sample(linearSampler, uv).rg;
    half3 rgb = yuvFullToRGB(luma, chroma);
    outputBGRA.write(half4(rgb, 1.0h), gid);
}

kernel void solidColorLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant uint& luma0 [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 p = gid + offsetXY;
    outputLuma.write(uint4(luma0, 0u, 0u, 255u), p);
}

kernel void solidColorLumaAlphaKernel(
    texture2d<uint, access::read_write> outputLuma [[texture(0)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant uint& luma0 [[buffer(6)]],
    constant uint& alpha0 [[buffer(12)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 p = gid + offsetXY;
    uint destLuma = outputLuma.read(p).r;
    uint luma = (luma0 * alpha0 + destLuma * (255u - alpha0) + 127u) / 255u;
    outputLuma.write(uint4(luma, 0u, 0u, 255u), p);
}

kernel void solidColorChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant uint2& chroma0 [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 p = gid + offsetXY;
    outputChroma.write(uint4(chroma0.x, chroma0.y, 0u, 255u), p);
}

kernel void solidColorChromaAlphaKernel(
    texture2d<uint, access::read_write> outputChroma [[texture(1)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant uint2& chroma0 [[buffer(6)]],
    constant uint& alpha0 [[buffer(12)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 p = gid + offsetXY;
    uint2 destChroma = outputChroma.read(p).rg;
    uint2 chroma = (chroma0 * alpha0 + destChroma * (255u - alpha0) + 127u) / 255u;
    outputChroma.write(uint4(chroma, 0u, 255u), p);
}

kernel void linearGradientLumaKernel(
    texture2d<uint, access::read_write> outputLuma [[texture(0)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant half& luma0 [[buffer(6)]],
    constant half& alpha0 [[buffer(7)]],
    constant half& luma1 [[buffer(8)]],
    constant half& alpha1 [[buffer(9)]],
    constant float2& pointUV0 [[buffer(10)]],
    constant float2& axisUV [[buffer(11)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    uint2 p = gid + offsetXY;
    float2 uv = (float2(gid) + 0.5f) / float2(gridSize);
    half t = half(clamp(dot(uv - pointUV0, axisUV) / dot(axisUV, axisUV), 0.0f, 1.0f));
    uint gradientLuma = min(uint(mix(luma0, luma1, t) * 255.0h), 255u);
    uint gradientAlpha = min(uint(mix(alpha0, alpha1, t) * 255.0h), 255u);
    uint destLuma = outputLuma.read(p).r;
    uint luma = (gradientLuma * gradientAlpha + destLuma * (255u - gradientAlpha) + 127u) / 255u;
    outputLuma.write(uint4(luma, 0u, 0u, 255u), p);
}

kernel void linearGradientChromaKernel(
    texture2d<uint, access::read_write> outputChroma [[texture(1)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant half2& chroma0 [[buffer(6)]],
    constant half& alpha0 [[buffer(7)]],
    constant half2& chroma1 [[buffer(8)]],
    constant half& alpha1 [[buffer(9)]],
    constant float2& pointUV0 [[buffer(10)]],
    constant float2& axisUV [[buffer(11)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    uint2 p = gid + offsetXY;
    float2 uv = (float2(gid) + 0.5f) / float2(gridSize);
    half t = half(clamp(dot(uv - pointUV0, axisUV) / dot(axisUV, axisUV), 0.0f, 1.0f));
    uint2 gradientChroma = min(uint2(mix(chroma0, chroma1, t) * 255.0h), 255u);
    uint gradientAlpha = min(uint(mix(alpha0, alpha1, t) * 255.0h), 255u);
    uint2 destChroma = outputChroma.read(p).rg;
    uint2 chroma = (gradientChroma * gradientAlpha + destChroma * (255u - gradientAlpha) + 127u) / 255u;
    outputChroma.write(uint4(chroma, 0u, 255u), p);
}

kernel void radialGradientLumaKernel(
    texture2d<uint, access::read_write> outputLuma [[texture(0)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant half& luma0 [[buffer(6)]],
    constant half& alpha0 [[buffer(7)]],
    constant half& luma1 [[buffer(8)]],
    constant half& alpha1 [[buffer(9)]],
    constant float2& centerUV [[buffer(10)]],
    constant float2& radiusUV [[buffer(11)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    uint2 p = gid + offsetXY;
    float2 uv = (float2(gid) + 0.5f) / float2(gridSize);
    half t = half(clamp((distance(uv, centerUV) - radiusUV.x) / (radiusUV.y - radiusUV.x), 0.0f, 1.0f));
    uint gradientLuma = min(uint(mix(luma0, luma1, t) * 255.0h), 255u);
    uint gradientAlpha = min(uint(mix(alpha0, alpha1, t) * 255.0h), 255u);
    uint destLuma = outputLuma.read(p).r;
    uint luma = (gradientLuma * gradientAlpha + destLuma * (255u - gradientAlpha) + 127u) / 255u;
    outputLuma.write(uint4(luma, 0, 0, 255), p);
}

kernel void radialGradientChromaKernel(
    texture2d<uint, access::read_write> outputChroma [[texture(1)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant half2& chroma0 [[buffer(6)]],
    constant half& alpha0 [[buffer(7)]],
    constant half2& chroma1 [[buffer(8)]],
    constant half& alpha1 [[buffer(9)]],
    constant float2& centerUV [[buffer(10)]],
    constant float2& radiusUV [[buffer(11)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    uint2 p = gid + offsetXY;
    float2 uv = (float2(gid) + 0.5f) / float2(gridSize);
    half t = half(clamp((distance(uv, centerUV) - radiusUV.x) / (radiusUV.y - radiusUV.x), 0.0f, 1.0f));
    uint2 gradientChroma = min(uint2(mix(chroma0, chroma1, t) * 255.0h), 255u);
    uint gradientAlpha = min(uint(mix(alpha0, alpha1, t) * 255.0h), 255u);
    uint2 destChroma = outputChroma.read(p).rg;
    uint2 chroma = (gradientChroma * gradientAlpha + destChroma * (255u - gradientAlpha) + 127u) / 255u;
    outputChroma.write(uint4(chroma, 0u, 255u), p);
}

kernel void conicGradientLumaKernel(
    texture2d<uint, access::read_write> outputLuma [[texture(0)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant half& luma0 [[buffer(6)]],
    constant half& alpha0 [[buffer(7)]],
    constant half& luma1 [[buffer(8)]],
    constant half& alpha1 [[buffer(9)]],
    constant float2& centerUV [[buffer(10)]],
    constant float& startAngleRadians [[buffer(11)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    constexpr float invTwoPi = 0.15915494309189533577;
    uint2 p = gid + offsetXY;
    float2 uv = (float2(gid) + 0.5f) / float2(gridSize);
    float2 delta = uv - centerUV;
    float angle = atan2(delta.y, delta.x) - startAngleRadians;
    half t = half(fract(angle * invTwoPi));
    uint gradientLuma = min(uint(mix(luma0, luma1, t) * 255.0h), 255u);
    uint gradientAlpha = min(uint(mix(alpha0, alpha1, t) * 255.0h), 255u);
    uint destLuma = outputLuma.read(p).r;
    uint luma = (gradientLuma * gradientAlpha + destLuma * (255u - gradientAlpha) + 127u) / 255u;
    outputLuma.write(uint4(luma, 0u, 0u, 255u), p);
}

kernel void conicGradientChromaKernel(
    texture2d<uint, access::read_write> outputChroma [[texture(1)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant half2& chroma0 [[buffer(6)]],
    constant half& alpha0 [[buffer(7)]],
    constant half2& chroma1 [[buffer(8)]],
    constant half& alpha1 [[buffer(9)]],
    constant float2& centerUV [[buffer(10)]],
    constant float& startAngleRadians [[buffer(11)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    constexpr float invTwoPi = 0.15915494309189533577;
    uint2 p = gid + offsetXY;
    float2 uv = (float2(gid) + 0.5f) / float2(gridSize);
    float2 delta = uv - centerUV;
    float angle = atan2(delta.y, delta.x) - startAngleRadians;
    half t = half(fract(angle * invTwoPi));
    uint2 gradientChroma = min(uint2(mix(chroma0, chroma1, t) * 255.0h), 255u);
    uint gradientAlpha = min(uint(mix(alpha0, alpha1, t) * 255.0h), 255u);
    uint2 destChroma = outputChroma.read(p).rg;
    uint2 chroma = (gradientChroma * gradientAlpha + destChroma * (255u - gradientAlpha) + 127u) / 255u;
    outputChroma.write(uint4(chroma, 0u, 255u), p);
}

kernel void testPatternLumaKernel(
    texture2d<uint, access::write> outputLuma [[texture(0)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant float& timeSeconds [[buffer(10)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    uint2 p = gid + offsetXY;
    float2 uv = (float2(gid) + 0.5f) / float2(gridSize);
    float t = timeSeconds * 0.5f;
    float right = step(0.5f, fract(uv.x * 12.0f - t));
    float left = step(0.5f, fract(uv.x * 11.0f + t));
    float down = step(0.5f, fract(uv.y * 8.0f - t));
    float up = step(0.5f, fract(uv.y * 7.0f + t));
    half r = half(right + up) * 0.5h;
    half g = half(left + down) * 0.5h;
    half b = half(right + left + up + down) * 0.25h;
    uint luma = min(uint((0.2126h * r + 0.7152h * g + 0.0722h * b) * 255.0h), 255u);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), p);
}

kernel void testPatternChromaKernel(
    texture2d<uint, access::write> outputChroma [[texture(1)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant float& timeSeconds [[buffer(10)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    uint2 p = gid + offsetXY;
    float2 uv = (float2(gid) + 0.5f) / float2(gridSize);
    float t = timeSeconds * 0.5f;
    float right = step(0.5f, fract(uv.x * 12.0f - t));
    float left = step(0.5f, fract(uv.x * 11.0f + t));
    float down = step(0.5f, fract(uv.y * 8.0f - t));
    float up = step(0.5f, fract(uv.y * 7.0f + t));
    half r = half(right + up) * 0.5h;
    half g = half(left + down) * 0.5h;
    half b = half(right + left + up + down) * 0.25h;
    half luma = 0.2126h * r + 0.7152h * g + 0.0722h * b;
    half2 chromaUnit = half2(0.5h + (b - luma) / 1.8556h, 0.5h + (r - luma) / 1.5748h);
    uint2 chroma = min(uint2(clamp(chromaUnit, half2(0.0h), half2(1.0h)) * 255.0h), 255u);
    outputChroma.write(uint4(chroma, 0u, 255u), p);
}
