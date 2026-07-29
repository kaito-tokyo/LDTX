// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

struct ClockOverlayVertexOutput {
    float4 position [[position]];
};

struct ClockGlyphInstance {
    float4 destinationRect;
    float4 atlasRect;
};

struct ClockOverlayUniforms {
    float4 foregroundColor;
    float4 backgroundColor0;
    float4 backgroundColor1;
    float4 outlineColor0;
    float4 outlineColor1;
    float2 overlaySize;
    float2 gradientDirection;
    float2 outlineThickness;
    uint backgroundKind;
    uint glyphCount;
};

struct ClockOverlayColorAlphaOutput {
    half4 color [[color(0)]];
    half4 alpha [[color(1)]];
};

vertex ClockOverlayVertexOutput clockOverlayVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0f, -1.0f),
        float2(3.0f, -1.0f),
        float2(-1.0f, 3.0f),
    };
    ClockOverlayVertexOutput output;
    output.position = float4(positions[vertexID], 0.0f, 1.0f);
    return output;
}

static inline half clockGlyphCoverage(
    float2 pixel,
    texture2d<half, access::sample> atlas,
    constant ClockOverlayUniforms& uniforms,
    const device ClockGlyphInstance* glyphs
) {
    constexpr sampler atlasSampler(
        coord::normalized,
        address::clamp_to_zero,
        filter::linear
    );
    half distance = 0.0h;
    for (uint index = 0; index < uniforms.glyphCount; index++) {
        float4 destination = glyphs[index].destinationRect;
        if (pixel.x < destination.x || pixel.y < destination.y ||
            pixel.x >= destination.z || pixel.y >= destination.w) {
            continue;
        }
        float2 size = max(destination.zw - destination.xy, float2(0.0001f));
        float2 local = (pixel - destination.xy) / size;
        float4 atlasRect = glyphs[index].atlasRect;
        float2 atlasUV = mix(atlasRect.xy, atlasRect.zw, local);
        distance = max(distance, atlas.sample(atlasSampler, atlasUV).r);
    }
    return distance;
}

static inline half4 clockBackground(float2 pixel, constant ClockOverlayUniforms& uniforms) {
    if (uniforms.backgroundKind == 0) {
        return half4(uniforms.backgroundColor0);
    }
    float2 size = max(uniforms.overlaySize, float2(1.0f));
    float2 centered = pixel / size - 0.5f;
    float2 direction = uniforms.gradientDirection;
    float extent = max(abs(direction.x) + abs(direction.y), 0.0001f);
    float amount = clamp(dot(centered, direction) / extent + 0.5f, 0.0f, 1.0f);
    return mix(half4(uniforms.backgroundColor0), half4(uniforms.backgroundColor1), half(amount));
}

static inline half4 clockOverlayColor(
    float2 pixel,
    texture2d<half, access::sample> atlas,
    constant ClockOverlayUniforms& uniforms,
    const device ClockGlyphInstance* glyphs
) {
    half distance = clockGlyphCoverage(pixel, atlas, uniforms, glyphs);
    half smoothing = max(half(fwidth(distance)), 1.0h / 255.0h);
    half fillCoverage = smoothstep(0.5h - smoothing, 0.5h + smoothing, distance);
    half outline1Threshold = 0.5h - half(uniforms.outlineThickness.x) * smoothing;
    half outline2Threshold = outline1Threshold - half(uniforms.outlineThickness.y) * smoothing;
    half outline1Coverage = smoothstep(outline1Threshold - smoothing, outline1Threshold + smoothing, distance);
    half outline2Coverage = smoothstep(outline2Threshold - smoothing, outline2Threshold + smoothing, distance);
    half4 foreground = half4(uniforms.foregroundColor);
    half4 outline1 = half4(uniforms.outlineColor0);
    half4 outline2 = half4(uniforms.outlineColor1);
    half4 background = clockBackground(pixel, uniforms);
    half fillAlpha = clamp(foreground.a * fillCoverage, 0.0h, 1.0h);
    half outline1Alpha = clamp(outline1.a * max(outline1Coverage - fillCoverage, 0.0h), 0.0h, 1.0h);
    half outline2Alpha = clamp(outline2.a * max(outline2Coverage - outline1Coverage, 0.0h), 0.0h, 1.0h);
    half foregroundAlpha = fillAlpha + outline1Alpha + outline2Alpha;
    half3 foregroundPremultiplied =
        foreground.rgb * fillAlpha + outline1.rgb * outline1Alpha + outline2.rgb * outline2Alpha;
    half backgroundAlpha = clamp(background.a, 0.0h, 1.0h);
    half outputAlpha = foregroundAlpha + backgroundAlpha * (1.0h - foregroundAlpha);
    half3 premultiplied =
        foregroundPremultiplied +
        background.rgb * backgroundAlpha * (1.0h - foregroundAlpha);
    half3 straightColor = outputAlpha > 0.0h
        ? premultiplied / outputAlpha
        : half3(0.0h);
    return half4(clamp(straightColor, half3(0.0h), half3(1.0h)), outputAlpha);
}

fragment half4 clockOverlayColorFragment(
    ClockOverlayVertexOutput input [[stage_in]],
    texture2d<half, access::sample> atlas [[texture(0)]],
    constant ClockOverlayUniforms& uniforms [[buffer(0)]],
    const device ClockGlyphInstance* glyphs [[buffer(1)]]
) {
    half4 overlay = clockOverlayColor(input.position.xy, atlas, uniforms, glyphs);
    return half4(overlay.rgb, 1.0h);
}

fragment ClockOverlayColorAlphaOutput clockOverlayColorAlphaFragment(
    ClockOverlayVertexOutput input [[stage_in]],
    texture2d<half, access::sample> atlas [[texture(0)]],
    constant ClockOverlayUniforms& uniforms [[buffer(0)]],
    const device ClockGlyphInstance* glyphs [[buffer(1)]]
) {
    half4 overlay = clockOverlayColor(input.position.xy, atlas, uniforms, glyphs);
    ClockOverlayColorAlphaOutput output;
    output.color = half4(overlay.rgb, 1.0h);
    output.alpha = half4(overlay.a, 0.0h, 0.0h, 1.0h);
    return output;
}
