// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

static inline float previewSampleUint8(texture2d<uint, access::read> texture, float2 uv, uint channel) {
    float2 size = float2(texture.get_width(), texture.get_height());
    float2 pixel = clamp(uv, float2(0.0f), float2(1.0f)) * size - 0.5f;
    int2 p0 = int2(floor(pixel));
    int2 p1 = p0 + int2(1);
    int2 maxPixel = int2(int(texture.get_width()) - 1, int(texture.get_height()) - 1);
    uint2 c00 = uint2(clamp(p0, int2(0), maxPixel));
    uint2 c10 = uint2(clamp(int2(p1.x, p0.y), int2(0), maxPixel));
    uint2 c01 = uint2(clamp(int2(p0.x, p1.y), int2(0), maxPixel));
    uint2 c11 = uint2(clamp(p1, int2(0), maxPixel));
    float2 f = fract(pixel);
    float v00 = float(texture.read(c00)[channel]);
    float v10 = float(texture.read(c10)[channel]);
    float v01 = float(texture.read(c01)[channel]);
    float v11 = float(texture.read(c11)[channel]);
    return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}

static inline half previewSampleLuma(texture2d<uint, access::read> luma, float2 uv) {
    return half(previewSampleUint8(luma, uv, 0u) / 255.0f);
}

static inline half2 previewSampleChroma(texture2d<uint, access::read> chroma, float2 uv) {
    return half2(
        half(previewSampleUint8(chroma, uv, 0u) / 255.0f),
        half(previewSampleUint8(chroma, uv, 1u) / 255.0f)
    );
}

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
    texture2d<uint, access::read> sourceLuma [[texture(0)]],
    texture2d<uint, access::read> sourceChroma [[texture(1)]],
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
    half luma = previewSampleLuma(sourceLuma, uv);
    half2 chroma = previewSampleChroma(sourceChroma, uv);
    half3 rgb = yuvFullToRGB(luma, chroma);
    outputBGRA.write(half4(rgb, 1.0h), gid);
}

// Draw one preview directly into a region of the drawable; no intermediate BGRA image.
kernel void previewNV12RegionKernel(
    texture2d<uint, access::read> sourceLuma [[texture(0)]],
    texture2d<uint, access::read> sourceChroma [[texture(1)]],
    texture2d<half, access::write> outputBGRA [[texture(2)]],
    constant uint4& region [[buffer(0)]],
    constant uint& state [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 destination = region.xy + gid;
    if (any(gid >= region.zw) || destination.x >= outputBGRA.get_width()
        || destination.y >= outputBGRA.get_height()) return;
    if (state != 1u && state != 3u) {
        half level = state == 2u ? 0.25h : 0.0h;
        outputBGRA.write(half4(level, level, level, 1.0h), destination);
        return;
    }
    float2 sourceSize = float2(sourceLuma.get_width(), sourceLuma.get_height());
    float2 outputSize = float2(region.zw);
    float scale = min(outputSize.x / sourceSize.x, outputSize.y / sourceSize.y);
    float2 origin = (outputSize - sourceSize * scale) * 0.5f;
    float2 pixel = (float2(gid) + 0.5f - origin) / scale;
    if (any(pixel < 0.0f) || any(pixel >= sourceSize)) {
        outputBGRA.write(half4(0.0h, 0.0h, 0.0h, 1.0h), destination);
        return;
    }
    float2 uv = pixel / sourceSize;
    if (state == 3u) {
        half level = half(previewSampleLuma(sourceLuma, uv));
        outputBGRA.write(half4(level, level, level, 1.0h), destination);
        return;
    }
    outputBGRA.write(half4(yuvFullToRGB(previewSampleLuma(sourceLuma, uv),
                                     previewSampleChroma(sourceChroma, uv)), 1.0h), destination);
}

kernel void previewLumaToGrayscaleBGRAKernel(
    texture2d<uint, access::read> sourceLuma [[texture(0)]],
    texture2d<half, access::write> outputBGRA [[texture(1)]],
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
    half luma = previewSampleLuma(sourceLuma, uv);
    outputBGRA.write(half4(luma, luma, luma, 1.0h), gid);
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

static inline uint retainedTextureLuma(half3 rgb) {
    uint3 rgb8 = min(
        uint3(clamp(rgb, half3(0.0h), half3(1.0h)) * 255.0h + 0.5h),
        uint3(255u)
    );
    uint value =
        13933u * rgb8.r +
        46871u * rgb8.g +
        4732u * rgb8.b +
        32768u;
    return min(value >> 16u, 255u);
}

static inline uint2 retainedTextureChroma(half3 rgb) {
    uint3 rgb8 = min(
        uint3(clamp(rgb, half3(0.0h), half3(1.0h)) * 255.0h + 0.5h),
        uint3(255u)
    );
    int cbOffset =
        -7509 * int(rgb8.r) -
        25259 * int(rgb8.g) +
        32768 * int(rgb8.b);
    int crOffset =
        32768 * int(rgb8.r) -
        29763 * int(rgb8.g) -
        3005 * int(rgb8.b);
    int cb = 128 + ((cbOffset + 32768) >> 16);
    int cr = 128 + ((crOffset + 32768) >> 16);
    return uint2(clamp(int2(cb, cr), int2(0), int2(255)));
}

static inline uint retainedTextureAlpha(
    texture2d<half, access::sample> alphaTexture,
    sampler textureSampler,
    float2 uv
) {
    return min(uint(alphaTexture.sample(textureSampler, uv).r * 255.0h + 0.5h), 255u);
}

kernel void retainedTextureLumaKernel(
    texture2d<uint, access::read_write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> sourceColor [[texture(2)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant float2& sourceOrigin [[buffer(5)]],
    constant float2& sourceScale [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    constexpr sampler textureSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    uint2 p = gid + offsetXY;
    float2 uv = sourceOrigin + ((float2(gid) + 0.5f) / float2(gridSize)) * sourceScale;
    uint luma = retainedTextureLuma(sourceColor.sample(textureSampler, uv).rgb);
    outputLuma.write(uint4(luma, 0u, 0u, 255u), p);
}

kernel void retainedTextureLumaAlphaKernel(
    texture2d<uint, access::read_write> outputLuma [[texture(0)]],
    texture2d<half, access::sample> sourceColor [[texture(2)]],
    texture2d<half, access::sample> sourceAlpha [[texture(3)]],
    constant uint2& offsetXY [[buffer(2)]],
    constant float2& sourceOrigin [[buffer(5)]],
    constant float2& sourceScale [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]]
) {
    constexpr sampler textureSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    uint2 p = gid + offsetXY;
    float2 uv = sourceOrigin + ((float2(gid) + 0.5f) / float2(gridSize)) * sourceScale;
    uint sourceLuma = retainedTextureLuma(sourceColor.sample(textureSampler, uv).rgb);
    uint alpha = retainedTextureAlpha(sourceAlpha, textureSampler, uv);
    uint destinationLuma = outputLuma.read(p).r;
    uint luma = (sourceLuma * alpha + destinationLuma * (255u - alpha) + 127u) / 255u;
    outputLuma.write(uint4(luma, 0u, 0u, 255u), p);
}

kernel void retainedTextureChromaKernel(
    texture2d<uint, access::read_write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> sourceColor [[texture(2)]],
    constant uint2& destinationOrigin [[buffer(2)]],
    constant uint2& destinationSize [[buffer(3)]],
    constant uint2& chromaOffsetXY [[buffer(4)]],
    constant float2& sourceOrigin [[buffer(5)]],
    constant float2& sourceScale [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]]
) {
    constexpr sampler textureSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    uint2 p = gid + chromaOffsetXY;
    uint2 destinationEnd = destinationOrigin + destinationSize;
    uint2 sourceChromaSum = uint2(0u);
    uint coveredSampleCount = 0u;

    for (uint y = 0u; y < 2u; y++) {
        for (uint x = 0u; x < 2u; x++) {
            uint2 outputPixel = p * 2u + uint2(x, y);
            if (any(outputPixel < destinationOrigin) || any(outputPixel >= destinationEnd)) {
                continue;
            }
            float2 sourcePixel = float2(outputPixel - destinationOrigin) + 0.5f;
            float2 uv = sourceOrigin + (sourcePixel / float2(destinationSize)) * sourceScale;
            sourceChromaSum += retainedTextureChroma(
                sourceColor.sample(textureSampler, uv).rgb
            );
            coveredSampleCount++;
        }
    }

    uint2 destinationChroma = outputChroma.read(p).rg;
    constexpr uint chromaSampleCount = 4u;
    uint2 chroma =
        (sourceChromaSum +
         destinationChroma * (chromaSampleCount - coveredSampleCount) +
         chromaSampleCount / 2u) /
        chromaSampleCount;
    outputChroma.write(uint4(chroma, 0u, 255u), p);
}

kernel void retainedTextureChromaAlphaKernel(
    texture2d<uint, access::read_write> outputChroma [[texture(1)]],
    texture2d<half, access::sample> sourceColor [[texture(2)]],
    texture2d<half, access::sample> sourceAlpha [[texture(3)]],
    constant uint2& destinationOrigin [[buffer(2)]],
    constant uint2& destinationSize [[buffer(3)]],
    constant uint2& chromaOffsetXY [[buffer(4)]],
    constant float2& sourceOrigin [[buffer(5)]],
    constant float2& sourceScale [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]]
) {
    constexpr sampler textureSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    uint2 p = gid + chromaOffsetXY;
    uint2 destinationEnd = destinationOrigin + destinationSize;
    uint2 weightedSourceChroma = uint2(0u);
    uint alphaSum = 0u;

    // Chroma represents a 2x2 luma footprint. Sampling straight RGB and alpha
    // independently at its center would multiply both averages afterward and
    // darken antialiased glyph boundaries. Convert each covered luma sample to
    // integer-domain chroma first, then average its premultiplied contribution.
    for (uint y = 0u; y < 2u; y++) {
        for (uint x = 0u; x < 2u; x++) {
            uint2 outputPixel = p * 2u + uint2(x, y);
            if (any(outputPixel < destinationOrigin) || any(outputPixel >= destinationEnd)) {
                continue;
            }
            float2 sourcePixel = float2(outputPixel - destinationOrigin) + 0.5f;
            float2 uv = sourceOrigin + (sourcePixel / float2(destinationSize)) * sourceScale;
            uint alpha = retainedTextureAlpha(sourceAlpha, textureSampler, uv);
            uint2 sourceChroma = retainedTextureChroma(
                sourceColor.sample(textureSampler, uv).rgb
            );
            weightedSourceChroma += sourceChroma * alpha;
            alphaSum += alpha;
        }
    }

    uint2 destinationChroma = outputChroma.read(p).rg;
    constexpr uint chromaWeight = 4u * 255u;
    uint2 chroma =
        (weightedSourceChroma +
         destinationChroma * (chromaWeight - alphaSum) +
         chromaWeight / 2u) /
        chromaWeight;
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
